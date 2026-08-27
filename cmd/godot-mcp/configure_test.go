package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkProject creates a minimal Godot project dir (just enough for FindProjectRoot).
func mkProject(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "project.godot"), []byte("config_version=5\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// quiet runs fn with stdout/stderr swapped to a temp file, returning what was
// written. runConfigure reports through both, and a test run should not spray
// them across the suite's output.
func quiet(t *testing.T, fn func() int) (int, string) {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = f, f
	rc := fn()
	os.Stdout, os.Stderr = oldOut, oldErr

	data, rerr := os.ReadFile(f.Name())
	if rerr != nil {
		t.Fatal(rerr)
	}
	return rc, string(data)
}

// serveArgs pulls the generated `serve --project <dir>` target out of a written
// JSON client config, so tests assert on what the client will actually launch.
func serveArgs(t *testing.T, path, parentKey, name string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]map[string]struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	if err := json.Unmarshal(data, &root); err != nil {
		t.Fatalf("config at %s is not valid JSON: %v", path, err)
	}
	entry, ok := root[parentKey][name]
	if !ok {
		t.Fatalf("no %q entry under %q in %s", name, parentKey, path)
	}
	return entry.Args
}

// A dir in no Godot project must not produce a config at all. Writing one is the
// real failure: serve cannot resolve a project root from it, so it falls back to
// the default port with the wrong-editor check disabled.
func TestConfigureRefusesNonProject(t *testing.T) {
	dir := t.TempDir()
	rc, _ := quiet(t, func() int {
		return runConfigure([]string{"claude", "--project", dir})
	})
	if rc == 0 {
		t.Fatal("configure accepted a dir with no project.godot")
	}
	if pathExists(filepath.Join(dir, ".mcp.json")) {
		t.Error("a config was written for a non-project dir")
	}
}

// The natural mistake is pointing --project at a repo root whose Godot project is
// one level down. The refusal has to name the fix, not just say no.
func TestConfigureSuggestsNestedProject(t *testing.T) {
	root := t.TempDir()
	mkProject(t, filepath.Join(root, "project"))

	rc, out := quiet(t, func() int {
		return runConfigure([]string{"claude", "--project", root})
	})
	if rc == 0 {
		t.Fatal("configure accepted a repo root that is not itself a project")
	}
	if !strings.Contains(out, "--config-dir") || !strings.Contains(out, filepath.Join(root, "project")) {
		t.Errorf("refusal did not suggest the nested project and --config-dir; got:\n%s", out)
	}
}

// FindProjectRoot walks up, so a subdirectory resolves to the project root and
// serve is pointed there rather than at the subdirectory.
func TestConfigureResolvesUpwardFromSubdir(t *testing.T) {
	proj := mkProject(t, filepath.Join(t.TempDir(), "game"))
	sub := filepath.Join(proj, "scenes", "levels")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}

	rc, out := quiet(t, func() int {
		return runConfigure([]string{"claude", "--project", sub})
	})
	if rc != 0 {
		t.Fatalf("rc = %d, want 0; output:\n%s", rc, out)
	}
	args := serveArgs(t, filepath.Join(proj, ".mcp.json"), "mcpServers", "godot-mcp")
	if got := args[len(args)-1]; got != proj {
		t.Errorf("serve --project = %q, want the project root %q", got, proj)
	}
}

// The point of --config-dir: the config lands where the client reads it while
// serve still drives the nested project.
func TestConfigureConfigDirSplitsLocationFromTarget(t *testing.T) {
	repo := t.TempDir()
	proj := mkProject(t, filepath.Join(repo, "project"))

	cases := []struct {
		client string
		rel    string
		key    string
	}{
		{"claude", ".mcp.json", "mcpServers"},
		{"cursor", filepath.Join(".cursor", "mcp.json"), "mcpServers"},
		{"vscode", filepath.Join(".vscode", "mcp.json"), "servers"},
	}
	for _, tc := range cases {
		t.Run(tc.client, func(t *testing.T) {
			rc, out := quiet(t, func() int {
				return runConfigure([]string{tc.client, "--project", proj, "--config-dir", repo})
			})
			if rc != 0 {
				t.Fatalf("rc = %d, want 0; output:\n%s", rc, out)
			}
			written := filepath.Join(repo, tc.rel)
			if !pathExists(written) {
				t.Fatalf("no config at %s", written)
			}
			if pathExists(filepath.Join(proj, tc.rel)) {
				t.Errorf("config also written into the project dir at %s", filepath.Join(proj, tc.rel))
			}
			args := serveArgs(t, written, tc.key, "godot-mcp")
			if got := args[len(args)-1]; got != proj {
				t.Errorf("serve --project = %q, want %q", got, proj)
			}
		})
	}
}

// --config-dir has no meaning where the path is fixed by the client.
func TestConfigureConfigDirRejectedWhereMeaningless(t *testing.T) {
	repo := t.TempDir()
	proj := mkProject(t, filepath.Join(repo, "project"))

	t.Run("with --global", func(t *testing.T) {
		rc, _ := quiet(t, func() int {
			return runConfigure([]string{"cursor", "--project", proj, "--config-dir", repo, "--global"})
		})
		if rc == 0 {
			t.Error("--config-dir was accepted alongside --global")
		}
	})

	t.Run("with codex", func(t *testing.T) {
		rc, _ := quiet(t, func() int {
			return runConfigure([]string{"codex", "--project", proj, "--config-dir", repo, "--global"})
		})
		if rc == 0 {
			t.Error("--config-dir was accepted for the global-only codex client")
		}
	})
}

// A typo must not become a new directory tree holding a config nothing reads.
func TestConfigureConfigDirMustExist(t *testing.T) {
	repo := t.TempDir()
	proj := mkProject(t, filepath.Join(repo, "project"))
	typo := filepath.Join(repo, "typo")

	rc, _ := quiet(t, func() int {
		return runConfigure([]string{"claude", "--project", proj, "--config-dir", typo})
	})
	if rc == 0 {
		t.Error("configure accepted a --config-dir that does not exist")
	}
	if pathExists(typo) {
		t.Errorf("%s was created for a nonexistent --config-dir", typo)
	}
}

func TestNestedProjects(t *testing.T) {
	root := t.TempDir()
	mkProject(t, filepath.Join(root, "project"))
	mkProject(t, filepath.Join(root, "another"))
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Hidden dirs are skipped: .godot and friends are never the target.
	mkProject(t, filepath.Join(root, ".hidden"))

	got := nestedProjects(root)
	want := []string{filepath.Join(root, "another"), filepath.Join(root, "project")}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("got %v, want %v", got, want)
			break
		}
	}
}
