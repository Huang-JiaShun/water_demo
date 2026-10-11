@tool
class_name WaveSim
extends RefCounted
## GPU wave-equation heightfield for one tank.
##
## Main thread: configure(), add_splat(), update(delta), set_obstacle_mask().
## Render thread: everything prefixed _rt_. The only result is `output_texture`
## (RGBA16F: h, dh/dx, dh/dz, mask), which never changes RID while configured.
##
## Timestep: fixed ticks at quality.sim_hz, each split into CFL-safe substeps,
## so wave speed does not depend on frame rate.

signal texture_ready

const STEP_SHADER := "res://water/sim/wave_step.glsl"
const DERIVE_SHADER := "res://water/sim/wave_derive.glsl"
const MAX_SPLATS := 64
const LOCAL_SIZE := 8
## Max Courant number per substep. The 2D stability limit is 1/sqrt(2); 0.5 leaves margin.
const CFL_LIMIT := 0.5
## Cap on ticks per frame after a hitch, to avoid a spiral of death.
const MAX_TICKS_PER_FRAME := 4

var output_texture := Texture2DRD.new()

## Phase speed (m/s). Ripples in a shallow tank: roughly 0.2-0.5.
var wave_speed := 0.4
## Velocity damping rate (1/s).
var damping := 0.6
## Pull toward rest level (1/s). Removes volume added by splats.
var restore := 0.2
## Height clamp (m).
var max_height := 0.03

var size := Vector2i.ZERO
var texel_size := Vector2.ONE  # metres per texel (tank X, tank Z)

var _tick_dt := 1.0 / 60.0
var _max_substeps := 4
var _accum := 0.0
var _pending := PackedFloat32Array()
var _warned_cfl := false
var _generation := 0

# --- render thread state ----------------------------------------------------
var _rd: RenderingDevice
var _step_shader := RID()
var _derive_shader := RID()
var _step_pipeline := RID()
var _derive_pipeline := RID()
var _state: Array[RID] = [RID(), RID()]
var _mask := RID()
var _out := RID()
var _splat_buffer := RID()
var _step_sets: Array[RID] = [RID(), RID()]   # [i]: read state[i] -> write state[1-i]
var _derive_sets: Array[RID] = [RID(), RID()] # [i]: read state[i]
var _current := 0


func configure(p_size: Vector2i, tank_size: Vector3, quality: WaterQuality) -> void:
	release()
	size = p_size
	texel_size = Vector2(tank_size.x / size.x, tank_size.z / size.y)
	_tick_dt = 1.0 / quality.sim_hz
	_max_substeps = quality.max_substeps
	_accum = 0.0
	_pending.clear()
	_warned_cfl = false
	_generation += 1
	RenderingServer.call_on_render_thread(_rt_init.bind(size, texel_size, _generation))


func release() -> void:
	if output_texture.texture_rd_rid.is_valid():
		output_texture.texture_rd_rid = RID()
	# At shutdown queued render-thread calls never flush, leaking the textures.
	if WaterVolumeEffect._on_render_thread():
		_rt_free()
	else:
		RenderingServer.call_on_render_thread(_rt_free)


## uv in [0,1]² over the tank footprint (u = +X, v = +Z). radius and strength are in metres.
## Negative strength pushes the surface down (drop, finger).
func add_splat(uv: Vector2, radius: float, strength: float) -> void:
	if _pending.size() >= MAX_SPLATS * 4 or size == Vector2i.ZERO:
		return
	_pending.append_array(PackedFloat32Array([uv.x * size.x, uv.y * size.y, radius / texel_size.x, strength]))


## mask: Image.FORMAT_R8 at `size`, 255 = water, 0 = solid.
func set_obstacle_mask(mask: Image) -> void:
	if mask.get_size() != size or mask.get_format() != Image.FORMAT_R8:
		push_error("WaveSim: obstacle mask must be FORMAT_R8 at %s" % size)
		return
	var src := mask.get_data()
	var data := PackedFloat32Array()
	data.resize(src.size())
	for i in src.size():
		data[i] = 1.0 if src[i] > 127 else 0.0
	RenderingServer.call_on_render_thread(_rt_upload_mask.bind(data.to_byte_array()))


func reset() -> void:
	RenderingServer.call_on_render_thread(_rt_clear_state)


func update(delta: float) -> void:
	if size == Vector2i.ZERO:
		return
	_accum = minf(_accum + delta, _tick_dt * MAX_TICKS_PER_FRAME)
	var ticks := int(_accum / _tick_dt)
	if ticks == 0:
		return
	_accum -= ticks * _tick_dt

	var dx := minf(texel_size.x, texel_size.y)
	var courant := wave_speed * _tick_dt / dx
	var substeps := clampi(ceili(courant / CFL_LIMIT), 1, _max_substeps)
	var courant_sub := courant / substeps
	if courant_sub > CFL_LIMIT:
		if not _warned_cfl:
			push_warning("WaveSim: wave_speed %.2f m/s needs more than %d substeps at this resolution; clamping."
					% [wave_speed, _max_substeps])
			_warned_cfl = true
		courant_sub = CFL_LIMIT
	var sub_dt := _tick_dt / substeps

	var floats := PackedFloat32Array([
		courant_sub * courant_sub,
		exp(-damping * sub_dt),
		1.0 - exp(-restore * sub_dt),
		max_height,
	])
	var splats := _pending
	_pending = PackedFloat32Array()
	RenderingServer.call_on_render_thread(_rt_simulate.bind(ticks * substeps, splats, floats))


func _publish_output(rid: RID, generation: int) -> void:
	# A newer configure() may have freed this texture before the deferred call ran.
	if generation != _generation:
		return
	output_texture.texture_rd_rid = rid
	texture_ready.emit()


# =============================================================================
# Render thread
# =============================================================================

func _rt_init(p_size: Vector2i, p_texel: Vector2, generation: int) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("WaveSim: requires the Forward+ or Mobile renderer (RenderingDevice).")
		return

	_step_shader = WaterRD.load_compute_shader(_rd, STEP_SHADER)
	_derive_shader = WaterRD.load_compute_shader(_rd, DERIVE_SHADER)
	if not (_step_shader.is_valid() and _derive_shader.is_valid()):
		return
	_step_pipeline = _rd.compute_pipeline_create(_step_shader)
	_derive_pipeline = _rd.compute_pipeline_create(_derive_shader)

	var RD := RenderingDevice
	var state_fmt := WaterRD.texture_format(p_size, RD.DATA_FORMAT_R32G32_SFLOAT,
			RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	for i in 2:
		_state[i] = _rd.texture_create(state_fmt, RDTextureView.new())

	# R32F rather than R8: R8 storage images are an optional Vulkan feature.
	var mask_fmt := WaterRD.texture_format(p_size, RD.DATA_FORMAT_R32_SFLOAT,
			RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_CAN_UPDATE_BIT)
	var all_water := PackedFloat32Array()
	all_water.resize(p_size.x * p_size.y)
	all_water.fill(1.0)
	_mask = _rd.texture_create(mask_fmt, RDTextureView.new(), [all_water.to_byte_array()])

	var out_fmt := WaterRD.texture_format(p_size, RD.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_SAMPLING_BIT | RD.TEXTURE_USAGE_CAN_COPY_TO_BIT | RD.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_out = _rd.texture_create(out_fmt, RDTextureView.new())

	_splat_buffer = _rd.storage_buffer_create(MAX_SPLATS * 16)

	for i in 2:
		_step_sets[i] = _rd.uniform_set_create([
			WaterRD.image_uniform(0, _state[i]),
			WaterRD.image_uniform(1, _state[1 - i]),
			WaterRD.image_uniform(2, _mask),
			WaterRD.storage_buffer_uniform(3, _splat_buffer),
		], _step_shader, 0)
		_derive_sets[i] = _rd.uniform_set_create([
			WaterRD.image_uniform(0, _state[i]),
			WaterRD.image_uniform(1, _mask),
			WaterRD.image_uniform(2, _out),
		], _derive_shader, 0)

	_rt_clear_state()
	_rd.texture_clear(_out, Color(0, 0, 0, 1), 0, 1, 0, 1)
	_publish_output.call_deferred(_out, generation)


func _rt_clear_state() -> void:
	if _rd == null:
		return
	_current = 0
	for tex in _state:
		if tex.is_valid():
			_rd.texture_clear(tex, Color(0, 0, 0, 0), 0, 1, 0, 1)


func _rt_upload_mask(data: PackedByteArray) -> void:
	if _rd and _mask.is_valid():
		_rd.texture_update(_mask, 0, data)


func _rt_simulate(steps: int, splats: PackedFloat32Array, floats: PackedFloat32Array) -> void:
	if _rd == null or not _step_pipeline.is_valid() or not _step_sets[0].is_valid():
		return
	@warning_ignore("integer_division")
	var splat_count := splats.size() / 4
	if splat_count > 0:
		var bytes := splats.to_byte_array()
		_rd.buffer_update(_splat_buffer, 0, bytes.size(), bytes)

	var gx := WaterRD.group_count(size.x, LOCAL_SIZE)
	var gy := WaterRD.group_count(size.y, LOCAL_SIZE)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _step_pipeline)
	for i in steps:
		# Splats are injected once per tick batch, on the first substep only.
		var pc := WaterRD.push_constant(
				PackedInt32Array([size.x, size.y, splat_count if i == 0 else 0, 0]), floats)
		_rd.compute_list_bind_uniform_set(cl, _step_sets[_current], 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_add_barrier(cl)
		_current = 1 - _current

	var dpc := WaterRD.push_constant(PackedInt32Array([size.x, size.y, 0, 0]),
			PackedFloat32Array([0.5 / texel_size.x, 0.5 / texel_size.y, 0.0, 0.0]))
	_rd.compute_list_bind_compute_pipeline(cl, _derive_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _derive_sets[_current], 0)
	_rd.compute_list_set_push_constant(cl, dpc, dpc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()


func _rt_free() -> void:
	if _rd == null:
		return
	# Uniform sets and pipelines are freed automatically with their dependencies.
	WaterRD.free_rids(_rd, [_state[0], _state[1], _mask, _out, _splat_buffer, _step_shader, _derive_shader])
	_state = [RID(), RID()]
	_step_sets = [RID(), RID()]
	_derive_sets = [RID(), RID()]
	_mask = RID()
	_out = RID()
	_splat_buffer = RID()
	_step_shader = RID()
	_derive_shader = RID()
	_step_pipeline = RID()
	_derive_pipeline = RID()
