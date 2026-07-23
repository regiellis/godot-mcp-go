extends Node

## Autoload that runs INSIDE the played game (declared in project.godot). It
## brokers inspection commands from the editor over file IPC: it polls
## user://mcp_game_request, runs the command against the live scene tree, and
## writes user://mcp_game_response. Not @tool — it does nothing in the editor.
##
## Most commands respond immediately. A handful are STATEFUL: they set internal
## state and only call _respond() once the operation completes over several
## frames. The single _process() drives that state machine; while IDLE it polls
## the request file and dispatches via _handle_request().

const PropertyParser := preload("res://addons/godot_mcp/utils/property_parser.gd")
const GameErrorLog := preload("res://addons/godot_mcp/services/game_error_log.gd")
const GameServer := preload("res://addons/godot_mcp/services/game_server.gd")
const REQUEST_PATH := "user://mcp_game_request"
const RESPONSE_PATH := "user://mcp_game_response"
const DIRECT_SERVER_SETTING := "godot_mcp/runtime/direct_server"

enum State { IDLE, CAPTURING_FRAMES, MONITORING, RECORDING, MOVING_TO, WATCHING_SIGNALS }

var _state: int = State.IDLE

# Captures runtime errors/warnings from this game process for runtime.errors.
var _error_log: Logger = null

# When set, _respond() delivers the result to this Callable instead of writing the
# file-IPC response. This is how the in-game direct server (game_server.gd) reuses
# the same command handlers: it calls run_command() with a sink that ships the
# result over its WebSocket. Empty for the editor file-IPC path (writes the file).
var _sink: Callable = Callable()

# The direct WebSocket server, created in _ready only for a debug build with the
# godot_mcp/runtime/direct_server setting on. Null otherwise (and in every export).
var _game_server: Node = null

# Frame capture state
var _capture_frames_remaining: int = 0
var _capture_frame_interval: int = 1
var _capture_frame_counter: int = 0
var _capture_half_res: bool = true
var _captured_images: Array = []
var _capture_node_path: String = ""
var _capture_node_props: Array = []
var _capture_frame_data: Array = []

# Monitor state
var _monitor_node_path: String = ""
var _monitor_properties: Array = []
var _monitor_frames_remaining: int = 0
var _monitor_frame_interval: int = 1
var _monitor_frame_counter: int = 0
var _monitor_timeline: Array = []

# Recording state
var _recording_events: Array = []
var _recording_start_msec: int = 0
var _input_relay: Node = null

# Signal watch state
var _watch_nodes: Array = []
var _watch_signal_filter: Array = []
var _watch_log: Array = []
var _watch_start_msec: int = 0
var _watch_duration_ms: int = 5000
var _watch_connections: Array = []

# Move-to state
var _moveto_target: Vector3 = Vector3.ZERO
var _moveto_player: Node3D = null
var _moveto_camera_pivot: Node3D = null
var _moveto_arrival_radius: float = 1.5
var _moveto_timeout: float = 15.0
var _moveto_elapsed: float = 0.0
var _moveto_run: bool = false
var _moveto_look_at: bool = true
var _moveto_keys_held: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep responding even if paused
	_error_log = GameErrorLog.new()
	OS.add_logger(_error_log)
	_maybe_start_direct_server()


## Start the in-game direct WebSocket server iff BOTH the build is a debug build
## AND the godot_mcp/runtime/direct_server setting is on. The debug-build check is
## the hard gate: this server is impossible in a release export even if the setting
## somehow ships enabled.
func _maybe_start_direct_server() -> void:
	if not OS.is_debug_build():
		return
	if not bool(ProjectSettings.get_setting(DIRECT_SERVER_SETTING, false)):
		return
	_game_server = GameServer.new()
	_game_server.name = "MCPGameServer"
	_game_server.inspector = self
	add_child(_game_server)
	_game_server.start()


func _process(delta: float) -> void:
	match _state:
		State.IDLE:
			# Don't read a file-IPC request while a direct-server command holds the
			# response sink — that would clobber it (_respond routes by _sink).
			if not _sink.is_valid() and FileAccess.file_exists(REQUEST_PATH):
				_handle_request()
		State.CAPTURING_FRAMES:
			_process_capture()
		State.MONITORING:
			_process_monitor()
		State.RECORDING:
			# Still accept new commands while recording (e.g. stop_recording).
			if not _sink.is_valid() and FileAccess.file_exists(REQUEST_PATH):
				_handle_request()
		State.MOVING_TO:
			_process_move_to(delta)
		State.WATCHING_SIGNALS:
			_process_watch_signals()


func _handle_request() -> void:
	var file := FileAccess.open(REQUEST_PATH, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	DirAccess.remove_absolute(REQUEST_PATH)

	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		_respond({"error": "Invalid request JSON"})
		return

	# The editor file-IPC path: _respond writes the response file, so clear any sink.
	_sink = Callable()

	# A new request aborts any in-progress stateful operation.
	if _state != State.RECORDING:
		_state = State.IDLE

	_dispatch(parsed.get("command", ""), parsed.get("params", {}))


## Shared entry for the in-game direct WebSocket server (game_server.gd). Runs the
## same game-side command handlers used over file IPC, but delivers the result to
## `sink` (a Callable taking one Dictionary) instead of the response file. The
## caller MUST serialize calls — one command is in flight at a time (see is_busy).
func run_command(command: String, params: Dictionary, sink: Callable) -> void:
	if _state != State.RECORDING:
		_state = State.IDLE
	_sink = sink
	_dispatch(command, params)


## True while a command is in flight (a response is still pending or a stateful
## operation is running). RECORDING is not "busy" — it is a resting state that
## still accepts new commands. Lets game_server.gd avoid clobbering a file-IPC
## command in an editor-launched game where both channels are live at once.
func is_busy() -> bool:
	return _sink.is_valid() or (_state != State.IDLE and _state != State.RECORDING)


## Route a game-side command name to its handler. Shared by the file-IPC path
## (_handle_request) and the direct server (run_command); handlers are unchanged
## and reach the response through _respond, which routes to the file or the sink.
func _dispatch(command: String, params: Dictionary) -> void:
	match command:
		"get_scene_tree": _get_scene_tree(params)
		"get_node_properties": _get_node_properties(params)
		"set_node_property": _set_node_property(params)
		"execute_script": _execute_script(params)
		"screenshot": _screenshot(params)
		"capture_frames": _capture_frames(params)
		"monitor_properties": _cmd_monitor(params)
		"start_recording": _start_recording(params)
		"stop_recording": _stop_recording(params)
		"replay_recording": _replay_recording(params)
		"find_nodes_by_script": _find_nodes_by_script(params)
		"get_autoload": _get_autoload(params)
		"batch_get_properties": _batch_get_properties(params)
		"find_ui_elements": _find_ui_elements(params)
		"click_button_by_text": _click_button_by_text(params)
		"wait_for_node": _wait_for_node(params)
		"find_nearby_nodes": _find_nearby_nodes(params)
		"navigate_to": _navigate_to(params)
		"move_to": _move_to(params)
		"watch_signals": _watch_signals(params)
		"await_signal": _await_signal(params)
		"get_runtime_errors": _get_runtime_errors(params)
		"assert_node_state": _assert_node_state(params)
		_: _respond({"error": "Unknown command: %s" % command})


func _assert_node_state(params: Dictionary) -> void:
	var node := _resolve(params.get("node_path", ""))
	if node == null:
		_respond({"error": "Node not found: %s" % params.get("node_path", "")})
		return
	var prop: String = params.get("property", "")
	if not prop in node:
		_respond({"error": "Property '%s' not found on %s" % [prop, node.get_class()]})
		return
	var actual: Variant = node.get(prop)
	var expected: Variant = params.get("expected")
	var op: String = params.get("operator", "eq")
	_respond({
		"passed": _compare(actual, expected, op),
		"node_path": _rel(node),
		"property": prop,
		"operator": op,
		"actual": PropertyParser.serialize_value(actual),
		"expected": expected,
	})


func _compare(actual: Variant, expected: Variant, op: String) -> bool:
	match op:
		"eq": return str(actual) == str(expected) or actual == expected
		"neq": return not (str(actual) == str(expected) or actual == expected)
		"gt": return float(actual) > float(expected)
		"lt": return float(actual) < float(expected)
		"gte": return float(actual) >= float(expected)
		"lte": return float(actual) <= float(expected)
		"contains": return str(actual).contains(str(expected))
		"type_is": return actual != null and (actual is Object and (actual as Object).get_class() == str(expected) or type_string(typeof(actual)) == str(expected))
	return false


func _respond(data: Dictionary) -> void:
	# Direct server: hand the result to the pending sink (one-shot) and stop —
	# never also write the file. Editor file-IPC: write the response file.
	if _sink.is_valid():
		var sink := _sink
		_sink = Callable()
		sink.call(data)
		return
	var file := FileAccess.open(RESPONSE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


## Resolve a node path against the running scene root. Accepts ".", a relative
## path ("UI/Score"), the root name, or an absolute "/root/..." path.
func _resolve(node_path: String) -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	if node_path.is_empty() or node_path == "." or node_path == String(scene.name):
		return scene
	if node_path.begins_with("/root"):
		return get_node_or_null(NodePath(node_path))
	if scene.has_node(node_path):
		return scene.get_node(node_path)
	return null


func _rel(node: Node) -> String:
	var scene := get_tree().current_scene
	return "." if node == scene else str(scene.get_path_to(node))


func _get_scene_tree(params: Dictionary) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		_respond({"error": "No current scene is running"})
		return
	_respond({"tree": _tree(scene, scene, int(params.get("max_depth", -1)))})


func _tree(node: Node, root: Node, max_depth: int, depth: int = 0) -> Dictionary:
	var result := {
		"name": String(node.name),
		"type": node.get_class(),
		"path": "." if node == root else str(root.get_path_to(node)),
	}
	var script: Script = node.get_script()
	if script != null:
		result["script"] = script.resource_path
	if max_depth == -1 or depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(_tree(child, root, max_depth, depth + 1))
		if not children.is_empty():
			result["children"] = children
	return result


func _get_node_properties(params: Dictionary) -> void:
	var node := _resolve(params.get("node_path", ""))
	if node == null:
		_respond({"error": "Node not found: %s" % params.get("node_path", "")})
		return
	var filter: Array = params.get("properties", [])
	var props: Dictionary = {}
	if filter.is_empty():
		for prop_info in node.get_property_list():
			var pn: String = prop_info["name"]
			if not (prop_info["usage"] & PROPERTY_USAGE_EDITOR):
				continue
			if pn.begins_with("_") or pn == "script":
				continue
			props[pn] = PropertyParser.serialize_value(node.get(pn))
	else:
		for pn in filter:
			props[String(pn)] = PropertyParser.serialize_value(node.get(String(pn)))
	_respond({"node_path": _rel(node), "type": node.get_class(), "properties": props})


func _set_node_property(params: Dictionary) -> void:
	var node := _resolve(params.get("node_path", ""))
	if node == null:
		_respond({"error": "Node not found: %s" % params.get("node_path", "")})
		return
	var property: String = params.get("property", "")
	if property.is_empty():
		_respond({"error": "property is required"})
		return
	if not params.has("value"):
		_respond({"error": "value is required"})
		return
	if not property in node:
		_respond({"error": "Property '%s' not found on %s" % [property, node.get_class()]})
		return
	var old_value: Variant = node.get(property)
	node.set(property, PropertyParser.parse_value(params["value"], typeof(old_value)))
	_respond({
		"node_path": _rel(node),
		"property": property,
		"old_value": PropertyParser.serialize_value(old_value),
		"new_value": PropertyParser.serialize_value(node.get(property)),
	})


func _execute_script(params: Dictionary) -> void:
	var code: String = params.get("code", "")
	if code.is_empty():
		_respond({"error": "code is required"})
		return
	var wrapped := "extends Node\n\nvar output: Array = []\n\nfunc emit(value: Variant) -> void:\n\toutput.append(str(value))\n\nfunc run() -> void:\n%s\n" % _indent(code)
	var script := GDScript.new()
	script.source_code = wrapped
	if script.reload() != OK:
		_respond({"error": "Script compilation failed"})
		return
	var node := Node.new()
	node.set_script(script)
	add_child(node)
	if node.has_method("run"):
		node.run()
	var out: Variant = node.get("output")
	node.queue_free()
	_respond({"output": out if out is Array else []})


func _indent(code: String) -> String:
	var out: PackedStringArray = []
	for line in code.split("\n"):
		out.append("\t" + line)
	return "\n".join(out)


func _screenshot(params: Dictionary) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_respond({"error": "Could not capture game viewport"})
		return
	var save_path: String = params.get("save_path", "")
	if not save_path.is_empty():
		var abs_path := ProjectSettings.globalize_path(save_path) if save_path.begins_with("res://") or save_path.begins_with("user://") else save_path
		if image.save_png(abs_path) != OK:
			_respond({"error": "Failed to save screenshot"})
			return
		_respond({"saved_path": save_path, "width": image.get_width(), "height": image.get_height(), "format": "png"})
		return
	_respond({
		"image_base64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"width": image.get_width(),
		"height": image.get_height(),
		"format": "png",
	})


# ── capture_frames (stateful) ─────────────────────────────────────────────────

func _capture_frames(params: Dictionary) -> void:
	var count: int = clampi(int(params.get("count", 5)), 1, 30)
	var interval: int = maxi(int(params.get("frame_interval", 10)), 1)
	_capture_half_res = bool(params.get("half_resolution", true))

	_capture_node_path = ""
	_capture_node_props = []
	_capture_frame_data.clear()
	var node_data: Dictionary = params.get("node_data", {})
	if not node_data.is_empty():
		_capture_node_path = node_data.get("node_path", "")
		_capture_node_props = node_data.get("properties", [])

	_captured_images.clear()
	_capture_frames_remaining = count
	_capture_frame_interval = interval
	_capture_frame_counter = 0
	_state = State.CAPTURING_FRAMES
	_capture_one_frame()


func _process_capture() -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		_state = State.IDLE
		_handle_request()
		return

	_capture_frame_counter += 1
	if _capture_frame_counter >= _capture_frame_interval:
		_capture_frame_counter = 0
		_capture_one_frame()


func _capture_one_frame() -> void:
	var viewport := get_viewport()
	if viewport == null:
		_finish_capture()
		return

	var image := viewport.get_texture().get_image()
	if image == null:
		_finish_capture()
		return

	if _capture_half_res:
		var new_size := image.get_size() / 2
		if new_size.x > 0 and new_size.y > 0:
			image.resize(new_size.x, new_size.y, Image.INTERPOLATE_BILINEAR)

	_captured_images.append(Marshalls.raw_to_base64(image.save_png_to_buffer()))

	if not _capture_node_path.is_empty() and not _capture_node_props.is_empty():
		var snap: Dictionary = {}
		var node := _resolve(_capture_node_path)
		if node:
			for prop_name in _capture_node_props:
				snap[String(prop_name)] = PropertyParser.serialize_value(node.get(String(prop_name)))
		_capture_frame_data.append(snap)

	_capture_frames_remaining -= 1
	if _capture_frames_remaining <= 0:
		_finish_capture()


func _finish_capture() -> void:
	_state = State.IDLE
	var viewport := get_viewport()
	var w := 0
	var h := 0
	if viewport:
		var size := viewport.get_visible_rect().size
		if _capture_half_res:
			size /= 2
		w = int(size.x)
		h = int(size.y)

	var response := {
		"frames": _captured_images,
		"count": _captured_images.size(),
		"width": w,
		"height": h,
		"half_resolution": _capture_half_res,
	}
	if not _capture_frame_data.is_empty():
		response["frame_data"] = _capture_frame_data
	_respond(response)
	_captured_images.clear()
	_capture_frame_data.clear()


# ── monitor_properties (stateful) ─────────────────────────────────────────────

func _cmd_monitor(params: Dictionary) -> void:
	_monitor_node_path = params.get("node_path", "")
	_monitor_properties = params.get("properties", [])
	if _monitor_node_path.is_empty() or _monitor_properties.is_empty():
		_respond({"error": "node_path and properties are required"})
		return

	var frame_count: int = clampi(int(params.get("frame_count", 60)), 1, 600)
	var interval: int = maxi(int(params.get("frame_interval", 1)), 1)

	_monitor_timeline.clear()
	_monitor_frames_remaining = frame_count
	_monitor_frame_interval = interval
	_monitor_frame_counter = 0
	_state = State.MONITORING
	_sample_one_frame()


func _process_monitor() -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		_state = State.IDLE
		_handle_request()
		return

	_monitor_frame_counter += 1
	if _monitor_frame_counter >= _monitor_frame_interval:
		_monitor_frame_counter = 0
		_sample_one_frame()


func _sample_one_frame() -> void:
	var sample: Dictionary = {}
	var node := _resolve(_monitor_node_path)
	if node == null:
		for prop_name in _monitor_properties:
			sample[String(prop_name)] = null
	else:
		for prop_name in _monitor_properties:
			sample[String(prop_name)] = PropertyParser.serialize_value(node.get(String(prop_name)))
	_monitor_timeline.append(sample)

	_monitor_frames_remaining -= 1
	if _monitor_frames_remaining <= 0:
		_finish_monitor()


func _finish_monitor() -> void:
	_state = State.IDLE
	_respond({
		"node_path": _monitor_node_path,
		"properties": _monitor_properties,
		"samples": _monitor_timeline,
		"sample_count": _monitor_timeline.size(),
		"frame_interval": _monitor_frame_interval,
	})
	_monitor_timeline.clear()


# ── Recording ─────────────────────────────────────────────────────────────────

## Input is captured via a small relay child whose own _input forwards events to
## _record_event(). This keeps the autoload itself free of the _input virtual.
func _start_recording(_params: Dictionary) -> void:
	_recording_events.clear()
	_recording_start_msec = Time.get_ticks_msec()
	_state = State.RECORDING
	_ensure_input_relay()
	_respond({"recording": true, "message": "Recording started"})


func _stop_recording(_params: Dictionary) -> void:
	_destroy_input_relay()
	_state = State.IDLE
	var events := _recording_events.duplicate()
	var duration_ms := Time.get_ticks_msec() - _recording_start_msec
	_respond({
		"recording": false,
		"events": events,
		"event_count": events.size(),
		"duration_ms": duration_ms,
	})


func _ensure_input_relay() -> void:
	if is_instance_valid(_input_relay):
		return
	var relay_src := "extends Node\n" \
		+ "var target: Object = null\n" \
		+ "func _input(event: InputEvent) -> void:\n" \
		+ "\tif target and is_instance_valid(target):\n" \
		+ "\t\ttarget.call(\"_record_event\", event)\n"
	var script := GDScript.new()
	script.source_code = relay_src
	if script.reload() != OK:
		return
	_input_relay = Node.new()
	_input_relay.set_script(script)
	_input_relay.set("target", self)
	_input_relay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_input_relay)


func _destroy_input_relay() -> void:
	if is_instance_valid(_input_relay):
		_input_relay.queue_free()
	_input_relay = null


## Called by the input relay child. Records the event if currently recording.
func _record_event(event: InputEvent) -> void:
	if _state != State.RECORDING:
		return

	var time_ms := Time.get_ticks_msec() - _recording_start_msec
	var data: Dictionary = {"time_ms": time_ms}

	if event is InputEventKey:
		var key: InputEventKey = event
		data["type"] = "key"
		data["keycode"] = OS.get_keycode_string(key.keycode) if key.keycode != 0 else ""
		data["physical_keycode"] = OS.get_keycode_string(key.physical_keycode) if key.physical_keycode != 0 else ""
		data["pressed"] = key.pressed
		data["shift"] = key.shift_pressed
		data["ctrl"] = key.ctrl_pressed
		data["alt"] = key.alt_pressed
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		data["type"] = "mouse_button"
		data["button"] = mb.button_index
		data["pressed"] = mb.pressed
		data["position"] = {"x": mb.position.x, "y": mb.position.y}
		data["double_click"] = mb.double_click
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		data["type"] = "mouse_motion"
		data["position"] = {"x": mm.position.x, "y": mm.position.y}
		data["relative"] = {"x": mm.relative.x, "y": mm.relative.y}
	elif event is InputEventAction:
		var act: InputEventAction = event
		data["type"] = "action"
		data["action"] = act.action
		data["pressed"] = act.pressed
		data["strength"] = act.strength
	else:
		return

	_recording_events.append(data)


func _replay_recording(params: Dictionary) -> void:
	var events: Array = params.get("events", [])
	if events.is_empty():
		_respond({"error": "No events to replay"})
		return

	var speed: float = float(params.get("speed", 1.0))
	if speed <= 0.0:
		speed = 1.0

	var start_msec := Time.get_ticks_msec()
	for event_data in events:
		if not event_data is Dictionary:
			continue
		var delay_ms: int = int((event_data as Dictionary).get("time_ms", 0))
		var adjusted_delay := int(delay_ms / speed)

		while Time.get_ticks_msec() - start_msec < adjusted_delay:
			await get_tree().process_frame

		var event := _reconstruct_event(event_data)
		if event != null:
			Input.parse_input_event(event)

	_respond({
		"replayed": true,
		"event_count": events.size(),
		"speed": speed,
	})


func _reconstruct_event(data: Dictionary) -> InputEvent:
	match String(data.get("type", "")):
		"key":
			var event := InputEventKey.new()
			var keycode_str: String = data.get("keycode", "")
			if not keycode_str.is_empty():
				event.keycode = OS.find_keycode_from_string(keycode_str)
			event.pressed = data.get("pressed", true)
			event.shift_pressed = data.get("shift", false)
			event.ctrl_pressed = data.get("ctrl", false)
			event.alt_pressed = data.get("alt", false)
			return event
		"mouse_button":
			var event := InputEventMouseButton.new()
			event.button_index = data.get("button", MOUSE_BUTTON_LEFT)
			event.pressed = data.get("pressed", true)
			event.double_click = data.get("double_click", false)
			var pos: Dictionary = data.get("position", {})
			event.position = Vector2(pos.get("x", 0.0), pos.get("y", 0.0))
			event.global_position = event.position
			return event
		"mouse_motion":
			var event := InputEventMouseMotion.new()
			var pos: Dictionary = data.get("position", {})
			event.position = Vector2(pos.get("x", 0.0), pos.get("y", 0.0))
			event.global_position = event.position
			var rel: Dictionary = data.get("relative", {})
			event.relative = Vector2(rel.get("x", 0.0), rel.get("y", 0.0))
			return event
		"action":
			var event := InputEventAction.new()
			event.action = data.get("action", "")
			event.pressed = data.get("pressed", true)
			event.strength = data.get("strength", 1.0)
			return event
	return null


# ── find_nodes_by_script ──────────────────────────────────────────────────────

func _find_nodes_by_script(params: Dictionary) -> void:
	var script_name: String = params.get("script", "")
	if script_name.is_empty():
		_respond({"error": "'script' is required"})
		return

	var root := get_tree().current_scene
	if root == null:
		_respond({"error": "No current scene"})
		return

	var prop_filter: Array = params.get("properties", [])
	var matches: Array = []
	_find_nodes_by_script_recursive(root, script_name.to_lower(), prop_filter, matches)
	_respond({"nodes": matches, "count": matches.size()})


func _find_nodes_by_script_recursive(node: Node, script_filter: String, prop_filter: Array, results: Array) -> void:
	var script: Script = node.get_script()
	var matched := false
	if script:
		if script.resource_path.to_lower().contains(script_filter):
			matched = true
		else:
			var gc := script.get_global_name()
			if gc != &"" and String(gc).to_lower().contains(script_filter):
				matched = true
	if matched:
		var entry := {
			"name": String(node.name),
			"path": _rel(node),
			"type": node.get_class(),
			"script": script.resource_path,
		}
		entry["properties"] = _collect_props(node, prop_filter)
		results.append(entry)

	for child in node.get_children():
		_find_nodes_by_script_recursive(child, script_filter, prop_filter, results)


## Collect serialized properties for a node, honoring an optional explicit filter.
func _collect_props(node: Node, prop_filter: Array) -> Dictionary:
	var props: Dictionary = {}
	if prop_filter.is_empty():
		for prop_info in node.get_property_list():
			var prop_name: String = prop_info["name"]
			if not (prop_info["usage"] & PROPERTY_USAGE_EDITOR):
				continue
			if prop_name.begins_with("_") or prop_name == "script":
				continue
			props[prop_name] = PropertyParser.serialize_value(node.get(prop_name))
	else:
		for prop_name in prop_filter:
			props[String(prop_name)] = PropertyParser.serialize_value(node.get(String(prop_name)))
	return props


# ── get_autoload ──────────────────────────────────────────────────────────────

func _get_autoload(params: Dictionary) -> void:
	var autoload_name: String = params.get("name", "")
	if autoload_name.is_empty():
		_respond({"error": "'name' is required"})
		return

	var node := get_node_or_null(NodePath("/root/" + autoload_name))
	if node == null:
		_respond({"error": "Autoload not found: %s" % autoload_name})
		return

	var result := {
		"name": autoload_name,
		"path": str(node.get_path()),
		"type": node.get_class(),
		"properties": _collect_props(node, params.get("properties", [])),
	}
	var script: Script = node.get_script()
	if script:
		result["script"] = script.resource_path
	_respond(result)


# ── batch_get_properties ──────────────────────────────────────────────────────

func _batch_get_properties(params: Dictionary) -> void:
	var nodes: Array = params.get("nodes", [])
	if nodes.is_empty():
		_respond({"error": "'nodes' array is required"})
		return

	var results: Array = []
	for entry in nodes:
		if not entry is Dictionary:
			continue
		var spec: Dictionary = entry
		var node_path: String = spec.get("path", spec.get("node_path", ""))
		var prop_filter: Array = spec.get("properties", [])

		if node_path.is_empty():
			results.append({"path": "", "properties": {}, "error": "Empty path"})
			continue

		var node := _resolve(node_path)
		if node == null:
			results.append({"path": node_path, "properties": {}, "error": "Node not found"})
			continue

		results.append({"path": _rel(node), "properties": _collect_props(node, prop_filter)})

	_respond({"nodes": results, "count": results.size()})


# ── find_ui_elements ──────────────────────────────────────────────────────────

func _find_ui_elements(params: Dictionary) -> void:
	var root := get_tree().current_scene
	if root == null:
		_respond({"error": "No current scene"})
		return

	var type_filter: String = params.get("type_filter", "")
	var elements: Array = []
	_find_ui_recursive(root, type_filter, elements)
	_respond({"elements": elements, "count": elements.size()})


func _find_ui_recursive(node: Node, type_filter: String, results: Array) -> void:
	if node is Control and (node as Control).visible:
		var ctrl: Control = node
		var entry: Dictionary = {}
		var include := false

		if ctrl is Button:
			var btn: Button = ctrl
			entry["type"] = "Button"
			entry["text"] = btn.text
			entry["disabled"] = btn.disabled
			include = true
		elif ctrl is Label:
			entry["type"] = "Label"
			entry["text"] = (ctrl as Label).text
			include = true
		elif ctrl is LineEdit:
			var le: LineEdit = ctrl
			entry["type"] = "LineEdit"
			entry["text"] = le.text
			entry["placeholder"] = le.placeholder_text
			include = true
		elif ctrl is TextEdit:
			entry["type"] = "TextEdit"
			entry["text"] = (ctrl as TextEdit).text.left(200)
			include = true
		elif ctrl is OptionButton:
			var ob: OptionButton = ctrl
			entry["type"] = "OptionButton"
			entry["text"] = ob.text
			entry["selected"] = ob.selected
			include = true
		elif ctrl is CheckBox:
			var cb: CheckBox = ctrl
			entry["type"] = "CheckBox"
			entry["text"] = cb.text
			entry["checked"] = cb.button_pressed
			include = true
		elif ctrl is HSlider or ctrl is VSlider:
			var sl: Range = ctrl
			entry["type"] = "HSlider" if ctrl is HSlider else "VSlider"
			entry["value"] = sl.value
			entry["min"] = sl.min_value
			entry["max"] = sl.max_value
			include = true

		if include and (type_filter.is_empty() or entry.get("type", "") == type_filter):
			var rect := ctrl.get_global_rect()
			entry["name"] = String(ctrl.name)
			entry["path"] = _rel(ctrl)
			entry["rect"] = {
				"x": rect.position.x,
				"y": rect.position.y,
				"width": rect.size.x,
				"height": rect.size.y,
			}
			entry["center"] = {
				"x": rect.position.x + rect.size.x / 2.0,
				"y": rect.position.y + rect.size.y / 2.0,
			}
			results.append(entry)

	for child in node.get_children():
		_find_ui_recursive(child, type_filter, results)


# ── click_button_by_text ──────────────────────────────────────────────────────

func _click_button_by_text(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	var partial: bool = bool(params.get("partial", true))
	if text.is_empty():
		_respond({"error": "'text' is required"})
		return

	var root := get_tree().current_scene
	if root == null:
		_respond({"error": "No current scene"})
		return

	var btn: Button = _find_button_by_text(root, text, partial)
	if btn == null:
		_respond({"error": "No visible button found with text: '%s'" % text})
		return

	var rect := btn.get_global_rect()
	var center := rect.get_center()
	var btn_text_value := btn.text

	# Capture path before clicking — the click may trigger a scene transition
	# that removes the node from the tree.
	var btn_path := _rel(btn) if btn.is_inside_tree() else ""

	# Emit pressed directly — more reliable than Input.parse_input_event for GUI.
	btn.emit_signal("pressed")

	if not is_instance_valid(btn) or not btn.is_inside_tree():
		_respond({
			"clicked": true,
			"button_text": btn_text_value,
			"button_path": btn_path,
			"position": {"x": center.x, "y": center.y},
			"note": "Button was removed from scene tree after click (likely a scene transition)",
		})
		return

	_respond({
		"clicked": true,
		"button_text": btn.text,
		"button_path": _rel(btn),
		"position": {"x": center.x, "y": center.y},
	})


func _find_button_by_text(node: Node, text: String, partial: bool) -> Button:
	if node is Button and (node as Button).visible:
		var btn: Button = node
		var btn_text := btn.text.to_lower().strip_edges()
		var search_text := text.to_lower().strip_edges()
		if partial and btn_text.contains(search_text):
			return btn
		elif not partial and btn_text == search_text:
			return btn

	for child in node.get_children():
		var found := _find_button_by_text(child, text, partial)
		if found != null:
			return found
	return null


# ── wait_for_node (polled via await) ──────────────────────────────────────────

func _wait_for_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_respond({"error": "'node_path' is required"})
		return

	var timeout_sec: float = float(params.get("timeout", 5.0))
	var poll_interval: int = maxi(int(params.get("poll_frames", 5)), 1)

	var attempts := maxi(int(timeout_sec / (poll_interval / 60.0)), 1)

	for i in attempts:
		var node := _resolve(node_path)
		if node != null:
			var result := {
				"found": true,
				"node_path": _rel(node),
				"type": node.get_class(),
				"name": String(node.name),
			}
			var script: Script = node.get_script()
			if script:
				result["script"] = script.resource_path
			_respond(result)
			return

		for _f in poll_interval:
			await get_tree().process_frame

	_respond({
		"found": false,
		"node_path": node_path,
		"error": "Node not found after %.1fs" % timeout_sec,
	})


# ── find_nearby_nodes ─────────────────────────────────────────────────────────

func _find_nearby_nodes(params: Dictionary) -> void:
	var radius: float = float(params.get("radius", 20.0))
	var max_results: int = int(params.get("max_results", 10))
	var type_filter: String = params.get("type_filter", "")
	var group_filter: String = params.get("group_filter", "")

	var origin := Vector3.ZERO
	var position_param: Variant = params.get("position", null)
	if position_param is String:
		var origin_node := _resolve(position_param as String)
		if origin_node == null:
			_respond({"error": "Origin node not found: %s" % position_param})
			return
		if origin_node is Node3D:
			origin = (origin_node as Node3D).global_position
		elif origin_node is Node2D:
			var pos2d: Vector2 = (origin_node as Node2D).global_position
			origin = Vector3(pos2d.x, pos2d.y, 0)
		else:
			_respond({"error": "Origin node is not Node2D or Node3D: %s" % position_param})
			return
	elif position_param is Dictionary:
		var dict: Dictionary = position_param
		origin = Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
	else:
		_respond({"error": "'position' is required (node_path string or {x,y,z} object)"})
		return

	var root := get_tree().current_scene
	if root == null:
		_respond({"error": "No current scene"})
		return

	var candidates: Array = []
	_find_nearby_recursive(root, origin, radius, type_filter, group_filter, candidates)

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["distance"] < b["distance"]
	)

	if candidates.size() > max_results:
		candidates.resize(max_results)

	_respond({
		"origin": {"x": origin.x, "y": origin.y, "z": origin.z},
		"radius": radius,
		"nodes": candidates,
		"count": candidates.size(),
	})


func _find_nearby_recursive(node: Node, origin: Vector3, radius: float, type_filter: String, group_filter: String, results: Array) -> void:
	var pos := Vector3.ZERO
	var is_spatial := false

	if node is Node3D:
		pos = (node as Node3D).global_position
		is_spatial = true
	elif node is Node2D:
		var pos2d: Vector2 = (node as Node2D).global_position
		pos = Vector3(pos2d.x, pos2d.y, 0)
		is_spatial = true

	if is_spatial:
		var diff := pos - origin
		var dist := diff.length()
		if dist <= radius:
			var passes := true
			if not type_filter.is_empty() and not node.is_class(type_filter):
				passes = false
			if not group_filter.is_empty() and not node.is_in_group(group_filter):
				passes = false

			if passes:
				var entry: Dictionary = {
					"node_path": _rel(node),
					"name": String(node.name),
					"type": node.get_class(),
					"distance": snappedf(dist, 0.01),
					"global_position": {"x": snappedf(pos.x, 0.01), "y": snappedf(pos.y, 0.01), "z": snappedf(pos.z, 0.01)},
					"direction": {"x": snappedf(diff.x, 0.01), "y": snappedf(diff.y, 0.01), "z": snappedf(diff.z, 0.01)},
				}
				var script: Script = node.get_script()
				if script:
					entry["script"] = script.resource_path
				results.append(entry)

	for child in node.get_children():
		_find_nearby_recursive(child, origin, radius, type_filter, group_filter, results)


# ── navigate_to (immediate analysis) ──────────────────────────────────────────

func _navigate_to(params: Dictionary) -> void:
	var player_path: String = params.get("player_path", "/root/Main/Player")
	var player := _resolve(player_path)
	if player == null:
		_respond({"error": "Player not found: %s" % player_path})
		return
	if not player is Node3D:
		_respond({"error": "Player is not Node3D: %s" % player_path})
		return
	var player_pos: Vector3 = (player as Node3D).global_position

	var target_param: Variant = params.get("target", null)
	var target_pos := Vector3.ZERO
	if target_param is String:
		var target_node := _resolve(target_param as String)
		if target_node == null:
			_respond({"error": "Target node not found: %s" % target_param})
			return
		if target_node is Node3D:
			target_pos = (target_node as Node3D).global_position
		else:
			_respond({"error": "Target is not Node3D: %s" % target_param})
			return
	elif target_param is Dictionary:
		var dict: Dictionary = target_param
		target_pos = Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
	else:
		_respond({"error": "'target' is required (node_path string or {x,y,z} object)"})
		return

	var world_dir := target_pos - player_pos
	var distance := world_dir.length()
	var flat_dir := Vector3(world_dir.x, 0, world_dir.z).normalized()

	var camera_path: String = params.get("camera_path", "")
	var camera: Camera3D = null
	if not camera_path.is_empty():
		var cam_node := _resolve(camera_path)
		if cam_node is Camera3D:
			camera = cam_node
	else:
		camera = get_viewport().get_camera_3d()

	var suggested_keys: Array = []
	var camera_yaw_delta: float = 0.0

	if camera != null:
		var camera_forward := -camera.global_basis.z
		var cam_flat := Vector3(camera_forward.x, 0, camera_forward.z).normalized()
		var cam_right := Vector3(camera_forward.z, 0, -camera_forward.x).normalized()

		if flat_dir.length() > 0.01:
			var forward_dot := flat_dir.dot(cam_flat)
			var right_dot := flat_dir.dot(cam_right)

			if forward_dot > 0.3:
				suggested_keys.append("KEY_W")
			elif forward_dot < -0.3:
				suggested_keys.append("KEY_S")
			if right_dot > 0.3:
				suggested_keys.append("KEY_D")
			elif right_dot < -0.3:
				suggested_keys.append("KEY_A")

			var angle_to_target := atan2(flat_dir.x, flat_dir.z)
			var cam_yaw := atan2(cam_flat.x, cam_flat.z)
			camera_yaw_delta = angle_to_target - cam_yaw
			while camera_yaw_delta > PI:
				camera_yaw_delta -= TAU
			while camera_yaw_delta < -PI:
				camera_yaw_delta += TAU

	var move_speed: float = float(params.get("move_speed", 5.0))
	var estimated_duration := distance / move_speed if move_speed > 0 else 0.0

	var mouse_sensitivity_scale: float = 400.0 / PI
	var suggested_mouse_x := -camera_yaw_delta * mouse_sensitivity_scale

	_respond({
		"distance": snappedf(distance, 0.01),
		"world_direction": {
			"x": snappedf(world_dir.x, 0.01),
			"y": snappedf(world_dir.y, 0.01),
			"z": snappedf(world_dir.z, 0.01),
		},
		"flat_direction": {
			"x": snappedf(flat_dir.x, 0.01),
			"z": snappedf(flat_dir.z, 0.01),
		},
		"suggested_keys": suggested_keys,
		"camera_rotation_delta": {
			"yaw_radians": snappedf(camera_yaw_delta, 0.001),
			"suggested_mouse_relative_x": snappedf(suggested_mouse_x, 1.0),
		},
		"estimated_duration": snappedf(estimated_duration, 0.1),
		"player_position": {"x": snappedf(player_pos.x, 0.01), "y": snappedf(player_pos.y, 0.01), "z": snappedf(player_pos.z, 0.01)},
		"target_position": {"x": snappedf(target_pos.x, 0.01), "y": snappedf(target_pos.y, 0.01), "z": snappedf(target_pos.z, 0.01)},
	})


# ── move_to (stateful) ────────────────────────────────────────────────────────

func _move_to(params: Dictionary) -> void:
	var player_path: String = params.get("player_path", "/root/Main/Player")
	var player := _resolve(player_path)
	if player == null or not player is Node3D:
		_respond({"error": "Player not found or not Node3D: %s" % player_path})
		return
	_moveto_player = player as Node3D

	var target_param: Variant = params.get("target", null)
	if target_param is String:
		var target_node := _resolve(target_param as String)
		if target_node == null:
			_respond({"error": "Target node not found: %s" % target_param})
			return
		if target_node is Node3D:
			_moveto_target = (target_node as Node3D).global_position
		else:
			_respond({"error": "Target is not Node3D: %s" % target_param})
			return
	elif target_param is Dictionary:
		var dict: Dictionary = target_param
		_moveto_target = Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
	else:
		_respond({"error": "'target' is required (node_path string or {x,y,z} object)"})
		return

	_moveto_camera_pivot = null
	var camera_path: String = params.get("camera_path", "")
	if not camera_path.is_empty():
		var cam_node := _resolve(camera_path)
		if cam_node is Node3D:
			_moveto_camera_pivot = cam_node as Node3D
	else:
		for child in _moveto_player.get_children():
			if child is SpringArm3D:
				_moveto_camera_pivot = child as Node3D
				break
		if _moveto_camera_pivot == null:
			var cam := get_viewport().get_camera_3d()
			if cam != null and cam.get_parent() is Node3D and cam.get_parent() != get_tree().root:
				_moveto_camera_pivot = cam.get_parent() as Node3D

	_moveto_arrival_radius = float(params.get("arrival_radius", 1.5))
	_moveto_timeout = float(params.get("timeout", 15.0))
	_moveto_run = bool(params.get("run", false))
	_moveto_look_at = bool(params.get("look_at_target", true))
	_moveto_elapsed = 0.0
	_moveto_keys_held.clear()

	var dist := _moveto_player.global_position.distance_to(_moveto_target)
	if dist <= _moveto_arrival_radius:
		_respond({
			"success": true,
			"arrived": true,
			"final_distance": snappedf(dist, 0.01),
			"final_position": PropertyParser.serialize_value(_moveto_player.global_position),
			"target_position": PropertyParser.serialize_value(_moveto_target),
			"elapsed_time": 0.0,
		})
		return

	_state = State.MOVING_TO
	_inject_key(KEY_W, true)
	if _moveto_run:
		_inject_key(KEY_SHIFT, true)


func _process_move_to(delta: float) -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		_finish_move_to(false, "Aborted by new command")
		_state = State.IDLE
		_handle_request()
		return

	_moveto_elapsed += delta

	if _moveto_elapsed >= _moveto_timeout:
		_finish_move_to(false, "Timeout after %.1fs" % _moveto_timeout)
		return

	if not is_instance_valid(_moveto_player):
		_finish_move_to(false, "Player node was freed")
		return

	var player_pos := _moveto_player.global_position
	var flat_target := Vector3(_moveto_target.x, player_pos.y, _moveto_target.z)
	var dist := player_pos.distance_to(flat_target)

	if dist <= _moveto_arrival_radius:
		_finish_move_to(true, "Arrived")
		return

	if _moveto_look_at and _moveto_camera_pivot != null and is_instance_valid(_moveto_camera_pivot):
		var dir := flat_target - player_pos
		if dir.length_squared() > 0.01:
			var target_yaw := atan2(-dir.x, -dir.z)
			var current_yaw: float = _moveto_camera_pivot.rotation.y
			var yaw_diff := target_yaw - current_yaw
			while yaw_diff > PI:
				yaw_diff -= TAU
			while yaw_diff < -PI:
				yaw_diff += TAU
			var max_step := 10.0 * delta
			var step := clampf(yaw_diff, -max_step, max_step)
			_moveto_camera_pivot.rotation.y += step


func _finish_move_to(success: bool, message: String) -> void:
	_release_all_keys()
	_state = State.IDLE

	var final_pos := Vector3.ZERO
	var final_dist := 0.0
	if is_instance_valid(_moveto_player):
		final_pos = _moveto_player.global_position
		final_dist = final_pos.distance_to(_moveto_target)

	_respond({
		"success": success,
		"arrived": success,
		"message": message,
		"final_distance": snappedf(final_dist, 0.01),
		"final_position": PropertyParser.serialize_value(final_pos),
		"target_position": PropertyParser.serialize_value(_moveto_target),
		"elapsed_time": snappedf(_moveto_elapsed, 0.01),
	})


func _inject_key(keycode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	if pressed:
		_moveto_keys_held.append(keycode)
	else:
		_moveto_keys_held.erase(keycode)


func _release_all_keys() -> void:
	for keycode in _moveto_keys_held.duplicate():
		var event := InputEventKey.new()
		event.keycode = keycode
		event.pressed = false
		Input.parse_input_event(event)
	_moveto_keys_held.clear()


# ── watch_signals (stateful) ──────────────────────────────────────────────────

func _watch_signals(params: Dictionary) -> void:
	if not params.has("node_paths") or not params["node_paths"] is Array:
		_respond({"error": "node_paths array is required"})
		return

	var node_paths: Array = params["node_paths"]
	if node_paths.is_empty():
		_respond({"error": "node_paths array is empty"})
		return

	_watch_signal_filter = params.get("signal_filter", []) if params.has("signal_filter") and params["signal_filter"] is Array else []
	_watch_duration_ms = clampi(int(params.get("duration_ms", 5000)), 500, 30000)
	_watch_log.clear()
	_watch_connections.clear()
	_watch_nodes = node_paths

	var connected_count: int = 0
	for node_path_str in node_paths:
		var path := String(node_path_str)
		var node := _resolve(path)
		if node == null:
			_watch_log.append({"warning": "Node not found: %s" % path})
			continue

		for sig_info in node.get_signal_list():
			var sig_name: String = sig_info["name"]
			if not _watch_signal_filter.is_empty():
				var match_found := false
				for filter_str in _watch_signal_filter:
					if sig_name.contains(String(filter_str)):
						match_found = true
						break
				if not match_found:
					continue

			var arg_count: int = (sig_info["args"] as Array).size()
			var cb := _make_signal_callback(path, sig_name, arg_count)
			if cb.is_valid() and not node.is_connected(sig_name, cb):
				node.connect(sig_name, cb)
				_watch_connections.append({"node": node, "signal": sig_name, "callable": cb})
				connected_count += 1

	if connected_count == 0 and _watch_log.is_empty():
		_respond({"error": "No signals connected. Check node_paths and signal_filter."})
		return

	_watch_start_msec = Time.get_ticks_msec()
	_state = State.WATCHING_SIGNALS


func _on_signal_fired(node_path_str: String, sig_name: String, args: Array) -> void:
	var entry: Dictionary = {
		"time_ms": Time.get_ticks_msec() - _watch_start_msec,
		"node": node_path_str,
		"signal": sig_name,
	}
	if not args.is_empty():
		var serialized: Array = []
		for a in args:
			serialized.append(PropertyParser.serialize_value(a))
		entry["args"] = serialized
	_watch_log.append(entry)


func _make_signal_callback(node_path_str: String, sig_name: String, arg_count: int) -> Callable:
	var np := node_path_str
	var sn := sig_name
	match arg_count:
		0:
			return func() -> void: _on_signal_fired(np, sn, [])
		1:
			return func(a: Variant) -> void: _on_signal_fired(np, sn, [a])
		2:
			return func(a: Variant, b: Variant) -> void: _on_signal_fired(np, sn, [a, b])
		3:
			return func(a: Variant, b: Variant, c: Variant) -> void: _on_signal_fired(np, sn, [a, b, c])
		4:
			return func(a: Variant, b: Variant, c: Variant, d: Variant) -> void: _on_signal_fired(np, sn, [a, b, c, d])
		_:
			var cb := func() -> void: _on_signal_fired(np, sn, [])
			return cb.unbind(arg_count)


func _process_watch_signals() -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		_finish_watch_signals()
		_state = State.IDLE
		_handle_request()
		return

	if Time.get_ticks_msec() - _watch_start_msec >= _watch_duration_ms:
		_finish_watch_signals()


func _finish_watch_signals() -> void:
	for conn in _watch_connections:
		var node: Node = conn["node"] as Node
		if is_instance_valid(node):
			var sig_name: String = conn["signal"]
			var cb: Callable = conn["callable"]
			if node.is_connected(sig_name, cb):
				node.disconnect(sig_name, cb)
	_watch_connections.clear()

	_state = State.IDLE
	_respond({
		"node_paths": _watch_nodes,
		"signal_filter": _watch_signal_filter,
		"duration_ms": _watch_duration_ms,
		"events": _watch_log,
		"event_count": _watch_log.size(),
	})
	_watch_log.clear()


# ── await_signal (one-shot, polled via await) ─────────────────────────────────

func _await_signal(params: Dictionary) -> void:
	var node := _resolve(params.get("node_path", ""))
	if node == null:
		_respond({"error": "Node not found: %s" % params.get("node_path", "")})
		return

	var sig_name: String = params.get("signal", "")
	if sig_name.is_empty():
		_respond({"error": "'signal' is required"})
		return
	if not node.has_signal(sig_name):
		_respond({"error": "Signal '%s' not found on %s" % [sig_name, node.get_class()]})
		return

	var timeout_sec: float = float(params.get("timeout", 10.0))

	# Look up the signal's declared argument count so we can connect a callback
	# of matching arity (a mismatch would silently drop the connection).
	var arg_count: int = 0
	for sig_info in node.get_signal_list():
		if String(sig_info["name"]) == sig_name:
			arg_count = (sig_info["args"] as Array).size()
			break

	# Boxed so the one-shot callback can mutate them by reference from its closure.
	var captured: Array = []
	var fired: Array = [false]
	var cb := _make_await_callback(captured, fired, arg_count)
	node.connect(sig_name, cb, CONNECT_ONE_SHOT)

	var start_msec := Time.get_ticks_msec()
	var deadline := start_msec + int(timeout_sec * 1000.0)
	while not fired[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	# CONNECT_ONE_SHOT auto-disconnects on fire; disconnect only on timeout.
	if is_instance_valid(node) and node.is_connected(sig_name, cb):
		node.disconnect(sig_name, cb)

	var serialized: Array = []
	for a in captured:
		serialized.append(PropertyParser.serialize_value(a))

	# A timeout is a success payload with fired:false, not an error.
	_respond({
		"fired": fired[0],
		"signal": sig_name,
		"node_path": _rel(node) if is_instance_valid(node) else params.get("node_path", ""),
		"args": serialized,
		"waited_ms": Time.get_ticks_msec() - start_msec,
	})


## Build a one-shot Callable of the given arity that records the emission's args
## into `captured` and flips `fired[0]`. Arities beyond the explicit cases fire
## without capturing args (unbind drops them).
func _make_await_callback(captured: Array, fired: Array, arg_count: int) -> Callable:
	match arg_count:
		0:
			return func() -> void:
				fired[0] = true
		1:
			return func(a: Variant) -> void:
				captured.append(a)
				fired[0] = true
		2:
			return func(a: Variant, b: Variant) -> void:
				captured.append(a)
				captured.append(b)
				fired[0] = true
		3:
			return func(a: Variant, b: Variant, c: Variant) -> void:
				captured.append(a)
				captured.append(b)
				captured.append(c)
				fired[0] = true
		4:
			return func(a: Variant, b: Variant, c: Variant, d: Variant) -> void:
				captured.append(a)
				captured.append(b)
				captured.append(c)
				captured.append(d)
				fired[0] = true
		5:
			return func(a: Variant, b: Variant, c: Variant, d: Variant, e: Variant) -> void:
				captured.append(a)
				captured.append(b)
				captured.append(c)
				captured.append(d)
				captured.append(e)
				fired[0] = true
		6:
			return func(a: Variant, b: Variant, c: Variant, d: Variant, e: Variant, f: Variant) -> void:
				captured.append(a)
				captured.append(b)
				captured.append(c)
				captured.append(d)
				captured.append(e)
				captured.append(f)
				fired[0] = true
		_:
			var cb := func() -> void:
				fired[0] = true
			return cb.unbind(arg_count)


func _get_runtime_errors(params: Dictionary) -> void:
	if _error_log == null:
		_respond({"error": "runtime error log not active"})
		return
	var since_seq := int(params.get("since_seq", 0))
	var clear := bool(params.get("clear", false))
	_respond(_error_log.poll(since_seq, clear))
