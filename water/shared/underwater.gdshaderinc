// Underwater helpers for decor / fish / particle materials (docs/water_architecture.md §6.2).
// Requires water_common.gdshaderinc to be included first.
//
// Caustic lookup: a point q is lit through the rest-surface entry point found by
// walking back along the refracted sun direction Lw (water_light_dir.xyz):
//   dist  = (surface - q.y) / Lw.y
//   entry = q.xz + Lw.xz * dist
// The caustic texture stores the gain (1 = calm water) at that entry point, and
// the light-depth texture stores how far the ray travels before hitting a solid.

global uniform sampler2D water_caustic_tex;
global uniform sampler2D water_light_depth_tex;
global uniform vec4 water_light_dir;
global uniform vec4 water_caustic_params; // x = strength, y = dispersion, z = 1: texture is true RGB

// Returns per-channel caustic gain for sunlight reaching world_pos (1 = no caustic effect).
// Points above the surface, outside the footprint or behind a light-depth
// occluder return 1, leaving shadowing to Godot's own shadow map.
vec3 water_caustics(vec3 world_pos) {
	if (water_light_dir.w < 0.5) return vec3(1.0);
	vec3 q = water_tank_pos(world_pos);
	vec3 Lw = water_light_dir.xyz;
	float depth = water_surface_height - q.y;
	if (depth <= 0.0) return vec3(1.0);
	float dist = depth / max(Lw.y, 0.05);
	vec2 uv = water_tank_uv(vec3(q.x + Lw.x * dist, 0.0, q.z + Lw.z * dist));
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(1.0);
	float blocked = textureLod(water_light_depth_tex, uv, 0.0).r;
	if (dist > blocked + 0.01) return vec3(1.0);

	vec3 g;
	if (water_caustic_params.z > 0.5) {
		// True RGB: every channel was traced with its own IOR.
		g = textureLod(water_caustic_tex, uv, 0.0).rgb;
	} else {
		// Fake dispersion: red refracts slightly less and blue slightly more, which
		// shifts their entry points along the horizontal light direction with depth.
		vec2 shift = normalize(Lw.xz + vec2(1e-5)) * dist * water_caustic_params.y / water_tank_size.xz;
		g.r = textureLod(water_caustic_tex, uv - shift, 0.0).r;
		g.g = textureLod(water_caustic_tex, uv, 0.0).g;
		g.b = textureLod(water_caustic_tex, uv + shift, 0.0).b;
	}
	// Fade in just below the surface, where the pattern has not formed yet.
	float fade = smoothstep(0.0, 0.02, depth) * water_caustic_params.x;
	// Fade out toward the footprint edge so the pattern doesn't cut off hard where
	// the entry point leaves the tank (visible as a sharp line along the glass).
	vec2 edge_m = min(uv, 1.0 - uv) * water_tank_size.xz;
	fade *= smoothstep(0.0, 0.03, min(edge_m.x, edge_m.y));
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
