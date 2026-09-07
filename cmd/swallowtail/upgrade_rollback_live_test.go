package main

import (
	"github.com/bynine/godot-mcp-go/internal/client"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Opt in only with a disposable editor project. The test authors and reloads a
// scene under that project, then checks both its disk bytes and live node tree.
func TestRestoreFixLive(t *testing.T) {
	root := client.Env("SWALLOWTAIL_TEST_PROJECT")
	if root == "" {
		t.Skip("set SWALLOWTAIL_TEST_PROJECT and SWALLOWTAIL_TEST_PORT for an isolated editor")
	}
	port, err := strconv.Atoi(client.Env("SWALLOWTAIL_TEST_PORT"))
	if err != nil {
		t.Fatal(err)
	}
	sess := &addonSession{root: root, port: port, timeout: 30 * time.Second}
	dir, err := os.MkdirTemp(root, "rollback-proof-")
	if err != nil {
		t.Fatal(err)
	}
	uri := "res://" + filepath.Base(dir) + "/main.tscn"
	call := func(method string, params map[string]any) {
		t.Helper()
		if _, err := sess.call(method, params); err != nil {
			t.Fatal(err)
		}
	}
	call("scene.create", map[string]any{"path": uri, "root_type": "Node3D"})
	scriptURI := "res://" + filepath.Base(dir) + "/logic.gd"
	call("script.create", map[string]any{"path": scriptURI, "content": "extends RefCounted\nfunc before_recovery():\n\treturn 1\n"})
	call("project.set_setting", map[string]any{"key": "application/config/features", "value": []string{"4.7", "GL Compatibility"}})
	t.Cleanup(func() {
		if _, err := sess.call("scene.close", map[string]any{"path": uri, "discard": true}); err != nil {
			t.Error(err)
			return
		}
		// Keep fixture files until this disposable editor exits: cached scripts
		// can be saved by a later scene.save even after their scene tab closes.
	})
	if err := requireSavedScenes(sess); err != nil {
		t.Fatal(err)
	}
	label := filepath.Base(dir)
	call("authoring.checkpoint", map[string]any{"action": "capture", "label": label})
	plan := fixPlan{Category: catTileMap, Edits: []fileEdit{{File: scriptURI}}, Actions: []plannedAction{
		{Method: "scene.open", Params: map[string]any{"path": uri}},
		{Method: "project.set_setting", Params: map[string]any{"key": "application/config/features"}},
	}}
	recovery, err := captureFixFiles(root, plan)
	if err != nil {
		t.Fatal(err)
	}
	recovery.Scene = uri
	call("node.add", map[string]any{"type": "Node3D", "name": "MustDisappear"})
	if err := requireSavedScenes(sess); err == nil {
		t.Fatal("unsaved scene was accepted")
	}
	call("scene.save", nil)
	call("script.edit", map[string]any{"path": scriptURI, "content": "extends RefCounted\nfunc after_recovery():\n\treturn 2\n"})
	call("project.set_setting", map[string]any{"key": "application/config/features", "value": []string{"4.8", "GL Compatibility"}})
	report := fixReport{Plan: plan, Checkpoint: label, recovery: recovery}
	restoreFix(root, sess, &report)
	if !report.Restored {
		t.Fatal(report.RecoveryErrors)
	}
	if _, err := sess.call("node.get", map[string]any{"node_path": "MustDisappear"}); err == nil {
		t.Fatal("deleted rollback node remains in the live tree")
	}
	raw, err := sess.call("script.symbols", map[string]any{"path": scriptURI})
	if err != nil || !strings.Contains(string(raw), "before_recovery") || strings.Contains(string(raw), "after_recovery") {
		t.Fatalf("cached script not restored: %s %v", raw, err)
	}
	raw, err = sess.call("editor.run_script", map[string]any{"code": `emit(JSON.stringify(ProjectSettings.get_setting("application/config/features")))`})
	if err != nil || !strings.Contains(string(raw), "4.7") || strings.Contains(string(raw), "4.8") {
		t.Fatalf("editor settings not restored: %s %v", raw, err)
	}
}
