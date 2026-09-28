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

signal sim_texture_ready

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
## Run the simulation in the editor too, so the surface can be previewed.
@export var simulate_in_editor := false

@export_group("Obstacles")
## Physics layers treated as decor that can block the surface.
@export_flags_3d_physics var obstacle_mask := 1
@export var bake_obstacles_on_ready := true

@export_group("Volume")
## Key light for in-scattering. The volume pass is attached to `environment`'s Compositor.
@export var sun: DirectionalLight3D
@export var environment: WorldEnvironment:
	set(v):
		_detach_volume()
		environment = v
		if is_inside_tree():
			_attach_volume()
## Multiplier on in-scattered light (1 = physical).
@export_range(0.0, 4.0, 0.01) var scatter_strength := 1.0

@export_group("Caustics")
## Physics layers that cast caustic shadows (light-depth bake).
@export_flags_3d_physics var caustic_mask := 1
## Multiplier on the wave slopes used for caustics. Match the surface material's
## height_scale so the caustics agree with the visible waves.
@export_range(0.0, 10.0, 0.01) var caustic_height_scale := 3.0
## Blend between uniform light (0) and full caustics (1).
@export_range(0.0, 2.0, 0.01) var caustic_strength := 1.0:
	set(v):
		caustic_strength = v
		_queue_publish()

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
	caustics.upload_light_depth(
			LightDepthBaker.bake(self, caustics.size, caustics.light_dir, caustic_mask), caustics.light_dir)


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
	sim.set_obstacle_mask(ObstacleBaker.bake(self, sim.size, obstacle_mask))


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
		volume.set_quality(quality.volume_downsample, quality.volume_steps)
	_do_publish()


# --- Volume pass ---------------------------------------------------------------

func _attach_volume() -> void:
	if environment == null:
		return
	if volume == null:
		volume = WaterVolumeEffect.new()
	if quality:
		volume.set_quality(quality.volume_downsample, quality.volume_steps)
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


func _sun_dir_tank() -> Vector3:
	if sun == null or not sun.is_visible_in_tree():
		return Vector3.DOWN
	return (global_transform.affine_inverse().basis * sun.global_transform.basis.z).normalized()


func _update_caustics() -> void:
	if caustics == null or optics == null or sim == null:
		return
	var moved := caustics.set_light(_sun_dir_tank(), optics.ior)
	if moved and _physics_ready:
		bake_light_depth()
	caustics.update(sim.output_texture.texture_rd_rid, tank_size, water_depth, optics.ior, caustic_height_scale)


func _update_volume() -> void:
	if volume == null or optics == null:
		return
	volume.scatter_strength = scatter_strength
	var to_light := Vector3.UP
	var irr := Color.BLACK
	if sun:
		# Light travels along the light's -Z axis.
		to_light = sun.global_transform.basis.z.normalized()
		if sun.is_visible_in_tree():
			irr = sun.light_color.srgb_to_linear() * sun.light_energy
	var amb := Color(0.3, 0.3, 0.3)
	if environment and environment.environment:
		var e := environment.environment
		amb = e.ambient_light_color.srgb_to_linear()
		if e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY or e.ambient_light_source == Environment.AMBIENT_SOURCE_BG:
			# No cheap CPU-side sky irradiance: use a neutral daylight sky estimate.
			amb = amb.lerp(Color(0.45, 0.55, 0.7), e.ambient_light_sky_contribution) * e.background_energy_multiplier
		amb *= e.ambient_light_energy
	volume.set_frame_data(global_transform.affine_inverse(), tank_size, water_depth,
			optics, to_light, irr, amb)
	if caustics:
		volume.set_caustics(caustics.caustic_texture.texture_rd_rid, caustics.light_depth_texture.texture_rd_rid,
				quality != null and quality.caustic_god_rays and caustics.lit)


func _do_publish() -> void:
	_publish_queued = false
	WaterGlobals.publish(self)


func _on_sim_texture_ready() -> void:
	WaterGlobals.publish(self)
	sim_texture_ready.emit()
