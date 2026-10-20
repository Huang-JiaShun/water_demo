#[compute]
#version 450
// Photon splat (docs/water_architecture.md §6.2).
//
// Parameterisation: every caustic / light-depth texel is a point on the rest
// surface. A texel's "light ray" enters there and travels along the flat-surface
// flat-surface refracted key-light ray (parallel for the sun, diverging from the
// light position for a local tank light; see water_light.glsl). light_depth stores the distance along that
// ray to the first solid (decor, floor or tank wall).
//
// Each photon starts on the surface, refracts through the simulated normal and
// marches until it goes behind the light-depth map. The hit point is then
// projected back along the flat-surface light ray to its entry texel, and the photon is added there. A
// calm surface maps each photon onto its own texel, giving a uniform gain of 1.
// Waves redistribute photons without adding energy.
//
// True RGB (gl_GlobalInvocationID.z = channel): each channel refracts with its
// own IOR and splats into its own band of the photon image (rows
// [channel * size.y, (channel + 1) * size.y)). The entry-point mapping keeps
// using the mono IOR, so dispersion shows up as a real per-channel shift.

#include "../shared/water_light.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D wave_tex;     // (h, dh/dx, dh/dz, mask), linear
layout(set = 0, binding = 1) uniform sampler2D light_depth;  // R32F, fetched with texelFetch
layout(r32ui, set = 0, binding = 2) uniform restrict uimage2D photons;

layout(push_constant, std430) uniform Params {
	ivec2 size;   // caustic grid
	int sub;      // photons per texel along each axis
	int steps;    // march steps
	vec4 light;   // xyz = Lw (toward the light, below the surface, unit), w = ior
	vec4 tank;    // x = half size X, y = rest surface height, z = half size Z, w = wave height scale
	vec4 misc;    // x = fixed-point energy of one photon, y = IOR spread (blue - red), z = channel count, w = light layer
	vec4 lpos;    // xyz = tank-space key light position, w = 1: local light (else directional, light.xyz)
} p;

vec2 xz_to_uv(vec2 xz) {
	return xz / (2.0 * p.tank.xz) + 0.5;
}

// Returns the entry-point UV of q (projected back along Lw to the rest surface)
// and, in .z, q's distance along the light ray from that entry point.
vec3 light_coords(vec3 q) {
	vec3 Lw;
	vec3 e = wl_entry(q, p.lpos, p.light.xyz, p.tank.y, p.light.w, Lw);
	return vec3(xz_to_uv(e.xy), e.z);
}

// Multi-light: every light has its own layer, stacked vertically (rows
// [layer * size.y, (layer + 1) * size.y)) in light_depth and in the photon image.
int layer() {
	return int(p.misc.w);
}

float depth_at(vec2 uv) {
	ivec2 c = clamp(ivec2(floor(uv * vec2(p.size))), ivec2(0), p.size - 1);
	return texelFetch(light_depth, c + ivec2(0, layer() * p.size.y), 0).r;
}

// Fresnel transmittance (Schlick) from air into water.
float fresnel_t(float cos_i, float ior) {
	float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
	return 1.0 - (f0 + (1.0 - f0) * pow(1.0 - clamp(cos_i, 0.0, 1.0), 5.0));
}

void splat(vec2 uv, float energy, int band) {
	vec2 f = uv * vec2(p.size) - 0.5;
	ivec2 c = ivec2(floor(f));
	vec2 w = f - vec2(c);
	float ws[4] = float[4]((1.0 - w.x) * (1.0 - w.y), w.x * (1.0 - w.y), (1.0 - w.x) * w.y, w.x * w.y);
	ivec2 os[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
	for (int i = 0; i < 4; i++) {
		// Clamp rather than drop, so edge texels keep their full share.
		// Photon bands: layer-major, then channel.
		ivec2 t = clamp(c + os[i], ivec2(0), p.size - 1) + ivec2(0, (layer() * int(p.misc.z) + band) * p.size.y);
		uint v = uint(energy * ws[i] * p.misc.x + 0.5);
		if (v > 0u) {
			imageAtomicAdd(photons, t, v);
		}
	}
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 n_ph = p.size * p.sub;
	if (any(greaterThanEqual(id, n_ph))) {
		return;
	}
	vec2 uv0 = (vec2(id) + 0.5) / vec2(n_ph);
	vec4 w = textureLod(wave_tex, uv0, 0.0);
	if (w.a < 0.5) {
		return; // decor pokes through the surface here: no light enters
	}

	float ior0 = p.light.w;
	vec3 s = vec3((uv0 - 0.5) * 2.0 * p.tank.xz, p.tank.y).xzy;
	vec3 Ls;
	if (p.lpos.w > 0.5) {
		// Local light: photons diverge from the light position.
		Ls = normalize(p.lpos.xyz - s);
	} else {
		// Air-side sun direction that refracts to Lw through a flat surface (mono IOR).
		vec2 ls_xz = p.light.xz * ior0;
		Ls = vec3(ls_xz.x, sqrt(max(1.0 - dot(ls_xz, ls_xz), 0.0)), ls_xz.y);
	}

	int band = int(gl_GlobalInvocationID.z);
	// Channels: 1 = mono; 3 = red, green, blue spread symmetrically around ior0.
	float ior = p.misc.z > 1.5 ? ior0 + p.misc.y * (float(band) - 1.0) * 0.5 : ior0;

	float hs = p.tank.w;
	vec3 n = normalize(vec3(-w.y * hs, 1.0, -w.z * hs));
	vec3 d = refract(-Ls, n, 1.0 / ior);
	if (d.y > -1e-3) {
		return;
	}
	// Tilted facets transmit a little more or less than the flat surface.
	float energy = fresnel_t(dot(Ls, n), ior) / max(fresnel_t(Ls.y, ior), 1e-3);

	// Exit through the tank floor or a wall.
	vec3 bmin = vec3(-p.tank.x, 0.0, -p.tank.z);
	vec3 bmax = vec3(p.tank.x, p.tank.y, p.tank.z);
	vec3 inv = 1.0 / d;
	vec3 tb = max((bmin - s) * inv, (bmax - s) * inv);
	float t_exit = max(min(min(tb.x, tb.y), tb.z), 0.0);

	// Linear march with a per-photon static dither, then a secant refinement
	// between the last free sample and the first blocked one.
	int steps = max(p.steps, 1);
	float jitter = fract(52.9829189 * fract(dot(vec2(id), vec2(0.06711056, 0.00583715))));
	float dt = t_exit / float(steps);
	float t_prev = 0.0;
	float f_prev = -depth_at(uv0); // dist(0) - depth = -depth
	float t_hit = t_exit;
	for (int i = 1; i <= steps; i++) {
		float t = min((float(i) + jitter) * dt, t_exit);
		vec3 lc = light_coords(s + d * t);
		float f = lc.z - depth_at(lc.xy);
		if (f >= 0.0) {
			// f_prev < 0 <= f: linear root between the two samples.
			t_hit = mix(t_prev, t, clamp(-f_prev / max(f - f_prev, 1e-6), 0.0, 1.0));
			break;
		}
		t_prev = t;
		f_prev = f;
	}

	vec3 lc = light_coords(s + d * t_hit);
	// Photons that leave the footprint hit a glass wall, where steep underwater
	// light is mostly reflected (TIR at the outer glass face). Mirror them back
	// across the wall instead of dropping them, so texels near the glass keep
	// their energy and the mean gain stays 1 right up to the edge.
	lc.xy = 1.0 - abs(1.0 - abs(lc.xy));
	if (any(lessThan(lc.xy, vec2(0.0))) || any(greaterThan(lc.xy, vec2(1.0)))) {
		return; // more than a full tank width away: numerically degenerate
	}
	splat(lc.xy, energy / float(p.sub * p.sub), band);
}
