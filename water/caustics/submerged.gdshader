shader_type spatial;
// Material for anything under the water (sand, rock, decor). Sunlight is
// modulated by the photon-splat caustics from WaterCaustics
// (underwater.gdshaderinc). Godot's own shadow map still provides shadowing via
// ATTENUATION. Attenuation along the downward path is applied by the volume pass.
#include "res://water/shared/water_common.gdshaderinc"
#include "res://water/shared/underwater.gdshaderinc"

uniform vec3 albedo : source_color = vec3(0.76, 0.68, 0.52);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;
/// Soft contact darkening where the surface meets the glass walls.
uniform float wall_ao_strength : hint_range(0.0, 1.0) = 0.35;
/// Width (m) of the contact-darkening falloff from the glass.
uniform float wall_ao_width : hint_range(0.001, 0.2) = 0.04;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// 1 away from the glass, falling smoothly toward (1 - strength) at the wall.
float wall_occlusion() {
	vec3 q = water_tank_pos(v_world);
	vec2 d = water_tank_size.xz * 0.5 - abs(q.xz);
	float dw = max(min(d.x, d.y), 0.0);
	float t = 1.0 - exp(-dw / max(wall_ao_width, 1e-4));
	return 1.0 - wall_ao_strength * (1.0 - t * t * (3.0 - 2.0 * t));
}

void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = roughness_val;
	AO = wall_occlusion();
	AO_LIGHT_AFFECT = 0.5;
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	// Caustics belong to the water's key lights only (suns and tank hood lights it
	// was told about). Other lights (room fill) stay pattern-free.
	int key = water_key_light(v_world, (INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz, LIGHT_IS_DIRECTIONAL);
	vec3 k = water_caustics(v_world, key);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * k / PI;
}
