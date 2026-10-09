package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/playtest"
)

func TestPlaytestRouting(t *testing.T) {
	for _, tc := range []struct {
		rest  []string
		addon bool
	}{
		{[]string{"start", "--name", "run"}, true},
		{[]string{"mark", "--label", "wave 3"}, true},
		{[]string{"event", "--name", "death"}, true},
		{[]string{"status"}, true},
		{[]string{"stop"}, true},
		{[]string{"report", "session.json"}, false},
		{[]string{"compare", "a.json", "b.json"}, false},
		{[]string{"report", "--latest"}, false},
		{nil, false},
	} {
		if got := routesToAddon("playtest", tc.rest); got != tc.addon {
			t.Errorf("routesToAddon(playtest, %v) = %v, want %v", tc.rest, got, tc.addon)
		}
	}
}

func TestWritePlaytestFileIsAtomicAndReplaces(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "report.md")
	if err := writePlaytestFile(path, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := writePlaytestFile(path, []byte("second")); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "second" {
		t.Fatalf("content = %q, %v", got, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("temp files left behind: %v", names)
	}
	// A destination that cannot be replaced (a directory) fails without
	// leaving a temp file next to it.
	blocker := filepath.Join(dir, "blocked")
	if err := os.MkdirAll(filepath.Join(blocker, "inside"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writePlaytestFile(blocker, []byte("x")); err == nil {
		t.Error("writing over a non-empty directory succeeded")
	}
	entries, _ = os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp-") {
			t.Errorf("failed write left %s", e.Name())
		}
	}
}

// playtestProject builds a project whose user-data dir resolves under a temp
// root, and writes the fixture session there twice with distinct names and
// modification times. It returns the project root and the two session paths,
// older first.
func playtestProject(t *testing.T) (string, string, string) {
	t.Helper()
	data := t.TempDir()
	t.Setenv("APPDATA", data)
	t.Setenv("XDG_DATA_HOME", data)
	t.Setenv("HOME", data)
	root := t.TempDir()
	cfg := "config_version=5\n\n[application]\n\nconfig/name=\"Playtest Fixture\"\n"
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	userDir, err := client.GameUserDataDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(userDir, data) {
		t.Fatalf("user dir %s is not under the temp data root %s", userDir, data)
	}
	sessions := filepath.Join(userDir, playtest.SessionsDir)
	if err := os.MkdirAll(sessions, 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile(filepath.Join("..", "..", "internal", "playtest", "testdata", "session_godot.json"))
	if err != nil {
		t.Fatal(err)
	}
	older := filepath.Join(sessions, "20261008-100000_before.json")
	newer := filepath.Join(sessions, "20261008-110000_after.json")
	for i, p := range []string{older, newer} {
		if err := os.WriteFile(p, fixture, 0o644); err != nil {
			t.Fatal(err)
		}
		mt := time.Now().Add(time.Duration(i-2) * time.Minute)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(sessions, "20261008-120000_half.json.part"), []byte("{"), 0o644)
	return root, older, newer
}

func TestPlaytestLatestResolution(t *testing.T) {
	root, older, newer := playtestProject(t)
	paths, err := latestPlaytestSessions(root)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(paths, []string{newer, older}) {
		t.Fatalf("latest = %v", paths)
	}

	empty := t.TempDir()
	if err := os.WriteFile(filepath.Join(empty, "project.godot"), []byte("[application]\nconfig/name=\"Nothing Recorded\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := latestPlaytestSessions(empty); err == nil || !strings.Contains(err.Error(), "no playtest sessions") {
		t.Errorf("an unrecorded project answered %v", err)
	}
}

func TestPlaytestReportAndCompareLatest(t *testing.T) {
	root, _, newer := playtestProject(t)
	out := filepath.Join(t.TempDir(), "report.json")
	if rc := runPlaytestReport([]string{"--latest", "--project", root, "--format", "json", "--out", out}); rc != 0 {
		t.Fatalf("report rc = %d", rc)
	}
	var rep playtest.Report
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &rep); err != nil {
		t.Fatal(err)
	}
	if rep.Kind != "swallowtail-playtest-report" || rep.Source != newer || rep.Frames.Count != 400 {
		t.Errorf("report = kind %s source %s frames %d", rep.Kind, rep.Source, rep.Frames.Count)
	}

	md := filepath.Join(t.TempDir(), "compare.md")
	if rc := runPlaytestCompare([]string{"--latest", "--project", root, "--out", md}); rc != 0 {
		t.Fatalf("compare rc = %d", rc)
	}
	text, _ := os.ReadFile(md)
	if !strings.Contains(string(text), "Verdict: **unchanged**") {
		t.Errorf("identical sessions should compare unchanged:\n%s", text)
	}

	if rc := runPlaytestCompare([]string{newer, newer}); rc != 2 {
		t.Errorf("comparing a file with itself rc = %d, want 2", rc)
	}
	if rc := runPlaytestReport([]string{"a.json", "b.json"}); rc != 2 {
		t.Errorf("report with two files rc = %d, want 2", rc)
	}
	if rc := runPlaytestReport([]string{newer, "--format", "html"}); rc != 2 {
		t.Errorf("report --format html rc = %d, want 2", rc)
	}
}

func TestPlaytestCompletion(t *testing.T) {
	c := cliCatalog{
		Methods: []string{"playtest.start", "playtest.stop", "playtest.status"},
		Docs:    map[string]commandDoc{"playtest.start": {Params: []paramDoc{{Name: "sample_every"}}}},
	}
	for _, tc := range []struct {
		words []string
		want  string
	}{
		{[]string{"play"}, "playtest"},
		{[]string{"playtest", "rep"}, "report"},
		{[]string{"playtest", "st"}, "stop"},
		{[]string{"playtest", "report", "--lat"}, "--latest"},
		{[]string{"playtest", "compare", "--tar"}, "--target-fps"},
		{[]string{"playtest", "start", "--sam"}, "--sample-every"},
	} {
		if got := completionCandidates(tc.words, c); !slices.Contains(got, tc.want) {
			t.Errorf("completion %v = %v, want %s", tc.words, got, tc.want)
		}
	}
}
