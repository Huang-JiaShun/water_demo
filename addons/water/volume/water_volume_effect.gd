@tool
class_name WaterVolumeEffect
extends CompositorEffect
## Water volume pass (docs/water_architecture.md §6.3). POST_OPAQUE:
##   1. volume_march.glsl at 1/downsample resolution: tank-AABB-clipped
##      single-scatter march -> (inscatter, transmittance)
##   2. volume_temporal.glsl (optional): reproject the previous result through
##      tank space, reject on depth mismatch, neighbourhood clamp, blend
##   3. volume_denoise.glsl (optional): depth-aware à-trous at low resolution
##   4. volume_composite.glsl at full resolution: depth-guided bilateral
##      upsample, color = scene * T + inscatter
## Because this runs before transparents, the water surface refracts an
## already-fogged underwater image (§3), so the surface owns no absorption.
##
## Main thread: WaterBody calls set_frame_data() every frame.
## Render thread: _render_callback() only.
##
## The caustic light's (light 0) in-scatter is modulated by the caustic gain and
## light-depth visibility (caustic-patterned god rays). Temporal runs for single-view rendering only.

const MARCH_SHADER := "res://addons/water/volume/volume_march.glsl"
const COMPOSITE_SHADER := "res://addons/water/volume/volume_composite.glsl"
const TEMPORAL_SHADER := "res://addons/water/volume/volume_temporal.glsl"
const DENOISE_SHADER := "res://addons/water/volume/volume_denoise.glsl"
const CONTEXT := &"water_volume"
const TEX_INSCATTER := &"inscatter"
const TEX_TRANS := &"transmittance"
const TEX_HIST_INS: Array[StringName] = [&"hist_ins_0", &"hist_ins_1"]
const TEX_HIST_TRANS: Array[StringName] = [&"hist_trans_0", &"hist_trans_1"]
const TEX_TMP_INS := &"tmp_ins"
const TEX_TMP_TRANS := &"tmp_trans"
const MAX_LIGHTS := 4
const UBO_SIZE := 2 * 64 + 5 * 16 + 3 * MAX_LIGHTS * 16 + 16
const TEMPORAL_UBO_SIZE := 4 * 64 + 16 + 16

## Multiplier on in-scattered light (1 = physical).
@export var scatter_strength := 1.0
## Visual density: scales sigma_a/sigma_s so a tank-sized body reads as coloured
## water (physical ocean coefficients barely tint a <1 m path). 1 = physical.
@export_range(0.0, 50.0, 0.1) var density_scale := 8.0
## How strongly the upsample rejects low-res samples at a different depth.
@export var depth_sharpness := 40.0
## Weight of the current frame for a static view (lower = smoother, more lag).
@export_range(0.02, 1.0, 0.01) var temporal_blend := 0.1
## Weight used once reprojection moves 4+ low-res pixels per frame.
@export_range(0.02, 1.0, 0.01) var temporal_blend_moving := 0.5

# Written on the main thread, read on the render thread. Each is replaced
# wholesale (never mutated in place), so the render thread sees a consistent copy.
var _frame := {}
var _downsample := 2
var _steps := 16
var _temporal := true
var _denoise := 0
var _caustic_rid := RID()
var _light_depth_rid := RID()
var _god_rays := false

var _rd: RenderingDevice
var _march_shader := RID()
var _composite_shader := RID()
var _temporal_shader := RID()
var _denoise_shader := RID()
var _march_pipeline := RID()
var _composite_pipeline := RID()
var _temporal_pipeline := RID()
var _denoise_pipeline := RID()
var _sampler := RID()
var _linear_sampler := RID()
var _ubo := RID()
var _temporal_ubo := RID()
var _fallback := RID()     # 1x1 R32F = 1 (caustic gain of calm water)
var _fallback_far := RID() # 1x1 R32F = 1e3 (nothing blocks the light)

# Render-thread temporal state.
var _frame_index := 0
# Temporal state per viewport (keyed by RenderSceneBuffersRD instance id): the
# history textures live on each viewport's buffers, so the ping-pong index and
# previous-frame matrices must too, or two viewports sharing this effect would
# read each other's history.
class _HistState:
	var cur := 0
	var prev_tank_to_view := Projection.IDENTITY
	var prev_proj := Projection.IDENTITY
	var has_prev := false
	var last_frame := -10

var _hist_states := {}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	# Weak ref: the effect may be freed before the queued init runs.
	RenderingServer.call_on_render_thread(_rt_init_weak.bind(weakref(self)))


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# `self` is being destroyed, so any deferred work must not reference it.
	var rids: Array[RID] = [_ubo, _temporal_ubo, _fallback, _fallback_far, _sampler, _linear_sampler,
			_march_shader, _composite_shader, _temporal_shader, _denoise_shader]
	if _on_render_thread():
		WaterRD.free_rids(_rd, rids)
	else:
		RenderingServer.call_on_render_thread(WaterRD.free_rids.bind(_rd, rids))


## True when RD calls made from here are already serialized with rendering:
## either we are on the render thread, or rendering runs on the main thread
## (the default thread model), where render-thread calls are only flushed per
## frame and would never run during shutdown.
static func _on_render_thread() -> bool:
	const THREAD_MODEL_SEPARATE := 2
	var separate: bool = ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1) == THREAD_MODEL_SEPARATE
	return not separate and OS.get_thread_caller_id() == OS.get_main_thread_id()


static func _rt_init_weak(ref: WeakRef) -> void:
	var effect := ref.get_ref() as WaterVolumeEffect
	if effect:
		effect._rt_init()


func set_quality(downsample: int, steps: int, temporal := true, denoise := 0) -> void:
	_downsample = clampi(downsample, 1, 8)
	_steps = maxi(steps, 1)
	_temporal = temporal
	_denoise = clampi(denoise, 0, 3)


## world_to_tank: tank inverse transform. surface_height, tank_size: tank units.
## lights: key lights, caustic light first (at most MAX_LIGHTS), each
##   {local = false, dir = Vector3 (tank space, toward the sun), color = Color} or
##   {local = true, pos = Vector3 (tank space), color, range = m, decay = exponent}.
## color is linear colour * energy. ambient: linear.
func set_frame_data(world_to_tank: Transform3D, tank_size: Vector3, surface_height: float,
		optics: WaterOptics, lights: Array, ambient: Color) -> void:
	var units := world_to_tank.basis.get_scale().x
	var lv: Array[Vector4] = []
	var cv: Array[Vector4] = []
	var av: Array[Vector4] = []
	for l: Dictionary in lights:
		if lv.size() >= MAX_LIGHTS:
			break
		var c: Color = l.color
		cv.append(Vector4(c.r, c.g, c.b, 0.0))
		if l.local:
			var p: Vector3 = l.pos
			lv.append(Vector4(p.x, p.y, p.z, 1.0))
			av.append(Vector4(1.0 / maxf(l.range, 1e-3), l.decay, units, 0.0))
		else:
			var d: Vector3 = (l.dir as Vector3).normalized()
			lv.append(Vector4(d.x, d.y, d.z, 0.0))
			av.append(Vector4.ZERO)
	_frame = {
		world_to_tank = world_to_tank,
		tank_max = Vector3(tank_size.x * 0.5, surface_height, tank_size.z * 0.5),
		sigma_a = optics.absorption,
		sigma_s = optics.scattering,
		g = optics.phase_g,
		ior = optics.ior,
		ambient = ambient,
		lights = lv,
		colors = cv,
		attens = av,
	}


## Caustic gain and light-depth textures from WaterCaustics (render-device RIDs).
## god_rays: modulate sun in-scatter by caustics and light-depth shadowing.
func set_caustics(caustic_rid: RID, light_depth_rid: RID, god_rays: bool) -> void:
	_caustic_rid = caustic_rid
	_light_depth_rid = light_depth_rid
	_god_rays = god_rays and caustic_rid.is_valid() and light_depth_rid.is_valid()


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
	# Optional passes: if either fails to compile the effect runs without it.
	_temporal_shader = WaterRD.load_compute_shader(_rd, TEMPORAL_SHADER)
	if _temporal_shader.is_valid():
		_temporal_pipeline = _rd.compute_pipeline_create(_temporal_shader)
	_denoise_shader = WaterRD.load_compute_shader(_rd, DENOISE_SHADER)
	if _denoise_shader.is_valid():
		_denoise_pipeline = _rd.compute_pipeline_create(_denoise_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = _rd.sampler_create(ss)
	var ls := RDSamplerState.new()
	ls.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ls.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ls.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ls.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_sampler = _rd.sampler_create(ls)
	var tf := WaterRD.texture_format(Vector2i.ONE, RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	_fallback = _rd.texture_create(tf, RDTextureView.new(), [PackedFloat32Array([1.0]).to_byte_array()])
	_fallback_far = _rd.texture_create(tf, RDTextureView.new(), [PackedFloat32Array([1e3]).to_byte_array()])
	_ubo = _rd.uniform_buffer_create(UBO_SIZE)
	_temporal_ubo = _rd.uniform_buffer_create(TEMPORAL_UBO_SIZE)


func _ensure_pair(buffers: RenderSceneBuffersRD, ins_name: StringName, trans_name: StringName, low: Vector2i) -> bool:
	if buffers.has_texture(CONTEXT, ins_name):
		return false
	var RD := RenderingDevice
	var usage := RD.TEXTURE_USAGE_STORAGE_BIT | RD.TEXTURE_USAGE_SAMPLING_BIT
	for n: StringName in [ins_name, trans_name]:
		buffers.create_texture(CONTEXT, n, RD.DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
				RD.TEXTURE_SAMPLES_1, low, 1, 1, true, false)
	return true


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

	var views := buffers.get_view_count()
	var temporal := _temporal and views == 1 and _temporal_pipeline.is_valid()
	var denoise := _denoise if _denoise_pipeline.is_valid() else 0

	if buffers.has_texture(CONTEXT, TEX_INSCATTER):
		var tf := _rd.texture_get_format(buffers.get_texture(CONTEXT, TEX_INSCATTER))
		if tf.width != low.x or tf.height != low.y:
			buffers.clear_context(CONTEXT)
	var reset := false
	_ensure_pair(buffers, TEX_INSCATTER, TEX_TRANS, low)
	if temporal:
		for i in 2:
			reset = _ensure_pair(buffers, TEX_HIST_INS[i], TEX_HIST_TRANS[i], low) or reset
	if denoise > 0:
		_ensure_pair(buffers, TEX_TMP_INS, TEX_TMP_TRANS, low)

	var god_rays := _god_rays and _rd.texture_is_valid(_caustic_rid) and _rd.texture_is_valid(_light_depth_rid)
	var caustic_tex := _caustic_rid if god_rays else _fallback
	var light_depth_tex := _light_depth_rid if god_rays else _fallback_far
	var inscatter := buffers.get_texture(CONTEXT, TEX_INSCATTER)
	var trans := buffers.get_texture(CONTEXT, TEX_TRANS)

	var cam_to_world := scene_data.get_cam_transform()
	var view_to_tank: Transform3D = f.world_to_tank * cam_to_world

	# History is only trusted across consecutive frames.
	var frame_now := Engine.get_frames_drawn()
	var key := buffers.get_instance_id()
	var hs: _HistState = _hist_states.get(key)
	if hs == null:
		hs = _HistState.new()
		_hist_states[key] = hs
		# Drop state for viewports that have stopped rendering.
		for k in _hist_states.keys():
			if frame_now - (_hist_states[k] as _HistState).last_frame > 120 and k != key:
				_hist_states.erase(k)
	if not temporal or not hs.has_prev or frame_now - hs.last_frame > 2:
		reset = true
	hs.last_frame = frame_now
	_frame_index = (_frame_index + 1) % 1024 if temporal else 0
	hs.has_prev = temporal

	var gx := WaterRD.group_count(low.x, 8)
	var gy := WaterRD.group_count(low.y, 8)

	for view in views:
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		var proj := scene_data.get_view_projection(view)
		# The march needs the projection the depth buffer was rendered with (Vulkan:
		# y flipped, z in [0,1] reversed). Newer Godot already returns it corrected
		# (y.y < 0); applying the correction twice breaks depth and flips rays.
		var proj_c := proj if proj.y.y < 0.0 else Projection.create_depth_correction(true) * proj
		var inv_proj := proj_c.inverse()
		_rd.buffer_update(_ubo, 0, UBO_SIZE, _pack_ubo(f, inv_proj, Projection(view_to_tank), low, full, god_rays))
		if temporal:
			# Buffer updates are not allowed inside a compute list.
			_rd.buffer_update(_temporal_ubo, 0, TEMPORAL_UBO_SIZE, _pack_temporal_ubo(
					inv_proj, Projection(view_to_tank), hs.prev_tank_to_view, hs.prev_proj, low, reset))

		var march_set := UniformSetCacheRD.get_cache(_march_shader, 0, [
			_sampler_uniform(0, depth),
			WaterRD.image_uniform(1, inscatter),
			WaterRD.image_uniform(2, trans),
			_ubo_uniform(3, _ubo),
			_sampler_uniform(4, caustic_tex, _linear_sampler),
			_sampler_uniform(5, light_depth_tex),
		])
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _march_pipeline)
		_rd.compute_list_bind_uniform_set(cl, march_set, 0)
		_rd.compute_list_dispatch(cl, gx, gy, 1)

		# The (inscatter, transmittance) pair the composite reads.
		var res: Array[RID] = [inscatter, trans]
		if temporal:
			var nxt := 1 - hs.cur
			var hi_prev := buffers.get_texture(CONTEXT, TEX_HIST_INS[hs.cur])
			var ht_prev := buffers.get_texture(CONTEXT, TEX_HIST_TRANS[hs.cur])
			res = [buffers.get_texture(CONTEXT, TEX_HIST_INS[nxt]), buffers.get_texture(CONTEXT, TEX_HIST_TRANS[nxt])]
			hs.prev_tank_to_view = Projection(view_to_tank.affine_inverse())
			hs.prev_proj = proj_c
			hs.cur = nxt
			var tset := UniformSetCacheRD.get_cache(_temporal_shader, 0, [
				WaterRD.image_uniform(0, inscatter),
				WaterRD.image_uniform(1, trans),
				_sampler_uniform(2, hi_prev, _linear_sampler),
				_sampler_uniform(3, ht_prev, _linear_sampler),
				WaterRD.image_uniform(4, res[0]),
				WaterRD.image_uniform(5, res[1]),
				_ubo_uniform(6, _temporal_ubo),
			])
			_rd.compute_list_add_barrier(cl)
			_rd.compute_list_bind_compute_pipeline(cl, _temporal_pipeline)
			_rd.compute_list_bind_uniform_set(cl, tset, 0)
			_rd.compute_list_dispatch(cl, gx, gy, 1)

		if denoise > 0:
			# Never write into history: ping-pong between tmp and the (already
			# consumed) march output. Without temporal, the march pair is the
			# source, so start by writing tmp.
			var tmp: Array[RID] = [buffers.get_texture(CONTEXT, TEX_TMP_INS), buffers.get_texture(CONTEXT, TEX_TMP_TRANS)]
			var march_pair: Array[RID] = [inscatter, trans]
			var src := res
			for it in denoise:
				var dst: Array[RID] = tmp if (it % 2 == 0) else march_pair
				var dset := UniformSetCacheRD.get_cache(_denoise_shader, 0, [
					WaterRD.image_uniform(0, src[0]),
					WaterRD.image_uniform(1, src[1]),
					WaterRD.image_uniform(2, dst[0]),
					WaterRD.image_uniform(3, dst[1]),
				])
				var dpc := WaterRD.push_constant(PackedInt32Array([low.x, low.y, 1 << it, 0]),
						PackedFloat32Array([depth_sharpness * 0.5, 0.0, 0.0, 0.0]))
				_rd.compute_list_add_barrier(cl)
				_rd.compute_list_bind_compute_pipeline(cl, _denoise_pipeline)
				_rd.compute_list_bind_uniform_set(cl, dset, 0)
				_rd.compute_list_set_push_constant(cl, dpc, dpc.size())
				_rd.compute_list_dispatch(cl, gx, gy, 1)
				src = dst
			res = src

		var comp_set := UniformSetCacheRD.get_cache(_composite_shader, 0, [
			WaterRD.image_uniform(0, color),
			_sampler_uniform(1, depth),
			WaterRD.image_uniform(2, res[0]),
			WaterRD.image_uniform(3, res[1]),
		])
		# Only the depth rows of inv_proj are needed for linearising depth.
		var pc := WaterRD.push_constant(PackedInt32Array([full.x, full.y, low.x, low.y]),
				PackedFloat32Array([inv_proj.z.z, inv_proj.w.z, inv_proj.z.w, inv_proj.w.w,
						depth_sharpness, 0.0, 0.0, 0.0]))
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_bind_compute_pipeline(cl, _composite_pipeline)
		_rd.compute_list_bind_uniform_set(cl, comp_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, WaterRD.group_count(full.x, 8), WaterRD.group_count(full.y, 8), 1)
		_rd.compute_list_end()


func _pack_ubo(f: Dictionary, inv_proj: Projection, view_to_tank: Projection, low: Vector2i, full: Vector2i, god_rays: bool) -> PackedByteArray:
	var fl := PackedFloat32Array()
	for m: Projection in [inv_proj, view_to_tank]:
		for c in 4:
			var col: Vector4 = m[c]
			fl.append_array([col.x, col.y, col.z, col.w])
	var tm: Vector3 = f.tank_max
	var sa: Vector3 = f.sigma_a * density_scale
	var ss: Vector3 = f.sigma_s * density_scale
	var am: Color = f.ambient
	var lv: Array[Vector4] = f.lights
	fl.append_array([tm.x, tm.y, tm.z, 1.0 if god_rays else 0.0])
	fl.append_array([sa.x, sa.y, sa.z, f.g])
	fl.append_array([ss.x, ss.y, ss.z, f.ior])
	# Frame index: 0 without the temporal pass (per-frame jitter without history just shimmers).
	fl.append_array([scatter_strength, float(_frame_index), float(_steps), float(lv.size())])
	fl.append_array([am.r, am.g, am.b, 0.0])
	for arr: Array[Vector4] in [f.lights, f.colors, f.attens]:
		for i in MAX_LIGHTS:
			var v: Vector4 = arr[i] if i < arr.size() else Vector4.ZERO
			fl.append_array([v.x, v.y, v.z, v.w])
	var bytes := fl.to_byte_array()
	var ints := PackedInt32Array([low.x, low.y, full.x, full.y]).to_byte_array()
	bytes.append_array(ints)
	return bytes


func _pack_temporal_ubo(inv_proj: Projection, view_to_tank: Projection, prev_tank_to_view: Projection,
		prev_proj: Projection, low: Vector2i, reset: bool) -> PackedByteArray:
	var fl := PackedFloat32Array()
	for m: Projection in [inv_proj, view_to_tank, prev_tank_to_view, prev_proj]:
		for c in 4:
			var col: Vector4 = m[c]
			fl.append_array([col.x, col.y, col.z, col.w])
	var bytes := fl.to_byte_array()
	bytes.append_array(PackedInt32Array([low.x, low.y, 1 if reset else 0, 0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([temporal_blend, maxf(temporal_blend_moving, temporal_blend),
			0.05, 0.0]).to_byte_array())
	return bytes


func _sampler_uniform(binding: int, texture: RID, sampler := RID()) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler if sampler.is_valid() else _sampler)
	u.add_id(texture)
	return u


func _ubo_uniform(binding: int, ubo: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(ubo)
	return u
