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
//   trans_out     = (transmittance rgb, view distance of the reprojection point)
//                   .a = 0 means the ray missed the water (nothing to reproject)
// The composite pass does color = scene * T + inscatter.

#include "../shared/water_light.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D inscatter_out;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D trans_out;

#define MAX_LIGHTS 4

layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_proj;      // NDC (Vulkan, reversed-Z) -> view
	mat4 view_to_tank;  // view -> tank local (origin = floor centre)
	vec4 tank_max;      // xyz = (half size x, rest surface height, half size z), w = 1: god rays
	vec4 sigma_a;       // xyz, w = phase g
	vec4 sigma_s;       // xyz, w = ior
	vec4 misc;          // x = scatter strength, y = frame index (jitter), z = step count, w = light count
	vec4 ambient;       // rgb above-water ambient radiance
	// Per key light (same order as the caustic layers):
	vec4 light[MAX_LIGHTS];  // sun: xyz = toward it (tank, air side, unit), w = 0. local: xyz = tank pos, w = 1
	vec4 color[MAX_LIGHTS];  // rgb = colour * energy (sun: irradiance)
	vec4 atten[MAX_LIGHTS];  // local: x = 1 / range, y = attenuation exponent, z = tank units per metre
	ivec4 sizes;        // xy = low-res size, zw = full-res size
} u;

// Godot's omni falloff (distance in metres).
float omni_attenuation(float d, float inv_range, float decay) {
	float nd = d * inv_range;
	nd *= nd;
	nd *= nd;
	nd = max(1.0 - nd, 0.0);
	return nd * nd * pow(max(d, 1e-4), -decay);
}

// Caustics (P3). Both are indexed by the rest-surface entry point of the
// refracted light ray, one layer per light stacked vertically; see
// water/caustics/caustics.gd.
layout(set = 0, binding = 4) uniform sampler2D caustic_tex;     // rgb gain, 1 = calm water
layout(set = 0, binding = 5) uniform sampler2D light_depth_tex; // distance to first solid

// Layer-local uv -> stacked uv, clamped half a texel inside the layer.
vec2 layer_uv(vec2 uv, int layer, float layer_h) {
	uv.y = clamp(uv.y, 0.5 / layer_h, 1.0 - 0.5 / layer_h);
	return vec2(uv.x, (uv.y + float(layer)) / float(MAX_LIGHTS));
}

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
		float eta = 1.0 / ior;
		float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
		int n_lights = min(int(u.misc.w), MAX_LIGHTS);
		float layer_h = float(textureSize(caustic_tex, 0).y) / float(MAX_LIGHTS);

		// Phase: HG (Mie) + a little Rayleigh, blended toward isotropic by the
		// single-scatter albedo as a cheap multiple-scattering approximation.
		vec3 albedo = sig_s / max(sig_t, vec3(1e-5));
		float a_lum = clamp(dot(albedo, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

		// Suns: one refracted direction, transmittance and phase per ray.
		vec3 sun_Lw[MAX_LIGHTS];
		vec3 sun_in[MAX_LIGHTS];
		float sun_ph[MAX_LIGHTS];
		for (int li = 0; li < n_lights; li++) {
			vec3 Ls = u.light[li].xyz;
			float cos_air = max(Ls.y, 0.0);
			float cos_w = sqrt(max(1.0 - eta * eta * (1.0 - cos_air * cos_air), 0.0));
			sun_Lw[li] = normalize(vec3(Ls.x * eta, max(cos_w, 0.05), Ls.z * eta));
			float Ft = 1.0 - (f0 + (1.0 - f0) * pow(1.0 - cos_air, 5.0));
			sun_in[li] = u.color[li].rgb * Ft;
			float c = dot(rd, sun_Lw[li]);
			sun_ph[li] = mix(0.95 * hg_phase(c, g) + 0.05 * rayleigh_phase(c), 1.0 / (4.0 * PI), a_lum);
		}

		int steps = max(int(u.misc.z), 1);
		float seg = t1 - t0;
		// Per pixel dither. With the temporal pass on, the frame index offsets it
		// every frame and the history integrates the jitter (0 when temporal is off).
		float jitter = ign(vec2(lo) + u.misc.y * 5.588238);
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
			vec3 lit = vec3(0.0); // sum over lights of radiance * phase
			for (int li = 0; li < n_lights; li++) {
				vec2 e;
				float dist;
				vec3 sun;
				float ph_x;
				if (u.light[li].w > 0.5) {
					// Hood light: per-sample entry point, direction and falloff.
					vec3 Lx;
					vec3 P = u.light[li].xyz;
					vec3 en = wl_entry_local(x, P, u.tank_max.y, ior, Lx);
					e = en.xy;
					dist = en.z;
					vec3 air = vec3(en.x, u.tank_max.y, en.y) - P;
					float la = length(air);
					float ca = clamp(-air.y / max(la, 1e-5), 0.0, 1.0);
					float Ftx = 1.0 - (f0 + (1.0 - f0) * pow(1.0 - ca, 5.0));
					// Unfolded path length for the falloff (metres).
					float r_m = (la + dist) / max(u.atten[li].z, 1e-5);
					sun = u.color[li].rgb * Ftx * omni_attenuation(r_m, u.atten[li].x, u.atten[li].y)
							* exp(-sig_t * dist);
					float cx = dot(rd, Lx);
					ph_x = mix(0.95 * hg_phase(cx, g) + 0.05 * rayleigh_phase(cx), 1.0 / (4.0 * PI), a_lum);
				} else {
					dist = d / sun_Lw[li].y;
					e = x.xz + sun_Lw[li].xz * dist;
					sun = sun_in[li] * exp(-sig_t * dist);
					ph_x = sun_ph[li];
				}
				if (u.tank_max.w > 0.5) {
					// God rays: the caustic pattern and decor shadows carried along
					// the light ray. Caustics are sharpest at their focal depth, so the
					// shafts vary naturally with depth.
					vec2 cuv = e / (2.0 * u.tank_max.xz) + 0.5;
					vec3 vis = vec3(1.0);
					if (all(greaterThanEqual(cuv, vec2(0.0))) && all(lessThanEqual(cuv, vec2(1.0)))) {
						vec2 luv = layer_uv(cuv, li, layer_h);
						float blocked = textureLod(light_depth_tex, luv, 0.0).r;
						vis = dist > blocked + 0.005 ? vec3(0.0) : textureLod(caustic_tex, luv, 0.0).rgb;
					}
					sun *= vis;
				}
				lit += sun * ph_x;
			}
			vec3 amb = u.ambient.rgb * exp(-sig_t * d);
			vec3 S = sig_s * (lit + amb) * u.misc.x;

			// Analytic integral over the segment (energy-conserving for any ds).
			vec3 Tseg = exp(-sig_t * ds);
			L += T * S * (1.0 - Tseg) / max(sig_t, vec3(1e-5));
			T *= Tseg;
		}

		// A submerged hit was also lit through the water from above: attenuate
		// its radiance by the depth below the surface (vertical approximation).
		// Tolerance: surfaces lying exactly on the tank floor/walls (sand at y = 0)
		// give t_scene ≈ t_exit, and a strict test flips per pixel with camera
		// motion, flickering the attenuation on and off.
		if (t_scene < t_exit + 0.01) {
			vec3 hit = ro + rd * t_scene;
			float d = clamp(u.tank_max.y - hit.y, 0.0, u.tank_max.y);
			T *= exp(-sig_t * d);
		}
	}

	// Reprojection point: the opaque hit (its view depth is what inscatter.a
	// stores, so the temporal depth test compares like with like), or the middle
	// of the water segment for sky pixels. Back in view units.
	float rep = 0.0;
	if (t1 > t0) {
		rep = (depth > 0.0 ? t_scene : 0.5 * (t0 + t1)) / scale;
	}
	imageStore(inscatter_out, lo, vec4(L, min(lin_depth, 6e4)));
	imageStore(trans_out, lo, vec4(T, rep));
}
