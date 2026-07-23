extends Node

## Slim WebSocket JSON-RPC server hosted INSIDE the running game (NOT @tool). It
## is the direct channel: the godot-mcp CLI dials it with --game and drives
## runtime.*/input.* with no editor in the loop, so a standalone game (one not
## launched from an editor) is reachable.
##
## Created and started by MCPGameInspector._ready(), only in a debug build with
## the godot_mcp/runtime/direct_server setting on — impossible in a release export.
##
## Wire contract is identical to the editor addon (websocket_server.gd): JSON-RPC
## 2.0 over WebSocket text frames, same error codes, 127.0.0.1 ONLY (invariant).
## Instead of routing to the editor command router, it maps runtime.<cmd> to the
## inspector's shared dispatch (run_command) and injects input.<cmd> through the
## MCPGameInput autoload — reusing the exact game-side handlers, not copies.

const DEFAULT_PORT := 9200
const PORT_RANGE := 16                        # scan DEFAULT_PORT .. DEFAULT_PORT+PORT_RANGE-1 (9200-9215)
const BIND_ADDRESS := "127.0.0.1"
const INBOUND_BUFFER := 1 * 1024 * 1024       # 1MB — requests are small JSON
const OUTBOUND_BUFFER := 16 * 1024 * 1024     # 16MB — responses can be large (screenshots)
const MAX_PEERS := 8
const CONNECT_TIMEOUT := 5.0
const IDLE_TIMEOUT := 120.0
const RESUME_GAP_MS := 15000                  # frame gap this large => host slept/suspended
const DISCOVERY_PATH := "user://godot-mcp-game.json"

## Wire runtime.<cmd> -> the MCPGameInspector game-side command name it maps to.
## The editor's runtime_commands.gd performs the same mapping when brokering over
## file IPC; the game handlers read the same param keys the CLI sends, so params
## pass straight through (each handler does its own validation/defaults).
const RUNTIME_MAP := {
	"runtime.tree": "get_scene_tree",
	"runtime.get": "get_node_properties",
	"runtime.set": "set_node_property",
	"runtime.eval": "execute_script",
	"runtime.screenshot": "screenshot",
	"runtime.capture_frames": "capture_frames",
	"runtime.monitor": "monitor_properties",
	"runtime.start_recording": "start_recording",
	"runtime.stop_recording": "stop_recording",
	"runtime.replay": "replay_recording",
	"runtime.find_by_script": "find_nodes_by_script",
	"runtime.autoload": "get_autoload",
	"runtime.batch_get": "batch_get_properties",
	"runtime.find_ui": "find_ui_elements",
	"runtime.click_text": "click_button_by_text",
	"runtime.wait_for": "wait_for_node",
	"runtime.find_nearby": "find_nearby_nodes",
	"runtime.navigate": "navigate_to",
	"runtime.move_to": "move_to",
	"runtime.watch_signals": "watch_signals",
	"runtime.await_signal": "await_signal",
	"runtime.errors": "get_runtime_errors",
}

const INPUT_METHODS := [
	"input.key", "input.tap", "input.click", "input.move", "input.action", "input.sequence",
]

var inspector: Node  # MCPGameInspector, set by the parent before start()

var _tcp := TCPServer.new()
var _peers: Array = []  # each: {"ws": WebSocketPeer, "age": float, "idle": float}
var _port: int = DEFAULT_PORT
var _running := false
var _stopped := false
var _last_tick := 0

# runtime.* commands share the inspector's single response sink, so serialize
# them: queue requests and submit the next only when the current has responded.
var _queue: Array = []   # each: {"ws": WebSocketPeer, "id": Variant, "cmd": String, "params": Dictionary}
var _in_flight := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep serving even if the game is paused


func start() -> void:
	# A crash leaves a stale discovery file; clear it up front, but never a live
	# sibling instance's file (pid still running).
	_clear_stale_discovery()
	for port in _candidate_ports():
		if _tcp.listen(port, BIND_ADDRESS) == OK:
			_port = port
			_running = true
			_write_discovery()
			print("[MCP Game] Direct server listening on ws://%s:%d" % [BIND_ADDRESS, _port])
			return
	push_error("[MCP Game] No free port in %d-%d for the direct server" % [DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE - 1])


## Port precedence: GODOT_MCP_GAME_PORT env pins a single port (wins); else scan
## the 9200-9215 range so multiple game instances each grab a free one.
func _candidate_ports() -> Array:
	var env := OS.get_environment("GODOT_MCP_GAME_PORT")
	if not env.is_empty() and env.is_valid_int():
		return [env.to_int()]
	var ports: Array = []
	for p in range(DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE):
		ports.append(p)
	return ports


func stop() -> void:
	if _stopped:
		return
	_stopped = true
	_running = false
	for p in _peers:
		(p["ws"] as WebSocketPeer).close(1000, "Game shutting down")
	_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	_remove_discovery()
	print("[MCP Game] Direct server stopped")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if not _running:
		return

	# Sleep/resume guard (mirrors websocket_server.gd): a large wall-clock gap
	# between frames means the OS suspended us and may have invalidated the socket;
	# rebuild the listener on a fresh socket instead of polling a stale handle.
	var now := Time.get_ticks_msec()
	if _last_tick != 0 and (now - _last_tick > RESUME_GAP_MS or delta > float(RESUME_GAP_MS) / 1000.0):
		_last_tick = now
		_relisten()
		return
	_last_tick = now

	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		if _peers.size() >= MAX_PEERS:
			if conn:
				conn.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = INBOUND_BUFFER
		ws.outbound_buffer_size = OUTBOUND_BUFFER
		if ws.accept_stream(conn) == OK:
			_peers.append({"ws": ws, "age": 0.0, "idle": 0.0})

	var still_open: Array = []
	for p in _peers:
		var ws: WebSocketPeer = p["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		p["age"] += delta
		p["idle"] += delta
		var keep := false
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				_handle_message(ws, ws.get_packet().get_string_from_utf8())
				p["idle"] = 0.0
			if p["idle"] > IDLE_TIMEOUT:
				ws.close(4000, "Idle timeout")
			else:
				keep = true
		elif state == WebSocketPeer.STATE_CONNECTING:
			keep = p["age"] <= CONNECT_TIMEOUT
		if keep:
			still_open.append(p)
	_peers = still_open

	# Drive the serialized runtime queue (also retries if the inspector was busy
	# with a file-IPC command in an editor-launched game).
	_pump_queue()


func _relisten() -> void:
	for p in _peers:
		(p["ws"] as WebSocketPeer).close(1001, "Server resuming")
	_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	var ports: Array = [_port]
	for c in _candidate_ports():
		if c != _port:
			ports.append(c)
	for port in ports:
		if _tcp.listen(port, BIND_ADDRESS) == OK:
			_port = port
			_write_discovery()
			print("[MCP Game] Listener rebuilt on ws://%s:%d" % [BIND_ADDRESS, _port])
			return
	_running = false
	push_error("[MCP Game] Could not rebind after resume — direct server stopped")


# --- Dispatch ---------------------------------------------------------------

func _handle_message(ws: WebSocketPeer, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		_send(ws, null, null, {"code": -32700, "message": "Parse error"})
		return
	var msg: Variant = json.data
	if not msg is Dictionary:
		_send(ws, null, null, {"code": -32600, "message": "Invalid request"})
		return

	var req: Dictionary = msg
	var method: String = req.get("method", "")
	# Heartbeat control frames carry no id; never surface them.
	if method == "ping" or method == "pong":
		return
	var id: Variant = req.get("id")
	var params: Dictionary = req.get("params", {})

	if method.is_empty():
		_send(ws, id, null, {"code": -32600, "message": "Missing method"})
		return

	if RUNTIME_MAP.has(method):
		_enqueue_runtime(ws, id, method, params)
	elif method in INPUT_METHODS:
		_handle_input(ws, id, method, params)
	else:
		_send(ws, id, null, {
			"code": -32601,
			"message": "Method not found: %s" % method,
			"data": {"available_methods": _available_methods()},
		})


func _available_methods() -> Array:
	var out: Array = RUNTIME_MAP.keys()
	out.append_array(INPUT_METHODS)
	out.sort()
	return out


# --- runtime.* (serialized through the inspector's shared dispatch) ----------

func _enqueue_runtime(ws: WebSocketPeer, id: Variant, method: String, params: Dictionary) -> void:
	if inspector == null or not inspector.has_method("run_command"):
		_send(ws, id, null, {"code": -32603, "message": "Game inspector unavailable"})
		return
	# Audit ad-hoc code execution before it runs (invariant #3), mirroring
	# base_command.audit_exec on the editor side.
	if method == "runtime.eval":
		var code: String = params.get("code", "")
		print("[godot-mcp-game] runtime.eval executing (%d bytes):\n%s\n[godot-mcp-game] --- end runtime.eval ---" % [code.length(), code])
	_queue.append({"ws": ws, "id": id, "cmd": RUNTIME_MAP[method], "params": params})
	_pump_queue()


func _pump_queue() -> void:
	if _in_flight or _queue.is_empty():
		return
	# In an editor-launched game both channels are live; wait if the inspector is
	# mid-command for the file-IPC path (retried next frame from _process).
	if inspector == null or inspector.is_busy():
		return

	var job: Dictionary = _queue.pop_front()
	var ws: WebSocketPeer = job["ws"]
	var id: Variant = job["id"]
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_pump_queue()  # peer gone before we got to it — skip and try the next
		return

	_in_flight = true
	var sink := func(result: Dictionary) -> void:
		_in_flight = false
		_deliver_runtime(ws, id, result)
		_pump_queue()
	inspector.run_command(job["cmd"], job["params"], sink)


## Translate a game-side result dict into a JSON-RPC response, matching how the
## editor's runtime_commands._send classifies it: a top-level "error" key is a
## failure (-32000), anything else is the success payload.
func _deliver_runtime(ws: WebSocketPeer, id: Variant, result: Dictionary) -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if result.has("error"):
		_send(ws, id, null, {"code": -32000, "message": str(result["error"])})
	else:
		_send(ws, id, result, null)


# --- input.* (injected directly through the MCPGameInput autoload) -----------

func _handle_input(ws: WebSocketPeer, id: Variant, method: String, params: Dictionary) -> void:
	var input_node := get_node_or_null("/root/MCPGameInput")
	if input_node == null or not input_node.has_method("inject_payload"):
		_send(ws, id, null, {"code": -32603, "message": "MCPGameInput autoload not available"})
		return
	var built := _build_input(method, params)
	if built.has("error"):
		_send(ws, id, null, built["error"])
		return
	input_node.inject_payload(built["payload"])
	_send(ws, id, built.get("result", {"sent": true}), null)


## Build the event payload for one input.<cmd> — the same shape input_commands.gd
## writes to the file-IPC channel, which MCPGameInput.inject_payload consumes.
## Returns {"payload": Variant, "result": Dictionary} or {"error": {...}}.
func _build_input(method: String, params: Dictionary) -> Dictionary:
	match method:
		"input.key": return _bi_key(params)
		"input.tap": return _bi_tap(params)
		"input.click": return _bi_click(params)
		"input.move": return _bi_move(params)
		"input.action": return _bi_action(params)
		"input.sequence": return _bi_sequence(params)
	return {"error": {"code": -32601, "message": "Method not found: %s" % method}}


func _bi_key(params: Dictionary) -> Dictionary:
	var kc: String = str(params.get("keycode", ""))
	if kc.is_empty():
		return _input_param_error("keycode")
	var event := _key_dict(params, kc)
	event["pressed"] = _bool(params, "pressed", true)
	return {"payload": [event], "result": {"sent": true, "event": event}}


func _bi_tap(params: Dictionary) -> Dictionary:
	var kc: String = str(params.get("keycode", ""))
	if kc.is_empty():
		return _input_param_error("keycode")
	var press := _key_dict(params, kc)
	press["pressed"] = true
	var release := _key_dict(params, kc)
	release["pressed"] = false
	var payload := {"sequence_events": [press, release], "frame_delay": _int(params, "frame_delay", 1)}
	return {"payload": payload, "result": {"sent": true, "keycode": kc, "tapped": true}}


func _bi_click(params: Dictionary) -> Dictionary:
	var press := {
		"type": "mouse_button",
		"button": _int(params, "button", MOUSE_BUTTON_LEFT),
		"pressed": _bool(params, "pressed", true),
		"double_click": _bool(params, "double_click", false),
		"position": {"x": float(params.get("x", 0)), "y": float(params.get("y", 0))},
	}
	# UI buttons fire on release, so a press defaults to press+release.
	if press["pressed"] and _bool(params, "auto_release", true):
		var release: Dictionary = press.duplicate()
		release["pressed"] = false
		var payload := {"sequence_events": [press, release], "frame_delay": 1}
		return {"payload": payload, "result": {"sent": true, "event": press, "auto_release": true}}
	return {"payload": [press], "result": {"sent": true, "event": press}}


func _bi_move(params: Dictionary) -> Dictionary:
	var event := {
		"type": "mouse_motion",
		"position": {"x": float(params.get("x", 0)), "y": float(params.get("y", 0))},
		"relative": {"x": float(params.get("relative_x", 0)), "y": float(params.get("relative_y", 0))},
		"button_mask": _int(params, "button_mask", 0),
	}
	if params.has("unhandled"):
		event["unhandled"] = _bool(params, "unhandled", false)
	return {"payload": [event], "result": {"sent": true, "event": event}}


func _bi_action(params: Dictionary) -> Dictionary:
	var action: String = str(params.get("action", ""))
	if action.is_empty():
		return _input_param_error("action")
	var event := {
		"type": "action",
		"action": action,
		"pressed": _bool(params, "pressed", true),
		"strength": float(params.get("strength", 1.0)),
	}
	return {"payload": [event], "result": {"sent": true, "event": event}}


func _bi_sequence(params: Dictionary) -> Dictionary:
	if not params.has("events") or not params["events"] is Array:
		return {"error": {"code": -32602, "message": "'events' array is required"}}
	var events: Array = params["events"]
	if events.is_empty():
		return {"error": {"code": -32602, "message": "'events' array is empty"}}
	for e in events:
		if not e is Dictionary or not (e as Dictionary).has("type"):
			return {"error": {"code": -32602, "message": "Each event needs a 'type'"}}
	var frame_delay := _int(params, "frame_delay", 1)
	var payload: Variant
	if frame_delay <= 0:
		payload = events  # all in one frame
	else:
		payload = {"sequence_events": events, "frame_delay": frame_delay}
	return {"payload": payload, "result": {"sent": true, "event_count": events.size(), "frame_delay": frame_delay}}


func _key_dict(params: Dictionary, keycode: String) -> Dictionary:
	return {
		"type": "key",
		"keycode": keycode,
		"shift": _bool(params, "shift", false),
		"ctrl": _bool(params, "ctrl", false),
		"alt": _bool(params, "alt", false),
	}


func _input_param_error(key: String) -> Dictionary:
	return {"error": {"code": -32602, "message": "Missing required parameter: %s" % key}}


func _bool(params: Dictionary, key: String, default: bool) -> bool:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is bool:
		return v
	if v is String:
		return (v as String).to_lower() in ["true", "1", "yes"]
	return bool(v)


func _int(params: Dictionary, key: String, default: int) -> int:
	if params.has(key):
		return int(params[key])
	return default


# --- Wire ------------------------------------------------------------------

func _send(ws: WebSocketPeer, id: Variant, result: Variant, err: Variant) -> void:
	var resp: Dictionary = {"jsonrpc": "2.0", "id": id}
	if err != null:
		resp["error"] = err
	else:
		resp["result"] = result if result != null else {}
	ws.send_text(JSON.stringify(resp))
	# Flush now so a response to `runtime.eval get_tree().quit()` reaches the client
	# before the process tears the socket down at end of frame.
	ws.poll()


# --- Discovery file ---------------------------------------------------------

func _write_discovery() -> void:
	var info := {
		"port": _port,
		"pid": OS.get_process_id(),
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"started_unix": int(Time.get_unix_time_from_system()),
	}
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(info))
		f.close()


## Remove our own discovery file on clean shutdown. Guard on pid so we never
## delete a sibling game instance's live file (same project shares user://).
func _remove_discovery() -> void:
	if not FileAccess.file_exists(DISCOVERY_PATH):
		return
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary and int((data as Dictionary).get("pid", 0)) != OS.get_process_id():
		return  # not ours — leave it
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DISCOVERY_PATH))


## On start, drop a leftover discovery file unless its recorded pid is still
## running (a live sibling instance). Junk/unparseable files are treated as stale.
func _clear_stale_discovery() -> void:
	if not FileAccess.file_exists(DISCOVERY_PATH):
		return
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary and OS.has_method("is_process_running"):
		var pid := int((data as Dictionary).get("pid", 0))
		if pid > 0 and OS.is_process_running(pid):
			return  # a live instance owns it
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DISCOVERY_PATH))
