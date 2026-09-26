shader_type spatial;
// Material for anything under the water (sand, rock, decor). Sunlight is
// modulated by caustics derived from the simulated wave field.
//
// Physics: a vertical ray refracted by the surface h(x) lands at
//   x' = x + d (1 - 1/n) grad h      (d = depth below surface)
// so, by energy conservation, irradiance scales by 1/det(J) with
//   det J ~= 1 + d (1 - 1/n) laplacian(h).
// Wave crests (laplacian < 0) focus light and troughs spread it. The mean over
// the floor stays ~1, so caustics redistribute light without adding energy.
// Attenuation along the downward path is applied by the volume pass.
#include "res://water/shared/water_common.gdshaderinc"

uniform vec3 albedo : source_color = vec3(0.76, 0.68, 0.52);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;
/// Must match the surface's height_scale so the caustics agree with what you see.
uniform float height_scale = 3.0;
uniform float max_gain = 6.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = roughness_val;
}

float caustic(vec3 world_pos, vec3 to_light_world) {
	vec3 p = water_tank_pos(world_pos);
	float d = water_surface_height - p.y;
	vec3 Ls = normalize((water_world_to_tank * vec4(to_light_world, 0.0)).xyz);
	if (d <= 0.0 || Ls.y <= 0.0) return 1.0;
	vec3 Lw = -refract(-Ls, vec3(0.0, 1.0, 0.0), 1.0 / water_ior);
	vec2 entry = p.xz + Lw.xz / max(Lw.y, 0.1) * d;
	vec2 uv = entry / water_tank_size.xz + 0.5;
	vec2 ts = 1.0 / vec2(textureSize(water_wave_tex, 0));
	// Wide, smoothed stencil: slope differences over 2 texels, averaged over a
	// 3x3 neighbourhood (tent weights). Removes the per-texel noise that produced
	// sharp rims in 1/det.
	float lap = 0.0; float wsum = 0.0;
	for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
		vec2 c = uv + vec2(float(i), float(j)) * ts * 1.5;
		float w = (2.0 - abs(float(i))) * (2.0 - abs(float(j)));
		float sx1 = water_sample_wave(c + vec2(2.0 * ts.x, 0.0)).y;
		float sx0 = water_sample_wave(c - vec2(2.0 * ts.x, 0.0)).y;
		float sz1 = water_sample_wave(c + vec2(0.0, 2.0 * ts.y)).z;
		float sz0 = water_sample_wave(c - vec2(0.0, 2.0 * ts.y)).z;
		lap += w * ((sx1 - sx0) / (4.0 * ts.x * water_tank_size.x) + (sz1 - sz0) / (4.0 * ts.y * water_tank_size.z));
		wsum += w;
	}
	lap = lap / wsum * height_scale;
	float path = d / max(Lw.y, 0.1);
	float det = 1.0 + path * (1.0 - 1.0 / water_ior) * lap;
	// Smooth gain: 1/sqrt(det^2 + eps^2) avoids the singular spike at det->0,
	// then a soft saturation toward max_gain instead of a hard clamp.
	const float eps = 0.25;
	float g = inversesqrt(det * det + eps * eps) * sqrt(1.0 + eps * eps); // g(1)=1
	float k = max_gain * (1.0 - exp(-g / max_gain)) / (1.0 - exp(-1.0 / max_gain)); // k(1)=1
	// Fade to uniform light near tank edges (no wave data) and at the surface.
	vec2 edge = smoothstep(vec2(0.0), vec2(0.04), uv) * smoothstep(vec2(0.0), vec2(0.04), 1.0 - uv);
	float fade = edge.x * edge.y * smoothstep(0.0, 0.02, d);
	return mix(1.0, k, fade);
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float k = 1.0;
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 to_light_world = (INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz;
		k = caustic(v_world, to_light_world);
	}
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * k / PI;
}
