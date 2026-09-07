package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// newTestServer builds an mcpServer whose stdout transport is a buffer, so tests
// can feed it a JSON-RPC line via handle() and read back the single response.
func newTestServer() (*mcpServer, *bytes.Buffer) {
	var buf bytes.Buffer
	s := &mcpServer{out: bufio.NewWriter(&buf)}
	return s, &buf
}

// roundtrip sends one request through handle and parses the response frame. It
// asserts exactly one newline-terminated frame came back (transport purity).
func roundtrip(t *testing.T, s *mcpServer, buf *bytes.Buffer, id int, method string, params any) map[string]any {
	t.Helper()
	buf.Reset()
	req := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		req["params"] = params
	}
	line, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	s.handle(line)

	out := buf.Bytes()
	// Exactly one frame: one trailing newline, no interior newlines (stdout purity).
	if n := bytes.Count(out, []byte{'\n'}); n != 1 {
		t.Fatalf("%s: expected exactly one response frame (1 newline), got %d in %q", method, n, out)
	}
	var resp map[string]any
	if err := json.Unmarshal(out, &resp); err != nil {
		t.Fatalf("%s: unmarshal response %q: %v", method, out, err)
	}
	return resp
}

func TestInitializeAdvertisesPromptsCapability(t *testing.T) {
	s, buf := newTestServer()
	resp := roundtrip(t, s, buf, 1, "initialize", map[string]any{"protocolVersion": mcpProtocolVersion})

	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("initialize: no result: %#v", resp)
	}
	caps, ok := result["capabilities"].(map[string]any)
	if !ok {
		t.Fatalf("initialize: no capabilities: %#v", result)
	}
	prompts, ok := caps["prompts"].(map[string]any)
	if !ok {
		t.Fatalf("initialize: prompts capability missing: %#v", caps)
	}
	if lc, ok := prompts["listChanged"].(bool); !ok || lc {
		t.Errorf("prompts.listChanged = %#v, want false", prompts["listChanged"])
	}
}

func TestPromptsListReturnsAllFour(t *testing.T) {
	s, buf := newTestServer()
	resp := roundtrip(t, s, buf, 2, "prompts/list", nil)

	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("prompts/list: no result: %#v", resp)
	}
	list, ok := result["prompts"].([]any)
	if !ok {
		t.Fatalf("prompts/list: prompts not an array: %#v", result)
	}
	if len(list) != 4 {
		t.Fatalf("prompts/list returned %d prompts, want 4", len(list))
	}

	want := map[string]bool{
		"discover-then-drive": false, // seen
		"spatial-placement":   false,
		"launch-recovery":     false,
		"bug-hunt":            false,
	}
	var spatial map[string]any
	for _, p := range list {
		pm := p.(map[string]any)
		name, _ := pm["name"].(string)
		if _, known := want[name]; !known {
			t.Errorf("unexpected prompt name %q", name)
			continue
		}
		want[name] = true
		if desc, _ := pm["description"].(string); desc == "" {
			t.Errorf("prompt %q has empty description", name)
		}
		if name == "spatial-placement" {
			spatial = pm
		}
	}
	for name, seen := range want {
		if !seen {
			t.Errorf("prompt %q missing from prompts/list", name)
		}
	}

	// spatial-placement advertises its optional `target` argument.
	args, ok := spatial["arguments"].([]any)
	if !ok || len(args) != 1 {
		t.Fatalf("spatial-placement arguments = %#v, want one", spatial["arguments"])
	}
	arg := args[0].(map[string]any)
	if arg["name"] != "target" {
		t.Errorf("spatial-placement arg name = %#v, want target", arg["name"])
	}
	if req, _ := arg["required"].(bool); req {
		t.Errorf("spatial-placement target must be optional (required:false)")
	}
	if desc, _ := arg["description"].(string); desc == "" {
		t.Errorf("spatial-placement target arg has empty description")
	}
}

// promptMessageText extracts the single user text message from a prompts/get result.
func promptMessageText(t *testing.T, resp map[string]any) (description, text string) {
	t.Helper()
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("prompts/get: no result: %#v", resp)
	}
	description, _ = result["description"].(string)
	msgs, ok := result["messages"].([]any)
	if !ok || len(msgs) != 1 {
		t.Fatalf("prompts/get: messages = %#v, want one", result["messages"])
	}
	m := msgs[0].(map[string]any)
	if m["role"] != "user" {
		t.Errorf("message role = %#v, want user", m["role"])
	}
	content, ok := m["content"].(map[string]any)
	if !ok {
		t.Fatalf("prompts/get: content = %#v", m["content"])
	}
	if content["type"] != "text" {
		t.Errorf("content type = %#v, want text", content["type"])
	}
	text, _ = content["text"].(string)
	if text == "" {
		t.Errorf("prompts/get: empty message text")
	}
	return description, text
}

func TestPromptsGetNoArguments(t *testing.T) {
	s, buf := newTestServer()
	resp := roundtrip(t, s, buf, 3, "prompts/get", map[string]any{"name": "discover-then-drive"})

	desc, text := promptMessageText(t, resp)
	if desc == "" {
		t.Errorf("discover-then-drive: empty description in prompts/get")
	}
	if !strings.Contains(text, "engine.search") {
		t.Errorf("discover-then-drive text missing the discover steer:\n%s", text)
	}
}

func TestPromptsGetSpatialWithAndWithoutTarget(t *testing.T) {
	s, buf := newTestServer()

	// Without the target argument: no "Apply this to:" tail.
	resp := roundtrip(t, s, buf, 4, "prompts/get", map[string]any{"name": "spatial-placement"})
	_, plain := promptMessageText(t, resp)
	if strings.Contains(plain, "Apply this to:") {
		t.Errorf("spatial-placement without target must not weave in a target line:\n%s", plain)
	}

	// With target: the tail is appended verbatim.
	resp = roundtrip(t, s, buf, 5, "prompts/get", map[string]any{
		"name":      "spatial-placement",
		"arguments": map[string]any{"target": "the crate"},
	})
	_, woven := promptMessageText(t, resp)
	if !strings.Contains(woven, "Apply this to: the crate") {
		t.Errorf("spatial-placement with target=the crate missing the woven line:\n%s", woven)
	}
	// The base body is still present; the target line is additive.
	if len(woven) <= len(plain) {
		t.Errorf("woven text (%d) should be longer than plain (%d)", len(woven), len(plain))
	}
}

func TestPromptsGetUnknownNameErrors(t *testing.T) {
	s, buf := newTestServer()
	resp := roundtrip(t, s, buf, 6, "prompts/get", map[string]any{"name": "does-not-exist"})

	if _, ok := resp["result"]; ok {
		t.Fatalf("unknown prompt returned a result: %#v", resp)
	}
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("unknown prompt: no error object: %#v", resp)
	}
	if code, _ := errObj["code"].(float64); code != -32602 {
		t.Errorf("unknown prompt error code = %v, want -32602", errObj["code"])
	}
}

// TestPromptDescriptorsShape unit-tests the registry projection directly (no JSON
// round-trip): every prompt has a name/description and a non-empty rendered body,
// and only prompts with arguments carry an arguments key.
func TestPromptDescriptorsShape(t *testing.T) {
	descs := promptDescriptors()
	if len(descs) != len(prompts) {
		t.Fatalf("promptDescriptors returned %d, want %d", len(descs), len(prompts))
	}
	for i, p := range prompts {
		if p.name == "" || p.description == "" {
			t.Errorf("prompt %d has empty name/description", i)
		}
		if p.render == nil {
			t.Fatalf("prompt %q has nil render", p.name)
		}
		if body := p.render(nil); strings.TrimSpace(body) == "" {
			t.Errorf("prompt %q renders empty body", p.name)
		}
		d := descs[i]
		_, hasArgs := d["arguments"]
		if hasArgs != (len(p.arguments) > 0) {
			t.Errorf("prompt %q arguments key presence = %v, want %v", p.name, hasArgs, len(p.arguments) > 0)
		}
	}
}
