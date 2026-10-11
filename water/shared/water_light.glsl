// Key light geometry shared by the caustic splat and the volume march.
// Mirrors water_light_entry() in underwater.gdshaderinc. Keep the two in sync.
//
// The key light is either
//   directional (mode 0): every underwater ray travels along the same refracted
//     direction Lw (toward the light, below the surface), or
//   local (mode 1): a point / short bar light at tank-space position P above the
//     rest surface, like an aquarium hood. Rays diverge from P and bend at the
//     surface, so each underwater point has its own entry point and direction.
//
// Every caustic / light-depth texel is a point on the rest surface (an "entry
// point"). wl_entry() maps an underwater point q back to its entry point.

// Exact Snell inverse for a point light: find the entry point e on the plane
// y = surf whose refracted ray from P passes through q. 1D Newton on the
// horizontal offset a = |e - P.xz| along the direction from P to q, starting
// from the paraxial (virtual source at height n*h) guess. 3 iterations reach
// sub-micrometre error for tank-sized geometry.
// Returns xy = entry xz, z = in-water distance entry -> q. Lw = unit direction
// from q toward the light (in water).
vec3 wl_entry_local(vec3 q, vec3 P, float surf, float ior, out vec3 Lw) {
	float h = max(P.y - surf, 1e-3);
	float D = max(surf - q.y, 0.0);
	vec2 r = q.xz - P.xz;
	float R = length(r);
	vec2 rh = R > 1e-6 ? r / R : vec2(1.0, 0.0);
	float a = R / (1.0 + D / (ior * h));
	for (int i = 0; i < 3; i++) {
		float la = sqrt(a * a + h * h);
		float s = a / (la * ior);
		float cw = sqrt(max(1.0 - s * s, 1e-6));
		float f = a + D * s / cw - R;
		float df = 1.0 + D * h * h / (la * la * la * ior * cw * cw * cw);
		a = clamp(a - f / df, 0.0, R);
	}
	float la = sqrt(a * a + h * h);
	float s = a / (la * ior);
	float cw = sqrt(max(1.0 - s * s, 1e-6));
	Lw = vec3(-rh.x * s, cw, -rh.y * s);
	return vec3(P.xz + rh * a, D / cw);
}

// light_pos.w: 0 = directional (Lw_dir used), 1 = local (light_pos.xyz used).
vec3 wl_entry(vec3 q, vec4 light_pos, vec3 Lw_dir, float surf, float ior, out vec3 Lw) {
	if (light_pos.w > 0.5) {
		return wl_entry_local(q, light_pos.xyz, surf, ior, Lw);
	}
	Lw = Lw_dir;
	float dist = max(surf - q.y, 0.0) / max(Lw_dir.y, 0.05);
	return vec3(q.xz + Lw_dir.xz * dist, dist);
}
