// Shared water helpers for spatial shaders.
// Must mirror water/shared/water_common.glsl (RD side, added in later phases).

global uniform sampler2D water_wave_tex;
global uniform mat4 water_world_to_tank;
global uniform vec3 water_tank_size;
global uniform float water_surface_height;
global uniform vec3 water_sigma_a;
global uniform vec3 water_sigma_s;
global uniform float water_phase_g;
global uniform float water_ior;

vec3 water_tank_pos(vec3 world_pos) {
	return (water_world_to_tank * vec4(world_pos, 1.0)).xyz;
}

vec2 water_tank_uv(vec3 tank_pos) {
	return tank_pos.xz / water_tank_size.xz + 0.5;
}

// x = height (m), yz = slopes dh/dx, dh/dz, w = water mask
vec4 water_sample_wave(vec2 uv) {
	return textureLod(water_wave_tex, uv, 0.0);
}

// Tank-space surface normal from slopes.
vec3 water_wave_normal(vec2 slopes) {
	return normalize(vec3(-slopes.x, 1.0, -slopes.y));
}
