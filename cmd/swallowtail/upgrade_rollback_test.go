package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/protocol"
)

type recoveryStub struct {
	call func(string, map[string]any) (json.RawMessage, error)
}

func (s recoveryStub) callTimeout(_ time.Duration, method string, params map[string]any) (json.RawMessage, error) {
	return s.call(method, params)
}

func TestRestoreFixFailurePaths(t *testing.T) {
	for _, failure := range []string{"", "reload", "checkpoint", "diff", "diff-shape", "script-refresh", "changed-scene", "file-write", "rescan-rewrites", "scene-select", "scene-reload"} {
		t.Run(failure, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "owned.gd")
			if err := os.WriteFile(path, []byte("before"), 0600); err != nil {
				t.Fatal(err)
			}
			plan := fixPlan{Edits: []fileEdit{{File: "res://owned.gd"}}}
			recovery, err := captureFixFiles(root, plan)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("after"), 0600); err != nil {
				t.Fatal(err)
			}
			unrelated := filepath.Join(root, "owners-new-work.txt")
			if err := os.WriteFile(unrelated, []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			if failure == "file-write" {
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			if failure == "scene-select" {
				recovery.Scene = "res://original.tscn"
			}
			if failure == "scene-reload" {
				recovery.Scenes = []string{"res://affected.tscn"}
			}
			report := fixReport{Plan: plan, Checkpoint: "before", recovery: recovery}
			stub := recoveryStub{call: func(method string, params map[string]any) (json.RawMessage, error) {
				if (failure == "reload" && method == "editor.reload") ||
					(failure == "script-refresh" && method == "script.edit") ||
					(failure == "checkpoint" && params["action"] == "restore") ||
					(failure == "diff" && params["action"] == "diff") ||
					(strings.HasPrefix(failure, "scene-") && method == "scene.open") {
					return nil, errors.New("injected failure")
				}
				if failure == "rescan-rewrites" && method == "editor.reload" {
					if err := os.WriteFile(path, []byte("rewritten by editor"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				if failure == "changed-scene" && params["action"] == "diff" {
					return json.RawMessage(`{"added":["unexpected"],"removed":[],"moved":[]}`), nil
				}
				if failure == "diff-shape" && params["action"] == "diff" {
					return json.RawMessage(`{}`), nil
				}
				return json.RawMessage(`{"added":[],"removed":[],"moved":[]}`), nil
			}}
			restoreFix(root, stub, &report)
			if report.Restored != (failure == "") {
				t.Fatalf("restored=%v errors=%v", report.Restored, report.RecoveryErrors)
			}
			if failure != "" && len(report.RecoveryErrors) == 0 {
				t.Fatal("failure was hidden")
			}
			if got, err := os.ReadFile(unrelated); err != nil || string(got) != "keep" {
				t.Fatalf("unrelated work lost: %s %v", got, err)
			}
			if failure != "file-write" && failure != "rescan-rewrites" {
				if got, err := os.ReadFile(path); err != nil || string(got) != "before" {
					t.Fatalf("file recovery failed: %s %v", got, err)
				}
			}
		})
	}
}

func TestRestoreFixOnlyRemovesPlannedNewFiles(t *testing.T) {
	root := t.TempDir()
	plan := fixPlan{Edits: []fileEdit{{File: "new.uid"}}}
	recovery, err := captureFixFiles(root, plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"new.uid", "unrelated.uid"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("new"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	report := fixReport{recovery: recovery}
	restoreFix(root, recoveryStub{call: func(string, map[string]any) (json.RawMessage, error) { return json.RawMessage(`{}`), nil }}, &report)
	if !report.Restored {
		t.Fatal(report.RecoveryErrors)
	}
	if _, err := os.Stat(filepath.Join(root, "new.uid")); !os.IsNotExist(err) {
		t.Fatal("planned new file remains")
	}
	if _, err := os.Stat(filepath.Join(root, "unrelated.uid")); err != nil {
		t.Fatal(err)
	}
}

func TestCaptureFixFilesRejectsEscapes(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"../outside", "res://../outside", "", root} {
		if _, err := captureFixFiles(root, fixPlan{Edits: []fileEdit{{File: name}}}); err == nil {
			t.Fatalf("accepted %q", name)
		}
	}
}

func TestRequireSavedScenes(t *testing.T) {
	for _, raw := range []string{`{"available":true,"unsaved":[]}`, `{"available":true,"unsaved":["res://dirty.tscn"]}`, `{"available":false}`, `{}`, `broken`} {
		err := requireSavedScenes(recoveryStub{call: func(string, map[string]any) (json.RawMessage, error) {
			return json.Marshal(map[string]any{"output": []string{raw}})
		}})
		wantOK := strings.Contains(raw, `"unsaved":[]`)
		if (err == nil) != wantOK {
			t.Fatalf("%s: %v", raw, err)
		}
	}
}

func TestCaptureFixCheckpointFailures(t *testing.T) {
	for _, needsScene := range []bool{false, true} {
		stub := recoveryStub{call: func(string, map[string]any) (json.RawMessage, error) {
			return nil, &protocol.Error{Code: -32000, Message: "No scene open"}
		}}
		_, captured, err := captureFixCheckpoint(stub, "test", needsScene)
		if captured || (err != nil) != needsScene {
			t.Fatalf("needsScene=%v captured=%v err=%v", needsScene, captured, err)
		}
	}
	stub := recoveryStub{call: func(method string, _ map[string]any) (json.RawMessage, error) {
		if method == "scene.tree" {
			return json.RawMessage(`{"scene_path":"res://main.tscn"}`), nil
		}
		return nil, errors.New("checkpoint disk full")
	}}
	if _, captured, err := captureFixCheckpoint(stub, "test", false); err == nil || captured {
		t.Fatal("capture failure was ignored")
	}
}
