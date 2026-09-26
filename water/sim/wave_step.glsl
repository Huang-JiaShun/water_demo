#[compute]
#version 450
// Wave equation step on the tank heightfield.
// Based on HPWater's HPWaterWaveEquation.compute (Neumann obstacles, Gaussian
// sources), changed for a closed tank:
//  - no sponge layer: glass walls reflect waves (the out-of-bounds cell counts as a wall)
//  - state packed as RG32F = (h_t, h_{t-1}): one read and one write image per step
//  - Courant number and damping computed per substep by the driver (fixed dt)
//  - many splats per step (fish, mouse, drops) instead of one source
//  - weak restoring term so accumulated splat volume does not drift the rest level

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rg32f, set = 0, binding = 0) uniform restrict readonly image2D state_in;
layout(rg32f, set = 0, binding = 1) uniform restrict writeonly image2D state_out;
layout(r32f, set = 0, binding = 2) uniform restrict readonly image2D water_mask; // 1 = water, 0 = solid

// xy = centre in texels, z = radius (texels), w = strength (m of height)
layout(std430, set = 0, binding = 3) restrict readonly buffer Splats {
	vec4 splats[];
};

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int splat_count;
	int _pad0;
	float courant2;   // (c * dt / dx)^2, <= 0.25 guaranteed by the driver
	float retention;  // velocity retention per substep, exp(-damping * dt)
	float restore;    // fraction pulled back to rest per substep
	float max_height; // clamp (m), guards against runaway energy from bad input
} p;

bool is_water(ivec2 c) {
	if (any(lessThan(c, ivec2(0))) || any(greaterThanEqual(c, p.size))) {
		return false;
	}
	return imageLoad(water_mask, c).r > 0.5;
}

// Neumann boundary: a wall neighbour mirrors the centre, so the gradient is zero and the wave reflects.
float neighbour(ivec2 c, float centre) {
	return is_water(c) ? imageLoad(state_in, c).r : centre;
}

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(c, p.size))) {
		return;
	}
	if (!is_water(c)) {
		imageStore(state_out, c, vec4(0.0));
		return;
	}

	vec2 s = imageLoad(state_in, c).rg;
	float u = s.r;
	float u_prev = s.g;

	float lap = neighbour(c + ivec2(-1, 0), u) + neighbour(c + ivec2(1, 0), u)
			+ neighbour(c + ivec2(0, -1), u) + neighbour(c + ivec2(0, 1), u) - 4.0 * u;

	float u_next = u + (u - u_prev) * p.retention + p.courant2 * lap;
	u_next -= u * p.restore;

	vec2 pos = vec2(c) + 0.5;
	for (int i = 0; i < p.splat_count; i++) {
		vec4 sp = splats[i];
		vec2 d = pos - sp.xy;
		float sigma = max(sp.z * 0.5, 0.5);
		float r2 = dot(d, d);
		if (r2 < 9.0 * sigma * sigma) {
			u_next += sp.w * exp(-r2 / (2.0 * sigma * sigma));
		}
	}

	u_next = clamp(u_next, -p.max_height, p.max_height);
	imageStore(state_out, c, vec4(u_next, u, 0.0, 0.0));
}
