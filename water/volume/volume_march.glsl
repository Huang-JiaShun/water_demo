#[compute]
#version 450
// Volume march (docs/water_architecture.md §6.3), run at reduced resolution.
//
// Per low-res pixel: rebuild the camera ray from the full-res depth buffer, move
// it into tank space, clip it to the water AABB (floor -> rest surface) and to
// the opaque scene, then integrate single scattering with exponential steps.
//
// Outputs:
//   inscatter_out = (in-scattered radiance rgb, linear view depth of the sample)
//   trans_out     = (transmittance rgb, 1)
// The composite pass does color = scene * T + inscatter.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D inscatter_out;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D trans_out;

layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_proj;      // NDC (Vulkan, reversed-Z) -> view
	mat4 view_to_tank;  // view -> tank local (origin = floor centre)
	vec4 tank_max;      // xyz = (half size x, rest surface height, half size z)
	vec4 sigma_a;       // xyz, w = phase g
	vec4 sigma_s;       // xyz, w = ior
	vec4 sun_dir;       // xyz = toward the sun in tank space (unit), w = scatter strength
	vec4 sun_irr;       // rgb above-water irradiance, w = frame index (jitter)
	vec4 ambient;       // rgb above-water ambient radiance, w = step count
	ivec4 sizes;        // xy = low-res size, zw = full-res size
} u;

const float PI = 3.14159265359;

float hg_phase(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

float rayleigh_phase(float c) {
	return 3.0 / (16.0 * PI) * (1.0 + c * c);
}

float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 lo = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(lo, u.sizes.xy))) {
		return;
	}
	ivec2 full_size = u.sizes.zw;
	vec2 uv = (vec2(lo) + 0.5) / vec2(u.sizes.xy);
	ivec2 full_px = min(ivec2(uv * vec2(full_size)), full_size - 1);
	uv = (vec2(full_px) + 0.5) / vec2(full_size);
	float depth = texelFetch(depth_tex, full_px, 0).r;

	// View-space ray. Reversed-Z: depth 0 = far plane / sky.
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 far_v = u.inv_proj * vec4(ndc, 1e-6, 1.0);
	vec3 dir_view = normalize(far_v.xyz / far_v.w);
	float t_scene = 1e6;
	float lin_depth = 1e4;
	if (depth > 0.0) {
		vec4 v = u.inv_proj * vec4(ndc, depth, 1.0);
		vec3 p = v.xyz / v.w;
		t_scene = length(p);
		lin_depth = -p.z;
	}

	// Into tank space. `scale` handles a scaled tank so distances stay in tank units.
	vec3 ro = (u.view_to_tank * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 rd_raw = mat3(u.view_to_tank) * dir_view;
	float scale = length(rd_raw);
	vec3 rd = rd_raw / scale;
	t_scene *= scale;

	vec3 bmin = vec3(-u.tank_max.x, 0.0, -u.tank_max.z);
	vec3 bmax = u.tank_max.xyz;
	vec3 inv = 1.0 / rd;
	vec3 ta = (bmin - ro) * inv;
	vec3 tb = (bmax - ro) * inv;
	vec3 tmin3 = min(ta, tb);
	vec3 tmax3 = max(ta, tb);
	float t0 = max(max(max(tmin3.x, tmin3.y), tmin3.z), 0.0);
	float t_exit = min(min(tmax3.x, tmax3.y), tmax3.z);
	float t1 = min(t_exit, t_scene);

	vec3 sig_a = u.sigma_a.xyz;
	vec3 sig_s = u.sigma_s.xyz;
	vec3 sig_t = sig_a + sig_s;
	vec3 T = vec3(1.0);
	vec3 L = vec3(0.0);

	if (t1 > t0) {
		float g = u.sigma_a.w;
		float ior = u.sigma_s.w;
		// Sun refracted into the water through the flat rest surface.
		vec3 Ls = u.sun_dir.xyz;
		float cos_air = max(Ls.y, 0.0);
		float eta = 1.0 / ior;
		float cos_w = sqrt(max(1.0 - eta * eta * (1.0 - cos_air * cos_air), 0.0));
		vec3 Lw = normalize(vec3(Ls.x * eta, cos_w, Ls.z * eta));
		float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
		float Ft = 1.0 - (f0 + (1.0 - f0) * pow(1.0 - cos_air, 5.0));
		vec3 sun_in = u.sun_irr.rgb * Ft;
		float inv_cos_w = 1.0 / max(cos_w, 0.05);

		// Phase: HG (Mie) + a little Rayleigh, blended toward isotropic by the
		// single-scatter albedo as a cheap multiple-scattering approximation.
		float c = dot(rd, Lw);
		float ph = 0.95 * hg_phase(c, g) + 0.05 * rayleigh_phase(c);
		vec3 albedo = sig_s / max(sig_t, vec3(1e-5));
		float a_lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		ph = mix(ph, 1.0 / (4.0 * PI), clamp(a_lum, 0.0, 1.0));

		int steps = max(int(u.ambient.w), 1);
		float seg = t1 - t0;
		// Stable per pixel dither (no per-frame jitter until the temporal pass exists).
		float jitter = ign(vec2(lo) + u.sun_irr.w * 5.588238);
		const float K = 2.0; // exponential spacing: denser near the camera
		float norm = 1.0 / (exp(K) - 1.0);
		float prev = 0.0;
		for (int i = 1; i <= steps; i++) {
			float s = float(i) / float(steps);
			float t_rel = (exp(K * s) - 1.0) * norm;
			float ds = (t_rel - prev) * seg;
			float t = t0 + mix(prev, t_rel, jitter) * seg;
			prev = t_rel;

			vec3 x = ro + rd * t;
			float d = clamp(u.tank_max.y - x.y, 0.0, u.tank_max.y);
			vec3 sun = sun_in * exp(-sig_t * d * inv_cos_w);
			vec3 amb = u.ambient.rgb * exp(-sig_t * d);
			vec3 S = sig_s * (sun * ph + amb) * u.sun_dir.w;

			// Analytic integral over the segment (energy-conserving for any ds).
			vec3 Tseg = exp(-sig_t * ds);
			L += T * S * (1.0 - Tseg) / max(sig_t, vec3(1e-5));
			T *= Tseg;
		}

		// A submerged hit was also lit through the water from above: attenuate
		// its radiance by the depth below the surface (vertical approximation).
		if (t_scene < t_exit) {
			vec3 hit = ro + rd * t_scene;
			float d = clamp(u.tank_max.y - hit.y, 0.0, u.tank_max.y);
			T *= exp(-sig_t * d);
		}
	}

	imageStore(inscatter_out, lo, vec4(L, min(lin_depth, 6e4)));
	imageStore(trans_out, lo, vec4(T, 1.0));
}
