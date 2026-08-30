package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// Phase 3. The rollback point has to exist before the first launch, because
// opening in the new editor is what starts rewriting the project. So the tag
// and the branch come first, then exactly one editor, then the harvest.

// catEngineError buckets a diagnostic the engine printed that names no project
// file, which is most of what a first reimport floods the log with.
const catEngineError = "engine_error"

// openReport is .godot/upgrade/open.json. fix reads its counts to know what a
// category started at, and verify re-runs the same harvest to diff against it.
type openReport struct {
	Phase         string                    `json:"phase"`
	GeneratedUnix int64                     `json:"generated_unix"`
	ProjectPath   string                    `json:"project_path"`
	GodotVersion  string                    `json:"godot_version"`
	TargetVersion string                    `json:"target_version"`
	Tag           string                    `json:"tag"`
	Branch        string                    `json:"branch"`
	EditorPort    int                       `json:"editor_port"`
	LaunchLog     string                    `json:"launch_log"`
	Scenes        []string                  `json:"scenes"`
	ResaveCommit  string                    `json:"resave_commit,omitempty"`
	SettleRounds  int                       `json:"settle_rounds"`
	Sources       []sourceSummary           `json:"sources"`
	Counts        map[string]int            `json:"counts"`
	Files         map[string]map[string]int `json:"files_by_category"`
	Findings      []upgradeFinding          `json:"findings"`
}

// runUpgradeOpen tags, branches, opens the project in the new editor, and
// harvests every source the craft doc names.
func runUpgradeOpen(args []string) int {
	fs := flag.NewFlagSet("upgrade open", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	newGodot := fs.String("godot", "", "path to the binary the project is moving to (required)")
	timeout := fs.Duration("timeout", 10*time.Minute, "how long to wait for the editor and the reimport")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "tag, branch, open in the new editor, and harvest the to-do list",
		[]string{"godot-mcp upgrade open --godot PATH [--project DIR] [--timeout 10m] [--json]"},
		`Refuses on a dirty tree, tags the tree as it stands, branches, then launches
exactly one headless editor and waits for the reimport to settle: successive
editor reloads until the error count comes back the same twice, because a scan
in progress reports failures that resolve themselves.

Then it reads all seven sources and buckets what they found by category. It
opens, validates and saves every scene, which is the deliberate resave pass, and
diffs the result to report each property the new version dropped. That diff is
the only place a silent drop shows up. The resave lands as its own commit so a
later fix has a well-defined thing to restore to.

Writes `+"`"+upgradeReportDir+"/open.json`"+` and prints the to-do table.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}
	if *newGodot == "" {
		fmt.Fprintf(os.Stderr, "%s upgrade open needs --godot: the binary the project is moving to is never guessed\n", ui.Err.Fail("error:"))
		return 2
	}
	if err := requireCleanTree(root, "upgrade open"); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 1
	}
	bin, berr := resolveGodotBinary(*newGodot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}
	version, verr := godotVersion(bin)
	if verr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), verr)
		return 2
	}
	target := shortVersion(version)

	report := openReport{
		Phase:         "open",
		GeneratedUnix: time.Now().Unix(),
		ProjectPath:   root,
		GodotVersion:  version,
		TargetVersion: target,
		Tag:           "pre-" + target + "-upgrade",
		Branch:        "upgrade/godot-" + target,
		LaunchLog:     godotLogPath(root, "launch"),
	}

	if _, terr := gitOut(root, "rev-parse", "--verify", "refs/tags/"+report.Tag); terr != nil {
		if err := gitRun(root, "tag", report.Tag); err != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
			return 2
		}
	}
	if _, berr2 := gitOut(root, "rev-parse", "--verify", "refs/heads/"+report.Branch); berr2 != nil {
		if err := gitRun(root, "switch", "-c", report.Branch); err != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
			return 2
		}
	} else if err := gitRun(root, "switch", report.Branch); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	// Exactly one editor. The verdict decides; a running one is never stacked.
	st := client.Diagnose(root, 0)
	action, reason := decideLaunch(st)
	fmt.Fprintln(os.Stderr, ui.Err.Dim(reason))
	if action == actionSpawn {
		if _, serr := spawnGodot(bin, root, report.LaunchLog, editorArgs(root, true)); serr != nil {
			fmt.Fprintf(os.Stderr, "%s could not launch %s: %v\n", ui.Err.Fail("error:"), bin, serr)
			return 2
		}
	}
	final := waitForEditor(root, *timeout)
	if final.Verdict != client.VerdictRunning {
		fmt.Fprintf(os.Stderr, "%s the editor did not come up within %s (verdict %s); see %s\n",
			ui.Err.Fail("error:"), *timeout, final.Verdict, report.LaunchLog)
		return 1
	}
	report.EditorPort = final.Port

	sess, serr := newAddonSession(root)
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), serr)
		return 1
	}
	if running, rverr := editorVersion(sess); rverr == nil && shortVersion(running) != target {
		fmt.Fprintf(os.Stderr, "%s the editor answering reports %s while --godot names %s; the harvest describes the editor, not the flag\n",
			ui.Err.Warn("warning:"), running, version)
	}

	rounds, settleErr := settleReimport(sess, *timeout)
	report.SettleRounds = rounds
	if settleErr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Warn("warning:"), settleErr)
	}

	findings, scenes, herr := harvestAll(root, sess, report.LaunchLog, target, true)
	if herr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), herr)
		return 1
	}
	report.Scenes = scenes

	// The resave diff, read before it is committed.
	diff, derr := gitOut(root, "diff", "--unified=3")
	if derr == nil {
		findings = append(findings, parseResaveDiff(diff)...)
	}
	status, _ := gitStatus(root)
	if status != "" {
		if err := gitRun(root, "add", "-A"); err == nil {
			if err := gitRun(root, "commit", "-m", "chore: resave under Godot "+target); err == nil {
				if head, herr2 := gitHead(root); herr2 == nil {
					report.ResaveCommit = head
				}
			}
		}
	}

	sortFindings(findings)
	report.Findings = findings
	report.Counts = countByCategory(findings)
	report.Files = filesByCategory(findings)
	report.Sources = summarizeSources(findings, map[string]string{
		srcOffline:        "the tree read as text: TileMap nodes, @export_file, typed Dictionary, .uid sidecars, dead ext_resource paths",
		srcLaunchLog:      report.LaunchLog,
		srcWarnings:       "the editor's own panel, with every GDScript warning forced on by preflight",
		srcScriptValidate: "script.validate --all, the tree-wide compile",
		srcSceneValidate:  fmt.Sprintf("%d scenes opened and validated", len(scenes)),
		srcResaveDiff:     "git diff of what the editor rewrote, committed as " + short(report.ResaveCommit),
		srcRenameSweep:    "the rename table matched against every .gd",
	})

	path, werr := writeUpgradeReport(root, "open.json", report)
	if werr != nil {
		fmt.Fprintf(os.Stderr, "%s writing the report: %v\n", ui.Err.Fail("error:"), werr)
		return 2
	}

	line := fmt.Sprintf("%d findings across %d categories on branch %s", len(findings), len(report.Counts), report.Branch)
	emitResult("upgrade open", report, *asJSON, line, [][2]string{
		{"project", root},
		{"editor", version},
		{"tag", report.Tag},
		{"branch", report.Branch},
		{"scenes", strconv.Itoa(len(scenes))},
		{"settle rounds", strconv.Itoa(rounds)},
		{"resave commit", short(report.ResaveCommit)},
		{"findings", strconv.Itoa(len(findings))},
		{"report", path},
	})
	if !*asJSON && ui.IsTerminal(os.Stdout) {
		fmt.Println()
		printTodoTable(report.Counts, report.Files)
		fmt.Println()
		fmt.Println(ui.Out.Dim("Next: godot-mcp upgrade fix --category <name> [--dry-run]"))
	}
	return 0
}

// editorVersion asks the running editor what it is, which is the version the
// harvest actually describes.
func editorVersion(sess *addonSession) (string, error) {
	var payload struct {
		Version struct {
			String string `json:"string"`
		} `json:"version"`
	}
	if err := sess.callInto(&payload, "engine.version", nil); err != nil {
		return "", err
	}
	return payload.Version.String, nil
}

// settleReimport reloads until the error count comes back the same twice. A
// scan in progress reports failures that resolve themselves, so reading the
// panel before it settles produces a to-do list of things already done.
func settleReimport(sess *addonSession, timeout time.Duration) (int, error) {
	deadline := time.Now().Add(timeout)
	last, stable, rounds := -1, 0, 0
	for time.Now().Before(deadline) {
		rounds++
		if _, err := sess.callTimeout(5*time.Minute, "editor.reload", nil); err != nil {
			return rounds, fmt.Errorf("editor.reload during the settle loop: %w", err)
		}
		entries, err := editorErrors(sess)
		if err != nil {
			return rounds, err
		}
		if len(entries) == last {
			stable++
			if stable >= 2 {
				return rounds, nil
			}
		} else {
			stable = 0
		}
		last = len(entries)
		time.Sleep(2 * time.Second)
	}
	return rounds, fmt.Errorf("the reimport had not settled after %d reloads in %s; the harvest below may include scan noise", rounds, timeout)
}

// editorErrors reads the editor's own panel, project entries only.
func editorErrors(sess *addonSession) ([]string, error) {
	var payload struct {
		Errors []string `json:"errors"`
	}
	err := sess.callInto(&payload, "editor.errors", map[string]any{"internal": false, "max_lines": 500})
	return payload.Errors, err
}

// harvestAll reads every source the craft doc names except the drive, which is
// baseline's and verify's. It returns the findings and the scenes it opened.
func harvestAll(root string, sess *addonSession, launchLog, target string, resave bool) ([]upgradeFinding, []string, error) {
	var findings []upgradeFinding

	// 1 and 2. The launch log and the editor's panel, warnings included. The
	// log gets the same rule editor.errors --internal=false applies to the panel:
	// a line sourced to engine C++ that names no project file is reimport noise
	// (a headless run prints dummy-renderer nulls by the dozen), while one that
	// names a res:// path is the engine telling us about the project.
	for _, e := range readEngineLog(launchLog) {
		if engineInternalLine(e) {
			continue
		}
		cat := catEngineError
		if strings.Contains(e.Level, "WARNING") {
			cat = catWarning
		} else if strings.HasSuffix(e.File, ".gd") {
			cat = catScriptError
		} else if strings.HasSuffix(e.File, ".tscn") || strings.HasSuffix(e.File, ".tres") {
			cat = catSceneError
		}
		findings = append(findings, upgradeFinding{
			Category: cat, Source: srcLaunchLog, File: e.File, Line: e.Line, Detail: e.String(),
		})
	}
	panelEntries, perr := editorErrors(sess)
	if perr != nil {
		return nil, nil, perr
	}
	for _, line := range panelEntries {
		cat := catEngineError
		if strings.Contains(line, "WARNING") {
			cat = catWarning
		}
		findings = append(findings, upgradeFinding{Category: cat, Source: srcWarnings, Detail: line})
	}

	// 3. The tree-wide compile.
	var validate struct {
		Checked int `json:"checked"`
		Failed  int `json:"failed"`
		Results []struct {
			Path    string `json:"path"`
			Message string `json:"message"`
		} `json:"results"`
	}
	raw, verr := sess.callTimeout(10*time.Minute, "script.validate", map[string]any{"all": true})
	if verr != nil {
		return nil, nil, verr
	}
	if jerr := json.Unmarshal(raw, &validate); jerr != nil {
		return nil, nil, jerr
	}
	for _, r := range validate.Results {
		findings = append(findings, upgradeFinding{
			Category: catScriptError, Source: srcScriptValidate, File: r.Path,
			Detail: strings.TrimSpace(r.Message),
		})
	}

	// 4. Every scene, opened, validated and resaved. The active scene is put
	// back afterwards, or every later command would target one nobody chose.
	scenes, scerr := walkProjectFiles(root, ".tscn")
	if scerr != nil {
		return nil, nil, scerr
	}
	original := activeScene(sess)
	opened := make([]string, 0, len(scenes))
	for _, rel := range scenes {
		res := resURI(rel)
		if _, err := sess.callTimeout(2*time.Minute, "scene.open", map[string]any{"path": res}); err != nil {
			findings = append(findings, upgradeFinding{
				Category: catSceneError, Source: srcSceneValidate, File: res,
				Detail: "the scene would not open: " + err.Error(),
			})
			continue
		}
		opened = append(opened, res)
		findings = append(findings, validateScene(sess, res)...)
		if !resave {
			continue
		}
		if _, err := sess.call("scene.save", nil); err != nil {
			findings = append(findings, upgradeFinding{
				Category: catSceneError, Source: srcSceneValidate, File: res,
				Detail: "the scene would not resave: " + err.Error(),
			})
		}
	}
	if original != "" {
		_, _ = sess.callTimeout(2*time.Minute, "scene.open", map[string]any{"path": original})
	}

	// 6. The offline scans, including the rename sweep. fix reads these counts,
	// so open carries the whole fixable picture rather than deferring to
	// preflight's report.
	scriptFindings, _, sferr := scanScripts(root)
	if sferr != nil {
		return nil, nil, sferr
	}
	findings = append(findings, scriptFindings...)
	if uid, uerr := scanUIDSidecars(root); uerr == nil {
		findings = append(findings, uid...)
	}
	if refs, rerr := scanExtResources(root); rerr == nil {
		findings = append(findings, refs...)
	}
	if tms, terr := scanTileMapNodes(root); terr == nil {
		for _, tm := range tms {
			findings = append(findings, upgradeFinding{
				Category: catTileMap, Source: srcOffline, File: tm.File, Line: tm.Line, Node: tm.Path, Fixable: true,
				Detail: "TileMap has been deprecated since 4.3 in favour of one TileMapLayer per layer",
			})
		}
	}
	findings = append(findings, scanFeatureTag(root, target)...)
	return findings, opened, nil
}

// validateScene runs scene.validate on the open scene and turns its issues into
// findings.
func validateScene(sess *addonSession, res string) []upgradeFinding {
	var payload struct {
		Issues []struct {
			Type      string `json:"type"`
			Node      string `json:"node"`
			Property  string `json:"property"`
			Path      string `json:"path"`
			Animation string `json:"animation"`
			TrackPath string `json:"track_path"`
			Detail    string `json:"detail"`
		} `json:"issues"`
	}
	if err := sess.callInto(&payload, "scene.validate", nil); err != nil {
		return []upgradeFinding{{
			Category: catSceneError, Source: srcSceneValidate, File: res,
			Detail: "scene.validate: " + err.Error(),
		}}
	}
	out := make([]upgradeFinding, 0, len(payload.Issues))
	for _, i := range payload.Issues {
		cat := catSceneError
		if i.Type == "missing_ext_resource" || i.Type == "missing_placeholder" {
			cat = catMissingRef
		}
		detail := i.Type
		if i.Detail != "" {
			detail += ": " + i.Detail
		}
		if i.Path != "" {
			detail += " (" + i.Path + ")"
		}
		if i.TrackPath != "" {
			detail += " (" + i.Animation + " track " + i.TrackPath + ")"
		}
		out = append(out, upgradeFinding{
			Category: cat, Source: srcSceneValidate, File: res, Node: i.Node, Property: i.Property, Detail: detail,
		})
	}
	return out
}

// activeScene reports which scene the editor currently has open, so the harvest
// can put it back.
func activeScene(sess *addonSession) string {
	var payload struct {
		ScenePath string `json:"scene_path"`
	}
	if err := sess.callInto(&payload, "scene.tree", map[string]any{"max_depth": 0}); err != nil {
		return ""
	}
	return payload.ScenePath
}

// engineInternalLine mirrors the addon's _is_internal: the source is an engine
// C++ file and nothing in the entry points back at the project.
func engineInternalLine(e engineLogEntry) bool {
	ext := strings.ToLower(filepath.Ext(e.File))
	switch ext {
	case ".cpp", ".hpp", ".h", ".inc", ".mm", ".m":
	default:
		return false
	}
	text := e.String()
	return !strings.Contains(text, "res://") && !strings.Contains(text, "user://")
}
