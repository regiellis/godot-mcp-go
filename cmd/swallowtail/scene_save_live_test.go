package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
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
	mustCall("scene.create", map[string]any{"path": original, "root_type": "Node3D"}, nil)
	defer func() {
		// Keep fixture files until the editor exits; cached resources can be saved later.
		for _, path := range []string{original, savedAs} {
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
	readSaved := func(path string, names []string) {
		t.Helper()
		var result struct {
			Output []string `json:"output"`
		}
		// Bypass the edited scene and ResourceLoader cache when checking persistence.
		code := "var packed = ResourceLoader.load(" + strconv.Quote(path) + ", \"PackedScene\", ResourceLoader.CACHE_MODE_IGNORE)\n" +
			"var saved = packed.instantiate()\nvar names: Array = []\n" +
			"for child in saved.get_children():\n\tnames.append(String(child.name))\n" +
			"emit(JSON.stringify(names))\nsaved.free()"
		mustCall("editor.run_script", map[string]any{"code": code}, &result)
		var got []string
		if len(result.Output) != 1 {
			t.Fatalf("saved scene %s readback: %+v", path, result)
		}
		if err := json.Unmarshal([]byte(result.Output[0]), &got); err != nil {
			t.Fatal(err)
		}
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
}
