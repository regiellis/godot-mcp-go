package main

import (
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// Phase 6. The same drive, replayed under the new binary, plus the harvest run
// again so the to-do list can be read as a delta rather than as a fresh list.

// numberDelta is one measurement on both sides of the port.
type numberDelta struct {
	Key      string  `json:"key"`
	Before   any     `json:"before"`
	After    any     `json:"after"`
	Changed  bool    `json:"changed"`
	Numeric  bool    `json:"numeric"`
	Absolute float64 `json:"absolute,omitempty"`
}

// imageDelta is one frame pair and how much of it moved.
type imageDelta struct {
	Name           string  `json:"name"`
	Before         string  `json:"before"`
	After          string  `json:"after"`
	ChangedPixels  int     `json:"changed_pixels"`
	ChangedPercent float64 `json:"changed_percent"`
	Note           string  `json:"note,omitempty"`
}

// verifyReport is .godot/upgrade/verify.json.
type verifyReport struct {
	Phase            string                    `json:"phase"`
	GeneratedUnix    int64                     `json:"generated_unix"`
	ProjectPath      string                    `json:"project_path"`
	GodotVersion     string                    `json:"godot_version"`
	BaselineVersion  string                    `json:"baseline_version"`
	Numbers          []numberDelta             `json:"numbers"`
	Images           []imageDelta              `json:"images"`
	RuntimeErrors    int                       `json:"runtime_errors"`
	OpenCounts       map[string]int            `json:"open_counts"`
	Counts           map[string]int            `json:"counts"`
	CategoryDelta    map[string]int            `json:"category_delta"`
	Files            map[string]map[string]int `json:"files_by_category"`
	Sources          []sourceSummary           `json:"sources"`
	Findings         []upgradeFinding          `json:"findings"`
	WarningsCommit   string                    `json:"warnings_commit,omitempty"`
	RevertCommit     string                    `json:"revert_commit,omitempty"`
	WarningsRestored []string                  `json:"warnings_restored,omitempty"`
	RevertNote       string                    `json:"revert_note,omitempty"`
}

// runUpgradeVerify replays the baseline under the new binary, diffs it,
// re-harvests, and reverts preflight's warnings commit.
func runUpgradeVerify(args []string) int {
	fs := flag.NewFlagSet("upgrade verify", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	newGodot := fs.String("godot", "", "path to the target binary (required)")
	scenario := fs.String("scenario", "", "scenario to replay (default: the one baseline recorded)")
	frames := fs.Int("frames", 0, "frames to record when there is no scenario (default: what baseline recorded)")
	threshold := fs.Int("threshold", 10, "per-channel difference that counts a pixel as changed")
	timeout := fs.Duration("timeout", 10*time.Minute, "how long to let the drive and the harvest run")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "replay the baseline, diff it, re-harvest, and revert the warnings commit",
		[]string{"godot-mcp upgrade verify --godot PATH [--scenario FILE] [--threshold 10] [--json]"},
		`Replays the identical drive under the new binary, compares each recorded
number and each captured frame against what baseline recorded, and runs the
seven-source harvest again so the result reads as a delta against open.json.

Read the changed-pixel percentage against the spread between two baseline runs
of the same build, never against a number picked in advance. Nothing in a real
game replays bit-identically, and a fixed threshold points the wrong way as
often as the right one.

Its last step reverts the commit preflight made, so the project leaves the port
with the warning settings it arrived with.

Writes `+"`"+upgradeReportDir+"/verify.json`"+` and prints the delta table.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}
	if *newGodot == "" {
		fmt.Fprintf(os.Stderr, "%s upgrade verify needs --godot\n", ui.Err.Fail("error:"))
		return 2
	}
	var base driveCapture
	if err := readUpgradeReport(root, filepath.Join("baseline", "baseline.json"), &base); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}
	var open openReport
	if err := readUpgradeReport(root, "open.json", &open); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	useScenario := *scenario
	if useScenario == "" {
		useScenario = base.Scenario
	}
	useFrames := *frames
	if useFrames == 0 {
		useFrames = base.Frames
	}
	if useFrames == 0 {
		useFrames = 300
	}
	if rc := runUpgradeDrive(root, "verify", "drive", *newGodot, useScenario, useFrames, *timeout, true, true); rc == 2 {
		return 2
	}
	var after driveCapture
	if err := readUpgradeReport(root, filepath.Join("verify", "drive.json"), &after); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	report := verifyReport{
		Phase:           "verify",
		GeneratedUnix:   time.Now().Unix(),
		ProjectPath:     root,
		GodotVersion:    after.GodotVersion,
		BaselineVersion: base.GodotVersion,
		RuntimeErrors:   len(after.Errors),
		OpenCounts:      open.Counts,
		Numbers:         diffNumbers(base.Numbers, after.Numbers),
	}

	// The editor is needed for the image comparison and the harvest.
	bin, berr := resolveGodotBinary(*newGodot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}
	st := client.Diagnose(root, 0)
	if action, reason := decideLaunch(st); action == actionSpawn {
		fmt.Fprintln(os.Stderr, ui.Err.Dim(reason))
		if _, serr := spawnGodot(bin, root, godotLogPath(root, "launch"), editorArgs(root, true)); serr != nil {
			fmt.Fprintf(os.Stderr, "%s could not launch %s: %v\n", ui.Err.Fail("error:"), bin, serr)
			return 2
		}
	}
	if final := waitForEditor(root, *timeout); final.Verdict != client.VerdictRunning {
		fmt.Fprintf(os.Stderr, "%s the editor did not come up (verdict %s)\n", ui.Err.Fail("error:"), final.Verdict)
		return 1
	}
	sess, serr := newAddonSession(root)
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), serr)
		return 1
	}

	report.Images = compareCaptures(sess, base.Screenshots, after.Screenshots, *threshold)

	findings, _, herr := harvestAll(root, sess, godotLogPath(root, "launch"), open.TargetVersion, false)
	if herr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), herr)
		return 1
	}
	for _, e := range after.Errors {
		findings = append(findings, upgradeFinding{
			Category: catRuntimeError, Source: srcDrive, Detail: fmt.Sprint(e),
		})
	}
	sortFindings(findings)
	report.Findings = findings
	report.Counts = countByCategory(findings)
	report.Files = filesByCategory(findings)
	report.CategoryDelta = map[string]int{}
	for k, v := range report.Counts {
		report.CategoryDelta[k] = v - open.Counts[k]
	}
	for k, v := range open.Counts {
		if _, ok := report.Counts[k]; !ok {
			report.CategoryDelta[k] = -v
		}
	}
	report.Sources = summarizeSources(findings, map[string]string{
		srcOffline:        "the tree read as text, after every applied fix",
		srcLaunchLog:      godotLogPath(root, "launch"),
		srcWarnings:       "the editor's own panel",
		srcScriptValidate: "script.validate --all",
		srcSceneValidate:  "every scene opened and validated, without a resave this time",
		srcResaveDiff:     "read by open; verify does not resave, so there is nothing new to diff",
		srcRenameSweep:    "the rename table matched against every .gd",
		srcDrive:          fmt.Sprintf("%s replayed under %s", orNone(useScenario), after.GodotVersion),
	})

	// Put the warning settings back, so the project leaves the port with what it
	// arrived with. The revert is tried first, and a second pass repairs what it
	// could not: the editor prunes any setting equal to its default on the next
	// save, so by now most of preflight's block is already gone from the file and
	// git's three-way merge reads the whole hunk as already reverted. Measured on
	// the live bed: 50 keys written, 8 left in project.godot, and the revert
	// answered "nothing to commit" with those 8 still in place.
	var pre preflightReport
	if err := readUpgradeReport(root, "preflight.json", &pre); err != nil || pre.WarningsCommit == "" {
		report.RevertNote = "preflight recorded no warnings commit, so there is nothing to restore"
	} else {
		report.WarningsCommit = pre.WarningsCommit
		if st, _ := gitStatus(root); st != "" {
			report.RevertNote = "the tree is dirty, so the warning settings were left in place; commit or restore, then run: git revert --no-edit " + pre.WarningsCommit
		} else {
			if rerr := gitRun(root, "revert", "--no-edit", pre.WarningsCommit); rerr != nil {
				// A revert that produced nothing leaves the sequencer mid-flight.
				_ = gitRun(root, "revert", "--quit")
			} else if head, herr2 := gitHead(root); herr2 == nil {
				report.RevertCommit = head
			}
			report.WarningsRestored = restoreWarningSettings(root, sess, pre)
			if len(report.WarningsRestored) > 0 {
				if err := gitRun(root, "add", "project.godot"); err == nil {
					if err := gitRun(root, "commit", "-m", "chore: restore the GDScript warning settings"); err == nil {
						if head, herr2 := gitHead(root); herr2 == nil {
							report.RevertCommit = head
						}
					}
				}
			}
			if report.RevertCommit == "" {
				report.RevertNote = "the warning settings were already back to what preflight found, so nothing was committed"
			}
		}
	}

	path, werr := writeUpgradeReport(root, "verify.json", report)
	if werr != nil {
		fmt.Fprintf(os.Stderr, "%s writing the report: %v\n", ui.Err.Fail("error:"), werr)
		return 2
	}

	changedNumbers := 0
	for _, n := range report.Numbers {
		if n.Changed {
			changedNumbers++
		}
	}
	line := fmt.Sprintf("%d of %d numbers moved, %d frame pairs compared, %d findings against %d at open",
		changedNumbers, len(report.Numbers), len(report.Images), len(findings), len(open.Findings))
	emitResult("upgrade verify", report, *asJSON, line, [][2]string{
		{"project", root},
		{"baseline", report.BaselineVersion},
		{"now", report.GodotVersion},
		{"numbers moved", fmt.Sprintf("%d of %d", changedNumbers, len(report.Numbers))},
		{"frames compared", strconv.Itoa(len(report.Images))},
		{"runtime errors", strconv.Itoa(report.RuntimeErrors)},
		{"warnings commit", short(report.WarningsCommit)},
		{"reverted as", short(report.RevertCommit)},
		{"report", path},
	})
	if !*asJSON && ui.IsTerminal(os.Stdout) {
		fmt.Println()
		printDeltaTable(report)
	}
	if report.RevertNote != "" {
		fmt.Fprintln(os.Stderr, ui.Err.Warn("note:")+" "+report.RevertNote)
	}
	return 0
}

// restoreWarningSettings puts every key preflight wrote back the way it found
// it, through the running editor rather than by editing project.godot: the
// editor rewrites that file on any settings write, and a hand edit made
// alongside its own rewrite is easy to lose. A key the project never carried is
// removed; one that had a value gets that value back. Returns what it touched.
func restoreWarningSettings(root string, sess *addonSession, pre preflightReport) []string {
	text, err := readProjectFile(root)
	if err != nil {
		return nil
	}
	current := readProjectSettings(text)
	keys := make([]string, 0, len(pre.WarningsApplied))
	for k := range pre.WarningsApplied {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var touched []string
	for _, k := range keys {
		now, present := current[k]
		before, had := pre.WarningsBefore[k]
		switch {
		case had && now != before:
			if _, cerr := sess.call("project.set_setting", map[string]any{"key": k, "value": before}); cerr == nil {
				touched = append(touched, k)
			}
		case !had && present:
			if _, cerr := sess.call("project.remove_setting", map[string]any{"key": k}); cerr == nil {
				touched = append(touched, k)
			}
		}
	}
	return touched
}

// diffNumbers pairs every measurement the two drives recorded.
func diffNumbers(before, after map[string]any) []numberDelta {
	keys := map[string]bool{}
	for k := range before {
		keys[k] = true
	}
	for k := range after {
		keys[k] = true
	}
	names := make([]string, 0, len(keys))
	for k := range keys {
		names = append(names, k)
	}
	sort.Strings(names)
	out := make([]numberDelta, 0, len(names))
	for _, k := range names {
		d := numberDelta{Key: k, Before: before[k], After: after[k]}
		d.Changed = fmt.Sprint(before[k]) != fmt.Sprint(after[k])
		bf, bok := before[k].(float64)
		af, aok := after[k].(float64)
		if bok && aok {
			d.Numeric = true
			d.Absolute = af - bf
		}
		out = append(out, d)
	}
	return out
}

// compareCaptures pairs frames by file name and asks the editor how many pixels
// moved. The images go over as base64 so no path guard is in the way and the
// comparison works wherever the captures were collected to.
func compareCaptures(sess *addonSession, before, after []string, threshold int) []imageDelta {
	byName := map[string]string{}
	for _, p := range after {
		byName[filepath.Base(p)] = p
	}
	out := []imageDelta{}
	for _, a := range before {
		name := filepath.Base(a)
		b, ok := byName[name]
		if !ok {
			out = append(out, imageDelta{Name: name, Before: a, Note: "the new drive captured no frame with this name"})
			continue
		}
		ea, erra := encodeImage(a)
		eb, errb := encodeImage(b)
		if erra != nil || errb != nil {
			out = append(out, imageDelta{Name: name, Before: a, After: b, Note: "one of the frames could not be read"})
			continue
		}
		var payload comparePayload
		if err := sess.callInto(&payload, "editor.compare_screenshots", map[string]any{
			"image_a": ea, "image_b": eb, "threshold": threshold,
		}); err != nil {
			out = append(out, imageDelta{Name: name, Before: a, After: b, Note: err.Error()})
			continue
		}
		out = append(out, imageDelta{
			Name: name, Before: a, After: b,
			ChangedPixels: payload.ChangedPixels, ChangedPercent: payload.ChangedPercent,
		})
	}
	return out
}

// encodeImage reads a PNG and returns it base64, which compare_screenshots
// accepts in place of a path.
func encodeImage(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(b), nil
}

// printDeltaTable renders what moved: the numbers, the frames, and the
// category counts against what open found.
func printDeltaTable(report verifyReport) {
	if len(report.Numbers) > 0 {
		fmt.Println(ui.Out.Heading("numbers") + " " + ui.Out.Dim("(baseline, then now)"))
		w := 0
		for _, n := range report.Numbers {
			w = max(w, len(n.Key))
		}
		for _, n := range report.Numbers {
			mark := ui.Out.OK("same")
			if n.Changed {
				mark = ui.Out.Warn("moved")
			}
			fmt.Printf("  %s  %s  %v -> %v\n", ui.Out.Key(padRight(n.Key, w)), mark, n.Before, n.After)
		}
		fmt.Println()
	}
	if len(report.Images) > 0 {
		fmt.Println(ui.Out.Heading("frames"))
		for _, i := range report.Images {
			if i.Note != "" {
				fmt.Printf("  %s  %s\n", ui.Out.Key(i.Name), ui.Out.Dim(i.Note))
				continue
			}
			fmt.Printf("  %s  %.2f%% of pixels changed (%d)\n", ui.Out.Key(i.Name), i.ChangedPercent, i.ChangedPixels)
		}
		fmt.Println()
	}
	cats := make([]string, 0, len(report.CategoryDelta))
	for c := range report.CategoryDelta {
		cats = append(cats, c)
	}
	sort.Strings(cats)
	if len(cats) == 0 {
		return
	}
	fmt.Println(ui.Out.Heading("categories") + " " + ui.Out.Dim("(open, then now)"))
	w := 0
	for _, c := range cats {
		w = max(w, len(c))
	}
	for _, c := range cats {
		d := report.CategoryDelta[c]
		sign := ""
		if d > 0 {
			sign = "+"
		}
		fmt.Printf("  %s  %4d -> %4d  %s\n",
			ui.Out.Key(padRight(c, w)), report.OpenCounts[c], report.Counts[c], ui.Out.Dim(sign+strconv.Itoa(d)))
	}
}

// comparePayload is editor.compare_screenshots' result. The addon names the
// percentage diff_percentage; decoding the wrong name here once made every pair
// read 0.00 while changed_pixels held six figures, and the platformer
// cross-version run is what caught it. TestComparePayloadDecode pins the shape.
type comparePayload struct {
	ChangedPixels  int     `json:"changed_pixels"`
	ChangedPercent float64 `json:"diff_percentage"`
}
