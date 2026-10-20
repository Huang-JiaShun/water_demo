@tool
class_name WaterRD
extends RefCounted
## Small RenderingDevice helpers shared by all water compute drivers.
## Every function here must be called on the render thread.


static func load_compute_shader(rd: RenderingDevice, path: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null:
		push_error("WaterRD: cannot load shader '%s'" % path)
		return RID()
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("WaterRD: '%s' failed to compile:\n%s" % [path, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


static func texture_format(size: Vector2i, format: RenderingDevice.DataFormat, usage: int) -> RDTextureFormat:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.format = format
	tf.width = size.x
	tf.height = size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = usage
	return tf


static func image_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(texture)
	return u


static func storage_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u


static func group_count(threads: int, local_size: int) -> int:
	@warning_ignore("integer_division")
	return (threads + local_size - 1) / local_size


## Packs push-constant data as std430: ints first, then floats, padded to 16 bytes.
static func push_constant(ints: PackedInt32Array, floats: PackedFloat32Array) -> PackedByteArray:
	var size := (ints.size() + floats.size()) * 4
	@warning_ignore("integer_division")
	size = ((size + 15) / 16) * 16
	var bytes := PackedByteArray()
	bytes.resize(size)
	var offset := 0
	for i in ints:
		bytes.encode_s32(offset, i)
		offset += 4
	for f in floats:
		bytes.encode_float(offset, f)
		offset += 4
	return bytes


## Frees owned resources. Uniform sets and pipelines are freed automatically
## by Godot when the textures/shaders they depend on are freed, so pass only
## textures, buffers and shaders here (textures/buffers before shaders).
static func free_rids(rd: RenderingDevice, rids: Array[RID]) -> void:
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)
