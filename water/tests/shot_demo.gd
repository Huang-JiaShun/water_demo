extends SceneTree
## Renders the aquarium demo from both cameras after the waves settle and saves
## screenshots to user:// (indoor tank light). Run with a window (needs a GPU):
##   godot --path . --script res://water/tests/shot_demo.gd [-- sun]

var scene: Node
var frame := 0


func _initialize() -> void:
	scene = load("res://water/demo/aquarium_demo.tscn").instantiate()
	root.add_child(scene)
	if "sun" in OS.get_cmdline_user_args():
		var body: WaterBody = scene.get_node("WaterBody")
		for l in body.tank_lights:
			l.visible = false
		(scene.get_node("DirectionalLight3D") as Node3D).visible = true
	root.size = Vector2i(1280, 720)


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 240:
		_save("above")
		(scene.get_node("CameraFront") as Camera3D).current = true
	if frame == 300:
		_save("front")
		return true
	return false


func _save(tag: String) -> void:
	var img := root.get_texture().get_image()
	var path := ProjectSettings.globalize_path("user://shot_%s.png" % tag)
	img.save_png(path)
	print("saved ", path)
