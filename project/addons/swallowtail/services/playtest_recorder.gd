extends Node

## Records a playtest session INSIDE the running game (NOT @tool). MCPGameInspector
## creates one as a child in _ready, so every playtest.* command reaches it through
## the inspector's shared dispatch, over the editor's file IPC and the direct
## server alike.
##
## While a session records, every frame's wall-clock length goes into a packed
## array, a full Performance snapshot lands every N frames (plus one on each
## spike frame), and inputs, game events, checkpoints, and runtime errors are
## timestamped as they happen. playtest.stop writes the whole session as one JSON
## file under user://swallowtail-playtests/ and the Go side (swallowtail playtest
## report) turns it into numbers.
##
## Frame times come from Time.get_ticks_usec between this node's own _process
## calls, never from Performance.TIME_PROCESS: that monitor is cached and updates
## on a slow cadence, so sampling it per frame reports one value for every frame.
## The wall-clock gap is what a player sees, vsync and pacing included.
##
## Every container is bounded. Past a cap the recorder keeps counting what it
## dropped and the session carries truncated: true with the per-part counts, so a
## long session degrades into a partial record that says so.

const PropertyParser := preload("res://addons/swallowtail/utils/property_parser.gd")

const SESSIONS_DIR := "user://swallowtail-playtests"
const SCHEMA := 1
const KIND := "swallowtail-playtest"

const MAX_FRAMES := 216000  # one hour at 60 fps
const MAX_SAMPLES := 20000
const MAX_EVENTS := 10000
const MAX_INPUTS := 20000
const MAX_MARKS := 1000
const MAX_ERRORS := 1000
const MAX_EVENT_DATA_BYTES := 4096
const MAX_TEXT := 256

const DEFAULT_SAMPLE_EVERY := 30
const MAX_SAMPLE_EVERY := 3600

## A frame counts as a spike for the extra snapshot when it runs this many times
## the running average AND at least SPIKE_MIN_EXCESS_MS over it. The report
## recomputes spikes from the full frame series; this only decides when to grab
## counters at the moment it happened (a texture upload shows as a jump in
## texture memory on exactly that frame and nowhere else).
const SPIKE_FACTOR := 2.0
const SPIKE_MIN_EXCESS_MS := 8.0
const RECENT_FRAMES := 120

## Set by MCPGameInspector when its runtime error capture is live (Godot 4.5+).
## Typed Object for the same reason the inspector's is: the Logger class does not
## exist at the 4.3 floor.
var error_log: Object = null

var _recording := false
var _session_name := ""
var _started_unix := 0.0
var _started_usec := 0
var _last_usec := 0
var _first_frame := -1
var _first_tick_ms := 0.0
var _sample_every := DEFAULT_SAMPLE_EVERY
var _frames_until_sample := 0
var _ema_ms := 0.0
var _error_cursor := 0
# Read at start: by the time a quitting game writes its session, the scene is gone.
var _scene_path := ""
var _viewport_size := [0, 0]

var _frame_ms := PackedFloat64Array()
var _samples: Array = []
var _events: Array = []
var _inputs: Array = []
var _marks: Array = []
var _errors: Array = []
var _dropped := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_recording() -> bool:
	return _recording


# --- Commands (results go back through the inspector's _respond) -------------

func cmd_start(params: Dictionary) -> Dictionary:
	if _recording:
		return _fail(-32009, "A playtest session is already recording ('%s')" % _session_name, {
			"suggestion": "Stop it first with playtest.stop.",
		})
	var every := DEFAULT_SAMPLE_EVERY
	if params.has("sample_every"):
		var raw: Variant = params["sample_every"]
		var text := str(raw).strip_edges()
		if not (raw is int or raw is float or text.is_valid_int()):
			return _fail(-32602, "sample_every must be a whole number of frames, got '%s'" % text)
		every = int(text.to_int() if raw is String else raw)
		if every < 1 or every > MAX_SAMPLE_EVERY:
			return _fail(-32602, "sample_every must be between 1 and %d frames, got %d" % [MAX_SAMPLE_EVERY, every])
	_reset()
	_session_name = _sanitize_name(str(params.get("name", "")))
	_sample_every = every
	_frames_until_sample = 0
	_started_unix = Time.get_unix_time_from_system()
	_started_usec = Time.get_ticks_usec()
	var scene := get_tree().current_scene
	_scene_path = scene.scene_file_path if scene != null else ""
	var viewport := get_viewport()
	var size := viewport.get_visible_rect().size if viewport != null else Vector2.ZERO
	_viewport_size = [int(size.x), int(size.y)]
	if error_log != null:
		_error_cursor = int(error_log.call("next_seq"))
	_recording = true
	return {
		"recording": true,
		"name": _session_name,
		"sample_every": _sample_every,
		"headless": _is_headless(),
		"display_server": DisplayServer.get_name(),
		"errors_capture": "on" if error_log != null else "unavailable",
		"limits": _limits(),
	}


func cmd_mark(params: Dictionary) -> Dictionary:
	if not _recording:
		return _not_recording()
	var label := str(params.get("label", "")).strip_edges()
	if label.is_empty():
		return _fail(-32602, "Missing required parameter: label")
	var mark := _record_mark(label, "cli")
	if mark.is_empty():
		return _fail(-32000, "The checkpoint limit (%d) is reached; this mark was not recorded" % MAX_MARKS)
	return {"marked": true, "label": mark["label"], "t_ms": mark["t_ms"], "frame": mark["frame"], "section": _marks.size()}


func cmd_event(params: Dictionary) -> Dictionary:
	if not _recording:
		return _not_recording()
	var event_name := str(params.get("name", "")).strip_edges()
	if event_name.is_empty():
		return _fail(-32602, "Missing required parameter: name")
	var data: Variant = params.get("data", {})
	if data is String and not (data as String).strip_edges().is_empty():
		var parsed: Variant = JSON.parse_string(data)
		if not parsed is Dictionary:
			return _fail(-32602, "data must be a JSON object")
		data = parsed
	elif data is String:
		data = {}
	if not data is Dictionary:
		return _fail(-32602, "data must be a JSON object, got %s" % type_string(typeof(data)))
	if not record_event(event_name, data, "cli"):
		return _fail(-32000, "The event limit (%d) is reached; this event was not recorded" % MAX_EVENTS)
	var last: Dictionary = _events[_events.size() - 1]
	return {"recorded": true, "name": last["name"], "t_ms": last["t_ms"], "frame": last["frame"], "events": _events.size()}


func cmd_status(_params: Dictionary) -> Dictionary:
	if not _recording:
		return {"recording": false}
	var recent := _recent_frames()
	var latest: Variant = _samples[_samples.size() - 1] if not _samples.is_empty() else null
	return {
		"recording": true,
		"name": _session_name,
		"elapsed_ms": _now_ms(),
		"frames": _frame_ms.size(),
		"samples": _samples.size(),
		"events": _events.size(),
		"inputs": _inputs.size(),
		"marks": _marks.size(),
		"errors": _errors.size(),
		"section": String(_marks[_marks.size() - 1]["label"]) if not _marks.is_empty() else "(start)",
		"fps": Engine.get_frames_per_second(),
		"recent_frames": recent,
		"latest_sample": latest,
		"truncated": not _dropped.is_empty(),
		"dropped": _dropped.duplicate(),
	}


func cmd_stop(_params: Dictionary) -> Dictionary:
	if not _recording:
		return _not_recording()
	return _finish("stop")


# --- Public game-side hooks ---------------------------------------------------

## Record a game event. The one call game code makes (through
## MCPGameInspector.playtest_event). Returns false and does nothing when no
## session is recording or the event cap is reached, so game code can call it
## unconditionally.
func record_event(event_name: String, data: Variant, source: String) -> bool:
	if not _recording:
		return false
	if _events.size() >= MAX_EVENTS:
		_drop("events")
		return false
	var payload: Variant = data
	if payload == null:
		payload = {}
	elif not payload is Dictionary:
		payload = {"value": payload}
	payload = PropertyParser.serialize_value(payload)
	var size := JSON.stringify(payload).length()
	if size > MAX_EVENT_DATA_BYTES:
		payload = {"_truncated": true, "_bytes": size}
		_drop("event_data")
	var entry := _stamp({"name": event_name.left(MAX_TEXT), "source": source})
	entry["data"] = payload
	_events.append(entry)
	return true


## Record a checkpoint from game code (MCPGameInspector.playtest_mark).
func record_mark(label: String) -> bool:
	if not _recording or label.strip_edges().is_empty():
		return false
	return not _record_mark(label.strip_edges(), "game").is_empty()


## Called by MCPGameInput for every event an input.* command injects, on either
## transport. Real player input is not recorded: the session describes what the
## agent did.
func record_input(data: Dictionary) -> void:
	if not _recording:
		return
	if _inputs.size() >= MAX_INPUTS:
		_drop("inputs")
		return
	var entry := _stamp({"type": str(data.get("type", ""))})
	for key in ["keycode", "action", "button", "pressed", "strength", "position", "relative", "double_click"]:
		if data.has(key):
			entry[key] = PropertyParser.serialize_value(data[key])
	_inputs.append(entry)


# --- Per frame ----------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _recording:
		return
	var now := Time.get_ticks_usec()
	if _first_frame < 0:
		# The first tick only anchors the clock: the gap since start() is part of
		# a frame, not a whole one.
		_first_frame = Engine.get_process_frames()
		_first_tick_ms = float(now - _started_usec) / 1000.0
		_last_usec = now
		_take_sample(false)
		_frames_until_sample = _sample_every
		return
	var ms := float(now - _last_usec) / 1000.0
	_last_usec = now
	if _frame_ms.size() < MAX_FRAMES:
		_frame_ms.append(snappedf(ms, 0.001))
	else:
		_drop("frames")
	var spike := _ema_ms > 0.0 and ms > maxf(_ema_ms * SPIKE_FACTOR, _ema_ms + SPIKE_MIN_EXCESS_MS)
	_ema_ms = ms if _ema_ms <= 0.0 else lerpf(_ema_ms, ms, 0.05)
	_frames_until_sample -= 1
	if spike:
		_take_sample(true)
	elif _frames_until_sample <= 0:
		_take_sample(false)
	if _frames_until_sample <= 0:
		_frames_until_sample = _sample_every
	_poll_errors()


func _take_sample(spike: bool) -> void:
	if _samples.size() >= MAX_SAMPLES:
		_drop("samples")
		return
	var s := _stamp({})
	s["fps"] = Performance.get_monitor(Performance.TIME_FPS)
	s["process_ms"] = snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.001)
	s["physics_ms"] = snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.001)
	s["static_mem"] = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	s["video_mem"] = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	s["texture_mem"] = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	s["objects"] = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	s["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	s["orphans"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	s["draw_calls"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	s["primitives"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	if spike:
		s["spike"] = true
		s["frame_ms"] = _frame_ms[_frame_ms.size() - 1] if not _frame_ms.is_empty() else 0.0
	_samples.append(s)


## Pull errors the logger captured since the last frame and timestamp them now.
## The logger's ring buffer holds 200 entries; a gap in seq means a burst
## overflowed it inside one frame, and that loss is counted, not hidden.
func _poll_errors() -> void:
	if error_log == null:
		return
	if int(error_log.call("next_seq")) <= _error_cursor:
		return
	var got: Dictionary = error_log.call("poll", _error_cursor, false)
	for e: Dictionary in got.get("errors", []):
		var seq := int(e.get("seq", 0))
		if seq > _error_cursor:
			_drop("errors", seq - _error_cursor)
		_error_cursor = seq + 1
		if _errors.size() >= MAX_ERRORS:
			_drop("errors")
			continue
		var entry := _stamp({})
		for key in ["kind", "message", "file", "line", "function", "backtrace"]:
			entry[key] = e.get(key)
		_errors.append(entry)
	_error_cursor = maxi(_error_cursor, int(got.get("next_seq", _error_cursor)))


# --- Finishing ----------------------------------------------------------------

func _finish(ended_by: String) -> Dictionary:
	_poll_errors()
	_recording = false
	var session := _build_session(ended_by)
	var written := _write(session)
	var summary := _summary(session)
	if written.has("error"):
		summary["write_error"] = written["error"]
		_reset()
		return _fail(-32603, "The session could not be written: %s" % written["error"], summary)
	summary["path"] = written["path"]
	summary["absolute_path"] = written["absolute_path"]
	summary["next"] = "swallowtail playtest report --latest"
	_reset()
	return summary


func _build_session(ended_by: String) -> Dictionary:
	return {
		"schema": SCHEMA,
		"kind": KIND,
		"name": _session_name,
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"engine_version": str(Engine.get_version_info().get("string", "")),
		"display_server": DisplayServer.get_name(),
		"headless": _is_headless(),
		"debug_build": OS.is_debug_build(),
		"os": OS.get_name(),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"adapter": RenderingServer.get_video_adapter_name(),
		"vsync_mode": DisplayServer.window_get_vsync_mode() if not _is_headless() else -1,
		"max_fps": Engine.max_fps,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"time_scale": Engine.time_scale,
		"viewport_size": _viewport_size,
		"scene": _scene_path,
		"started_unix": _started_unix,
		"stopped_unix": Time.get_unix_time_from_system(),
		"duration_ms": _now_ms(),
		"ended_by": ended_by,
		"sample_every": _sample_every,
		"frames": {
			"first_frame": _first_frame,
			"first_tick_ms": snappedf(_first_tick_ms, 0.001),
			"count": _frame_ms.size(),
			"times_ms": _frame_ms,
		},
		"samples": _samples,
		"marks": _marks,
		"events": _events,
		"inputs": _inputs,
		"errors": _errors,
		"errors_capture": "on" if error_log != null else "unavailable",
		"truncated": not _dropped.is_empty(),
		"dropped": _dropped.duplicate(),
		"limits": _limits(),
	}


## Write the session under user://swallowtail-playtests/, published by rename so a
## reader polling the folder never opens a half-written file. The name is built
## here from a timestamp and the sanitized session name, so no caller-supplied
## text ever reaches the path.
func _write(session: Dictionary) -> Dictionary:
	var dir_abs := ProjectSettings.globalize_path(SESSIONS_DIR)
	if DirAccess.make_dir_recursive_absolute(dir_abs) != OK and not DirAccess.dir_exists_absolute(dir_abs):
		return {"error": "cannot create %s" % dir_abs}
	var stamp := _timestamp()
	var file_name := "%s_%s.json" % [stamp, _session_name]
	var n := 2
	while FileAccess.file_exists(SESSIONS_DIR.path_join(file_name)):
		file_name = "%s_%s-%d.json" % [stamp, _session_name, n]
		n += 1
	var path := SESSIONS_DIR.path_join(file_name)
	var part := path + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		return {"error": "cannot open %s (%s)" % [part, error_string(FileAccess.get_open_error())]}
	f.store_string(JSON.stringify(session))
	f.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(part), ProjectSettings.globalize_path(path)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
		return {"error": "cannot rename %s into place" % part}
	return {"path": path, "absolute_path": ProjectSettings.globalize_path(path)}


func _summary(session: Dictionary) -> Dictionary:
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for ms in sorted:
		total += ms
	var frames := {"count": count}
	if count > 0:
		frames["avg_fps"] = snappedf(1000.0 * count / total, 0.01) if total > 0.0 else 0.0
		frames["p50_ms"] = _nearest_rank(sorted, 0.50)
		frames["p95_ms"] = _nearest_rank(sorted, 0.95)
		frames["p99_ms"] = _nearest_rank(sorted, 0.99)
		frames["max_ms"] = sorted[count - 1]
	return {
		"stopped": true,
		"name": session["name"],
		"duration_ms": session["duration_ms"],
		"ended_by": session["ended_by"],
		"headless": session["headless"],
		"frames": frames,
		"samples": _samples.size(),
		"events": _events.size(),
		"inputs": _inputs.size(),
		"marks": _marks.size(),
		"errors": _errors.size(),
		"truncated": session["truncated"],
		"dropped": session["dropped"],
	}


# --- Lifecycle ----------------------------------------------------------------

## A game that quits itself (a game-over screen calling get_tree().quit(), the
## window's close button) still gets its session written. An editor-stopped game
## is killed outright and never reaches this, which is why playtest.stop comes
## before scene.stop.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _recording:
		_finish("game_exit")


func _exit_tree() -> void:
	if _recording:
		_finish("game_exit")


# --- Helpers ------------------------------------------------------------------

func _record_mark(label: String, source: String) -> Dictionary:
	if _marks.size() >= MAX_MARKS:
		_drop("marks")
		return {}
	var mark := _stamp({"label": label.left(MAX_TEXT), "source": source})
	_marks.append(mark)
	return mark


func _stamp(entry: Dictionary) -> Dictionary:
	entry["t_ms"] = snappedf(_now_ms(), 0.001)
	entry["frame"] = Engine.get_process_frames()
	return entry


func _now_ms() -> float:
	return float(Time.get_ticks_usec() - _started_usec) / 1000.0


func _recent_frames() -> Dictionary:
	var n := mini(RECENT_FRAMES, _frame_ms.size())
	if n == 0:
		return {"count": 0}
	var total := 0.0
	var worst := 0.0
	for i in range(_frame_ms.size() - n, _frame_ms.size()):
		total += _frame_ms[i]
		worst = maxf(worst, _frame_ms[i])
	return {"count": n, "avg_ms": snappedf(total / n, 0.001), "max_ms": worst}


func _nearest_rank(sorted: PackedFloat64Array, q: float) -> float:
	var idx := clampi(ceili(q * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[idx]


func _drop(part: String, count: int = 1) -> void:
	_dropped[part] = int(_dropped.get(part, 0)) + count


func _limits() -> Dictionary:
	return {
		"frames": MAX_FRAMES, "samples": MAX_SAMPLES, "events": MAX_EVENTS,
		"inputs": MAX_INPUTS, "marks": MAX_MARKS, "errors": MAX_ERRORS,
		"event_data_bytes": MAX_EVENT_DATA_BYTES,
	}


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _reset() -> void:
	_recording = false
	_session_name = ""
	_first_frame = -1
	_first_tick_ms = 0.0
	_last_usec = 0
	_ema_ms = 0.0
	_frame_ms = PackedFloat64Array()
	_samples = []
	_events = []
	_inputs = []
	_marks = []
	_errors = []
	_dropped = {}


## Letters, digits, '-' and '_' only, at most 48 characters. The session name ends
## up in a file name, so anything else (separators, dots, a drive colon) becomes
## '-' and an empty result falls back to "session".
func _sanitize_name(raw: String) -> String:
	var re := RegEx.create_from_string("[^A-Za-z0-9_-]+")
	var clean := re.sub(raw.strip_edges(), "-", true).lstrip("-").rstrip("-").left(48)
	return clean if not clean.is_empty() else "session"


func _timestamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]


func _fail(code: int, message: String, data: Dictionary = {}) -> Dictionary:
	var out := {"error": message, "error_code": code}
	if not data.is_empty():
		out["error_data"] = data
	return out


func _not_recording() -> Dictionary:
	return _fail(-32000, "No playtest session is recording", {"suggestion": "Start one with playtest.start."})
