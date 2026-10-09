shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

uniform vec3 edge_tint : source_color = vec3(0.85, 0.95, 0.9);
uniform float roughness_val = 0.02;

// Water seen through the glass (HPWater-style per-pixel volumetrics):
// clip the view segment glass -> opaque scene to the water box, then apply
// Beer-Lambert extinction plus single-scatter in-scatter toward water_color.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 water_min = vec3(-0.6, 0.0, -0.225);   // world-space water AABB
uniform vec3 water_max = vec3(0.6, 0.42, 0.225);
uniform vec3 absorption = vec3(0.45, 0.07, 0.03);   // 1/m, WaterOptics
uniform vec3 scattering = vec3(0.04, 0.05, 0.06);
uniform float density_scale : hint_range(0.0, 50.0) = 8.0;
uniform vec3 water_color : source_color = vec3(0.05, 0.32, 0.36);
uniform float max_path = 3.0;

vec2 ray_box(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax) {
	vec3 inv = 1.0 / rd;
	vec3 t0 = (bmin - ro) * inv;
	vec3 t1 = (bmax - ro) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	return vec2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
}

void fragment() {
	float c = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float F = 0.04 + 0.96 * pow(1.0 - c, 5.0);

	// World-space glass point and opaque scene point behind it.
	float d = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vs = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	vs.xyz /= vs.w;
	vec3 p_scene = (INV_VIEW_MATRIX * vec4(vs.xyz, 1.0)).xyz;

	// Ray from the CAMERA (not this glass face) so every overlapping pane
	// computes the identical path — result is independent of the
	// transparent sort order, which flips as the camera moves.
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 seg = p_scene - cam;
	float seg_len = length(seg);
	vec3 rd = seg / max(seg_len, 1e-5);
	vec2 t = ray_box(cam, rd, water_min, water_max);
	float t0 = max(t.x, 0.0);
	float t1 = min(t.y, seg_len);
	float path = clamp(t1 - t0, 0.0, max_path);

	vec3 sig_t = (absorption + scattering) * density_scale;
	vec3 T = exp(-sig_t * path);
	vec3 bg = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	vec3 through = bg * T + water_color * (vec3(1.0) - T);

	ALBEDO = edge_tint * F;
	ROUGHNESS = roughness_val;
	SPECULAR = 0.5;
	EMISSION = through * (1.0 - F);
	ALPHA = 1.0;
}
