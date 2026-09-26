@tool
extends MeshInstance3D
## Feeds the volume shader with the scene's real lighting so in-scatter follows
## the sun and the ambient light instead of a fixed colour.

@export var sun: DirectionalLight3D
@export var environment: WorldEnvironment
## Water surface material also gets the same lighting (for its in-scatter term).
@export var surface: MeshInstance3D

func _process(_dt: float) -> void:
	var mat := get_active_material(0) as ShaderMaterial
	if mat == null:
		return
	var smat: ShaderMaterial = surface.get_active_material(0) as ShaderMaterial if surface else null
	if sun:
		# Light travels opposite to the light's -Z axis. Convert it to this box's local space.
		var to_light := sun.global_transform.basis.z.normalized()
		mat.set_shader_parameter("sun_dir_local", (global_transform.basis.inverse() * to_light).normalized())
		var c := sun.light_color.srgb_to_linear() * sun.light_energy
		var irr := Vector3(c.r, c.g, c.b) if sun.visible else Vector3.ZERO
		mat.set_shader_parameter("sun_irradiance", irr)
		if smat:
			smat.set_shader_parameter("sun_dir_world", to_light)
			smat.set_shader_parameter("sun_irradiance", irr)
	if environment and environment.environment:
		var e := environment.environment
		var a := e.ambient_light_color.srgb_to_linear()
		if e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY or e.ambient_light_source == Environment.AMBIENT_SOURCE_BG:
			# No cheap CPU-side sky irradiance: use a neutral daylight sky estimate.
			a = a.lerp(Color(0.45, 0.55, 0.7), e.ambient_light_sky_contribution) * e.background_energy_multiplier
		a *= e.ambient_light_energy
		mat.set_shader_parameter("ambient_radiance", Vector3(a.r, a.g, a.b))
		if smat:
			smat.set_shader_parameter("ambient_radiance", Vector3(a.r, a.g, a.b))
