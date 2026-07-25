@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"shader.create": _create,
		"shader.read": _read,
		"shader.edit": _edit,
		"shader.assign_material": _assign_material,
		"shader.set_param": _set_param,
		"shader.get_params": _get_params,
		"shader.global_add": _global_add,
		"shader.global_set": _global_set,
		"shader.global_list": _global_list,
		"shader.global_remove": _global_remove,
		"shader.create_visual": _create_visual,
	}


# --- Global shader parameters (project-wide uniforms) -----------------------
# Stored where the editor's Shader Globals inspector keeps them:
# ProjectSettings shader_globals/<name> = {"type": <typename>, "value": <value>}.

const _GLOBAL_TYPES := {
	"bool": TYPE_BOOL, "int": TYPE_INT, "uint": TYPE_INT, "float": TYPE_FLOAT,
	"vec2": TYPE_VECTOR2, "vec3": TYPE_VECTOR3, "vec4": TYPE_VECTOR4, "color": TYPE_COLOR,
	"mat2": TYPE_TRANSFORM2D, "mat3": TYPE_BASIS, "mat4": TYPE_PROJECTION,
	"sampler2D": TYPE_STRING, "samplerCube": TYPE_STRING,
}


func _global_key(name: String) -> String:
	return "shader_globals/" + name


func _parse_global_value(type: String, raw: Variant) -> Variant:
	var vt: int = _GLOBAL_TYPES.get(type, TYPE_NIL)
	if type.begins_with("sampler"):
		return str(raw)  # texture path
	if raw is String:
		return PropertyParser.parse_value(raw, vt)
	return raw


func _global_add(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var name: String = rn[0]
	var type := optional_string(params, "type", "float")
	if not _GLOBAL_TYPES.has(type):
		return error_invalid_params("type must be one of %s" % [_GLOBAL_TYPES.keys()])
	var key := _global_key(name)
	if ProjectSettings.has_setting(key) and not optional_bool(params, "force", false):
		return error_conflict("Global shader param '%s' already exists" % name, {"suggestion": "Use shader.global_set, or pass force=true"} as Dictionary)

	var value: Variant = _parse_global_value(type, params.get("value", null))
	ProjectSettings.set_setting(key, {"type": type, "value": value})
	ProjectSettings.save()
	return success({"name": name, "type": type, "value": str(value), "added": true})


func _global_set(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var name: String = rn[0]
	var key := _global_key(name)
	if not ProjectSettings.has_setting(key):
		return error_not_found("Global shader param '%s'" % name, "Create it with shader.global_add")
	var entry: Variant = ProjectSettings.get_setting(key)
	if not entry is Dictionary:
		return error_internal("Malformed shader_globals entry")
	var type := str((entry as Dictionary).get("type", "float"))
	var value: Variant = _parse_global_value(type, params.get("value", null))
	(entry as Dictionary)["value"] = value
	ProjectSettings.set_setting(key, entry)
	ProjectSettings.save()
	# Live update so open shaders see it without a reload.
	if RenderingServer.global_shader_parameter_get_list().has(StringName(name)):
		RenderingServer.global_shader_parameter_set(name, value)
	return success({"name": name, "type": type, "value": str(value), "updated": true})


func _global_list(_params: Dictionary) -> Dictionary:
	var out: Array = []
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop.get("name", "")
		if pname.begins_with("shader_globals/"):
			var entry: Variant = ProjectSettings.get_setting(pname)
			var rec := {"name": pname.trim_prefix("shader_globals/")}
			if entry is Dictionary:
				rec["type"] = (entry as Dictionary).get("type", "")
				rec["value"] = str((entry as Dictionary).get("value", ""))
			out.append(rec)
	return success({"count": out.size(), "globals": out})


func _global_remove(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var name: String = rn[0]
	var key := _global_key(name)
	if not ProjectSettings.has_setting(key):
		return success({"name": name, "was_present": false})
	ProjectSettings.set_setting(key, null)
	ProjectSettings.save()
	return success({"name": name, "removed": true})


# --- create_visual (VisualShader resource) ----------------------------------

const _SHADER_MODES := {"spatial": 0, "canvas_item": 1, "particles": 2, "sky": 3, "fog": 4}


func _create_visual(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not (path.ends_with(".tres") or path.ends_with(".res")):
		return error_invalid_params("path must end in .tres or .res")
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard
	if FileAccess.file_exists(path) and not optional_bool(params, "force", false):
		return error_conflict("'%s' already exists" % path, {"suggestion": "pass force=true"} as Dictionary)

	var mode := optional_string(params, "mode", "spatial")
	if not _SHADER_MODES.has(mode):
		return error_invalid_params("mode must be one of %s" % [_SHADER_MODES.keys()])
	var vs := VisualShader.new()
	vs.mode = _SHADER_MODES[mode]

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := ResourceSaver.save(vs, path)
	if err != OK:
		return error_internal("Failed to save VisualShader: %s" % error_string(err))
	EditorInterface.get_resource_filesystem().update_file(path)
	return success({"path": path, "mode": mode, "created": true, "note": "Empty VisualShader graph — assign it to a ShaderMaterial; author nodes in the editor's VisualShader graph, or write a text shader with shader.create for code-first work."})


const _SHADER_TEMPLATES := {
	"spatial": "shader_type spatial;\n\nvoid vertex() {\n\t// Called for every vertex\n}\n\nvoid fragment() {\n\t// Called for every pixel\n\tALBEDO = vec3(1.0);\n}\n",
	"canvas_item": "shader_type canvas_item;\n\nvoid vertex() {\n\t// Called for every vertex\n}\n\nvoid fragment() {\n\t// Called for every pixel\n\tCOLOR = vec4(1.0);\n}\n",
	"particles": "shader_type particles;\n\nvoid start() {\n\t// Called when particle spawns\n}\n\nvoid process() {\n\t// Called every frame per particle\n}\n",
	"sky": "shader_type sky;\n\nvoid sky() {\n\tCOLOR = vec3(0.3, 0.5, 0.8);\n}\n",
}


func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	var shader_type := optional_string(params, "shader_type", "spatial")
	var content := optional_string(params, "content", "")
	var force := optional_bool(params, "force", false)

	var path_guard := guard_project_path(path)
	if not path_guard.is_empty():
		return path_guard

	var guard := guard_text_resource_write(path, force)
	if not guard.is_empty():
		return guard

	if content.is_empty():
		content = _SHADER_TEMPLATES.get(shader_type, "")

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return error_internal("Cannot create shader: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(content)
	file.close()

	_refresh_loaded_shader(path, content)

	return success({"path": path, "shader_type": shader_type, "created": true})


func _read(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	if not FileAccess.file_exists(path):
		return error_not_found("Shader '%s'" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return error_internal("Cannot read shader: %s" % error_string(FileAccess.get_open_error()))
	var content := file.get_as_text()
	file.close()

	return success({"path": path, "content": content, "size": content.length()})


func _edit(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	if not FileAccess.file_exists(path):
		return error_not_found("Shader '%s'" % path)

	var force := optional_bool(params, "force", false)
	var guard := guard_text_resource_write(path, force)
	if not guard.is_empty():
		return guard

	var changes_made := 0
	var content := ""

	if params.has("content"):
		content = str(params["content"])
		changes_made = 1
	elif params.has("replacements") and params["replacements"] is Array:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return error_internal("Cannot read shader")
		content = file.get_as_text()
		file.close()

		for replacement in params["replacements"]:
			if replacement is Dictionary:
				var search := str(replacement.get("search", ""))
				var replace := str(replacement.get("replace", ""))
				if not search.is_empty() and content.contains(search):
					content = content.replace(search, replace)
					changes_made += 1

	if changes_made > 0:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return error_internal("Cannot write shader: %s" % error_string(FileAccess.get_open_error()))
		file.store_string(content)
		file.close()
		_refresh_loaded_shader(path, content)

	return success({"path": path, "changes_made": changes_made})


func _assign_material(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node_path: String = rn[0]

	var rs := require_string(params, "shader_path")
	if rs[1] != null:
		return rs[1]
	var shader_path: String = rs[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := find_node_by_path(node_path)
	if node == null:
		return error_not_found("Node at '%s'" % node_path)

	if not ResourceLoader.exists(shader_path):
		return error_not_found("Shader '%s'" % shader_path)
	var shader: Shader = load(shader_path)
	if shader == null:
		return error_internal("Failed to load shader")

	var material := ShaderMaterial.new()
	material.shader = shader

	var property := ""
	if node is CanvasItem:
		property = "material"
	elif node is MeshInstance3D:
		property = "material_override"
	elif "material" in node:
		property = "material"
	else:
		return error_invalid_params("Node '%s' (%s) does not support materials" % [node_path, node.get_class()])

	var old_value: Variant = node.get(property)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Assign shader material")
	undo_redo.add_do_property(node, property, material)
	undo_redo.add_do_reference(material)
	undo_redo.add_undo_property(node, property, old_value)
	undo_redo.commit_action()

	return success({"node_path": node_path, "shader_path": shader_path, "assigned": true})


func _set_param(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node_path: String = rn[0]

	var rp := require_string(params, "param")
	if rp[1] != null:
		return rp[1]
	var param_name: String = rp[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := find_node_by_path(node_path)
	if node == null:
		return error_not_found("Node at '%s'" % node_path)

	var material := _get_shader_material(node)
	if material == null:
		return error(-32000, "Node has no ShaderMaterial")

	var value: Variant = params.get("value")
	if value is String:
		var expr := Expression.new()
		if expr.parse(value) == OK:
			var parsed: Variant = expr.execute()
			if parsed != null:
				value = parsed

	material.set_shader_parameter(param_name, value)

	return success({"node_path": node_path, "param": param_name, "value": str(value)})


func _get_params(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node_path: String = rn[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := find_node_by_path(node_path)
	if node == null:
		return error_not_found("Node at '%s'" % node_path)

	var material := _get_shader_material(node)
	if material == null:
		return error(-32000, "Node has no ShaderMaterial")

	var shader_params: Dictionary = {}
	for prop in material.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("shader_parameter/"):
			shader_params[pname.substr(17)] = str(material.get(pname))

	return success({"node_path": node_path, "params": shader_params})


# --- Helpers ----------------------------------------------------------------

func _get_shader_material(node: Node) -> ShaderMaterial:
	if node is CanvasItem and (node as CanvasItem).material is ShaderMaterial:
		return (node as CanvasItem).material
	if node is MeshInstance3D and (node as MeshInstance3D).material_override is ShaderMaterial:
		return (node as MeshInstance3D).material_override
	return null


func _refresh_loaded_shader(path: String, content: String) -> void:
	var normalized := normalize_project_path(path)
	if normalized.is_empty():
		return
	if ResourceLoader.has_cached(normalized):
		var shader := Shader.new()
		shader.code = content
		shader.take_over_path(normalized)
		shader.emit_changed()
	EditorInterface.get_resource_filesystem().update_file(normalized)


func get_command_docs() -> Dictionary:
	return {
		"shader.create": {
			"description": "Write a new text shader (.gdshader) file. Uses --content, or a starter template for --shader-type when content is omitted. Refuses to clobber a file open in the script editor without --force.",
			"params": [
				doc_param("path", "String", true, "Save path for the shader (inside the project)."),
				doc_param("shader_type", "String", false, "Template to seed when --content is empty: spatial (default), canvas_item, particles, sky."),
				doc_param("content", "String", false, "Full shader source (overrides the template)."),
				doc_param("force", "bool", false, "Overwrite even if the file is open in the script editor."),
			],
		},
		"shader.read": {
			"description": "Read a shader file's source text.",
			"params": [
				doc_param("path", "String", true, "Path to the shader file."),
			],
		},
		"shader.edit": {
			"description": "Rewrite a shader with --content, or apply --replacements (search/replace pairs) to the existing source. Refuses a file open in the script editor without --force.",
			"params": [
				doc_param("path", "String", true, "Path to the shader file."),
				doc_param("content", "String", false, "Full replacement source. Use this OR --replacements."),
				doc_param("replacements", "Array", false, "Array of {search, replace} objects applied in order. Use instead of --content."),
				doc_param("force", "bool", false, "Overwrite even if the file is open in the script editor."),
			],
		},
		"shader.assign_material": {
			"description": "Wrap a shader in a fresh ShaderMaterial and assign it to a node's material slot (CanvasItem/MeshInstance3D/other with a `material`). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("shader_path", "String", true, "Path to the shader resource to assign."),
			],
		},
		"shader.set_param": {
			"description": "Set a uniform on a node's ShaderMaterial. A string --value is evaluated as an Expression (so 'Vector3(1,0,0)', numbers, etc. work).",
			"params": [
				doc_param("node_path", "NodePath", true, "Node with a ShaderMaterial."),
				doc_param("param", "String", true, "Uniform name."),
				doc_param("value", "JSON", false, "Value to set (string is Expression-evaluated; may be null/omitted)."),
			],
		},
		"shader.get_params": {
			"description": "List the shader-parameter uniforms and their current values on a node's ShaderMaterial.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node with a ShaderMaterial."),
			],
		},
		"shader.global_add": {
			"description": "Add a project-wide global shader uniform (stored in ProjectSettings shader_globals/*). Writes and saves project.godot — a persistent side effect; revert after throwaway tests. Refuses an existing name without --force.",
			"params": [
				doc_param("name", "String", true, "Global uniform name."),
				doc_param("type", "String", false, "One of bool, int, uint, float (default), vec2, vec3, vec4, color, mat2, mat3, mat4, sampler2D, samplerCube."),
				doc_param("value", "JSON", false, "Initial value (a sampler type takes a texture path string)."),
				doc_param("force", "bool", false, "Overwrite an existing global of this name."),
			],
		},
		"shader.global_set": {
			"description": "Update an existing global shader uniform's value (keeps its type) and live-update the RenderingServer. Writes and saves project.godot.",
			"params": [
				doc_param("name", "String", true, "Existing global uniform name."),
				doc_param("value", "JSON", false, "New value (coerced toward the stored type)."),
			],
		},
		"shader.global_list": {
			"description": "List all global shader uniforms (name, type, value) defined in the project.",
			"params": [],
		},
		"shader.global_remove": {
			"description": "Remove a global shader uniform from the project (saves project.godot). No error if it wasn't present.",
			"params": [
				doc_param("name", "String", true, "Global uniform name to remove."),
			],
		},
		"shader.create_visual": {
			"description": "Create an empty VisualShader resource (.tres/.res) of a given mode — author its graph in the editor's VisualShader panel, or use shader.create for code-first work. Refuses to overwrite without --force.",
			"params": [
				doc_param("path", "String", true, "Save path (must end in .tres or .res)."),
				doc_param("mode", "String", false, "One of spatial (default), canvas_item, particles, sky, fog."),
				doc_param("force", "bool", false, "Overwrite an existing file."),
			],
		},
	}
