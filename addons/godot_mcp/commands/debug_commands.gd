@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Interactive debugger control for a game launched from the editor (scene.play):
## arm breakpoints through the script gutter, read a paused game's stack and
## variables, step it, and hot-reload changed scripts into the live process.
##
## All state lives in services/debugger_bridge.gd, reached through
## editor_plugin.debugger_bridge. These commands are not undoable and write no
## files: a named button press and a gutter toggle are editor UI, not code
## execution, so there is no UndoRedo, no path guard, and no audit here.

## How long a resume watches for the game to break again, and how long a step waits
## for the new break to land. Both bounded: a resume that hits nothing simply keeps
## running, which is a real outcome and not a timeout to apologize for.
const RESUME_WATCH_MS := 1000
const STEP_WAIT_MS := 2000
const PAUSE_WATCH_MS := 1000

## Frames to let pass after edit_script before the gutter is reachable: the script
## editor builds its text control over the frames following the open.
const EDITOR_OPEN_FRAMES := 4

## Variables reported without --all-vars, so one break cannot bury a result.
const VARS_CAP := 40

## Godot callbacks that fire far too often for a breakpoint to be left armed in.
## Every continue re-breaks immediately while one is armed, so the game can never
## move or take input.
const HOT_CALLBACKS := {
	"_process": "every frame",
	"_physics_process": "every physics frame",
	"_integrate_forces": "every physics frame",
	"_draw": "every time the node redraws",
	"_input": "on every input event",
	"_unhandled_input": "on every unhandled input event",
	"_unhandled_key_input": "on every unhandled key event",
	"_shortcut_input": "on every shortcut event",
	"_gui_input": "on every input event over the control",
}

## debug.step --mode values, which are also the bridge's action names.
const STEP_MODES := ["over", "into", "out"]

## The variable groups as the game sends them (RemoteDebugger's stack-var types),
## in the wording results report.
const VAR_KINDS := {0: "local", 1: "member", 2: "global"}


func get_commands() -> Dictionary:
	return {
		"debug.set_breakpoint": _set_breakpoint,
		"debug.remove_breakpoint": _remove_breakpoint,
		"debug.breakpoints": _breakpoints,
		"debug.clear_breakpoints": _clear_breakpoints,
		"debug.state": _break_state,
		"debug.frame": _select_frame,
		"debug.resume": _resume,
		"debug.pause": _pause,
		"debug.step": _step,
		"debug.reload_scripts": _reload_scripts,
	}


# --- Breakpoints ------------------------------------------------------------

func _set_breakpoint(params: Dictionary) -> Dictionary:
	return await _toggle_breakpoint(params, true)


func _remove_breakpoint(params: Dictionary) -> Dictionary:
	return await _toggle_breakpoint(params, false)


## Arm or clear one line through the editor's own script gutter.
##
## This is deliberately the long way round. The raw "breakpoint" debugger message
## would arm the GAME only: invisible in the gutter and the Breakpoints list, and
## dropped by the next run, since a new session is sent the EDITOR's breakpoint map.
## Toggling the gutter goes through CodeEdit's breakpoint_toggled signal into that
## map, so the user sees it, the game already running gets it (it hits the next time
## the line executes, with no restart), and a later run gets it too.
func _toggle_breakpoint(params: Dictionary, enabled: bool) -> Dictionary:
	var bridge_res := _require_bridge()
	if bridge_res[1] != null:
		return bridge_res[1]

	var pr := require_string(params, "path")
	if pr[1] != null:
		return pr[1]
	var path := normalize_project_path(pr[0])
	if not params.has("line"):
		return error_invalid_params("Missing required parameter: line")
	var line := optional_int(params, "line", 0)
	if line <= 0:
		return error_invalid_params("'line' is 1-based and must be greater than 0")
	if path.get_extension().to_lower() != "gd":
		return error_invalid_params("%s is not a GDScript file; a breakpoint is armed on a line of a .gd script" % path)
	if not FileAccess.file_exists(path):
		return error_not_found("Script '%s'" % path)

	var opened := await _open_gutter(path, line)
	if opened[1] != null:
		return opened[1]
	var code: CodeEdit = opened[0]

	var index := line - 1
	if index >= code.get_line_count():
		return error_invalid_params("Line %d is outside %s, which has %d lines" % [line, path, code.get_line_count()])

	var text := code.get_line(index).strip_edges()
	if enabled:
		var never := _never_executes(text)
		if not never.is_empty():
			var runnable := _first_executable_line(code, index)
			var runnable_text := "" if runnable <= 0 else code.get_line(runnable - 1).strip_edges()
			return _unhittable_error(path, line, never, runnable, runnable_text)
	code.set_line_as_breakpoint(index, enabled)
	if code.is_line_breakpointed(index) != enabled:
		return error_internal("the gutter did not take the change on line %d of %s" % [line, path])

	var bridge: Variant = bridge_res[0]
	bridge.record_armed(path, line, enabled)

	var result := {
		"path": path,
		"line": line,
		"enabled": enabled,
		"line_text": text,
		"live_now": EditorInterface.is_playing_scene(),
	}
	if enabled:
		var hot := _hot_callback_note(_enclosing_function(code, index))
		if not hot.is_empty():
			result["warning"] = hot
	return success(result)


## The refusal an unhittable line earns, naming the line that would work instead.
func _unhittable_error(path: String, line: int, never: String, runnable: int, suggestion: String) -> Dictionary:
	var data := {"path": path, "line": line, "line_is": never}
	if runnable > 0:
		data["suggestion"] = "Arm line %d instead (\"%s\")" % [runnable, suggestion]
	else:
		data["suggestion"] = "Arm a line that actually executes"
	return error(-32602, "Line %d of %s is %s, so execution never stops there and this breakpoint could never be hit" % [line, path, never], data)


## Open a script and reach the CodeEdit carrying its breakpoint gutter.
## Returns [CodeEdit, error_or_null].
func _open_gutter(path: String, line: int) -> Array:
	var script: Variant = load(path)
	if not (script is Script):
		return [null, error_invalid_params("%s is not a script, so it has no lines to break on" % path)]
	# edit_script's line is 1-based, with 0 meaning "keep the current position".
	EditorInterface.edit_script(script as Script, maxi(line, 0))
	for i in EDITOR_OPEN_FRAMES:
		await get_tree().process_frame

	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return [null, error_internal("the editor's script editor could not be reached")]
	var current_script := script_editor.get_current_script()
	# A mismatch means the open failed, and arming a gutter in whatever file happens
	# to be in front would put the breakpoint somewhere nobody asked for.
	if current_script == null or normalize_project_path(current_script.resource_path) != path:
		var showing := "nothing" if current_script == null else current_script.resource_path
		return [null, error_conflict("The editor did not open %s (it is showing %s), so no gutter for it could be reached" % [path, showing])]
	var current_editor := script_editor.get_current_editor()
	if current_editor == null or not current_editor.has_method("get_base_editor"):
		return [null, error_internal("this editor build's script editor exposes no text control to toggle a breakpoint in")]
	var code := current_editor.call("get_base_editor") as CodeEdit
	if code == null:
		return [null, error_internal("the open script is not a text editor whose gutter can carry a breakpoint")]
	return [code, null]


## What a line IS when it can never be stopped on, or "" when it holds a statement
## that runs. The function signature is the case that matters: unlike a blank or a
## comment it looks exactly like the code you meant. `var` is deliberately absent,
## since its initializer does run.
func _never_executes(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return "blank"
	if trimmed.begins_with("#"):
		return "a comment"
	if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
		return "a function declaration"
	if trimmed.begins_with("class_name") or trimmed.begins_with("extends"):
		return "a class declaration"
	if trimmed.begins_with("signal "):
		return "a signal declaration"
	if trimmed.begins_with("enum "):
		return "an enum declaration"
	return ""


## The 1-based line after `from_index` a breakpoint can actually stop on, or -1.
func _first_executable_line(code: CodeEdit, from_index: int) -> int:
	for index in range(from_index + 1, code.get_line_count()):
		if _never_executes(code.get_line(index)).is_empty():
			return index + 1
	return -1


## The name of the function a line sits inside, or "" at class scope. Found by
## walking UP to the nearest declaration, the only way to know what a bare line of a
## body belongs to.
func _enclosing_function(code: CodeEdit, index: int) -> String:
	for i in range(mini(index, code.get_line_count() - 1), -1, -1):
		var text := code.get_line(i).strip_edges()
		if text.begins_with("func ") or text.begins_with("static func "):
			var after := text.trim_prefix("static ").trim_prefix("func ")
			return after.split("(")[0].strip_edges()
	return ""


func _hot_callback_note(function_name: String) -> String:
	if not HOT_CALLBACKS.has(function_name):
		return ""
	return "%s runs %s, so the game breaks again the moment it resumes and cannot move or take input while this is armed. Remove it before continuing." % [function_name, String(HOT_CALLBACKS[function_name])]


func _breakpoints(_params: Dictionary) -> Dictionary:
	var bridge_res := _require_bridge()
	if bridge_res[1] != null:
		return bridge_res[1]
	var bridge: Variant = bridge_res[0]
	var armed: Array = bridge.armed_list()
	return success({
		"breakpoints": armed,
		"count": armed.size(),
		"note": "Only breakpoints set through debug.set_breakpoint are tracked; the editor exposes no way to enumerate ones the user set by hand.",
	})


## Clear every breakpoint this group armed, through the same gutter mechanism.
## Breakpoints the USER set by hand are never touched: we did not arm them.
func _clear_breakpoints(_params: Dictionary) -> Dictionary:
	var bridge_res := _require_bridge()
	if bridge_res[1] != null:
		return bridge_res[1]
	var bridge: Variant = bridge_res[0]

	var cleared: Array = []
	var failed: Array = []
	for entry: Dictionary in bridge.armed_list():
		var path := String(entry["path"])
		var line := int(entry["line"])
		var res := await _toggle_breakpoint({"path": path, "line": line}, false)
		if res.has("error"):
			failed.append({"path": path, "line": line, "reason": String((res["error"] as Dictionary)["message"])})
			continue
		cleared.append({"path": path, "line": line})
	return success({
		"cleared": cleared,
		"cleared_count": cleared.size(),
		"failed": failed,
		"remaining": bridge.armed_list(),
	})


# --- Reading a paused game --------------------------------------------------

func _break_state(params: Dictionary) -> Dictionary:
	var watcher := _require_watcher()
	if watcher[1] != null:
		return watcher[1]
	var bridge: Variant = watcher[0]

	var state: Dictionary = bridge.current_break()
	if state.is_empty():
		return success({"breaked": false, "playing": EditorInterface.is_playing_scene()})
	await bridge.settle(state)
	return success(_describe_break(bridge, state, params))


## Select a stack frame and read its variables. Selecting through the debugger's own
## Tree is what makes the EDITOR fetch that frame's variables; there is no
## scriptable request for them.
func _select_frame(params: Dictionary) -> Dictionary:
	var watcher := _require_watcher()
	if watcher[1] != null:
		return watcher[1]
	var bridge: Variant = watcher[0]

	if not params.has("index"):
		return error_invalid_params("Missing required parameter: index")
	var wanted := optional_int(params, "index", -1)
	if wanted < 0:
		return error_invalid_params("'index' is a 0-based stack frame index")

	var state: Dictionary = bridge.current_break()
	if state.is_empty():
		return error(-32000, "The game is not paused, so there is no stack to select a frame in",
			{"suggestion": "Use debug.state to see what is true right now."})

	if wanted != int(bridge.synced_selection(state)):
		var picked: Dictionary = bridge.select_frame(state, wanted)
		if not bool(picked["ok"]):
			return error_not_found("Stack frame %d" % wanted, String(picked["why"]))
		await bridge.settle(state)

	# The user can click a frame by hand while this settles; reporting one frame's
	# variables under another frame's number would be a lie, so refuse instead.
	var landed := int(bridge.synced_selection(state))
	if landed != wanted:
		return error_conflict(
			"Frame %d was asked for, but the debugger's stack list now has frame %d selected" % [wanted, landed],
			{"selected_frame": landed, "suggestion": "Ask for frame %d again on its own." % wanted}
		)
	return success(_describe_break(bridge, state, params))


## One break as a result payload: what stopped the game, the stack, and the selected
## frame's variables.
func _describe_break(bridge: Variant, state: Dictionary, params: Dictionary) -> Dictionary:
	var selected := int(bridge.synced_selection(state))
	var frames: Array = []
	for frame: Dictionary in (state.get("frames", []) as Array):
		frames.append({
			"frame": int(frame.get("frame", frames.size())),
			"file": String(frame.get("file", "")),
			"line": int(frame.get("line", 0)),
			"function": String(frame.get("function", "")),
		})

	var all_vars := optional_bool(params, "all_vars", false)
	var needle := optional_string(params, "filter", "").to_lower()
	var matched: Array = []
	for data: Array in (state.get("vars", []) as Array):
		var var_name := String(data[0])
		if not needle.is_empty() and not var_name.to_lower().contains(needle):
			continue
		matched.append({
			"name": var_name,
			"kind": String(VAR_KINDS.get(int(data[1]) if data.size() > 1 else -1, "unknown")),
			# The debugger encodes an object as an id stub, not the object itself.
			"value": _render_value(data[3] if data.size() > 3 else null),
		})

	var out := {
		"breaked": true,
		"reason": String(state.get("reason", "")),
		"can_debug": bool(state.get("can_debug", false)),
		"frames": frames,
		"selected_frame": selected,
		"vars_total": matched.size(),
	}
	if not all_vars and matched.size() > VARS_CAP:
		out["vars_truncated"] = matched.size() - VARS_CAP
		matched = matched.slice(0, VARS_CAP)
	out["vars"] = matched
	if not needle.is_empty():
		out["filter"] = optional_string(params, "filter", "")
	return out


## A stack variable's value as JSON. A live object arrives as an id stub — the
## debugger encodes objects without their contents — so it is reported as an id
## rather than printed as if it were the object.
func _render_value(value: Variant) -> Variant:
	if value is Object and (value as Object).has_method("get_object_id"):
		return {"object_id": int((value as Object).call("get_object_id"))}
	return PropertyParser.serialize_value(value)


# --- Execution control ------------------------------------------------------

func _resume(_params: Dictionary) -> Dictionary:
	var watcher := _require_watcher()
	if watcher[1] != null:
		return watcher[1]
	var bridge: Variant = watcher[0]

	var state: Dictionary = bridge.current_break()
	if state.is_empty():
		return error(-32000, "The game is not paused, so there is nothing to resume",
			{"playing": EditorInterface.is_playing_scene()})

	var was_at := int(state.get("at", 0))
	var pressed: Dictionary = bridge.press("resume", bridge.panel_for(state))
	if not bool(pressed["ok"]):
		return error_internal(String(pressed["why"]))

	var landed := await _await_new_break(bridge, was_at, RESUME_WATCH_MS)
	var out := {"resumed": true, "rebroke": not landed.is_empty(), "playing": EditorInterface.is_playing_scene()}
	if not landed.is_empty():
		await bridge.settle(landed)
		out["state"] = _describe_break(bridge, landed, {})
		out["note"] = "It stopped again immediately, which is what a breakpoint in a per-frame callback does on every resume."
	return success(out)


func _pause(_params: Dictionary) -> Dictionary:
	var watcher := _require_watcher()
	if watcher[1] != null:
		return watcher[1]
	var bridge: Variant = watcher[0]

	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing", {"suggestion": "Use scene.play first"})
	if not (bridge.current_break() as Dictionary).is_empty():
		return error_conflict("The game is already paused", {"suggestion": "Use debug.state to read it, or debug.resume to let it run on."})

	var pressed_at := Time.get_ticks_msec()
	var pressed: Dictionary = bridge.press("pause", null)
	if not bool(pressed["ok"]):
		return error_internal(String(pressed["why"]))

	var landed := await _await_new_break(bridge, pressed_at, PAUSE_WATCH_MS)
	var out := {
		"pause_requested": true,
		"breaked": not landed.is_empty(),
		"note": "The press is asynchronous: the game stops at its next script statement, so no break here is not a failure. Poll debug.state, and note that a game idle in engine code with no GDScript running never lands one.",
	}
	if not landed.is_empty():
		await bridge.settle(landed)
		out["state"] = _describe_break(bridge, landed, {})
	return success(out)


func _step(params: Dictionary) -> Dictionary:
	var watcher := _require_watcher()
	if watcher[1] != null:
		return watcher[1]
	var bridge: Variant = watcher[0]

	var mode := optional_string(params, "mode", "over").to_lower()
	if not mode in STEP_MODES:
		return error_invalid_params("'mode' must be one of over, into, out (got '%s')" % mode)

	var state: Dictionary = bridge.current_break()
	if state.is_empty():
		return error(-32000, "The game is not paused, so there is nothing to step",
			{"playing": EditorInterface.is_playing_scene()})
	if not bool(state.get("can_debug", false)):
		return error_conflict(
			"This break is not steppable: the engine reports can_debug false, which is what a runtime error break looks like",
			{"suggestion": "Only debug.resume is offered from here, and it resumes with the failed function abandoned."}
		)

	var was_at := int(state.get("at", 0))
	var pressed: Dictionary = bridge.press(mode, bridge.panel_for(state))
	if not bool(pressed["ok"]):
		return error_internal(String(pressed["why"]))

	var landed := await _await_new_break(bridge, was_at, STEP_WAIT_MS)
	if landed.is_empty():
		if not EditorInterface.is_playing_scene():
			return success({"stepped": true, "mode": mode, "playing": false,
				"note": "The game ran to the end instead of stopping again; the run is over."})
		return success({"stepped": true, "mode": mode, "playing": true,
			"note": "The game ran on instead of stopping again, so it is running now, not paused."})

	await bridge.settle(landed)
	var frames: Array = landed.get("frames", [])
	var out := {"stepped": true, "mode": mode, "playing": true, "breaked": true}
	if not frames.is_empty():
		var top: Dictionary = frames[0]
		out["location"] = {
			"file": String(top.get("file", "")),
			"line": int(top.get("line", 0)),
			"function": String(top.get("function", "")),
		}
	out["reason"] = String(landed.get("reason", ""))
	return success(out)


## Wait, bounded, for a break newer than the one just left. A resume that hits
## nothing simply keeps running, which is a real outcome, so {} is not an error.
func _await_new_break(bridge: Variant, after_msec: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state: Dictionary = bridge.current_break()
		if not state.is_empty() and int(state.get("at", 0)) > after_msec:
			return state
		if not EditorInterface.is_playing_scene():
			return {}
		await get_tree().process_frame
	return {}


# --- Hot reload -------------------------------------------------------------

## Push edited .gd files into the RUNNING game: every live instance starts running
## the new code and keeps the state it had.
func _reload_scripts(params: Dictionary) -> Dictionary:
	var bridge_res := _require_bridge()
	if bridge_res[1] != null:
		return bridge_res[1]
	var bridge: Variant = bridge_res[0]

	if not EditorInterface.is_playing_scene():
		return error(-32000, "No scene is currently playing, so there is nothing to reload into",
			{"suggestion": "Use scene.play first"})
	var live: Array = bridge.active_sessions()
	if live.is_empty():
		return error(-32000, "The game is starting and has no debug session yet",
			{"suggestion": "Wait a moment and call again."})

	var armed := _reload_armed(bridge)
	if armed[1] != null:
		return armed[1]

	var session: EditorDebuggerSession = (live[0] as Array)[1]
	# A game stopped at a breakpoint is frozen by the DEBUGGER: scene: messages
	# queue up unheard until it resumes.
	if session.is_breaked():
		return error_conflict("The game is paused at a break, and a reload sent now would queue unheard",
			{"suggestion": "Resume it with debug.resume, then reload."})

	var chosen := _reload_paths(params, bridge)
	if chosen[1] != null:
		return chosen[1]
	var paths: Array = chosen[0]
	if paths.is_empty():
		return success({"reloaded": [], "sessions_active": live.size(),
			"note": "No .gd file has changed since this run started, so there was nothing to reload."})

	# The editor's own filesystem must know a file changed before the game re-reads
	# it, exactly as saving in the script editor would.
	var filesystem := EditorInterface.get_resource_filesystem()
	for path: String in paths:
		filesystem.update_file(path)
	# A core-debugger message handled inside the game process: no agent, no reply.
	session.send_message("scene:reload_cached_files", [PackedStringArray(paths)])

	return success({
		"reloaded": paths,
		"sessions_active": live.size(),
		"caveats": [
			"An autoload singleton keeps the instance it already has.",
			"A reload replaces code, not state: changed @export defaults and already-initialized var values do not re-apply to live nodes, only to ones created afterwards.",
			"class_name registration updates only on a fresh run.",
		],
	})


## Whether the running game can take a reload at all. A run scene.play started is
## armed by construction; the user's own run is judged by their Debug menu as it
## stands now, which is the only evidence there is. Returns [true, error_or_null].
func _reload_armed(bridge: Variant) -> Array:
	var run: Dictionary = bridge.run_record()
	if not run.is_empty():
		if bool(run.get("live_reload", false)):
			return [true, null]
		return [false, error_conflict(
			"This run started before hot reload was armed, so a reload would not apply: the change never reaches the game, and for some scripts the node running them stops processing instead",
			{"suggestion": "Stop it and relaunch with scene.play, which arms both flags for every run it starts."}
		)]
	var off: Array = bridge.reload_flags_off()
	if off.is_empty():
		return [true, null]
	return [false, error_conflict(
		"This run was not launched by scene.play, and the editor's Debug menu has %s switched off, so a reload would silently fail to apply" % " and ".join(PackedStringArray(off)),
		{"suggestion": "Relaunch with scene.play (every run it starts is armed), or ask the user to tick those Debug-menu options and run again."}
	)]


## Which .gd files a reload covers: the ones named, or every script changed since
## the run started. Returns [Array, error_or_null].
func _reload_paths(params: Dictionary, bridge: Variant) -> Array:
	if params.has("paths"):
		var ar := require_array(params, "paths")
		if ar[1] != null:
			return [[], ar[1]]
		var resolved: Array = []
		for entry in (ar[0] as Array):
			var path := normalize_project_path(String(entry))
			if path.get_extension().to_lower() != "gd":
				return [[], error_invalid_params("%s is not a .gd script; a reload swaps GDScript code, and a scene or resource change needs a fresh run" % path)]
			if not FileAccess.file_exists(path):
				return [[], error_not_found("Script '%s'" % path)]
			resolved.append(path)
		return [resolved, null]

	var run: Dictionary = bridge.run_record()
	if run.is_empty():
		return [[], error_invalid_params("This run was not started by scene.play, so there is no launch time to measure 'changed since' against; pass --paths with the scripts to reload")]
	var since := int(run.get("started_unix", 0))
	var changed: Array = []
	_collect_changed_scripts("res://", since, changed)
	changed.sort()
	return [changed, null]


## Every .gd under `dir` modified at or after `since` (unix seconds). Hidden dirs
## are skipped: .godot holds the editor's own caches, not project scripts.
func _collect_changed_scripts(dir_path: String, since: int, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect_changed_scripts(full, since, out)
		elif entry.get_extension().to_lower() == "gd" and FileAccess.get_modified_time(full) >= since:
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


# --- Preambles --------------------------------------------------------------

## The debugger bridge, or the error explaining its absence. Returns [bridge, err].
func _require_bridge() -> Array:
	if editor_plugin == null or not ("debugger_bridge" in editor_plugin):
		return [null, error_internal("the debugger bridge is not available in this plugin build")]
	var bridge: Variant = editor_plugin.debugger_bridge
	if bridge == null:
		return [null, error_internal("the debugger bridge is not running (the plugin may be reloading)")]
	return [bridge, null]


## The bridge with its break-state watcher hooked to the editor's debugger panels.
## Re-attempted on every use, so a panel created after plugin load is picked up.
func _require_watcher() -> Array:
	var bridge_res := _require_bridge()
	if bridge_res[1] != null:
		return bridge_res
	var bridge: Variant = bridge_res[0]
	var hook: Dictionary = bridge.ensure_connected()
	if int(hook["found"]) == 0:
		return [null, error_internal("the debugger's session panels could not be located in this editor build (its internal layout may have changed)")]
	if int(hook["hooked"]) == 0:
		return [null, error_internal("this editor build's debugger panel raises no break signals, so a paused game cannot be read from it")]
	return [bridge, null]


func get_command_docs() -> Dictionary:
	return {
		"debug.set_breakpoint": {
			"description": "Arm a breakpoint on one line of a .gd script through the editor's script gutter, so it shows in the gutter and the debugger's Breakpoints list and is live for the game already running (it hits the next time that line executes, with no restart). Refuses a line that can never be hit (blank, comment, or a declaration) and names the first executable line instead; warns when the enclosing function is a hot per-frame callback.",
			"params": [
				doc_param("path", "String", true, "res:// path to the .gd script."),
				doc_param("line", "int", true, "1-based line to break on."),
			],
		},
		"debug.remove_breakpoint": {
			"description": "Clear a breakpoint from one line of a .gd script through the same gutter mechanism.",
			"params": [
				doc_param("path", "String", true, "res:// path to the .gd script."),
				doc_param("line", "int", true, "1-based line to clear."),
			],
		},
		"debug.breakpoints": {
			"description": "List the breakpoints this group armed. Only breakpoints set through debug.set_breakpoint are tracked: the editor exposes no way to enumerate ones the user set by hand.",
		},
		"debug.clear_breakpoints": {
			"description": "Remove every breakpoint this group armed, through the same gutter mechanism. Breakpoints the user set by hand are untouched. Best-effort per file; reports what cleared and what failed.",
		},
		"debug.state": {
			"description": "Report the current break: what stopped the game, whether stepping is offered, the GDScript call stack, and the selected frame's variables. Returns breaked:false when nothing is paused. Waits for the stack the editor asks for on its own to land before answering.",
			"params": [
				doc_param("all_vars", "bool", false, "Report every variable instead of the first 40."),
				doc_param("filter", "String", false, "Only variables whose name contains this substring."),
			],
		},
		"debug.frame": {
			"description": "Select a stack frame by 0-based --index and report that frame's variables. Selecting through the debugger's own stack list is what makes the editor fetch the frame's variables. Refuses if something else moved the selection while the read settled.",
			"params": [
				doc_param("index", "int", true, "0-based stack frame index (0 is innermost)."),
				doc_param("all_vars", "bool", false, "Report every variable instead of the first 40."),
				doc_param("filter", "String", false, "Only variables whose name contains this substring."),
			],
		},
		"debug.resume": {
			"description": "Let a paused game run on, by pressing the debugger's Continue control. Watches about a second for a new break and reports rebroke:true with the new state when one lands, which is what a breakpoint in a per-frame callback does on every resume.",
		},
		"debug.pause": {
			"description": "Break into a running game, by pressing the debugger's Pause control. Requires a game that is playing and not already paused. The press is asynchronous: the game stops at its next script statement, so an empty result right away is not a failure.",
		},
		"debug.step": {
			"description": "Advance a paused game one step, by pressing the debugger's own stepping control. Waits up to two seconds for the new break and reports where it landed; says so instead if the game ran on or ended. Refuses when the engine reports the break as not steppable (a runtime error break).",
			"params": [
				doc_param("mode", "String", false, "'over' (default), 'into', or 'out'."),
			],
		},
		"debug.reload_scripts": {
			"description": "Hot-reload changed .gd files into the running game without restarting it: every live instance starts running the new code and keeps the state it had. Requires a run launched with the Debug-menu hot-reload flags armed (scene.play arms them) and a game that is not paused at a break. Omit --paths to reload every .gd changed since the run started.",
			"params": [
				doc_param("paths", "JSON", false, "JSON array of res:// .gd paths, e.g. '[\"res://player.gd\"]'. Omit for every script changed since the run started."),
			],
		},
	}
