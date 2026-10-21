@tool
class_name WaterBody
extends Node3D
## Root of one aquarium tank's water. Owns every water subsystem and publishes
## shared data as global shader params (see WaterGlobals).
##
## Local space: origin at the centre of the tank floor, +Y up. The inner volume
## is tank_size, and the water fills it to water_depth.
##
## Owns the wave simulation, caustics (P3) and the volume CompositorEffect (P2).
## set_tier() swaps the quality preset at runtime (P4).

signal sim_texture_ready

const SURFACE_SHADER := preload("../surface/water_surface.gdshader")

@export var tank_size := Vector3(1.2, 0.5, 0.45):
	set(v):
		tank_size = v.max(Vector3(0.05, 0.05, 0.05))
		water_depth = minf(water_depth, tank_size.y)
		_queue_rebuild()

@export var water_depth := 0.42:
	set(v):
		water_depth = clampf(v, 0.01, tank_size.y)
		_queue_publish()

@export var optics: WaterOptics:
	set(v):
		if optics and optics.changed.is_connected(_queue_publish):
			optics.changed.disconnect(_queue_publish)
		optics = v
		if optics:
			optics.changed.connect(_queue_publish)
		_queue_publish()

@export var quality: WaterQuality:
	set(v):
		if quality and quality.changed.is_connected(_queue_rebuild):
			quality.changed.disconnect(_queue_rebuild)
		quality = v
		if quality:
			quality.changed.connect(_queue_rebuild)
		_queue_rebuild()

@export_group("Waves")
@export_range(0.05, 2.0, 0.01, "suffix:m/s") var wave_speed := 0.4:
	set(v):
		wave_speed = v
		if sim: sim.wave_speed = v
@export_range(0.0, 10.0, 0.01, "suffix:1/s") var wave_damping := 0.6:
	set(v):
		wave_damping = v
		if sim: sim.damping = v
@export_range(0.0, 5.0, 0.01, "suffix:1/s") var wave_restore := 0.2:
	set(v):
		wave_restore = v
		if sim: sim.restore = v
## Visual multiplier on the simulated height and slopes (1 = physical). Shared by
## the surface, glass waterline and caustics so they all see the same waves.
@export_range(0.0, 10.0, 0.01) var wave_height_scale := 3.0:
	set(v):
		wave_height_scale = v
		_queue_publish()
## Surface mesh using water_surface.gdshader. Tier switching toggles its
## high-precision refraction. Empty: the first child using that shader.
@export var surface: GeometryInstance3D
## Run the simulation in the editor too, so the surface can be previewed.
@export var simulate_in_editor := false

@export_group("Obstacles")
## Physics layers treated as decor that can block the surface.
@export_flags_3d_physics var obstacle_mask := 1
@export var bake_obstacles_on_ready := true

@export_group("Lighting")
## The tank's own lights: OmniLight3D / SpotLight3D a few cm above the water
## (hood LED bars, spot pendants). Each visible one above the surface is a key
## light for volume in-scatter (at most WaterVolumeEffect.MAX_LIGHTS, including
## `sun`). The caustic light is `sun` when it reaches the water, otherwise the
## brightest tank light. It is the only one with
## caustics, caustic god rays and bubble glints. Room lights not listed stay
## pattern-free fill.
## Each light is an LED bar along its local X. Per-light overrides via node
## metadata: "led_length" (m), "led_width" (m), "leds" (int); otherwise the
## defaults below. led_length 0 = a point light (single LED).
@export var tank_lights: Array[Light3D] = []:
	set(v):
		tank_lights = v
		_queue_publish()
## Default LED bar length (m), along the light's local X. Spreads the caustics into
## layered copies that separate with depth.
@export_range(0.0, 2.0, 0.001, "suffix:m") var tank_light_length := 0.9:
	set(v):
		tank_light_length = v
		_queue_publish()
## Default LED bar width (m). Softens the caustics across the bar.
@export_range(0.0, 0.3, 0.001, "suffix:m") var tank_light_width := 0.03:
	set(v):
		tank_light_width = v
		_queue_publish()
## Default LEDs sampled along the bar when shading caustics (cost: 2 taps per LED).
@export_range(1, 16, 1) var tank_light_leds := 6:
	set(v):
		tank_light_leds = v
		_queue_publish()
## Optional distant light (window sun, outdoor pond). When visible and above the
## horizon it is the caustic light; the tank lights still light the volume.
@export var sun: DirectionalLight3D

@export_group("Volume")
## The volume pass is attached to `environment`'s Compositor.
@export var environment: WorldEnvironment:
	set(v):
		_detach_volume()
		environment = v
		if is_inside_tree():
			_attach_volume()
## Multiplier on in-scattered light (1 = physical).
@export_range(0.0, 4.0, 0.01) var scatter_strength := 1.0

@export_group("Caustics")
## Enables the caustic light pattern (ripple shadows) on the floor and submerged
## objects. When off, underwater surfaces get uniform light and the caustic pass is skipped.
@export var caustics_enabled := true:
	set(v):
		caustics_enabled = v
		_queue_publish()
## Physics layers that cast caustic shadows (light-depth bake).
@export_flags_3d_physics var caustic_mask := 1
## Blend between uniform light (0) and full caustics (1).
@export_range(0.0, 2.0, 0.01) var caustic_strength := 1.0:
	set(v):
		caustic_strength = v
		_queue_publish()
## Diffuse albedo of the tank floor. Drives the pattern-free bounce light: light
## the floor scatters upward is partly reflected back down by the underside of the
## water surface (total internal reflection + Fresnel), lifting the caustic troughs.
@export_range(0.0, 1.0, 0.01) var floor_albedo := 0.4:
	set(v):
		floor_albedo = v
		_queue_publish()


## Fraction of the floor's sun irradiance that arrives as uniform bounce light.
## Floor -> surface underside -> floor is a geometric series; the bounced share
## of the total is albedo * R_int, where R_int is the diffuse internal reflectance
## of the water surface (total internal reflection outside the ~49° escape cone
## plus Fresnel inside it), Egan & Hilgeman fit: ~0.47 for water.
func caustic_fill() -> float:
	var n := optics.ior if optics else 1.333
	var r_int := -1.440 / (n * n) + 0.710 / n + 0.668 + 0.0636 * n
	return clampf(floor_albedo * r_int, 0.0, 0.95)


## Tangent of the in-water half-angle of the sun disc (refraction narrows it by ~1/n).
func sun_half_angle_tan() -> float:
	var deg := sun.light_angular_distance if sun else 0.5
	var n := optics.ior if optics else 1.333
	return tan(deg_to_rad(maxf(deg, 0.0) * 0.5) / n)


## The key lights in use this frame, caustic light first. Each entry:
## {light, local, pos (tank, local) / dir (tank, toward the sun), shape: Vector4, leds: int}.
## shape: sun x = tan of the in-water half-angle; local x/y = bar half length/width
## (tank units), zw = bar axis (tank xz). Lights that cannot reach the water are
## skipped (local below the surface, sun below the horizon).
func key_light_info() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var inv := global_transform.affine_inverse()
	var sc := global_transform.basis.get_scale().x
	for l in tank_lights:
		if out.size() >= WaterVolumeEffect.MAX_LIGHTS:
			break
		if l == null or not l.is_visible_in_tree():
			continue
		var p := inv * l.global_position
		if p.y <= water_depth + 1e-3:
			continue
		var axis := inv.basis * l.global_transform.basis.x
		var a := Vector2(axis.x, axis.z)
		a = a.normalized() if a.length_squared() > 1e-8 else Vector2(1.0, 0.0)
		var length: float = l.get_meta(&"led_length", tank_light_length)
		var width: float = l.get_meta(&"led_width", tank_light_width)
		var leds: int = l.get_meta(&"leds", tank_light_leds) if length > 0.0 else 1
		out.append({light = l, local = true, pos = p,
				shape = Vector4(length * 0.5 / sc, width * 0.5 / sc, a.x, a.y), leds = leds})
	if sun and sun.is_visible_in_tree() and out.size() < WaterVolumeEffect.MAX_LIGHTS:
		var d := (inv.basis * sun.global_transform.basis.z).normalized()
		if d.y > 1e-3:
			out.append({light = sun, local = false, dir = d,
					shape = Vector4(sun_half_angle_tan(), 0.0, 1.0, 0.0), leds = 1})
	# The caustic light goes first: the sun when it reaches the water, otherwise
	# the brightest tank light.
	var best := 0
	for i in out.size():
		if not out[i].local:
			best = i
			break
		if (out[i].light as Light3D).light_energy > (out[best].light as Light3D).light_energy:
			best = i
	if best > 0:
		out.push_front(out.pop_at(best))
	return out


## The caustic light (the sun, else the brightest tank light), or null. key_light_info()[0].
func key_light() -> Light3D:
	var info := key_light_info()
	return info[0].light if not info.is_empty() else null

var sim: WaveSim
var volume: WaterVolumeEffect
var caustics: WaterCaustics

var _rebuild_queued := false
var _publish_queued := false
var _physics_ready := false


func _ready() -> void:
	if optics == null:
		optics = WaterOptics.new()
	if quality == null:
		quality = WaterQuality.preset(WaterQuality.Tier.MEDIUM)
	_rebuild()
	_attach_volume()
	if bake_obstacles_on_ready and not Engine.is_editor_hint():
		# Wait for physics so that colliders exist in the space.
		await get_tree().physics_frame
		await get_tree().physics_frame
		_physics_ready = true
		bake_obstacles()
	elif not Engine.is_editor_hint():
		_physics_ready = true


func _enter_tree() -> void:
	# Re-entering after a remove/reparent: _exit_tree released the sim and
	# detached the volume, and _ready does not run again.
	if is_node_ready():
		_rebuild()
		_attach_volume()


func _exit_tree() -> void:
	if sim:
		sim.release()
	if caustics:
		caustics.release()
	_detach_volume()


func _process(delta: float) -> void:
	WaterGlobals.publish_transform(self)
	if sim and (simulate_in_editor or not Engine.is_editor_hint()):
		sim.update(delta)
	_update_caustics()
	_update_volume()


# --- Public API ---------------------------------------------------------------

## Replaces `quality` with the preset for `tier` and rebuilds every subsystem.
## Waves restart from rest; obstacles and light depth are re-baked.
func set_tier(tier: WaterQuality.Tier) -> void:
	quality = WaterQuality.preset(tier)
	_rebuild()


func get_tier() -> WaterQuality.Tier:
	return quality.tier if quality else WaterQuality.Tier.MEDIUM

## Sim grid size, with square texels matching the tank aspect.
func get_sim_size() -> Vector2i:
	var res := quality.sim_resolution if quality else 256
	if tank_size.x >= tank_size.z:
		return Vector2i(res, maxi(8, roundi(res * tank_size.z / tank_size.x)))
	return Vector2i(maxi(8, roundi(res * tank_size.x / tank_size.z)), res)


## Caustic grid size, with square texels matching the tank aspect.
func get_caustic_size() -> Vector2i:
	var res := quality.caustic_resolution if quality else 256
	if tank_size.x >= tank_size.z:
		return Vector2i(res, maxi(8, roundi(res * tank_size.z / tank_size.x)))
	return Vector2i(maxi(8, roundi(res * tank_size.x / tank_size.z)), res)


## Forces a light-depth re-bake (call after moving decor).
func bake_light_depth() -> void:
	if caustics == null or not caustics.lit or not is_inside_tree():
		return
	var key := caustics.light_key
	caustics.upload_light_depth(
			LightDepthBaker.bake(get_world_3d().direct_space_state, global_transform, tank_size, water_depth,
					caustics.size, key, caustic_mask, optics.ior if optics else 1.333), key)

func world_to_tank(p: Vector3) -> Vector3:
	return global_transform.affine_inverse() * p


## Tank-local XZ to sim UV. Returns (-1,-1) if outside the footprint.
func tank_to_uv(local: Vector3) -> Vector2:
	var uv := Vector2(local.x / tank_size.x + 0.5, local.z / tank_size.z + 0.5)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return Vector2(-1, -1)
	return uv


## World-space disturbance. radius in m. strength in m: positive raises the surface, negative pushes it down.
func disturb(world_pos: Vector3, radius: float, strength: float) -> void:
	if sim == null:
		return
	var uv := tank_to_uv(world_to_tank(world_pos))
	if uv.x >= 0.0:
		sim.add_splat(uv, radius, strength)


## World position of the rest surface, or null if the ray misses the tank footprint.
func intersect_surface(ray_origin: Vector3, ray_dir: Vector3) -> Variant:
	var inv := global_transform.affine_inverse()
	var o := inv * ray_origin
	var d := inv.basis * ray_dir
	if absf(d.y) < 1e-6:
		return null
	var t := (water_depth - o.y) / d.y
	if t < 0.0:
		return null
	var hit := o + d * t
	if tank_to_uv(hit).x < 0.0:
		return null
	return global_transform * hit


func bake_obstacles() -> void:
	if sim == null or not is_inside_tree():
		return
	sim.set_obstacle_mask(ObstacleBaker.bake(get_world_3d().direct_space_state, global_transform,
			tank_size, water_depth, sim.size, obstacle_mask))


# --- Internals -----------------------------------------------------------------

func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	_deferred_rebuild.call_deferred()


func _deferred_rebuild() -> void:
	# Skip if something already rebuilt synchronously (e.g. _ready) since queuing.
	if _rebuild_queued:
		_rebuild()


func _queue_publish() -> void:
	if _publish_queued or not is_inside_tree():
		return
	_publish_queued = true
	_do_publish.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	if quality == null:
		return
	if sim == null:
		sim = WaveSim.new()
		sim.texture_ready.connect(_on_sim_texture_ready)
	sim.wave_speed = wave_speed
	sim.damping = wave_damping
	sim.restore = wave_restore
	sim.configure(get_sim_size(), tank_size, quality)
	if caustics == null:
		caustics = WaterCaustics.new()
		caustics.textures_ready.connect(_on_sim_texture_ready)
	caustics.configure(get_caustic_size(), quality)
	if volume:
		_apply_volume_quality()
	_apply_surface_quality()
	# configure() reset the obstacle mask; light depth re-bakes via set_lights().
	if _physics_ready and bake_obstacles_on_ready:
		bake_obstacles()
	_do_publish()


func _apply_volume_quality() -> void:
	volume.set_quality(quality.volume_downsample, quality.volume_steps,
			quality.volume_temporal, quality.volume_denoise)


func _surface_material() -> ShaderMaterial:
	var candidates: Array[Node] = get_children()
	if surface:
		candidates = [surface]
	for n in candidates:
		var g := n as GeometryInstance3D
		if g == null:
			continue
		var m := g.material_override as ShaderMaterial
		if m == null and g is MeshInstance3D:
			m = (g as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
		if m and m.shader == SURFACE_SHADER:
			return m
	return null


func _apply_surface_quality() -> void:
	var m := _surface_material()
	if m:
		m.set_shader_parameter(&"high_quality_refraction", quality.high_quality_refraction)


# --- Volume pass ---------------------------------------------------------------

func _attach_volume() -> void:
	if environment == null:
		return
	if volume == null:
		volume = WaterVolumeEffect.new()
	if quality:
		_apply_volume_quality()
	var comp := environment.compositor
	if comp == null:
		comp = Compositor.new()
		environment.compositor = comp
	# Drop stale instances (e.g. one serialized when the scene was saved in the
	# editor) so the volume is never applied twice.
	var effects: Array[CompositorEffect] = []
	for e in comp.compositor_effects:
		if not (e is WaterVolumeEffect) or e == volume:
			effects.append(e)
	if not effects.has(volume):
		effects.append(volume)
	comp.compositor_effects = effects


func _detach_volume() -> void:
	if volume == null or environment == null or environment.compositor == null:
		return
	var comp := environment.compositor
	var effects := comp.compositor_effects
	if effects.has(volume):
		effects.erase(volume)
		comp.compositor_effects = effects


func _update_caustics() -> void:
	if not caustics_enabled or caustics == null or optics == null or sim == null:
		return
	var info := key_light_info()
	var stale := caustics.set_light(info[0] if not info.is_empty() else {}, water_depth, optics.ior)
	if stale and _physics_ready:
		bake_light_depth()
	caustics.update(sim.output_texture.texture_rd_rid, tank_size, water_depth, optics.ior, wave_height_scale,
			optics.dispersion)


func _update_volume() -> void:
	if volume == null or optics == null:
		return
	volume.scatter_strength = scatter_strength
	var lights: Array[Dictionary] = []
	for k in key_light_info():
		var l: Light3D = k.light
		var e := {local = k.local, color = l.light_color.srgb_to_linear() * l.light_energy}
		if k.local:
			e.pos = k.pos
			e.range = _light_range(l)
			e.decay = _light_decay(l)
		else:
			e.dir = k.dir
		lights.append(e)
	var amb := Color(0.3, 0.3, 0.3)
	if environment and environment.environment:
		var e := environment.environment
		amb = e.ambient_light_color.srgb_to_linear()
		if e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY or e.ambient_light_source == Environment.AMBIENT_SOURCE_BG:
			# No cheap CPU-side sky irradiance: use a neutral daylight sky estimate.
			amb = amb.lerp(Color(0.45, 0.55, 0.7), e.ambient_light_sky_contribution) * e.background_energy_multiplier
		amb *= e.ambient_light_energy
	volume.set_frame_data(global_transform.affine_inverse(), tank_size, water_depth, optics, lights, amb)
	if caustics:
		volume.set_caustics(caustics.caustic_texture.texture_rd_rid, caustics.light_depth_texture.texture_rd_rid,
				quality != null and quality.caustic_god_rays and caustics.lit and caustics_enabled)


static func _light_range(l: Light3D) -> float:
	if l is OmniLight3D:
		return (l as OmniLight3D).omni_range
	if l is SpotLight3D:
		return (l as SpotLight3D).spot_range
	return 4096.0


static func _light_decay(l: Light3D) -> float:
	if l is OmniLight3D:
		return (l as OmniLight3D).omni_attenuation
	if l is SpotLight3D:
		return (l as SpotLight3D).spot_attenuation
	return 1.0


func _do_publish() -> void:
	_publish_queued = false
	WaterGlobals.publish(self)


func _on_sim_texture_ready() -> void:
	WaterGlobals.publish(self)
	sim_texture_ready.emit()
