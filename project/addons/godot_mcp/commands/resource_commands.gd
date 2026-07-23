@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"resource.read": _read,
		"resource.edit": _edit,
		"resource.create": _create,
		"resource.preview": _preview,
		"resource.find": _find,
		"resource.info": _info,
	}


# --- Discovery: type-filtered find + dependency/referencer graph -------------

## All project files known to the EditorFileSystem, as {path, type, script_class}.
## type is the stored resource class; script_class is the class_name for custom
## Resource scripts (empty otherwise). No resources are loaded.
func _all_files() -> Array:
	var out: Array = []
	var root := EditorInterface.get_resource_filesystem().get_filesystem()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var d: EditorFileSystemDirectory = stack.pop_back()
		for i in d.get_file_count():
			out.append({
				"path": d.get_file_path(i),
				"type": String(d.get_file_type(i)),
				"script_class": d.get_file_script_class_name(i),
			})
		for j in d.get_subdir_count():
			stack.append(d.get_subdir(j))
	return out


func _type_matches(file_type: String, script_class: String, requested: String) -> bool:
	if requested == file_type or requested == script_class:
		return true
	# inheritance: --type Texture2D matches a CompressedTexture2D file
	if ClassDB.class_exists(file_type) and ClassDB.class_exists(requested):
		return ClassDB.is_parent_class(file_type, requested)
	return false


## Extract the resolvable res:// path from a get_dependencies() entry, which can be
## "uid://x::Type::res://path", "res://path::Type::", or a bare path.
func _dep_path(entry: String) -> String:
	for part in entry.split("::"):
		if part.begins_with("res://") or part.begins_with("user://"):
			return part
	for part in entry.split("::"):
		if part.begins_with("uid://"):
			return ResourceUID.uid_to_path(part)
	return entry


func _find(params: Dictionary) -> Dictionary:
	var type_filter := optional_string(params, "type", "")
	var path_prefix := optional_string(params, "path", "res://")
	var name_filter := optional_string(params, "name", "").to_lower()
	var limit := optional_int(params, "limit", 100)

	var matched: Array = []
	for f: Dictionary in _all_files():
		var p: String = f["path"]
		if not p.begins_with(path_prefix):
			continue
		if not name_filter.is_empty() and not p.get_file().to_lower().contains(name_filter):
			continue
		if not type_filter.is_empty() and not _type_matches(f["type"], f["script_class"], type_filter):
			continue
		var entry := {"path": p, "type": f["type"]}
		if not String(f["script_class"]).is_empty():
			entry["script_class"] = f["script_class"]
		matched.append(entry)

	return success({
		"type": type_filter, "path": path_prefix,
		"total_matched": matched.size(), "truncated": matched.size() > limit,
		"resources": matched.slice(0, limit),
	})


func _info(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not FileAccess.file_exists(path):
		return error_not_found("Resource '%s'" % path)

	var files := _all_files()
	var ftype := ""
	var sclass := ""
	for f: Dictionary in files:
		if f["path"] == path:
			ftype = f["type"]
			sclass = f["script_class"]
			break

	var uid_id := ResourceLoader.get_resource_uid(path)
	var uid_text := ResourceUID.id_to_text(uid_id) if uid_id != ResourceUID.INVALID_ID else ""

	var deps: Array = []
	for d in ResourceLoader.get_dependencies(path):
		deps.append({"raw": d, "path": _dep_path(d)})

	# Referencers: scan every project file for a dependency on this path/uid. No
	# reverse index exists in the engine, so this is O(files) get_dependencies calls.
	var refs: Array = []
	if optional_bool(params, "referencers", true):
		for f: Dictionary in files:
			var fp: String = f["path"]
			if fp == path:
				continue
			for fd in ResourceLoader.get_dependencies(fp):
				if fd.contains(path) or (not uid_text.is_empty() and fd.contains(uid_text)):
					refs.append(fp)
					break

	var out := {
		"path": path, "type": ftype, "uid": uid_text,
		"dependencies": deps, "referencers": refs,
	}
	if not sclass.is_empty():
		out["script_class"] = sclass
	return success(out)


func _read(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	if not FileAccess.file_exists(path):
		return error_not_found("Resource '%s'" % path)

	var guard := guard_offline_scene_save(path)
	if not guard.is_empty():
		return guard

	var resource := ResourceLoader.load(path)
	if resource == null:
		return error_internal("Failed to load resource: %s" % path)

	var props: Dictionary = {}
	for prop_info in resource.get_property_list():
		var prop_name: String = prop_info["name"]
		if not (int(prop_info["usage"]) & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name.begins_with("_") or prop_name in ["script", "resource_local_to_scene", "resource_name", "resource_path"]:
			continue
		props[prop_name] = PropertyParser.serialize_value(resource.get(prop_name))

	return success({
		"path": path,
		"type": resource.get_class(),
		"resource_name": resource.resource_name,
		"properties": props,
	})


func _edit(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	var pr := require_dict(params, "properties")
	if pr[1] != null:
		return pr[1]
	var new_props: Dictionary = pr[0]

	if not FileAccess.file_exists(path):
		return error_not_found("Resource '%s'" % path)

	var guard := guard_offline_scene_save(path)
	if not guard.is_empty():
		return guard

	var resource := ResourceLoader.load(path)
	if resource == null:
		return error_internal("Failed to load resource: %s" % path)

	var changed: Dictionary = {}
	for prop_name: String in new_props:
		if not prop_name in resource:
			continue
		var old_value: Variant = resource.get(prop_name)
		var new_value: Variant = PropertyParser.parse_value(new_props[prop_name], typeof(old_value))
		resource.set(prop_name, new_value)
		changed[prop_name] = {
			"old": PropertyParser.serialize_value(old_value),
			"new": PropertyParser.serialize_value(resource.get(prop_name)),
		}

	if changed.is_empty():
		return success({"path": path, "changed": {}, "message": "No properties were changed"})

	var err := ResourceSaver.save(resource, path)
	if err != OK:
		return error_internal("Failed to save resource: %s" % error_string(err))

	return success({"path": path, "type": resource.get_class(), "changed": changed})


func _create(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "path")
	if rp[1] != null:
		return rp[1]
	var path: String = rp[0]

	var path_guard := guard_project_path(path)
	if not path_guard.is_empty():
		return path_guard

	var rt := require_string(params, "type")
	if rt[1] != null:
		return rt[1]
	var resource_type: String = rt[0]

	var overwrite := optional_bool(params, "overwrite", false)
	if FileAccess.file_exists(path) and not overwrite:
		return error(-32000, "Resource already exists: %s" % path, {"suggestion": "Set overwrite=true to replace"})

	var guard := guard_offline_scene_save(path)
	if not guard.is_empty():
		return guard

	var resource: Resource = make_resource(resource_type)
	if resource == null:
		return error_invalid_params("'%s' is not a known Resource type (a ClassDB class or a class_name Resource script)" % resource_type)

	var properties: Dictionary = params.get("properties", {})
	for prop_name: String in properties:
		if prop_name in resource:
			resource.set(prop_name, PropertyParser.parse_value(properties[prop_name], typeof(resource.get(prop_name))))

	var err := ResourceSaver.save(resource, path)
	if err != OK:
		return error_internal("Failed to save resource: %s" % error_string(err))

	EditorInterface.get_resource_filesystem().scan()

	return success({"path": path, "type": resource_type, "properties_set": properties.keys()})


func _preview(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	if not FileAccess.file_exists(path):
		return error_not_found("Resource '%s'" % path)

	var max_size := optional_int(params, "max_size", 256)
	var image: Image = null

	var ext := path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "bmp", "webp", "svg"]:
		image = Image.new()
		var err := image.load(path)
		if err != OK:
			return error_internal("Failed to load image: %s" % error_string(err))
	else:
		var resource := ResourceLoader.load(path)
		if resource == null:
			return error_internal("Failed to load resource: %s" % path)
		if resource is Texture2D:
			image = (resource as Texture2D).get_image()
		elif resource is Image:
			image = resource as Image
		else:
			return error_invalid_params("Resource type '%s' does not have an image preview" % resource.get_class())

	if image == null:
		return error_internal("Could not extract image from resource")

	if image.get_width() > max_size or image.get_height() > max_size:
		var scale := minf(float(max_size) / float(image.get_width()), float(max_size) / float(image.get_height()))
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)

	var png_buffer := image.save_png_to_buffer()
	var base64 := Marshalls.raw_to_base64(png_buffer)

	return success({
		"image_base64": base64,
		"width": image.get_width(),
		"height": image.get_height(),
		"format": "png",
		"path": path,
	})


func get_command_docs() -> Dictionary:
	return {
		"resource.read": {
			"description": "Load a resource file and return its editor-visible properties (serialized). Refuses a scene open in the editor.",
			"params": [
				doc_param("path", "String", true, "Path to the resource file to read."),
			],
		},
		"resource.edit": {
			"description": "Load a resource, set the given --properties (coerced per property type), and save it back. Skips property names the resource doesn't have. Refuses a scene open in the editor.",
			"params": [
				doc_param("path", "String", true, "Path to the resource file to edit."),
				doc_param("properties", "Dictionary", true, "{property: value} map to apply (values coerced toward each property's type)."),
			],
		},
		"resource.create": {
			"description": "Create and save a new Resource of --type (a ClassDB class or a class_name Resource script) with optional initial --properties. Refuses to overwrite without --overwrite.",
			"params": [
				doc_param("path", "String", true, "Save path (must be inside the project)."),
				doc_param("type", "String", true, "Resource class (ClassDB) or a class_name Resource script."),
				doc_param("properties", "Dictionary", false, "Initial {property: value} map."),
				doc_param("overwrite", "bool", false, "Replace an existing file at --path (default false)."),
			],
		},
		"resource.preview": {
			"description": "Return a base64 PNG preview of an image file, Texture2D, or Image resource, downscaled to fit --max-size.",
			"params": [
				doc_param("path", "String", true, "Path to an image/texture resource."),
				doc_param("max_size", "int", false, "Max width/height of the preview in pixels (default 256)."),
			],
		},
		"resource.find": {
			"description": "List project resources known to the EditorFileSystem, filtered by type (inheritance-aware), path prefix, and filename substring. No resources are loaded.",
			"params": [
				doc_param("type", "String", false, "Filter to this resource class or script class_name (matches subclasses, e.g. 'Texture2D')."),
				doc_param("path", "String", false, "Only paths beginning with this prefix (default 'res://')."),
				doc_param("name", "String", false, "Case-insensitive filename substring filter."),
				doc_param("limit", "int", false, "Max results returned (default 100)."),
			],
		},
		"resource.info": {
			"description": "Report a resource's type, UID, dependencies, and (optionally) referencers. Referencers are found by scanning every project file's dependencies (O(files)).",
			"params": [
				doc_param("path", "String", true, "Path to the resource file."),
				doc_param("referencers", "bool", false, "Scan the project for files that depend on this one (default true)."),
			],
		},
	}
