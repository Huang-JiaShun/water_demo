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
const HEIGHT_SCALE := &"water_height_scale"     # float      visual multiplier on wave height/slopes
const VIEW_TINT := &"water_view_tint"           # vec4       rgb = view colour, a = density multiplier
const VIEW_EXTINCTION := &"water_view_extinction" # vec3     view-tint extinction (1/m), before density
const VIEW_MAX_PATH := &"water_view_max_path"   # float      longest path (m) the view tint integrates
const CAUSTIC_TEX := &"water_caustic_tex"       # sampler2D  RGBA32F gain vs calm water, per rest-surface entry point
const LIGHT_DEPTH_TEX := &"water_light_depth_tex" # sampler2D R32F distance along the refracted sun ray to the first solid
const CAUSTIC_PARAMS := &"water_caustic_params" # vec4       x = strength, y = dispersion (IOR spread), z = 1 if true RGB, w = diffuse fill
const LIGHT_COUNT := &"water_light_count"       # int        key lights in use (<= WaterCaustics.MAX_LIGHTS)
const LIGHTS := &"water_lights"                 # mat4       column i: sun: refracted tank dir toward it, w = 0; local: tank pos, w = 1
const LIGHT_SHAPES := &"water_light_shapes"     # mat4       column i: sun: x = tan of in-water half-angle; local: x/y = bar half length/width, zw = bar axis
const LIGHT_LEDS := &"water_light_leds"         # vec4       per light: LEDs sampled along the bar

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
	RenderingServer.global_shader_parameter_set(HEIGHT_SCALE, body.wave_height_scale)
	var o := body.optics
	if o:
		RenderingServer.global_shader_parameter_set(SIGMA_A, o.absorption)
		RenderingServer.global_shader_parameter_set(SIGMA_S, o.scattering)
		RenderingServer.global_shader_parameter_set(PHASE_G, o.phase_g)
		RenderingServer.global_shader_parameter_set(IOR, o.ior)
		var c := o.view_color
		RenderingServer.global_shader_parameter_set(VIEW_TINT, Vector4(c.r, c.g, c.b, o.view_density))
		RenderingServer.global_shader_parameter_set(VIEW_EXTINCTION, o.view_extinction)
		RenderingServer.global_shader_parameter_set(VIEW_MAX_PATH, o.view_max_path)
	publish_transform(body)


## Per-frame: the tank may move (e.g. demo rotation).
static func publish_transform(body: WaterBody) -> void:
	RenderingServer.global_shader_parameter_set(
			WORLD_TO_TANK, Projection(body.global_transform.affine_inverse()))
	var c := body.caustics
	var lights := Projection(Vector4(0, 1, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 1, 0, 0))
	var shapes := Projection(Vector4(0, 0, 1, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 1, 0))
	var leds := Vector4.ONE
	var count := 0
	if c:
		count = c.light_count()
		var info := body.key_light_info()
		for i in count:
			lights[i] = c.light_keys[i]
			shapes[i] = info[i].shape
			leds[i] = info[i].leds
	RenderingServer.global_shader_parameter_set(LIGHT_COUNT, count)
	RenderingServer.global_shader_parameter_set(LIGHTS, lights)
	RenderingServer.global_shader_parameter_set(LIGHT_SHAPES, shapes)
	RenderingServer.global_shader_parameter_set(LIGHT_LEDS, leds)
	var disp := body.optics.dispersion if body.optics else 0.0
	var rgb := 1.0 if c and c.is_true_rgb() else 0.0
	RenderingServer.global_shader_parameter_set(CAUSTIC_PARAMS, Vector4(body.caustic_strength if body.caustics_enabled else 0.0, disp, rgb, body.caustic_fill()))
