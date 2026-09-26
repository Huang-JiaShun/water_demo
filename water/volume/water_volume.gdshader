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
// Fed each frame by water_volume_light.gd.
uniform vec3 sun_dir_local = vec3(0.35, 0.7, 0.6); // toward the sun, box space
uniform vec3 sun_irradiance = vec3(1.0);            // linear, above water
uniform vec3 ambient_radiance = vec3(0.3);          // linear, above water
uniform float scatter_strength = 1.0;

float hg_phase(float cos_t, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5));
}

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
	// Single scatter, with lighting evaluated at the segment midpoint.
	// The sun is refracted into the water (Snell) and attenuated along its slanted
	// path from the surface. Ambient light is treated as isotropic and attenuated vertically.
	vec3 Ls = normalize(sun_dir_local);
	float cos_air = max(Ls.y, 0.0);
	float eta = 1.0 / water_ior;
	float cos_w = sqrt(max(1.0 - eta * eta * (1.0 - cos_air * cos_air), 0.0));
	vec3 Lw = normalize(vec3(Ls.x * eta, cos_w, Ls.z * eta));
	float f0 = pow((water_ior - 1.0) / (water_ior + 1.0), 2.0);
	float Ft = 1.0 - (f0 + (1.0 - f0) * pow(1.0 - cos_air, 5.0));
	vec3 mid = local_pos + rd_local * (0.5 * L);
	float d_mid = clamp(box_half_extents.y - mid.y, 0.0, 2.0 * box_half_extents.y);
	vec3 sun_w = sun_irradiance * Ft * exp(-sigma_t * d_mid / max(cos_w, 0.05));
	vec3 amb_w = ambient_radiance * exp(-sigma_t * d_mid);
	float phase = hg_phase(dot(rd_local, Lw), water_phase_g);
	vec3 inscatter = scatter_strength * albedo * (1.0 - T) * (sun_w * phase + amb_w);

	vec3 bg = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	ALBEDO = bg * T + inscatter;
	ALPHA = 1.0;
}
