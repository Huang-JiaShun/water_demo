@tool
class_name LightDepthBaker
extends RefCounted
## Bakes the caustic light-depth map: for every caustic texel (a point on the
## rest surface), the distance along the refracted sun ray to the first solid.
##
## Design note: like ObstacleBaker, this uses physics raycasts rather than an
## ortho SubViewport depth render. The bake runs only when the sun moves, it is
## exact, and it needs no GPU readback. Decor must have collision shapes on
## `collision_mask` to cast caustic shadows. Rays also stop at the tank floor
## and walls (the AABB).


## light_dir: tank-space unit vector toward the light, below the surface (Lw).
static func bake(body: WaterBody, size: Vector2i, light_dir: Vector3, collision_mask: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size.x * size.y)
	var ts := body.tank_size
	var surf := body.water_depth
	var d := -light_dir
	var hx := ts.x * 0.5
	var hz := ts.z * 0.5
	var space := body.get_world_3d().direct_space_state if body.is_inside_tree() else null
	var xf := body.global_transform
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = collision_mask
	q.collide_with_areas = false
	q.hit_from_inside = true
	q.hit_back_faces = true
	var inv := Vector3(1.0 / d.x if absf(d.x) > 1e-6 else 1e9, 1.0 / d.y, 1.0 / d.z if absf(d.z) > 1e-6 else 1e9)

	for y in size.y:
		var lz := ((y + 0.5) / size.y - 0.5) * ts.z
		for x in size.x:
			var lx := ((x + 0.5) / size.x - 0.5) * ts.x
			var s := Vector3(lx, surf, lz)
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
