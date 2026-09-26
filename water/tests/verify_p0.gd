extends SceneTree
## Headless-ish P0 check: runs the demo scene, injects a splat, reads the wave
## texture back and verifies (1) non-zero response, (2) troughs exist (no clamp
## to >= 0), (3) the obstacle mask marked the rock, (4) energy decays.
## Run: godot --path . --script res://water/tests/verify_p0.gd

var body: WaterBody
var frame := 0
var peak := 0.0
var seen_min := 0.0
var seen_max := 0.0


func _initialize() -> void:
	var scene: Node = load("res://water/demo/aquarium_demo.tscn").instantiate()
	scene.get_node("Disturber").drop_rate = 0.0
	root.add_child(scene)
	body = scene.get_node("WaterBody")


func _read() -> Image:
	var rd := RenderingServer.get_rendering_device()
	var rid := body.sim.output_texture.texture_rd_rid
	if not rid.is_valid():
		return null
	var s := body.sim.size
	return Image.create_from_data(s.x, s.y, false, Image.FORMAT_RGBAH, rd.texture_get_data(rid, 0))


func _stats(img: Image) -> Dictionary:
	var mn := 1e9
	var mx := -1e9
	var solid := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			mn = minf(mn, c.r)
			mx = maxf(mx, c.r)
			if c.a < 0.5:
				solid += 1
	return {min = mn, max = mx, solid = solid}


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 30:
		body.disturb(body.global_transform * Vector3(-0.3, body.water_depth, 0.0), 0.02, -0.004)
	if frame in [40, 60, 400]:
		var img := _read()
		if img == null:
			print("FAIL: no texture")
			return true
		var st := _stats(img)
		seen_min = minf(seen_min, st.min)
		seen_max = maxf(seen_max, st.max)
		print("frame %d  min=%.5f  max=%.5f  solid_texels=%d  size=%s" % [frame, st.min, st.max, st.solid, body.sim.size])
		if frame == 60:
			peak = maxf(absf(st.min), st.max)
			print("  response: ", "OK" if peak > 1e-4 else "FAIL")
			print("  rock obstacle baked: ", "OK" if st.solid > 0 else "FAIL")
		if frame == 400:
			var now := maxf(absf(st.min), st.max)
			# An initial push-down first spreads as a dip; crests form later.
			print("  troughs & crests (whole run): ", "OK" if seen_min < -1e-5 and seen_max > 1e-5 else "FAIL")
			print("  decays: ", "OK" if now < peak * 0.5 else "FAIL", "  (%.5f -> %.5f)" % [peak, now])
			return true
	return false
