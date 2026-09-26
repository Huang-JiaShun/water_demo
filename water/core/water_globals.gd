@tool
class_name WaterGlobals
extends RefCounted
## Single place that knows the names of the water global shader parameters.
## Any material (decor, fish, particles, surface) can read these via
## `global uniform ...` without holding a reference to the WaterBody.
##
## Parameters are declared in project.godot [shader_globals] (see publish()).
##
## Only one WaterBody is expected to publish at a time (one tank per scene).

const WAVE_TEX := &"water_wave_tex"             # sampler2D  RGBA16F (h, dh/dx, dh/dz, water_mask)
const WORLD_TO_TANK := &"water_world_to_tank"   # mat4       world -> tank local (origin = floor centre)
const TANK_SIZE := &"water_tank_size"           # vec3       inner tank size (m)
const SURFACE_HEIGHT := &"water_surface_height" # float      rest surface height in tank space (m)
const SIGMA_A := &"water_sigma_a"               # vec3       absorption (1/m)
const SIGMA_S := &"water_sigma_s"               # vec3       scattering (1/m)
const PHASE_G := &"water_phase_g"               # float
const IOR := &"water_ior"                       # float

## Static-ish data: textures, dimensions, optics. Call when any of them change.
## The parameters must already be declared in project.godot [shader_globals].
## They are not registered at runtime: global_shader_parameter_get_list() is
## editor-only, and a shader referencing an undeclared global fails to compile anyway.
static func publish(body: WaterBody) -> void:
	if body.sim:
		RenderingServer.global_shader_parameter_set(WAVE_TEX, body.sim.output_texture)
	RenderingServer.global_shader_parameter_set(TANK_SIZE, body.tank_size)
	RenderingServer.global_shader_parameter_set(SURFACE_HEIGHT, body.water_depth)
	var o := body.optics
	if o:
		RenderingServer.global_shader_parameter_set(SIGMA_A, o.absorption)
		RenderingServer.global_shader_parameter_set(SIGMA_S, o.scattering)
		RenderingServer.global_shader_parameter_set(PHASE_G, o.phase_g)
		RenderingServer.global_shader_parameter_set(IOR, o.ior)
	publish_transform(body)


## Per-frame: the tank may move (e.g. demo rotation).
static func publish_transform(body: WaterBody) -> void:
	RenderingServer.global_shader_parameter_set(
			WORLD_TO_TANK, Projection(body.global_transform.affine_inverse()))
