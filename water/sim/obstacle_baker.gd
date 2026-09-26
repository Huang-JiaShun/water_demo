@tool
class_name ObstacleBaker
extends RefCounted
## Marks sim texels where solid decor pokes through the water surface.
## Those texels become Neumann walls in the wave equation.
##
## Design note: the architecture doc proposed an ortho SubViewport depth bake.
## For a one-off (or rare) bake, downward physics raycasts are simpler and exact.
## They need no render round trip, no GPU readback and no special depth
## material. The cost is ~sim texel count rays, i.e. about 32k at 256x128 and
## a few ms. Decor must have collision shapes on `collision_mask`.


## Returns an Image (FORMAT_R8) where 255 = water, 0 = solid at the surface.
## band: how far below the rest surface (m) an object still counts as a wall.
## Rocks just under the surface still block ripples visibly.
static func bake(body: WaterBody, size: Vector2i, collision_mask: int, band := 0.01) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_R8)
	img.fill(Color(1, 0, 0))
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return img

	var xf := body.global_transform
	var ts := body.tank_size
	var top := ts.y + 0.05
	var bottom := body.water_depth - band
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = collision_mask
	q.collide_with_areas = false
	q.hit_from_inside = true
	q.hit_back_faces = true

	for y in size.y:
		var lz := ((y + 0.5) / size.y - 0.5) * ts.z
		for x in size.x:
			var lx := ((x + 0.5) / size.x - 0.5) * ts.x
			q.from = xf * Vector3(lx, top, lz)
			q.to = xf * Vector3(lx, bottom, lz)
			if not space.intersect_ray(q).is_empty():
				img.set_pixel(x, y, Color(0, 0, 0))
	return img
