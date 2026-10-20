@tool
class_name LightDepthBaker
extends RefCounted
## Bakes the caustic light-depth map: for every caustic texel (a point on the
## rest surface), the distance along the flat-surface refracted key-light ray to
## the first solid. Directional lights share one ray direction; for a local light
## each texel refracts the ray coming from the light position.
##
## Design note: like ObstacleBaker, this uses physics raycasts rather than an
## ortho SubViewport depth render. The bake runs only when the light moves, it is
## exact, and it needs no GPU readback. Decor must have collision shapes on
## `collision_mask` to cast caustic shadows. Rays also stop at the tank floor
## and walls (the AABB).


## key: WaterCaustics.light_key(): xyz = tank-space unit vector toward the light,
## below the surface (Lw), w = 0; or xyz = local light position, w = 1.
## xf: tank transform (origin = floor centre). ts: inner tank size. surf: rest
## surface height in tank space. space may be null (walls and floor only).
static func bake(space: PhysicsDirectSpaceState3D, xf: Transform3D, ts: Vector3, surf: float,
		size: Vector2i, key: Vector4, collision_mask: int, ior := 1.333) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size.x * size.y)
	var local := key.w > 0.5
	var lp := Vector3(key.x, key.y, key.z)
	var d := -lp
	var hx := ts.x * 0.5
	var hz := ts.z * 0.5
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = collision_mask
	q.collide_with_areas = false
	q.hit_from_inside = true
	q.hit_back_faces = true

	for y in size.y:
		var lz := ((y + 0.5) / size.y - 0.5) * ts.z
		for x in size.x:
			var lx := ((x + 0.5) / size.x - 0.5) * ts.x
			var s := Vector3(lx, surf, lz)
			if local:
				# Flat-surface refraction of the ray from the light through s.
				var i := (s - lp).normalized()
				var t2 := Vector2(i.x, i.z) / ior
				d = Vector3(t2.x, -sqrt(maxf(1.0 - t2.length_squared(), 1e-6)), t2.y)
			var inv := Vector3(1.0 / d.x if absf(d.x) > 1e-6 else 1e9, 1.0 / d.y, 1.0 / d.z if absf(d.z) > 1e-6 else 1e9)
			# Exit distance through the floor or a wall.
			var tx := ((hx if d.x > 0.0 else -hx) - s.x) * inv.x
			var tz := ((hz if d.z > 0.0 else -hz) - s.z) * inv.z
			var ty := (0.0 - s.y) * inv.y
			var t := maxf(minf(minf(absf(tx), absf(tz)), ty), 0.0)
			if space:
				q.from = xf * s
				q.to = xf * (s + d * t)
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					t = (xf.affine_inverse() * (hit.position as Vector3)).distance_to(s)
			out[y * size.x + x] = t
	return out
