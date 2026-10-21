@tool
class_name WaterBubbles
extends GPUParticles3D
## Rising air-bubble stream (aerator / air stone) for a WaterBody.
## Place it as a child of the WaterBody at the release point. Bubbles rise with
## buoyancy + turbulence and are culled at the rest surface; pops disturb the
## wave sim near the stream's column.

@export var body: WaterBody
## Rise speed (m/s). Millimetre-sized bubbles terminate around 0.2-0.3 m/s.
@export_range(0.02, 1.0, 0.01, "suffix:m/s") var rise_speed := 0.22:
	set(v):
		rise_speed = v
		_configure()
@export_range(0.0005, 0.01, 0.0001, "suffix:m") var bubble_radius := 0.0022:
	set(v):
		bubble_radius = v
		_configure()
## Horizontal wobble (m/s of turbulence).
@export_range(0.0, 0.2, 0.001) var wobble := 0.03:
	set(v):
		wobble = v
		_configure()
## Pop impulses per second at the surface. 0 disables.
@export_range(0.0, 60.0, 0.1) var pop_rate := 12.0
@export_range(-0.005, 0.005, 0.0001, "suffix:m") var pop_strength := -0.0004

const SHADER := preload("res://addons/water/bubbles/bubble.gdshader")

## Runtime multiplier on pop_strength (0..1); a driver can fade pops out when idle.
var pop_scale := 1.0

var _pop_timer := 0.0


func _ready() -> void:
	if body == null:
		body = get_parent() as WaterBody
	_configure()


func _configure() -> void:
	if not is_inside_tree():
		return
	var pm := process_material as ParticleProcessMaterial
	if pm == null:
		pm = ParticleProcessMaterial.new()
		process_material = pm
	pm.direction = Vector3.UP
	pm.spread = 8.0
	pm.initial_velocity_min = rise_speed * 0.6
	pm.initial_velocity_max = rise_speed * 0.9
	pm.gravity = Vector3(0, rise_speed * 0.5, 0) # buoyancy toward terminal speed
	pm.damping_min = 0.3
	pm.damping_max = 0.6
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.006
	pm.turbulence_enabled = wobble > 0.0
	pm.turbulence_noise_strength = wobble * 20.0
	pm.turbulence_noise_scale = 0.4
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.15

	var mesh := draw_pass_1 as SphereMesh
	if mesh == null:
		mesh = SphereMesh.new()
		draw_pass_1 = mesh
	mesh.radius = bubble_radius
	mesh.height = bubble_radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	if mesh.material == null:
		var m := ShaderMaterial.new()
		m.shader = SHADER
		mesh.material = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Die at the surface: travel time from the emitter to the rest level.
	if body:
		var local_y := (body.global_transform.affine_inverse() * global_position).y
		lifetime = maxf((body.water_depth - local_y) / (rise_speed * 0.9), 0.1)
		visibility_aabb = AABB(Vector3(-0.1, -0.02, -0.1), Vector3(0.2, body.water_depth - local_y + 0.04, 0.2))


func _process(delta: float) -> void:
	if body == null:
		return
	var mesh := draw_pass_1 as SphereMesh
	var m := mesh.material as ShaderMaterial if mesh else null
	var key := body.key_light()
	if m and key:
		# Directional: the light shines along its -Z. Local: toward the light position.
		var to_light := key.global_transform.basis.z.normalized() if key is DirectionalLight3D \
				else (key.global_position - global_position).normalized()
		m.set_shader_parameter(&"sun_dir_world", to_light)
		m.set_shader_parameter(&"sun_color", key.light_color.srgb_to_linear() * key.light_energy
				if key.is_visible_in_tree() else Color.BLACK)
	if Engine.is_editor_hint() or not emitting or pop_rate <= 0.0 or pop_scale <= 0.0:
		return
	_pop_timer += delta
	var interval := 1.0 / pop_rate
	while _pop_timer >= interval:
		_pop_timer -= interval
		var inv := body.global_transform.affine_inverse()
		var local := inv * global_position
		local.x += randf_range(-0.012, 0.012)
		local.z += randf_range(-0.012, 0.012)
		local.y = body.water_depth
		body.disturb(body.global_transform * local, 0.006, pop_strength * pop_scale)
