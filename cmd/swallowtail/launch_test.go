package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// The verdict decides the move, and `running` is the one that must never spawn:
// a second editor on the same project breaks discovery for every client. The
// other three are the launch policy the skill teaches, in table form.
func TestDecideLaunch(t *testing.T) {
	cases := []struct {
		verdict client.Verdict
		want    launchAction
	}{
		{client.VerdictRunning, actionRefuse},
		{client.VerdictStarting, actionWait},
		{client.VerdictCrashed, actionSpawn},
		{client.VerdictClosed, actionSpawn},
		{client.Verdict("nonsense"), actionRefuse},
	}
	for _, c := range cases {
		got, reason := decideLaunch(client.Status{Verdict: c.verdict, Port: 9080, PID: 4242})
		if got != c.want {
			t.Errorf("decideLaunch(%s) = %v, want %v", c.verdict, got, c.want)
		}
		if reason == "" {
			t.Errorf("decideLaunch(%s) returned no reason line", c.verdict)
		}
	}
}

// A running editor reports the port it is on, since that is what the caller
// needs to know it is talking to the right one.
func TestDecideLaunchRefusalNamesThePort(t *testing.T) {
	_, reason := decideLaunch(client.Status{Verdict: client.VerdictRunning, Port: 9083})
	if !strings.Contains(reason, "already running") || !strings.Contains(reason, "9083") {
		t.Errorf("refusal reason = %q, want it to name the running editor and port 9083", reason)
	}
}

// The child is anchored on the project root with --path, which is what makes
// the addon bind for this project rather than whatever the binary last opened.
func TestEditorArgs(t *testing.T) {
	root := filepath.Join("C:", "games", "myproject")
	got := editorArgs(root, false)
	want := []string{"--path", root, "--editor"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("editorArgs(headless=false) = %v, want %v", got, want)
	}
	got = editorArgs(root, true)
	want = append(want, "--headless")
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("editorArgs(headless=true) = %v, want %v", got, want)
	}
}

// An explicit --godot wins over PATH, and an unrunnable one is an error rather
// than a silent fall back to whichever godot happens to be installed.
func TestResolveGodotBinaryOverride(t *testing.T) {
	dir := t.TempDir()
	name := "fakegodot"
	if runtime.GOOS == "windows" {
		name += ".cmd"
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("exit 0\n"), 0o755); err != nil {
		t.Fatalf("writing the stub: %v", err)
	}

	got, err := resolveGodotBinary(path)
	if err != nil {
		t.Fatalf("resolveGodotBinary(%q) errored: %v", path, err)
	}
	if got != path {
		t.Errorf("resolveGodotBinary(%q) = %q, want the path as given", path, got)
	}

	missing := filepath.Join(dir, "no-such-binary")
	if _, err := resolveGodotBinary(missing); err == nil {
		t.Errorf("resolveGodotBinary(%q) succeeded, want an error naming the flag", missing)
	}
}

// With no override the lookup goes to PATH, and "godot-dev" is never a
// candidate: that slot tracks engine master while work here targets stable.
func TestResolveGodotBinaryPathLookup(t *testing.T) {
	dir := t.TempDir()
	name := "godot"
	if runtime.GOOS == "windows" {
		name += ".cmd"
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("exit 0\n"), 0o755); err != nil {
		t.Fatalf("writing the stub: %v", err)
	}
	// A dev-slot binary alongside it must not be picked up.
	devName := "godot-dev"
	if runtime.GOOS == "windows" {
		devName += ".cmd"
	}
	if err := os.WriteFile(filepath.Join(dir, devName), []byte("exit 0\n"), 0o755); err != nil {
		t.Fatalf("writing the dev stub: %v", err)
	}
	t.Setenv("PATH", dir)

	got, err := resolveGodotBinary("")
	if err != nil {
		t.Fatalf("resolveGodotBinary(\"\") errored: %v", err)
	}
	if filepath.Base(got) != name {
		t.Errorf("resolveGodotBinary(\"\") = %q, want the %s on PATH", got, name)
	}
}

// Nothing on PATH is a clear refusal naming the flag, not a spawn attempt.
func TestResolveGodotBinaryMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	_, err := resolveGodotBinary("")
	if err == nil {
		t.Fatal("resolveGodotBinary(\"\") succeeded with an empty PATH")
	}
	if !strings.Contains(err.Error(), "--godot") {
		t.Errorf("error = %q, want it to name the --godot flag", err)
	}
}
