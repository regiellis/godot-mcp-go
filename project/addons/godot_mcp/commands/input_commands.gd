@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Simulate input into the RUNNING game. Fire-and-forget: events are written to
## the game's user dir and injected by the MCPGameInput autoload. Requires a
## scene to be playing (scene.play). Mouse coords are in viewport space.


func get_commands() -> Dictionary:
	return {
		"input.key": _key,
		"input.tap": _tap,
		"input.click": _click,
		"input.move": _move,
		"input.action": _action,
		"input.sequence": _sequence,
	}


func _key(params: Dictionary) -> Dictionary:
	var r := require_string(params, "keycode")
	if r[1] != null:
		return r[1]
	var event := _key_dict(params, r[0])
	event["pressed"] = optional_bool(params, "pressed", true)
	var err := _write([event])
	return err if not err.is_empty() else success({"sent": true, "event": event})


func _tap(params: Dictionary) -> Dictionary:
	var r := require_string(params, "keycode")
	if r[1] != null:
		return r[1]
	var press := _key_dict(params, r[0])
	press["pressed"] = true
	var release := _key_dict(params, r[0])
	release["pressed"] = false
	var err := _write({"sequence_events": [press, release], "frame_delay": optional_int(params, "frame_delay", 1)})
	return err if not err.is_empty() else success({"sent": true, "keycode": r[0], "tapped": true})


func _key_dict(params: Dictionary, keycode: String) -> Dictionary:
	return {
		"type": "key",
		"keycode": keycode,
		"shift": optional_bool(params, "shift", false),
		"ctrl": optional_bool(params, "ctrl", false),
		"alt": optional_bool(params, "alt", false),
	}


func _click(params: Dictionary) -> Dictionary:
	var press := {
		"type": "mouse_button",
		"button": optional_int(params, "button", MOUSE_BUTTON_LEFT),
		"pressed": optional_bool(params, "pressed", true),
		"double_click": optional_bool(params, "double_click", false),
		"position": {"x": float(params.get("x", 0)), "y": float(params.get("y", 0))},
	}
	# UI buttons fire on release, so a press defaults to press+release.
	if press["pressed"] and optional_bool(params, "auto_release", true):
		var release := press.duplicate()
		release["pressed"] = false
		var err := _write({"sequence_events": [press, release], "frame_delay": 1})
		return err if not err.is_empty() else success({"sent": true, "event": press, "auto_release": true})
	var err := _write([press])
	return err if not err.is_empty() else success({"sent": true, "event": press})


func _move(params: Dictionary) -> Dictionary:
	var event := {
		"type": "mouse_motion",
		"position": {"x": float(params.get("x", 0)), "y": float(params.get("y", 0))},
		"relative": {"x": float(params.get("relative_x", 0)), "y": float(params.get("relative_y", 0))},
		"button_mask": optional_int(params, "button_mask", 0),
	}
	if params.has("unhandled"):
		event["unhandled"] = optional_bool(params, "unhandled", false)
	var err := _write([event])
	return err if not err.is_empty() else success({"sent": true, "event": event})


func _action(params: Dictionary) -> Dictionary:
	var r := require_string(params, "action")
	if r[1] != null:
		return r[1]
	var event := {
		"type": "action",
		"action": r[0],
		"pressed": optional_bool(params, "pressed", true),
		"strength": float(params.get("strength", 1.0)),
	}
	var err := _write([event])
	return err if not err.is_empty() else success({"sent": true, "event": event})


func _sequence(params: Dictionary) -> Dictionary:
	if not params.has("events") or not params["events"] is Array:
		return error_invalid_params("'events' array is required")
	var events: Array = params["events"]
	if events.is_empty():
		return error_invalid_params("'events' array is empty")
	for e in events:
		if not e is Dictionary or not (e as Dictionary).has("type"):
			return error_invalid_params("Each event needs a 'type'")
	var frame_delay := optional_int(params, "frame_delay", 1)
	var err: Dictionary
	if frame_delay <= 0:
		err = _write(events)  # all in one frame
	else:
		err = _write({"sequence_events": events, "frame_delay": frame_delay})
	return err if not err.is_empty() else success({"sent": true, "event_count": events.size(), "frame_delay": frame_delay})


## Write the payload to the game's input-command file. Returns {} on success or
## an error dict (game not playing / write failure).
func _write(payload: Variant) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Use scene.play first"})
	var path := get_game_user_dir() + "/mcp_input_commands"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return error_internal("Could not write input commands to %s" % path)
	file.store_string(JSON.stringify(payload))
	file.close()
	return {}


## Every input.* command is fire-and-forget into the RUNNING game and requires a
## scene to be playing (scene.play). Verify effects via runtime.eval/runtime.get.
func get_command_docs() -> Dictionary:
	return {
		"input.key": {
			"description": "Send a key press (or release) to the running game. Fire-and-forget. Requires scene.play.",
			"params": [
				doc_param("keycode", "String", true, "Key name, e.g. 'KEY_SPACE' or 'Space'."),
				doc_param("pressed", "bool", false, "Press (true, default) or release (false)."),
				doc_param("shift", "bool", false, "Hold Shift."),
				doc_param("ctrl", "bool", false, "Hold Ctrl."),
				doc_param("alt", "bool", false, "Hold Alt."),
			],
		},
		"input.tap": {
			"description": "Send a key press+release in quick succession. Fire-and-forget. Requires scene.play.",
			"params": [
				doc_param("keycode", "String", true, "Key name, e.g. 'KEY_SPACE'."),
				doc_param("shift", "bool", false, "Hold Shift."),
				doc_param("ctrl", "bool", false, "Hold Ctrl."),
				doc_param("alt", "bool", false, "Hold Alt."),
				doc_param("frame_delay", "int", false, "Frames between press and release (default 1)."),
			],
		},
		"input.click": {
			"description": "Send a mouse-button event at (--x, --y) in viewport space; defaults to press+release (UI buttons fire on release). Requires scene.play.",
			"params": [
				doc_param("x", "float", false, "Viewport X (default 0)."),
				doc_param("y", "float", false, "Viewport Y (default 0)."),
				doc_param("button", "int", false, "Mouse button index (default 1 = left)."),
				doc_param("pressed", "bool", false, "Press (true, default) or release."),
				doc_param("double_click", "bool", false, "Mark the event as a double-click."),
				doc_param("auto_release", "bool", false, "Auto-send the matching release after a press (default true)."),
			],
		},
		"input.move": {
			"description": "Send a mouse-motion event to (--x, --y), optionally with a relative delta and held-button mask. Requires scene.play.",
			"params": [
				doc_param("x", "float", false, "Target viewport X."),
				doc_param("y", "float", false, "Target viewport Y."),
				doc_param("relative_x", "float", false, "Relative X motion."),
				doc_param("relative_y", "float", false, "Relative Y motion."),
				doc_param("button_mask", "int", false, "Held-button bitmask during the motion."),
				doc_param("unhandled", "bool", false, "Deliver as an unhandled input event."),
			],
		},
		"input.action": {
			"description": "Trigger an input-map action by --action name (press or release, with --strength). Preferred over raw keys. Requires scene.play.",
			"params": [
				doc_param("action", "String", true, "Input-map action name."),
				doc_param("pressed", "bool", false, "Press (true, default) or release."),
				doc_param("strength", "float", false, "Action strength 0..1 (default 1.0)."),
			],
		},
		"input.sequence": {
			"description": "Send a sequence of raw input --events, one per frame (or all in one frame if --frame-delay 0). Requires scene.play.",
			"params": [
				doc_param("events", "Array", true, "List of event dicts, each with a 'type'."),
				doc_param("frame_delay", "int", false, "Frames between events (default 1; 0 = same frame)."),
			],
		},
	}
