// Underwater helpers for decor / fish / particle materials (docs/water_architecture.md §6.2).
// Requires water_common.gdshaderinc to be included first.
//
// Key lights: up to WATER_MAX_LIGHTS (suns and/or local tank lights). Each has its
// own layer in the caustic and light-depth textures, stacked vertically (layer i
// covers v in [i, i + 1] / WATER_MAX_LIGHTS). A point q is lit by light i through
// the rest-surface entry point of the flat-surface refracted ray that reaches it:
//   directional sun:  dist = (surface - q.y) / Lw.y, entry = q.xz + Lw.xz * dist
//   local tank light: exact Snell inverse from the light position (water_light.glsl)
// The caustic layer stores the gain (1 = calm water) at that entry point, and
// the light-depth layer stores how far the ray travels before hitting a solid.
//
// Global uniforms cannot be arrays, so per-light data lives in mat4 columns.

#define WATER_MAX_LIGHTS 4

global uniform sampler2D water_caustic_tex;
global uniform sampler2D water_light_depth_tex;
global uniform vec4 water_caustic_params; // x = strength, y = dispersion, z = 1: texture is true RGB, w = diffuse fill
global uniform int water_light_count;
// Column i: sun: xyz = tank-space refracted direction toward it (in water), w = 0.
//           local: xyz = tank-space position, w = 1.
global uniform mat4 water_lights;
// Column i: sun: x = tan of the in-water half-angle.
//           local: x = LED bar half length, y = half width (tank units), zw = bar axis (tank xz).
global uniform mat4 water_light_shapes;
global uniform vec4 water_light_leds;     // per light: LEDs sampled along the bar


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

// xy = entry point (tank xz), z = in-water distance to it. Lw: toward light i.
vec3 water_light_entry(vec3 q, int i, out vec3 Lw) {
	vec4 l = water_lights[i];
	if (l.w > 0.5) {
		return water_light_entry_local(q, l.xyz, water_surface_height, water_ior, Lw);
	}
	Lw = l.xyz;
	float dist = max(water_surface_height - q.y, 0.0) / max(Lw.y, 0.05);
	return vec3(q.xz + Lw.xz * dist, dist);
}

// For light(): which water key light (index) is the light arriving at world_pos
// from world-space direction light_dir_world, or -1 for plain room fill.
// Directional lights match a sun, others the local light they point back to
// (loose test: the light refracts at the surface; the best match wins).
int water_key_light(vec3 world_pos, vec3 light_dir_world, bool directional) {
	vec3 q = water_tank_pos(world_pos);
	vec3 l = normalize(mat3(water_world_to_tank) * light_dir_world);
	int best = -1;
	float best_dot = directional ? 0.995 : 0.9;
	for (int i = 0; i < min(water_light_count, WATER_MAX_LIGHTS); i++) {
		vec4 k = water_lights[i];
		if ((k.w > 0.5) == directional) continue;
		vec3 to_l;
		if (directional) {
			// Back to the air-side direction (undo the refraction).
			vec2 a = k.xz * water_ior;
			to_l = vec3(a.x, sqrt(max(1.0 - dot(a, a), 0.0)), a.y);
		} else {
			to_l = normalize(k.xyz - q);
		}
		float d = dot(l, to_l);
		if (d > best_dot) {
			best_dot = d;
			best = i;
		}
	}
	return best;
}

// uv in one layer -> uv in the stacked texture. Clamped half a texel inside the
// layer so bilinear taps never bleed into the neighbouring light.
vec2 water_layer_uv(vec2 uv, int layer, sampler2D tex) {
	float h = float(textureSize(tex, 0).y) / float(WATER_MAX_LIGHTS);
	uv.y = clamp(uv.y, 0.5 / h, 1.0 - 0.5 / h);
	return vec2(uv.x, (uv.y + float(layer)) / float(WATER_MAX_LIGHTS));
}

vec3 water_caustic_tap(vec2 uv, vec2 shift, int layer) {
	if (water_caustic_params.z > 0.5) {
		// True RGB: every channel was traced with its own IOR.
		return textureLod(water_caustic_tex, water_layer_uv(uv, layer, water_caustic_tex), 0.0).rgb;
	}
	return vec3(textureLod(water_caustic_tex, water_layer_uv(uv - shift, layer, water_caustic_tex), 0.0).r,
			textureLod(water_caustic_tex, water_layer_uv(uv, layer, water_caustic_tex), 0.0).g,
			textureLod(water_caustic_tex, water_layer_uv(uv + shift, layer, water_caustic_tex), 0.0).b);
}

// Per-channel caustic gain of key light i reaching world_pos (1 = no caustic effect).
// Points above the surface, outside the footprint or behind a light-depth
// occluder return 1, leaving shadowing to Godot's own shadow map.
vec3 water_caustics(vec3 world_pos, int i) {
	if (i < 0 || i >= min(water_light_count, WATER_MAX_LIGHTS)) return vec3(1.0);
	vec3 q = water_tank_pos(world_pos);
	float depth = water_surface_height - q.y;
	if (depth <= 0.0) return vec3(1.0);
	vec3 Lw;
	vec3 ent = water_light_entry(q, i, Lw);
	float dist = ent.z;
	vec2 uv = water_tank_uv(vec3(ent.x, 0.0, ent.y));
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(1.0);
	float blocked = textureLod(water_light_depth_tex, water_layer_uv(uv, i, water_light_depth_tex), 0.0).r;
	if (dist > blocked + 0.01) return vec3(1.0);

	vec2 shift = vec2(0.0);
	if (water_caustic_params.z < 0.5) {
		// Fake dispersion: red refracts slightly less and blue slightly more, which
		// shifts their entry points along the horizontal light direction with depth.
		shift = normalize(Lw.xz + vec2(1e-5)) * dist * water_caustic_params.y / water_tank_size.xz;
	}
	vec4 shape = water_light_shapes[i];
	vec3 g = vec3(0.0);
	if (water_lights[i].w > 0.5) {
		// LED bar: every LED casts its own copy of the pattern. Moving the source by
		// x moves q's entry point by x * k / (1 + k), k = D / (n h) (paraxial), so the
		// copies spread apart with depth: sharp just below the surface, layered and
		// criss-crossed deeper down, like real hood lighting. The bar width blurs
		// each copy slightly across the bar.
		float h = max(water_lights[i].y - water_surface_height, 1e-3);
		float k = depth / (water_ior * h);
		float m = k / (1.0 + k);
		vec2 axis = shape.zw;
		vec2 perp = vec2(-axis.y, axis.x);
		int n = clamp(int(water_light_leds[i] + 0.5), 1, 16);
		vec2 w_uv = perp * shape.y * m * 0.6 / water_tank_size.xz;
		for (int j = 0; j < n; j++) {
			float x = n > 1 ? (float(j) / float(n - 1) * 2.0 - 1.0) * shape.x : 0.0;
			vec2 o = axis * x * m / water_tank_size.xz;
			g += water_caustic_tap(uv + o + w_uv, shift, i) + water_caustic_tap(uv + o - w_uv, shift, i);
		}
		g /= float(2 * n);
	} else {
		// Sun-disc penumbra: each point sees the surface through a cone of half-angle
		// atan(blur), so the caustic is the texture averaged over a disc of radius
		// dist * tan. Deeper points get softer, lower-contrast caustics.
		vec2 r_uv = vec2(dist * shape.x) / water_tank_size.xz;
		// 1 centre + 8 taps on a ring at 0.7 r (approximates the uniform-disc mean).
		const vec2 TAPS[8] = vec2[8](vec2(1.0, 0.0), vec2(0.7071, 0.7071), vec2(0.0, 1.0), vec2(-0.7071, 0.7071),
				vec2(-1.0, 0.0), vec2(-0.7071, -0.7071), vec2(0.0, -1.0), vec2(0.7071, -0.7071));
		for (int j = -1; j < 8; j++) {
			vec2 o = j < 0 ? vec2(0.0) : TAPS[j] * 0.7 * r_uv;
			g += water_caustic_tap(uv + o, shift, i);
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
