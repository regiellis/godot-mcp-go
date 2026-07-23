package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

// runServe runs godot-mcp as a Model Context Protocol server over stdio. It
// always exposes a generic `godot_run` tool that proxies `<group>.<command>`
// calls to the running Godot editor addon, and — unless --typed=false — also
// exposes one first-class typed tool per command, built lazily from the addon's
// live param docs. MCP clients (Claude Desktop, etc.) can then build and inspect
// Godot projects directly.
//
// Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout. Nothing but
// protocol messages may go to stdout; logs go to stderr.
func runServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	port := fs.Int("port", 0, "addon WebSocket port (0 = discover from --project/cwd, then 9080)")
	project := fs.String("project", "", "Godot project dir for port discovery (default: cwd)")
	timeout := fs.Duration("timeout", 60*time.Second, "per-tool-call timeout")
	typed := fs.Bool("typed", true, "expose per-command MCP tools built from the addon's live param docs (false = only godot_run, for tool-limited clients)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	cwd := *project
	if cwd == "" {
		cwd, _ = os.Getwd()
	}

	s := &mcpServer{flagPort: *port, cwd: cwd, timeout: *timeout, typed: *typed, out: bufio.NewWriter(os.Stdout)}
	logf("godot-mcp MCP server ready (stdio)")

	reader := bufio.NewReaderSize(os.Stdin, 16*1024*1024)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			s.handle(line)
		}
		if err != nil {
			if err != io.EOF {
				logf("stdin read error: %v", err)
			}
			return 0
		}
	}
}

func logf(format string, a ...any) { fmt.Fprintf(os.Stderr, "[godot-mcp serve] "+format+"\n", a...) }

const mcpProtocolVersion = "2025-06-18"

type mcpServer struct {
	flagPort int
	cwd      string
	timeout  time.Duration
	out      *bufio.Writer
	typed    bool // --typed (default true): expose per-command typed tools

	// Typed-tool cache, built lazily from the addon's param docs. The serve loop
	// handles one request at a time, so no locking is needed.
	typedFetched bool              // a successful docs fetch has happened
	typedTools   []map[string]any  // built tool descriptors, sorted by name
	nameToMethod map[string]string // typed tool name -> dotted method
}

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (s *mcpServer) reply(id json.RawMessage, result any, e *rpcErr) {
	if id == nil {
		return // notification — no response
	}
	resp := map[string]any{"jsonrpc": "2.0", "id": id}
	if e != nil {
		resp["error"] = e
	} else {
		resp["result"] = result
	}
	b, err := json.Marshal(resp)
	if err != nil {
		logf("marshal response: %v", err)
		return
	}
	s.out.Write(b)
	s.out.WriteByte('\n')
	// A flush error means stdout (the MCP transport) is broken — surface it to stderr
	// instead of silently spinning the read loop against a dead client.
	if err := s.out.Flush(); err != nil {
		logf("write response to stdout transport: %v", err)
	}
}

func (s *mcpServer) handle(line []byte) {
	var msg rpcMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		logf("parse error: %v", err)
		return
	}
	switch msg.Method {
	case "initialize":
		s.reply(msg.ID, s.initializeResult(msg.Params), nil)
	case "tools/list":
		s.toolsList(msg.ID)
	case "tools/call":
		s.toolsCall(msg)
	case "resources/list":
		s.reply(msg.ID, map[string]any{"resources": resourceDescriptors()}, nil)
	case "resources/templates/list":
		s.reply(msg.ID, map[string]any{"resourceTemplates": []any{}}, nil)
	case "resources/read":
		s.resourcesRead(msg)
	case "ping":
		s.reply(msg.ID, map[string]any{}, nil)
	default:
		if msg.ID != nil { // a request we don't support (notifications are ignored)
			s.reply(msg.ID, nil, &rpcErr{Code: -32601, Message: "Method not found: " + msg.Method})
		}
	}
}

func (s *mcpServer) initializeResult(params json.RawMessage) map[string]any {
	version := mcpProtocolVersion
	var p struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	if json.Unmarshal(params, &p) == nil && p.ProtocolVersion != "" {
		version = p.ProtocolVersion // agree to the client's version
	}
	return map[string]any{
		"protocolVersion": version,
		// listChanged: typed tools are fetched lazily, so the tool list can grow
		// after the first tools/list — we emit notifications/tools/list_changed.
		"capabilities": map[string]any{
			"tools":     map[string]any{"listChanged": true},
			"resources": map[string]any{},
		},
		"serverInfo":   map[string]any{"name": "godot-mcp", "version": "0.4.0"},
		"instructions": serverInstructions,
	}
}

// serverInstructions is surfaced to the MCP client at every connect (MCP
// InitializeResult.instructions). Keep it short — the durable, always-present
// steer; the godot-mcp skill carries the detail.
const serverInstructions = "Drives a running Godot editor (4.7+) via the godot-mcp addon. " +
	"Per-command tools (node_add, scene_tree, runtime_eval, …) appear when the editor was reachable; " +
	"the generic godot_run tool (method \"<group>.<command>\", params) reaches ANY method, including ones without a typed tool. " +
	"Discover before you act: your training may predate the running engine, so confirm a class/property/method against it " +
	"(method \"engine.search\" {query} / \"engine.class_info\" {class}) instead of guessing. " +
	"Spatial placement: do NOT position dependent 3D objects with parallel absolute coordinates. " +
	"Place an anchor, read its REAL world bounds back (a node's get_aabb() via global_transform, or node.get global_position), " +
	"then derive the next piece from that. node.set position is LOCAL to the parent — anchor across objects via global_position/global_transform. " +
	"Seat objects on surfaces with a downward raycast (works at edit time against CSG use_collision; via the game's physics at runtime) rather than computing heights; " +
	"face with Node3D.look_at, never hand-computed Euler. Verify by reading bounds/positions back, not by trusting one screenshot. " +
	"Godot is +Y up, -Z forward, right-handed, meters. Editor mutations are undoable; runtime.*/input.* need a scene playing (scene.play), " +
	"or set game:true to drive a standalone running debug-build game directly instead of the editor."

// gamePropDesc documents the `game` routing property on runtime.*/input.* typed
// tools and the godot_run tool.
const gamePropDesc = "Route to a standalone debug-build game's direct server instead of the editor (requires godot_mcp/runtime/direct_server)."

// godotRunTool is the always-present generic escape hatch: it reaches any method
// by name, including commands that carry no param docs (hence no typed tool) and
// project-local commands. Typed per-command tools are offered alongside it when
// the editor was reachable at list time.
var godotRunTool = map[string]any{
	"name": "godot_run",
	"description": "Run any command against a running Godot editor, 4.7 or newer (via the godot-mcp addon) and return the JSON result. " +
		"This is the generic escape hatch: `method` is \"<group>.<command>\" and `params` mirror the command's parameters, so it reaches EVERY method — " +
		"including commands without a typed tool and project-local commands. When the editor was reachable at list time, first-class per-command tools " +
		"(node_add, scene_tree, runtime_eval, …) are offered too; prefer one of those when it fits. " +
		"Set `game`:true to route a runtime.*/input.* method to a standalone debug-build game's direct server instead of the editor. " +
		"Groups: project scene node script csharp editor runtime engine input animation anim_tree tilemap theme shader particles scene3d physics navigation audio input_map resource analysis batch profiling export test android (and more). " +
		"Discover the live API with method \"engine.search\" {query} or \"engine.class_info\" {class}; \"engine.commands\" {group?} lists this server's own methods, and calling an unknown method returns the same list. " +
		"Editor mutations are undoable. `runtime.*`/`input.*` require a scene to be playing (method \"scene.play\") or game:true. " +
		"Placing 3D geometry: anchor to realized bounds and read them back (node.get global_position / get_aabb via run_script), " +
		"raycast to seat on surfaces, and verify numerically — never trust one screenshot. " +
		"Requires the Godot editor open with the plugin enabled.",
	"inputSchema": map[string]any{
		"type": "object",
		"properties": map[string]any{
			"method": map[string]any{"type": "string", "description": "<group>.<command>, e.g. node.add or engine.search"},
			"params": map[string]any{"type": "object", "description": "command parameters", "additionalProperties": true},
			"game":   map[string]any{"type": "boolean", "description": gamePropDesc},
		},
		"required": []string{"method"},
	},
}

// toolsList replies to tools/list. godot_run always comes first (the generic
// escape hatch), then the typed tools sorted by name. On the first list (with
// --typed and no successful fetch yet) it dials the addon to build the typed
// tools; if the editor is unreachable it returns just godot_run and leaves the
// cache empty so the NEXT tools/list retries.
func (s *mcpServer) toolsList(id json.RawMessage) {
	if s.typed && !s.typedFetched {
		s.fetchTypedTools() // best-effort; leaves the cache empty on failure
	}
	tools := make([]map[string]any, 0, 1+len(s.typedTools))
	tools = append(tools, godotRunTool)
	tools = append(tools, s.typedTools...)
	s.reply(id, map[string]any{"tools": tools}, nil)
}

// fetchTypedTools dials the addon (its own short timeout, independent of the
// serve --timeout) for engine.commands {docs:true} and builds the typed tool
// list into the cache. It is best-effort: a failure logs to stderr and leaves
// typedFetched false so a later list/call can retry. Returns whether it built.
func (s *mcpServer) fetchTypedTools() bool {
	resolved := client.ResolvePort(s.flagPort, s.cwd)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	raw, err := client.Call(ctx, resolved, "engine.commands", map[string]any{"docs": true})
	if err != nil {
		logf("typed tools: docs fetch failed (%v); exposing godot_run only, will retry on next list/call", err)
		return false
	}
	var payload struct {
		Docs map[string]commandDoc `json:"docs"`
	}
	if jerr := json.Unmarshal(raw, &payload); jerr != nil {
		logf("typed tools: docs parse failed: %v", jerr)
		return false
	}
	if len(payload.Docs) == 0 {
		logf("typed tools: addon returned no docs; exposing godot_run only")
		return false
	}
	s.typedTools, s.nameToMethod = buildTypedTools(payload.Docs)
	s.typedFetched = true
	logf("typed tools: built %d per-command tools from live param docs", len(s.typedTools))
	return true
}

// maybeUpgradeTypedTools is called after a successful *editor* call (tools/call
// or resources/read): if typed tools were never fetched, fetch them now
// (non-fatally — a failure never affects the call that triggered it) and, on
// success, emit notifications/tools/list_changed so the client re-lists.
func (s *mcpServer) maybeUpgradeTypedTools() {
	if !s.typed || s.typedFetched {
		return
	}
	if s.fetchTypedTools() {
		s.notifyToolsListChanged()
	}
}

// notifyToolsListChanged emits the server->client tools list_changed
// notification (a JSON-RPC message with no id) on stdout.
func (s *mcpServer) notifyToolsListChanged() {
	b, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
	if err != nil {
		logf("marshal tools/list_changed: %v", err)
		return
	}
	s.out.Write(b)
	s.out.WriteByte('\n')
	if err := s.out.Flush(); err != nil {
		logf("write tools/list_changed to stdout transport: %v", err)
	}
}

// buildTypedTools turns the addon's param docs into per-command MCP tool
// descriptors plus an explicit tool-name -> dotted-method map (names are never
// parsed back). Names are the method with '.' -> '_'. On a name collision the
// first (in sorted method order, for determinism) wins; the rest are logged and
// skipped, and godot_run still covers them. Tools are sorted by name.
func buildTypedTools(docs map[string]commandDoc) ([]map[string]any, map[string]string) {
	methods := make([]string, 0, len(docs))
	for m := range docs {
		methods = append(methods, m)
	}
	slices.Sort(methods)

	nameToMethod := make(map[string]string, len(methods))
	tools := make([]map[string]any, 0, len(methods))
	for _, method := range methods {
		name := strings.ReplaceAll(method, ".", "_")
		if kept, ok := nameToMethod[name]; ok {
			logf("typed tools: name %q collides (%q and %q); keeping %q, skipping %q (godot_run still covers it)", name, kept, method, kept, method)
			continue
		}
		nameToMethod[name] = method
		tools = append(tools, buildTool(name, method, docs[method]))
	}
	slices.SortFunc(tools, func(a, b map[string]any) int {
		return strings.Compare(a["name"].(string), b["name"].(string))
	})
	return tools, nameToMethod
}

// buildTool builds one typed tool descriptor from a command's param docs.
// runtime.*/input.* methods get an extra optional `game` boolean for routing to
// a standalone game's direct server.
func buildTool(name, method string, doc commandDoc) map[string]any {
	props := make(map[string]any, len(doc.Params)+1)
	required := make([]string, 0, len(doc.Params))
	for _, p := range doc.Params {
		schema := map[string]any{}
		if t := jsonSchemaType(p.Type); t != "" {
			schema["type"] = t // JSON / unknown -> omit the type key (any)
		}
		if p.Desc != "" {
			schema["description"] = p.Desc
		}
		props[p.Name] = schema
		if p.Required {
			required = append(required, p.Name)
		}
	}
	if strings.HasPrefix(method, "runtime.") || strings.HasPrefix(method, "input.") {
		props["game"] = map[string]any{"type": "boolean", "description": gamePropDesc}
	}
	return map[string]any{
		"name":        name,
		"description": doc.Description,
		"inputSchema": map[string]any{
			"type":       "object",
			"properties": props,
			"required":   required,
		},
	}
}

// jsonSchemaType maps the addon's friendly Godot type string to a JSON Schema
// type. JSON (and any unmapped type) returns "" so the caller omits the type
// key, leaving the property unconstrained (any).
func jsonSchemaType(godotType string) string {
	switch godotType {
	case "String", "NodePath", "Vector2", "Vector3", "Color":
		return "string"
	case "int":
		return "integer"
	case "float":
		return "number"
	case "bool":
		return "boolean"
	case "Array":
		return "array"
	case "Dictionary":
		return "object"
	default: // JSON, or an unknown type -> no type constraint
		return ""
	}
}

// godotResource is a read-only MCP resource that maps a stable godot:// URI to a
// live introspection command. Exposing project/scene/engine state as resources
// (not just tool calls) lets MCP clients pull context without spending a tool turn.
type godotResource struct {
	uri, name, description, method string
}

var resources = []godotResource{
	{"godot://project/info", "Project info", "Godot project metadata: name, path, engine version, main scene.", "project.info"},
	{"godot://project/tree", "Project file tree", "The project's res:// file tree.", "project.tree"},
	{"godot://scene/tree", "Edited scene tree", "Node tree of the scene currently open in the editor.", "scene.tree"},
	{"godot://engine/singletons", "Engine singletons", "Autoloads and engine singletons in the running build.", "engine.singletons"},
	{"godot://editor/errors", "Editor errors", "Current errors from the editor Output panel.", "editor.errors"},
}

func resourceDescriptors() []map[string]any {
	out := make([]map[string]any, 0, len(resources))
	for _, r := range resources {
		out = append(out, map[string]any{
			"uri": r.uri, "name": r.name, "description": r.description, "mimeType": "application/json",
		})
	}
	return out
}

func (s *mcpServer) resourcesRead(msg rpcMsg) {
	var p struct {
		URI string `json:"uri"`
	}
	if err := json.Unmarshal(msg.Params, &p); err != nil {
		s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "invalid params: " + err.Error()})
		return
	}
	method := ""
	for _, r := range resources {
		if r.uri == p.URI {
			method = r.method
			break
		}
	}
	if method == "" {
		s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "unknown resource: " + p.URI})
		return
	}

	resolved := client.ResolvePort(s.flagPort, s.cwd)
	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	result, err := client.Call(ctx, resolved, method, nil)
	if err != nil {
		var de *client.DialError
		if errors.As(err, &de) {
			// Editor unreachable: attach the verdict so the client can recover.
			st := client.Diagnose(s.cwd, resolved)
			s.reply(msg.ID, nil, &rpcErr{Code: -32000, Message: "editor unreachable: " + string(st.Verdict), Data: st})
			return
		}
		s.reply(msg.ID, nil, &rpcErr{Code: -32603, Message: err.Error()})
		return
	}
	s.reply(msg.ID, map[string]any{
		"contents": []map[string]any{{
			"uri": p.URI, "mimeType": "application/json", "text": string(result),
		}},
	}, nil)
	// A reachable editor is a chance to build typed tools if we haven't yet.
	s.maybeUpgradeTypedTools()
}

func (s *mcpServer) toolsCall(msg rpcMsg) {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(msg.Params, &call); err != nil {
		s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "invalid params: " + err.Error()})
		return
	}

	var (
		method string
		params map[string]any
		isGame bool
	)

	switch {
	case call.Name == "godot_run":
		var args struct {
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
			Game   bool           `json:"game"`
		}
		if len(call.Arguments) > 0 {
			if err := json.Unmarshal(call.Arguments, &args); err != nil {
				s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "invalid params: " + err.Error()})
				return
			}
		}
		if args.Method == "" {
			s.reply(msg.ID, toolResult("missing required argument: method", true), nil)
			return
		}
		// `game` is a top-level argument, a sibling of params, so the forwarded
		// params never contain it — no stripping needed here.
		method, params, isGame = args.Method, args.Params, args.Game
	default:
		m, ok := s.nameToMethod[call.Name]
		if !ok {
			s.reply(msg.ID, toolResult("unknown tool: "+call.Name, true), nil)
			return
		}
		method = m
		// A typed tool's arguments ARE the params (a flat object).
		if len(call.Arguments) > 0 {
			if err := json.Unmarshal(call.Arguments, &params); err != nil {
				s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "invalid params: " + err.Error()})
				return
			}
		}
		// The `game` routing flag is injected into runtime.*/input.* schemas; pull
		// it out and strip it so the addon never sees it.
		if g, ok := params["game"].(bool); ok {
			isGame = g
			delete(params, "game")
		}
	}

	var resolved int
	if isGame {
		resolved = client.ResolveGamePort(0, s.cwd)
	} else {
		resolved = client.ResolvePort(s.flagPort, s.cwd)
	}

	ctx, cancel := context.WithTimeout(context.Background(), methodTimeout(method, params, s.timeout))
	defer cancel()

	result, err := client.Call(ctx, resolved, method, params)
	if err != nil {
		s.replyCallError(msg.ID, err, resolved, isGame)
		return
	}
	s.reply(msg.ID, toolResult(string(result), false), nil)
	if !isGame {
		// A reachable editor is a chance to build typed tools if we haven't yet.
		s.maybeUpgradeTypedTools()
	}
}

// replyCallError renders a failed tool call as a tool-error result: a reachable
// server's protocol.Error passes through verbatim; a dial failure attaches the
// editor diagnosis (crashed / closed / starting) or, for a --game call, the
// game-unreachable checklist. Never emits free text to stdout — always a frame.
func (s *mcpServer) replyCallError(id json.RawMessage, err error, port int, isGame bool) {
	var rpc *protocol.Error
	var de *client.DialError
	switch {
	case errors.As(err, &rpc):
		b, _ := json.Marshal(map[string]any{"code": rpc.Code, "message": rpc.Message, "data": rpc.Data})
		s.reply(id, toolResult(string(b), true), nil)
	case errors.As(err, &de) && isGame:
		// The game channel has no discovery-file lifecycle to derive a verdict
		// from, so name the three things that make the game unreachable.
		b, _ := json.Marshal(gameDialErrorPayload(port))
		s.reply(id, toolResult(string(b), true), nil)
	case errors.As(err, &de):
		// Editor unreachable: return the verdict (crashed / closed / starting)
		// so the agent recovers deliberately instead of relaunching blindly.
		st := client.Diagnose(s.cwd, port)
		b, _ := json.Marshal(map[string]any{
			"editor_unreachable": true, "verdict": st.Verdict,
			"message": st.Message, "action": st.Action, "status": st,
		})
		s.reply(id, toolResult(string(b), true), nil)
	default:
		s.reply(id, toolResult("error: "+err.Error(), true), nil)
	}
}

// gameDialErrorPayload mirrors printGameDialError's content as structured data
// for a tool-error result (never free text on stdout).
func gameDialErrorPayload(port int) map[string]any {
	return map[string]any{
		"game_unreachable": true,
		"port":             port,
		"message":          fmt.Sprintf("could not reach the game's direct server on 127.0.0.1:%d — --game talks to a running game, not the editor.", port),
		"checks": []string{
			"the game is actually running",
			"it was launched as a debug build (an exported release build never serves this)",
			"the godot_mcp/runtime/direct_server project setting is enabled",
		},
	}
}

func toolResult(text string, isError bool) map[string]any {
	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
		"isError": isError,
	}
}
