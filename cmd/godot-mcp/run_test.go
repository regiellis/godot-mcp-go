package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// --path anchors the run on this project, and the scene rides as a positional
// res:// path straight after it, which is how the engine takes a scene to start.
func TestGameArgsScene(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "myproject")

	got := gameArgs(root, gameRunOptions{})
	if strings.Join(got, " ") != "--path "+root {
		t.Errorf("bare run = %v, want just --path", got)
	}

	got = gameArgs(root, gameRunOptions{Scene: "res://levels/one.tscn", Headless: true})
	want := []string{"--path", root, "res://levels/one.tscn", "--headless"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("scene run = %v, want %v", got, want)
	}
}

func TestGameArgsFlags(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "myproject")
	got := gameArgs(root, gameRunOptions{
		DebugCollisions: true,
		DebugPaths:      true,
		DebugNavigation: true,
		DebugAvoidance:  true,
		FixedFPS:        60,
		TimeScale:       0.5,
		PrintFPS:        true,
		GPUProfile:      true,
		BenchmarkFile:   filepath.Join(string(filepath.Separator), "tmp", "bench.json"),
		Movie:           filepath.Join(string(filepath.Separator), "tmp", "run.avi"),
		MaxFPS:          30,
		DisableVsync:    true,
		Resolution:      "1280x720",
		Windowed:        true,
		Verbose:         true,
	})
	joined := strings.Join(got, " ")
	for _, want := range []string{
		"--debug-collisions", "--debug-paths", "--debug-navigation", "--debug-avoidance",
		"--fixed-fps 60", "--time-scale 0.5", "--print-fps", "--gpu-profile",
		"--benchmark-file", "--write-movie", "--max-fps 30", "--disable-vsync",
		"--resolution 1280x720", "--windowed", "--verbose",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("gameArgs is missing %q: %s", want, joined)
		}
	}
}

// A zero value means "the engine's own default", so it must not reach the argv
// as an explicit 0: --max-fps 0 means unlimited and --time-scale 0 freezes time.
func TestGameArgsOmitsZeroValues(t *testing.T) {
	got := strings.Join(gameArgs("/p", gameRunOptions{}), " ")
	for _, flag := range []string{"--fixed-fps", "--time-scale", "--max-fps", "--benchmark-file", "--write-movie", "--resolution"} {
		if strings.Contains(got, flag) {
			t.Errorf("zero-value options put %s in the argv: %s", flag, got)
		}
	}
}

// --extra is appended verbatim and split on spaces, with no quote handling. That
// is the documented contract, so a quoted value staying two tokens is correct.
func TestGameArgsExtra(t *testing.T) {
	got := gameArgs("/p", gameRunOptions{Extra: "  --frame-delay 16   --single-window "})
	want := []string{"--path", "/p", "--frame-delay", "16", "--single-window"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("extra = %v, want %v", got, want)
	}
}

// import runs the editor headless only to build the import cache, then quits.
func TestImportArgs(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "myproject")
	want := []string{"--headless", "--path", root, "--import", "--quit"}
	if got := importArgs(root); strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("importArgs = %v, want %v", got, want)
	}
}

// The two local subcommands whose names are also addon groups hand a bare
// command name back to the addon, so `godot-mcp export info` keeps working while
// `godot-mcp export "Windows Desktop"` runs the headless export.
func TestRoutesToAddon(t *testing.T) {
	cases := []struct {
		name string
		rest []string
		want bool
	}{
		{"export", []string{"info"}, true},
		{"export", []string{"list-presets"}, true},
		{"export", []string{"list_presets"}, true},
		{"export", []string{"project", "--preset-name", "Web"}, true},
		{"export", []string{"Windows Desktop"}, false},
		{"export", []string{"--preset", "info"}, false},
		{"export", nil, false},
		{"import", []string{"reimport", "--path", "res://a.png"}, true},
		{"import", []string{"--project", "."}, false},
		{"import", nil, false},
		// Names with no addon group of their own are never diverted.
		{"launch", []string{"info"}, false},
		{"check", []string{"info"}, false},
		{"run", []string{"info"}, false},
	}
	for _, c := range cases {
		if got := routesToAddon(c.name, c.rest); got != c.want {
			t.Errorf("routesToAddon(%q, %v) = %v, want %v", c.name, c.rest, got, c.want)
		}
	}
}
