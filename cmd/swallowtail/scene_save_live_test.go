package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// Opt in with a disposable editor using this checkout's addon. This never
// launches an engine; retain its complete process logs through shutdown too.
func TestSceneSaveLive(t *testing.T) {
	project := client.Env("SWALLOWTAIL_TEST_PROJECT")
	if project == "" {
		t.Skip("set SWALLOWTAIL_TEST_PROJECT and SWALLOWTAIL_TEST_PORT for an isolated editor")
	}
	port, err := strconv.Atoi(client.Env("SWALLOWTAIL_TEST_PORT"))
	if err != nil || port < 1 || port > 65535 {
		t.Fatal("SWALLOWTAIL_TEST_PORT must name the disposable editor's port (1-65535)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws://127.0.0.1:"+strconv.Itoa(port), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	id := 40
	call := func(method string, params map[string]any, result any) *protocol.Error {
		t.Helper()
		id++
		if err := wsjson.Write(ctx, conn, protocol.NewRequest(id, method, params)); err != nil {
			t.Fatalf("%s request: %v", method, err)
		}
		for {
			var reply struct {
				protocol.Response
				Method string `json:"method"`
			}
			if err := wsjson.Read(ctx, conn, &reply); err != nil {
				t.Fatalf("%s response: %v", method, err)
			}
			if reply.Method != "" {
				continue
			}
			if reply.JSONRPC != protocol.Version || !reply.IDEquals(id) {
				t.Fatalf("%s response lost request identity %d: %+v", method, id, reply.Response)
			}
			if reply.Error != nil {
				return reply.Error
			}
			if result != nil {
				if err := json.Unmarshal(reply.Result, result); err != nil {
					t.Fatalf("%s result: %v", method, err)
				}
			}
			return nil
		}
	}
	mustCall := func(method string, params map[string]any, result any) {
		t.Helper()
		if err := call(method, params, result); err != nil {
			t.Fatalf("%s: %v", method, err)
		}
	}
	var info struct {
		ProjectPath string `json:"project_path"`
	}
	mustCall("project.info", nil, &info)
	if !client.SameProjectPath(project, info.ProjectPath) {
		t.Fatalf("refusing editor for %q; expected %q", info.ProjectPath, project)
	}
	checkErrors := func() {
		t.Helper()
		var result struct {
			Errors []string `json:"errors"`
			Count  int      `json:"count"`
		}
		// The default filter hides the exact ProgressDialog failures under test.
		mustCall("editor.errors", map[string]any{"include_noise": true, "internal": true, "max_lines": 10000}, &result)
		if result.Count != 0 || len(result.Errors) != 0 {
			t.Fatalf("unfiltered editor diagnostics: %v", result.Errors)
		}
	}
	checkErrors()
	dir, err := os.MkdirTemp(project, "scene-save-proof-")
	if err != nil {
		t.Fatal(err)
	}
	original := "res://" + filepath.Base(dir) + "/original.tscn"
	savedAs := "res://" + filepath.Base(dir) + "/new-dir/saved-as.tscn"
	ownedScenes := []string{original, savedAs}
	mustCall("scene.create", map[string]any{"path": original, "root_type": "Node3D"}, nil)
	defer func() {
		// Keep fixture files until the editor exits; cached resources can be saved later.
		for _, path := range ownedScenes {
			if err := call("scene.close", map[string]any{"path": path, "discard": true}, nil); err != nil && err.Code != -32001 {
				t.Errorf("close fixture %s: %v", path, err)
			}
		}
	}()
	save := func(params map[string]any, path, method string) {
		t.Helper()
		var result struct {
			Path   string `json:"path"`
			Saved  bool   `json:"saved"`
			Method string `json:"method"`
		}
		mustCall("scene.save", params, &result)
		if result.Path != path || !result.Saved || result.Method != method {
			t.Fatalf("save result = %+v; want %s via %s", result, path, method)
		}
		checkErrors()
	}
	editorJSON := func(code string, value any) {
		t.Helper()
		var result struct {
			Output []string `json:"output"`
		}
		mustCall("editor.run_script", map[string]any{"code": code}, &result)
		if len(result.Output) != 1 {
			t.Fatalf("editor script readback: %+v", result)
		}
		if err := json.Unmarshal([]byte(result.Output[0]), value); err != nil {
			t.Fatal(err)
		}
	}
	readSaved := func(path string, names []string) {
		t.Helper()
		// Bypass the edited scene and ResourceLoader cache when checking persistence.
		code := "var packed = ResourceLoader.load(" + strconv.Quote(path) + ", \"PackedScene\", ResourceLoader.CACHE_MODE_IGNORE)\n" +
			"var saved = packed.instantiate()\nvar names: Array = []\n" +
			"for child in saved.get_children():\n\tnames.append(String(child.name))\n" +
			"emit(JSON.stringify(names))\nsaved.free()"
		var got []string
		editorJSON(code, &got)
		if !reflect.DeepEqual(got, names) {
			t.Fatalf("saved scene %s children = %v; want %v", path, got, names)
		}
	}
	add := func(name string) {
		mustCall("node.add", map[string]any{"type": "Node3D", "name": name}, nil)
	}
	add("SamePathSentinel")
	save(nil, original, "save_scene")
	readSaved(original, []string{"SamePathSentinel"})
	add("SaveAsSentinel")
	save(map[string]any{"path": savedAs}, savedAs, "save_scene_as")
	readSaved(savedAs, []string{"SamePathSentinel", "SaveAsSentinel"})
	add("LaterEditSentinel")
	save(nil, savedAs, "save_scene")
	readSaved(savedAs, []string{"SamePathSentinel", "SaveAsSentinel", "LaterEditSentinel"})
	readSaved(original, []string{"SamePathSentinel"})
	checkErrors()

	probeSource, err := os.ReadFile(filepath.Join("testdata", "scene_save_guard.gd"))
	if err != nil {
		t.Fatal(err)
	}
	prefix := "res://" + filepath.Base(dir) + "/"
	probePath := prefix + "scene_save_guard.gd"
	mustCall("script.create", map[string]any{"path": probePath, "content": string(probeSource)}, nil)
	guardA, guardB := prefix+"guard-a.tscn", prefix+"guard-b.tscn"
	ownedScenes = append(ownedScenes, guardA, guardB)
	mustCall("scene.create", map[string]any{"path": guardB, "root_type": "Node3D", "open": false}, nil)
	mustCall("scene.create", map[string]any{"path": guardA, "root_type": "Node3D"}, nil)
	before := make(map[string][]byte)
	for _, name := range []string{"guard-a.tscn", "guard-b.tscn"} {
		path := filepath.Join(dir, name)
		before[path], err = os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
	}
	guard := func(mode string) {
		t.Helper()
		mustCall("scene.open", map[string]any{"path": guardA}, nil)
		outputName := "must-not-save-" + mode + ".tscn"
		outputURI := prefix + outputName
		helperName := "F22Guard-" + filepath.Base(dir) + "-" + mode
		lookup := "get_tree().root.get_node(" + strconv.Quote(helperName) + ")"
		defer mustCall("editor.run_script", map[string]any{"code": lookup + ".queue_free()"}, nil)
		// The persistent helper starts _save through its await, then switches/closes
		// synchronously. Two separate network writes would leave this to timing.
		code := "var probe = load(" + strconv.Quote(probePath) + ").new()\n" +
			"probe.name = " + strconv.Quote(helperName) + "\nget_tree().root.add_child(probe)\n" +
			"probe.begin(" + strconv.Quote(mode) + ", " + strconv.Quote(guardB) + ", " + strconv.Quote(outputURI) + ")"
		mustCall("editor.run_script", map[string]any{"code": code}, nil)
		var receipt struct {
			Done       bool `json:"done"`
			FileExists bool `json:"file_exists"`
			Reply      struct {
				Error  *protocol.Error `json:"error"`
				Result json.RawMessage `json:"result"`
			} `json:"result"`
		}
		poll := "var probe = " + lookup + "\nemit(JSON.stringify({\"done\": probe.done, \"result\": probe.result, " +
			"\"file_exists\": FileAccess.file_exists(" + strconv.Quote(outputURI) + ")}))"
		deadline := time.Now().Add(10 * time.Second)
		for {
			editorJSON(poll, &receipt)
			if receipt.Done {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s save guard did not complete within 10 seconds", mode)
			}
			time.Sleep(25 * time.Millisecond)
		}
		failure := receipt.Reply.Error
		if failure == nil || failure.Code != -32009 || len(receipt.Reply.Result) != 0 {
			t.Fatalf("%s pending save did not refuse the changed target: %+v", mode, receipt)
		}
		if !strings.Contains(failure.Message, "scene") || !strings.Contains(failure.Message, "save") || failure.Data["expected_scene"] != guardA {
			t.Fatalf("%s conflict does not describe the original save target: %+v", mode, failure)
		}
		var active struct {
			ScenePath string `json:"scene_path"`
		}
		if err := call("scene.tree", nil, &active); err != nil && err.Code != -32000 {
			t.Fatal(err)
		}
		if active.ScenePath == guardA || failure.Data["active_scene"] != active.ScenePath || (mode == "switch" && active.ScenePath != guardB) {
			t.Fatalf("%s guard changed the selected target or misreported it: %+v, active=%q", mode, failure, active.ScenePath)
		}
		if _, err := os.Stat(filepath.Join(dir, outputName)); receipt.FileExists || !os.IsNotExist(err) {
			t.Fatalf("%s refused save created an output: exists=%v, stat=%v", mode, receipt.FileExists, err)
		}
		for path, expected := range before {
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, expected) {
				t.Fatalf("%s refused save changed source %s: %v", mode, path, err)
			}
		}
		checkErrors()
		t.Logf("%s pending save refused with unchanged source files and no output", mode)
	}
	guard("switch")
	guard("close")
	checkErrors()
}
