@tool
extends Node

## Streamable-HTTP MCP endpoint hosted inside the editor, a sibling transport to
## websocket_server.gd that reuses the SAME command router (so every guard —
## audit_exec, _guard_unsafe_io, guard_project_path — applies unchanged). An MCP
## client that speaks streamable HTTP (Claude Code with a `url` server entry, …)
## connects directly to the running editor with no external Go process.
##
## Godot 4 has no high-level HTTP server, so we drive a TCPServer, wrap each
## accepted stream in a StreamPeerTCP, and parse HTTP/1.1 by hand. 127.0.0.1 ONLY
## (a hard invariant — never 0.0.0.0). POST /mcp carries a JSON-RPC 2.0 body and
## we reply with a plain application/json response (no SSE in v1).

var command_router: Node
## Back-reference to the WebSocket server, the single writer of the shared
## discovery file. We ask it to rewrite the file after a resume-rebind so
## <project>/.godot/godot-mcp.json keeps an accurate http_port.
var ws_server: Node = null

const DEFAULT_PORT := 9100
const PORT_RANGE := 16                        # scan DEFAULT_PORT .. DEFAULT_PORT+PORT_RANGE-1 (9100-9115)
const BIND_ADDRESS := "127.0.0.1"
const MAX_BODY := 16 * 1024 * 1024            # cap a request body (matches the addon's 16MB buffers)
const MAX_PEERS := 16                          # cap concurrent clients to bound memory
const CONNECT_TIMEOUT := 5.0                    # drop peers stuck mid-connect
const IDLE_TIMEOUT := 120.0                     # reap dead/half-open peers (longer than any command)
const RESUME_GAP_MS := 15000                    # frame gap this large ⇒ host slept/suspended

const MCP_PATH := "/mcp"
const PORT_SETTING := "godot_mcp/network/http_port"
const TYPED_SETTING := "godot_mcp/network/http_typed"

## Streamable-HTTP MCP protocol versions we understand. We echo the client's if it
## is one of these, else fall back to our latest (the first entry).
const PROTOCOL_VERSIONS := ["2025-06-18", "2025-03-26"]
const LATEST_PROTOCOL := "2025-06-18"

## Short, always-present discover-then-drive + spatial-placement steer, surfaced to
## the client at initialize (MCP InitializeResult.instructions). The godot-mcp skill
## carries the detail; this is the durable minimum that rides along without it.
const INSTRUCTIONS := "This endpoint drives a running Godot editor (4.7+) through the godot-mcp addon. " + \
	"Each typed tool is a <group>_<command> method with dots turned to underscores; the generic godot_run tool reaches any method by its dotted name. " + \
	"Discover before you act — your training may predate this build, so confirm a class, property, or method against it with engine_search or engine_class_info instead of guessing; engine_commands lists every method. " + \
	"Placing 3D objects: anchor one piece, read its REAL world bounds back (node_get global_position, or get_aabb via global_transform), then derive neighbours from that — a node's position is LOCAL to its parent, so span objects via global_transform. " + \
	"Seat things on surfaces with a downward raycast and face with look_at rather than hand-computing heights or Euler angles; verify by reading positions back, not by trusting one screenshot. " + \
	"Godot is +Y up, -Z forward, right-handed, meters. Editor edits are undoable; runtime_* and input_* need a scene playing (scene_play)."

var _tcp := TCPServer.new()
var _conns: Array = []  # each: {peer, buf: PackedByteArray, idle: float, busy: bool, dead: bool}
var _port: int = 0
var _running: bool = false
var _last_tick: int = 0

# Typed-tool cache, built once from the router's live param docs (the router is
# stable after registration). The http_typed toggle is applied per tools/list.
var _typed_tools: Array = []
var _name_to_method: Dictionary = {}  # typed tool name -> dotted method
var _typed_built: bool = false
var _version_cache: String = ""


func start() -> void:
	for port in _candidate_ports():
		if _tcp.listen(port, BIND_ADDRESS) == OK:
			_port = port
			_running = true
			print("[MCP-HTTP] MCP endpoint listening on http://%s:%d%s" % [BIND_ADDRESS, _port, MCP_PATH])
			return
	push_error("[MCP-HTTP] No free port in %d-%d for the MCP HTTP endpoint" % [DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE - 1])


func stop() -> void:
	_running = false
	for conn in _conns:
		(conn["peer"] as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	if _tcp.is_listening():
		_tcp.stop()
	print("[MCP-HTTP] MCP endpoint stopped")


## The bound port, or 0 when not listening. The WebSocket server reads this to
## stamp http_port into the shared discovery file.
func bound_port() -> int:
	return _port if _running else 0


## Port precedence, mirroring the WebSocket server: GODOT_MCP_HTTP_PORT env pins a
## single port (wins); else the per-project setting godot_mcp/network/http_port if
## > 0; else scan the auto range so instances each grab a free one.
func _candidate_ports() -> Array:
	var env := OS.get_environment("GODOT_MCP_HTTP_PORT")
	if not env.is_empty() and env.is_valid_int():
		return [env.to_int()]
	var pinned := int(ProjectSettings.get_setting(PORT_SETTING, 0))
	if pinned > 0:
		return [pinned]
	var ports: Array = []
	for p in range(DEFAULT_PORT, DEFAULT_PORT + PORT_RANGE):
		ports.append(p)
	return ports


## Drop all peers and the TCP listener, then bind a fresh socket. Mirrors the WS
## server's resume guard: polling an OS-invalidated socket handle across a
## suspend/resume can take Godot down in C++ with no GDScript trace.
func _relisten() -> void:
	push_warning("[MCP-HTTP] Resume detected — rebuilding the HTTP listener")
	for conn in _conns:
		(conn["peer"] as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	if _tcp.is_listening():
		_tcp.stop()
	var ports: Array = [_port]
	for c in _candidate_ports():
		if c != _port:
			ports.append(c)
	for port in ports:
		if _tcp.listen(port, BIND_ADDRESS) == OK:
			_port = port
			print("[MCP-HTTP] Listener rebuilt on http://%s:%d%s" % [BIND_ADDRESS, _port, MCP_PATH])
			# The port may have changed — refresh the shared discovery file.
			if ws_server != null and ws_server.has_method("rewrite_discovery"):
				ws_server.rewrite_discovery()
			return
	_running = false
	push_error("[MCP-HTTP] Could not rebind after resume — HTTP endpoint stopped")


func _process(delta: float) -> void:
	if not _running:
		return

	# Sleep/resume guard (see _relisten). A large wall-clock gap between frames
	# means we just resumed — rebuild the listener on fresh sockets.
	var now := Time.get_ticks_msec()
	if _last_tick != 0 and (now - _last_tick > RESUME_GAP_MS or delta > float(RESUME_GAP_MS) / 1000.0):
		_last_tick = now
		_relisten()
		return
	_last_tick = now

	# Accept pending connections up to the cap; beyond it, take and drop so the
	# accept queue can't wedge.
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if peer == null:
			continue
		if _conns.size() >= MAX_PEERS:
			peer.disconnect_from_host()
			continue
		_conns.append({"peer": peer, "buf": PackedByteArray(), "idle": 0.0, "age": 0.0, "busy": false, "dead": false, "connected": false})

	var still: Array = []
	for conn in _conns:
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()
		var status := peer.get_status()
		conn["age"] += delta
		conn["idle"] += delta

		if status == StreamPeerTCP.STATUS_CONNECTED:
			conn["connected"] = true
			# Read whatever bytes are available (non-blocking). PackedByteArray is
			# copy-on-write, so read-modify-WRITE the stored buffer, never mutate a
			# cast temporary (which would silently drop the appended bytes).
			var avail := peer.get_available_bytes()
			if avail > 0:
				var res: Array = peer.get_partial_data(avail)
				if res[0] == OK:
					var buf: PackedByteArray = conn["buf"]
					buf.append_array(res[1] as PackedByteArray)
					conn["buf"] = buf
					conn["idle"] = 0.0

			# Extract and dispatch one request at a time (no pipelining): only when
			# the connection isn't already mid-request (busy) awaiting a coroutine.
			if not conn["busy"] and not conn["dead"]:
				var req := _try_extract_request(conn)
				var st := String(req.get("status", ""))
				if st == "ok":
					conn["busy"] = true
					_service(conn, req)  # async — parks the connection until the result lands
				elif st == "error":
					# HTTP framing error (bad request line, missing length, too large):
					# reply and close, per "close on parse errors".
					_send_status(peer, int(req["code"]), String(req["text"]), false)
					conn["dead"] = true
				# "incomplete" ⇒ wait for more bytes.

		# Lifetime: a busy connection is never reaped mid-request. Otherwise drop on
		# a hard error, on a peer that was connected and is now gone, on one that
		# never connected within the grace window, on our own close intent, or on
		# idle timeout.
		var keep := true
		if conn["busy"]:
			keep = true
		elif status == StreamPeerTCP.STATUS_ERROR:
			keep = false
		elif status == StreamPeerTCP.STATUS_NONE and conn["connected"]:
			keep = false
		elif status != StreamPeerTCP.STATUS_CONNECTED and conn["age"] > CONNECT_TIMEOUT:
			keep = false
		elif conn["dead"]:
			keep = false
		elif conn["idle"] > IDLE_TIMEOUT:
			keep = false

		if keep:
			still.append(conn)
		else:
			peer.disconnect_from_host()
	_conns = still


## Parse one complete HTTP request from the connection buffer. Returns one of:
##   {status:"incomplete"}                              — need more bytes
##   {status:"error", code, text, ...}                  — framing error (reply + close)
##   {status:"ok", method, path, body, keep_alive}      — a full request (bytes consumed)
func _try_extract_request(conn: Dictionary) -> Dictionary:
	var buf: PackedByteArray = conn["buf"]
	var header_end := _find_header_end(buf)
	if header_end == -1:
		if buf.size() > MAX_BODY:
			return {"status": "error", "code": 431, "text": "Request Header Fields Too Large"}
		return {"status": "incomplete"}

	var header_text := buf.slice(0, header_end - 4).get_string_from_utf8()
	var lines := header_text.split("\r\n")
	if lines.size() == 0:
		return {"status": "error", "code": 400, "text": "Bad Request"}
	var parts := lines[0].split(" ", false)
	if parts.size() < 2:
		return {"status": "error", "code": 400, "text": "Bad Request"}
	var http_method := parts[0].to_upper()
	var path := parts[1].split("?", true, 1)[0]  # strip any query string

	var headers: Dictionary = {}
	for i in range(1, lines.size()):
		var line: String = lines[i]
		var ci := line.find(":")
		if ci > 0:
			headers[line.substr(0, ci).strip_edges().to_lower()] = line.substr(ci + 1).strip_edges()

	var keep_alive := String(headers.get("connection", "")).to_lower() != "close"
	var content_length := int(headers["content-length"]) if headers.has("content-length") else -1

	if http_method == "POST":
		if content_length < 0:
			return {"status": "error", "code": 411, "text": "Length Required"}
		if content_length > MAX_BODY:
			return {"status": "error", "code": 413, "text": "Payload Too Large"}
		if buf.size() < header_end + content_length:
			return {"status": "incomplete"}
		var body := buf.slice(header_end, header_end + content_length)
		conn["buf"] = buf.slice(header_end + content_length)
		return {"status": "ok", "method": http_method, "path": path, "body": body, "keep_alive": keep_alive}

	# Non-POST carries no body here; consume the headers (plus any declared body).
	var consumed := header_end
	if content_length > 0:
		if buf.size() < header_end + content_length:
			return {"status": "incomplete"}
		consumed = header_end + content_length
	conn["buf"] = buf.slice(consumed)
	return {"status": "ok", "method": http_method, "path": path, "body": PackedByteArray(), "keep_alive": keep_alive}


## Index just past the CRLFCRLF header terminator, or -1 if not present yet.
func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i + 4
	return -1


## Handle one extracted request, write its response, and release the connection.
## Async: a tools/call awaits the router's command coroutine, so the connection is
## parked (busy) until the result lands, exactly as the WebSocket server does.
func _service(conn: Dictionary, req: Dictionary) -> void:
	var peer: StreamPeerTCP = conn["peer"]
	var keep_alive: bool = req["keep_alive"]
	var http_method: String = req["method"]
	var path: String = req["path"]

	if http_method == "OPTIONS":
		# CORS preflight tolerance (local dev bridge, 127.0.0.1 only).
		_send_status(peer, 204, "No Content", keep_alive, _cors_preflight_headers())
	elif path != MCP_PATH:
		_send_status(peer, 404, "Not Found", keep_alive)
	elif http_method != "POST":
		_send_status(peer, 405, "Method Not Allowed", keep_alive, {"Allow": "POST, OPTIONS"})
	else:
		await _handle_post(peer, req["body"], keep_alive)

	conn["busy"] = false
	if not keep_alive:
		conn["dead"] = true


func _handle_post(peer: StreamPeerTCP, body: PackedByteArray, keep_alive: bool) -> void:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not (json.data is Dictionary):
		_send_json(peer, {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}, keep_alive)
		return
	var msg: Dictionary = json.data

	# A JSON-RPC notification (no id — e.g. notifications/initialized) is accepted
	# with an empty 202 and no body.
	if not (msg.has("id") and msg["id"] != null):
		_send_status(peer, 202, "Accepted", keep_alive)
		return

	var resp := await _handle_mcp(String(msg.get("method", "")), msg.get("params", {}), _normalize_id(msg["id"]))
	_send_json(peer, resp, keep_alive)


## Godot's JSON parser coerces every number to a float, so an integer id like 1
## arrives as 1.0. Echo integral ids back as ints for faithful JSON-RPC id
## matching; leave strings and genuinely fractional numbers untouched.
func _normalize_id(id: Variant) -> Variant:
	if id is float and is_finite(id) and id == floor(id):
		return int(id)
	return id


func _handle_mcp(rpc_method: String, params: Variant, id: Variant) -> Dictionary:
	if rpc_method == "initialize":
		return _ok(id, _initialize_result(params))
	if rpc_method == "ping":
		return _ok(id, {})
	if rpc_method == "tools/list":
		return _ok(id, {"tools": _list_tools()})
	if rpc_method == "tools/call":
		return await _handle_tools_call(params, id)
	return _err(id, -32601, "Method not found: %s" % rpc_method)


func _initialize_result(params: Variant) -> Dictionary:
	var p: Dictionary = params if params is Dictionary else {}
	var requested := String(p.get("protocolVersion", ""))
	var version := requested if requested in PROTOCOL_VERSIONS else LATEST_PROTOCOL
	return {
		"protocolVersion": version,
		"capabilities": {"tools": {"listChanged": false}},
		"serverInfo": {"name": "godot-mcp-addon", "version": _addon_version()},
		"instructions": INSTRUCTIONS,
	}


## tools/list: godot_run always first (the generic escape hatch, mirroring
## serve.go), then — unless godot_mcp/network/http_typed is false — every typed
## per-command tool. http_typed=false is the tool-limited-client mode (serve
## --typed=false's role): godot_run alone.
func _list_tools() -> Array:
	var out: Array = [_godot_run_tool()]
	if _typed_enabled():
		_ensure_typed_tools()
		out.append_array(_typed_tools)
	return out


func _handle_tools_call(params: Variant, id: Variant) -> Dictionary:
	var p: Dictionary = params if params is Dictionary else {}
	var tool_name := String(p.get("name", ""))
	var args_val: Variant = p.get("arguments", {})
	var arguments: Dictionary = args_val if args_val is Dictionary else {}

	if tool_name == "godot_run":
		var method := String(arguments.get("method", ""))
		if method.is_empty():
			return _ok(id, _tool_result("missing required argument: method", true))
		var run_params_val: Variant = arguments.get("params", {})
		var run_params: Dictionary = run_params_val if run_params_val is Dictionary else {}
		# `game` is accepted for schema parity with serve.go's godot_run, but the
		# addon IS the editor and has no separate game channel to route to — the
		# runtime.*/input.* commands broker to the running game the same way
		# regardless — so it is ignored here.
		return await _dispatch_command(method, run_params, id)

	_ensure_typed_tools()
	if not _name_to_method.has(tool_name):
		return _err(id, -32602, "Unknown tool: %s" % tool_name)
	return await _dispatch_command(_name_to_method[tool_name], arguments, id)


## Run a dotted method through the SAME router the WebSocket server uses (so every
## guard applies unchanged) and render the outcome as an MCP tool result.
func _dispatch_command(method: String, params: Dictionary, id: Variant) -> Dictionary:
	if command_router == null:
		return _err(id, -32603, "No command router")
	var outcome: Dictionary = await command_router.execute(method, params)
	if outcome.has("error"):
		return _ok(id, _tool_result(JSON.stringify(outcome["error"], "  "), true))
	return _ok(id, _tool_result(JSON.stringify(outcome.get("result", {}), "  "), false))


# --- Typed tools (built from the router's live param docs) ------------------

func _typed_enabled() -> bool:
	return bool(ProjectSettings.get_setting(TYPED_SETTING, true))


## Build the typed tool list and name→method map once from the router's docs. The
## router is stable after registration, so this is cached; the http_typed toggle is
## applied at list time, not here.
func _ensure_typed_tools() -> void:
	if _typed_built or command_router == null:
		return
	var methods: Array = command_router.get_available_methods()
	methods.sort()
	var docs: Dictionary = {}
	if command_router.has_method("get_command_docs"):
		docs = command_router.get_command_docs()
	var tools: Array = []
	var name_map: Dictionary = {}
	for method: String in methods:
		# MCP tool names must match ^[a-zA-Z0-9_-]{1,64}$ — no dots. Mirror serve.go:
		# dotted method → name with '.' replaced by '_'. First (sorted) wins a
		# collision; the rest are skipped and still reachable via godot_run.
		var tool_name := method.replace(".", "_")
		if name_map.has(tool_name):
			push_warning("[MCP-HTTP] tool name '%s' collides (%s vs %s); keeping the first, godot_run still covers it" % [tool_name, name_map[tool_name], method])
			continue
		name_map[tool_name] = method
		tools.append(_build_tool(tool_name, method, docs.get(method, null)))
	_typed_tools = tools
	_name_to_method = name_map
	_typed_built = true


func _build_tool(tool_name: String, method: String, doc: Variant) -> Dictionary:
	if doc is Dictionary:
		var d: Dictionary = doc
		return {
			"name": tool_name,
			"description": String(d.get("description", "")),
			"inputSchema": _schema_from_params(d.get("params", [])),
		}
	# No docs metadata — a permissive object schema; params are addon-defined.
	return {
		"name": tool_name,
		"description": "Godot MCP command '%s'. Parameters are addon-defined; discover them via engine_commands (group '%s') or the generic godot_run tool." % [method, method.get_slice(".", 0)],
		"inputSchema": {"type": "object"},
	}


func _schema_from_params(params: Variant) -> Dictionary:
	var props: Dictionary = {}
	var required: Array = []
	if params is Array:
		for entry in (params as Array):
			if not (entry is Dictionary):
				continue
			var pd: Dictionary = entry
			var pname := String(pd.get("name", ""))
			if pname.is_empty():
				continue
			var schema: Dictionary = {}
			var t := _json_schema_type(String(pd.get("type", "")))
			if not t.is_empty():
				schema["type"] = t
			var desc := String(pd.get("desc", ""))
			if not desc.is_empty():
				schema["description"] = desc
			props[pname] = schema
			if bool(pd.get("required", false)):
				required.append(pname)
	return {"type": "object", "properties": props, "required": required}


## The addon's friendly Godot type string → a JSON Schema type. JSON (and any
## unmapped type) returns "" so the caller omits the type key (any). Mirrors
## serve.go's jsonSchemaType.
func _json_schema_type(godot_type: String) -> String:
	match godot_type:
		"String", "NodePath", "Vector2", "Vector3", "Color":
			return "string"
		"int":
			return "integer"
		"float":
			return "number"
		"bool":
			return "boolean"
		"Array":
			return "array"
		"Dictionary":
			return "object"
		_:
			return ""


## The generic escape hatch, always present and always first, mirroring the tool
## serve.go exposes: `method` (dotted "<group>.<command>", required), `params`
## (object), and `game` (accepted for parity, ignored in-addon — see
## _handle_tools_call). It reaches EVERY method, including undocumented and
## project-local commands, so a tool-limited client (http_typed=false) can drive
## the whole surface through this one tool.
func _godot_run_tool() -> Dictionary:
	return {
		"name": "godot_run",
		"description": "Run any godot-mcp command against the running Godot editor (4.7+) and return its JSON result. " + \
			"`method` is \"<group>.<command>\" (e.g. node.add, engine.search) and `params` mirrors that command's parameters, so it reaches EVERY method — including commands without a typed tool and project-local commands. " + \
			"Discover the live API with method \"engine.search\" {query} or \"engine.class_info\" {class}; \"engine.commands\" {group?} lists this server's own methods. " + \
			"Editor mutations are undoable; runtime.*/input.* require a scene to be playing (method \"scene.play\").",
		"inputSchema": {
			"type": "object",
			"properties": {
				"method": {"type": "string", "description": "<group>.<command>, e.g. node.add or engine.search"},
				"params": {"type": "object", "description": "command parameters"},
				"game": {"type": "boolean", "description": "Route a runtime.*/input.* method to a standalone debug-build game's direct server instead of the editor (accepted for parity; the in-editor endpoint brokers to the game either way)."},
			},
			"required": ["method"],
		},
	}


func _addon_version() -> String:
	if not _version_cache.is_empty():
		return _version_cache
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/godot_mcp/plugin.cfg") == OK:
		_version_cache = String(cfg.get_value("plugin", "version", "0.0.0"))
	else:
		_version_cache = "0.0.0"
	return _version_cache


# --- JSON-RPC / HTTP response helpers ---------------------------------------

func _ok(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _err(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _tool_result(text: String, is_error: bool) -> Dictionary:
	return {"content": [{"type": "text", "text": text}], "isError": is_error}


func _cors_preflight_headers() -> Dictionary:
	return {
		"Access-Control-Allow-Methods": "POST, OPTIONS",
		"Access-Control-Allow-Headers": "Content-Type, Mcp-Session-Id, Mcp-Protocol-Version, Accept",
		"Access-Control-Max-Age": "86400",
	}


func _send_json(peer: StreamPeerTCP, obj: Dictionary, keep_alive: bool) -> void:
	_send_http(peer, 200, "OK", "application/json", JSON.stringify(obj).to_utf8_buffer(), keep_alive)


func _send_status(peer: StreamPeerTCP, code: int, reason: String, keep_alive: bool, extra: Dictionary = {}) -> void:
	_send_http(peer, code, reason, "", PackedByteArray(), keep_alive, extra)


func _send_http(peer: StreamPeerTCP, code: int, reason: String, content_type: String, body: PackedByteArray, keep_alive: bool, extra: Dictionary = {}) -> void:
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var head := "HTTP/1.1 %d %s\r\n" % [code, reason]
	if not content_type.is_empty():
		head += "Content-Type: %s\r\n" % content_type
	# A 204 carries no body and (per RFC 7230) no Content-Length; everything else does.
	if code != 204:
		head += "Content-Length: %d\r\n" % body.size()
	head += "Access-Control-Allow-Origin: *\r\n"
	head += "Connection: %s\r\n" % ("keep-alive" if keep_alive else "close")
	for k in extra:
		head += "%s: %s\r\n" % [k, extra[k]]
	head += "\r\n"
	var out := head.to_utf8_buffer()
	out.append_array(body)
	peer.put_data(out)
