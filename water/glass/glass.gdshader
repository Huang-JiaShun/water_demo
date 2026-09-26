shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;
// Thin soda-lime glass: Schlick Fresnel (F0 ~0.04) drives opacity, so the
// pane is clear head-on and reflective/greener at grazing angles.
uniform vec3 edge_tint : source_color = vec3(0.85, 0.95, 0.9);
uniform float roughness_val = 0.02;
void fragment() {
	float c = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float F = 0.04 + 0.96 * pow(1.0 - c, 5.0);
	ALBEDO = edge_tint;
	ROUGHNESS = roughness_val;
	SPECULAR = 0.5;
	ALPHA = clamp(F, 0.0, 0.6);
}
