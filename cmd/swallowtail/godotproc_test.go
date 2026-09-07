package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Real 4.7.2 output from `godot --headless --path project --script res://bad.gd
// --check-only`, captured 2026-08-30. The parser is built from this rather than
// from what the format looks like it should be: the "at:" line is indented, the
// location lives in its trailing parenthesis, and a parse failure prints both a
// SCRIPT ERROR and a plain ERROR that names a .cpp file, not the script.
const checkOnlyTranscript = `Godot Engine v4.7.2.rc.custom_build.36a04fe52 (2026-07-30 23:59:26 UTC) - https://godotengine.org

SCRIPT ERROR: Parse Error: Expected expression for variable initial value after "=".
   at: GDScript::reload (res://zz_throwaway_bad.gd:4)
ERROR: Failed to load script "res://zz_throwaway_bad.gd" with error "Parse error".
   at: ResourceFormatLoaderGDScript::load (modules\gdscript\gdscript_resource_format.cpp:46)
`

func TestParseEngineLogCheckOnly(t *testing.T) {
	entries := parseEngineLog(strings.NewReader(checkOnlyTranscript))
	if len(entries) != 2 {
		t.Fatalf("parsed %d entries, want 2: %+v", len(entries), entries)
	}

	got := entries[0]
	if got.Level != "SCRIPT ERROR" {
		t.Errorf("first entry level = %q, want SCRIPT ERROR", got.Level)
	}
	if got.Message != `Parse Error: Expected expression for variable initial value after "=".` {
		t.Errorf("first entry message = %q", got.Message)
	}
	if got.File != "res://zz_throwaway_bad.gd" || got.Line != 4 {
		t.Errorf("first entry location = %s:%d, want res://zz_throwaway_bad.gd:4", got.File, got.Line)
	}
	if want := "res://zz_throwaway_bad.gd:4: " + got.Message; got.String() != want {
		t.Errorf("String() = %q, want %q", got.String(), want)
	}

	// The engine's own follow-up names a .cpp file. It is still an error, it just
	// does not point at the caller's script, which is why check prefers the
	// SCRIPT ERROR entries when it has them.
	if entries[1].Level != "ERROR" || entries[1].File != `modules\gdscript\gdscript_resource_format.cpp` {
		t.Errorf("second entry = %+v, want the ERROR naming the .cpp loader", entries[1])
	}
}

// SCRIPT ERROR must win over the ERROR prefix it contains, and the USER forms
// (push_error / push_warning from project code) must not be dropped.
func TestParseEngineLogLevels(t *testing.T) {
	text := strings.Join([]string{
		"WARNING: The Vulkan driver is out of date.",
		"   at: initialize (drivers/vulkan/rendering_device_driver_vulkan.cpp:100)",
		"USER ERROR: save failed",
		"USER WARNING: no save slot",
		"ERROR: Cannot open file 'res://missing.tres'.",
	}, "\n")
	entries := parseEngineLog(strings.NewReader(text))
	var levels []string
	for _, e := range entries {
		levels = append(levels, e.Level)
	}
	want := []string{"WARNING", "USER ERROR", "USER WARNING", "ERROR"}
	if strings.Join(levels, ",") != strings.Join(want, ",") {
		t.Fatalf("levels = %v, want %v", levels, want)
	}

	errs, warns := splitEngineLog(entries)
	if len(errs) != 2 {
		t.Errorf("errors = %d, want 2 (ERROR and USER ERROR)", len(errs))
	}
	if len(warns) != 2 {
		t.Errorf("warnings = %d, want 2 (WARNING and USER WARNING)", len(warns))
	}
}

// A line with no diagnostic prefix contributes nothing, and an "at:" line with
// no entry above it is not an entry of its own.
func TestParseEngineLogIgnoresPlainOutput(t *testing.T) {
	text := "Godot Engine v4.7.2.rc\n   at: orphaned (res://x.gd:1)\nsome print() output\n"
	if entries := parseEngineLog(strings.NewReader(text)); len(entries) != 0 {
		t.Errorf("parsed %d entries from plain output, want 0: %+v", len(entries), entries)
	}
}

// Real 4.7.2 output from a failing `--export-release`, captured 2026-08-30. The
// engine puts the whole reason on continuation lines between the ERROR and its
// "at:", so an entry that stops at the first line reports "configuration errors"
// and drops the two paths that say which templates are missing.
const exportFailureTranscript = `[  83% ] first_scan_filesystem | Starting file scan...
ERROR: Cannot export project with preset "Windows Desktop" due to configuration errors:
No export template found at the expected path:
C:/Users/x/AppData/Roaming/Godot/export_templates/4.7.2.rc/windows_debug_x86_64.exe
No export template found at the expected path:
C:/Users/x/AppData/Roaming/Godot/export_templates/4.7.2.rc/windows_release_x86_64.exe

   at: EditorNode::_fs_changed (editor\gui\editor_node.cpp:1401)
ERROR: Project export for preset "Windows Desktop" failed.
   at: EditorNode::_fs_changed (editor\gui\editor_node.cpp:1417)
`

func TestParseEngineLogKeepsExportDetail(t *testing.T) {
	entries := parseEngineLog(strings.NewReader(exportFailureTranscript))
	if len(entries) != 2 {
		t.Fatalf("parsed %d entries, want 2: %+v", len(entries), entries)
	}
	if len(entries[0].Detail) != 4 {
		t.Fatalf("detail = %v, want the four lines naming the missing templates", entries[0].Detail)
	}
	if !strings.Contains(entries[0].String(), "windows_release_x86_64.exe") {
		t.Errorf("String() = %q, want it to carry the missing template path", entries[0].String())
	}
	// The second error closes on its own "at:" and borrows nothing from the first.
	if len(entries[1].Detail) != 0 {
		t.Errorf("second entry picked up detail: %v", entries[1].Detail)
	}
}

// Lines after an error that never closes with an "at:" are ordinary output, not
// the engine's detail, so they must not be folded into the message.
func TestParseEngineLogDropsUnclosedDetail(t *testing.T) {
	text := "ERROR: something went wrong\nplayer spawned\nlevel loaded\n"
	entries := parseEngineLog(strings.NewReader(text))
	if len(entries) != 1 {
		t.Fatalf("parsed %d entries, want 1", len(entries))
	}
	if len(entries[0].Detail) != 0 {
		t.Errorf("detail = %v, want none for an entry with no at: line", entries[0].Detail)
	}
}

func TestToResPath(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "scripts", "player.gd")
	if err := os.MkdirAll(filepath.Dir(nested), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := toResPath(root, nested)
	if err != nil {
		t.Fatalf("toResPath(%q) errored: %v", nested, err)
	}
	if got != "res://scripts/player.gd" {
		t.Errorf("toResPath = %q, want res://scripts/player.gd", got)
	}

	// An already-res:// path is the engine's own form and passes through.
	if got, err := toResPath(root, "res://main.tscn"); err != nil || got != "res://main.tscn" {
		t.Errorf("toResPath(res://main.tscn) = %q, %v", got, err)
	}

	// res:// cannot name a file outside the project, so this must not silently
	// produce a path with .. in it.
	outside := filepath.Join(filepath.Dir(root), "elsewhere.gd")
	if _, err := toResPath(root, outside); err == nil {
		t.Errorf("toResPath(%q) succeeded, want an outside-the-project error", outside)
	}
}

func TestProjectSetting(t *testing.T) {
	root := t.TempDir()
	body := strings.Join([]string{
		"config_version=5",
		"",
		"[application]",
		"",
		`config/name="Test"`,
		"",
		"[godot_mcp]",
		"",
		"runtime/direct_server=true",
		"network/port=9083",
		"",
		"[display]",
		"",
		"window/size/viewport_width=640",
	}, "\n")
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	if v, ok := projectSetting(root, "godot_mcp", "network/port"); !ok || v != "9083" {
		t.Errorf("network/port = %q, %v; want 9083, true", v, ok)
	}
	if !projectBoolSetting(root, "godot_mcp", "runtime/direct_server") {
		t.Error("runtime/direct_server read as false, want true")
	}
	// A key that exists in another section must not leak across.
	if _, ok := projectSetting(root, "godot_mcp", "window/size/viewport_width"); ok {
		t.Error("read a [display] key from the [godot_mcp] section")
	}
	// An absent bool setting is false, the way Godot treats a default it never wrote.
	if projectBoolSetting(root, "godot_mcp", "network/mcp_http") {
		t.Error("absent setting read as true")
	}
}
