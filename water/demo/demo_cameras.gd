extends Node
## Demo helper. Press C to switch between the above-water camera and the view
## through the front of the tank (below the waterline), which shows Snell's
## window and total internal reflection.

@export var cameras: Array[Camera3D] = []

var _index := 0


func _ready() -> void:
	if not cameras.is_empty():
		cameras[0].make_current()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		if cameras.is_empty():
			return
		_index = (_index + 1) % cameras.size()
		cameras[_index].make_current()
