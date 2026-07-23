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

var _server: Node
var _router: Node


func _enter_tree() -> void:
	_register_settings()
	_inject_autoloads()

	_router = preload("res://addons/godot_mcp/command_router.gd").new()
	_router.name = "MCPCommandRouter"
	_router.editor_plugin = self
	add_child(_router)

	_server = preload("res://addons/godot_mcp/websocket_server.gd").new()
	_server.name = "MCPWebSocketServer"
	_server.command_router = _router
	add_child(_server)
	_server.start()


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server.queue_free()
	if _router:
		_router.queue_free()
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
