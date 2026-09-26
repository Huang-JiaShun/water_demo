#[compute]
#version 450
// Converts the simulation state into the texture every consumer samples:
//   RGBA16F = (height m, dh/dx, dh/dz, water_mask)
// Gradients are dimensionless world-space slopes along tank-local X and Z, so
// the tank-space normal is simply normalize(vec3(-dh/dx, 1, -dh/dz)).
// Computing them once here saves the surface, caustic and volume passes from
// each re-deriving them.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rg32f, set = 0, binding = 0) uniform restrict readonly image2D state_in;
layout(r32f, set = 0, binding = 1) uniform restrict readonly image2D water_mask;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D wave_out;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int _pad0;
	int _pad1;
	float inv_2dx; // 1 / (2 * texel size X in m)
	float inv_2dz; // 1 / (2 * texel size Z in m)
	float _pad2;
	float _pad3;
} p;

bool is_water(ivec2 c) {
	if (any(lessThan(c, ivec2(0))) || any(greaterThanEqual(c, p.size))) {
		return false;
	}
	return imageLoad(water_mask, c).r > 0.5;
}

float h_at(ivec2 c, float centre) {
	return is_water(c) ? imageLoad(state_in, c).r : centre;
}

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(c, p.size))) {
		return;
	}
	float mask = is_water(c) ? 1.0 : 0.0;
	float h = imageLoad(state_in, c).r;
	float dhdx = (h_at(c + ivec2(1, 0), h) - h_at(c - ivec2(1, 0), h)) * p.inv_2dx;
	float dhdz = (h_at(c + ivec2(0, 1), h) - h_at(c - ivec2(0, 1), h)) * p.inv_2dz;
	imageStore(wave_out, c, vec4(h, dhdx, dhdz, mask) * vec4(1.0, mask, mask, 1.0));
}
