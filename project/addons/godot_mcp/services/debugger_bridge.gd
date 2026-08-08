@tool
extends EditorDebuggerPlugin

## The addon's foothold in the editor debugger, behind the `debug` command group.
## plugin.gd registers it with add_debugger_plugin, which is the only scriptable
## route to EditorDebuggerSession objects — and so to is_active()/is_breaked() and
## the send_message channel debug.reload_scripts rides.
##
## Nothing here ASKS the game for a stack. On every break the editor itself sends
## get_stack_dump and auto-selects frame 0 (which fetches that frame's variables),
## landing ~50-200 ms behind the break signal; this class only records the signals
## those replies raise, which is why every read settles before it answers.

## The debugger toolbar controls, keyed by the action a command takes, as the theme
## icon that identifies each button. Icons, not tooltips: tooltips are localized.
const ICONS := {
	"resume": "DebugContinue",
	"pause": "Pause",
	"over": "DebugNext",
	"into": "DebugStep",
	"out": "DebugOut",
}

## The editor's Debug-menu hot-reload flags, as the project-metadata keys the engine
## reads when it builds a run's arguments (EditorSettings project metadata, section
## "debug_options"). scene.play arms BOTH: the reload message needs both set at
## LAUNCH or it silently breaks the running scripts instead of updating them.
const RELOAD_OPTIONS := ["run_live_debug", "run_reload_scripts"]
const RELOAD_OPTION_LABELS := {
	"run_live_debug": "Synchronize Scene Changes",
	"run_reload_scripts": "Synchronize Script Changes",
}

## How long a read waits for a break's stack and variables to arrive.
const SETTLE_MS := 700

## How recent a run record must be to survive a session ending. scene.play stamps
## the record and the OUTGOING run's stopped signal arrives moments later, so a
## fresh stamp has to outlive it; anything older belonged to a run that is over.
const RUN_RECORD_GRACE_MS := 2000

var _sessions: Dictionary = {}  # session id -> EditorDebuggerSession
var _states: Dictionary = {}    # debugger panel instance id -> break state
var _armed: Dictionary = {}     # res:// path -> sorted 1-based lines WE armed
var _run: Dictionary = {}       # {started_msec, started_unix, live_reload}


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null or _sessions.has(session_id):
		return
	_sessions[session_id] = session
	session.stopped.connect(func() -> void:
		_sessions.erase(session_id)
		_retire_run())


## Debug sessions attached to a running game, as [session_id, session] pairs.
func active_sessions() -> Array:
	var live: Array = []
	for session_id in _sessions:
		var session: EditorDebuggerSession = _sessions[session_id]
		if session != null and session.is_active():
			live.append([session_id, session])
	return live


# --- Break-state watcher ----------------------------------------------------

## Hook every debugger panel's break signals, idempotently. Called at creation and
## again from every entry point, so a panel created later is still picked up.
## Returns {found, hooked} to separate "no debugger panel in this build" from
## "this build's panel raises no break signals" — two different honest refusals.
func ensure_connected() -> Dictionary:
	var found := 0
	var hooked := 0
	# There is no public API for the debugger panels; walking the editor's control
	# tree for the class name is the only way to reach them.
	for panel: Node in find_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger"):
		found += 1
		if not panel.has_signal("breaked") or not panel.has_signal("stack_dump"):
			continue
		hooked += 1
		_connect_one(panel, "breaked", _on_breaked)
		_connect_one(panel, "stack_dump", _on_stack_dump)
		_connect_one(panel, "stack_frame_vars", _on_stack_frame_vars)
		_connect_one(panel, "stack_frame_var", _on_stack_frame_var)
		_connect_one(panel, "stopped", _on_stopped)
	return {"found": found, "hooked": hooked}


func _connect_one(panel: Node, signal_name: String, handler: Callable) -> void:
	if not panel.has_signal(signal_name):
		return
	# The panel rides as a bound argument so one handler can serve every session's
	# tab; Callable equality covers the binding, so is_connected still guards.
	var bound := handler.bind(panel)
	if not panel.is_connected(signal_name, bound):
		panel.connect(signal_name, bound)


## A break beginning or ending. The editor raises this BEFORE the stack it then
## asks for arrives, so the record opens empty and fills in.
func _on_breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool, panel: Node) -> void:
	var state := _state(panel)
	if not reallydid:
		state["breaked"] = false
		return
	state["breaked"] = true
	state["reason"] = reason
	state["can_debug"] = can_debug
	state["has_stackdump"] = has_stackdump
	state["frames"] = []
	state["vars"] = []
	state["expected"] = -1
	state["selected"] = 0
	state["at"] = Time.get_ticks_msec()


func _on_stack_dump(frames: Array, panel: Node) -> void:
	_state(panel)["frames"] = frames


## The count the game promises to follow with, which is what tells a read the
## variables have all arrived rather than guessing a delay.
func _on_stack_frame_vars(num_vars: int, panel: Node) -> void:
	var state := _state(panel)
	state["expected"] = num_vars
	state["vars"] = []


func _on_stack_frame_var(data: Array, panel: Node) -> void:
	(_state(panel)["vars"] as Array).append(data)


func _on_stopped(panel: Node) -> void:
	_state(panel)["breaked"] = false


## The panel's own instance id rides the record, so a button press or a frame
## selection can be scoped to the session that is actually paused — a
## multi-instance run has several panels, and the others hold stale stacks.
func _state(panel: Node) -> Dictionary:
	var key := panel.get_instance_id()
	if not _states.has(key):
		_states[key] = {
			"id": key, "breaked": false, "reason": "", "can_debug": false,
			"has_stackdump": false, "frames": [], "vars": [],
			"expected": -1, "selected": 0, "at": 0,
		}
	return _states[key]


## The recorded states whose panels still exist, stale ids dropped in passing.
func live_states() -> Array:
	var out: Array = []
	for key in _states.keys():
		if instance_from_id(int(key)) == null:
			_states.erase(key)
			continue
		out.append(_states[key])
	return out


## The state of the session paused right now, or {} when nothing is paused.
func current_break() -> Dictionary:
	for state: Dictionary in live_states():
		if bool(state["breaked"]):
			return state
	return {}


## The debugger panel a break belongs to, or null once it is gone.
func panel_for(state: Dictionary) -> Node:
	if state.is_empty():
		return null
	return instance_from_id(int(state.get("id", 0))) as Node


## Whether a break's stack and every variable it promised have arrived. A break
## with no script stack at all is complete the moment it is reported.
func stack_landed(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	if not bool(state.get("has_stackdump", false)):
		return true
	if (state.get("frames", []) as Array).is_empty():
		return false
	var expected := int(state.get("expected", -1))
	return expected >= 0 and (state.get("vars", []) as Array).size() >= expected


## Wait, bounded, for the stack and variables the editor already asked for. Never
## a request of its own — see the class note.
func settle(state: Dictionary) -> void:
	var deadline := Time.get_ticks_msec() + SETTLE_MS
	while Time.get_ticks_msec() < deadline and not stack_landed(state):
		await Engine.get_main_loop().process_frame


# --- Debugger panel controls ------------------------------------------------

## The debugger toolbar buttons, as theme icon name -> Button, matched by icon
## identity because the tooltips are localized. A `panel` scopes the search to one
## session's tab: every tab carries its own set, and only the paused session's
## buttons do anything.
func buttons(panel: Node) -> Dictionary:
	var base := EditorInterface.get_base_control()
	var wanted: Dictionary = {}
	for action in ICONS:
		var icon_name := String(ICONS[action])
		wanted[icon_name] = base.get_theme_icon(icon_name, "EditorIcons")
	var found: Dictionary = {}
	var panels: Array = [panel] if panel != null else find_by_class(base, "ScriptEditorDebugger")
	for tab: Node in panels:
		for node: Node in find_by_class(tab, "Button"):
			var button := node as Button
			for icon_name in wanted:
				if button.icon == wanted[icon_name] and not found.has(icon_name):
					found[icon_name] = button
	return found


## Press one stepping control the way the user's hand would. {ok, why}.
##
## The wire messages ("continue"/"step") are not an option: they must carry the
## BREAKING thread's id, which EditorDebuggerSession.send_message cannot set, and
## the buttons additionally clear the execution markers and restore the game's
## foreground and audio. A disabled button is the engine's own verdict on what is
## legal here (an error break reports can_debug false and disables every step), so
## a refusal quotes it instead of guessing.
func press(action: String, panel: Node) -> Dictionary:
	if not ICONS.has(action):
		return {"ok": false, "why": "'%s' is not a debugger action" % action}
	var icon_name := String(ICONS[action])
	var found := buttons(panel)
	if not found.has(icon_name):
		return {"ok": false, "why": "the debugger's %s button could not be located in this editor build (its internal layout may have changed)" % action}
	var button: Button = found[icon_name]
	if button.disabled:
		return {"ok": false, "why": "the debugger's %s button is disabled right now, so the engine does not allow that here" % action}
	button.emit_signal("pressed")
	return {"ok": true, "why": ""}


## The stack tree's item for one frame index, found by the frame dictionary the
## editor stamps on every row — the only fingerprint separating this Tree from the
## debugger's other single-column ones.
func frame_item(tree: Tree, frame: int) -> TreeItem:
	if tree.columns != 1:
		return null
	var root := tree.get_root()
	if root == null:
		return null
	var item := root.get_first_child()
	while item != null:
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary and (meta as Dictionary).has("frame"):
			if int((meta as Dictionary)["frame"]) == frame:
				return item
		item = item.get_next()
	return null


## Select one stack frame through the debugger's OWN stack tree, so the EDITOR
## fetches that frame's variables (there is no scriptable request for them) and its
## inspector shows the frame the result describes. {ok, why}.
func select_frame(state: Dictionary, frame: int) -> Dictionary:
	var panel := panel_for(state)
	if panel == null:
		return {"ok": false, "why": "the debugger panel holding this break is gone"}
	for node: Node in find_by_class(panel, "Tree"):
		var item := frame_item(node as Tree, frame)
		if item == null:
			continue
		# The variables on record belong to the frame being left, so they are
		# dropped rather than read as the new frame's until its reply arrives.
		state["expected"] = -1
		state["vars"] = []
		state["selected"] = frame
		item.select(0)
		return {"ok": true, "why": ""}
	return {"ok": false, "why": "frame %d is not on the debugger's stack list" % frame}


## The frame the debugger's stack tree ACTUALLY has selected, synced into the
## record and returned. Our own memory only tracks selections we made, but the user
## can click a frame by hand between calls — the editor then fetches THAT frame's
## variables, which the signal handlers duly record — so trusting the memory would
## caption one frame's variables with another frame's number.
func synced_selection(state: Dictionary) -> int:
	var panel := panel_for(state)
	if panel != null:
		for node: Node in find_by_class(panel, "Tree"):
			var item := (node as Tree).get_selected()
			if item == null:
				continue
			var meta: Variant = item.get_metadata(0)
			if meta is Dictionary and (meta as Dictionary).has("frame"):
				state["selected"] = int((meta as Dictionary)["frame"])
				break
	return int(state.get("selected", 0))


# --- Armed breakpoints ------------------------------------------------------

## Remember (or forget) a breakpoint the debug group armed. The editor exposes no
## way to enumerate the user's own breakpoints, so this record is what a report can
## honestly name — and every result that reads it says so.
func record_armed(path: String, line: int, enabled: bool) -> void:
	var lines: Array = _armed.get(path, [])
	if enabled:
		if not lines.has(line):
			lines.append(line)
			lines.sort()
	else:
		lines.erase(line)
	if lines.is_empty():
		_armed.erase(path)
	else:
		_armed[path] = lines


## Every breakpoint this session armed and has not removed, as {path, line} entries
## in path then line order.
func armed_list() -> Array:
	var out: Array = []
	var paths: Array = _armed.keys()
	paths.sort()
	for path: String in paths:
		for line: int in _armed[path]:
			out.append({"path": path, "line": line})
	return out


# --- Run record and the Debug-menu hot-reload flags -------------------------

## Stamp what scene.play just launched, so debug.reload_scripts knows whether the
## run can take a reload at all and which scripts changed since it started.
func note_run(live_reload: bool) -> void:
	_run = {
		"started_msec": Time.get_ticks_msec(),
		"started_unix": int(Time.get_unix_time_from_system()),
		"live_reload": live_reload,
	}


func run_record() -> Dictionary:
	return _run


## A run ending retires its record, so a later run the user launched by hand is
## judged by their Debug menu rather than by flags armed for a run that is gone.
func _retire_run() -> void:
	if _run.is_empty():
		return
	if Time.get_ticks_msec() - int(_run.get("started_msec", 0)) < RUN_RECORD_GRACE_MS:
		return
	_run = {}


## Turn both hot-reload flags on, returning what they were so the caller can put
## the user's own Debug menu back.
func arm_reload_flags() -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	var previous: Dictionary = {}
	for key: String in RELOAD_OPTIONS:
		previous[key] = bool(settings.get_project_metadata("debug_options", key, false))
		settings.set_project_metadata("debug_options", key, true)
	return previous


func restore_reload_flags(previous: Dictionary) -> void:
	var settings := EditorInterface.get_editor_settings()
	for key: String in previous:
		settings.set_project_metadata("debug_options", key, bool(previous[key]))


## The hot-reload flags currently switched off in the user's Debug menu, by their
## menu labels — the only evidence about a run this session did not launch.
func reload_flags_off() -> Array:
	var settings := EditorInterface.get_editor_settings()
	var off: Array = []
	for key: String in RELOAD_OPTIONS:
		if not bool(settings.get_project_metadata("debug_options", key, false)):
			off.append(String(RELOAD_OPTION_LABELS[key]))
	return off


# --- Editor control-tree search ---------------------------------------------

## Every node under `root` whose class is exactly `cls`. Internal children are
## included on purpose: the editor builds its panels out of them, so a walk that
## skips them finds nothing.
func find_by_class(root: Node, cls: String) -> Array:
	var found: Array = []
	if root == null:
		return found
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children(true):
			stack.append(child)
		if node.get_class() == cls:
			found.append(node)
	return found
