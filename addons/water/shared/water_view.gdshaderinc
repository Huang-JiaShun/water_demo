// Water as seen from outside it (through the glass, or from above the surface).
// Beer-Lambert extinction plus an artistic in-scatter toward water_view_tint.rgb.
// Every parameter comes from WaterGlobals, so glass and surface always agree.
#include "res://addons/water/shared/water_common.gdshaderinc"

global uniform vec4 water_view_tint;     // rgb = colour, a = density multiplier
global uniform vec3 water_view_extinction; // 1/m, independent of the physical sigma
global uniform float water_view_max_path;

// Length of the world-space ray [0, max_t] that lies inside the rest-water box.
// Intersected in tank space, so it follows the tank's transform.
float water_view_path(vec3 ro_world, vec3 rd_world, float max_t) {
	vec3 ro = water_tank_pos(ro_world);
	vec3 rd = mat3(water_world_to_tank) * rd_world; // tank transform is rigid: lengths preserved
	vec3 bmin = vec3(-0.5 * water_tank_size.x, 0.0, -0.5 * water_tank_size.z);
	vec3 bmax = vec3(0.5 * water_tank_size.x, water_surface_height, 0.5 * water_tank_size.z);
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

// Live (displaced) surface height in tank space at a tank-space point.
float water_live_height(vec3 tank_pos) {
	vec2 uv = clamp(water_tank_uv(tank_pos), vec2(0.002), vec2(0.998));
	return water_surface_height + water_sample_wave(uv).x * water_height_scale;
}
