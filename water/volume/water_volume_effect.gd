@tool
class_name WaterVolumeEffect
extends CompositorEffect
## Water volume pass (docs/water_architecture.md §6.3). POST_OPAQUE:
##   1. volume_march.glsl at 1/downsample resolution: tank-AABB-clipped
##      single-scatter march -> (inscatter, transmittance)
##   2. volume_composite.glsl at full resolution: depth-guided bilateral
##      upsample, color = scene * T + inscatter
## Because this runs before transparents, the water surface refracts an
## already-fogged underwater image (§3), so the surface owns no absorption.
##
## Main thread: WaterBody calls set_frame_data() every frame.
## Render thread: _render_callback() only.
##
## Not yet implemented (P4): temporal reprojection + à-trous.

const MARCH_SHADER := "res://water/volume/volume_march.glsl"
const COMPOSITE_SHADER := "res://water/volume/volume_composite.glsl"
const CONTEXT := &"water_volume"
const TEX_INSCATTER := &"inscatter"
const TEX_TRANS := &"transmittance"
const UBO_SIZE := 2 * 64 + 6 * 16 + 16

## Multiplier on in-scattered light (1 = physical).
@export var scatter_strength := 1.0
## How strongly the upsample rejects low-res samples at a different depth.
@export var depth_sharpness := 40.0

# Written on the main thread, read on the render thread. Each is replaced
# wholesale (never mutated in place), so the render thread sees a consistent copy.
var _frame := {}
var _downsample := 2
var _steps := 16

var _rd: RenderingDevice
var _march_shader := RID()
var _composite_shader := RID()
var _march_pipeline := RID()
var _composite_pipeline := RID()
var _sampler := RID()
var _ubo := RID()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	RenderingServer.call_on_render_thread(_rt_init)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		WaterRD.free_rids(_rd, [_ubo, _sampler, _march_shader, _composite_shader])


func set_quality(downsample: int, steps: int) -> void:
	_downsample = clampi(downsample, 1, 8)
	_steps = maxi(steps, 1)


## world_to_tank: tank inverse transform. surface_height, tank_size: tank units.
## sun_dir_world: unit vector toward the sun. Colours are linear.
func set_frame_data(world_to_tank: Transform3D, tank_size: Vector3, surface_height: float,
		optics: WaterOptics, sun_dir_world: Vector3, sun_irradiance: Color, ambient: Color) -> void:
	_frame = {
		world_to_tank = world_to_tank,
		tank_max = Vector3(tank_size.x * 0.5, surface_height, tank_size.z * 0.5),
		sigma_a = optics.absorption,
		sigma_s = optics.scattering,
		g = optics.phase_g,
		ior = optics.ior,
		sun_dir_tank = (world_to_tank.basis * sun_dir_world).normalized(),
		sun_irr = sun_irradiance,
		ambient = ambient,
	}


# =============================================================================
# Render thread
# =============================================================================

func _rt_init() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	_march_shader = WaterRD.load_compute_shader(_rd, MARCH_SHADER)
	_composite_shader = WaterRD.load_compute_shader(_rd, COMPOSITE_SHADER)
	if not (_march_shader.is_valid() and _composite_shader.is_valid()):
		return
	_march_pipeline = _rd.compute_pipeline_create(_march_shader)
	_composite_pipeline = _rd.compute_pipeline_create(_composite_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = _rd.sampler_create(ss)
	_ubo = _rd.uniform_buffer_create(UBO_SIZE)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_OPAQUE or _rd == null:
		return
	if not (_march_pipeline.is_valid() and _composite_pipeline.is_valid()):
		return
	var f := _frame
	if f.is_empty():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var full := buffers.get_internal_size()
	if full.x == 0 or full.y == 0:
		return
	var low := Vector2i(maxi(1, ceili(full.x / float(_downsample))), maxi(1, ceili(full.y / float(_downsample))))

	var RD := RenderingDevice
	var usage := RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_SAMPLING_BIT
	if buffers.has_texture(CONTEXT, TEX_INSCATTER):
		var tf := _rd.texture_get_format(buffers.get_texture(CONTEXT, TEX_INSCATTER))
		if tf.width != low.x or tf.height != low.y:
			buffers.clear_context(CONTEXT)
	if not buffers.has_texture(CONTEXT, TEX_INSCATTER):
		buffers.create_texture(CONTEXT, TEX_INSCATTER, RD.DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
				RD.TEXTURE_SAMPLES_1, low, 1, 1, true, false)
		buffers.create_texture(CONTEXT, TEX_TRANS, RD.DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
				RD.TEXTURE_SAMPLES_1, low, 1, 1, true, false)
	var inscatter := buffers.get_texture(CONTEXT, TEX_INSCATTER)
	var trans := buffers.get_texture(CONTEXT, TEX_TRANS)

	var cam_to_world := scene_data.get_cam_transform()
	var view_to_tank: Transform3D = f.world_to_tank * cam_to_world

	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		var proj := scene_data.get_view_projection(view)
		# Match the projection the depth buffer was rendered with (Vulkan: z in [0,1], reversed).
		var inv_proj := (Projection.create_depth_correction(true) * proj).inverse()
		_rd.buffer_update(_ubo, 0, UBO_SIZE, _pack_ubo(f, inv_proj, Projection(view_to_tank), low, full))

		var march_set := UniformSetCacheRD.get_cache(_march_shader, 0, [
			_sampler_uniform(0, depth),
			WaterRD.image_uniform(1, inscatter),
			WaterRD.image_uniform(2, trans),
			_ubo_uniform(3),
		])
		var comp_set := UniformSetCacheRD.get_cache(_composite_shader, 0, [
			WaterRD.image_uniform(0, color),
			_sampler_uniform(1, depth),
			WaterRD.image_uniform(2, inscatter),
			WaterRD.image_uniform(3, trans),
		])
		# Only the depth rows of inv_proj are needed for linearising depth.
		var pc := WaterRD.push_constant(PackedInt32Array([full.x, full.y, low.x, low.y]),
				PackedFloat32Array([inv_proj.z.z, inv_proj.w.z, inv_proj.z.w, inv_proj.w.w,
						depth_sharpness, 0.0, 0.0, 0.0]))

		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _march_pipeline)
		_rd.compute_list_bind_uniform_set(cl, march_set, 0)
		_rd.compute_list_dispatch(cl, WaterRD.group_count(low.x, 8), WaterRD.group_count(low.y, 8), 1)
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_bind_compute_pipeline(cl, _composite_pipeline)
		_rd.compute_list_bind_uniform_set(cl, comp_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, WaterRD.group_count(full.x, 8), WaterRD.group_count(full.y, 8), 1)
		_rd.compute_list_end()


func _pack_ubo(f: Dictionary, inv_proj: Projection, view_to_tank: Projection, low: Vector2i, full: Vector2i) -> PackedByteArray:
	var fl := PackedFloat32Array()
	for m: Projection in [inv_proj, view_to_tank]:
		for c in 4:
			var col: Vector4 = m[c]
			fl.append_array([col.x, col.y, col.z, col.w])
	var tm: Vector3 = f.tank_max
	var sa: Vector3 = f.sigma_a
	var ss: Vector3 = f.sigma_s
	var sd: Vector3 = f.sun_dir_tank
	var si: Color = f.sun_irr
	var am: Color = f.ambient
	fl.append_array([tm.x, tm.y, tm.z, 0.0])
	fl.append_array([sa.x, sa.y, sa.z, f.g])
	fl.append_array([ss.x, ss.y, ss.z, f.ior])
	fl.append_array([sd.x, sd.y, sd.z, scatter_strength])
	# Frame index stays 0 until the P4 temporal pass: per-frame jitter without TAA just shimmers.
	fl.append_array([si.r, si.g, si.b, 0.0])
	fl.append_array([am.r, am.g, am.b, float(_steps)])
	var bytes := fl.to_byte_array()
	var ints := PackedInt32Array([low.x, low.y, full.x, full.y]).to_byte_array()
	bytes.append_array(ints)
	return bytes


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(texture)
	return u


func _ubo_uniform(binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(_ubo)
	return u
