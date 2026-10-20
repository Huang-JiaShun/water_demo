// PHASE 0 PLACEHOLDER: only here to visualise the simulation.
// Phase 1 replaces it with the full interface shader (Fresnel, refraction,
// Snell's window / total internal reflection).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_schlick_ggx;

#include "res://addons/water/shared/water_common.gdshaderinc"

uniform vec3 tint : source_color = vec3(0.02, 0.08, 0.1);
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float opacity : hint_range(0.0, 1.0) = 0.6;
uniform float height_scale = 1.0;

varying vec3 tank_normal;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = water_tank_uv(water_tank_pos(world));
	vec4 w = water_sample_wave(uv);
	VERTEX.y += w.x * height_scale;
	tank_normal = water_wave_normal(w.yz * height_scale);
}

void fragment() {
	// Mesh local space equals tank space (child of WaterBody, no extra rotation), so
	// tank space -> view space is VIEW_MATRIX * MODEL_MATRIX.
	vec3 n = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(tank_normal, 0.0)).xyz);
	NORMAL = FRONT_FACING ? n : -n;
	ALBEDO = tint;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ALPHA = opacity;
}
