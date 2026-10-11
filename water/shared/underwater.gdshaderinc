// Underwater helpers for decor / fish / particle materials (docs/water_architecture.md §6.2).
// Requires water_common.gdshaderinc to be included first.
//
// Caustic lookup: a point q is lit through the rest-surface entry point of the
// flat-surface refracted key-light ray that reaches it:
//   directional sun:  dist = (surface - q.y) / Lw.y, entry = q.xz + Lw.xz * dist
//   local tank light: exact Snell inverse from the light position (water_light.glsl)
// The caustic texture stores the gain (1 = calm water) at that entry point, and
// the light-depth texture stores how far the ray travels before hitting a solid.

global uniform sampler2D water_caustic_tex;
global uniform sampler2D water_light_depth_tex;
global uniform vec4 water_light_dir;
global uniform vec4 water_caustic_params; // x = strength, y = dispersion, z = 1: texture is true RGB, w = diffuse fill
// Directional: x = tan of the in-water sun half-angle.
// Local: x = LED bar half length (m), y = bar half width (m), zw = bar axis (tank xz, unit).
global uniform vec4 water_caustic_blur;
global uniform vec4 water_light_pos;      // xyz = tank-space key light position, w = 1: local light
global uniform int water_light_leds;      // LEDs sampled along the bar (local light)

// Mirror of wl_entry_local() in water/shared/water_light.glsl (RD side). Keep in sync.
vec3 water_light_entry_local(vec3 q, vec3 P, float surf, float ior, out vec3 Lw) {
	float h = max(P.y - surf, 1e-3);
	float D = max(surf - q.y, 0.0);
	vec2 r = q.xz - P.xz;
	float R = length(r);
	vec2 rh = R > 1e-6 ? r / R : vec2(1.0, 0.0);
	float a = R / (1.0 + D / (ior * h));
	for (int i = 0; i < 3; i++) {
		float la = sqrt(a * a + h * h);
		float s = a / (la * ior);
		float cw = sqrt(max(1.0 - s * s, 1e-6));
		float f = a + D * s / cw - R;
		float df = 1.0 + D * h * h / (la * la * la * ior * cw * cw * cw);
		a = clamp(a - f / df, 0.0, R);
	}
	float la = sqrt(a * a + h * h);
	float s = a / (la * ior);
	float cw = sqrt(max(1.0 - s * s, 1e-6));
	Lw = vec3(-rh.x * s, cw, -rh.y * s);
	return vec3(P.xz + rh * a, D / cw);
}

// xy = entry point (tank xz), z = in-water distance to it. Lw: toward the light.
vec3 water_light_entry(vec3 q, out vec3 Lw) {
	if (water_light_pos.w > 0.5) {
		return water_light_entry_local(q, water_light_pos.xyz, water_surface_height, water_ior, Lw);
	}
	Lw = water_light_dir.xyz;
	float dist = max(water_surface_height - q.y, 0.0) / max(Lw.y, 0.05);
	return vec3(q.xz + Lw.xz * dist, dist);
}

// For light() of non-directional lights: true if the light arriving at world_pos
// from world-space direction light_dir_world is the water's local key light.
bool water_is_key_light(vec3 world_pos, vec3 light_dir_world) {
	if (water_light_pos.w < 0.5) return false;
	vec3 q = water_tank_pos(world_pos);
	vec3 l = normalize(mat3(water_world_to_tank) * light_dir_world);
	// The light refracts at the surface, so compare loosely.
	return dot(l, normalize(water_light_pos.xyz - q)) > 0.9;
}

vec3 water_caustic_tap(vec2 uv, vec2 shift) {
	if (water_caustic_params.z > 0.5) {
		// True RGB: every channel was traced with its own IOR.
		return textureLod(water_caustic_tex, uv, 0.0).rgb;
	}
	return vec3(textureLod(water_caustic_tex, uv - shift, 0.0).r,
			textureLod(water_caustic_tex, uv, 0.0).g,
			textureLod(water_caustic_tex, uv + shift, 0.0).b);
}

// Returns per-channel caustic gain for key light reaching world_pos (1 = no caustic effect).
// Points above the surface, outside the footprint or behind a light-depth
// occluder return 1, leaving shadowing to Godot's own shadow map.
vec3 water_caustics(vec3 world_pos) {
	if (water_light_dir.w < 0.5) return vec3(1.0);
	vec3 q = water_tank_pos(world_pos);
	float depth = water_surface_height - q.y;
	if (depth <= 0.0) return vec3(1.0);
	vec3 Lw;
	vec3 ent = water_light_entry(q, Lw);
	float dist = ent.z;
	vec2 uv = water_tank_uv(vec3(ent.x, 0.0, ent.y));
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(1.0);
	float blocked = textureLod(water_light_depth_tex, uv, 0.0).r;
	if (dist > blocked + 0.01) return vec3(1.0);

	vec2 shift = vec2(0.0);
	if (water_caustic_params.z < 0.5) {
		// Fake dispersion: red refracts slightly less and blue slightly more, which
		// shifts their entry points along the horizontal light direction with depth.
		shift = normalize(Lw.xz + vec2(1e-5)) * dist * water_caustic_params.y / water_tank_size.xz;
	}
	vec3 g = vec3(0.0);
	if (water_light_pos.w > 0.5) {
		// LED bar: every LED casts its own copy of the pattern. Moving the source by
		// x moves q's entry point by x * k / (1 + k), k = D / (n h) (paraxial), so the
		// copies spread apart with depth: sharp just below the surface, layered and
		// criss-crossed deeper down, like real hood lighting. The bar width blurs
		// each copy slightly across the bar.
		float h = max(water_light_pos.y - water_surface_height, 1e-3);
		float k = depth / (water_ior * h);
		float m = k / (1.0 + k);
		vec2 axis = water_caustic_blur.zw;
		vec2 perp = vec2(-axis.y, axis.x);
		int n = clamp(water_light_leds, 1, 16);
		vec2 w_uv = perp * water_caustic_blur.y * m * 0.6 / water_tank_size.xz;
		for (int i = 0; i < n; i++) {
			float x = n > 1 ? (float(i) / float(n - 1) * 2.0 - 1.0) * water_caustic_blur.x : 0.0;
			vec2 o = axis * x * m / water_tank_size.xz;
			g += water_caustic_tap(uv + o + w_uv, shift) + water_caustic_tap(uv + o - w_uv, shift);
		}
		g /= float(2 * n);
	} else {
		// Sun-disc penumbra: each point sees the surface through a cone of half-angle
		// atan(blur), so the caustic is the texture averaged over a disc of radius
		// dist * tan. Deeper points get softer, lower-contrast caustics.
		vec2 r_uv = vec2(dist * water_caustic_blur.x) / water_tank_size.xz;
		// 1 centre + 8 taps on a ring at 0.7 r (approximates the uniform-disc mean).
		const vec2 TAPS[8] = vec2[8](vec2(1.0, 0.0), vec2(0.7071, 0.7071), vec2(0.0, 1.0), vec2(-0.7071, 0.7071),
				vec2(-1.0, 0.0), vec2(-0.7071, -0.7071), vec2(0.0, -1.0), vec2(0.7071, -0.7071));
		for (int i = -1; i < 8; i++) {
			vec2 o = i < 0 ? vec2(0.0) : TAPS[i] * 0.7 * r_uv;
			g += water_caustic_tap(uv + o, shift);
		}
		g /= 9.0;
	}
	// Fade in just below the surface, where the pattern has not formed yet.
	float fade = smoothstep(0.0, 0.02, depth) * water_caustic_params.x;
	// Fade out toward the footprint edge so the pattern doesn't cut off hard where
	// the entry point leaves the tank (visible as a sharp line along the glass).
	vec2 edge_m = min(uv, 1.0 - uv) * water_tank_size.xz;
	fade *= smoothstep(0.0, 0.03, min(edge_m.x, edge_m.y));
	// Floor bounce: light the floor scatters up is partly reflected back down by
	// the underside of the surface (TIR + Fresnel). It is pattern-free, so a share
	// fill = albedo * R_int (computed by WaterBody, ~0.19 for sand) of the total
	// irradiance is uniform. Mixing toward 1 keeps the mean, lifts the troughs.
	g = mix(g, vec3(1.0), clamp(water_caustic_params.w, 0.0, 1.0));
	return mix(vec3(1.0), g, fade);
}

// Analytic fog for transparent underwater objects, which the volume pass cannot see.
// Attenuates `color` along the in-water part of the camera ray to world_pos and
// adds a simple ambient in-scatter tinted by the medium.
vec3 water_fog(vec3 color, vec3 world_pos, vec3 camera_pos, vec3 ambient) {
	vec3 a = water_tank_pos(camera_pos);
	vec3 b = water_tank_pos(world_pos);
	vec3 rd = b - a;
	float len = length(rd);
	if (len < 1e-5) return color;
	rd /= len;
	vec3 hi = vec3(water_tank_size.x * 0.5, water_surface_height, water_tank_size.z * 0.5);
	vec3 lo = vec3(-hi.x, 0.0, -hi.z);
	vec3 inv = 1.0 / rd;
	vec3 t0 = (lo - a) * inv;
	vec3 t1 = (hi - a) * inv;
	float tn = max(max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z)), 0.0);
	float tf = min(min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z)), len);
	float seg = max(tf - tn, 0.0);
	vec3 sig_t = water_sigma_a + water_sigma_s;
	vec3 T = exp(-sig_t * seg);
	vec3 albedo = water_sigma_s / max(sig_t, vec3(1e-5));
	return color * T + ambient * albedo * (1.0 - T);
}
