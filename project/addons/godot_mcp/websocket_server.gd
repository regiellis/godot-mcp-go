@tool
extends Node

## WebSocket server hosted inside the editor. Listens on 127.0.0.1:<port>,
## accepts multiple concurrent clients, and dispatches JSON-RPC 2.0 requests
## to the command router. Godot 4 has no high-level WS server, so we drive a
## TCPServer and wrap each accepted stream in a WebSocketPeer.

var command_router: Node
## The sibling HTTP endpoint (mcp_http_server.gd), set by the plugin. We stamp its
## bound port into the shared discovery file so a CLI/client can find both
## transports from one file. Null when the HTTP endpoint is disabled ⇒ http_port 0.
var http_server: Node = null

const DEFAULT_PORT := 9080
const PORT_RANGE := 16        # scan DEFAULT_PORT .. DEFAULT_PORT+PORT_RANGE-1
const BIND_ADDRESS := "127.0.0.1"
const INBOUND_BUFFER := 1 * 1024 * 1024     # 1MB — requests are small JSON
const OUTBOUND_BUFFER := 16 * 1024 * 1024   # 16MB — responses can be large (screenshots)
const MAX_PEERS := 16                        # cap concurrent clients to bound memory
const CONNECT_TIMEOUT := 5.0                 # drop peers stuck mid-handshake
const IDLE_TIMEOUT := 120.0                  # reap dead/half-open peers (longer than any command)
const RESUME_GAP_MS := 15000                 # frame gap this large ⇒ host slept/suspended
                                             # (well above any heavy synchronous command)
const DISCOVERY_PATH := "res://.godot/godot-mcp.json"

var _tcp := TCPServer.new()
var _peers: Array = []  # each: {"ws": WebSocketPeer, "age": float, "idle": float}
var _port: int = DEFAULT_PORT
var _running: bool = false
var _last_tick: int = 0


func start() -> void:
	# A crash leaves a stale discovery file behind (clean shutdown removes it), so
	# the CLI would read it as "crashed" until we bind. Clear it up front — but only
	# if its process is gone, never a live sibling instance's file.
	_clear_stale_discovery()
	# Bind the first free port in the range so multiple editor instances can run
	# at once (each writes its actual port to its own discovery file).
	for port in _candidate_ports():
		if _tcp.listen(port, BIND_ADDRESS) == OK:
			_port = port
			_running = true
			_write_discovery()
			print("[MCP] Server listening on ws://%s:%d" % [BIND_ADDRESS, _port])
			return
	push_error("[MCP] No free port in %d-%d for the MCP server" % [DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE - 1])


func stop() -> void:
	_running = false
	for p in _peers:
		(p["ws"] as WebSocketPeer).close(1000, "Editor shutting down")
	_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	_remove_discovery()
	print("[MCP] Server stopped")


## Drop all peers and the TCP listener, then bind a fresh socket. Called after a
## suspend/resume gap so we never poll an OS-invalidated socket handle. Prefers
## the same port, else the first free one in range.
func _relisten() -> void:
	push_warning("[MCP] Resume detected — rebuilding the WebSocket listener")
	for p in _peers:
		(p["ws"] as WebSocketPeer).close(1001, "Server resuming")
		if p["counted"] and command_router:
			command_router.note_connection(-1)
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
			print("[MCP] Listener rebuilt on ws://%s:%d" % [BIND_ADDRESS, _port])
			return
	_running = false
	push_error("[MCP] Could not rebind after resume — server stopped")


## Port precedence: GODOT_MCP_PORT env pins a single port (wins); else the
## per-project setting godot_mcp/network/port if > 0 (how concurrent projects get
## deterministic ports); else scan the range so instances each grab a free one.
func _candidate_ports() -> Array:
	var env := OS.get_environment("GODOT_MCP_PORT")
	if not env.is_empty() and env.is_valid_int():
		return [env.to_int()]
	var pinned := int(ProjectSettings.get_setting("godot_mcp/network/port", 0))
	if pinned > 0:
		return [pinned]
	var ports: Array = []
	for p in range(DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE):
		ports.append(p)
	return ports


func _process(delta: float) -> void:
	if not _running:
		return

	# Sleep/resume guard. The OS can invalidate the listening socket across a
	# suspend; polling a dead native socket handle every frame can take Godot
	# down in C++ with no GDScript trace (fits "crash on resume, no exit code").
	# A large wall-clock gap between frames means we just resumed — rebuild the
	# listener on fresh sockets instead of touching the stale one.
	var now := Time.get_ticks_msec()
	if _last_tick != 0 and (now - _last_tick > RESUME_GAP_MS or delta > float(RESUME_GAP_MS) / 1000.0):
		_last_tick = now
		_relisten()
		return
	_last_tick = now

	# Accept pending connections, up to the cap. Beyond it, take and discard so
	# the accept queue doesn't wedge (a flood can't grow memory without bound).
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
			_peers.append({"ws": ws, "age": 0.0, "idle": 0.0, "counted": false})

	# Poll each peer; read complete text frames and dispatch. Reap peers stuck
	# mid-handshake and dead/half-open peers (no traffic for IDLE_TIMEOUT) so a
	# Ctrl+C'd or killed client can't leak a 16MB peer forever.
	var still_open: Array = []
	for p in _peers:
		var ws: WebSocketPeer = p["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		p["age"] += delta
		p["idle"] += delta
		var keep := false
		if state == WebSocketPeer.STATE_OPEN:
			if not p["counted"]:
				p["counted"] = true
				if command_router:
					command_router.note_connection(1)
			while ws.get_available_packet_count() > 0:
				_dispatch(ws, ws.get_packet().get_string_from_utf8())
				p["idle"] = 0.0
			if p["idle"] > IDLE_TIMEOUT:
				ws.close(4000, "Idle timeout")
			else:
				keep = true
		elif state == WebSocketPeer.STATE_CONNECTING:
			keep = p["age"] <= CONNECT_TIMEOUT
		# STATE_CLOSING / STATE_CLOSED peers are dropped.
		if keep:
			still_open.append(p)
		elif p["counted"] and command_router:
			command_router.note_connection(-1)
	_peers = still_open


func _dispatch(ws: WebSocketPeer, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		_send(ws, null, null, {"code": -32700, "message": "Parse error"})
		return
	var msg: Variant = json.data
	if not msg is Dictionary:
		_send(ws, null, null, {"code": -32600, "message": "Invalid request"})
		return

	var req: Dictionary = msg
	var id: Variant = req.get("id")
	var method: String = req.get("method", "")
	var params: Dictionary = req.get("params", {})

	if method.is_empty():
		_send(ws, id, null, {"code": -32600, "message": "Missing method"})
		return
	if not command_router:
		_send(ws, id, null, {"code": -32603, "message": "No command router"})
		return

	_execute.call_deferred(ws, id, method, params)


func _execute(ws: WebSocketPeer, id: Variant, method: String, params: Dictionary) -> void:
	# The peer may have closed while the call was deferred.
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var result: Dictionary = await command_router.execute(method, params)
	# A command can span several frames; the client may have gone since.
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if result.has("error"):
		_send(ws, id, null, result["error"])
	else:
		_send(ws, id, result.get("result", {}), null)


func _send(ws: WebSocketPeer, id: Variant, result: Variant, err: Variant) -> void:
	var resp: Dictionary = {"jsonrpc": "2.0", "id": id}
	if err != null:
		resp["error"] = err
	else:
		resp["result"] = result if result != null else {}
	ws.send_text(JSON.stringify(resp))


## Rewrite the discovery file on demand (e.g. after the HTTP endpoint rebinds on
## resume and its port changed). No-op unless we're bound.
func rewrite_discovery() -> void:
	if _running:
		_write_discovery()


func _write_discovery() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot"))
	var info := {
		"port": _port,
		"http_port": (http_server.bound_port() if (http_server != null and http_server.has_method("bound_port")) else 0),
		"pid": OS.get_process_id(),
		"godot_version": "%s.%s.%s" % [
			Engine.get_version_info()["major"],
			Engine.get_version_info()["minor"],
			Engine.get_version_info()["patch"],
		],
		"project_path": ProjectSettings.globalize_path("res://"),
		"started_unix": int(Time.get_unix_time_from_system()),
	}
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(info))
		f.close()


func _remove_discovery() -> void:
	if FileAccess.file_exists(DISCOVERY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DISCOVERY_PATH))


## Remove a leftover discovery file unless its recorded pid is still running (a
## live sibling instance). Junk/unparseable files are treated as stale.
func _clear_stale_discovery() -> void:
	if not FileAccess.file_exists(DISCOVERY_PATH):
		return
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text)
	if data is Dictionary and data.has("pid") and OS.has_method("is_process_running"):
		var pid := int(data["pid"])
		if pid > 0 and OS.is_process_running(pid):
			return # a live instance owns it — leave it alone
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DISCOVERY_PATH))
