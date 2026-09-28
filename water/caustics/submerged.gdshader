shader_type spatial;
// Material for anything under the water (sand, rock, decor). Sunlight is
// modulated by the photon-splat caustics from WaterCaustics
// (underwater.gdshaderinc). Godot's own shadow map still provides shadowing via
// ATTENUATION. Attenuation along the downward path is applied by the volume pass.
#include "res://water/shared/water_common.gdshaderinc"
#include "res://water/shared/underwater.gdshaderinc"

uniform vec3 albedo : source_color = vec3(0.76, 0.68, 0.52);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = roughness_val;
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	vec3 k = vec3(1.0);
	if (LIGHT_IS_DIRECTIONAL) {
		k = water_caustics(v_world);
	}
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * k / PI;
}
