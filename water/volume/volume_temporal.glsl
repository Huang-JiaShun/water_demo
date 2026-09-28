#[compute]
#version 450
// Volume temporal reprojection (docs/water_architecture.md §6.3), low resolution.
//
// The march jitters its step positions per frame. Here each pixel's
// representative point (the opaque hit, or the middle of the water segment for
// background pixels) is rebuilt, moved into tank space and projected with the
// previous frame's camera. History is sampled there, rejected on a depth
// mismatch, clamped to the current 3x3 neighbourhood and blended.
//
// Reprojection goes through tank space, so a moving tank or camera both
// reproject correctly. Dynamic objects (fish) are handled by depth rejection
// rather than motion vectors: the fog in front of a fish changes slowly.
//
// Inputs:  march output (inscatter.rgb, lin depth) / (T.rgb, view distance of rep point)
//          previous history (same layout)
// Output:  new history (read by the composite / denoise, and next frame).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D ins_cur;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D trans_cur;
layout(set = 0, binding = 2) uniform sampler2D ins_hist;
layout(set = 0, binding = 3) uniform sampler2D trans_hist;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D ins_out;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D trans_out;

layout(set = 0, binding = 6, std140) uniform Params {
	mat4 inv_proj;          // current NDC -> view
	mat4 view_to_tank;      // current view -> tank
	mat4 prev_tank_to_view; // previous frame tank -> view
	mat4 prev_proj;         // previous frame view -> clip (Vulkan corrected)
	ivec4 sizes;            // xy = low-res size, z = 1: reset history
	vec4 params;            // x = min blend (static), y = max blend (fast motion), z = depth tolerance
} u;

const float SKY = 5e3;

void main() {
	ivec2 lo = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = u.sizes.xy;
	if (any(greaterThanEqual(lo, size))) {
		return;
	}
	vec4 ci = imageLoad(ins_cur, lo);
	vec4 ct = imageLoad(trans_cur, lo);
	float dist = ct.a;
	if (u.sizes.z != 0 || dist <= 0.0) {
		imageStore(ins_out, lo, ci);
		imageStore(trans_out, lo, ct);
		return;
	}

	vec2 uv = (vec2(lo) + 0.5) / vec2(size);
	vec4 far_v = u.inv_proj * vec4(uv * 2.0 - 1.0, 1e-6, 1.0);
	vec3 dir_view = normalize(far_v.xyz / far_v.w);
	vec4 p_tank = u.view_to_tank * vec4(dir_view * dist, 1.0);
	vec4 p_prev = u.prev_tank_to_view * p_tank;
	vec4 clip = u.prev_proj * p_prev;
	vec2 puv = clip.xy / clip.w * 0.5 + 0.5;
	bool valid = clip.w > 0.0 && all(greaterThanEqual(puv, vec2(0.0))) && all(lessThanEqual(puv, vec2(1.0)));

	vec4 hi = vec4(0.0);
	vec4 ht = vec4(1.0);
	if (valid) {
		hi = textureLod(ins_hist, puv, 0.0);
		ht = textureLod(trans_hist, puv, 0.0);
		if (ci.a > SKY) {
			valid = hi.a > SKY;
		} else {
			float expect = -p_prev.z;
			valid = abs(hi.a - expect) < u.params.z * max(expect, 1e-3);
		}
		valid = valid && ht.a > 0.0; // history had water here
	}
	if (!valid) {
		imageStore(ins_out, lo, ci);
		imageStore(trans_out, lo, ct);
		return;
	}

	// Neighbourhood clamp against ghosting. The box spans the per-pixel jitter
	// range, so converged history survives while stale history is pulled in.
	vec3 imin = ci.rgb, imax = ci.rgb;
	vec3 tmin = ct.rgb, tmax = ct.rgb;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			if (i == 0 && j == 0) {
				continue;
			}
			ivec2 q = clamp(lo + ivec2(i, j), ivec2(0), size - 1);
			vec4 a = imageLoad(ins_cur, q);
			vec4 b = imageLoad(trans_cur, q);
			if (b.a <= 0.0) {
				continue; // no water there: would widen the box with (0, 1)
			}
			imin = min(imin, a.rgb);
			imax = max(imax, a.rgb);
			tmin = min(tmin, b.rgb);
			tmax = max(tmax, b.rgb);
		}
	}
	vec3 hist_i = clamp(hi.rgb, imin, imax);
	vec3 hist_t = clamp(ht.rgb, tmin, tmax);

	float motion_px = length((puv - uv) * vec2(size));
	float a = mix(u.params.x, u.params.y, clamp(motion_px * 0.25, 0.0, 1.0));
	imageStore(ins_out, lo, vec4(mix(hist_i, ci.rgb, a), ci.a));
	imageStore(trans_out, lo, vec4(mix(hist_t, ct.rgb, a), ct.a));
}
