@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Test automation: editor-side orchestration of a running game plus runtime
## assertions via file-based IPC with the MCPGameInspector autoload. Requires a
## scene to be playing (scene.play). Node paths are relative to the running root.


func get_commands() -> Dictionary:
	return {
		"test.run_scenario": _run_scenario,
		"test.assert_node_state": _assert_node_state,
		"test.assert_screen_text": _assert_screen_text,
		"test.run_stress_test": _run_stress_test,
		"test.report": _report,
	}


var _test_results: Array[Dictionary] = []


func _run_scenario(params: Dictionary) -> Dictionary:
	if not params.has("steps") or not params["steps"] is Array:
		return error_invalid_params("Missing required parameter: steps (Array)")

	var steps: Array = params["steps"]
	if steps.is_empty():
		return error_invalid_params("Steps array is empty")

	var scene_path := optional_string(params, "scene_path")

	if not scene_path.is_empty():
		if EditorInterface.is_playing_scene():
			EditorInterface.stop_playing_scene()
			await get_tree().create_timer(0.5).timeout

		if scene_path == "main":
			EditorInterface.play_main_scene()
		elif scene_path == "current":
			EditorInterface.play_current_scene()
		else:
			if not FileAccess.file_exists(scene_path):
				return error_not_found("Scene file '%s'" % scene_path)
			EditorInterface.play_custom_scene(scene_path)

		await get_tree().create_timer(1.0).timeout

	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Provide scene_path or use scene.play first"})

	var results: Array[Dictionary] = []
	var pass_count := 0
	var fail_count := 0
	var error_count := 0

	for i in steps.size():
		var step: Dictionary = steps[i]
		if not step.has("type"):
			results.append({"step": i, "error": "Missing 'type' field"})
			error_count += 1
			continue

		var step_type := str(step["type"])
		var step_result: Dictionary = {"step": i, "type": step_type}

		match step_type:
			"input":
				step_result.merge(await _execute_input_step(step))
			"wait":
				step_result.merge(await _execute_wait_step(step))
			"assert":
				var assert_result := await _execute_assert_step(step)
				step_result.merge(assert_result)
				if assert_result.get("passed", false):
					pass_count += 1
				else:
					fail_count += 1
			"screenshot":
				var shot := await _send_game_command("capture_frames", {
					"count": 1,
					"frame_interval": 1,
					"half_resolution": optional_bool(step, "half_resolution", true),
				}, 5.0)
				if shot.has("result"):
					step_result["captured"] = true
				else:
					step_result["captured"] = false
					step_result["error"] = "Screenshot capture failed"
					error_count += 1
			_:
				step_result["error"] = "Unknown step type: %s" % step_type
				error_count += 1

		results.append(step_result)

		if not EditorInterface.is_playing_scene():
			results.append({"step": i + 1, "error": "Game stopped unexpectedly"})
			error_count += 1
			break

	var summary := {
		"total_steps": steps.size(),
		"completed_steps": results.size(),
		"assertions_passed": pass_count,
		"assertions_failed": fail_count,
		"errors": error_count,
		"all_passed": fail_count == 0 and error_count == 0,
		"results": results,
	}

	_test_results.append_array(results)

	return success(summary)


func _assert_node_state(params: Dictionary) -> Dictionary:
	var path_result := require_string(params, "node_path")
	if path_result[1] != null:
		return path_result[1]

	var prop_result := require_string(params, "property")
	if prop_result[1] != null:
		return prop_result[1]

	if not params.has("expected"):
		return error_invalid_params("Missing required parameter: expected")

	var operator := optional_string(params, "operator", "eq")
	var valid_operators := ["eq", "neq", "gt", "lt", "gte", "lte", "contains", "type_is"]
	if operator not in valid_operators:
		return error_invalid_params("Invalid operator '%s'. Valid: %s" % [operator, str(valid_operators)])

	var result := await _send_game_command("assert_node_state", {
		"node_path": path_result[0],
		"property": prop_result[0],
		"expected": params["expected"],
		"operator": operator,
	}, 5.0)

	if result.has("result"):
		_test_results.append(result["result"])

	return result


func _assert_screen_text(params: Dictionary) -> Dictionary:
	var text_result := require_string(params, "text")
	if text_result[1] != null:
		return text_result[1]

	var expected_text: String = text_result[0]
	var partial := optional_bool(params, "partial", true)
	var case_sensitive := optional_bool(params, "case_sensitive", true)

	var ui_result := await _send_game_command("find_ui_elements", {})
	if ui_result.has("error"):
		return ui_result

	var elements: Array = []
	if ui_result.has("result") and ui_result["result"].has("elements"):
		elements = ui_result["result"]["elements"]

	var found := false
	var matched_element: Dictionary = {}
	var all_texts: Array[String] = []

	for element: Dictionary in elements:
		var element_text := str(element.get("text", ""))
		if element_text.is_empty():
			continue
		all_texts.append(element_text)

		var search_text := expected_text
		var compare_text := element_text
		if not case_sensitive:
			search_text = search_text.to_lower()
			compare_text = compare_text.to_lower()

		if partial:
			if compare_text.contains(search_text):
				found = true
				matched_element = element
				break
		elif compare_text == search_text:
			found = true
			matched_element = element
			break

	var assertion := {
		"passed": found,
		"expected_text": expected_text,
		"partial": partial,
		"case_sensitive": case_sensitive,
	}

	if found:
		assertion["matched_element"] = {
			"text": matched_element.get("text", ""),
			"type": matched_element.get("type", ""),
			"path": matched_element.get("path", ""),
		}
	else:
		assertion["visible_texts"] = all_texts

	_test_results.append(assertion)

	return success(assertion)


func _run_stress_test(params: Dictionary) -> Dictionary:
	var duration := float(params.get("duration", 5.0))
	if duration <= 0 or duration > 60:
		return error_invalid_params("Duration must be between 0 and 60 seconds")

	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Use scene.play first"})

	var initial_errors := _count_log_errors()

	var actions := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_cancel"]
	for action in params.get("actions", []):
		actions.append(str(action))

	var events_sent := 0
	var start_time := Time.get_ticks_msec()
	var duration_ms := int(duration * 1000.0)
	var input_path := get_game_user_dir() + "/mcp_input_commands"

	while Time.get_ticks_msec() - start_time < duration_ms:
		if not EditorInterface.is_playing_scene():
			var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
			return success({
				"completed": false,
				"crashed": true,
				"elapsed_seconds": elapsed,
				"events_sent": events_sent,
				"error": "Game stopped during stress test",
			})

		var batch: Array = []
		for j in 3:
			var action_name: String = actions[randi() % actions.size()]
			batch.append({"type": "action", "action": action_name, "pressed": true, "strength": 1.0})
			batch.append({"type": "action", "action": action_name, "pressed": false, "strength": 0.0})

		var file := FileAccess.open(input_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"sequence_events": batch, "frame_delay": 1}))
			file.close()
			events_sent += batch.size()

		await get_tree().create_timer(0.1).timeout

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	var new_errors := _count_log_errors() - initial_errors
	var still_running := EditorInterface.is_playing_scene()

	return success({
		"completed": true,
		"crashed": not still_running,
		"duration_seconds": elapsed,
		"events_sent": events_sent,
		"new_errors": new_errors,
		"game_still_running": still_running,
	})


func _report(params: Dictionary) -> Dictionary:
	var clear := optional_bool(params, "clear", true)

	var pass_count := 0
	var fail_count := 0
	var details: Array[Dictionary] = []

	for result: Dictionary in _test_results:
		if result.get("passed", false):
			pass_count += 1
		else:
			fail_count += 1
		details.append(result)

	var report := {
		"total": _test_results.size(),
		"passed": pass_count,
		"failed": fail_count,
		"pass_rate": ("%.1f%%" % (100.0 * pass_count / _test_results.size())) if not _test_results.is_empty() else "N/A",
		"all_passed": fail_count == 0 and not _test_results.is_empty(),
		"details": details,
	}

	if clear:
		_test_results.clear()

	return success(report)


# --- Step executors ---------------------------------------------------------

func _execute_input_step(step: Dictionary) -> Dictionary:
	var events: Array = []

	if step.has("action"):
		var pressed := bool(step.get("pressed", true))
		events.append({
			"type": "action",
			"action": str(step["action"]),
			"pressed": pressed,
			"strength": float(step.get("strength", 1.0)),
		})
		if pressed and step.get("auto_release", true):
			events.append({"type": "action", "action": str(step["action"]), "pressed": false, "strength": 0.0})
	elif step.has("keycode"):
		events.append({
			"type": "key",
			"keycode": str(step["keycode"]),
			"pressed": bool(step.get("pressed", true)),
			"shift": step.get("shift", false),
			"ctrl": step.get("ctrl", false),
			"alt": step.get("alt", false),
		})
	else:
		return {"error": "Input step requires 'action' or 'keycode'"}

	var file := FileAccess.open(get_game_user_dir() + "/mcp_input_commands", FileAccess.WRITE)
	if file == null:
		return {"error": "Failed to write input commands"}
	file.store_string(JSON.stringify({"sequence_events": events, "frame_delay": int(step.get("frame_delay", 1))}))
	file.close()

	return {"sent": true, "event_count": events.size()}


func _execute_wait_step(step: Dictionary) -> Dictionary:
	if step.has("node_path"):
		var timeout := float(step.get("timeout", 5.0))
		var result := await _send_game_command("wait_for_node", {
			"node_path": str(step["node_path"]),
			"timeout": timeout,
			"poll_frames": int(step.get("poll_frames", 5)),
		}, timeout + 2.0)
		if result.has("error"):
			return {"error": "Wait for node failed: %s" % str(result["error"])}
		return {"waited_for": str(step["node_path"]), "found": true}
	else:
		var seconds := float(step.get("seconds", 1.0))
		await get_tree().create_timer(seconds).timeout
		return {"waited_seconds": seconds}


func _execute_assert_step(step: Dictionary) -> Dictionary:
	if step.has("text"):
		var ui_result := await _send_game_command("find_ui_elements", {})
		if ui_result.has("error"):
			return {"passed": false, "error": "Could not get UI elements"}

		var elements: Array = []
		if ui_result.has("result") and ui_result["result"].has("elements"):
			elements = ui_result["result"]["elements"]

		var expected_text := str(step["text"])
		var partial := bool(step.get("partial", true))
		for element: Dictionary in elements:
			var element_text := str(element.get("text", ""))
			if partial and element_text.contains(expected_text):
				return {"passed": true, "type": "screen_text", "expected": expected_text, "found_in": element_text}
			elif not partial and element_text == expected_text:
				return {"passed": true, "type": "screen_text", "expected": expected_text, "found_in": element_text}

		return {"passed": false, "type": "screen_text", "expected": expected_text, "error": "Text not found on screen"}

	elif step.has("node_path") and step.has("property"):
		var result := await _send_game_command("assert_node_state", {
			"node_path": str(step["node_path"]),
			"property": str(step["property"]),
			"expected": step.get("expected", null),
			"operator": str(step.get("operator", "eq")),
		}, 5.0)
		if result.has("result"):
			return result["result"]
		elif result.has("error"):
			return {"passed": false, "error": str(result["error"])}
		return {"passed": false, "error": "Unknown assertion error"}

	else:
		return {"passed": false, "error": "Assert step requires 'text' or 'node_path'+'property'"}


# --- File IPC ---------------------------------------------------------------

func _send_game_command(command: String, params: Dictionary = {}, timeout_sec: float = 5.0) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Use scene.play first"})

	var user_dir := get_game_user_dir()
	var request_path := user_dir + "/mcp_game_request"
	var response_path := user_dir + "/mcp_game_response"

	if FileAccess.file_exists(response_path):
		DirAccess.remove_absolute(response_path)

	var req := FileAccess.open(request_path, FileAccess.WRITE)
	if req == null:
		return error_internal("Could not create game request file")
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
		# Game may be paused on a runtime error; try to resume the debugger.
		if EditorInterface.is_playing_scene():
			_try_debugger_continue()
			for _retry in 20:
				await get_tree().create_timer(0.1).timeout
				if FileAccess.file_exists(response_path):
					break

	if not FileAccess.file_exists(response_path):
		if FileAccess.file_exists(request_path):
			DirAccess.remove_absolute(request_path)
		return error(-32000, "Game command timed out after %.1fs" % timeout_sec, {
			"suggestion": "Ensure the game is running and the MCPGameInspector autoload is active",
		})

	var file := FileAccess.open(response_path, FileAccess.READ)
	if file == null:
		return error_internal("Could not read game response file")
	var text := file.get_as_text()
	file.close()
	DirAccess.remove_absolute(response_path)

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return error_internal("Invalid response JSON from game")
	if parsed.has("error"):
		return error(-32000, str(parsed["error"]))
	return success(parsed)


## Press the debugger "Continue" button to resume a paused game process.
func _try_debugger_continue() -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var queue: Array[Node] = [base]
	while not queue.is_empty():
		var node := queue.pop_front()
		if node.get_class() == "ScriptEditorDebugger":
			var inner: Array[Node] = [node]
			while not inner.is_empty():
				var n := inner.pop_front()
				if n is Button and (n as Button).tooltip_text == "Continue":
					(n as Button).emit_signal("pressed")
					push_warning("[MCP] Auto-resumed debugger after runtime error")
					return
				for c in n.get_children():
					inner.append(c)
			return
		for child in node.get_children():
			queue.append(child)


func _count_log_errors() -> int:
	var count := 0
	var log_path := "user://logs/godot.log"
	if FileAccess.file_exists(log_path):
		var file := FileAccess.open(log_path, FileAccess.READ)
		if file != null:
			var content := file.get_as_text()
			file.close()
			for line in content.split("\n"):
				if (line as String).contains("ERROR") or (line as String).contains("SCRIPT ERROR"):
					count += 1
	return count


func get_command_docs() -> Dictionary:
	return {
		"test.run_scenario": {
			"description": "Run a scripted scenario against the playing game: a sequence of --steps (input/wait/assert/screenshot) driven over file IPC. Optionally (re)starts the scene first. Requires a playing scene.",
			"params": [
				doc_param("steps", "Array", true, "Non-empty JSON array of step objects, each with a 'type': 'input' ({action|keycode, pressed, ...}), 'wait' ({seconds} or {node_path, timeout}), 'assert' ({text} or {node_path, property, expected, operator}), or 'screenshot'."),
				doc_param("scene_path", "String", false, "'main', 'current', or a scene file path to (re)start before running; omit to use the already-playing scene."),
			],
		},
		"test.assert_node_state": {
			"description": "Assert a property on a node in the running game compares as expected. Requires a playing scene.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node path relative to the running scene root."),
				doc_param("property", "String", true, "Property to read."),
				doc_param("expected", "JSON", true, "Expected value to compare against."),
				doc_param("operator", "String", false, "Comparison: eq (default), neq, gt, lt, gte, lte, contains, type_is."),
			],
		},
		"test.assert_screen_text": {
			"description": "Assert some visible UI element in the running game shows the given text. Requires a playing scene.",
			"params": [
				doc_param("text", "String", true, "Text to look for on screen."),
				doc_param("partial", "bool", false, "Substring match rather than exact (default true)."),
				doc_param("case_sensitive", "bool", false, "Case-sensitive match (default true)."),
			],
		},
		"test.run_stress_test": {
			"description": "Fire random input actions at the running game for a duration, watching for crashes and new log errors. Requires a playing scene.",
			"params": [
				doc_param("duration", "float", false, "Seconds to run, 0..60 (default 5)."),
				doc_param("actions", "Array", false, "Extra action names to include alongside the default ui_* actions."),
			],
		},
		"test.report": {
			"description": "Summarize accumulated test results (pass/fail counts, pass rate, details) collected across test.* calls.",
			"params": [
				doc_param("clear", "bool", false, "Clear the accumulated results after reporting (default true)."),
			],
		},
	}
