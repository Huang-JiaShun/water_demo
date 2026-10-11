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
const CAUSTIC_TEX := &"water_caustic_tex"       # sampler2D  RGBA32F gain vs calm water, per rest-surface entry point
const LIGHT_DEPTH_TEX := &"water_light_depth_tex" # sampler2D R32F distance along the refracted sun ray to the first solid
const LIGHT_DIR := &"water_light_dir"           # vec4       xyz = tank-space refracted dir toward the sun, w = 1 if lit (either light type)
const CAUSTIC_PARAMS := &"water_caustic_params" # vec4       x = strength, y = dispersion (IOR spread), z = 1 if true RGB, w = diffuse fill
const CAUSTIC_BLUR := &"water_caustic_blur"     # vec4       sun: x = tan of in-water half-angle; local: x/y = bar half length/width, zw = bar axis
const LIGHT_POS := &"water_light_pos"           # vec4       xyz = tank-space key light position, w = 1 if the key light is local
const LIGHT_LEDS := &"water_light_leds"         # int        LEDs sampled along the bar (local key light)

## Static-ish data: textures, dimensions, optics. Call when any of them change.
## The parameters must already be declared in project.godot [shader_globals].
## They are not registered at runtime: global_shader_parameter_get_list() is
## editor-only, and a shader referencing an undeclared global fails to compile anyway.
static func publish(body: WaterBody) -> void:
	if body.sim:
		RenderingServer.global_shader_parameter_set(WAVE_TEX, body.sim.output_texture)
	if body.caustics:
		RenderingServer.global_shader_parameter_set(CAUSTIC_TEX, body.caustics.caustic_texture)
		RenderingServer.global_shader_parameter_set(LIGHT_DEPTH_TEX, body.caustics.light_depth_texture)
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
	var c := body.caustics
	if c:
		var d := c.light_dir
		RenderingServer.global_shader_parameter_set(LIGHT_DIR, Vector4(d.x, d.y, d.z, 1.0 if c.lit else 0.0))
		var p := c.light_pos
		RenderingServer.global_shader_parameter_set(LIGHT_POS, Vector4(p.x, p.y, p.z, 1.0 if c.light_local else 0.0))
	var disp := body.optics.dispersion if body.optics else 0.0
	var rgb := 1.0 if c and c.is_true_rgb() else 0.0
	RenderingServer.global_shader_parameter_set(CAUSTIC_PARAMS, Vector4(body.caustic_strength, disp, rgb, body.caustic_fill()))
	RenderingServer.global_shader_parameter_set(CAUSTIC_BLUR, body.caustic_blur())
	RenderingServer.global_shader_parameter_set(LIGHT_LEDS, body.tank_light_leds)
