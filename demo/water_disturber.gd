class_name WaterDisturber
extends Node
## Demo input that feeds a WaterBody: mouse drag plus periodic drops.
## Fish and other gameplay objects call WaterBody.disturb() directly instead.

@export var body: WaterBody
@export_range(0.002, 0.1, 0.001, "suffix:m") var mouse_radius := 0.015
@export_range(-0.01, 0.01, 0.0001, "suffix:m") var mouse_strength := -0.0015
@export_range(0.002, 0.1, 0.001, "suffix:m") var drop_radius := 0.01
@export_range(-0.01, 0.01, 0.0001, "suffix:m") var drop_strength := -0.002
## Drops per second when the mouse is not pressed. 0 disables them.
@export_range(0.0, 30.0, 0.1) var drop_rate := 4.0
## Seconds after the last mouse input over which the drops and bubble pops fade out, letting the
## surface settle to calm. 0 keeps dropping forever.
@export_range(0.0, 60.0, 0.1, "suffix:s") var calm_time := 6.0

var _mouse_down := false
var _mouse_pos := Vector2.ZERO
var _drop_timer := 0.0
var _idle := 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_mouse_pos = event.position
		_idle = 0.0
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_down = event.pressed


func _process(delta: float) -> void:
	if body == null or Engine.is_editor_hint():
		return
	if _mouse_down:
		var cam := get_viewport().get_camera_3d()
		if cam:
			var hit: Variant = body.intersect_surface(cam.project_ray_origin(_mouse_pos),
					cam.project_ray_normal(_mouse_pos))
			if hit != null:
				body.disturb(hit, mouse_radius, mouse_strength * delta * 60.0)
	else:
		_idle += delta
	var calm := 1.0 if calm_time <= 0.0 else clampf(1.0 - _idle / calm_time, 0.0, 1.0)
	# Bubble pops under the body settle with the drops.
	for b in body.find_children("*", "GPUParticles3D", true, false):
		if b is WaterBubbles:
			b.pop_scale = calm
	if not _mouse_down and drop_rate > 0.0 and calm > 0.0:
		_drop_timer += delta
		var interval := 1.0 / drop_rate
		while _drop_timer >= interval:
			_drop_timer -= interval
			var ts := body.tank_size
			var local := Vector3(randf_range(-0.5, 0.5) * ts.x, body.water_depth, randf_range(-0.5, 0.5) * ts.z)
			body.disturb(body.global_transform * local, drop_radius, drop_strength * calm)
