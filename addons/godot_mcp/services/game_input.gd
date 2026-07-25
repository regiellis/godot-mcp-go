extends Node

## Autoload that runs INSIDE the played game (declared in project.godot). It
## polls user://mcp_input_commands for events written by the editor-side input
## commands and injects them via Input.parse_input_event / viewport.push_input.
## Fire-and-forget: the editor does not wait for a response.

const COMMANDS_PATH := "user://mcp_input_commands"

var _queue: Array = []        # pending sequence events
var _frame_delay: int = 1     # frames between sequence events
var _frames_waited: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if not _queue.is_empty():
		_frames_waited += 1
		if _frames_waited >= _frame_delay:
			_frames_waited = 0
			_dispatch_next()
	if FileAccess.file_exists(COMMANDS_PATH):
		_read_commands()


func _read_commands() -> void:
	var file := FileAccess.open(COMMANDS_PATH, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	DirAccess.remove_absolute(COMMANDS_PATH)

	var parsed = JSON.parse_string(text)
	if parsed == null:
		push_warning("[MCP Input] Failed to parse input commands")
		return
	inject_payload(parsed)


## Inject an input payload built by an MCP command. Shared by the editor file-IPC
## path (_read_commands) and the in-game direct server (game_server.gd), so both
## reuse the same event-creation/injection handlers below. A payload is either a
## single event dict, an Array of event dicts, or a {sequence_events, frame_delay}
## dict that spaces the events one per N frames.
func inject_payload(payload: Variant) -> void:
	if payload is Dictionary and payload.has("sequence_events"):
		_queue = (payload["sequence_events"] as Array).duplicate()
		_frame_delay = maxi(int(payload.get("frame_delay", 1)), 1)
		_frames_waited = 0
		_dispatch_next()
		return
	var events: Array = payload if payload is Array else [payload]
	for data in events:
		_inject(data)


func _dispatch_next() -> void:
	if _queue.is_empty():
		return
	_inject(_queue.pop_front())


func _inject(data: Dictionary) -> void:
	var event := _create_event(data)
	if event == null:
		return
	# Drag motions (button held) bypass GUI to reach _unhandled_input unless the
	# caller explicitly opts back in with "unhandled": false.
	var unhandled: bool
	if data.has("unhandled"):
		unhandled = bool(data["unhandled"])
	else:
		unhandled = event is InputEventMouseMotion and event.button_mask != 0
	var vp := get_viewport()
	if unhandled and vp != null:
		vp.push_input(event, true)
	else:
		Input.parse_input_event(event)


func _create_event(data: Dictionary) -> InputEvent:
	match data.get("type", ""):
		"key": return _key_event(data)
		"mouse_button": return _mouse_button_event(data)
		"mouse_motion": return _mouse_motion_event(data)
		"action": return _action_event(data)
		_:
			push_warning("[MCP Input] Unknown event type: %s" % data.get("type", ""))
			return null


func _key_event(data: Dictionary) -> InputEventKey:
	var event := InputEventKey.new()
	var keycode_str: String = data.get("keycode", "")
	if keycode_str.begins_with("KEY_"):
		var c := ClassDB.class_get_integer_constant("@GlobalScope", keycode_str)
		event.keycode = c if c != 0 else OS.find_keycode_from_string(keycode_str.substr(4))
	else:
		event.keycode = OS.find_keycode_from_string(keycode_str)
	event.pressed = data.get("pressed", true)
	event.shift_pressed = data.get("shift", false)
	event.ctrl_pressed = data.get("ctrl", false)
	event.alt_pressed = data.get("alt", false)
	return event


## Godot applies viewport.get_final_transform() to mouse events internally, so
## convert the caller's viewport coords to window space before dispatch.
func _to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	return vp.get_final_transform() * pos if vp else pos


func _position(data: Dictionary) -> Vector2:
	var pos = data.get("position", null)
	if pos is Dictionary:
		return Vector2(float(pos.get("x", 0)), float(pos.get("y", 0)))
	return Vector2(float(data.get("x", 0)), float(data.get("y", 0)))


func _mouse_button_event(data: Dictionary) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = data.get("button", MOUSE_BUTTON_LEFT)
	event.pressed = data.get("pressed", true)
	event.double_click = data.get("double_click", false)
	var win := _to_window(_position(data))
	event.position = win
	event.global_position = win
	return event


func _mouse_motion_event(data: Dictionary) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	var win := _to_window(_position(data))
	event.position = win
	event.global_position = win
	var rel := Vector2(float(data.get("relative_x", 0)), float(data.get("relative_y", 0)))
	var rd = data.get("relative", null)
	if rd is Dictionary:
		rel = Vector2(float(rd.get("x", 0)), float(rd.get("y", 0)))
	var vp := get_viewport()
	event.relative = rel * vp.get_final_transform().get_scale() if vp else rel
	event.button_mask = int(data.get("button_mask", 0))
	return event


func _action_event(data: Dictionary) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = data.get("action", "")
	event.pressed = data.get("pressed", true)
	event.strength = float(data.get("strength", 1.0))
	return event
