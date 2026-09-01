package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testFixtureLog is one real run's merged engine output, captured verbatim from
// project/.godot/godot-mcp-test.log on Godot 4.7.2: a file that does not parse,
// a file whose methods pass, fail an assertion and raise a script error, and a
// project print() landing inside a span. Everything the parser has to survive is
// in here, so it is kept as the engine wrote it rather than trimmed.
const testFixtureLog = `Godot Engine v4.7.2.rc.custom_build.36a04fe52 (2026-07-30 23:59:26 UTC) - https://godotengine.org

##GDMCP-TEST## load res://test/broken_test.gd
SCRIPT ERROR: Parse Error: Expected end of statement after expression, found "Identifier" instead.
   at: GDScript::reload (res://test/broken_test.gd:4)
   GDScript backtrace (most recent call first):
       [0] _run_file (res://.godot/godot-mcp-test-runner.gd:60)
       [1] _initialize (res://.godot/godot-mcp-test-runner.gd:46)
ERROR: Failed to load script "res://test/broken_test.gd" with error "Parse error".
   at: ResourceFormatLoaderGDScript::load (modules\gdscript\gdscript_resource_format.cpp:46)
   GDScript backtrace (most recent call first):
       [0] _run_file (res://.godot/godot-mcp-test-runner.gd:60)
       [1] _initialize (res://.godot/godot-mcp-test-runner.gd:46)
##GDMCP-TEST## idle
##GDMCP-TEST## load res://test/math_test.gd
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/math_test.gd test_addition
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/math_test.gd test_clamp_is_inclusive
math_test: checking clamp
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/math_test.gd test_deliberate_failure
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/math_test.gd test_no_harness
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/math_test.gd test_runtime_error
SCRIPT ERROR: Invalid access to property or key 'missing_key' on a base object of type 'Nil'.
   at: test_runtime_error (res://test/math_test.gd:17)
   GDScript backtrace (most recent call first):
       [0] test_runtime_error (res://test/math_test.gd:17)
       [1] _run_file (res://.godot/godot-mcp-test-runner.gd:86)
       [2] _initialize (res://.godot/godot-mcp-test-runner.gd:46)
##GDMCP-TEST## idle
##GDMCP-TEST## load res://test/migration_test.gd
##GDMCP-TEST## idle
##GDMCP-TEST## test res://test/migration_test.gd test_v1_to_v2
##GDMCP-TEST## idle
##GDMCP-TEST-RESULT##{"files":[{"error":"res://test/broken_test.gd did not compile","loaded":false,"path":"res://test/broken_test.gd","tests":[]},{"error":"","loaded":true,"path":"res://test/math_test.gd","tests":[{"duration_ms":0.004,"failures":[],"name":"test_addition","ok":true},{"duration_ms":0.509,"failures":[],"name":"test_clamp_is_inclusive","ok":true},{"duration_ms":0.019,"failures":["this one should fail: expected 5 (int), got 4 (int)","and so should this"],"name":"test_deliberate_failure","ok":false},{"duration_ms":0.001,"failures":[],"name":"test_no_harness","ok":true},{"duration_ms":1.554,"failures":[],"name":"test_runtime_error","ok":true}]},{"error":"","loaded":true,"path":"res://test/migration_test.gd","tests":[{"duration_ms":0.014,"failures":[],"name":"test_v1_to_v2","ok":true}]}]}
`

// testFixtureNoReport is a run whose generated runner itself failed to parse,
// captured while developing it. Nothing marks a span, so every diagnostic lands
// under the empty key and there is no report at all.
const testFixtureNoReport = `Godot Engine v4.7.2.rc.custom_build.36a04fe52 (2026-07-30 23:59:26 UTC) - https://godotengine.org

SCRIPT ERROR: Parse Error: Cannot find member "exit_code" in base "OS".
   at: GDScript::reload (res://.godot/godot-mcp-test-runner.gd:50)
ERROR: Failed to load script "res://.godot/godot-mcp-test-runner.gd" with error "Parse error".
   at: ResourceFormatLoaderGDScript::load (modules\gdscript\gdscript_resource_format.cpp:46)
`

// testTargetProject lays out a project with a file in each place the walker has
// a rule about, and returns its root.
func testTargetProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := []string{
		"project.godot",
		"test/math_test.gd",
		"test/test_migration.gd",
		"test/helpers/fixtures.gd",
		"test/helpers/deep_test.gd",
		"test/README.md",
		"scripts/player.gd",
		"addons/godot_mcp/thing_test.gd",
		".godot/imported/cached_test.gd",
	}
	for _, f := range files {
		p := filepath.Join(root, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("extends RefCounted\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// Both naming conventions count, the walk is recursive, and the two directories
// that are never the caller's own tests stay out of it.
func TestCollectTestFilesConventions(t *testing.T) {
	root := testTargetProject(t)
	got, err := collectTestFiles(root, []string{filepath.Join(root, "test")})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"res://test/helpers/deep_test.gd",
		"res://test/math_test.gd",
		"res://test/test_migration.gd",
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectTestFiles(test/) = %v, want %v", got, want)
	}

	// A sweep of the whole project keeps the same rules and finds nothing in
	// scripts/, which holds no test files.
	got, err = collectTestFiles(root, []string{root})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectTestFiles(root) = %v, want %v", got, want)
	}
}

// Naming a path inside addons is the opt-in, exactly as check treats it.
func TestCollectTestFilesAddonsWhenNamed(t *testing.T) {
	root := testTargetProject(t)
	got, err := collectTestFiles(root, []string{filepath.Join(root, "addons")})
	if err != nil {
		t.Fatal(err)
	}
	if want := "res://addons/godot_mcp/thing_test.gd"; strings.Join(got, ",") != want {
		t.Errorf("collectTestFiles(addons) = %v, want %v", got, want)
	}
}

// Naming a file is the statement that it is a test, whatever it is called, and
// the same file reached twice is still one file to run.
func TestCollectTestFilesExplicit(t *testing.T) {
	root := testTargetProject(t)
	got, err := collectTestFiles(root, []string{
		filepath.Join(root, "scripts", "player.gd"),
		"res://test/math_test.gd",
		filepath.Join(root, "test", "math_test.gd"),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"res://scripts/player.gd", "res://test/math_test.gd"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("collectTestFiles(files) = %v, want %v", got, want)
	}
}

// A named path that is not GDScript, or is not there at all, is a mistake worth
// reporting rather than a silent no-op that reads as a clean run.
func TestCollectTestFilesRejectsNonScript(t *testing.T) {
	root := testTargetProject(t)
	if _, err := collectTestFiles(root, []string{filepath.Join(root, "test", "README.md")}); err == nil {
		t.Error("collectTestFiles accepted a .md file")
	}
	if _, err := collectTestFiles(root, []string{filepath.Join(root, "no", "such", "dir")}); err == nil {
		t.Error("collectTestFiles accepted a path that does not exist")
	}
}

func TestIsTestScript(t *testing.T) {
	cases := map[string]bool{
		"math_test.gd":      true,
		"test_migration.gd": true,
		"Math_Test.GD":      true,
		"player.gd":         false,
		"testing.gd":        false,
		"test.gd":           false,
		"contest.gd":        false,
		"math_test.tscn":    false,
		"math_test":         false,
	}
	for name, want := range cases {
		if got := isTestScript(name); got != want {
			t.Errorf("isTestScript(%q) = %v, want %v", name, got, want)
		}
	}
}

// ++ is what separates the engine's own arguments from the ones the runner reads
// back with OS.get_cmdline_user_args(), so the file list has to sit after it.
func TestTestArgs(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "p")
	got := testArgs(root, "res://.godot/godot-mcp-test-runner.gd", []string{"res://test/a_test.gd", "res://test/b_test.gd"})
	want := []string{
		"--headless", "--path", root,
		"--script", "res://.godot/godot-mcp-test-runner.gd",
		"++", "res://test/a_test.gd", "res://test/b_test.gd",
	}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("testArgs = %v, want %v", got, want)
	}
}

// The report line is found wherever it lands in the stream, and each diagnostic
// is filed under the span it was printed inside, with the project's own print()
// output and the engine banner ignored.
func TestReadTestLog(t *testing.T) {
	report, spans, err := readTestLog(strings.NewReader(testFixtureLog))
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Files) != 3 {
		t.Fatalf("report has %d files, want 3", len(report.Files))
	}
	if report.Files[1].Path != "res://test/math_test.gd" || len(report.Files[1].Tests) != 5 {
		t.Errorf("second file = %+v, want math_test.gd with 5 tests", report.Files[1])
	}
	if got := report.Files[1].Tests[2].Failures; len(got) != 2 {
		t.Errorf("test_deliberate_failure failures = %v, want 2", got)
	}

	load := spans["load res://test/broken_test.gd"]
	if len(load) != 2 {
		t.Fatalf("broken_test load span = %v, want the parse error and the load error", load)
	}
	if load[0].File != "res://test/broken_test.gd" || load[0].Line != 4 {
		t.Errorf("parse error located at %s:%d, want res://test/broken_test.gd:4", load[0].File, load[0].Line)
	}

	run := spans["res://test/math_test.gd::test_runtime_error"]
	if len(run) != 1 || !strings.Contains(run[0].Message, "missing_key") {
		t.Fatalf("test_runtime_error span = %v, want the one script error", run)
	}

	// The banner and a project print() belong to no test.
	for key, entries := range spans {
		if key == "" && len(entries) > 0 {
			t.Errorf("unmarked output produced diagnostics: %v", entries)
		}
	}
	if _, ok := spans["res://test/math_test.gd::test_clamp_is_inclusive"]; ok {
		t.Error("a project print() inside a span was read as a diagnostic")
	}
}

// A runner that never reported is an environment failure, not a test failure,
// and whatever the engine printed still has to come back so the cause is visible.
func TestReadTestLogNoReport(t *testing.T) {
	report, spans, err := readTestLog(strings.NewReader(testFixtureNoReport))
	if err == nil {
		t.Fatal("readTestLog accepted a log with no report line")
	}
	if report != nil {
		t.Errorf("report = %+v, want nil", report)
	}
	if len(spans[""]) != 2 {
		t.Errorf("unmarked diagnostics = %v, want the parse error and the load error", spans[""])
	}
}

// The merge is what turns the runner's verdicts into the reported result: a
// script error the harness could not see fails its test, a file that never ran
// fails as a file, and the order is the order the files were asked for.
func TestMergeTestReport(t *testing.T) {
	report, spans, err := readTestLog(strings.NewReader(testFixtureLog))
	if err != nil {
		t.Fatal(err)
	}
	requested := []string{
		"res://test/broken_test.gd",
		"res://test/math_test.gd",
		"res://test/migration_test.gd",
	}
	got := mergeTestReport(requested, report, spans)
	if len(got) != 3 {
		t.Fatalf("merged %d files, want 3", len(got))
	}
	for i, f := range got {
		if f.Path != requested[i] {
			t.Fatalf("file %d = %s, want %s", i, f.Path, requested[i])
		}
	}

	broken := got[0]
	if broken.OK || broken.Loaded || broken.Error == "" || len(broken.Errors) != 2 {
		t.Errorf("broken_test = %+v, want a failed unloaded file carrying both engine errors", broken)
	}

	math := got[1]
	if math.OK {
		t.Error("math_test passed, want failed")
	}
	byName := map[string]testCase{}
	for _, tc := range math.Tests {
		byName[tc.Name] = tc
	}
	// The runner reported this one as ok: the script error aborted the call
	// before any assertion ran, so only the log knows it failed.
	if tc := byName["test_runtime_error"]; tc.OK || len(tc.Errors) != 1 {
		t.Errorf("test_runtime_error = %+v, want failed with one engine error", tc)
	}
	if tc := byName["test_deliberate_failure"]; tc.OK || len(tc.Failures) != 2 {
		t.Errorf("test_deliberate_failure = %+v, want failed with two harness messages", tc)
	}
	if tc := byName["test_clamp_is_inclusive"]; !tc.OK || len(tc.Errors) != 0 {
		t.Errorf("test_clamp_is_inclusive = %+v, want a clean pass", tc)
	}

	if !got[2].OK || len(got[2].Tests) != 1 {
		t.Errorf("migration_test = %+v, want one passing test", got[2])
	}
}

// A file the runner never reached must show up as a failure. Silently dropping
// it would report a green run over fewer tests than were asked for.
func TestMergeTestReportMissingFile(t *testing.T) {
	report, spans, err := readTestLog(strings.NewReader(testFixtureLog))
	if err != nil {
		t.Fatal(err)
	}
	got := mergeTestReport([]string{"res://test/never_ran_test.gd"}, report, spans)
	if len(got) != 1 {
		t.Fatalf("merged %d files, want 1", len(got))
	}
	if got[0].OK || got[0].Error == "" {
		t.Errorf("missing file = %+v, want a failure naming the gap", got[0])
	}
}
