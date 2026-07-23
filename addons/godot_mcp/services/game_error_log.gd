extends Logger

## Captures runtime errors/warnings from the RUNNING game into a bounded ring
## buffer, polled by runtime.errors over the game IPC. MCPGameInspector registers
## one of these via OS.add_logger in _ready(). Only errors/warnings flow through
## _log_error (regular prints are ignored, so overhead is negligible). The
## callback is airtight: it never logs and guards against re-entrancy, so an error
## storm can't recurse through the logger or destabilize the game.

const MAX_ENTRIES := 200

var _entries: Array = []   # ring buffer of error dicts, each tagged with a seq
var _seq: int = 0          # monotonic id handed to each entry; the poll cursor
var _in_log: bool = false  # re-entrancy guard


func _log_error(function, file, line, code, rationale, editor_notify, error_type, script_backtraces) -> void:
	if _in_log:
		return
	_in_log = true
	var frames: Array = []
	if script_backtraces is Array:
		for bt in script_backtraces:
			if bt != null:
				for i in bt.get_frame_count():
					frames.append({
						"function": str(bt.get_frame_function(i)),
						"file": str(bt.get_frame_file(i)),
						"line": int(bt.get_frame_line(i)),
					})
	# Godot splits the text across two params: real engine errors put the human
	# description in `rationale` and the failed condition in `code`; push_error
	# puts its text in `code` with `rationale` empty. Prefer rationale, fall back
	# to code, so `message` is always populated. For built-ins (push_error) the
	# reported file/line/function is engine C++ internals — the real game-script
	# location is backtrace[0].
	var rat := str(rationale)
	var cod := str(code)
	_entries.append({
		"seq": _seq,
		"kind": _kind(int(error_type)),
		"message": rat if not rat.is_empty() else cod,
		"code": cod,
		"function": str(function),
		"file": str(file),
		"line": int(line),
		"backtrace": frames,
	})
	_seq += 1
	while _entries.size() > MAX_ENTRIES:
		_entries.pop_front()
	_in_log = false


func _log_message(message, error) -> void:
	pass  # errors arrive via _log_error; regular messages are not buffered


func _kind(t: int) -> String:
	match t:
		Logger.ERROR_TYPE_WARNING: return "warning"
		Logger.ERROR_TYPE_SCRIPT: return "script"
		Logger.ERROR_TYPE_SHADER: return "shader"
		_: return "error"


## Return buffered entries with seq >= since_seq. next_seq is the cursor to pass
## on the following poll for incremental reads. clear empties the buffer after.
func poll(since_seq: int, clear: bool) -> Dictionary:
	var out: Array = []
	for e in _entries:
		if int(e["seq"]) >= since_seq:
			out.append(e)
	var next_seq := _seq
	if clear:
		_entries.clear()
	return {"errors": out, "count": out.size(), "next_seq": next_seq, "buffered": _entries.size()}
