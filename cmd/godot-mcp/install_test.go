package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// resolveAsset anchors its search to the executable, so these exercise the
// override and failure paths directly and cover the layout walk through the
// helper below, which takes the bases as arguments.
func TestResolveAssetOverride(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "custom", "godot_mcp")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "plugin.cfg"), []byte("[plugin]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Run("a valid override wins outright", func(t *testing.T) {
		got, tried := resolveAsset(src, "plugin.cfg", []string{"addons", "godot_mcp"})
		if got != src {
			t.Errorf("got %q, want %q", got, src)
		}
		if len(tried) != 1 || tried[0] != src {
			t.Errorf("tried = %v, want just the override", tried)
		}
	})

	t.Run("a bad override fails and names itself", func(t *testing.T) {
		bad := filepath.Join(dir, "typo")
		got, tried := resolveAsset(bad, "plugin.cfg", []string{"addons", "godot_mcp"})
		if got != "" {
			t.Errorf("got %q, want no resolution", got)
		}
		// The whole point of reporting `tried`: a typo has to appear in the
		// output rather than the user being shown a default they never passed.
		if len(tried) != 1 || tried[0] != bad {
			t.Errorf("tried = %v, want the bad override named", tried)
		}
	})

	t.Run("an override is not second-guessed by the layout search", func(t *testing.T) {
		bad := filepath.Join(dir, "typo")
		_, tried := resolveAsset(bad, "plugin.cfg", []string{"addons", "godot_mcp"})
		for _, p := range tried {
			if strings.Contains(p, "addons") {
				t.Errorf("layout candidate %q searched despite an explicit override", p)
			}
		}
	})
}

func TestResolveAssetReportsEveryCandidate(t *testing.T) {
	// With no override and nothing on disk, resolution fails and must report
	// each path it considered. This is the "binary copied onto PATH alone"
	// case, where naming a single guess is what made the failure confusing.
	got, tried := resolveAsset("", "plugin.cfg",
		[]string{"addons", "godot_mcp"},
		[]string{"project", "addons", "godot_mcp"},
	)
	if got != "" {
		t.Fatalf("got %q, want no resolution in a bare temp environment", got)
	}
	if len(tried) != 4 {
		t.Errorf("tried %d candidates, want 4 (2 layouts x 2 bases): %v", len(tried), tried)
	}
	for _, p := range tried {
		if !filepath.IsAbs(p) {
			t.Errorf("candidate %q is not absolute; the error would be ambiguous", p)
		}
	}
}

func TestCopyDirSkipsDevContextDocs(t *testing.T) {
	// release.ps1 strips CLAUDE.md from every archive; copyDir has to apply the
	// same rule so a source-checkout install does not put the addon's dev context
	// doc into someone's game project.
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	files := map[string]string{
		"plugin.cfg":               "[plugin]\n",
		"CLAUDE.md":                "dev guidance",
		"commands/base_command.gd": "@tool\n",
		"commands/CLAUDE.md":       "nested dev guidance",
		"services/game_input.gd":   "extends Node\n",
		"docs/claude.md":           "lowercase variant",
	}
	for rel, body := range files {
		p := filepath.Join(src, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	skipped, err := copyDir(src, dst)
	if err != nil {
		t.Fatal(err)
	}

	mustExist := []string{"plugin.cfg", "commands/base_command.gd", "services/game_input.gd"}
	for _, rel := range mustExist {
		if !fileExists(filepath.Join(dst, filepath.FromSlash(rel))) {
			t.Errorf("%s was not copied", rel)
		}
	}
	// Nested and differently-cased copies must go too: a case-insensitive
	// filesystem would otherwise ship the same file under another spelling.
	mustNotExist := []string{"CLAUDE.md", "commands/CLAUDE.md", "docs/claude.md"}
	for _, rel := range mustNotExist {
		if fileExists(filepath.Join(dst, filepath.FromSlash(rel))) {
			t.Errorf("%s was copied into the destination", rel)
		}
	}
	if len(skipped) != len(mustNotExist) {
		t.Errorf("skipped %d files, want %d: %v", len(skipped), len(mustNotExist), skipped)
	}
	// Directories that held only a skipped file are still created; that is fine,
	// but the skip must be reported so the install is not silently lossy.
	if len(skipped) == 0 {
		t.Error("nothing reported as skipped; the caller cannot tell the copy was filtered")
	}
}

// writeProject drops a minimal project.godot in a temp dir and returns its path.
func writeProject(t *testing.T, body string) (root, file string) {
	t.Helper()
	root = t.TempDir()
	file = filepath.Join(root, "project.godot")
	if err := os.WriteFile(file, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return root, file
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestEnableAutoloads(t *testing.T) {
	// --enable writes the plugin into project.godot, which fires the addon's
	// _enter_tree but never its _enable_plugin, so nothing injects the two
	// game-side singletons. The installer has to, or runtime/input commands fail
	// in a project the CLI itself just set up.
	const bare = "config_version=5\n\n[application]\n\nconfig/name=\"Demo\"\n"

	t.Run("adds both entries and a section when there is none", func(t *testing.T) {
		root, file := writeProject(t, bare)
		added, conflicts, err := enableAutoloads(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(added) != 2 || len(conflicts) != 0 {
			t.Fatalf("added %v, conflicts %v; want both added and no conflicts", added, conflicts)
		}
		s := readFile(t, file)
		for _, want := range []string{
			"[autoload]",
			`MCPGameInspector="*res://addons/godot_mcp/services/game_inspector.gd"`,
			`MCPGameInput="*res://addons/godot_mcp/services/game_input.gd"`,
			`config/name="Demo"`,
		} {
			if !strings.Contains(s, want) {
				t.Errorf("project.godot is missing %q:\n%s", want, s)
			}
		}
	})

	t.Run("a second run changes nothing", func(t *testing.T) {
		root, file := writeProject(t, bare)
		if _, _, err := enableAutoloads(root); err != nil {
			t.Fatal(err)
		}
		first := readFile(t, file)
		added, conflicts, err := enableAutoloads(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(added) != 0 || len(conflicts) != 0 {
			t.Errorf("second run added %v, conflicts %v; want neither", added, conflicts)
		}
		second := readFile(t, file)
		if second != first {
			t.Errorf("second run rewrote the file:\n--- first ---\n%s\n--- second ---\n%s", first, second)
		}
		if n := strings.Count(second, "MCPGameInspector="); n != 1 {
			t.Errorf("MCPGameInspector appears %d times, want 1", n)
		}
	})

	t.Run("an existing [autoload] section is extended, not replaced", func(t *testing.T) {
		root, file := writeProject(t, "config_version=5\n\n[autoload]\n\nGameState=\"*res://src/game_state.gd\"\n\n[display]\n\nwindow/size/viewport_width=1280\n")
		added, _, err := enableAutoloads(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(added) != 2 {
			t.Fatalf("added %v, want both", added)
		}
		s := readFile(t, file)
		if !strings.Contains(s, `GameState="*res://src/game_state.gd"`) {
			t.Errorf("the project's own autoload was lost:\n%s", s)
		}
		// The new keys have to land inside [autoload], not in the section after it.
		auto := s[strings.Index(s, "[autoload]"):strings.Index(s, "[display]")]
		if !strings.Contains(auto, "MCPGameInspector=") || !strings.Contains(auto, "MCPGameInput=") {
			t.Errorf("entries did not land in the [autoload] section:\n%s", s)
		}
		if !strings.Contains(s, "window/size/viewport_width=1280") {
			t.Errorf("the [display] section was damaged:\n%s", s)
		}
	})

	t.Run("a same-named foreign entry is reported, never overwritten", func(t *testing.T) {
		root, file := writeProject(t, "config_version=5\n\n[autoload]\n\nMCPGameInput=\"*res://src/my_input.gd\"\n")
		added, conflicts, err := enableAutoloads(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(added) != 1 || added[0] != "MCPGameInspector" {
			t.Errorf("added %v, want just MCPGameInspector", added)
		}
		if len(conflicts) != 1 || !strings.Contains(conflicts[0], "MCPGameInput") {
			t.Fatalf("conflicts %v, want the foreign MCPGameInput named", conflicts)
		}
		s := readFile(t, file)
		if !strings.Contains(s, `MCPGameInput="*res://src/my_input.gd"`) {
			t.Errorf("the user's autoload was overwritten:\n%s", s)
		}
		if strings.Contains(s, "game_input.gd") {
			t.Errorf("the addon's script was written over a user-owned name:\n%s", s)
		}
	})

	t.Run("an entry without the star prefix still counts as ours", func(t *testing.T) {
		root, _ := writeProject(t, "config_version=5\n\n[autoload]\n\nMCPGameInspector=\"res://addons/godot_mcp/services/game_inspector.gd\"\n")
		added, conflicts, err := enableAutoloads(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(conflicts) != 0 {
			t.Errorf("conflicts %v; an entry pointing at our own script is ours", conflicts)
		}
		if len(added) != 1 || added[0] != "MCPGameInput" {
			t.Errorf("added %v, want just MCPGameInput", added)
		}
	})
}

func TestSectionBounds(t *testing.T) {
	lines := strings.Split("config_version=5\n\n[autoload]\n\nA=\"1\"\n\n[display]\n\nB=\"2\"\n", "\n")
	start, end := sectionBounds(lines, "autoload")
	if start < 0 {
		t.Fatal("[autoload] not found")
	}
	body := strings.Join(lines[start:end], "\n")
	if !strings.Contains(body, `A="1"`) || strings.Contains(body, `B="2"`) {
		t.Errorf("body spans the wrong lines: %q", body)
	}
	if s, e := sectionBounds(lines, "input"); s != -1 || e != -1 {
		t.Errorf("absent section reported as (%d, %d), want (-1, -1)", s, e)
	}
}

func TestSamePath(t *testing.T) {
	// Guards the source-onto-destination copy that a cwd-based search could
	// otherwise set up.
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"identical", "/a/b", "/a/b", true},
		{"trailing separator", "/a/b/", "/a/b", true},
		{"dot segment", "/a/./b", "/a/b", true},
		{"different", "/a/b", "/a/c", false},
		{"prefix is not a match", "/a/bb", "/a/b", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := samePath(c.a, c.b); got != c.want {
				t.Errorf("samePath(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
			}
		})
	}
}
