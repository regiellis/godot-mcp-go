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
