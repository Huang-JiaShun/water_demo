extends SceneTree
## P3 check: reads back the caustic gain texture and light-depth map.
##   calm water  -> gain ~1 everywhere lit (energy-conserving parameterisation)
##   after waves -> contrast appears, mean stays near 1
##   light depth -> the rock casts a shadow (some texels shorter than the floor path)
## Run: godot --path . --script res://tests/verify_p3.gd

var body: WaterBody
var frame := 0
var calm := PackedFloat32Array()


func _initialize() -> void:
	var scene: Node = load("res://demo/aquarium_demo.tscn").instantiate()
	scene.get_node("Disturber").drop_rate = 0.0
	root.add_child(scene)
	body = scene.get_node("WaterBody")


func _read(tex: Texture2DRD, channel := 0) -> PackedFloat32Array:
	var rd := RenderingServer.get_rendering_device()
	if not tex.texture_rd_rid.is_valid():
		return PackedFloat32Array()
	var all := rd.texture_get_data(tex.texture_rd_rid, 0).to_float32_array()
	var n := body.caustics.size.x * body.caustics.size.y
	if all.size() == n:
		return all
	# RGBA32F gain: pick one channel.
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = all[i * 4 + channel]
	return out


func _gain_stats() -> Dictionary:
	var g := _read(body.caustics.caustic_texture)
	var s := body.caustics.size
	var sum := 0.0
	var sq := 0.0
	var n := 0
	var mx := 0.0
	# Interior only: edges lose photons that land on side walls.
	for y in range(s.y / 5, s.y * 4 / 5):
		for x in range(s.x / 5, s.x * 4 / 5):
			var v := g[y * s.x + x]
			# Skip texels where decor pierces the surface (no light enters).
			if not calm.is_empty() and calm[y * s.x + x] < 0.5:
				continue
			sum += v
			sq += v * v
			mx = maxf(mx, v)
			n += 1
	var mean := sum / maxi(n, 1)
	return {mean = mean, std = sqrt(maxf(sq / maxi(n, 1) - mean * mean, 0.0)), max = mx}


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 20:
		calm = _read(body.caustics.caustic_texture)
		var st := _gain_stats()
		print("calm: mean=%.3f std=%.3f max=%.3f" % [st.mean, st.std, st.max])
		print("  calm uniform: ", "OK" if absf(st.mean - 1.0) < 0.1 and st.std < 0.15 else "FAIL")
		var d := _read(body.caustics.light_depth_texture)
		var mn := 1e9
		var mxd := 0.0
		for v in d:
			mn = minf(mn, v)
			mxd = maxf(mxd, v)
		print("light depth: min=%.3f max=%.3f  lit=%s dir=%s" % [mn, mxd, body.caustics.lit, body.caustics.light_dir])
		print("  rock shadow baked: ", "OK" if mn < 0.3 else "FAIL")
		for i in 6:
			body.disturb(body.global_transform * Vector3(-0.4 + i * 0.15, body.water_depth, 0.05 * (i % 2)), 0.02, -0.004)
	if frame == 60:
		var st := _gain_stats()
		print("waves: mean=%.3f std=%.3f max=%.3f" % [st.mean, st.std, st.max])
		print("  contrast: ", "OK" if st.std > 0.05 else "FAIL")
		print("  energy ~conserved: ", "OK" if absf(st.mean - 1.0) < 0.15 else "FAIL")
		return true
	return false
