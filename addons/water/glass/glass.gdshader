shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;
#include "res://addons/water/shared/water_view.gdshaderinc"

// The glass owns only its own look (Fresnel, tint, roughness). The water seen
// through it comes from water_view.gdshaderinc, fed by WaterGlobals.
uniform vec3 edge_tint : source_color = vec3(0.85, 0.95, 0.9);
uniform float roughness_val = 0.02;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

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
	// Live surface height at this glass point: waves plus the meniscus, the same
	// displacement the surface shader applies, so the waterline on the pane meets
	// the curved surface exactly.
	vec3 p_glass = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 q = water_tank_pos(p_glass);
	float live = water_live_height(q);

	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 seg = p_scene - cam;
	float seg_len = length(seg);
	vec3 rd = seg / max(seg_len, 1e-5);
	// The box top follows the live height here, so the band where waves or the
	// meniscus lift the water above rest is tinted too instead of left clear.
	float path = water_view_path(cam, rd, seg_len, max(live, water_surface_height));
	vec3 bg = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	vec3 through = water_view_tint_apply(bg, path);

	// If the ray enters the water through its top face, the first thing seen
	// behind the glass is the water SURFACE (a transparent pass that screen_tex
	// doesn't contain). Act as plain clear glass there so the surface shader
	// shows through, instead of painting the underwater tint over it.
	// Tested where the ray reaches the inner wall, not at this face: looking down
	// at an angle, a ray can cross the outer face above the waterline and still
	// drop below it inside the pane, entering through the wall (no surface hit).
	vec3 w = water_wall_entry(cam, rd);
	float above = w.y - water_live_height(w);
	float aa = max(fwidth(above), 1e-4);
	float via_top = smoothstep(-aa, aa, above);

	ALBEDO = edge_tint * F;
	ROUGHNESS = roughness_val;
	SPECULAR = 0.5;
	EMISSION = through * (1.0 - F) * (1.0 - via_top);
	ALPHA = mix(1.0, F, via_top);
}
