package client

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSameProjectPath(t *testing.T) {
	// The addon reports globalize_path("res://"): forward slashes and a trailing
	// separator. The CLI reports what FindProjectRoot walked up to. Both name the
	// same directory and must compare equal.
	cases := []struct {
		name    string
		a, b    string
		want    bool
		winOnly bool
	}{
		{name: "identical", a: "/home/u/game", b: "/home/u/game", want: true},
		{name: "addon trailing slash", a: "/home/u/game/", b: "/home/u/game", want: true},
		{name: "different projects", a: "/home/u/game", b: "/home/u/other", want: false},
		{name: "empty answering", a: "", b: "/home/u/game", want: false},
		{name: "empty expected", a: "/home/u/game", b: "", want: false},
		{name: "sibling prefix is not a match", a: "/home/u/game2", b: "/home/u/game", want: false},
		{name: "windows separators and case", a: "C:/Games/Demo/", b: `c:\games\demo`, want: true, winOnly: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.winOnly && runtime.GOOS != "windows" {
				t.Skip("path case folding is platform-specific")
			}
			if got := SameProjectPath(c.a, c.b); got != c.want {
				t.Errorf("SameProjectPath(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
			}
		})
	}
}

func TestNeedsProjectCheck(t *testing.T) {
	// A live discovery file names its own editor, so that route alone is trusted.
	// os.Getpid() stands in for a live editor; a pid that cannot be running models
	// the stale file a crash leaves behind.
	live := &Discovery{Port: 9080, PID: os.Getpid()}
	dead := &Discovery{Port: 9080, PID: -1}

	cases := []struct {
		name string
		res  Resolution
		want bool
	}{
		{"outside any project", Resolution{Source: SourceDefault}, false},
		{"live discovery file", Resolution{Source: SourceDiscovery, Project: "/p", Disc: live}, false},
		{"stale discovery file", Resolution{Source: SourceDiscovery, Project: "/p", Disc: dead}, true},
		{"default fallback", Resolution{Source: SourceDefault, Project: "/p"}, true},
		{"explicit flag", Resolution{Source: SourceFlag, Project: "/p", Disc: live}, true},
		{"env var", Resolution{Source: SourceEnv, Project: "/p", Disc: live}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.res.NeedsProjectCheck(); got != c.want {
				t.Errorf("NeedsProjectCheck() = %v, want %v", got, c.want)
			}
		})
	}
}

func TestProjectMismatchFatal(t *testing.T) {
	// A port the CLI guessed has no intent behind it, so a mismatch there is a bug
	// and must stop the command. An explicitly named port only warns.
	cases := map[PortSource]bool{
		SourceDefault:   true,
		SourceDiscovery: true,
		SourceFlag:      false,
		SourceEnv:       false,
	}
	for src, want := range cases {
		mm := &ProjectMismatch{Port: 9080, Source: src, Expected: "/a", Answering: "/b"}
		if got := mm.Fatal(); got != want {
			t.Errorf("Fatal() for source %q = %v, want %v", src, got, want)
		}
	}
}

func TestResolvePortSource(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte("config_version=5\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Run("no discovery file falls back to the default", func(t *testing.T) {
		t.Setenv("GODOT_MCP_PORT", "")
		got := ResolvePortSource(0, root)
		if got.Port != DefaultPort || got.Source != SourceDefault {
			t.Errorf("got port %d from %q, want %d from %q", got.Port, got.Source, DefaultPort, SourceDefault)
		}
		if got.Project == "" {
			t.Error("project root not resolved; the mismatch check would be skipped")
		}
	})

	if err := os.MkdirAll(filepath.Join(root, ".godot"), 0o755); err != nil {
		t.Fatal(err)
	}
	disc := `{"port":9083,"pid":4242,"project_path":"/p"}`
	if err := os.WriteFile(filepath.Join(root, ".godot", "godot-mcp.json"), []byte(disc), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Run("discovery file wins over the default", func(t *testing.T) {
		t.Setenv("GODOT_MCP_PORT", "")
		got := ResolvePortSource(0, root)
		if got.Port != 9083 || got.Source != SourceDiscovery {
			t.Errorf("got port %d from %q, want 9083 from %q", got.Port, got.Source, SourceDiscovery)
		}
	})

	t.Run("env wins over the discovery file", func(t *testing.T) {
		t.Setenv("GODOT_MCP_PORT", "9090")
		got := ResolvePortSource(0, root)
		if got.Port != 9090 || got.Source != SourceEnv {
			t.Errorf("got port %d from %q, want 9090 from %q", got.Port, got.Source, SourceEnv)
		}
		if got.Disc == nil {
			t.Error("discovery file not read; NeedsProjectCheck could not see a stale pid")
		}
	})

	t.Run("flag wins over everything", func(t *testing.T) {
		t.Setenv("GODOT_MCP_PORT", "9090")
		got := ResolvePortSource(9099, root)
		if got.Port != 9099 || got.Source != SourceFlag {
			t.Errorf("got port %d from %q, want 9099 from %q", got.Port, got.Source, SourceFlag)
		}
	})
}
