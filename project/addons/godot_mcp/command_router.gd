@tool
extends Node

## Routes dotted JSON-RPC methods (<group>.<command>) to handlers. Each command
## group is a node under here exposing get_commands() -> {method: Callable}.
## Also records lightweight activity stats (for the opt-in dashboard).

var editor_plugin: EditorPlugin

var _handlers: Dictionary = {}  # "group.command" -> Callable
var _docs: Dictionary = {}      # "group.command" -> {description, params:[...]} (optional per command)
var _unavailable: Array = []    # [{file, reason}] built-in groups this engine could not load

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


## The built-in command groups, in registration order. Paths, not preloads, and
## loaded one at a time on purpose: the addon's floor is Godot 4.3, and a group
## that names an API a newer engine added is a PARSE error on an older one. A
## preload makes that error the router's own, so a single unsupported group takes
## the whole plugin down; loading at runtime skips just that group (recorded in
## _unavailable, reported by engine.commands) and everything else still serves.
const _BUILTIN_GROUPS: Array = [
	"res://addons/godot_mcp/commands/project_commands.gd",
	"res://addons/godot_mcp/commands/scene_commands.gd",
	"res://addons/godot_mcp/commands/node_commands.gd",
	"res://addons/godot_mcp/commands/spatial_commands.gd",
	"res://addons/godot_mcp/commands/authoring_commands.gd",
	"res://addons/godot_mcp/commands/script_commands.gd",
	"res://addons/godot_mcp/commands/csharp_commands.gd",
	"res://addons/godot_mcp/commands/editor_commands.gd",
	"res://addons/godot_mcp/commands/debug_commands.gd",
	"res://addons/godot_mcp/commands/runtime_commands.gd",
	"res://addons/godot_mcp/commands/engine_commands.gd",
	"res://addons/godot_mcp/commands/input_commands.gd",
	"res://addons/godot_mcp/commands/animation_commands.gd",
	"res://addons/godot_mcp/commands/animation_tree_commands.gd",
	"res://addons/godot_mcp/commands/tilemap_commands.gd",
	"res://addons/godot_mcp/commands/theme_commands.gd",
	"res://addons/godot_mcp/commands/shader_commands.gd",
	"res://addons/godot_mcp/commands/particle_commands.gd",
	"res://addons/godot_mcp/commands/scene_3d_commands.gd",
	"res://addons/godot_mcp/commands/scene_2d_commands.gd",
	"res://addons/godot_mcp/commands/material_commands.gd",
	"res://addons/godot_mcp/commands/csg_commands.gd",
	"res://addons/godot_mcp/commands/gridmap_commands.gd",
	"res://addons/godot_mcp/commands/scatter_commands.gd",
	"res://addons/godot_mcp/commands/lighting_commands.gd",
	"res://addons/godot_mcp/commands/path_commands.gd",
	"res://addons/godot_mcp/commands/pcg_commands.gd",
	"res://addons/godot_mcp/commands/wfc_commands.gd",
	"res://addons/godot_mcp/commands/mesh_commands.gd",
	"res://addons/godot_mcp/commands/doc_commands.gd",
	"res://addons/godot_mcp/commands/cleanup_commands.gd",
	"res://addons/godot_mcp/commands/physics_commands.gd",
	"res://addons/godot_mcp/commands/navigation_commands.gd",
	"res://addons/godot_mcp/commands/audio_commands.gd",
	"res://addons/godot_mcp/commands/input_map_commands.gd",
	"res://addons/godot_mcp/commands/resource_commands.gd",
	"res://addons/godot_mcp/commands/fs_commands.gd",
	"res://addons/godot_mcp/commands/import_commands.gd",
	"res://addons/godot_mcp/commands/multiplayer_commands.gd",
	"res://addons/godot_mcp/commands/skeleton_commands.gd",
	"res://addons/godot_mcp/commands/localization_commands.gd",
	"res://addons/godot_mcp/commands/ui_commands.gd",
	"res://addons/godot_mcp/commands/camera_commands.gd",
	"res://addons/godot_mcp/commands/analysis_commands.gd",
	"res://addons/godot_mcp/commands/batch_commands.gd",
	"res://addons/godot_mcp/commands/profiling_commands.gd",
	"res://addons/godot_mcp/commands/export_commands.gd",
	"res://addons/godot_mcp/commands/test_commands.gd",
	"res://addons/godot_mcp/commands/android_commands.gd",
	"res://addons/godot_mcp/commands/stats_commands.gd",
]


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	_register(_BUILTIN_GROUPS)
	_register_project_commands()


func _register(paths: Array) -> void:
	for path: String in paths:
		var script: Variant = load(path)
		# `is Script` is not enough: load() on a file that failed to PARSE hands back
		# a GDScript object anyway, and calling new() on it is a hard runtime error
		# that aborts this loop, so every group after the bad one silently vanishes
		# (seen exactly that way while testing the fault path). can_instantiate() is
		# what actually reports the compile.
		if not (script is Script) or not (script as Script).can_instantiate():
			_note_unavailable(path, "failed to compile (it names an API this Godot build does not have, or has a syntax error)")
			continue
		var inst: Variant = (script as Script).new()
		if not (inst is Node):
			_note_unavailable(path, "script must instantiate to a Node")
			continue
		var cmd: Node = inst
		cmd.editor_plugin = editor_plugin
		add_child(cmd)
		var commands: Dictionary = cmd.get_commands()
		for method: String in commands:
			_handlers[method] = commands[method]
		# Optional per-command param metadata (the [CliArg] equivalent).
		if cmd.has_method("get_command_docs"):
			var docs: Variant = cmd.get_command_docs()
			if docs is Dictionary:
				for method: String in (docs as Dictionary):
					_docs[method] = (docs as Dictionary)[method]
	print("[MCP] Registered %d commands" % _handlers.size())


## Record a built-in group this engine could not register. Never fatal: the rest
## of the surface still serves, and engine.commands reports what is missing so an
## agent on an older editor sees the gap instead of guessing at a -32601.
func _note_unavailable(path: String, reason: String) -> void:
	_unavailable.append({"file": path.get_file(), "reason": reason})
	push_warning("[MCP] Skipping command group '%s': %s" % [path.get_file(), reason])


## Register project-local command groups from res://mcp_commands/*.gd, so a
## consumer project extends the MCP without forking the addon. Each valid file
## instantiates to a Node exposing get_commands() -> {"group.command": Callable};
## a bad file (fails to load, not a Node, no get_commands) is skipped with a
## push_warning and never breaks startup, and a name that collides with a
## built-in (or an earlier project command) is skipped, since built-ins win.
## Editing a file here needs a full editor restart to recompile (reload_plugin
## re-runs registration but does not re-parse changed GDScript from disk).
func _register_project_commands() -> void:
	const PROJECT_DIR := "res://mcp_commands"
	var dir := DirAccess.open(PROJECT_DIR)
	if dir == null:
		return  # no project-local commands, so skip silently
	var registered := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		# Only .gd files: Godot 4.7 writes a .uid sidecar per script, ignored here.
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
	# can_instantiate() as well as `is Script`: a file that failed to parse still
	# loads as a GDScript, and new() on it faults hard enough to abandon the rest
	# of the scan, which is the one thing this path promises never to do.
	if not (script is Script) or not (script as Script).can_instantiate():
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


# Param names handlers accept beyond their documented list. Kept small on
# purpose: an alias is a deliberate compatibility grant, not a loophole.
const _PARAM_ALIASES := {
	"node.add": ["parent"],
	"node.add_resource": ["properties"],
	"scene.instance": ["path"],
	# `parent` as an alias for `parent_path`, matching node.add. Every one of
	# these handlers reads it deliberately; the grant is what keeps the refusal
	# below from rejecting a call that works.
	"csg.add": ["parent"],
	"doc.note": ["parent"],
	"lighting.add": ["parent"],
	"lighting.add_2d": ["parent"],
	"lighting.occluder_2d": ["parent"],
	"multiplayer.add_spawner": ["parent"],
	"multiplayer.add_synchronizer": ["parent"],
	"navigation.add_link": ["parent"],
	"path.create": ["parent"],
	"pcg.scatter": ["parent"],
	"physics.add_joint": ["parent"],
	"scatter.populate": ["parent"],
	"scene2d.add_sprite": ["parent"],
	"scene2d.add_camera": ["parent"],
	"scene2d.add_body": ["parent"],
	"scene2d.add_animated_sprite": ["parent"],
	"scene3d.add_body": ["parent"],
	"ui.add_container": ["parent"],
	"ui.add_control": ["parent"],
	# Discrete cell coordinates, named in the `cell` param's own description.
	"gridmap.set_cell": ["x", "y", "z"],
	"gridmap.set_cell_variant": ["x", "y", "z"],
	"gridmap.fill": ["x", "y", "z"],
	"gridmap.get_cell": ["x", "y", "z"],
	# Discrete form of `position`.
	"anim_tree.set_blend_point": ["pos_x", "pos_y"],
	# Read only to refuse it with a message naming node.add_resource; granting it
	# lets that specific answer win over this file's generic one.
	"physics.setup_body": ["physics_material_override"],
}

# Params a transport injects for routing; never the handler's business.
const _TRANSPORT_PARAMS := ["game"]


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
		# Before the handler, never after: a refusal that arrives once the work is
		# done reports failure on a call that already mutated the project.
		var rejection := _reject_unknown_params(method, params)
		if not rejection.is_empty():
			result = rejection
		else:
			result = await _handlers[method].call(params)
	# Don't record the dashboard's own stats polling.
	if not method.begins_with("stats."):
		_record(method, not result.has("error"), Time.get_ticks_msec() - t0, params)
	return result


# A param the command's docs don't declare is almost always a typo or a flag
# borrowed from a sibling command, and a handler reads only the keys it knows, so
# the call would otherwise succeed while the value goes nowhere. Three eval
# workers walked into that on 2026-08-26 (`scene.validate --path`, `node.get
# --property`, a trailing `--format`), each getting a plausible answer to a
# question they had not asked.
#
# This used to annotate the success payload instead of refusing, because docs
# were "the best available map of a handler's params, not a proven-complete one".
# They are proven now: scripts/lib/audit_params.py walks every handler for the
# keys it reads and fails `task check` on one the docs don't declare, so an
# undeclared param here is a caller mistake rather than a gap in our own map.
# A param a handler deliberately accepts without advertising goes in
# _PARAM_ALIASES above, which is what keeps this from rejecting a working call.
func _reject_unknown_params(method: String, params: Dictionary) -> Dictionary:
	if not _docs.has(method):
		return {}
	# `documented` is what the caller should have passed and what the refusal
	# names; `declared` additionally carries the unadvertised grants, which are
	# accepted but deliberately absent from --help. Listing a transport param in
	# the refusal made the payload disagree with a help text that reads "Takes no
	# parameters" (eval worker, 2026-08-27).
	var documented := {}
	for p in (_docs[method] as Dictionary).get("params", []):
		if p is Dictionary:
			documented[str((p as Dictionary).get("name", ""))] = true
	var declared := documented.duplicate()
	for alias in _PARAM_ALIASES.get(method, []):
		declared[alias] = true
	for t in _TRANSPORT_PARAMS:
		declared[t] = true
	var unknown: Array = []
	var hints: Array = []
	for key in params:
		var k := str(key)
		if declared.has(k):
			continue
		unknown.append(k)
		var best := ""
		var best_score := 0.0
		for d in documented:
			var score: float = k.similarity(str(d))
			if score > best_score:
				best_score = score
				best = str(d)
		if best_score >= 0.4:
			hints.append("'%s' is not a %s param. Did you mean '%s'?" % [k, method, best])
		else:
			hints.append("'%s' is not a %s param (see %s --help)" % [k, method, method])
	if unknown.is_empty():
		return {}
	return {"error": {
		"code": -32602,
		"message": "Unknown param(s) for %s: %s" % [method, ", ".join(unknown)],
		"data": {
			"unknown_params": unknown,
			"unknown_params_hint": "; ".join(hints),
			"declared_params": documented.keys(),
		},
	}}


func get_available_methods() -> Array:
	return _handlers.keys()


## Per-command param metadata collected at registration ("group.command" ->
## {description, params:[...]}), for commands whose group exposes get_command_docs().
func get_command_docs() -> Dictionary:
	return _docs


## Built-in groups that did not register on this engine, as [{file, reason}].
## Empty on a supported build; non-empty means the surface is short those groups.
func get_unavailable_groups() -> Array:
	return _unavailable


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
