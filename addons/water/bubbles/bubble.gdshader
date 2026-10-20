// Air bubble in water (transparent). The volume pass cannot see transparents,
// so fogging is done analytically with water_fog() (docs/water_architecture.md §3).
//
// A bubble is an air sphere seen from water: nearly clear at the centre and
// bright at the rim, where TIR at the water->air boundary reflects the
// surroundings. Shaded unlit with a cheap sun glint so it composes cleanly
// with the analytic fog.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, unshaded, shadows_disabled;

#include "res://addons/water/shared/water_common.gdshaderinc"
#include "res://addons/water/shared/underwater.gdshaderinc"

uniform vec3 rim_color : source_color = vec3(0.85, 0.93, 1.0);
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;
uniform float centre_alpha : hint_range(0.0, 1.0) = 0.06;
/// World-space direction toward the key light (set by WaterBubbles each frame).
uniform vec3 sun_dir_world = vec3(0.3, 0.8, 0.4);
uniform vec3 sun_color : source_color = vec3(1.0);
uniform float glint : hint_range(0.0, 20.0) = 6.0;
/// Linear ambient radiance used for the fog in-scatter.
uniform vec3 ambient = vec3(0.25, 0.32, 0.4);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float c = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - c, rim_power);
	// Reflection of the sun off the outside of the bubble.
	vec3 L = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
	vec3 H = normalize(L + VIEW);
	float spec = pow(max(dot(NORMAL, H), 0.0), 80.0) * glint;
	vec3 col = rim_color * rim + sun_color * spec;
	float a = clamp(centre_alpha + rim + spec, 0.0, 1.0);

	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	// Fog the premultiplied contribution, then un-premultiply for blend_mix.
	vec3 fogged = water_fog(col * a, v_world, cam, ambient * a);
	ALBEDO = fogged / max(a, 1e-3);
	ALPHA = a;
}
