#[compute]
#version 450
// Caustic resolve + à-trous denoise (docs/water_architecture.md §6.2).
//   mode 0: photons (r32ui, fixed point) -> gain (rgba32f), then clear photons.
//           `channels` = 1: one band, replicated to rgb. 3: bands r, g, b stacked
//           vertically in the photon image.
//   mode 1: one à-trous iteration (B3-spline 5x5, holes of `step` texels) src -> dst
// Gain is irradiance relative to a flat surface: 1 = calm water.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32ui, set = 0, binding = 0) uniform restrict uimage2D photons;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D src;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D dst;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int mode;
	int step;
	float inv_scale; // 1 / fixed-point energy of a flat-surface texel
	float channels;
	float _pad1;
	float _pad2;
} p;

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(c, p.size))) {
		return;
	}
	if (p.mode == 0) {
		vec3 g;
		if (p.channels > 1.5) {
			for (int ch = 0; ch < 3; ch++) {
				ivec2 pc = c + ivec2(0, ch * p.size.y);
				g[ch] = float(imageLoad(photons, pc).r) * p.inv_scale;
				imageStore(photons, pc, uvec4(0u));
			}
		} else {
			g = vec3(float(imageLoad(photons, c).r) * p.inv_scale);
			imageStore(photons, c, uvec4(0u));
		}
		imageStore(dst, c, vec4(g, 1.0));
		return;
	}
	const float k[3] = float[3](0.375, 0.25, 0.0625);
	vec3 sum = vec3(0.0);
	float wsum = 0.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			ivec2 q = c + ivec2(i, j) * p.step;
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, p.size))) {
				continue;
			}
			float w = k[abs(i)] * k[abs(j)];
			sum += w * imageLoad(src, q).rgb;
			wsum += w;
		}
	}
	imageStore(dst, c, vec4(sum / wsum, 1.0));
}
