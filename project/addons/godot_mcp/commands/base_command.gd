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
	# Naming scene.create here read as an accusation when scene.create was exactly
	# what the caller had just run (it now opens what it writes, so this is the
	# --open=false / closed-tab case).
	return error(-32000, "No scene is currently open in the editor", {
		"suggestion": "Open one with scene.open --path res://…, or create one with scene.create (which opens it unless --open=false).",
	})


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


## Optional counterpart to require_dict: absent means an empty map, which is not an
## error. A value that is present but not an object still is — a malformed
## --properties used to be iterated as a String and drop every key without a word.
func optional_dict(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return [{}, null]
	return require_dict(params, key)


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


## Precondition for every editor->game file-IPC call: the launched game reads
## project.godot FROM DISK, so a game-side autoload the editor holds only in
## memory does not exist in the game.
##
## Worth checking rather than discovering by timeout. plugin.gd injects these on
## enable and saves, but the on-disk file can lose them between then and now — a
## git revert or checkout of project.godot (common in projects that keep dev-only
## autoloads out of version control), a branch switch, an external edit. The
## editor keeps its in-memory copy either way, so `project.info` still lists the
## autoloads and every editor-side command keeps answering normally; only the game
## hop is broken, which is what makes this one hard to see.
##
## Without the check the failure is both expensive and mute: runtime.* burns its
## entire timeout and then GUESSES at this cause in a suggestion string, and
## input.* — fire-and-forget, with no response to wait on — reports
## `{"sent": true}` for an event nothing will ever read.
##
## Returns {} when the channel can work (including when project.godot cannot be
## read at all — better to attempt the call than to block on a guess), or an
## error dict ready to return.
func game_autoload_error(autoload_name: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(ProjectSettings.globalize_path("res://project.godot")) != OK:
		return {}
	if cfg.has_section_key("autoload", autoload_name):
		return {}
	return error(
		-32000,
		"%s is missing from project.godot on disk, so the running game never loaded it" % autoload_name,
		{
			"suggestion": (
				"The plugin injects this autoload when it is enabled, and the on-disk file has "
				+ "lost it since (a git revert or checkout of project.godot does exactly this). "
				+ "Re-save project settings from the editor, then stop and replay the game."
			),
			"missing_setting": "autoload/%s" % autoload_name,
		}
	)


## Read a game IPC response file, tolerating the moment right after it appears.
## The game publishes the file by rename so a torn read should be impossible, but
## the OS can still hold it locked for an instant — and treating that as fatal is
## what produced the intermittent "-32603 Could not read game response file" that
## an immediate retry always cured. Returns the text, or "" after `attempts`
## tries. The caller deletes the file.
func read_game_response(response_path: String, attempts: int = 10) -> Array:
	var text := ""
	var tries := 0
	while tries < attempts:
		tries += 1
		var file := FileAccess.open(response_path, FileAccess.READ)
		if file != null:
			text = file.get_as_text()
			file.close()
			if not text.strip_edges().is_empty():
				break
		await get_tree().create_timer(0.05).timeout
	return [text, tries]


## The debugger bridge's current break, or {} when nothing is paused (also when
## the bridge is unavailable — a plugin mid-reload, or an older install).
func debugger_break() -> Dictionary:
	if editor_plugin == null or not ("debugger_bridge" in editor_plugin):
		return {}
	var bridge: Variant = editor_plugin.debugger_bridge
	if bridge == null:
		return {}
	bridge.ensure_connected()
	return bridge.current_break()


## The error for a game command that never answered. A game stopped at a DEBUGGER
## BREAK is the common cause and the one the old message got wrong: it blamed a
## missing autoload (already ruled out on disk by game_autoload_error) while the
## game sat paused with its _process loop — and so the IPC poll — frozen. The
## debugger bridge knows the break state, so ask it instead of guessing.
func game_timeout_error(timeout_sec: float) -> Dictionary:
	var brk := debugger_break()
	if not brk.is_empty():
		var reason := str(brk.get("reason", "")).strip_edges()
		return error(-32000, "Game command timed out after %.1fs: the game is paused at a debugger break%s" % [
			timeout_sec, (" (%s)" % reason) if not reason.is_empty() else ""],
			{
				"debugger_breaked": true,
				"break_reason": reason,
				"can_debug": brk.get("can_debug", false),
				"suggestion": "Read the stop with debug.state, then debug.resume (or debug.step) to let the game run — runtime.* and input.* cannot be served while it is stopped.",
			})
	return error(-32000, "Game command timed out after %.1fs" % timeout_sec,
		{"suggestion": "Ensure the game is running with the MCPGameInspector autoload active"})


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
				"suggestion": "Edit it live and use scene.save, or close the tab first with scene.close --path %s." % normalize_project_path(path),
			}
		)
	return {}


# --- UndoRedo helpers -------------------------------------------------------

## Add `child` under `parent` in one undoable action. `index` >= 0 seats it at that
## sibling position instead of appending, inside the same action, since sibling
## order is draw order in 2D and a second action would make that two undo steps.
func add_child_with_undo(parent: Node, child: Node, root: Node, action_name: String, index: int = -1) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	undo_redo.add_do_method(parent, "add_child", child)
	undo_redo.add_do_method(child, "set_owner", root)
	if index >= 0:
		undo_redo.add_do_method(parent, "move_child", child, index)
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


# --- Initial property maps --------------------------------------------------

## Apply an initial {property: value} map to a freshly built object, coercing each
## value against its DECLARED type via parse_checked. Returns
## {applied, ignored, failures}: `ignored` names the object does not have, and
## `failures` coercions parse_checked refused.
##
## Use this for every `--properties` / `--mesh_properties` map. The shortcut it
## replaces — `obj.set(name, parse_value(raw, typeof(obj.get(name))))` — failed
## silently twice over: `typeof` on a null Resource property reads TYPE_NIL, so a
## `res://` path was assigned as text and dropped, and the lenient parse zero-pads
## a short numeric literal instead of refusing it. Both returned success.
func apply_initial_properties(obj: Object, props: Dictionary) -> Dictionary:
	var applied: Array = []
	var ignored: Array = []
	var failures: Array = []
	for prop_name: String in props:
		if not prop_name in obj:
			ignored.append(prop_name)
			continue
		var decl := PropertyParser.declared_type(obj, prop_name)
		var target_type: int = int(decl["type"]) if decl["found"] else typeof(obj.get(prop_name))
		var res := PropertyParser.parse_checked(props[prop_name], target_type, String(decl["class_name"]))
		if not bool(res["ok"]):
			failures.append("%s: %s" % [prop_name, String(res["reason"])])
			continue
		obj.set(prop_name, res["value"])
		applied.append(prop_name)
	return {"applied": applied, "ignored": ignored, "failures": failures}


## The error for a non-empty `failures` from apply_initial_properties. Callers
## refuse the whole call rather than persisting an object some of whose properties
## silently never landed.
func error_property_failures(result: Dictionary) -> Dictionary:
	var failures: Array = result["failures"]
	var noun := "property" if failures.size() == 1 else "properties"
	return error(-32602, "Could not set %d %s" % [failures.size(), noun], {
		"failed": failures,
		"applied": result["applied"],
		"ignored": result["ignored"],
	})


# --- Script introspection ---------------------------------------------------

## Friendly type string for a Variant type int, preferring the class name for
## objects (TYPE_OBJECT alone tells a caller nothing useful).
func type_name(t: int, hint_class: String = "") -> String:
	if t == TYPE_OBJECT and not hint_class.is_empty():
		return hint_class
	return type_string(t)


## One method entry (name, return type, arg names + types) for a symbol table.
func method_brief(m: Dictionary) -> Dictionary:
	var args: Array = []
	for a in m["args"]:
		args.append({"name": a["name"], "type": type_name(a["type"], a.get("class_name", ""))})
	var ret: Dictionary = m.get("return", {})
	return {
		"name": m["name"],
		"return": type_name(ret.get("type", TYPE_NIL), ret.get("class_name", "")),
		"args": args,
	}


## Name → occurrence count across a script list, used to subtract a base script's
## members from a derived one's.
func _name_counts(entries: Array) -> Dictionary:
	var counts := {}
	for e in entries:
		var n := String(e["name"])
		counts[n] = int(counts.get(n, 0)) + 1
	return counts


## Keep only the members `script` itself declares, given its base script's list.
##
## get_script_*_list() walks the whole SCRIPT chain, so a command group extending
## base_command.gd reports base_command's 50-odd helpers as its own. Subtracting by
## multiset rather than by name keeps overrides: a method the child redeclares
## appears twice in the child list and once in the base's, leaving one for the child.
func _own_members(entries: Array, base_entries: Array) -> Array:
	var budget := _name_counts(base_entries)
	var own: Array = []
	for e in entries:
		var n := String(e["name"])
		var left := int(budget.get(n, 0))
		if left > 0:
			budget[n] = left - 1
			continue
		own.append(e)
	return own


## Drop repeat names, keeping the first (most-derived) entry. An override otherwise
## surfaces once per level of the chain.
func _dedupe_by_name(entries: Array) -> Array:
	var seen := {}
	var out: Array = []
	for e in entries:
		var n := String(e["name"])
		if seen.has(n):
			continue
		seen[n] = true
		out.append(e)
	return out


## The API surface a Script exposes: properties, methods, signals, constants
## (enums included — an enum is a constant whose value is a Dictionary).
##
## Shared by engine.class_info and script.symbols, which want different scopes and
## so pass `include_inherited` differently. false answers "what does this file
## declare", which is what a caller reading one script wants; true answers "what can
## I call on this type", which is what a caller resolving a class wants. Neither
## reports engine members — a script chain stops at its base ENGINE type, so those
## come from engine.class_info on `base_type`.
func script_symbols(
	script: Script, filter: String = "", include_private: bool = false, include_inherited: bool = true
) -> Dictionary:
	var needle := filter.to_lower()
	var base := script.get_base_script()

	var raw_properties := Array(script.get_script_property_list())
	var raw_methods := Array(script.get_script_method_list())
	var raw_signals := Array(script.get_script_signal_list())
	if include_inherited:
		raw_properties = _dedupe_by_name(raw_properties)
		raw_methods = _dedupe_by_name(raw_methods)
		raw_signals = _dedupe_by_name(raw_signals)
	elif base != null:
		raw_properties = _own_members(raw_properties, Array(base.get_script_property_list()))
		raw_methods = _own_members(raw_methods, Array(base.get_script_method_list()))
		raw_signals = _own_members(raw_signals, Array(base.get_script_signal_list()))

	var properties: Array = []
	for p in raw_properties:
		if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) or p["type"] == TYPE_NIL:
			continue
		var pname: String = p["name"]
		if not needle.is_empty() and not pname.to_lower().contains(needle):
			continue
		properties.append({"name": pname, "type": type_name(p["type"], p.get("class_name", ""))})

	var methods: Array = []
	for m in raw_methods:
		var mname: String = m["name"]
		if not include_private and mname.begins_with("_"):
			continue
		if not needle.is_empty() and not mname.to_lower().contains(needle):
			continue
		methods.append(method_brief(m))

	var signals: Array = []
	for s in raw_signals:
		var sname: String = s["name"]
		if not needle.is_empty() and not sname.to_lower().contains(needle):
			continue
		var args: Array = []
		for a in s["args"]:
			args.append({"name": a["name"], "type": type_name(a["type"], a.get("class_name", ""))})
		signals.append({"name": sname, "args": args})

	# Constants are a flat map with no per-entry origin, so the base's map is
	# subtracted by key when the caller asked for this script's own declarations.
	var constant_map: Dictionary = script.get_script_constant_map()
	var base_constants: Dictionary = {} if (include_inherited or base == null) else base.get_script_constant_map()
	var constants: Dictionary = {}
	for k in constant_map:
		var cname := String(k)
		if base_constants.has(k):
			continue
		if not needle.is_empty() and not cname.to_lower().contains(needle):
			continue
		constants[cname] = PropertyParser.serialize_value(constant_map[k])

	return {
		"properties": properties,
		"methods": methods,
		"signals": signals,
		"constants": constants,
		"property_count": properties.size(),
		"method_count": methods.size(),
		"signal_count": signals.size(),
		"base_script": base.resource_path if base != null else "",
		"includes_inherited": include_inherited,
	}


# --- Command documentation --------------------------------------------------

## One param entry for a group's get_command_docs() table. Keeps the per-command
## param metadata (surfaced by engine.commands --group) terse to author. `ptype`
## is a friendly type string (String/int/float/bool/Vector2/Vector3/Color/Array/
## Dictionary/JSON/NodePath); `desc` is one actionable line.
func doc_param(pname: String, ptype: String, required: bool, desc: String) -> Dictionary:
	return {"name": pname, "type": ptype, "required": required, "desc": desc}
