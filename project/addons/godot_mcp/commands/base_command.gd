@tool
extends Node

## Base class for command groups. Subclasses override get_commands() to return
## {"<group>.<command>": Callable}. Helpers below keep handlers terse.

const PropertyParser := preload("res://addons/godot_mcp/utils/property_parser.gd")

var editor_plugin: EditorPlugin


func get_commands() -> Dictionary:
	return {}


# --- Result helpers ---------------------------------------------------------

func success(data: Dictionary = {}) -> Dictionary:
	return {"result": data}


func error(code: int, message: String, data: Dictionary = {}) -> Dictionary:
	var err := {"code": code, "message": message}
	if not data.is_empty():
		err["data"] = data
	return {"error": err}


func error_invalid_params(message: String) -> Dictionary:
	return error(-32602, message)


func error_not_found(what: String, suggestion: String = "") -> Dictionary:
	var data := {}
	if suggestion:
		data["suggestion"] = suggestion
	return error(-32001, "%s not found" % what, data)


func error_no_scene() -> Dictionary:
	return error(-32000, "No scene is currently open", {"suggestion": "Use scene.open or scene.create first"})


func error_conflict(message: String, data: Dictionary = {}) -> Dictionary:
	return error(-32009, message, data)


func error_internal(message: String) -> Dictionary:
	return error(-32603, "Internal error: %s" % message)


# --- Param helpers ----------------------------------------------------------

func require_string(params: Dictionary, key: String) -> Array:
	if not params.has(key) or not params[key] is String or (params[key] as String).is_empty():
		return [null, error_invalid_params("Missing required parameter: %s" % key)]
	return [params[key] as String, null]


func optional_string(params: Dictionary, key: String, default: String = "") -> String:
	if params.has(key) and params[key] is String:
		return params[key] as String
	return default


func optional_int(params: Dictionary, key: String, default: int = 0) -> int:
	if params.has(key):
		return int(params[key])
	return default


func optional_bool(params: Dictionary, key: String, default: bool = false) -> bool:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is bool:
		return v
	if v is String:
		return (v as String).to_lower() in ["true", "1", "yes"]
	return bool(v)


## Require a Dictionary param. Accepts a Dictionary, or a JSON object passed as a
## string; errors clearly otherwise. Returns [Dictionary, error_or_null], matching
## require_string. Use when a param must be an object, so a malformed value gets
## feedback instead of a silent skip or a hard `var x: Dictionary = ...` cast-crash.
func require_dict(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return [{}, error_invalid_params("Missing required parameter: %s" % key)]
	var v: Variant = params[key]
	if v is Dictionary:
		return [v, null]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Dictionary:
			return [parsed, null]
	return [{}, error_invalid_params("Parameter '%s' must be an object, got %s" % [key, type_string(typeof(v))])]


## Require an Array param. Accepts an Array, or a JSON array passed as a string.
## Returns [Array, error_or_null], matching require_dict.
func require_array(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return [[], error_invalid_params("Missing required parameter: %s" % key)]
	var v: Variant = params[key]
	if v is Array:
		return [v, null]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Array:
			return [parsed, null]
	return [[], error_invalid_params("Parameter '%s' must be an array, got %s" % [key, type_string(typeof(v))])]


## Parse an optional Vector3 param. Accepts a "Vector3(x,y,z)" string, a 3-element
## Array, or a {x,y,z} Dictionary; returns `default` when absent. Replaces the ~13
## per-group _v3/_v3param/_v3p copies.
func vec3_param(params: Dictionary, key: String, default: Vector3 = Vector3.ZERO) -> Vector3:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return PropertyParser.parse_value(v, TYPE_VECTOR3)


## Parse an optional Vector2 param (see vec3_param).
func vec2_param(params: Dictionary, key: String, default: Vector2 = Vector2.ZERO) -> Vector2:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return PropertyParser.parse_value(v, TYPE_VECTOR2)


# --- Editor access ----------------------------------------------------------

func get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func get_undo_redo() -> EditorUndoRedoManager:
	return editor_plugin.get_undo_redo()


## The running game's user data dir, used for editor<->game file IPC.
## OS.get_user_data_dir() is cached at editor startup and won't reflect a
## project-name change; the game derives its dir from project.godot on disk,
## so we resolve it the same way to keep both sides pointing at one folder.
func get_game_user_dir() -> String:
	var cached := OS.get_user_data_dir()
	var cfg := ConfigFile.new()
	if cfg.load(ProjectSettings.globalize_path("res://project.godot")) != OK:
		return cached
	if cfg.get_value("application", "config/use_custom_user_dir", false):
		return cached
	var disk_name = cfg.get_value("application", "config/name", "")
	if typeof(disk_name) != TYPE_STRING or (disk_name as String).is_empty():
		return cached
	var sanitized := (disk_name as String).xml_unescape().validate_filename().replace(".", "_")
	if sanitized.is_empty():
		return cached
	var game_dir := cached.get_base_dir().path_join(sanitized)
	if not DirAccess.dir_exists_absolute(game_dir):
		DirAccess.make_dir_recursive_absolute(game_dir)
	return game_dir


## Resolve a global class_name (an addon/project script class) to its Script, or
## null. Lets node/resource commands use third-party addon types by name.
func find_script_class(class_name_str: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")) == class_name_str:
			var path: String = entry.get("path", "")
			if not path.is_empty():
				return load(path) as Script
	return null


## Instantiate a Resource by ClassDB class name OR by a class_name Resource
## script (so addon resource types work too). Returns null if not a Resource.
func make_resource(type: String) -> Resource:
	if ClassDB.class_exists(type):
		if not ClassDB.is_parent_class(type, "Resource"):
			return null
		return ClassDB.instantiate(type)
	var script := find_script_class(type)
	if script == null:
		return null
	var base := script.get_instance_base_type()
	if not ClassDB.is_parent_class(base, "Resource"):
		return null
	var res: Resource = ClassDB.instantiate(base)
	if res != null:
		res.set_script(script)
	return res


func normalize_project_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("res://") or path.begins_with("user://"):
		return path.simplify_path()
	return ProjectSettings.localize_path(path).simplify_path()


## Reject a write target that escapes the project. Returns an error dict if `path`
## resolves outside res:// / user:// (an absolute OS path, or a `..` chain that climbs
## past the root); empty dict if safe. Call at file-WRITE entry points before saving.
func guard_project_path(path: String) -> Dictionary:
	var n := normalize_project_path(path)
	if not (n.begins_with("res://") or n.begins_with("user://")):
		return error_invalid_params("Path '%s' is outside the project; write targets must be res:// or user://" % path)
	# simplify_path() collapses interior "../"; any left means it climbed past the root.
	if n.trim_prefix("res://").trim_prefix("user://").contains(".."):
		return error_invalid_params("Path '%s' escapes the project root (.. outside res://)" % path)
	return {}


## Audit trail for ad-hoc code execution (editor.run_script / runtime.eval): write the
## full body to stderr BEFORE running, so a destructive one-off is always traceable.
func audit_exec(kind: String, code: String) -> void:
	# print (not printerr): this is an audit trail, not an error. Using printerr
	# rendered every line red as "ERROR:" in the Output panel, so editor.errors
	# (which scans for "ERROR") collected the whole script body as fake errors.
	print("[godot-mcp] %s executing (%d bytes):\n%s\n[godot-mcp] --- end %s ---" % [kind, code.length(), code, kind])


## Resolve a node path relative to the edited scene root. Accepts ".", the root
## name, a relative path, or a path prefixed with the root name.
func find_node_by_path(node_path: String) -> Node:
	var root := get_edited_root()
	if root == null:
		return null
	# "selected" resolves to the editor's current selection (first node) — lets the
	# user click a node and the agent act on it without guessing the path.
	if node_path == "selected":
		var sel := EditorInterface.get_selection().get_selected_nodes()
		return sel[0] if sel.size() > 0 else null
	if node_path == "." or node_path == root.name:
		return root
	if root.has_node(node_path):
		return root.get_node(node_path)
	if node_path.begins_with(root.name + "/"):
		var rel := node_path.substr(root.name.length() + 1)
		if root.has_node(rel):
			return root.get_node(rel)
	return null


## Require an edited scene root. Returns [Node, error_or_null].
func require_scene_root() -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	return [root, null]


## Require a 3D edited scene root. `group` names the command for a clear error.
## Returns [Node3D, error_or_null].
func require_scene_root_3d(group: String = "this command") -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	if not root is Node3D:
		return [null, error_invalid_params("%s needs a 3D scene (root is not a Node3D)" % group)]
	return [root as Node3D, null]


## Resolve a `node_path` param to a node under the edited scene root, with clear
## errors for missing-param / no-scene / not-found. Returns [Node, error_or_null].
func resolve_node_param(params: Dictionary, key: String = "node_path") -> Array:
	var r := require_string(params, key)
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null:
		return [null, error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")]
	return [node, null]


# --- 3D / spatial helpers ---------------------------------------------------

## Every node in `root`'s subtree (root included), depth-first. One traversal for
## the many hand-rolled stack walks across command groups.
func walk_tree(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## Descendants of `root` (root included) whose class is or derives from `klass`.
func find_descendants_of_type(root: Node, klass: String) -> Array:
	var out: Array = []
	for n: Node in walk_tree(root):
		if n.is_class(klass):
			out.append(n)
	return out


## World-space AABB of `node`: union of its own and descendants' VisualInstance3D
## AABBs, each transformed to global via all 8 corners (correct under rotation —
## do NOT use `global_transform * get_aabb()`, which only moves the origin).
## Returns {has: bool, aabb: AABB}.
func world_aabb(node: Node) -> Dictionary:
	var has := false
	var acc := AABB()
	for n: Node in walk_tree(node):
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var local := vi.get_aabb()
			var gt := vi.global_transform
			var wa := AABB(gt * local.get_endpoint(0), Vector3.ZERO)
			for i in range(1, 8):
				wa = wa.expand(gt * local.get_endpoint(i))
			acc = wa if not has else acc.merge(wa)
			has = true
	return {"has": has, "aabb": acc}


## The edited scene's edit-time physics space (for raycasts against CSG
## use_collision / StaticBody colliders). Returns [PhysicsDirectSpaceState3D, err].
func edit_space_state() -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	if not root is Node3D:
		return [null, error_invalid_params("edit-time raycast needs a 3D scene (root is not a Node3D)")]
	var world := (root as Node3D).get_world_3d()
	if world == null:
		return [null, error_internal("no World3D for the edited scene")]
	return [world.direct_space_state, null]


# --- Scene-open guards (avoid clobbering editor state) ----------------------

func is_scene_resource_path(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return ext == "tscn" or ext == "scn"


func get_open_scene_paths() -> Array[String]:
	var paths: Array[String] = []
	for scene_path: String in EditorInterface.get_open_scenes():
		var n := normalize_project_path(scene_path)
		if not n.is_empty() and n not in paths:
			paths.append(n)
	var root := get_edited_root()
	if root != null and not root.scene_file_path.is_empty():
		var active := normalize_project_path(root.scene_file_path)
		if active not in paths:
			paths.append(active)
	return paths


func is_scene_path_open(path: String) -> bool:
	var n := normalize_project_path(path)
	return not n.is_empty() and n in get_open_scene_paths()


func is_active_scene_path(path: String) -> bool:
	var root := get_edited_root()
	if root == null:
		return false
	return normalize_project_path(root.scene_file_path) == normalize_project_path(path)


## True if `path` is currently open in the script editor (script or shader tab).
func is_text_resource_open_in_script_editor(path: String) -> bool:
	var target := normalize_project_path(path)
	if target.is_empty():
		return false
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return false
	for open_resource in script_editor.get_open_scripts():
		if open_resource is Resource:
			if normalize_project_path((open_resource as Resource).resource_path) == target:
				return true
	return false


## Block offline writes to a text resource open in the script editor (would lose
## the editor's unsaved buffer). Pass force=true to override deliberately.
func guard_text_resource_write(path: String, force: bool) -> Dictionary:
	if not force and is_text_resource_open_in_script_editor(path):
		return error_conflict(
			"Refusing to write '%s' while it's open in the script editor" % normalize_project_path(path),
			{
				"path": normalize_project_path(path),
				"suggestion": "Close it in Godot's script editor, or pass force=true to overwrite the buffer.",
			}
		)
	return {}


## Block offline writes to a scene that's open in the editor (would desync state).
func guard_offline_scene_save(path: String) -> Dictionary:
	if is_scene_resource_path(path) and is_scene_path_open(path):
		return error_conflict(
			"Refusing to write open scene '%s' outside the editor" % normalize_project_path(path),
			{
				"path": normalize_project_path(path),
				"open_scenes": get_open_scene_paths(),
				"suggestion": "Edit it live and use scene.save, or close the scene tab first.",
			}
		)
	return {}


# --- UndoRedo helpers -------------------------------------------------------

func add_child_with_undo(parent: Node, child: Node, root: Node, action_name: String) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	undo_redo.add_do_method(parent, "add_child", child)
	undo_redo.add_do_method(child, "set_owner", root)
	undo_redo.add_do_reference(child)
	undo_redo.add_undo_method(parent, "remove_child", child)
	undo_redo.commit_action()


## Set one property through a single undoable action (old value captured from obj).
func set_property_with_undo(obj: Object, prop: String, value: Variant, action_name: String) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	undo_redo.add_do_property(obj, prop, value)
	undo_redo.add_undo_property(obj, prop, obj.get(prop))
	undo_redo.commit_action()


## Set several properties in ONE undoable action. Values must be fully resolved
## before calling — the action is created and committed here with no early exit, so
## callers can't leave a dangling uncommitted action (the failure mode this fixes).
func set_properties_with_undo(obj: Object, props: Dictionary, action_name: String) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	for prop: String in props:
		undo_redo.add_do_property(obj, prop, props[prop])
		undo_redo.add_undo_property(obj, prop, obj.get(prop))
	undo_redo.commit_action()


# --- Command documentation --------------------------------------------------

## One param entry for a group's get_command_docs() table. Keeps the per-command
## param metadata (surfaced by engine.commands --group) terse to author. `ptype`
## is a friendly type string (String/int/float/bool/Vector2/Vector3/Color/Array/
## Dictionary/JSON/NodePath); `desc` is one actionable line.
func doc_param(pname: String, ptype: String, required: bool, desc: String) -> Dictionary:
	return {"name": pname, "type": ptype, "required": required, "desc": desc}
