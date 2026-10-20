#[compute]
#version 450
// Depth-aware à-trous on the low-res volume (docs/water_architecture.md §6.3).
// B3-spline 5x5 with holes of `step` texels; the edge-stopping weight uses the
// linear depth stored in inscatter.a, so fog never blurs across silhouettes.
// Runs after the temporal pass and never feeds back into history.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D ins_src;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D trans_src;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D ins_dst;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D trans_dst;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int step;
	int _pad0;
	float depth_sharpness;
	float _pad1;
	float _pad2;
	float _pad3;
} p;

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(c, p.size))) {
		return;
	}
	vec4 ci = imageLoad(ins_src, c);
	vec4 ct = imageLoad(trans_src, c);
	if (ct.a <= 0.0) {
		imageStore(ins_dst, c, ci);
		imageStore(trans_dst, c, ct);
		return;
	}
	float z0 = ci.a;
	const float k[3] = float[3](0.375, 0.25, 0.0625);
	vec3 si = vec3(0.0);
	vec3 st = vec3(0.0);
	float wsum = 0.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			ivec2 q = c + ivec2(i, j) * p.step;
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, p.size))) {
				continue;
			}
			vec4 a = imageLoad(ins_src, q);
			vec4 b = imageLoad(trans_src, q);
			if (b.a <= 0.0) {
				continue;
			}
			float dz = abs(a.a - z0) / max(z0, 1e-3);
			float w = k[abs(i)] * k[abs(j)] * exp(-dz * p.depth_sharpness);
			si += a.rgb * w;
			st += b.rgb * w;
			wsum += w;
		}
	}
	// The centre always contributes (dz = 0), so wsum > 0.
	imageStore(ins_dst, c, vec4(si / wsum, ci.a));
	imageStore(trans_dst, c, vec4(st / wsum, ct.a));
}
