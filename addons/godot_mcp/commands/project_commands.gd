@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Project-level introspection and configuration: info, filesystem tree, file
## and in-file search, project settings, UID conversion, autoloads.

const _TEXT_EXTS: PackedStringArray = ["gd", "tscn", "tres", "cfg", "godot", "gdshader", "md", "txt", "json"]


func get_commands() -> Dictionary:
	return {
		"project.info": _info,
		"project.tree": _tree,
		"project.search": _search,
		"project.grep": _grep,
		"project.settings": _settings,
		"project.set_setting": _set_setting,
		"project.uid_to_path": _uid_to_path,
		"project.path_to_uid": _path_to_uid,
		"project.add_autoload": _add_autoload,
		"project.remove_autoload": _remove_autoload,
		"project.plugins": _plugins,
		"project.enable_plugin": _enable_plugin,
		"project.disable_plugin": _disable_plugin,
	}


func _plugins(_params: Dictionary) -> Dictionary:
	var enabled: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	var plugins: Array = []
	var dir := DirAccess.open("res://addons")
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while not name.is_empty():
			var cfg_path := "res://addons/%s/plugin.cfg" % name
			if dir.current_is_dir() and FileAccess.file_exists(cfg_path):
				var cfg := ConfigFile.new()
				cfg.load(cfg_path)
				plugins.append({
					"name": name,  # the folder name — pass this to enable/disable
					"display_name": cfg.get_value("plugin", "name", name),
					"version": str(cfg.get_value("plugin", "version", "")),
					"enabled": cfg_path in enabled,
				})
			name = dir.get_next()
		dir.list_dir_end()
	plugins.sort_custom(func(a, b): return a["name"] < b["name"])
	return success({"plugins": plugins, "count": plugins.size()})


func _enable_plugin(params: Dictionary) -> Dictionary:
	return _set_plugin(params, true)


func _disable_plugin(params: Dictionary) -> Dictionary:
	return _set_plugin(params, false)


func _set_plugin(params: Dictionary, enabled: bool) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var name: String = r[0]
	if not FileAccess.file_exists("res://addons/%s/plugin.cfg" % name):
		return error_not_found("Plugin '%s' (no res://addons/%s/plugin.cfg)" % [name, name],
			"Use project.plugins to list installed plugins")
	EditorInterface.set_plugin_enabled(name, enabled)
	return success({"name": name, "enabled": EditorInterface.is_plugin_enabled(name)})


func _tree(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var filter := optional_string(params, "filter", "")  # e.g. "*.gd"
	var max_depth := optional_int(params, "max_depth", 10)
	return success({"tree": _scan_dir(path, filter, max_depth, 0)})


func _scan_dir(path: String, filter: String, max_depth: int, depth: int) -> Dictionary:
	var result := {"name": path.get_file(), "path": path, "type": "directory"}
	if depth >= max_depth:
		return result
	var dir := DirAccess.open(path)
	if dir == null:
		return result
	var children: Array = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not file_name.begins_with("."):
			var full := path.path_join(file_name)
			if dir.current_is_dir():
				children.append(_scan_dir(full, filter, max_depth, depth + 1))
			elif filter.is_empty() or file_name.match(filter):
				children.append({"name": file_name, "path": full, "type": "file"})
		file_name = dir.get_next()
	dir.list_dir_end()
	if not children.is_empty():
		result["children"] = children
	return result


func _search(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var query: String = r[0].to_lower()
	var path := optional_string(params, "path", "res://")
	var file_type := optional_string(params, "file_type", "")
	var max_results := optional_int(params, "max_results", 50)
	var matches: Array = []
	_search_files(path, query, file_type, matches, max_results)
	return success({"matches": matches, "count": matches.size()})


func _search_files(path: String, query: String, file_type: String, matches: Array, limit: int) -> void:
	if matches.size() >= limit:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty() and matches.size() < limit:
		if not file_name.begins_with("."):
			var full := path.path_join(file_name)
			if dir.current_is_dir():
				_search_files(full, query, file_type, matches, limit)
			elif file_type.is_empty() or file_name.get_extension() == file_type:
				if file_name.to_lower().contains(query) or file_name.match(query):
					matches.append(full)
		file_name = dir.get_next()
	dir.list_dir_end()


func _grep(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var query: String = r[0]
	var path := optional_string(params, "path", "res://")
	var file_type := optional_string(params, "file_type", "")
	var max_results := optional_int(params, "max_results", 50)
	var regex: RegEx = null
	if optional_bool(params, "regex", false):
		regex = RegEx.new()
		if regex.compile(query) != OK:
			return error_invalid_params("Invalid regex pattern: %s" % query)
	var matches: Array = []
	_grep_files(path, query, regex, file_type, matches, max_results)
	return success({"matches": matches, "count": matches.size(), "query": query})


func _grep_files(path: String, query: String, regex: RegEx, file_type: String, matches: Array, limit: int) -> void:
	if matches.size() >= limit:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty() and matches.size() < limit:
		if not file_name.begins_with("."):
			var full := path.path_join(file_name)
			if dir.current_is_dir():
				if file_name != "addons" and file_name != ".godot":
					_grep_files(full, query, regex, file_type, matches, limit)
			else:
				var ext := file_name.get_extension()
				if (file_type.is_empty() and ext in _TEXT_EXTS) or (not file_type.is_empty() and ext == file_type):
					var file := FileAccess.open(full, FileAccess.READ)
					if file:
						var lines := file.get_as_text().split("\n")
						file.close()
						for i in range(lines.size()):
							if matches.size() >= limit:
								break
							var hit := regex.search(lines[i]) != null if regex != null else lines[i].contains(query)
							if hit:
								matches.append({"file": full, "line": i + 1, "text": lines[i].strip_edges()})
		file_name = dir.get_next()
	dir.list_dir_end()


func _settings(params: Dictionary) -> Dictionary:
	var key := optional_string(params, "key", "")
	if not key.is_empty():
		if not ProjectSettings.has_setting(key):
			return error_not_found("Setting '%s'" % key)
		return success({"key": key, "value": str(ProjectSettings.get_setting(key))})
	var section := optional_string(params, "section", "")
	var settings: Dictionary = {}
	for prop in ProjectSettings.get_property_list():
		var name: String = prop["name"]
		if section.is_empty() or name.begins_with(section):
			settings[name] = str(ProjectSettings.get_setting(name))
	return success({"settings": settings, "count": settings.size()})


func _set_setting(params: Dictionary) -> Dictionary:
	var r := require_string(params, "key")
	if r[1] != null:
		return r[1]
	if not params.has("value"):
		return error_invalid_params("Missing required parameter: value")
	var key: String = r[0]
	var value: Variant = PropertyParser.parse_value(params["value"], TYPE_NIL)
	ProjectSettings.set_setting(key, value)
	var err := ProjectSettings.save()
	if err != OK:
		return error_internal("Failed to save project settings: %s" % error_string(err))
	return success({"key": key, "value": str(ProjectSettings.get_setting(key)), "saved": true})


func _uid_to_path(params: Dictionary) -> Dictionary:
	var r := require_string(params, "uid")
	if r[1] != null:
		return r[1]
	var id := ResourceUID.text_to_id(r[0])
	if id == ResourceUID.INVALID_ID:
		return error_invalid_params("Invalid UID format: %s" % r[0])
	if not ResourceUID.has_id(id):
		return error_not_found("UID '%s'" % r[0])
	return success({"uid": r[0], "path": ResourceUID.get_id_path(id)})


func _path_to_uid(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	if not ResourceLoader.exists(r[0]):
		return error_not_found("Resource at '%s'" % r[0])
	var id := ResourceLoader.get_resource_uid(r[0])
	if id == ResourceUID.INVALID_ID:
		return error_not_found("UID for '%s'" % r[0])
	return success({"path": r[0], "uid": ResourceUID.id_to_text(id)})


func _add_autoload(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var rp := require_string(params, "path")
	if rp[1] != null:
		return rp[1]
	var autoload_name: String = rn[0]
	var autoload_path: String = rp[0]
	if not FileAccess.file_exists(autoload_path):
		return error_not_found("File '%s'" % autoload_path)
	var key := "autoload/" + autoload_name
	if ProjectSettings.has_setting(key):
		return error(-32000, "Autoload '%s' already exists" % autoload_name, {"suggestion": "Use project.remove_autoload first"})
	ProjectSettings.set_setting(key, "*" + autoload_path)
	var err := ProjectSettings.save()
	if err != OK:
		return error_internal("Failed to save project settings: %s" % error_string(err))
	return success({"name": autoload_name, "path": autoload_path, "added": true})


func _remove_autoload(params: Dictionary) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var autoload_name: String = r[0]
	var key := "autoload/" + autoload_name
	if not ProjectSettings.has_setting(key):
		return error_not_found("Autoload '%s'" % autoload_name)
	var old_value := str(ProjectSettings.get_setting(key))
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		return error_internal("Failed to save project settings: %s" % error_string(err))
	return success({"name": r[0], "old_path": old_value, "removed": true})


func _info(_params: Dictionary) -> Dictionary:
	var info := {}
	info["project_name"] = ProjectSettings.get_setting("application/config/name", "")
	info["godot_version"] = Engine.get_version_info()
	info["project_path"] = ProjectSettings.globalize_path("res://")
	info["main_scene"] = ProjectSettings.get_setting("application/run/main_scene", "")
	info["viewport_width"] = ProjectSettings.get_setting("display/window/size/viewport_width", 0)
	info["viewport_height"] = ProjectSettings.get_setting("display/window/size/viewport_height", 0)
	info["renderer"] = ProjectSettings.get_setting("rendering/renderer/rendering_method", "")

	var autoloads := {}
	for prop in ProjectSettings.get_property_list():
		var name: String = prop["name"]
		if name.begins_with("autoload/"):
			autoloads[name.substr(9)] = ProjectSettings.get_setting(name)
	info["autoloads"] = autoloads

	return success(info)


func get_command_docs() -> Dictionary:
	return {
		"project.info": {
			"description": "Report project name, Godot version, path, main scene, viewport size, renderer, and autoloads.",
		},
		"project.tree": {
			"description": "Return the project's filesystem tree under --path, optionally filtered by a filename glob.",
			"params": [
				doc_param("path", "String", false, "Root directory to scan (default 'res://')."),
				doc_param("filter", "String", false, "Filename glob to include (e.g. '*.gd')."),
				doc_param("max_depth", "int", false, "Max directory depth (default 10)."),
			],
		},
		"project.search": {
			"description": "Search filenames under --path for --query (substring or glob match).",
			"params": [
				doc_param("query", "String", true, "Filename substring/glob to match."),
				doc_param("path", "String", false, "Root directory (default 'res://')."),
				doc_param("file_type", "String", false, "Restrict to this extension (e.g. 'gd')."),
				doc_param("max_results", "int", false, "Cap on matches (default 50)."),
			],
		},
		"project.grep": {
			"description": "Search file contents for --query across text files (skips addons/ and .godot/). Optional regex.",
			"params": [
				doc_param("query", "String", true, "Text or regex to search for."),
				doc_param("path", "String", false, "Root directory (default 'res://')."),
				doc_param("file_type", "String", false, "Restrict to this extension; default scans common text types."),
				doc_param("max_results", "int", false, "Cap on matches (default 50)."),
				doc_param("regex", "bool", false, "Treat --query as a regex pattern."),
			],
		},
		"project.settings": {
			"description": "Read project settings. With --key returns one setting; otherwise all, optionally narrowed to a --section prefix.",
			"params": [
				doc_param("key", "String", false, "A single setting key to read."),
				doc_param("section", "String", false, "Section prefix filter when listing all."),
			],
		},
		"project.set_setting": {
			"description": "Set a project setting (--key to --value, auto-parsed) and save project.godot. The safe way to change settings — never hand-edit project.godot.",
			"params": [
				doc_param("key", "String", true, "Setting key (e.g. 'display/window/size/viewport_width')."),
				doc_param("value", "JSON", true, "Value, auto-parsed to the right type."),
			],
		},
		"project.uid_to_path": {
			"description": "Resolve a Godot resource UID (uid://...) to its res:// path.",
			"params": [
				doc_param("uid", "String", true, "The uid:// identifier."),
			],
		},
		"project.path_to_uid": {
			"description": "Get the resource UID (uid://...) for a res:// path.",
			"params": [
				doc_param("path", "String", true, "res:// path to an existing resource."),
			],
		},
		"project.add_autoload": {
			"description": "Register an autoload singleton (--name pointing at --path) and save. Errors if the name already exists.",
			"params": [
				doc_param("name", "String", true, "Autoload singleton name."),
				doc_param("path", "String", true, "res:// path to the script/scene."),
			],
		},
		"project.remove_autoload": {
			"description": "Remove an autoload singleton by --name and save.",
			"params": [
				doc_param("name", "String", true, "Autoload singleton name to remove."),
			],
		},
		"project.plugins": {
			"description": "List installed editor plugins (folder name, display name, version, enabled state).",
		},
		"project.enable_plugin": {
			"description": "Enable an editor plugin by its addon folder --name.",
			"params": [
				doc_param("name", "String", true, "The addon folder name (as listed by project.plugins)."),
			],
		},
		"project.disable_plugin": {
			"description": "Disable an editor plugin by its addon folder --name.",
			"params": [
				doc_param("name", "String", true, "The addon folder name."),
			],
		},
	}
