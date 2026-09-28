#[compute]
#version 450
// Photon splat (docs/water_architecture.md §6.2).
//
// Parameterisation: every caustic / light-depth texel is a point on the rest
// surface. A texel's "light ray" enters there and travels along the flat-surface
// refracted sun direction d0 = -Lw. light_depth stores the distance along that
// ray to the first solid (decor, floor or tank wall).
//
// Each photon starts on the surface, refracts through the simulated normal and
// marches until it goes behind the light-depth map. The hit point is then
// projected back along d0 to its entry texel, and the photon is added there. A
// calm surface maps each photon onto its own texel, giving a uniform gain of 1.
// Waves redistribute photons without adding energy.

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
	vec4 misc;    // x = fixed-point energy of one photon
} p;

vec2 xz_to_uv(vec2 xz) {
	return xz / (2.0 * p.tank.xz) + 0.5;
}

// Returns the entry-point UV of q (projected back along Lw to the rest surface)
// and, in .z, q's distance along the light ray from that entry point.
vec3 light_coords(vec3 q) {
	vec3 Lw = p.light.xyz;
	float dist = (p.tank.y - q.y) / Lw.y;
	vec2 e = q.xz + Lw.xz * dist;
	return vec3(xz_to_uv(e), dist);
}

float depth_at(vec2 uv) {
	ivec2 c = clamp(ivec2(floor(uv * vec2(p.size))), ivec2(0), p.size - 1);
	return texelFetch(light_depth, c, 0).r;
}

// Fresnel transmittance (Schlick) from air into water.
float fresnel_t(float cos_i, float ior) {
	float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
	return 1.0 - (f0 + (1.0 - f0) * pow(1.0 - clamp(cos_i, 0.0, 1.0), 5.0));
}

void splat(vec2 uv, float energy) {
	vec2 f = uv * vec2(p.size) - 0.5;
	ivec2 c = ivec2(floor(f));
	vec2 w = f - vec2(c);
	float ws[4] = float[4]((1.0 - w.x) * (1.0 - w.y), w.x * (1.0 - w.y), (1.0 - w.x) * w.y, w.x * w.y);
	ivec2 os[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
	for (int i = 0; i < 4; i++) {
		// Clamp rather than drop, so edge texels keep their full share.
		ivec2 t = clamp(c + os[i], ivec2(0), p.size - 1);
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

	float ior = p.light.w;
	vec3 Lw = p.light.xyz;
	// Air-side sun direction that refracts to Lw through a flat surface.
	vec2 ls_xz = Lw.xz * ior;
	vec3 Ls = vec3(ls_xz.x, sqrt(max(1.0 - dot(ls_xz, ls_xz), 0.0)), ls_xz.y);

	float hs = p.tank.w;
	vec3 n = normalize(vec3(-w.y * hs, 1.0, -w.z * hs));
	vec3 d = refract(-Ls, n, 1.0 / ior);
	if (d.y > -1e-3) {
		return;
	}
	// Tilted facets transmit a little more or less than the flat surface.
	float energy = fresnel_t(dot(Ls, n), ior) / max(fresnel_t(Ls.y, ior), 1e-3);

	vec3 s = vec3((uv0 - 0.5) * 2.0 * p.tank.xz, p.tank.y).xzy;

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
	if (any(lessThan(lc.xy, vec2(0.0))) || any(greaterThan(lc.xy, vec2(1.0)))) {
		return; // landed on a side wall outside the footprint
	}
	splat(lc.xy, energy / float(p.sub * p.sub));
}
