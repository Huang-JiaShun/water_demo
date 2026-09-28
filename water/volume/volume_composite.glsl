#[compute]
#version 450
// Joint bilateral upsample of the low-res volume result, guided by full-res
// depth, then composite into the scene color: color = scene * T + inscatter.
// The depth guide stops fog bleeding across the glass / foreground edges.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D inscatter_in;
layout(rgba16f, set = 0, binding = 3) uniform restrict readonly image2D trans_in;

layout(push_constant, std430) uniform Params {
	ivec2 full_size;
	ivec2 low_size;
	// z and w rows of the inverse projection, restricted to the depth term:
	// view z = zc*d + zo, view w = wc*d + wo (x/y terms vanish for any frustum).
	float zc;
	float zo;
	float wc;
	float wo;
	float depth_sharpness;
	float _pad0;
	float _pad1;
	float _pad2;
} p;

float linear_depth(float d) {
	if (d <= 0.0) {
		return 1e4;
	}
	return -(p.zc * d + p.zo) / (p.wc * d + p.wo);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, p.full_size))) {
		return;
	}
	float z0 = min(linear_depth(texelFetch(depth_tex, px, 0).r), 6e4);

	vec2 lp = (vec2(px) + 0.5) * vec2(p.low_size) / vec2(p.full_size) - 0.5;
	ivec2 base = ivec2(floor(lp));
	vec2 f = lp - vec2(base);

	vec3 ins = vec3(0.0);
	vec3 T = vec3(0.0);
	float wsum = 0.0;
	float best_dz = 1e9;
	vec3 best_ins = vec3(0.0);
	vec3 best_T = vec3(1.0);
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 c = clamp(base + ivec2(i, j), ivec2(0), p.low_size - 1);
			vec4 s = imageLoad(inscatter_in, c);
			vec3 t = imageLoad(trans_in, c).rgb;
			float bw = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
			float dz = abs(s.a - z0) / max(z0, 1e-3);
			float w = bw * exp(-dz * p.depth_sharpness) + 1e-6 * bw;
			ins += s.rgb * w;
			T += t * w;
			wsum += w;
			if (dz < best_dz) {
				best_dz = dz;
				best_ins = s.rgb;
				best_T = t;
			}
		}
	}
	// If no neighbour matches this depth (thin edge), fall back to the closest in depth.
	if (wsum < 1e-4) {
		ins = best_ins;
		T = best_T;
	} else {
		ins /= wsum;
		T /= wsum;
	}
	if (all(greaterThanEqual(T, vec3(0.9999))) && all(lessThanEqual(ins, vec3(1e-6)))) {
		return;
	}
	vec4 col = imageLoad(color_image, px);
	imageStore(color_image, px, vec4(col.rgb * T + ins, col.a));
}
