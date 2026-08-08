@tool
extends EditorPlugin

## Boots the MCP WebSocket server when the plugin is enabled and tears it down
## on exit. The addon is the SERVER; the godot-mcp Go CLI is a client.

## Game-side autoloads needed for runtime/input commands. Injected on enable so
## the addon works in any project; removed on disable by OWNERSHIP — an entry is
## ours iff its value points at the addon's own service script, so even an
## autoload persisted into project.godot by an earlier session is cleaned up
## (injection saves ProjectSettings, so session-only provenance tracking never
## fired on later sessions and disable left the autoloads behind — the one
## manual step in every ship-the-game flow). Unrelated autoloads are untouched.
const _AUTOLOADS: Array = [
	["MCPGameInspector", "res://addons/godot_mcp/services/game_inspector.gd"],
	["MCPGameInput", "res://addons/godot_mcp/services/game_input.gd"],
]

## Per-project MCP settings, edited in Project → Project Settings and persisted in
## the project's own project.godot. Lets two concurrent projects pin distinct
## ports deterministically. `0` = auto-pick a free port in the 9080-9095 range.
const _PORT_SETTING := "godot_mcp/network/port"

## Opt-in: when on AND the run is a debug build, the game hosts its own slim
## WebSocket server (services/game_server.gd) so the CLI can drive runtime.*/input.*
## directly with --game, no editor in the loop. Default off; the debug-build check
## in MCPGameInspector is the hard gate, so this can never expose a release export.
const _DIRECT_SERVER_SETTING := "godot_mcp/runtime/direct_server"

## Streamable-HTTP MCP endpoint (mcp_http_server.gd), a sibling transport to the
## WebSocket server so an HTTP MCP client reaches the editor with no Go process.
## _MCP_HTTP_SETTING enables it (default true); _HTTP_PORT_SETTING pins its port
## (0 = auto in 9100-9115); _HTTP_TYPED_SETTING toggles typed tools (default true;
## false = only godot_run, for tool-limited clients). All three follow the same
## non-dirtying set_initial_value pattern as the WS port setting.
const _MCP_HTTP_SETTING := "godot_mcp/network/mcp_http"
const _HTTP_PORT_SETTING := "godot_mcp/network/http_port"
const _HTTP_TYPED_SETTING := "godot_mcp/network/http_typed"

var _server: Node
var _http_server: Node
var _router: Node

## Editor activity ring buffer (selection/saves/scene switches/undo bumps),
## polled by editor.activity. Public: editor_commands reaches it via the plugin.
var activity_log: Node

## Editor debugger foothold (break state, sessions, armed breakpoints, the run
## record), behind the debug.* commands. Public: debug_commands and scene_commands
## reach it via the plugin. An EditorDebuggerPlugin is a RefCounted, so it is
## registered rather than added as a child, and dropped rather than freed. Left
## untyped like activity_log: the addon declares no global class_name, so its own
## methods are reached dynamically.
var debugger_bridge: Variant = null

## In-editor stats dashboard, a right-side dock. Reads the router's snapshot
## in-process. Public: commands or scripts may reach it through the plugin.
var stats_panel: Control


func _enter_tree() -> void:
	_register_settings()

	activity_log = preload("res://addons/godot_mcp/services/activity_log.gd").new()
	activity_log.name = "MCPActivityLog"
	add_child(activity_log)
	activity_log.setup(self)

	# In-memory, per-session wiring like the activity log above — NOT a project.godot
	# write, so it belongs here rather than in _enable_plugin. Registering is the only
	# scriptable route to EditorDebuggerSession objects.
	debugger_bridge = preload("res://addons/godot_mcp/services/debugger_bridge.gd").new()
	add_debugger_plugin(debugger_bridge)
	debugger_bridge.ensure_connected()

	_router = preload("res://addons/godot_mcp/command_router.gd").new()
	_router.name = "MCPCommandRouter"
	_router.editor_plugin = self
	add_child(_router)

	# A right-side dock: the panel is a narrow, tall instrument column that stays
	# open beside the work, not a drawer over it. Its tab label IS the node name
	# ("MCP", set in the panel's _init, before this add). In-memory wiring like
	# the activity log — no project.godot write, so it does not belong in
	# _enable_plugin. Built after the router because that is its data source.
	stats_panel = preload("res://addons/godot_mcp/services/stats_panel.gd").new()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, stats_panel)
	stats_panel.setup(_router)

	# Start the HTTP endpoint first (when enabled) so its bound port is known
	# before the WebSocket server writes the shared discovery file.
	if _http_enabled():
		_http_server = preload("res://addons/godot_mcp/mcp_http_server.gd").new()
		_http_server.name = "MCPHttpServer"
		_http_server.command_router = _router
		add_child(_http_server)
		_http_server.start()

	_server = preload("res://addons/godot_mcp/websocket_server.gd").new()
	_server.name = "MCPWebSocketServer"
	_server.command_router = _router
	_server.http_server = _http_server  # null when the HTTP endpoint is disabled
	add_child(_server)
	_server.start()

	# Let the HTTP endpoint refresh the discovery file after a resume-rebind.
	if _http_server:
		_http_server.ws_server = _server


func _exit_tree() -> void:
	if stats_panel:
		remove_control_from_docks(stats_panel)
		stats_panel.queue_free()
		stats_panel = null
	if _http_server:
		_http_server.stop()
		_http_server.queue_free()
	if _server:
		_server.stop()
		_server.queue_free()
	if _router:
		_router.queue_free()
	if activity_log:
		activity_log.queue_free()
	if debugger_bridge:
		remove_debugger_plugin(debugger_bridge)
		debugger_bridge = null


## Autoloads are injected when the plugin is ENABLED and removed only on an actual DISABLE.
##
## They used to ride `_enter_tree` / `_exit_tree`, which run on every editor launch and shutdown — so
## the addon rewrote the host's `project.godot` twice per session. Two costs, both paid by the user:
## the file is permanently dirty, so the autoloads have to be kept out of every commit by hand; and
## the shutdown save can drop OTHER plugins' committed autoloads, because it persists whatever the
## in-memory settings hold after every plugin has torn itself down. Seen 2026-07-27 in a consumer
## project — one quit stripped a different addon's seven autoloads, which would have shipped a game
## that could not boot.
##
## `_enable_plugin` / `_disable_plugin` fire exactly when the user ticks or unticks the plugin, which
## is what these are for. The export flow is unchanged: disabling still removes them, so they never
## reach a release `project.binary`. A project that keeps the plugin enabled should COMMIT the two
## autoloads — nothing re-adds them at load any more, by design.
func _enable_plugin() -> void:
	_inject_autoloads()


func _disable_plugin() -> void:
	_remove_autoloads()


## Register the addon's project settings idempotently. set_initial_value(0) keeps
## the default OUT of project.godot (a value equal to its initial value is never
## persisted), so enabling the plugin never dirties the file; a user-pinned port
## survives disable/enable because we only set the value when the key is absent.
func _register_settings() -> void:
	if not ProjectSettings.has_setting(_PORT_SETTING):
		ProjectSettings.set_setting(_PORT_SETTING, 0)
	ProjectSettings.set_initial_value(_PORT_SETTING, 0)
	ProjectSettings.add_property_info({
		"name": _PORT_SETTING,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,65535,1",  # 0 = auto-pick a free port in 9080-9095
	})
	ProjectSettings.set_as_basic(_PORT_SETTING, true)

	# Same idempotence rules as the port setting: set_initial_value(false) keeps the
	# default OUT of project.godot, and we only seed the value when the key is absent,
	# so a user's choice survives disable/enable. Not removed on disable.
	if not ProjectSettings.has_setting(_DIRECT_SERVER_SETTING):
		ProjectSettings.set_setting(_DIRECT_SERVER_SETTING, false)
	ProjectSettings.set_initial_value(_DIRECT_SERVER_SETTING, false)
	ProjectSettings.add_property_info({
		"name": _DIRECT_SERVER_SETTING,
		"type": TYPE_BOOL,
	})
	ProjectSettings.set_as_basic(_DIRECT_SERVER_SETTING, true)

	# HTTP endpoint enable (default true): a bool kept out of project.godot by
	# set_initial_value(true); only false (a user opt-out) is ever persisted.
	if not ProjectSettings.has_setting(_MCP_HTTP_SETTING):
		ProjectSettings.set_setting(_MCP_HTTP_SETTING, true)
	ProjectSettings.set_initial_value(_MCP_HTTP_SETTING, true)
	ProjectSettings.add_property_info({
		"name": _MCP_HTTP_SETTING,
		"type": TYPE_BOOL,
	})
	ProjectSettings.set_as_basic(_MCP_HTTP_SETTING, true)

	# HTTP port (0 = auto-pick a free port in 9100-9115), same non-dirtying rules
	# as the WS port setting.
	if not ProjectSettings.has_setting(_HTTP_PORT_SETTING):
		ProjectSettings.set_setting(_HTTP_PORT_SETTING, 0)
	ProjectSettings.set_initial_value(_HTTP_PORT_SETTING, 0)
	ProjectSettings.add_property_info({
		"name": _HTTP_PORT_SETTING,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,65535,1",  # 0 = auto-pick a free port in 9100-9115
	})
	ProjectSettings.set_as_basic(_HTTP_PORT_SETTING, true)

	# HTTP typed tools (default true): false lists only godot_run, for tool-limited
	# MCP clients (the serve --typed=false role).
	if not ProjectSettings.has_setting(_HTTP_TYPED_SETTING):
		ProjectSettings.set_setting(_HTTP_TYPED_SETTING, true)
	ProjectSettings.set_initial_value(_HTTP_TYPED_SETTING, true)
	ProjectSettings.add_property_info({
		"name": _HTTP_TYPED_SETTING,
		"type": TYPE_BOOL,
	})
	ProjectSettings.set_as_basic(_HTTP_TYPED_SETTING, true)


## Whether the streamable-HTTP MCP endpoint should run (default true when unset).
func _http_enabled() -> bool:
	return bool(ProjectSettings.get_setting(_MCP_HTTP_SETTING, true))


func _inject_autoloads() -> void:
	var changed := false
	for entry: Array in _AUTOLOADS:
		var key := "autoload/" + (entry[0] as String)
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, "*" + (entry[1] as String))
			changed = true
	if changed:
		ProjectSettings.save()


func _remove_autoloads() -> void:
	# Ownership by content, not session provenance: remove an entry only when it
	# still points at the addon's own script, so a user's unrelated autoload of
	# the same name survives and a persisted injection from any session is gone.
	var changed := false
	for entry: Array in _AUTOLOADS:
		var key := "autoload/" + (entry[0] as String)
		if not ProjectSettings.has_setting(key):
			continue
		var value := str(ProjectSettings.get_setting(key))
		if value.trim_prefix("*") == (entry[1] as String):
			ProjectSettings.set_setting(key, null)
			changed = true
	if changed:
		ProjectSettings.save()
