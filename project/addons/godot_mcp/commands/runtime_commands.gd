@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Inspect and drive the RUNNING game. These commands broker to the
## MCPGameInspector autoload over file IPC, so they require a scene to be
## playing (scene.play) and the autoload to be active. Paths are relative to
## the running scene root, matching scene.tree.


func get_commands() -> Dictionary:
	return {
		"runtime.tree": _tree,
		"runtime.get": _get_props,
		"runtime.set": _set_prop,
		"runtime.eval": _eval,
		"runtime.screenshot": _screenshot,
		"runtime.capture_frames": _capture_frames,
		"runtime.monitor": _monitor,
		"runtime.start_recording": _start_recording,
		"runtime.stop_recording": _stop_recording,
		"runtime.replay": _replay,
		"runtime.find_by_script": _find_by_script,
		"runtime.autoload": _autoload,
		"runtime.batch_get": _batch_get,
		"runtime.find_ui": _find_ui,
		"runtime.click_text": _click_text,
		"runtime.wait_for": _wait_for,
		"runtime.find_nearby": _find_nearby,
		"runtime.navigate": _navigate,
		"runtime.move_to": _move_to,
		"runtime.watch_signals": _watch_signals,
		"runtime.await_signal": _await_signal,
		"runtime.errors": _errors,
	}


func _capture_frames(params: Dictionary) -> Dictionary:
	var count := optional_int(params, "count", 5)
	var interval := optional_int(params, "frame_interval", 10)
	var timeout := minf(float(count * interval) / 60.0 + 2.0, 25.0)
	return await _send("capture_frames", {
		"count": count, "frame_interval": interval,
		"half_resolution": optional_bool(params, "half_resolution", true),
	}, timeout)


func _monitor(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	if not params.has("properties") or not params["properties"] is Array:
		return error_invalid_params("'properties' array is required")
	var frame_count := optional_int(params, "frame_count", 60)
	var interval := optional_int(params, "frame_interval", 1)
	var timeout := minf(float(frame_count * interval) / 60.0 + 2.0, 25.0)
	return await _send("monitor_properties", {
		"node_path": r[0], "properties": params["properties"],
		"frame_count": frame_count, "frame_interval": interval,
	}, timeout)


func _start_recording(_params: Dictionary) -> Dictionary:
	return await _send("start_recording", {})


func _stop_recording(_params: Dictionary) -> Dictionary:
	return await _send("stop_recording", {}, 5.0)


func _replay(params: Dictionary) -> Dictionary:
	if not params.has("events") or not params["events"] is Array:
		return error_invalid_params("'events' array is required")
	var speed := float(params.get("speed", 1.0))
	var max_ms := 0
	for e in params["events"]:
		if e is Dictionary:
			max_ms = maxi(max_ms, int((e as Dictionary).get("time_ms", 0)))
	var timeout := minf(float(max_ms) / 1000.0 / maxf(speed, 0.01) + 5.0, 120.0)
	return await _send("replay_recording", {"events": params["events"], "speed": speed}, timeout)


func _find_by_script(params: Dictionary) -> Dictionary:
	var r := require_string(params, "script")
	if r[1] != null:
		return r[1]
	var cmd := {"script": r[0]}
	if params.has("properties") and params["properties"] is Array:
		cmd["properties"] = params["properties"]
	return await _send("find_nodes_by_script", cmd)


func _autoload(params: Dictionary) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var cmd := {"name": r[0]}
	if params.has("properties") and params["properties"] is Array:
		cmd["properties"] = params["properties"]
	return await _send("get_autoload", cmd)


func _batch_get(params: Dictionary) -> Dictionary:
	if not params.has("nodes") or not params["nodes"] is Array:
		return error_invalid_params("'nodes' array is required")
	return await _send("batch_get_properties", {"nodes": params["nodes"]})


func _find_ui(params: Dictionary) -> Dictionary:
	var cmd := {}
	var tf := optional_string(params, "type_filter")
	if not tf.is_empty():
		cmd["type_filter"] = tf
	return await _send("find_ui_elements", cmd)


func _click_text(params: Dictionary) -> Dictionary:
	var r := require_string(params, "text")
	if r[1] != null:
		return r[1]
	return await _send("click_button_by_text", {"text": r[0], "partial": optional_bool(params, "partial", true)})


func _wait_for(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var timeout := float(params.get("timeout", 5.0))
	return await _send("wait_for_node", {
		"node_path": r[0], "timeout": timeout, "poll_frames": optional_int(params, "poll_frames", 5),
	}, timeout + 2.0)


func _find_nearby(params: Dictionary) -> Dictionary:
	if not params.has("position"):
		return error_invalid_params("Missing required parameter: position")
	var cmd := {"position": params["position"]}
	if params.has("radius"):
		cmd["radius"] = float(params["radius"])
	var tf := optional_string(params, "type_filter")
	if not tf.is_empty():
		cmd["type_filter"] = tf
	var gf := optional_string(params, "group_filter")
	if not gf.is_empty():
		cmd["group_filter"] = gf
	if params.has("max_results"):
		cmd["max_results"] = int(params["max_results"])
	return await _send("find_nearby_nodes", cmd)


func _navigate(params: Dictionary) -> Dictionary:
	if not params.has("target"):
		return error_invalid_params("Missing required parameter: target")
	var cmd := {"target": params["target"]}
	var pp := optional_string(params, "player_path")
	if not pp.is_empty():
		cmd["player_path"] = pp
	var cp := optional_string(params, "camera_path")
	if not cp.is_empty():
		cmd["camera_path"] = cp
	if params.has("move_speed"):
		cmd["move_speed"] = float(params["move_speed"])
	return await _send("navigate_to", cmd)


func _move_to(params: Dictionary) -> Dictionary:
	if not params.has("target"):
		return error_invalid_params("Missing required parameter: target")
	var cmd := {"target": params["target"]}
	var pp := optional_string(params, "player_path")
	if not pp.is_empty():
		cmd["player_path"] = pp
	var cp := optional_string(params, "camera_path")
	if not cp.is_empty():
		cmd["camera_path"] = cp
	if params.has("arrival_radius"):
		cmd["arrival_radius"] = float(params["arrival_radius"])
	if params.has("run"):
		cmd["run"] = bool(params["run"])
	if params.has("look_at_target"):
		cmd["look_at_target"] = bool(params["look_at_target"])
	var game_timeout := float(params.get("timeout", 15.0))
	cmd["timeout"] = game_timeout
	return await _send("move_to", cmd, game_timeout + 5.0)


func _watch_signals(params: Dictionary) -> Dictionary:
	if not params.has("node_paths") or not params["node_paths"] is Array:
		return error_invalid_params("'node_paths' array is required")
	var cmd := {"node_paths": params["node_paths"]}
	if params.has("signal_filter") and params["signal_filter"] is Array:
		cmd["signal_filter"] = params["signal_filter"]
	var duration_ms := optional_int(params, "duration_ms", 5000)
	cmd["duration_ms"] = duration_ms
	return await _send("watch_signals", cmd, float(duration_ms) / 1000.0 + 5.0)


func _await_signal(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var rs := require_string(params, "signal")
	if rs[1] != null:
		return rs[1]
	var timeout := float(params.get("timeout", 10.0))
	# Give the editor-side IPC wait a margin over the game-side deadline so a
	# timeout is reported as fired:false by the game, not as an IPC timeout.
	return await _send("await_signal", {
		"node_path": r[0], "signal": rs[0], "timeout": timeout,
	}, timeout + 5.0)


## Poll runtime errors/warnings captured from the running game by the
## OS.add_logger channel in MCPGameInspector. --since-seq for incremental reads
## (use the returned next_seq), --clear to drain the buffer after reading.
func _errors(params: Dictionary) -> Dictionary:
	var cmd := {"clear": optional_bool(params, "clear", false)}
	if params.has("since_seq"):
		cmd["since_seq"] = optional_int(params, "since_seq", 0)
	return await _send("get_runtime_errors", cmd, 5.0)


func _tree(params: Dictionary) -> Dictionary:
	return await _send("get_scene_tree", {"max_depth": optional_int(params, "max_depth", -1)})


func _get_props(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var cmd := {"node_path": r[0]}
	if params.has("properties") and params["properties"] is Array:
		cmd["properties"] = params["properties"]
	return await _send("get_node_properties", cmd)


func _set_prop(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var rp := require_string(params, "property")
	if rp[1] != null:
		return rp[1]
	if not params.has("value"):
		return error_invalid_params("Missing required parameter: value")
	return await _send("set_node_property", {"node_path": r[0], "property": rp[0], "value": params["value"]})


func _eval(params: Dictionary) -> Dictionary:
	var r := require_string(params, "code")
	if r[1] != null:
		return r[1]
	audit_exec("runtime.eval", r[0])
	return await _send("execute_script", {"code": r[0]}, 10.0)


func _screenshot(params: Dictionary) -> Dictionary:
	var cmd := {}
	var save_path := optional_string(params, "save_path", "")
	if not save_path.is_empty():
		cmd["save_path"] = save_path
	return await _send("screenshot", cmd, 8.0)


# --- File IPC ---------------------------------------------------------------

func _send(command: String, params: Dictionary, timeout_sec: float = 5.0) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Use scene.play first"})

	var user_dir := get_game_user_dir()
	var request_path := user_dir + "/mcp_game_request"
	var response_path := user_dir + "/mcp_game_response"

	if FileAccess.file_exists(response_path):
		DirAccess.remove_absolute(response_path)

	var req := FileAccess.open(request_path, FileAccess.WRITE)
	if req == null:
		return error_internal("Could not create game request file at %s" % request_path)
	req.store_string(JSON.stringify({"command": command, "params": params}))
	req.close()

	var attempts := int(timeout_sec / 0.1)
	while attempts > 0:
		await get_tree().create_timer(0.1).timeout
		if FileAccess.file_exists(response_path):
			break
		if not EditorInterface.is_playing_scene():
			if FileAccess.file_exists(request_path):
				DirAccess.remove_absolute(request_path)
			return error(-32000, "Game stopped during command execution")
		attempts -= 1

	if not FileAccess.file_exists(response_path):
		if FileAccess.file_exists(request_path):
			DirAccess.remove_absolute(request_path)
		return error(-32000, "Game command timed out after %.1fs" % timeout_sec,
			{"suggestion": "Ensure the game is running with the MCPGameInspector autoload active"})

	var file := FileAccess.open(response_path, FileAccess.READ)
	if file == null:
		return error_internal("Could not read game response file")
	var text := file.get_as_text()
	file.close()
	DirAccess.remove_absolute(response_path)

	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return error_internal("Invalid response JSON from game")
	if parsed.has("error"):
		return error(-32000, str(parsed["error"]))
	return success(parsed)


## Every runtime.* command drives the RUNNING game over file IPC and requires a
## scene to be playing (scene.play); node paths are relative to the running scene root.
func get_command_docs() -> Dictionary:
	return {
		"runtime.tree": {
			"description": "Return the running game's scene tree. Requires scene.play.",
			"params": [
				doc_param("max_depth", "int", false, "Max depth to descend (-1 = unlimited, the default)."),
			],
		},
		"runtime.get": {
			"description": "Read properties of a node in the running game. Requires scene.play.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node path in the running scene."),
				doc_param("properties", "Array", false, "Specific property names to read (default a standard set)."),
			],
		},
		"runtime.set": {
			"description": "Set a property on a node in the running game. Requires scene.play.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node path in the running scene."),
				doc_param("property", "String", true, "Property name."),
				doc_param("value", "JSON", true, "New value."),
			],
		},
		"runtime.eval": {
			"description": "Execute ad-hoc GDScript inside the running game and return its result. Audited. Requires scene.play. (A real script error under a headless editor can freeze the game — recover with scene.stop/play.)",
			"params": [
				doc_param("code", "String", true, "GDScript to run in the game process."),
			],
		},
		"runtime.screenshot": {
			"description": "Capture the running game's viewport to a PNG (base64, or --save-path). Works headless. Requires scene.play.",
			"params": [
				doc_param("save_path", "String", false, "Path to save the PNG; omit to return base64."),
			],
		},
		"runtime.capture_frames": {
			"description": "Capture a burst of consecutive game frames as images. Requires scene.play.",
			"params": [
				doc_param("count", "int", false, "Number of frames (default 5)."),
				doc_param("frame_interval", "int", false, "Frames to wait between captures (default 10)."),
				doc_param("half_resolution", "bool", false, "Downscale captures to half resolution (default true)."),
			],
		},
		"runtime.monitor": {
			"description": "Sample --properties on a node over --frame-count frames (a time series). Requires scene.play.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to sample."),
				doc_param("properties", "Array", true, "Property names to record each sample."),
				doc_param("frame_count", "int", false, "How many samples (default 60)."),
				doc_param("frame_interval", "int", false, "Frames between samples (default 1)."),
			],
		},
		"runtime.start_recording": {
			"description": "Begin recording input events in the running game. Requires scene.play.",
		},
		"runtime.stop_recording": {
			"description": "Stop input recording and return the captured event list. Requires scene.play.",
		},
		"runtime.replay": {
			"description": "Replay a recorded --events list into the running game at --speed. Requires scene.play.",
			"params": [
				doc_param("events", "Array", true, "Recorded input events (each with a time_ms)."),
				doc_param("speed", "float", false, "Playback speed multiplier (default 1.0)."),
			],
		},
		"runtime.find_by_script": {
			"description": "Find running-game nodes whose attached script matches --script, optionally reading --properties from each. Requires scene.play.",
			"params": [
				doc_param("script", "String", true, "Script path or class name to match."),
				doc_param("properties", "Array", false, "Property names to read from each match."),
			],
		},
		"runtime.autoload": {
			"description": "Read an autoload singleton by --name in the running game, optionally specific --properties. Requires scene.play.",
			"params": [
				doc_param("name", "String", true, "Autoload singleton name."),
				doc_param("properties", "Array", false, "Property names to read."),
			],
		},
		"runtime.batch_get": {
			"description": "Read properties from several running-game nodes in one call. Requires scene.play.",
			"params": [
				doc_param("nodes", "Array", true, "List of {node_path, properties} specs."),
			],
		},
		"runtime.find_ui": {
			"description": "List Control/UI elements in the running game, optionally filtered by --type-filter class. Requires scene.play.",
			"params": [
				doc_param("type_filter", "String", false, "Restrict to this Control class."),
			],
		},
		"runtime.click_text": {
			"description": "Click a button in the running game by its visible --text (partial match by default). Requires scene.play.",
			"params": [
				doc_param("text", "String", true, "Button label text to find."),
				doc_param("partial", "bool", false, "Match text as a substring (default true)."),
			],
		},
		"runtime.wait_for": {
			"description": "Block until a node appears at --node-path in the running game (or --timeout). Requires scene.play.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node path to wait for."),
				doc_param("timeout", "float", false, "Seconds to wait (default 5)."),
				doc_param("poll_frames", "int", false, "Frames between existence checks (default 5)."),
			],
		},
		"runtime.find_nearby": {
			"description": "Find running-game nodes near a world --position, within --radius, optionally filtered by type/group. Requires scene.play.",
			"params": [
				doc_param("position", "Vector3", true, "World position to search around (a Vector2 for 2D games)."),
				doc_param("radius", "float", false, "Search radius."),
				doc_param("type_filter", "String", false, "Restrict to this node class."),
				doc_param("group_filter", "String", false, "Restrict to nodes in this group."),
				doc_param("max_results", "int", false, "Cap on returned nodes."),
			],
		},
		"runtime.navigate": {
			"description": "Instantly move the player/camera to a --target in the running game. Requires scene.play.",
			"params": [
				doc_param("target", "NodePath", true, "Target node path (or a world position)."),
				doc_param("player_path", "NodePath", false, "Explicit player node to move."),
				doc_param("camera_path", "NodePath", false, "Explicit camera node to move."),
				doc_param("move_speed", "float", false, "Movement speed override."),
			],
		},
		"runtime.move_to": {
			"description": "Walk the player toward a --target over time (pathed movement), up to --timeout. Requires scene.play.",
			"params": [
				doc_param("target", "NodePath", true, "Target node path (or a world position)."),
				doc_param("player_path", "NodePath", false, "Explicit player node to move."),
				doc_param("camera_path", "NodePath", false, "Explicit camera node."),
				doc_param("arrival_radius", "float", false, "Distance from the target that counts as arrived."),
				doc_param("run", "bool", false, "Move at running speed."),
				doc_param("look_at_target", "bool", false, "Face the target while moving."),
				doc_param("timeout", "float", false, "Seconds before giving up (default 15)."),
			],
		},
		"runtime.watch_signals": {
			"description": "Watch --node-paths for emitted signals over --duration-ms, returning what fired. Requires scene.play.",
			"params": [
				doc_param("node_paths", "Array", true, "Nodes to watch."),
				doc_param("signal_filter", "Array", false, "Only these signal names."),
				doc_param("duration_ms", "int", false, "How long to watch, milliseconds (default 5000)."),
			],
		},
		"runtime.await_signal": {
			"description": "Block until --node-path emits --signal (or --timeout), returning the serialized signal args. A timeout is fired:false, not an error. Requires scene.play.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node emitting the signal."),
				doc_param("signal", "String", true, "Signal name to await."),
				doc_param("timeout", "float", false, "Seconds to wait (default 10)."),
			],
		},
		"runtime.errors": {
			"description": "Poll runtime errors/warnings the running game captured via OS.add_logger. --since-seq for incremental reads (use the returned next_seq), --clear to drain. Requires scene.play.",
			"params": [
				doc_param("since_seq", "int", false, "Return only entries after this sequence number."),
				doc_param("clear", "bool", false, "Clear the buffer after reading."),
			],
		},
	}
