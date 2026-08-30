package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// upgrade is the 4.3-to-4.7 port pipeline. The spec is the craft doc
// skills/godot-mcp/porting-godot-versions.md, section "The upgrade pipeline":
// five phases, each a gate that does its work, writes a report under
// <project>/.godot/upgrade/, and stops. Nothing runs the next phase, because
// every phase ends with something a person should read.
//
// Two rules run through all of it. The harvest reads seven sources rather than
// the editor's error panel, and every finding names the source it came from.
// And a fix applies, proves itself, and then keeps or restores: report-only is
// what the editor already gives you.

// upgradeReportDir is where every phase writes, relative to the project root.
// .godot/ is session-scoped and git-ignored, so a report never lands in the
// port diff a reviewer has to read as one migration.
const upgradeReportDir = ".godot/upgrade"

// The categories a finding is bucketed into. The first six are what fix can
// apply; the rest are report-only and say so in their own findings.
const (
	catRenames      = "renames"
	catExportFile   = "export_file"
	catTypedDict    = "typed_dictionary"
	catTileMap      = "tilemap"
	catSettings     = "settings"
	catUID          = "uid"
	catGDExtension  = "gdextension"
	catMissingRef   = "missing_resource"
	catScriptError  = "script_error"
	catSceneError   = "scene_error"
	catResaveDrop   = "resave_drop"
	catWarning      = "warning"
	catRuntimeError = "runtime_error"
)

// fixableCategories are the mechanical ones, in the order the craft doc lists
// them. Everything else is a report a person has to act on.
var fixableCategories = []string{catRenames, catExportFile, catTypedDict, catTileMap, catSettings, catUID}

// The seven harvest sources, plus the offline scan preflight runs before an
// editor has ever opened the project.
const (
	srcOffline        = "offline_scan"
	srcLaunchLog      = "launch_log"
	srcWarnings       = "warnings"
	srcScriptValidate = "script_validate"
	srcSceneValidate  = "scene_validate"
	srcResaveDiff     = "resave_diff"
	srcRenameSweep    = "rename_sweep"
	srcDrive          = "drive"
)

// upgradeFinding is one thing a harvest source found. Node and Property are
// filled by the sources that can name them (scene validation, the resave diff);
// File and Line by the ones that read text.
type upgradeFinding struct {
	Category string `json:"category"`
	Source   string `json:"source"`
	File     string `json:"file,omitempty"`
	Line     int    `json:"line,omitempty"`
	Node     string `json:"node,omitempty"`
	Property string `json:"property,omitempty"`
	Fixable  bool   `json:"fixable"`
	Detail   string `json:"detail"`
}

// sortFindings orders findings so two runs over an unchanged project produce
// byte-identical reports, which is what makes the delta table readable.
func sortFindings(f []upgradeFinding) {
	sort.SliceStable(f, func(i, j int) bool {
		a, b := f[i], f[j]
		switch {
		case a.Category != b.Category:
			return a.Category < b.Category
		case a.File != b.File:
			return a.File < b.File
		case a.Line != b.Line:
			return a.Line < b.Line
		case a.Node != b.Node:
			return a.Node < b.Node
		case a.Property != b.Property:
			return a.Property < b.Property
		}
		return a.Detail < b.Detail
	})
}

// countByCategory buckets findings for the to-do table.
func countByCategory(findings []upgradeFinding) map[string]int {
	counts := map[string]int{}
	for _, f := range findings {
		counts[f.Category]++
	}
	return counts
}

// filesByCategory reports how many findings each file carries per category,
// which is the form the to-do table needs: one renamed method in thirty
// scripts is one row with thirty behind it, not thirty rows.
func filesByCategory(findings []upgradeFinding) map[string]map[string]int {
	out := map[string]map[string]int{}
	for _, f := range findings {
		if f.File == "" {
			continue
		}
		if out[f.Category] == nil {
			out[f.Category] = map[string]int{}
		}
		out[f.Category][f.File]++
	}
	return out
}

// sourceSummary is one row of "which source found what", so a report can say
// where every finding came from and which sources were not read this phase.
type sourceSummary struct {
	Source string `json:"source"`
	Count  int    `json:"count"`
	Read   bool   `json:"read"`
	Note   string `json:"note,omitempty"`
}

// summarizeSources counts findings per source across the seven the craft doc
// names, keeping a source that produced nothing in the list: "read and found
// nothing" and "not read this phase" are different answers.
func summarizeSources(findings []upgradeFinding, read map[string]string) []sourceSummary {
	order := []string{srcOffline, srcLaunchLog, srcWarnings, srcScriptValidate, srcSceneValidate, srcResaveDiff, srcRenameSweep, srcDrive}
	counts := map[string]int{}
	for _, f := range findings {
		counts[f.Source]++
	}
	out := make([]sourceSummary, 0, len(order))
	for _, s := range order {
		note, wasRead := read[s]
		out = append(out, sourceSummary{Source: s, Count: counts[s], Read: wasRead, Note: note})
	}
	return out
}

// runUpgrade dispatches the phase. Each phase parses its own flags, so the
// shared surface here is only the phase name and the help.
func runUpgrade(args []string) int {
	phases := map[string]func([]string) int{
		"preflight": runUpgradePreflight,
		"baseline":  runUpgradeBaseline,
		"open":      runUpgradeOpen,
		"fix":       runUpgradeFix,
		"verify":    runUpgradeVerify,
	}
	if len(args) == 0 {
		upgradeUsage()
		return 2
	}
	switch args[0] {
	case "help", "--help", "-h":
		upgradeUsage()
		return 0
	}
	phase := strings.ReplaceAll(args[0], "-", "_")
	fn, ok := phases[phase]
	if !ok {
		fmt.Fprintf(os.Stderr, "%s unknown upgrade phase %q\n", ui.Err.Fail("error:"), args[0])
		upgradeUsage()
		return 2
	}
	return fn(args[1:])
}

// upgradeUsage renders the phase table in the same shape as the top-level help.
func upgradeUsage() {
	p := ui.Err
	w := os.Stderr
	fmt.Fprintln(w, p.Heading("godot-mcp upgrade")+": port a 4.3+ project to a newer Godot, one gated phase at a time")
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Usage:"))
	fmt.Fprintln(w, "  "+tintSlots("godot-mcp upgrade <phase> [flags]", p))
	phases := [][2]string{
		{"preflight", "cold audit of the tree, then one commit forcing GDScript warnings on"},
		{"baseline", "record how the game behaves under the old binary"},
		{"open", "tag, branch, open in the new editor, and harvest the seven sources"},
		{"fix", "apply one category, prove it, and keep or restore"},
		{"verify", "replay the baseline, diff it, re-harvest, and revert the warnings commit"},
	}
	nameW := 0
	for _, s := range phases {
		nameW = max(nameW, len(s[0]))
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Phases:"))
	for _, s := range phases {
		fmt.Fprintf(w, "  %s  %s\n", p.Key(padRight(s[0], nameW)), s[1])
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Every phase writes its report under <project>/"+upgradeReportDir+"/ and stops.")
	fmt.Fprintln(w, "Two binaries are required and neither is guessed: --old-godot for the version")
	fmt.Fprintln(w, "the project was built in, --godot for the one it is moving to. Scope is 4.3 and up.")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Per-phase flags: godot-mcp upgrade <phase> --help")
}

// --- git ---------------------------------------------------------------------

// gitOut runs a git command in the project and returns its stdout. Git is a
// hard dependency of this pipeline: the rollback point, the resave diff, and
// every fix's restore are all git, and a project without it cannot be ported
// safely by anything here.
func gitOut(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var errBuf strings.Builder
	cmd.Stderr = &errBuf
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(errBuf.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), msg)
	}
	return string(out), nil
}

// gitRun runs a git command for its effect.
func gitRun(root string, args ...string) error {
	_, err := gitOut(root, args...)
	return err
}

// gitStatus returns the porcelain status, which is empty exactly when the tree
// is clean.
func gitStatus(root string) (string, error) {
	out, err := gitOut(root, "status", "--porcelain")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// requireCleanTree refuses a phase whose rollback point would otherwise be
// ambiguous. Installing the addon or saving a scene before this check turns
// "the tree was clean" into a judgement call, which is the whole reason the
// craft doc puts the check first.
func requireCleanTree(root, phase string) error {
	st, err := gitStatus(root)
	if err != nil {
		return fmt.Errorf("%s needs a git repository at %s: %w", phase, root, err)
	}
	if st != "" {
		return fmt.Errorf("%s needs a clean tree; commit or stash these first:\n%s", phase, st)
	}
	return nil
}

// gitHead returns the current commit sha.
func gitHead(root string) (string, error) {
	out, err := gitOut(root, "rev-parse", "HEAD")
	return strings.TrimSpace(out), err
}

// --- reports -----------------------------------------------------------------

// upgradeReportPath names a report file under the project's report dir.
func upgradeReportPath(root, name string) string {
	return filepath.Join(root, filepath.FromSlash(upgradeReportDir), name)
}

// writeUpgradeReport writes a phase report as indented JSON and returns its
// path. Reports are the pipeline's memory: fix reads open.json's counts, and
// verify reads baseline's numbers and preflight's warnings commit.
func writeUpgradeReport(root, name string, v any) (string, error) {
	path := upgradeReportPath(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// readUpgradeReport loads a report a previous phase wrote.
func readUpgradeReport(root, name string, v any) error {
	b, err := os.ReadFile(upgradeReportPath(root, name))
	if err != nil {
		return fmt.Errorf("%s not found; run the phase that writes it first (%w)", filepath.Join(upgradeReportDir, name), err)
	}
	return json.Unmarshal(b, v)
}

// --- the addon session -------------------------------------------------------

// addonSession is one phase's connection to the running editor. Every call
// resolves the port the way the CLI does and verifies the answering project
// before the first real call, so a phase can never rewrite a sibling project
// that happened to answer on a guessed port.
type addonSession struct {
	root    string
	port    int
	timeout time.Duration
}

// newAddonSession resolves the editor for this project and confirms it is
// serving this project. A mismatch on a guessed port aborts, exactly as the
// <group> <command> path does.
func newAddonSession(root string) (*addonSession, error) {
	res := client.ResolvePortSource(0, root)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if mm := client.CheckProject(ctx, res); mm != nil {
		if mm.Fatal() {
			return nil, fmt.Errorf("%s (port %d came from %s)", mm.Error(), mm.Port, mm.Source)
		}
		fmt.Fprintf(os.Stderr, "%s %s\n", ui.Err.Warn("warning:"), mm.Error())
	}
	return &addonSession{root: root, port: res.Port, timeout: 60 * time.Second}, nil
}

// call sends one command to the editor and returns its raw result.
func (s *addonSession) call(method string, params map[string]any) (json.RawMessage, error) {
	return s.callTimeout(s.timeout, method, params)
}

// callTimeout is call with an explicit deadline, for the commands that
// legitimately run long: a tree-wide script validate, or a drive that awaits
// the running game over the two-hop IPC.
func (s *addonSession) callTimeout(d time.Duration, method string, params map[string]any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	raw, err := client.Call(ctx, s.port, method, params)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	return raw, nil
}

// callInto sends one command and decodes its result into v.
func (s *addonSession) callInto(v any, method string, params map[string]any) error {
	raw, err := s.call(method, params)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, v)
}

// --- shared rendering --------------------------------------------------------

// printTodoTable renders the bucketed counts a person reads before deciding
// what to do next: category, how many findings, in how many files, and whether
// fix can apply it.
func printTodoTable(counts map[string]int, files map[string]map[string]int) {
	if len(counts) == 0 {
		fmt.Println(ui.Out.OK("nothing found"))
		return
	}
	cats := make([]string, 0, len(counts))
	for c := range counts {
		cats = append(cats, c)
	}
	sort.Strings(cats)
	w := 0
	for _, c := range cats {
		w = max(w, len(c))
	}
	fmt.Println(ui.Out.Heading("to do") + " " + ui.Out.Dim("(category, findings, files, fix)"))
	for _, c := range cats {
		applies := "report only"
		if isFixable(c) {
			applies = "godot-mcp upgrade fix --category " + c
		}
		fmt.Printf("  %s  %4d  %3d files  %s\n",
			ui.Out.Key(padRight(c, w)), counts[c], len(files[c]), ui.Out.Dim(applies))
	}
}

// isFixable reports whether a category is one of the mechanical ones fix can
// apply.
func isFixable(category string) bool {
	for _, c := range fixableCategories {
		if c == category {
			return true
		}
	}
	return false
}

// godotVersion asks a binary what it is. The whole pipeline turns on the two
// versions being named rather than assumed, so every report carries the exact
// string each binary printed.
func godotVersion(bin string) (string, error) {
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		return "", fmt.Errorf("%s --version: %w", bin, err)
	}
	// The engine prints a trailing newline and, for a source build, a build
	// hash on the same line.
	return strings.TrimSpace(strings.Split(strings.TrimSpace(string(out)), "\n")[0]), nil
}

// shortVersion reduces a Godot version string to major.minor, which is what
// names the tag and the branch. "4.7.2.rc.custom_build" becomes "4.7".
func shortVersion(v string) string {
	parts := strings.Split(strings.TrimSpace(v), ".")
	if len(parts) < 2 {
		return strings.TrimSpace(v)
	}
	return parts[0] + "." + parts[1]
}

// --- the direct game channel -------------------------------------------------

// gameSession is one drive's connection to a running game's own WebSocket
// server. It serves runtime.* and input.* with no editor in the loop, which is
// what lets baseline and verify run against a binary that has no editor open.
type gameSession struct {
	port    int
	timeout time.Duration
}

// call sends one runtime or input command to the game.
func (g *gameSession) call(method string, params map[string]any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), g.timeout)
	defer cancel()
	raw, err := client.Call(ctx, g.port, method, params)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	return raw, nil
}
