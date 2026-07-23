@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

const NodeUtils := preload("res://addons/godot_mcp/utils/node_utils.gd")


func get_commands() -> Dictionary:
	return {
		"scene.tree": _tree,
		"scene.content": _content,
		"scene.create": _create,
		"scene.open": _open,
		"scene.delete": _delete,
		"scene.instance": _instance,
		"scene.play": _play,
		"scene.stop": _stop,
		"scene.save": _save,
		"scene.validate": _validate,
	}


func _tree(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var max_depth := optional_int(params, "max_depth", -1)
	return success({"scene_path": root.scene_file_path, "tree": NodeUtils.get_node_tree(root, root, max_depth)})


func _content(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not FileAccess.file_exists(path):
		return error_not_found("Scene file '%s'" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return error_internal("Cannot read file: %s" % error_string(FileAccess.get_open_error()))
	var content := file.get_as_text()
	file.close()
	return success({"path": path, "content": content, "size": content.length()})


func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	var path_guard := guard_project_path(path)
	if not path_guard.is_empty():
		return path_guard
	var guard := guard_offline_scene_save(path)
	if not guard.is_empty():
		return guard

	var root_type := optional_string(params, "root_type", "Node2D")
	var root_name := optional_string(params, "root_name", "")
	if not ClassDB.class_exists(root_type):
		return error_invalid_params("Unknown node type: %s" % root_type)

	var root: Node = ClassDB.instantiate(root_type)
	if root_name.is_empty():
		root_name = path.get_file().get_basename()
	root.name = root_name

	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.queue_free()
	if err != OK:
		return error_internal("Failed to pack scene: %s" % error_string(err))

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	err = ResourceSaver.save(scene, path)
	if err != OK:
		return error_internal("Failed to save scene: %s" % error_string(err))

	EditorInterface.get_resource_filesystem().scan()
	return success({"path": path, "root_type": root_type, "root_name": root_name})


func _open(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not FileAccess.file_exists(path):
		return error_not_found("Scene file '%s'" % path)

	var normalized := normalize_project_path(path)
	var force := optional_bool(params, "force", false)
	var was_open := is_scene_path_open(normalized)
	var was_active := is_active_scene_path(normalized)

	# Opening the already-active scene is a no-op: open_scene_from_path keeps the
	# live edited instance (it does not reload from disk), so calling it again
	# only risks desyncing editor state. Make it idempotent unless force=true.
	if was_active and not force:
		return success({"path": normalized, "opened": false, "already_active": true})

	# force=true on an open scene reloads from disk, discarding unsaved edits.
	if force and was_open and EditorInterface.has_method("reload_scene_from_path"):
		EditorInterface.reload_scene_from_path(normalized)
		return success({"path": normalized, "opened": true, "reloaded": true})

	EditorInterface.open_scene_from_path(normalized)
	return success({"path": normalized, "opened": true, "was_already_open": was_open})


func _delete(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not FileAccess.file_exists(path):
		return error_not_found("Scene file '%s'" % path)
	if is_scene_path_open(path):
		return error_conflict("Refusing to delete open scene '%s'" % normalize_project_path(path),
			{"suggestion": "Close the scene tab first."})
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return error_internal("Failed to delete scene: %s" % error_string(err))
	EditorInterface.get_resource_filesystem().scan()
	return success({"path": path, "deleted": true})


func _instance(params: Dictionary) -> Dictionary:
	var r := require_string(params, "scene_path")
	if r[1] != null:
		return r[1]
	var scene_path: String = r[0]

	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not FileAccess.file_exists(scene_path):
		return error_not_found("Scene file '%s'" % scene_path)

	var parent := find_node_by_path(optional_string(params, "parent_path", "."))
	if parent == null:
		return error_not_found("Parent node", "Use scene.tree to see available nodes")

	var packed: PackedScene = load(scene_path)
	if packed == null:
		return error_internal("Failed to load scene: %s" % scene_path)
	# GEN_EDIT_STATE_INSTANCE makes the editor treat this as a real scene
	# instance (collapsed, internal nodes owned by the instance — not local).
	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var instance_name := optional_string(params, "name", "")
	if not instance_name.is_empty():
		instance.name = instance_name

	# Only the instance root is owned by the edited scene. Do NOT recurse owners
	# into the instance's internal nodes — that flattens them into duplicated
	# local nodes that clash with the instance's own content on reload.
	add_child_with_undo(parent, instance, root, "MCP: Instance %s" % scene_path)
	return success({
		"node_path": str(root.get_path_to(instance)),
		"scene_path": scene_path,
		"name": String(instance.name),
	})


func _play(params: Dictionary) -> Dictionary:
	var mode := optional_string(params, "mode", "main")  # "main", "current", or a scene path
	match mode:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		_:
			if not FileAccess.file_exists(mode):
				return error_not_found("Scene file '%s'" % mode)
			EditorInterface.play_custom_scene(mode)
	return success({"playing": true, "mode": mode})


func _stop(_params: Dictionary) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return success({"stopped": false, "message": "No scene is currently playing"})
	EditorInterface.stop_playing_scene()
	return success({"stopped": true})


func _save(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var path := optional_string(params, "path", "")
	if path.is_empty():
		path = root.scene_file_path
	if path.is_empty():
		return error_invalid_params("No save path specified and scene has no existing path")
	var normalized := normalize_project_path(path)

	if is_scene_path_open(normalized) and not is_active_scene_path(normalized):
		return error_conflict("Refusing to save inactive open scene '%s'" % normalized,
			{"active_scene": normalize_project_path(root.scene_file_path),
			"suggestion": "Open the target scene tab before saving it."})

	var dir_path := normalized.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var err := OK
	var method := ""
	if root.scene_file_path.is_empty() or normalize_project_path(root.scene_file_path) != normalized:
		EditorInterface.save_scene_as(normalized)
		method = "save_scene_as"
	else:
		err = EditorInterface.save_scene()
		method = "save_scene"
	if err != OK:
		return error_internal("Failed to save scene via %s: %s" % [method, error_string(err)])
	return success({"path": normalized, "saved": true, "method": method})


# --- Scene integrity validation (read-only) ---------------------------------

## Scan the open scene for integrity problems that don't surface until play —
## chiefly AnimationPlayer tracks whose node path doesn't resolve ("track doesn't
## lead to a Node") and exported/stored NodePath references that point nowhere.
## Returns {valid, issue_count, issues:[...]}. Never mutates the scene; script
## parse errors are out of scope (use script.validate).
func _validate(_params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var issues: Array = []
	_validate_node(root, root, issues)
	return success({
		"scene_path": root.scene_file_path,
		"valid": issues.is_empty(),
		"issue_count": issues.size(),
		"issues": issues,
	})


func _validate_node(node: Node, root: Node, issues: Array) -> void:
	if node is AnimationPlayer:
		_validate_animations(node, root, issues)
	for prop in node.get_property_list():
		if int(prop.get("type", TYPE_NIL)) != TYPE_NODE_PATH:
			continue
		if not (int(prop.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
			continue
		var np: NodePath = node.get(prop["name"])
		if np == null or np.is_empty():
			continue
		if node.get_node_or_null(np) == null:
			issues.append({
				"type": "unresolved_node_path",
				"node": str(root.get_path_to(node)),
				"property": String(prop["name"]),
				"path": String(np),
			})
	for child in node.get_children():
		_validate_node(child, root, issues)


func _validate_animations(player: AnimationPlayer, root: Node, issues: Array) -> void:
	var anim_root: Node = player.get_node_or_null(player.root_node)
	if anim_root == null:
		anim_root = player
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		if lib == null:
			continue
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			if anim == null:
				continue
			for ti in range(anim.get_track_count()):
				var tpath := String(anim.track_get_path(ti))
				var colon := tpath.find(":")
				var node_part := tpath.substr(0, colon) if colon >= 0 else tpath
				if node_part.is_empty():
					continue
				if anim_root.get_node_or_null(NodePath(node_part)) == null:
					var qual: String = anim_name if String(lib_name).is_empty() else "%s/%s" % [lib_name, anim_name]
					issues.append({
						"type": "missing_animation_track",
						"node": str(root.get_path_to(player)),
						"animation": qual,
						"track": ti,
						"track_path": tpath,
						"detail": "track node path does not resolve under the player's root_node",
					})


func get_command_docs() -> Dictionary:
	return {
		"scene.tree": {
			"description": "Return the edited scene's node tree (names, types, and paths relative to the root).",
			"params": [
				doc_param("max_depth", "int", false, "Max depth to descend (-1 = unlimited, the default)."),
			],
		},
		"scene.content": {
			"description": "Read a scene file's raw text from disk by --path (does not open it in the editor).",
			"params": [
				doc_param("path", "String", true, "res:// path to a .tscn/.scn file."),
			],
		},
		"scene.create": {
			"description": "Create a new scene file with a fresh root of --root-type and save it to --path. Does not switch the edited scene — a 3D scene needs a follow-up scene.open before 3D-only commands work.",
			"params": [
				doc_param("path", "String", true, "res:// path to write the scene to."),
				doc_param("root_type", "String", false, "Root node class (default 'Node2D')."),
				doc_param("root_name", "String", false, "Root node name (default the file basename)."),
			],
		},
		"scene.open": {
			"description": "Open a scene in the editor and make it the edited scene. Idempotent on the already-active scene; --force reloads from disk, discarding unsaved edits.",
			"params": [
				doc_param("path", "String", true, "res:// path to the scene."),
				doc_param("force", "bool", false, "Reload from disk even if already open/active (discards unsaved edits)."),
			],
		},
		"scene.delete": {
			"description": "Delete a scene file from disk (refuses a scene currently open in the editor).",
			"params": [
				doc_param("path", "String", true, "res:// path to the scene."),
			],
		},
		"scene.instance": {
			"description": "Instance an existing scene (--scene-path) as a child under --parent-path in the edited scene. Undoable.",
			"params": [
				doc_param("scene_path", "String", true, "res:// path to the scene to instance."),
				doc_param("parent_path", "NodePath", false, "Parent to add under, relative to the root (default '.')."),
				doc_param("name", "String", false, "Name for the instance node."),
			],
		},
		"scene.play": {
			"description": "Run the project. --mode 'main' (default), 'current' (the edited scene), or a res:// scene path to run a specific scene.",
			"params": [
				doc_param("mode", "String", false, "'main', 'current', or a res:// scene path (default 'main')."),
			],
		},
		"scene.stop": {
			"description": "Stop the currently playing scene (a no-op if nothing is playing).",
		},
		"scene.save": {
			"description": "Save the edited scene. --path saves to a new path (save-as); otherwise saves in place. Refuses to save an inactive open scene.",
			"params": [
				doc_param("path", "String", false, "res:// path to save to (default the scene's current path)."),
			],
		},
		"scene.validate": {
			"description": "Scan the open scene for integrity problems that surface only at play: AnimationPlayer tracks whose node path doesn't resolve, and stored NodePath references pointing nowhere. Read-only.",
		},
	}
