extends SceneTree
## P4 check:
##   - all volume passes compiled (temporal + à-trous)
##   - tier switching rebuilds the subsystems at the new resolutions
##   - HIGH tier: true-RGB caustics, channels differ under waves, green mean ~1
##   - temporal pass reprojects with motion vectors
##   - rendered frame with a moving camera: temporal pass stable (no NaN / black frame)
## Run: godot --path . --script res://tests/verify_p4.gd

var body: WaterBody
var frame := 0
var ok := true
var calm := PackedFloat32Array()
var cam: Camera3D


func _initialize() -> void:
	var scene: Node = load("res://demo/aquarium_demo.tscn").instantiate()
	scene.get_node("Disturber").drop_rate = 0.0
	root.add_child(scene)
	body = scene.get_node("WaterBody")


func _check(label: String, cond: bool) -> void:
	print("  ", label, ": ", "OK" if cond else "FAIL")
	ok = ok and cond


func _gain_rgb() -> Array[float]:
	var rd := RenderingServer.get_rendering_device()
	var rid := body.caustics.caustic_texture.texture_rd_rid
	if not rid.is_valid():
		return [0.0, 0.0, 0.0, 0.0]
	var d := rd.texture_get_data(rid, 0).to_float32_array()
	var s := body.caustics.size
	var sum := [0.0, 0.0, 0.0]
	var diff := 0.0
	var n := 0
	for y in range(s.y / 5, s.y * 4 / 5):
		for x in range(s.x / 5, s.x * 4 / 5):
			var i := (y * s.x + x) * 4
			# Skip texels where decor pierces the surface (no light enters).
			if not calm.is_empty() and calm[y * s.x + x] < 0.5:
				continue
			for c in 3:
				sum[c] += d[i + c]
			diff += absf(d[i] - d[i + 2])
			n += 1
	return [sum[0] / n, sum[1] / n, sum[2] / n, diff / n]


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 10:
		var v := body.volume
		print("volume passes:")
		_check("march/composite", v._march_pipeline.is_valid() and v._composite_pipeline.is_valid())
		_check("temporal", v._temporal_pipeline.is_valid())
		_check("denoise", v._denoise_pipeline.is_valid())
		_check("medium tier has temporal", body.quality.volume_temporal)
		_check("motion vectors used", v._used_motion_vectors)
		cam = root.get_viewport().get_camera_3d()
		body.set_tier(WaterQuality.Tier.HIGH)
	if frame == 30:
		print("HIGH tier:")
		_check("sim 512", body.sim.size.x == 512)
		_check("caustics 512", body.caustics.size.x == 512)
		_check("true RGB", body.caustics.is_true_rgb())
		var m := body._surface_material()
		_check("hq refraction on", m != null and m.get_shader_parameter(&"high_quality_refraction") == true)
		var raw := RenderingServer.get_rendering_device().texture_get_data(
				body.caustics.caustic_texture.texture_rd_rid, 0).to_float32_array()
		calm.resize(raw.size() / 4)
		for i in calm.size():
			calm[i] = raw[i * 4 + 1]
		var g := _gain_rgb()
		print("  calm gain rgb = %.3f %.3f %.3f" % [g[0], g[1], g[2]])
		_check("calm ~1", absf(g[1] - 1.0) < 0.1)
		for i in 6:
			body.disturb(body.global_transform * Vector3(-0.4 + i * 0.15, body.water_depth, 0.05 * (i % 2)), 0.02, -0.004)
	if cam and frame > 30 and frame < 70:
		cam.global_position.x += 0.01
	if frame == 70:
		var g := _gain_rgb()
		print("  waves gain rgb = %.3f %.3f %.3f  |r-b| = %.4f" % g)
		_check("dispersion separates r/b", g[3] > 0.005)
		_check("energy ~conserved", absf(g[1] - 1.0) < 0.15)
		var img := root.get_texture().get_image()
		var bad := 0
		var lum := 0.0
		for y in range(0, img.get_height(), 8):
			for x in range(0, img.get_width(), 8):
				var c := img.get_pixel(x, y)
				if is_nan(c.r) or is_nan(c.g) or is_nan(c.b):
					bad += 1
				lum += c.get_luminance()
		_check("frame has no NaN", bad == 0)
		_check("frame not black", lum > 1.0)
		img.save_png("user://verify_p4_high.png")
		body.set_tier(WaterQuality.Tier.LOW)
	if frame == 90:
		print("LOW tier:")
		_check("sim 128", body.sim.size.x == 128)
		_check("mono caustics", not body.caustics.is_true_rgb())
		_check("no temporal", not body.quality.volume_temporal)
		print("P4: ", "ALL OK" if ok else "FAILURES")
		return true
	return false
