package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// Phase 1. Nothing here opens an editor, because opening one is the step that
// starts rewriting the project: it resaves scenes as it touches them and
// rewrites project.godot. Everything preflight reads has to be read before that.

// preflightCheck is one cold parse sweep: which binary ran it, what it calls
// itself, and how many scripts failed under it.
type preflightCheck struct {
	Binary  string      `json:"binary"`
	Version string      `json:"version"`
	Total   int         `json:"total"`
	Failed  int         `json:"failed"`
	Files   []checkFile `json:"files,omitempty"`
}

// csharpState is what a C# project needs answered before the port starts. The
// SDK version in the csproj has to match the engine, and binary compatibility
// is not held across minors, so a full rebuild is required rather than optional.
type csharpState struct {
	Projects   []string `json:"projects"`
	SDKVersion string   `json:"sdk_version,omitempty"`
}

// preflightReport is .godot/upgrade/preflight.json.
type preflightReport struct {
	Phase           string                    `json:"phase"`
	GeneratedUnix   int64                     `json:"generated_unix"`
	ProjectPath     string                    `json:"project_path"`
	ConfigVersion   string                    `json:"config_version"`
	Features        string                    `json:"features"`
	CSharp          csharpState               `json:"csharp"`
	GDExtensions    []gdextFile               `json:"gdextensions"`
	TileMapNodes    []tileMapNode             `json:"tilemap_nodes"`
	Checks          []preflightCheck          `json:"checks"`
	GitHead         string                    `json:"git_head"`
	WarningsCommit  string                    `json:"warnings_commit,omitempty"`
	WarningSettings []string                  `json:"warning_settings"`
	WarningsApplied map[string]string         `json:"warnings_applied"`
	WarningsBefore  map[string]string         `json:"warnings_before"`
	Sources         []sourceSummary           `json:"sources"`
	Counts          map[string]int            `json:"counts"`
	Files           map[string]map[string]int `json:"files_by_category"`
	Findings        []upgradeFinding          `json:"findings"`
}

// sdkVersionRe pulls the Godot.NET.Sdk version out of a csproj's Sdk attribute.
var sdkVersionRe = regexp.MustCompile(`Godot\.NET\.Sdk/([0-9][^"'\s]*)`)

// runUpgradePreflight audits the tree cold and leaves one commit behind: every
// GDScript warning forced to warn, so the first open reports what it otherwise
// would not. verify reverts that commit as its last step.
func runUpgradePreflight(args []string) int {
	fs := flag.NewFlagSet("upgrade preflight", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	oldGodot := fs.String("old-godot", "", "path to the binary the project was built in, for a cold parse sweep")
	newGodot := fs.String("godot", "", "path to the binary the project is moving to, for a cold parse sweep")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "audit the tree cold, before an editor has ever opened it",
		[]string{"godot-mcp upgrade preflight [--project DIR] [--old-godot PATH] [--godot PATH] [--json]"},
		`Reads the project the way nothing else can once an editor has touched it:
the feature tag and config version, each .gdextension and whether it has a
build for this machine, TileMap nodes still in scenes, the GDScript patterns
the 4.3-to-4.7 range broke, missing .uid sidecars, and every ext_resource path
that no longer exists.

A GDExtension with no build for this platform is a hard refusal. Those binaries
are compiled against a specific engine ABI and only the addon's author can
rebuild them, so nothing further is worth running until that is answered.

With --old-godot or --godot it also runs the cold parse sweep under each, which
is the same check godot-mcp check runs.

It requires a clean tree and ends with one commit setting every
debug/gdscript/warnings key to warn. The parser reads those through a cached
path, so a change made while the editor runs is invisible to it; it has to be
in project.godot before the first launch. godot-mcp upgrade verify reverts that
commit.

Writes `+"`"+upgradeReportDir+"/preflight.json`"+`.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}

	// The GDExtension question comes first: it is the one finding that stops
	// the port outright, and there is no value in reading anything else until
	// it is answered.
	exts, xerr := scanGDExtensions(root)
	if xerr != nil {
		fmt.Fprintf(os.Stderr, "%s reading .gdextension files: %v\n", ui.Err.Fail("error:"), xerr)
		return 2
	}
	var blocked []gdextFile
	for _, e := range exts {
		if !e.HasPlatformBuild {
			blocked = append(blocked, e)
		}
	}
	if len(blocked) > 0 {
		fmt.Fprintf(os.Stderr, "%s %d GDExtension addon(s) have no %s build on disk:\n",
			ui.Err.Fail("error:"), len(blocked), platformToken())
		for _, e := range blocked {
			fmt.Fprintf(os.Stderr, "  %s (compatibility_minimum %s)\n", e.File, orNone(e.CompatibilityMinimum))
			for _, lib := range e.Libraries {
				fmt.Fprintf(os.Stderr, "    %-32s %s\n", lib.Key, lib.Path)
			}
			if len(e.Libraries) == 0 {
				fmt.Fprintln(os.Stderr, "    no [libraries] entries at all")
			}
		}
		fmt.Fprintln(os.Stderr, "Those binaries are compiled against a specific engine ABI and only the addon's")
		fmt.Fprintln(os.Stderr, "author can rebuild them. Get a build for the target, or disable the addon in")
		fmt.Fprintln(os.Stderr, "project.godot, then run preflight again.")
		return 1
	}

	if err := requireCleanTree(root, "upgrade preflight"); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 1
	}

	report := preflightReport{
		Phase:         "preflight",
		GeneratedUnix: time.Now().Unix(),
		ProjectPath:   root,
		GDExtensions:  exts,
	}
	if v, ok := projectSetting(root, "", "config_version"); ok {
		report.ConfigVersion = v
	}
	if v, ok := projectSetting(root, "application", "config/features"); ok {
		report.Features = v
	}
	report.CSharp = scanCSharp(root)

	findings, _, serr := scanScripts(root)
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s scanning scripts: %v\n", ui.Err.Fail("error:"), serr)
		return 2
	}
	uidFindings, uerr := scanUIDSidecars(root)
	if uerr != nil {
		fmt.Fprintf(os.Stderr, "%s scanning .uid sidecars: %v\n", ui.Err.Fail("error:"), uerr)
		return 2
	}
	refFindings, ferr := scanExtResources(root)
	if ferr != nil {
		fmt.Fprintf(os.Stderr, "%s scanning ext_resource paths: %v\n", ui.Err.Fail("error:"), ferr)
		return 2
	}
	tileMaps, terr := scanTileMapNodes(root)
	if terr != nil {
		fmt.Fprintf(os.Stderr, "%s scanning scenes for TileMap nodes: %v\n", ui.Err.Fail("error:"), terr)
		return 2
	}
	report.TileMapNodes = tileMaps
	findings = append(findings, uidFindings...)
	findings = append(findings, refFindings...)
	for _, tm := range tileMaps {
		findings = append(findings, upgradeFinding{
			Category: catTileMap, Source: srcOffline, File: tm.File, Line: tm.Line, Node: tm.Path, Fixable: true,
			Detail: "TileMap has been deprecated since 4.3 in favour of one TileMapLayer per layer",
		})
	}
	for _, e := range exts {
		findings = append(findings, upgradeFinding{
			Category: catGDExtension, Source: srcOffline, File: e.File,
			Detail: "GDExtension addon, compatibility_minimum " + orNone(e.CompatibilityMinimum) +
				"; confirm its author supports the target release before shipping the port",
		})
	}

	// The cold parse sweeps. Two binaries, the same scripts, so a script that
	// fails only under the new one is a real port finding rather than a script
	// that was already broken.
	for _, b := range []struct{ label, path string }{{"old", *oldGodot}, {"new", *newGodot}} {
		if b.path == "" {
			continue
		}
		chk, cerr := coldParseSweep(root, b.path)
		if cerr != nil {
			fmt.Fprintf(os.Stderr, "%s %s binary: %v\n", ui.Err.Fail("error:"), b.label, cerr)
			return 2
		}
		report.Checks = append(report.Checks, chk)
		if b.label == "new" {
			for _, f := range chk.Files {
				for _, e := range f.Errors {
					findings = append(findings, upgradeFinding{
						Category: catScriptError, Source: srcScriptValidate, File: f.Path, Line: e.Line,
						Detail: "cold parse under " + chk.Version + ": " + e.String(),
					})
				}
			}
		}
	}

	sortFindings(findings)
	report.Findings = findings
	report.Counts = countByCategory(findings)
	report.Files = filesByCategory(findings)
	report.Sources = summarizeSources(findings, map[string]string{
		srcOffline:        "the whole tree, read as text before any editor opened it",
		srcRenameSweep:    "the rename table matched against every .gd",
		srcScriptValidate: coldSweepNote(report.Checks),
	})
	if head, herr := gitHead(root); herr == nil {
		report.GitHead = head
	}

	// The warnings commit. It has to land before the first launch, so it is
	// preflight's last act rather than open's first.
	text, terr2 := readProjectFile(root)
	if terr2 != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), terr2)
		return 2
	}
	current := readProjectSettings(text)
	values := warningSettings(current)
	report.WarningSettings = warningSettingKeys(values)
	report.WarningsApplied = values
	// What each key held before, so verify can put it back key by key. A key
	// the project never carried is absent here rather than empty, because
	// removing it and setting it to "" are different repairs.
	report.WarningsBefore = map[string]string{}
	for k := range values {
		if v, ok := current[k]; ok {
			report.WarningsBefore[k] = v
		}
	}
	if werr := writeProjectFile(root, setProjectSettings(text, values)); werr != nil {
		fmt.Fprintf(os.Stderr, "%s writing project.godot: %v\n", ui.Err.Fail("error:"), werr)
		return 2
	}
	if bad := verifyProjectSettings(root, values); len(bad) > 0 {
		_ = writeProjectFile(root, text)
		fmt.Fprintf(os.Stderr, "%s project.godot did not read back with %d of the settings just written; the file was restored\n",
			ui.Err.Fail("error:"), len(bad))
		for _, k := range bad {
			fmt.Fprintln(os.Stderr, "  "+k)
		}
		return 1
	}
	if *newGodot != "" {
		if perr := verifyProjectLoads(root, *newGodot); perr != nil {
			_ = writeProjectFile(root, text)
			fmt.Fprintf(os.Stderr, "%s the edited project.godot no longer loads; the file was restored: %v\n",
				ui.Err.Fail("error:"), perr)
			return 1
		}
	}
	if cerr := gitRun(root, "add", "project.godot"); cerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), cerr)
		return 2
	}
	if cerr := gitRun(root, "commit", "-m", "chore: force GDScript warnings on for the upgrade harvest"); cerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), cerr)
		return 2
	}
	if head, herr := gitHead(root); herr == nil {
		report.WarningsCommit = head
	}

	path, werr := writeUpgradeReport(root, "preflight.json", report)
	if werr != nil {
		fmt.Fprintf(os.Stderr, "%s writing the report: %v\n", ui.Err.Fail("error:"), werr)
		return 2
	}

	rows := [][2]string{
		{"project", root},
		{"config version", orNone(report.ConfigVersion)},
		{"features", orNone(report.Features)},
		{"gdextensions", strconv.Itoa(len(exts))},
		{"findings", strconv.Itoa(len(findings))},
		{"warnings commit", short(report.WarningsCommit)},
		{"report", path},
	}
	for _, c := range report.Checks {
		rows = append(rows, [2]string{"cold parse " + c.Version,
			fmt.Sprintf("%d files, %d failed", c.Total, c.Failed)})
	}
	line := fmt.Sprintf("%d findings across %d categories; warnings forced on in %s",
		len(findings), len(report.Counts), short(report.WarningsCommit))
	emitResult("upgrade preflight", report, *asJSON, line, rows)
	if !*asJSON && ui.IsTerminal(os.Stdout) {
		fmt.Println()
		printTodoTable(report.Counts, report.Files)
		fmt.Println()
		fmt.Println(ui.Out.Dim("Next: godot-mcp upgrade baseline --old-godot <path> [--scenario FILE]"))
	}
	return 0
}

// coldParseSweep runs the same per-file --check-only parse godot-mcp check runs
// and keeps the failures.
func coldParseSweep(root, bin string) (preflightCheck, error) {
	resolved, err := resolveGodotBinary(bin)
	if err != nil {
		return preflightCheck{}, err
	}
	version, verr := godotVersion(resolved)
	if verr != nil {
		return preflightCheck{}, verr
	}
	scripts, cerr := collectScripts(root, []string{root})
	if cerr != nil {
		return preflightCheck{}, cerr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	files, _ := checkScripts(ctx, resolved, root, scripts, 4)
	out := preflightCheck{Binary: resolved, Version: version, Total: len(files)}
	for _, f := range files {
		if !f.OK {
			out.Failed++
			out.Files = append(out.Files, f)
		}
	}
	return out, nil
}

// coldSweepNote describes what the cold parse sweeps covered, for the report's
// source table. A source nobody ran says so rather than reading as clean.
func coldSweepNote(checks []preflightCheck) string {
	if len(checks) == 0 {
		return "not run; pass --old-godot and --godot for the cold parse sweep"
	}
	parts := make([]string, 0, len(checks))
	for _, c := range checks {
		parts = append(parts, fmt.Sprintf("%s: %d files, %d failed", c.Version, c.Total, c.Failed))
	}
	return "cold parse, " + strings.Join(parts, "; ")
}

// verifyProjectLoads proves the edited project.godot still loads, by running
// one cold parse against it under the target binary. The engine reads
// project.godot to resolve res:// at all, so a file it cannot read fails here.
func verifyProjectLoads(root, bin string) error {
	resolved, err := resolveGodotBinary(bin)
	if err != nil {
		return err
	}
	scripts, cerr := collectScripts(root, []string{root})
	if cerr != nil || len(scripts) == 0 {
		// Nothing to parse means nothing to prove with; the settings
		// round-trip above is the whole verification for such a project.
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	f, _ := checkOne(ctx, resolved, root, scripts[0])
	if f.OK {
		return nil
	}
	// A script that was already broken is not evidence about project.godot,
	// so only an error naming the project file counts.
	for _, e := range f.Errors {
		if strings.Contains(strings.ToLower(e.Message), "project.godot") {
			return fmt.Errorf("%s", e.String())
		}
	}
	return nil
}

// scanCSharp reports the project's csproj files and the Godot.NET.Sdk version
// they pin.
func scanCSharp(root string) csharpState {
	out := csharpState{Projects: []string{}}
	entries, err := os.ReadDir(root)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".csproj") {
			continue
		}
		out.Projects = append(out.Projects, e.Name())
		if b, rerr := os.ReadFile(filepath.Join(root, e.Name())); rerr == nil {
			if m := sdkVersionRe.FindStringSubmatch(string(b)); m != nil && out.SDKVersion == "" {
				out.SDKVersion = m[1]
			}
		}
	}
	sort.Strings(out.Projects)
	return out
}

// orNone renders an empty string as a word rather than a gap in a table.
func orNone(s string) string {
	if strings.TrimSpace(s) == "" {
		return "none"
	}
	return s
}

// short abbreviates a commit sha for a summary row.
func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	if sha == "" {
		return "none"
	}
	return sha
}
