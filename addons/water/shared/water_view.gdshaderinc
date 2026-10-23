// Water as seen from outside it (through the glass, or from above the surface).
// Beer-Lambert extinction plus an artistic in-scatter toward water_view_tint.rgb.
// Every parameter comes from WaterGlobals, so glass and surface always agree.
#include "res://addons/water/shared/water_common.gdshaderinc"

global uniform vec4 water_view_tint;     // rgb = colour, a = density multiplier
global uniform vec3 water_view_extinction; // 1/m, independent of the physical sigma
global uniform float water_view_max_path;
global uniform vec2 water_meniscus;      // x = width (m), y = height the water climbs at the glass (m)

// Length of the world-space ray [0, max_t] that lies inside the water box with
// its top at tank height `top`. Intersected in tank space, so it follows the
// tank's transform.
float water_view_path(vec3 ro_world, vec3 rd_world, float max_t, float top) {
	vec3 ro = water_tank_pos(ro_world);
	vec3 rd = mat3(water_world_to_tank) * rd_world; // tank transform is rigid: lengths preserved
	vec3 bmin = vec3(-0.5 * water_tank_size.x, 0.0, -0.5 * water_tank_size.z);
	vec3 bmax = vec3(0.5 * water_tank_size.x, top, 0.5 * water_tank_size.z);
	vec3 inv = 1.0 / rd;
	vec3 t0 = (bmin - ro) * inv;
	vec3 t1 = (bmax - ro) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	float enter = max(max(max(tmin.x, tmin.y), tmin.z), 0.0);
	float exit = min(min(min(tmax.x, tmax.y), tmax.z), max_t);
	return clamp(exit - enter, 0.0, water_view_max_path);
}

vec3 water_view_tint_apply(vec3 background, float path) {
	vec3 T = exp(-water_view_extinction * water_view_tint.a * min(path, water_view_max_path));
	return background * T + water_view_tint.rgb * (vec3(1.0) - T);
}

// Distance (m) from a tank-space point to the nearest side wall, and the unit
// XZ direction toward that wall.
float water_wall_distance(vec2 xz, out vec2 to_wall) {
	vec2 d = water_tank_size.xz * 0.5 - abs(xz);
	if (d.x < d.y) {
		to_wall = vec2(sign(xz.x), 0.0);
		return max(d.x, 0.0);
	}
	to_wall = vec2(0.0, sign(xz.y));
	return max(d.y, 0.0);
}

// Meniscus profile at distance d from the glass: height above the waves and its
// slope toward the wall. Exponential capillary profile h(d) = H * exp(-d / w).
vec2 water_meniscus_at(float d) {
	float w = max(water_meniscus.x, 1e-5);
	float e = exp(-d / w);
	return vec2(water_meniscus.y * e, water_meniscus.y * e / w);
}

// Live surface height in tank space at a tank-space point: rest + waves +
// meniscus, the same displacement the surface mesh gets.
float water_live_height(vec3 tank_pos) {
	vec2 uv = clamp(water_tank_uv(tank_pos), vec2(0.002), vec2(0.998));
	vec2 to_wall;
	float dw = water_wall_distance(tank_pos.xz, to_wall);
	return water_surface_height + water_sample_wave(uv).x * water_height_scale + water_meniscus_at(dw).x;
}

// Where a world-space ray crosses the inner side walls of the tank (tank space):
// the point it passes from outside the footprint to inside. A camera inside the
// footprint returns ro itself.
vec3 water_wall_entry(vec3 ro_world, vec3 rd_world) {
	vec3 ro = water_tank_pos(ro_world);
	vec3 rd = mat3(water_world_to_tank) * rd_world;
	vec2 h = water_tank_size.xz * 0.5;
	vec2 inv = 1.0 / rd.xz;
	vec2 t0 = (-h - ro.xz) * inv;
	vec2 t1 = (h - ro.xz) * inv;
	vec2 tmin = min(t0, t1);
	return ro + rd * max(max(tmin.x, tmin.y), 0.0);
}
