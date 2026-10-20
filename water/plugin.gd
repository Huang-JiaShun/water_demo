@tool
extends EditorPlugin
## Declares the water_* global shader parameters (WaterGlobals.DECLARATIONS) in
## project.godot [shader_globals] so the water shaders compile in any project.


func _enable_plugin() -> void:
	for name: StringName in WaterGlobals.DECLARATIONS:
		var key := "shader_globals/" + name
		if ProjectSettings.has_setting(key):
			continue
		var decl: Array = WaterGlobals.DECLARATIONS[name]
		ProjectSettings.set_setting(key, {type = decl[0], value = decl[1]})
		RenderingServer.global_shader_parameter_add(name, _type_of(decl[0]), decl[1])
	ProjectSettings.save()


func _disable_plugin() -> void:
	for name: StringName in WaterGlobals.DECLARATIONS:
		var key := "shader_globals/" + name
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			RenderingServer.global_shader_parameter_remove(name)
	ProjectSettings.save()


static func _type_of(type: String) -> RenderingServer.GlobalShaderParameterType:
	match type:
		"float": return RenderingServer.GLOBAL_VAR_TYPE_FLOAT
		"int": return RenderingServer.GLOBAL_VAR_TYPE_INT
		"vec3": return RenderingServer.GLOBAL_VAR_TYPE_VEC3
		"vec4": return RenderingServer.GLOBAL_VAR_TYPE_VEC4
		"mat4": return RenderingServer.GLOBAL_VAR_TYPE_MAT4
		"sampler2D": return RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D
	push_error("Water: unknown global shader type %s" % type)
	return RenderingServer.GLOBAL_VAR_TYPE_FLOAT
