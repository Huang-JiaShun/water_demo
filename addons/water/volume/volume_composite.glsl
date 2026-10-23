#[compute]
#version 450
// Full-res reconstruction of the low-res volume result, then composite into the
// scene color: color = scene * T + inscatter.
//
// The low-res pass gives each texel an optical depth tau = -ln T and an
// in-scatter L over its own water path. Here they are turned back into medium
// coefficients: the effective extinction (absorption + scattering) sigma_t =
// tau / path, and the scattering source S = L / (1 - T). Both are joint
// bilateral upsampled, guided by full-res depth (no bleeding across the glass /
// foreground edges), and re-integrated over this pixel's exact water path:
//   T = exp(-sigma_t * path_full)      absorption: energy loss along the path
//   L = S * (1 - T)                    scattering: light added along the path
// so silhouettes and the waterline get the full-res path length instead of an
// interpolated transmittance.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D inscatter_in;
layout(rgba16f, set = 0, binding = 3) uniform restrict readonly image2D trans_in;

layout(set = 0, binding = 4, std140) uniform Geo {
	mat4 inv_proj;      // NDC (Vulkan, reversed-Z) -> view
	mat4 view_to_tank;  // view -> tank local
	vec4 tank_max;      // xyz = (half size x, rest surface height, half size z)
} g;

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

const float SKY = 5e3;

float linear_depth(float d) {
	if (d <= 0.0) {
		return 1e4;
	}
	return -(p.zc * d + p.zo) / (p.wc * d + p.wo);
}

// Water path length (tank units) the march integrates for the ray through uv
// ending at linear view depth z: the AABB-clipped segment plus, for a submerged
// hit, its depth below the surface (the light reaching it came down through
// the water too). Mirrors volume_march.glsl.
float water_path(vec2 uv, float z) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 far_v = g.inv_proj * vec4(ndc, 1e-6, 1.0);
	vec3 dir_view = normalize(far_v.xyz / far_v.w);
	vec3 ro = (g.view_to_tank * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 rd_raw = mat3(g.view_to_tank) * dir_view;
	float scale = length(rd_raw);
	vec3 rd = rd_raw / scale;
	float t_scene = z > SKY ? 1e6 : z / max(-dir_view.z, 1e-4) * scale;
	vec3 bmin = vec3(-g.tank_max.x, 0.0, -g.tank_max.z);
	vec3 bmax = g.tank_max.xyz;
	vec3 inv = 1.0 / rd;
	vec3 ta = (bmin - ro) * inv;
	vec3 tb = (bmax - ro) * inv;
	vec3 tmin3 = min(ta, tb);
	vec3 tmax3 = max(ta, tb);
	float t0 = max(max(max(tmin3.x, tmin3.y), tmin3.z), 0.0);
	float t_exit = min(min(tmax3.x, tmax3.y), tmax3.z);
	float t1 = min(t_exit, t_scene);
	if (t1 <= t0) {
		return 0.0;
	}
	float path = t1 - t0;
	if (t_scene < t_exit + 0.01) {
		vec3 hit = ro + rd * t_scene;
		path += clamp(g.tank_max.y - hit.y, 0.0, g.tank_max.y);
	}
	return path;
}

// The full-res texel the march took its depth from for low-res texel c.
vec2 low_uv(ivec2 c) {
	vec2 uv = (vec2(c) + 0.5) / vec2(p.low_size);
	ivec2 fp = min(ivec2(uv * vec2(p.full_size)), p.full_size - 1);
	return (vec2(fp) + 0.5) / vec2(p.full_size);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, p.full_size))) {
		return;
	}
	float z0 = min(linear_depth(texelFetch(depth_tex, px, 0).r), 6e4);
	vec2 uv0 = (vec2(px) + 0.5) / vec2(p.full_size);
	float path0 = water_path(uv0, z0);

	vec2 lp = (vec2(px) + 0.5) * vec2(p.low_size) / vec2(p.full_size) - 0.5;
	ivec2 base = ivec2(floor(lp));
	vec2 f = lp - vec2(base);

	// Weighted sums: sigma_t = sum(tau) / sum(path), S = sum(L) / sum(1 - T).
	// Ratios of sums stay stable where a texel's own path is near zero.
	vec3 tau = vec3(0.0);
	float len = 0.0;
	vec3 ins = vec3(0.0);
	vec3 opa = vec3(0.0);
	vec3 T_direct = vec3(0.0);
	float wsum = 0.0;
	float best_dz = 1e9;
	ivec2 best = base;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 c = clamp(base + ivec2(i, j), ivec2(0), p.low_size - 1);
			vec4 s = imageLoad(inscatter_in, c);
			vec3 t = clamp(imageLoad(trans_in, c).rgb, vec3(1e-6), vec3(1.0));
			float bw = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
			float dz = abs(s.a - z0) / max(z0, 1e-3);
			float w = bw * exp(-dz * p.depth_sharpness) + 1e-6 * bw;
			tau += -log(t) * w;
			len += water_path(low_uv(c), s.a) * w;
			ins += s.rgb * w;
			opa += (1.0 - t) * w;
			T_direct += t * w;
			wsum += w;
			if (dz < best_dz) {
				best_dz = dz;
				best = c;
			}
		}
	}
	// If no neighbour matches this depth (thin edge), fall back to the closest in depth.
	if (wsum < 1e-4) {
		vec4 s = imageLoad(inscatter_in, best);
		vec3 t = clamp(imageLoad(trans_in, best).rgb, vec3(1e-6), vec3(1.0));
		tau = -log(t);
		len = water_path(low_uv(best), s.a);
		ins = s.rgb;
		opa = 1.0 - t;
		T_direct = t;
		wsum = 1.0;
	}
	vec3 T;
	vec3 L;
	if (len > 1e-5 * wsum && path0 > 0.0) {
		T = exp(-(tau / len) * path0);
		// Channels with almost no opacity carry no usable source; keep the
		// interpolated in-scatter there.
		vec3 S = ins / max(opa, vec3(1e-4));
		L = mix(ins / wsum, S * (1.0 - T), step(vec3(1e-4), opa));
	} else if (path0 <= 0.0) {
		T = vec3(1.0);
		L = vec3(0.0);
	} else {
		T = T_direct / wsum;
		L = ins / wsum;
	}
	if (all(greaterThanEqual(T, vec3(0.9999))) && all(lessThanEqual(L, vec3(1e-6)))) {
		return;
	}
	vec4 col = imageLoad(color_image, px);
	imageStore(color_image, px, vec4(col.rgb * T + L, col.a));
}
