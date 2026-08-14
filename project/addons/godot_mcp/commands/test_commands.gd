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

## Scenario steps that carry no assertion (input/wait/screenshot). Counted for
## bookkeeping only and never scored: folding them into _test_results is what
## made a green 94-step run report 13 passed and 81 failed, because _report
## scores anything without a passing "passed" field as a failure.
var _step_records: int = 0


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
	var assertions: Array[Dictionary] = []
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
				assertions.append(assert_result)
				if assert_result.get("passed", false):
					pass_count += 1
				else:
					fail_count += 1
			"screenshot":
				var shot_result := await _execute_screenshot_step(step)
				step_result.merge(shot_result)
				if not shot_result.get("captured", false):
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

	# Only assertion results are scoreable. Every other step is bookkeeping, and
	# feeding them all into _test_results made test.report call a green run 81
	# failures out of 94 -- one "failure" per input, wait and screenshot step.
	_test_results.append_array(assertions)
	_step_records += results.size() - assertions.size()

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
	# Drives input for up to 60s; without the autoload every event goes nowhere and
	# the run would report a clean stress test having exercised nothing.
	var no_autoload := game_autoload_error("MCPGameInput")
	if not no_autoload.is_empty():
		return no_autoload

	var initial_errors := _count_log_errors()

	var actions := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_cancel"]
	for action in params.get("actions", []):
		actions.append(str(action))

	var events_sent := 0
	var batches_skipped := 0
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

		# One slot, and WRITE truncates it. Clobbering a payload the game has not
		# read yet would count events that never reached it, so wait instead.
		if FileAccess.file_exists(input_path):
			batches_skipped += 1
			await get_tree().create_timer(0.05).timeout
			continue

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
		"batches_skipped": batches_skipped,
		"new_errors": new_errors,
		"game_still_running": still_running,
	})


func _report(params: Dictionary) -> Dictionary:
	var clear := optional_bool(params, "clear", true)

	var pass_count := 0
	var fail_count := 0
	var details: Array[Dictionary] = []
	var step_count := _step_records

	for result: Dictionary in _test_results:
		# An entry with no "passed" field asserted nothing, so it can neither pass
		# nor fail. Count it as a step and leave the headline numbers to assertions.
		if not result.has("passed"):
			step_count += 1
			continue
		if result.get("passed", false):
			pass_count += 1
		else:
			fail_count += 1
		details.append(result)

	var total := pass_count + fail_count
	var report := {
		"total": total,
		"passed": pass_count,
		"failed": fail_count,
		"pass_rate": ("%.1f%%" % (100.0 * pass_count / total)) if total > 0 else "N/A",
		"all_passed": fail_count == 0 and total > 0,
		"steps_recorded": step_count,
		"details": details,
	}

	if clear:
		_test_results.clear()
		_step_records = 0

	return success(report)


# --- Step executors ---------------------------------------------------------

## An action press is released again in the same batch unless the step sets
## auto_release false. That default stays -- a scenario that never releases
## leaves the action stuck down for every later step -- but it turns a
## hold-then-wait into a one-frame tap, so the step result reports it rather
## than leaving the caller to explain a player that moved 0.08 units instead of
## 7. Keycode steps have no such default and hold until a later step releases.
func _execute_input_step(step: Dictionary) -> Dictionary:
	var events: Array = []
	var auto_released := false

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
			auto_released = true
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

	var path := get_game_user_dir() + "/mcp_input_commands"
	var wait_sec := float(step.get("consume_timeout", 2.0))

	# The input channel is ONE file slot and FileAccess.WRITE truncates it, so two
	# adjacent input steps landing inside a single game frame used to destroy each
	# other: the first payload was gone before MCPGameInput polled, and both steps
	# still reported sent true. This runner sequences its own steps, so it waits
	# for the game to take a pending payload before writing and again after.
	var slot_was_clear := await _await_input_slot_clear(path, wait_sec)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "Failed to write input commands"}
	file.store_string(JSON.stringify({"sequence_events": events, "frame_delay": int(step.get("frame_delay", 1))}))
	file.close()

	var consumed := await _await_input_slot_clear(path, wait_sec)

	var result := {"sent": true, "event_count": events.size(), "consumed": consumed}
	if not slot_was_clear:
		result["overwrote_pending"] = true
	if not consumed:
		result["warning"] = "The game did not read this payload within %.1fs, so a later input step may overwrite it. A debugger break or a stopped game is the usual cause; --consume-timeout on the step raises the wait." % wait_sec
	if auto_released:
		result["auto_released"] = true
	return result


## Poll until the game has emptied the one-slot input file (MCPGameInput deletes
## it on read), up to timeout_sec. True means the slot is clear. The wait is
## bounded on purpose: a game stopped at a debugger break never polls, so a
## scenario must report that rather than hang on it.
func _await_input_slot_clear(path: String, timeout_sec: float) -> bool:
	if not FileAccess.file_exists(path):
		return true
	var attempts := maxi(int(timeout_sec / 0.05), 1)
	while attempts > 0:
		await get_tree().create_timer(0.05).timeout
		if not FileAccess.file_exists(path):
			return true
		if not EditorInterface.is_playing_scene():
			return false
		attempts -= 1
	return false


## A scenario screenshot step. Without save_path the capture is taken and thrown
## away (the frames come back base64 and nothing here keeps them), which the
## result now says instead of reporting a bare captured true. With save_path the
## GAME writes the PNG, because the capture happens in the game process: user://
## therefore resolves under the game's own user-data dir, not the editor's.
func _execute_screenshot_step(step: Dictionary) -> Dictionary:
	var save_path := str(step.get("save_path", ""))
	if save_path.is_empty():
		var shot := await _send_game_command("capture_frames", {
			"count": 1,
			"frame_interval": 1,
			"half_resolution": optional_bool(step, "half_resolution", true),
		}, 5.0)
		if not shot.has("result"):
			return {"captured": false, "saved": false, "error": "Screenshot capture failed"}
		return {
			"captured": true,
			"saved": false,
			"note": "The frame was captured but not kept. Give the step a save_path (a user:// or res:// path the game writes) to keep the PNG.",
		}

	var guard := guard_project_path(save_path)
	if not guard.is_empty():
		var why: Dictionary = guard["error"]
		return {"captured": false, "saved": false, "error": str(why.get("message", "Invalid save_path"))}

	var saved := await _send_game_command("screenshot", {"save_path": save_path}, 8.0)
	if not saved.has("result"):
		return {"captured": false, "saved": false, "error": "Screenshot capture failed"}
	var payload: Dictionary = saved["result"]
	var result := {
		"captured": true,
		"saved": true,
		"save_path": str(payload.get("saved_path", save_path)),
		"width": payload.get("width", 0),
		"height": payload.get("height", 0),
	}
	if bool(payload.get("black_frame", false)):
		result["black_frame"] = true
	return result


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
	var no_autoload := game_autoload_error("MCPGameInspector")
	if not no_autoload.is_empty():
		return no_autoload

	var user_dir := get_game_user_dir()
	var request_path := user_dir + "/mcp_game_request"
	var response_path := user_dir + "/mcp_game_response"

	if FileAccess.file_exists(response_path):
		DirAccess.remove_absolute(response_path)

	var request_id := next_game_request_id()
	var req := FileAccess.open(request_path, FileAccess.WRITE)
	if req == null:
		return error_internal("Could not create game request file")
	req.store_string(JSON.stringify({"command": command, "params": params, "_id": request_id}))
	req.close()

	var attempts := int(timeout_sec / 0.1)
	var text := ""
	var unreadable := false
	while attempts > 0:
		await get_tree().create_timer(0.1).timeout
		if FileAccess.file_exists(response_path):
			# Shared tolerant read (base_command): the response file can be locked
			# for an instant after the game renames it into place.
			var read: Array = await read_game_response(response_path)
			DirAccess.remove_absolute(response_path)
			var body := String(read[0])
			if body.strip_edges().is_empty():
				unreadable = true
				break
			# A response carrying a different id answers an EARLIER request the game
			# finished late. It is not this call's answer, so drop it and keep waiting.
			if is_stale_game_response(body, request_id):
				attempts -= 1
				continue
			text = body
			break
		if not EditorInterface.is_playing_scene():
			if FileAccess.file_exists(request_path):
				DirAccess.remove_absolute(request_path)
			return error(-32000, "Game stopped during command execution")
		attempts -= 1

	if unreadable:
		return error_internal("Could not read game response file (%s)" % response_path)
	if text.is_empty():
		# A debugger break is the usual cause, and game_timeout_error names it and
		# points at debug.resume. This path used to press the debugger's Continue
		# button itself: it hid a break the caller never asked to release, matched
		# the button by its localized tooltip, and let the freed command's late
		# reply be read as this one's answer.
		if FileAccess.file_exists(request_path):
			DirAccess.remove_absolute(request_path)
		return game_timeout_error(timeout_sec)

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return error_internal("Invalid response JSON from game")
	(parsed as Dictionary).erase("_id")
	if parsed.has("error"):
		return error(-32000, str(parsed["error"]))
	return success(parsed)


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
			"description": "Run a scripted scenario against the playing game: a sequence of --steps (input/wait/assert/screenshot) driven over file IPC. Optionally (re)starts the scene first. Requires a playing scene. An 'input' step with an action and pressed true is RELEASED in the same batch unless it sets auto_release false, so a hold-then-wait needs that flag or it runs as a one-frame tap; a step that auto-released reports auto_released true. Each input step waits for the game to read its payload before the next step runs and reports consumed true or false, so adjacent steps no longer overwrite each other.",
			"params": [
				doc_param("steps", "Array", true, "Non-empty JSON array of step objects, each with a 'type': 'input' ({action|keycode, pressed, strength, frame_delay, auto_release, consume_timeout}), 'wait' ({seconds} or {node_path, timeout}), 'assert' ({text} or {node_path, property, expected, operator}), or 'screenshot' ({save_path, half_resolution}). A screenshot step with save_path has the GAME write the PNG there (user:// is the game's user-data dir) and reports save_path; without one the capture is discarded and the step reports saved false."),
				doc_param("scene_path", "String", false, "'main', 'current', or a scene file path to (re)start before running; omit to use the already-playing scene."),
			],
		},
		"test.assert_node_state": {
			"description": "Assert a property on a node in the running game compares as expected. The expected value is coerced to the live value's type before comparing; a pair that cannot be compared is passed false with a 'reason' naming both types. Requires a playing scene.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node path relative to the running scene root."),
				doc_param("property", "String", true, "Property to read."),
				doc_param("expected", "JSON", true, "Expected value. Godot literals work as strings: \"Vector2(64, 0)\", \"#ff0000\", \"true\", numbers."),
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
			"description": "Summarize accumulated test results collected across test.* calls. Only assertion-bearing results score: total, passed, failed and pass_rate count assertions alone, while input/wait/screenshot steps are reported as steps_recorded.",
			"params": [
				doc_param("clear", "bool", false, "Clear the accumulated results after reporting (default true)."),
			],
		},
	}
