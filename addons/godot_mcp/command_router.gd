@tool
extends Node

## Routes dotted JSON-RPC methods (<group>.<command>) to handlers. Each command
## group is a node under here exposing get_commands() -> {method: Callable}.
## Also records lightweight activity stats (for the opt-in dashboard).

var editor_plugin: EditorPlugin

var _handlers: Dictionary = {}  # "group.command" -> Callable
var _docs: Dictionary = {}      # "group.command" -> {description, params:[...]} (optional per command)

const HISTORY_MAX := 200
const SNAPSHOT_RECENT := 50  # cap the snapshot payload small (frequent dashboard polling)

var _start_ms: int = 0
var _total: int = 0
var _errors: int = 0
var _by_group: Dictionary = {}   # group -> count
var _by_method: Dictionary = {}  # method -> count
var _history: Array = []         # ring buffer of {ts, method, ok, ms, params}
var _active_conn: int = 0
var _total_conn: int = 0


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	_register([
		preload("res://addons/godot_mcp/commands/project_commands.gd"),
		preload("res://addons/godot_mcp/commands/scene_commands.gd"),
		preload("res://addons/godot_mcp/commands/node_commands.gd"),
		preload("res://addons/godot_mcp/commands/spatial_commands.gd"),
		preload("res://addons/godot_mcp/commands/authoring_commands.gd"),
		preload("res://addons/godot_mcp/commands/script_commands.gd"),
		preload("res://addons/godot_mcp/commands/csharp_commands.gd"),
		preload("res://addons/godot_mcp/commands/editor_commands.gd"),
		preload("res://addons/godot_mcp/commands/runtime_commands.gd"),
		preload("res://addons/godot_mcp/commands/engine_commands.gd"),
		preload("res://addons/godot_mcp/commands/input_commands.gd"),
		preload("res://addons/godot_mcp/commands/animation_commands.gd"),
		preload("res://addons/godot_mcp/commands/animation_tree_commands.gd"),
		preload("res://addons/godot_mcp/commands/tilemap_commands.gd"),
		preload("res://addons/godot_mcp/commands/theme_commands.gd"),
		preload("res://addons/godot_mcp/commands/shader_commands.gd"),
		preload("res://addons/godot_mcp/commands/particle_commands.gd"),
		preload("res://addons/godot_mcp/commands/scene_3d_commands.gd"),
		preload("res://addons/godot_mcp/commands/scene_2d_commands.gd"),
		preload("res://addons/godot_mcp/commands/material_commands.gd"),
		preload("res://addons/godot_mcp/commands/csg_commands.gd"),
		preload("res://addons/godot_mcp/commands/gridmap_commands.gd"),
		preload("res://addons/godot_mcp/commands/scatter_commands.gd"),
		preload("res://addons/godot_mcp/commands/lighting_commands.gd"),
		preload("res://addons/godot_mcp/commands/path_commands.gd"),
		preload("res://addons/godot_mcp/commands/pcg_commands.gd"),
		preload("res://addons/godot_mcp/commands/wfc_commands.gd"),
		preload("res://addons/godot_mcp/commands/mesh_commands.gd"),
		preload("res://addons/godot_mcp/commands/doc_commands.gd"),
		preload("res://addons/godot_mcp/commands/cleanup_commands.gd"),
		preload("res://addons/godot_mcp/commands/physics_commands.gd"),
		preload("res://addons/godot_mcp/commands/navigation_commands.gd"),
		preload("res://addons/godot_mcp/commands/audio_commands.gd"),
		preload("res://addons/godot_mcp/commands/input_map_commands.gd"),
		preload("res://addons/godot_mcp/commands/resource_commands.gd"),
		preload("res://addons/godot_mcp/commands/fs_commands.gd"),
		preload("res://addons/godot_mcp/commands/import_commands.gd"),
		preload("res://addons/godot_mcp/commands/multiplayer_commands.gd"),
		preload("res://addons/godot_mcp/commands/skeleton_commands.gd"),
		preload("res://addons/godot_mcp/commands/localization_commands.gd"),
		preload("res://addons/godot_mcp/commands/ui_commands.gd"),
		preload("res://addons/godot_mcp/commands/camera_commands.gd"),
		preload("res://addons/godot_mcp/commands/analysis_commands.gd"),
		preload("res://addons/godot_mcp/commands/batch_commands.gd"),
		preload("res://addons/godot_mcp/commands/profiling_commands.gd"),
		preload("res://addons/godot_mcp/commands/export_commands.gd"),
		preload("res://addons/godot_mcp/commands/test_commands.gd"),
		preload("res://addons/godot_mcp/commands/android_commands.gd"),
		preload("res://addons/godot_mcp/commands/stats_commands.gd"),
	])
	_register_project_commands()


func _register(command_classes: Array) -> void:
	for cmd_class in command_classes:
		var cmd: Node = cmd_class.new()
		cmd.editor_plugin = editor_plugin
		add_child(cmd)
		for method: String in cmd.get_commands():
			_handlers[method] = cmd.get_commands()[method]
		# Optional per-command param metadata (the [CliArg] equivalent).
		if cmd.has_method("get_command_docs"):
			var docs: Variant = cmd.get_command_docs()
			if docs is Dictionary:
				for method: String in (docs as Dictionary):
					_docs[method] = (docs as Dictionary)[method]
	print("[MCP] Registered %d commands" % _handlers.size())


## Register project-local command groups from res://mcp_commands/*.gd, so a
## consumer project extends the MCP without forking the addon. Each valid file
## instantiates to a Node exposing get_commands() -> {"group.command": Callable};
## a bad file (fails to load, not a Node, no get_commands) is skipped with a
## push_warning and never breaks startup, and a name that collides with a
## built-in (or an earlier project command) is skipped — built-ins win.
## Editing a file here needs a full editor restart to recompile (reload_plugin
## re-runs registration but does not re-parse changed GDScript from disk).
func _register_project_commands() -> void:
	const PROJECT_DIR := "res://mcp_commands"
	var dir := DirAccess.open(PROJECT_DIR)
	if dir == null:
		return  # no project-local commands — silently skip
	var registered := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		# Only .gd files: Godot 4.7 writes a .uid sidecar per script — ignore it.
		if not dir.current_is_dir() and file_name.get_extension() == "gd":
			registered += _register_project_file(PROJECT_DIR.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	if registered > 0:
		print("[MCP] Registered %d project commands from %s" % [registered, PROJECT_DIR])


## Load, instantiate, and register one project command file. Returns how many
## commands it added (0 if the file is invalid or all its names collide).
func _register_project_file(path: String) -> int:
	var script: Variant = load(path)
	if not (script is Script):
		push_warning("[MCP] Skipping project command file '%s': failed to load as a script" % path)
		return 0
	var inst: Variant = (script as Script).new()
	if not (inst is Node):
		push_warning("[MCP] Skipping project command file '%s': script must instantiate to a Node" % path)
		return 0
	var cmd: Node = inst
	if not cmd.has_method("get_commands"):
		push_warning("[MCP] Skipping project command file '%s': no get_commands() method" % path)
		cmd.free()
		return 0
	var commands: Variant = cmd.get_commands()
	if not (commands is Dictionary):
		push_warning("[MCP] Skipping project command file '%s': get_commands() must return a Dictionary" % path)
		cmd.free()
		return 0
	if "editor_plugin" in cmd:
		cmd.editor_plugin = editor_plugin
	add_child(cmd)
	# Optional per-command param docs, keyed the same as get_commands().
	var cmd_docs: Dictionary = {}
	if cmd.has_method("get_command_docs"):
		var d: Variant = cmd.get_command_docs()
		if d is Dictionary:
			cmd_docs = d
	var added := 0
	for method in (commands as Dictionary):
		if typeof(method) != TYPE_STRING:
			continue
		if _handlers.has(method):
			push_warning("[MCP] Skipping project command '%s' from '%s': collides with a built-in (built-ins can't be overridden)" % [method, path])
			continue
		_handlers[method] = (commands as Dictionary)[method]
		if cmd_docs.has(method):
			_docs[method] = cmd_docs[method]
		added += 1
	return added


func execute(method: String, params: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var result: Dictionary
	if not _handlers.has(method):
		result = {"error": {
			"code": -32601,
			"message": "Method not found: %s" % method,
			"data": {"available_methods": _handlers.keys()},
		}}
	else:
		result = await _handlers[method].call(params)
	# Don't record the dashboard's own stats polling.
	if not method.begins_with("stats."):
		_record(method, not result.has("error"), Time.get_ticks_msec() - t0, params)
	return result


func get_available_methods() -> Array:
	return _handlers.keys()


## Per-command param metadata collected at registration ("group.command" ->
## {description, params:[...]}), for commands whose group exposes get_command_docs().
func get_command_docs() -> Dictionary:
	return _docs


# --- Stats ------------------------------------------------------------------

func _record(method: String, ok: bool, ms: int, params: Dictionary) -> void:
	_total += 1
	if not ok:
		_errors += 1
	var group := method.get_slice(".", 0)
	_by_group[group] = int(_by_group.get(group, 0)) + 1
	_by_method[method] = int(_by_method.get(method, 0)) + 1
	_history.append({
		"ts": int(Time.get_unix_time_from_system() * 1000.0),
		"method": method,
		"ok": ok,
		"ms": ms,
		"params": _summarize(params),
	})
	if _history.size() > HISTORY_MAX:
		_history.remove_at(0)


func _summarize(params: Dictionary) -> String:
	if params.is_empty():
		return ""
	var s := JSON.stringify(params)
	return s if s.length() <= 100 else s.substr(0, 97) + "…"


## Called by the WebSocket server when a peer connects (+1) or drops (-1).
func note_connection(delta: int) -> void:
	_active_conn = maxi(0, _active_conn + delta)
	if delta > 0:
		_total_conn += delta


func stats_snapshot() -> Dictionary:
	var recent: Array = []
	var n := mini(_history.size(), SNAPSHOT_RECENT)
	for i in range(n):  # newest first, capped to keep the payload small
		recent.append(_history[_history.size() - 1 - i])
	return {
		"uptime_ms": Time.get_ticks_msec() - _start_ms,
		"total_calls": _total,
		"errors": _errors,
		"active_connections": _active_conn,
		"total_connections": _total_conn,
		"command_count": _handlers.size(),
		"playing": EditorInterface.is_playing_scene(),
		"by_group": _by_group,
		"by_method": _by_method,
		"recent": recent,
	}


func reset_stats() -> void:
	_total = 0
	_errors = 0
	_by_group.clear()
	_by_method.clear()
	_history.clear()
	_total_conn = _active_conn
	_start_ms = Time.get_ticks_msec()
