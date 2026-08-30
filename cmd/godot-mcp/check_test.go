package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// checkProject lays out a project with a script in each place the walker has a
// rule about, and returns its root.
func checkProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := []string{
		"project.godot",
		"scripts/player.gd",
		"scripts/enemy.gd",
		"scripts/notes.md",
		"addons/godot_mcp/plugin.gd",
		".godot/imported/cached.gd",
		"levels/one.tscn",
	}
	for _, f := range files {
		p := filepath.Join(root, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("extends Node\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// A sweep of the project takes the caller's own scripts: .godot/ is a build
// cache and addons/ is third-party code, so neither is what "check my project"
// means.
func TestCollectScriptsSkipsCacheAndAddons(t *testing.T) {
	root := checkProject(t)
	got, err := collectScripts(root, []string{root})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"res://scripts/enemy.gd", "res://scripts/player.gd"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectScripts(root) = %v, want %v", got, want)
	}
}

// Naming a path inside addons is the opt-in: the addon's own scripts are then
// exactly what the caller asked to check.
func TestCollectScriptsAddonsWhenNamed(t *testing.T) {
	root := checkProject(t)
	got, err := collectScripts(root, []string{filepath.Join(root, "addons")})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"res://addons/godot_mcp/plugin.gd"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectScripts(addons) = %v, want %v", got, want)
	}
}

// The same paths given twice, once as a file and once through its directory,
// are one file to check.
func TestCollectScriptsDeduplicatesAndSorts(t *testing.T) {
	root := checkProject(t)
	got, err := collectScripts(root, []string{
		filepath.Join(root, "scripts", "player.gd"),
		filepath.Join(root, "scripts"),
		"res://scripts/enemy.gd",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"res://scripts/enemy.gd", "res://scripts/player.gd"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectScripts = %v, want %v", got, want)
	}
}

// A named file that is not GDScript is a mistake worth reporting, rather than a
// silent no-op that reads as a clean sweep.
func TestCollectScriptsRejectsNonScript(t *testing.T) {
	root := checkProject(t)
	if _, err := collectScripts(root, []string{filepath.Join(root, "levels", "one.tscn")}); err == nil {
		t.Error("collectScripts accepted a .tscn as a script to parse")
	}
	if _, err := collectScripts(root, []string{filepath.Join(root, "no", "such", "file.gd")}); err == nil {
		t.Error("collectScripts accepted a path that does not exist")
	}
}

func TestUnderAddons(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "p")
	cases := map[string]bool{
		filepath.Join(root, "addons"):                     true,
		filepath.Join(root, "addons", "godot_mcp"):        true,
		filepath.Join(root, "scripts"):                    false,
		filepath.Join(root, "scripts", "addons_helper"):   false,
		filepath.Join(root, "levels", "addons", "x.gd"):   true,
		filepath.Join(root, "levels", "addon", "x.gd"):    false,
		filepath.Join(root, "levels", "myaddons", "x.gd"): false,
	}
	for path, want := range cases {
		if got := underAddons(root, path); got != want {
			t.Errorf("underAddons(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestCheckArgs(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "p")
	want := []string{"--headless", "--path", root, "--script", "res://scripts/player.gd", "--check-only"}
	got := checkArgs(root, "res://scripts/player.gd")
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("checkArgs = %v, want %v", got, want)
	}
}

// localPath accepts the engine's own res:// spelling as well as a path on disk,
// so `godot-mcp check res://scripts` works from anywhere.
func TestLocalPath(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "p")
	got, err := localPath(root, "res://scripts/player.gd")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "scripts", "player.gd"); got != want {
		t.Errorf("localPath(res://) = %q, want %q", got, want)
	}
}
