// Water surface: the air/water boundary only (see docs/water_architecture.md §3, §6.4).
//
// This shader owns: Fresnel, refraction, the specular highlight, Snell's window and
// total internal reflection (TIR). Absorption and scattering belong to the volume
// CompositorEffect (water/volume/water_volume_effect.gd), which runs before this.
//
// Both sides: the exact dielectric Fresnel F is computed here (TIR-aware from
//   below) and used as a metallic F0 (ALBEDO = F, METALLIC = 1). This removes
//   diffuse and scales the sky/probe reflection by F, and the transmitted part is
//   refracted * (1 - F), so the two always sum to 1. From above this gives ~2%
//   reflection looking straight down, rising to a mirror at grazing angles; from
//   below reflection reaches 1 past the critical angle (~48.6 deg). Snell's window
//   falls out of refract() naturally.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

#include "res://water/shared/water_common.gdshaderinc"


uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

group_uniforms waves;
/// Visual multiplier on the simulated height and slopes. 1 = physical.
uniform float height_scale : hint_range(0.0, 10.0) = 3.0;

group_uniforms detail;
/// Seamless normal map for small-scale ripples. It is sampled twice, at two scales and directions.
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.12;
uniform float detail_scale_a = 2.5;  // tiles per metre
uniform float detail_scale_b = 6.0;
uniform vec2 detail_speed_a = vec2(0.020, 0.012);
uniform vec2 detail_speed_b = vec2(-0.017, 0.026);

group_uniforms shading;
uniform float roughness : hint_range(0.0, 1.0) = 0.03;

group_uniforms refraction;
/// 1 = physically sized offset. Raise it to exaggerate.
uniform float refraction_scale : hint_range(0.0, 4.0) = 1.0;
/// Caps the distance behind the surface used to size the offset (m).
uniform float max_refraction_distance : hint_range(0.01, 2.0) = 0.5;
/// Exponential ray march through the depth buffer (HPWater's high-precision mode).
/// It fixes "disjointed" refraction at object edges. Costs march_steps extra depth reads.
uniform bool high_quality_refraction = false;
uniform int march_steps : hint_range(4, 32) = 8;
uniform float march_thickness : hint_range(0.005, 0.5) = 0.05;

varying vec3 v_tank_pos;

// --- helpers ------------------------------------------------------------------

// Exact unpolarised dielectric Fresnel. eta = n_incident / n_transmitted.
// Returns 1.0 under total internal reflection.
float fresnel_dielectric(float cos_i, float eta) {
	float sin2_t = eta * eta * (1.0 - cos_i * cos_i);
	if (sin2_t >= 1.0) {
		return 1.0;
	}
	float cos_t = sqrt(1.0 - sin2_t);
	float rs = (eta * cos_i - cos_t) / (eta * cos_i + cos_t);
	float rp = (cos_i - eta * cos_t) / (cos_i + eta * cos_t);
	return 0.5 * (rs * rs + rp * rp);
}

// Linear view depth (m) of the opaque scene at a screen UV (Forward+, reversed-Z).
float scene_depth(vec2 uv, mat4 inv_proj) {
	float d = textureLod(depth_tex, uv, 0.0).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

vec2 view_to_uv(vec3 p, mat4 proj) {
	vec4 c = proj * vec4(p, 1.0);
	return c.xy / c.w * 0.5 + 0.5;
}

bool uv_inside(vec2 uv) {
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

// Interleaved gradient noise, used to jitter the march start and hide banding.
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// --- stages ---------------------------------------------------------------------

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_tank_pos = water_tank_pos(world);
	// The mesh is a child of WaterBody with no rotation, so local +Y is tank +Y.
	VERTEX.y += water_sample_wave(water_tank_uv(v_tank_pos)).x * height_scale;
}

void fragment() {
	// Normal: simulated slopes, sampled per pixel so they stay sharp, plus scrolling detail.
	vec2 slope = water_sample_wave(water_tank_uv(v_tank_pos)).yz * height_scale;
	vec2 xz = v_tank_pos.xz;
	vec2 da = texture(detail_normal, xz * detail_scale_a + TIME * detail_speed_a).xy * 2.0 - 1.0;
	vec2 db = texture(detail_normal, xz * detail_scale_b + TIME * detail_speed_b).xy * 2.0 - 1.0;
	vec3 n_tank = normalize(vec3(-slope.x, 1.0, -slope.y)
			+ vec3(da.x + db.x, 0.0, da.y + db.y) * detail_strength);

	// Tank space to view space. transpose(world_to_tank) is the correct normal matrix
	// for tank->world, even when the tank transform includes scale.
	vec3 n_world = normalize(transpose(mat3(water_world_to_tank)) * n_tank);
	vec3 n_view = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	bool below = !FRONT_FACING;
	vec3 N = below ? -n_view : n_view;         // faces the viewer
	vec3 V = normalize(-VERTEX);               // towards the camera
	float cos_i = clamp(dot(N, V), 0.0, 1.0);
	float eta = below ? water_ior : 1.0 / water_ior;
	float F = fresnel_dielectric(cos_i, eta);
	vec3 T = refract(-V, N, eta);              // zero vector under TIR

	// --- refraction -------------------------------------------------------------
	float surface_depth = -VERTEX.z;
	float thickness = max(scene_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_depth, 0.0);
	vec2 refr_uv = SCREEN_UV;

	if (F < 1.0) {
		// Fast path: follow the refracted ray for as far as the scene lies behind
		// the surface, then project that point back to the screen.
		float dist = min(thickness, max_refraction_distance) * refraction_scale;
		vec2 fast_uv = view_to_uv(VERTEX + T * dist, PROJECTION_MATRIX);
		refr_uv = uv_inside(fast_uv) ? fast_uv : SCREEN_UV;

		if (high_quality_refraction) {
			float jitter = ign(FRAGCOORD.xy + vec2(TIME * 37.0));
			float prev_t = 0.0;
			for (int i = 1; i <= march_steps; i++) {
				// Exponential spacing: dense near the surface, sparse far away.
				float s = (float(i) - 1.0 + jitter) / float(march_steps);
				float t = max_refraction_distance * (pow(8.0, s) - 1.0) / 7.0;
				vec3 p = VERTEX + T * t;
				vec2 uv = view_to_uv(p, PROJECTION_MATRIX);
				if (!uv_inside(uv)) {
					break;
				}
				float scene = scene_depth(uv, INV_PROJECTION_MATRIX);
				float ray = -p.z;
				// Thickness test: accept only if the ray is just behind the scene surface.
				if (ray > scene && ray - scene < march_thickness + (t - prev_t)) {
					refr_uv = uv;
					break;
				}
				prev_t = t;
			}
		}

		// Depth reject: never refract in something that is in front of the water
		// surface (a fish or the rock between camera and water). That is the
		// classic foreground-bleeding artifact. Instead of snapping the whole offset
		// to zero (which leaves a hard seam where the ripples suddenly stop), bisect
		// for the largest fraction of the offset that still lands behind the surface,
		// so the distortion fades out continuously towards the occluder's edge.
		if (scene_depth(refr_uv, INV_PROJECTION_MATRIX) < surface_depth) {
			vec2 offset = refr_uv - SCREEN_UV;
			float lo = 0.0;
			float hi = 1.0;
			for (int i = 0; i < 5; i++) {
				float mid = 0.5 * (lo + hi);
				if (scene_depth(SCREEN_UV + offset * mid, INV_PROJECTION_MATRIX) < surface_depth) {
					hi = mid;
				} else {
					lo = mid;
				}
			}
			refr_uv = SCREEN_UV + offset * lo;
		}
	}

	// Blur the transmitted image with roughness through the screen texture mip chain.
	// No absorption / in-scatter here: the volume CompositorEffect (POST_OPAQUE)
	// already fogged the underwater scene this refracts (§3: one owner per effect).
	vec3 refracted = textureLod(screen_tex, refr_uv, roughness * 6.0).rgb;

	// --- output ----------------------------------------------------------------
	NORMAL = N;
	ROUGHNESS = roughness;
	// Both sides: feed our exact Fresnel to Godot as a metallic F0. Godot applies
	// its own Schlick curve on top (F0 + (1-F0)(1-cos)^5), so invert that here:
	// the reflection then comes out at weight F, matching the (1 - F) that scales
	// transmission, and reflection + transmission add up to 1.
	// (Godot's dielectric path uses F0 = 0.16 * SPECULAR^2, which cannot match.)
	float p = pow(1.0 - cos_i, 5.0);
	ALBEDO = vec3(clamp((F - p) / max(1.0 - p, 1e-4), 0.0, 1.0));
	METALLIC = 1.0;
	EMISSION = refracted * (1.0 - F);
	ALPHA = 1.0;
}
