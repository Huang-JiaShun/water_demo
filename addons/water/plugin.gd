@tool
extends EditorPlugin
## Declares the water global shader parameters (WaterGlobals.DECLARATIONS) in
## project.godot so water shaders compile in any project the addon is copied into.

const WaterGlobalsScript := preload("core/water_globals.gd")


func _enable_plugin() -> void:
	var added := false
	for name: StringName in WaterGlobalsScript.DECLARATIONS:
		var key := "shader_globals/" + name
		if ProjectSettings.has_setting(key):
			continue
		var decl: Array = WaterGlobalsScript.DECLARATIONS[name]
		ProjectSettings.set_setting(key, {type = decl[0], value = decl[1]})
		added = true
	if added:
		ProjectSettings.save()


func _disable_plugin() -> void:
	for name: StringName in WaterGlobalsScript.DECLARATIONS:
		ProjectSettings.set_setting("shader_globals/" + name, null)
	ProjectSettings.save()
