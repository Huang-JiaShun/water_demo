@tool
class_name WaterCaustics
extends RefCounted
## Caustics driver (docs/water_architecture.md §6.2).
##
## Grid: one texel per point on the rest surface, covering the tank footprint.
## Both textures use that parameterisation:
##   light_depth_texture (R32F): distance along the flat-surface refracted key
##     light ray from the surface to the first solid (decor, floor or wall).
##     Baked on the main thread by LightDepthBaker, re-baked when the light moves.
##   caustic_texture (RGBA32F): per-channel irradiance gain relative to calm
##     water (1 = flat). Mono mode writes the same gain to r, g and b; true-RGB
##     mode traces each channel with its own IOR (quality.caustic_rgb).
##
## Key light: a directional sun (all rays share one refracted direction Lw) or a
## local tank light at light_pos (rays diverge from it). A point q underwater maps
## to its entry texel with wl_entry() in water/shared/water_light.glsl:
##   directional: dist = (surface - q.y) / Lw.y,  entry = q.xz + Lw.xz * dist
##   local:       exact Snell inverse from light_pos to q (Newton, 3 iterations)
## It is lit iff dist <= light_depth(entry), and its caustic gain is caustic(entry).
##
## Per frame (render thread): photon splat -> resolve -> à-trous x N.

signal textures_ready

const SPLAT_SHADER := "res://water/caustics/caustic_splat.glsl"
const DENOISE_SHADER := "res://water/caustics/caustic_denoise.glsl"
const LOCAL_SIZE := 8
## Fixed-point energy of one flat-surface texel. Headroom: ~2^32 / 4096 = 1M x gain.
const FIXED_POINT := 4096.0

var caustic_texture := Texture2DRD.new()
var light_depth_texture := Texture2DRD.new()

var size := Vector2i.ZERO
## Tank-space unit vector toward the light, below the surface (refracted). Valid
## when `lit` and not `light_local`. For a local light: the direction straight below it.
var light_dir := Vector3.UP
## Tank-space position of a local key light (valid when light_local).
var light_pos := Vector3.ZERO
var light_local := false
var lit := false

var _photons_per_axis := 2
var _march_steps := 16
var _denoise_iterations := 2
var _channels := 1
var _generation := 0
var _baked_key := Vector4.ZERO

# --- render thread state ----------------------------------------------------
var _rd: RenderingDevice
var _splat_shader := RID()
var _denoise_shader := RID()
var _splat_pipeline := RID()
var _denoise_pipeline := RID()
var _sampler := RID()
var _photons := RID()
var _depth := RID()
var _gain: Array[RID] = [RID(), RID()]


func configure(p_size: Vector2i, quality: WaterQuality) -> void:
	release()
	size = p_size
	_photons_per_axis = quality.caustic_photons
	_march_steps = quality.caustic_steps
	_denoise_iterations = quality.caustic_denoise
	_channels = 3 if quality.caustic_rgb else 1
	_baked_key = Vector4.ZERO
	_generation += 1
	RenderingServer.call_on_render_thread(_rt_init.bind(size, _channels, _generation))


func release() -> void:
	caustic_texture.texture_rd_rid = RID()
	light_depth_texture.texture_rd_rid = RID()
	# At shutdown queued render-thread calls never flush, leaking the textures.
	if WaterVolumeEffect._on_render_thread():
		_rt_free()
	else:
		RenderingServer.call_on_render_thread(_rt_free)


## Directional key light. to_light_tank: unit vector toward the sun in tank space
## (above the water). Returns true when the light moved enough that light depth
## must be re-baked.
func set_light(to_light_tank: Vector3, ior: float) -> bool:
	light_local = false
	lit = to_light_tank.y > 1e-3
	if not lit:
		return false
	var eta := 1.0 / ior
	var t := Vector2(to_light_tank.x, to_light_tank.z) * eta
	light_dir = Vector3(t.x, sqrt(maxf(1.0 - t.length_squared(), 0.0)), t.y).normalized()
	# ~0.25 degrees.
	return _baked_key.w != 0.0 or Vector3(_baked_key.x, _baked_key.y, _baked_key.z).dot(light_dir) < 0.99999


## Local key light (tank hood). pos_tank: light position in tank space; it must be
## above the rest surface (surface_height) to light the water. Returns true when
## light depth must be re-baked (moved by more than 1 mm).
func set_local_light(pos_tank: Vector3, surface_height: float) -> bool:
	light_local = true
	light_pos = pos_tank
	light_dir = Vector3.UP
	lit = pos_tank.y > surface_height + 1e-3
	if not lit:
		return false
	return _baked_key.w != 1.0 or Vector3(_baked_key.x, _baked_key.y, _baked_key.z).distance_to(pos_tank) > 1e-3


## Light key for the current light: xyz = dir or position, w = 1 if local.
func light_key() -> Vector4:
	var v := light_pos if light_local else light_dir
	return Vector4(v.x, v.y, v.z, 1.0 if light_local else 0.0)


## Uploads a baked light-depth map (PackedFloat32Array, size.x * size.y) baked for
## light_key().
func upload_light_depth(depths: PackedFloat32Array, for_key: Vector4) -> void:
	if depths.size() != size.x * size.y:
		return
	_baked_key = for_key
	RenderingServer.call_on_render_thread(_rt_upload_depth.bind(depths.to_byte_array()))


## True when the caustic texture holds real per-channel dispersion.
func is_true_rgb() -> bool:
	return _channels == 3


## wave_rid: the sim's RGBA16F output. Call once per frame after the sim update.
## dispersion: IOR spread between red and blue (used in true-RGB mode).
func update(wave_rid: RID, tank_size: Vector3, surface_height: float, ior: float, height_scale: float,
		dispersion := 0.0) -> void:
	if size == Vector2i.ZERO:
		return
	var pc := WaterRD.push_constant(
			PackedInt32Array([size.x, size.y, _photons_per_axis, _march_steps]),
			PackedFloat32Array([
				light_dir.x, light_dir.y, light_dir.z, ior,
				tank_size.x * 0.5, surface_height, tank_size.z * 0.5, height_scale,
				FIXED_POINT, dispersion, float(_channels), 0.0,
				light_pos.x, light_pos.y, light_pos.z, 1.0 if light_local else 0.0,
			]))
	RenderingServer.call_on_render_thread(_rt_update.bind(wave_rid, pc, lit))


func _publish(caustic: RID, depth: RID, generation: int) -> void:
	if generation != _generation:
		return
	caustic_texture.texture_rd_rid = caustic
	light_depth_texture.texture_rd_rid = depth
	textures_ready.emit()


# =============================================================================
# Render thread
# =============================================================================

func _rt_init(p_size: Vector2i, channels: int, generation: int) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("WaterCaustics: requires a RenderingDevice renderer.")
		return
	_splat_shader = WaterRD.load_compute_shader(_rd, SPLAT_SHADER)
	_denoise_shader = WaterRD.load_compute_shader(_rd, DENOISE_SHADER)
	if not (_splat_shader.is_valid() and _denoise_shader.is_valid()):
		return
	_splat_pipeline = _rd.compute_pipeline_create(_splat_shader)
	_denoise_pipeline = _rd.compute_pipeline_create(_denoise_shader)

	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)

	var RD := RenderingDevice
	_photons = _rd.texture_create(WaterRD.texture_format(Vector2i(p_size.x, p_size.y * channels), RD.DATA_FORMAT_R32_UINT,
			RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_CAN_COPY_TO_BIT), RDTextureView.new())
	_rd.texture_clear(_photons, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var f32 := RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_SAMPLING_BIT \
			| RD.TEXTURE_USAGE_CAN_COPY_TO_BIT | RD.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	for i in 2:
		_gain[i] = _rd.texture_create(WaterRD.texture_format(p_size, RD.DATA_FORMAT_R32G32B32A32_SFLOAT, f32), RDTextureView.new())
		_rd.texture_clear(_gain[i], Color(1, 1, 1, 1), 0, 1, 0, 1)
	var far := PackedFloat32Array()
	far.resize(p_size.x * p_size.y)
	far.fill(1e3) # nothing blocks the light until the first bake
	_depth = _rd.texture_create(WaterRD.texture_format(p_size, RD.DATA_FORMAT_R32_SFLOAT,
			f32 | RD.TEXTURE_USAGE_CAN_UPDATE_BIT), RDTextureView.new(), [far.to_byte_array()])

	_publish.call_deferred(_gain[0], _depth, generation)


func _rt_upload_depth(data: PackedByteArray) -> void:
	if _rd and _depth.is_valid():
		_rd.texture_update(_depth, 0, data)


func _rt_update(wave_rid: RID, pc: PackedByteArray, p_lit: bool) -> void:
	if _rd == null or not _splat_pipeline.is_valid() or not _gain[0].is_valid():
		return
	if not p_lit or not wave_rid.is_valid() or not _rd.texture_is_valid(wave_rid):
		_rd.texture_clear(_gain[0], Color(1, 1, 1, 1), 0, 1, 0, 1)
		return

	var splat_set := UniformSetCacheRD.get_cache(_splat_shader, 0, [
		_sampler_uniform(0, wave_rid),
		_sampler_uniform(1, _depth),
		WaterRD.image_uniform(2, _photons),
	])
	# Result must end in _gain[0] (the published texture). The resolve writes the
	# texture that makes an even number of à-trous ping-pongs land there.
	var n := _denoise_iterations
	var first := n % 2
	var sets: Array[RID] = []
	for i in 2:
		sets.append(UniformSetCacheRD.get_cache(_denoise_shader, 0, [
			WaterRD.image_uniform(0, _photons),
			WaterRD.image_uniform(1, _gain[i]),
			WaterRD.image_uniform(2, _gain[1 - i]),
		]))
	var resolve_set: RID = sets[1 - first] # writes _gain[first]

	var gx := WaterRD.group_count(size.x, LOCAL_SIZE)
	var gy := WaterRD.group_count(size.y, LOCAL_SIZE)
	var sub := pc.decode_s32(8)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _splat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, splat_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	var channels := int(pc.decode_float(56))
	_rd.compute_list_dispatch(cl, WaterRD.group_count(size.x * sub, LOCAL_SIZE), WaterRD.group_count(size.y * sub, LOCAL_SIZE), channels)
	_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _denoise_pipeline)
	var dpc := WaterRD.push_constant(PackedInt32Array([size.x, size.y, 0, 0]),
			PackedFloat32Array([1.0 / FIXED_POINT, float(channels), 0.0, 0.0]))
	_rd.compute_list_bind_uniform_set(cl, resolve_set, 0)
	_rd.compute_list_set_push_constant(cl, dpc, dpc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	var cur := first
	for i in n:
		_rd.compute_list_add_barrier(cl)
		dpc = WaterRD.push_constant(PackedInt32Array([size.x, size.y, 1, 1 << i]),
				PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
		_rd.compute_list_bind_uniform_set(cl, sets[cur], 0)
		_rd.compute_list_set_push_constant(cl, dpc, dpc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		cur = 1 - cur
	_rd.compute_list_end()


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(texture)
	return u


func _rt_free() -> void:
	if _rd == null:
		return
	WaterRD.free_rids(_rd, [_photons, _depth, _gain[0], _gain[1], _sampler, _splat_shader, _denoise_shader])
	_photons = RID()
	_depth = RID()
	_gain = [RID(), RID()]
	_sampler = RID()
	_splat_shader = RID()
	_denoise_shader = RID()
	_splat_pipeline = RID()
	_denoise_pipeline = RID()
