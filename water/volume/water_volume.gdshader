// Water volume pass: Beer-Lambert absorption + single-scatter in-scatter for
// everything seen THROUGH the water body from outside (e.g. through the glass).
// Drawn on a box covering the tank interior (floor -> rest surface height).
// Top face is skipped when the camera is above the surface: that path is shaded
// by water_surface.gdshader (refraction + its own absorption).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

#include "res://water/shared/water_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 box_half_extents = vec3(0.6, 0.21, 0.225);
// Radiance of light scattered toward the viewer by the medium (ambient + sun, pre-phase).
uniform vec3 scatter_radiance : source_color = vec3(0.25, 0.3, 0.32);
uniform float scatter_strength = 1.0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

// Ray exit distance from an axis-aligned box (origin inside or on the box).
float box_exit(vec3 ro, vec3 rd, vec3 h) {
	vec3 inv = 1.0 / rd;
	vec3 t1 = (-h - ro) * inv;
	vec3 t2 = (h - ro) * inv;
	vec3 tmax = max(t1, t2);
	return min(min(tmax.x, tmax.y), tmax.z);
}

void fragment() {
	mat4 inv_model = inverse(MODEL_MATRIX);
	vec3 cam_local = (inv_model * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;

	// Top face seen from above: surface shader owns this path.
	if (cam_local.y > box_half_extents.y && local_pos.y > box_half_extents.y - 1e-3) {
		discard;
	}

	// Distance through the box along the view ray (local space == world scale for unscaled node).
	vec3 rd_local = normalize(local_pos - cam_local);
	float t_box = max(box_exit(local_pos, rd_local, box_half_extents), 0.0);

	// Distance to the opaque scene behind this fragment.
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_dist = length(view.xyz / view.w);
	float frag_dist = length(VERTEX);
	float t_scene = max(scene_dist - frag_dist, 0.0);

	float L = min(t_box, t_scene);

	vec3 sigma_t = water_sigma_a + water_sigma_s;
	vec3 T = exp(-sigma_t * L);
	// If the ray ends on a submerged object, its illumination also came down
	// through the water from the surface: attenuate by its depth below the top.
	if (t_scene < t_box) {
		vec3 hit = local_pos + rd_local * t_scene;
		float d = clamp(box_half_extents.y - hit.y, 0.0, 2.0 * box_half_extents.y);
		T *= exp(-sigma_t * d);
	}
	vec3 albedo = water_sigma_s / max(sigma_t, vec3(1e-4));
	vec3 inscatter = scatter_radiance * scatter_strength * albedo * (1.0 - T);

	vec3 bg = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	ALBEDO = bg * T + inscatter;
	ALPHA = 1.0;
}
