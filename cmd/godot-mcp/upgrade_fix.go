package main

import (
	"encoding/json"
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

// Phases 4 and 5. Report-only is what the editor already gives you, so a fix
// applies, proves itself, and then keeps or restores.
//
// The rollback unit is the checkpoint plus git, not one undo. Each addon
// command commits its own EditorUndoRedoManager action and the wire has no way
// to group several calls into one, so a category that takes more than one
// command cannot be a single undo step. authoring.checkpoint captures the
// scene's node identities and transforms, git holds everything else, and a
// failed proof restores both.

// fileEdit is one script rewritten as text, kept whole so --dry-run can render
// a real diff and the apply can send exactly the lines the plan named.
type fileEdit struct {
	File   string   `json:"file"`
	Lines  []int    `json:"lines"`
	Before string   `json:"-"`
	After  string   `json:"-"`
	Search []string `json:"-"`
	Repl   []string `json:"-"`
}

// plannedAction is one addon command a non-textual category will send.
type plannedAction struct {
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
	Detail string         `json:"detail"`
}

// fixPlan is what a category would do, computed before anything is touched.
type fixPlan struct {
	Category string          `json:"category"`
	Edits    []fileEdit      `json:"edits"`
	Actions  []plannedAction `json:"actions"`
	Blocked  []string        `json:"blocked"`
}

// proofSnapshot is the state a fix is measured against: the category's own
// count, plus the two tree-wide numbers that must not get worse.
type proofSnapshot struct {
	CategoryCount int `json:"category_count"`
	ScriptFailed  int `json:"script_validate_failed"`
	EditorErrors  int `json:"editor_errors"`
}

// fixReport is what fix writes and prints.
type fixReport struct {
	Phase         string           `json:"phase"`
	GeneratedUnix int64            `json:"generated_unix"`
	ProjectPath   string           `json:"project_path"`
	Category      string           `json:"category"`
	DryRun        bool             `json:"dry_run"`
	Plan          fixPlan          `json:"plan"`
	Before        proofSnapshot    `json:"before"`
	After         proofSnapshot    `json:"after"`
	Checkpoint    string           `json:"checkpoint,omitempty"`
	Tag           string           `json:"tag,omitempty"`
	Commit        string           `json:"commit,omitempty"`
	Applied       bool             `json:"applied"`
	Restored      bool             `json:"restored"`
	Drive         *driveCapture    `json:"drive,omitempty"`
	DebugState    json.RawMessage  `json:"debug_state,omitempty"`
	Findings      []upgradeFinding `json:"remaining_findings"`
	Reason        string           `json:"reason,omitempty"`
}

// runUpgradeFix applies one category and proves it.
func runUpgradeFix(args []string) int {
	fs := flag.NewFlagSet("upgrade fix", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	category := fs.String("category", "", "which category to apply: "+strings.Join(fixableCategories, ", "))
	dryRun := fs.Bool("dry-run", false, "print the diff and touch nothing")
	newGodot := fs.String("godot", "", "path to the target binary, to replay the drive as part of the proof")
	scenario := fs.String("scenario", "", "scenario to replay as part of the proof (default: the one baseline recorded)")
	timeout := fs.Duration("timeout", 10*time.Minute, "how long to let the proof run")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "apply one category, prove it, and keep or restore",
		[]string{"godot-mcp upgrade fix --category NAME [--dry-run] [--godot PATH] [--scenario FILE] [--json]"},
		`Reads `+"`"+upgradeReportDir+"/open.json`"+` for what the category started at, captures a
checkpoint and a tag, applies the category through the tool's own commands, then
proves it: editor reload, script validate --all, editor errors, and the drive
when --godot names a binary to run it under.

The category's count has to reach zero and neither tree-wide number may get
worse. If either fails, the checkpoint is restored, the files are checked back
out, and the report says why, with the debugger's stack attached when a runtime
fault broke the game. A category that passes lands as one commit.

Categories: `+strings.Join(fixableCategories, ", ")+`. The rest of what open
found is a report a person acts on, and fix says so rather than guessing.

--dry-run prints a unified diff for the categories that rewrite text and the
command list for the ones that do not.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}
	cat := strings.ReplaceAll(strings.TrimSpace(*category), "-", "_")
	if cat == "" {
		fmt.Fprintf(os.Stderr, "%s upgrade fix needs --category (%s)\n", ui.Err.Fail("error:"), strings.Join(fixableCategories, ", "))
		return 2
	}
	if !isFixable(cat) {
		fmt.Fprintf(os.Stderr, "%s %q is not a category fix can apply. Mechanical categories: %s\n",
			ui.Err.Fail("error:"), cat, strings.Join(fixableCategories, ", "))
		return 2
	}

	var open openReport
	if err := readUpgradeReport(root, "open.json", &open); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	report := fixReport{
		Phase:         "fix",
		GeneratedUnix: time.Now().Unix(),
		ProjectPath:   root,
		Category:      cat,
		DryRun:        *dryRun,
		Before:        proofSnapshot{CategoryCount: open.Counts[cat]},
	}

	plan, perr := planCategory(root, cat, open)
	if perr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), perr)
		return 2
	}
	report.Plan = plan

	if *dryRun {
		printPlan(plan)
		emitResult("upgrade fix", report, *asJSON,
			fmt.Sprintf("%s: %d files and %d commands planned; nothing was touched", cat, len(plan.Edits), len(plan.Actions)),
			[][2]string{
				{"category", cat},
				{"files", strconv.Itoa(len(plan.Edits))},
				{"commands", strconv.Itoa(len(plan.Actions))},
				{"blocked", strconv.Itoa(len(plan.Blocked))},
			})
		return 0
	}

	if len(plan.Edits) == 0 && len(plan.Actions) == 0 {
		report.Reason = "nothing to apply"
		if len(plan.Blocked) > 0 {
			report.Reason = "every finding in this category needs a person"
		}
		printPlan(plan)
		emitResult("upgrade fix", report, *asJSON, cat+": "+report.Reason, [][2]string{
			{"category", cat},
			{"blocked", strconv.Itoa(len(plan.Blocked))},
		})
		return 0
	}

	if err := requireCleanTree(root, "upgrade fix"); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 1
	}
	sess, serr := newAddonSession(root)
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s %v; upgrade fix drives the open editor, so run upgrade open first\n", ui.Err.Fail("error:"), serr)
		return 1
	}

	// Capture. The tag is forced because a retried category should compare
	// against where this attempt started, not where the first one did.
	label := "upgrade-fix-" + cat
	report.Checkpoint = label
	report.Tag = label + "-before"
	if _, err := sess.call("authoring.checkpoint", map[string]any{"action": "capture", "label": label}); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Warn("warning: no scene checkpoint;"), err)
		report.Checkpoint = ""
	}
	if err := gitRun(root, "tag", "-f", report.Tag); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	before, berr := snapshotProof(root, sess, cat, open)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 1
	}
	report.Before = before

	if aerr := applyPlan(sess, plan); aerr != nil {
		restoreFix(root, sess, &report)
		report.Reason = "applying the category failed: " + aerr.Error()
		emitFix(report, *asJSON, report.Reason)
		return 1
	}

	after, aerr2 := snapshotProof(root, sess, cat, open)
	if aerr2 != nil {
		restoreFix(root, sess, &report)
		report.Reason = "proving the category failed: " + aerr2.Error()
		emitFix(report, *asJSON, report.Reason)
		return 1
	}
	report.After = after
	if left, lerr := recountCategory(root, cat, open.TargetVersion); lerr == nil {
		sortFindings(left)
		report.Findings = left
	}

	switch {
	case after.CategoryCount > 0:
		report.Reason = fmt.Sprintf("%d %s findings survived the fix", after.CategoryCount, cat)
	case after.ScriptFailed > before.ScriptFailed:
		report.Reason = fmt.Sprintf("script validate went from %d failures to %d", before.ScriptFailed, after.ScriptFailed)
	case after.EditorErrors > before.EditorErrors:
		report.Reason = fmt.Sprintf("the editor's error count went from %d to %d", before.EditorErrors, after.EditorErrors)
	}
	if report.Reason == "" && *newGodot != "" {
		drive, derr := proveDrive(root, *newGodot, *scenario, *timeout)
		report.Drive = drive
		if derr != nil {
			report.Reason = "the drive failed after the fix: " + derr.Error()
		}
	}
	if report.Reason != "" {
		if raw, err := sess.call("debug.state", nil); err == nil {
			report.DebugState = raw
		}
		restoreFix(root, sess, &report)
		emitFix(report, *asJSON, cat+" was restored: "+report.Reason)
		return 1
	}

	if err := gitRun(root, "add", "-A"); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}
	if st, _ := gitStatus(root); st != "" {
		if err := gitRun(root, "commit", "-m", "fix(upgrade): "+cat); err != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
			return 2
		}
	}
	if head, herr := gitHead(root); herr == nil {
		report.Commit = head
	}
	report.Applied = true
	emitFix(report, *asJSON, fmt.Sprintf("%s applied and proved: %d to 0, committed as %s",
		cat, before.CategoryCount, short(report.Commit)))
	return 0
}

// emitFix renders the fix outcome.
func emitFix(report fixReport, asJSON bool, line string) {
	rows := [][2]string{
		{"category", report.Category},
		{"files", strconv.Itoa(len(report.Plan.Edits))},
		{"commands", strconv.Itoa(len(report.Plan.Actions))},
		{"count before", strconv.Itoa(report.Before.CategoryCount)},
		{"count after", strconv.Itoa(report.After.CategoryCount)},
		{"script failures", fmt.Sprintf("%d to %d", report.Before.ScriptFailed, report.After.ScriptFailed)},
		{"editor errors", fmt.Sprintf("%d to %d", report.Before.EditorErrors, report.After.EditorErrors)},
		{"applied", fmt.Sprint(report.Applied)},
	}
	if report.Restored {
		rows = append(rows, [2]string{"restored", "checkpoint " + report.Checkpoint + ", tree back to " + report.Tag})
	}
	if report.Commit != "" {
		rows = append(rows, [2]string{"commit", short(report.Commit)})
	}
	emitResult("upgrade fix", report, asJSON, line, rows)
}

// restoreFix undoes a failed category: the scene checkpoint first, then the
// working tree. Both are needed, because the checkpoint holds node transforms
// and git holds everything the checkpoint does not.
func restoreFix(root string, sess *addonSession, report *fixReport) {
	if report.Checkpoint != "" {
		_, _ = sess.call("authoring.checkpoint", map[string]any{"action": "restore", "label": report.Checkpoint})
	}
	_ = gitRun(root, "checkout", "--", ".")
	_ = gitRun(root, "clean", "-fd", "--", ".")
	_, _ = sess.callTimeout(5*time.Minute, "editor.reload", nil)
	report.Restored = true
}

// snapshotProof measures the three numbers a fix is judged on.
func snapshotProof(root string, sess *addonSession, cat string, open openReport) (proofSnapshot, error) {
	out := proofSnapshot{}
	findings, err := recountCategory(root, cat, open.TargetVersion)
	if err != nil {
		return out, err
	}
	out.CategoryCount = len(findings)

	// The Output panel is a running buffer, so a raw count carries every error
	// the session ever printed, a failed attempt's included. Draining it and
	// rescanning makes both snapshots measure the state in front of them, which
	// is the only way the before and after numbers compare. Without this a
	// second attempt at a category fails on the first attempt's errors.
	_, _ = sess.call("editor.errors", map[string]any{"internal": false, "clear": true})
	if _, rerr := sess.callTimeout(5*time.Minute, "editor.reload", nil); rerr != nil {
		return out, rerr
	}

	var validate struct {
		Failed int `json:"failed"`
	}
	raw, verr := sess.callTimeout(10*time.Minute, "script.validate", map[string]any{"all": true})
	if verr != nil {
		return out, verr
	}
	if jerr := json.Unmarshal(raw, &validate); jerr != nil {
		return out, jerr
	}
	out.ScriptFailed = validate.Failed

	entries, eerr := editorErrors(sess)
	if eerr != nil {
		return out, eerr
	}
	out.EditorErrors = len(entries)
	return out, nil
}

// recountCategory re-runs the offline scan for one category, which is how the
// count is proved to have reached zero rather than assumed.
func recountCategory(root, cat, target string) ([]upgradeFinding, error) {
	var all []upgradeFinding
	switch cat {
	case catExportFile, catTypedDict, catRenames:
		f, _, err := scanScripts(root)
		if err != nil {
			return nil, err
		}
		all = f
	case catUID:
		f, err := scanUIDSidecars(root)
		if err != nil {
			return nil, err
		}
		all = f
	case catTileMap:
		nodes, err := scanTileMapNodes(root)
		if err != nil {
			return nil, err
		}
		for _, n := range nodes {
			all = append(all, upgradeFinding{Category: catTileMap, File: n.File, Line: n.Line, Node: n.Path})
		}
	case catSettings:
		all = scanFeatureTag(root, target)
	}
	out := all[:0]
	for _, f := range all {
		if f.Category == cat || f.Category == "" {
			out = append(out, f)
		}
	}
	return out, nil
}

// exportFileAnyRe matches the annotation in either spelling.
var exportFileAnyRe = regexp.MustCompile(`@export_file(_path)?`)

// featuresVersionRe reads the first entry of a PackedStringArray feature tag,
// which is the version that last saved the project.
var featuresVersionRe = regexp.MustCompile(`PackedStringArray\(\s*"([^"]*)"`)

// scanFeatureTag reports the feature tag when it still names an older release.
// The editor rewrites everything else on its own and leaves this one alone, so
// a fully ported project keeps reporting the version it came from until
// something sets it.
func scanFeatureTag(root, target string) []upgradeFinding {
	raw, ok := projectSetting(root, "application", "config/features")
	if !ok || target == "" {
		return nil
	}
	m := featuresVersionRe.FindStringSubmatch(raw)
	if m == nil || m[1] == target {
		return nil
	}
	return []upgradeFinding{{
		Category: catSettings, Source: srcOffline, File: "project.godot", Property: "application/config/features",
		Fixable: true,
		Detail:  "the feature tag still names " + m[1] + " while the project is being ported to " + target,
	}}
}

// --- planning ----------------------------------------------------------------

// planCategory works out what a category would do without doing any of it.
func planCategory(root, cat string, open openReport) (fixPlan, error) {
	plan := fixPlan{Category: cat, Edits: []fileEdit{}, Actions: []plannedAction{}, Blocked: []string{}}
	switch cat {
	case catExportFile:
		return planTextEdits(root, cat, open, rewriteExportFileLine)
	case catTypedDict:
		return planTextEdits(root, cat, open, rewriteTypedDictLine)
	case catRenames:
		if len(fixableRenames()) == 0 {
			for _, f := range open.Findings {
				if f.Category == catRenames {
					plan.Blocked = append(plan.Blocked, fmt.Sprintf("%s:%d %s", f.File, f.Line, f.Detail))
				}
			}
			return plan, nil
		}
		return planTextEdits(root, cat, open, rewriteRenameLine)
	case catTileMap:
		return planTileMap(root, open)
	case catSettings:
		for _, f := range scanFeatureTag(root, open.TargetVersion) {
			plan.Actions = append(plan.Actions, plannedAction{
				Method: "project.set_setting",
				Params: map[string]any{"key": "application/config/features", "value": featureTagValue(root, open.TargetVersion)},
				Detail: f.Detail,
			})
		}
		return plan, nil
	case catUID:
		missing, err := scanUIDSidecars(root)
		if err != nil {
			return plan, err
		}
		if len(missing) > 0 {
			plan.Actions = append(plan.Actions, plannedAction{
				Method: "editor.reload",
				Params: map[string]any{},
				Detail: fmt.Sprintf("rescan the filesystem so the editor writes the %d missing .uid sidecars", len(missing)),
			})
		}
		return plan, nil
	}
	return plan, fmt.Errorf("no plan for category %q", cat)
}

// featureTagValue builds the PackedStringArray the feature tag should hold: the
// target version, then whatever renderer strings the project already used.
func featureTagValue(root, target string) []string {
	out := []string{target}
	raw, ok := projectSetting(root, "application", "config/features")
	if !ok {
		return out
	}
	for _, m := range regexp.MustCompile(`"([^"]*)"`).FindAllStringSubmatch(raw, -1) {
		if m[1] == "" || m[1] == target || strings.HasPrefix(m[1], target[:1]+".") && strings.Count(m[1], ".") == 1 {
			continue
		}
		out = append(out, m[1])
	}
	return out
}

// planTextEdits builds the per-file rewrite for a text category, reading the
// files rather than trusting the report's line numbers on their own.
func planTextEdits(root, cat string, open openReport, rewrite func(string) (string, bool)) (fixPlan, error) {
	plan := fixPlan{Category: cat, Edits: []fileEdit{}, Actions: []plannedAction{}, Blocked: []string{}}
	files := map[string][]int{}
	for _, f := range open.Findings {
		if f.Category != cat || f.File == "" || f.Line <= 0 {
			continue
		}
		if !f.Fixable {
			plan.Blocked = append(plan.Blocked, fmt.Sprintf("%s:%d %s", f.File, f.Line, f.Detail))
			continue
		}
		files[f.File] = append(files[f.File], f.Line)
	}
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, res := range names {
		local := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(res, "res://")))
		b, err := os.ReadFile(local)
		if err != nil {
			plan.Blocked = append(plan.Blocked, res+": "+err.Error())
			continue
		}
		before := string(b)
		lines := strings.Split(before, "\n")
		edit := fileEdit{File: res, Before: before}
		seen := map[int]bool{}
		for _, n := range files[res] {
			if n < 1 || n > len(lines) || seen[n] {
				continue
			}
			seen[n] = true
			next, ok := rewrite(lines[n-1])
			if !ok {
				plan.Blocked = append(plan.Blocked, fmt.Sprintf("%s:%d no mechanical rewrite for %q", res, n, strings.TrimSpace(lines[n-1])))
				continue
			}
			edit.Lines = append(edit.Lines, n)
			edit.Search = append(edit.Search, lines[n-1])
			edit.Repl = append(edit.Repl, next)
			lines[n-1] = next
		}
		if len(edit.Lines) == 0 {
			continue
		}
		sort.Ints(edit.Lines)
		edit.After = strings.Join(lines, "\n")
		plan.Edits = append(plan.Edits, edit)
	}
	return plan, nil
}

// rewriteExportFileLine turns @export_file into @export_file_path, the 4.5
// annotation that forces the res:// shape @export_file stopped returning in 4.4.
func rewriteExportFileLine(line string) (string, bool) {
	// Go's regexp has no negative lookahead, so the annotation that already
	// carries _path is skipped inside the replacement rather than excluded by
	// the match.
	out := exportFileAnyRe.ReplaceAllStringFunc(line, func(m string) string {
		if strings.HasSuffix(m, "_path") {
			return m
		}
		return "@export_file_path"
	})
	if out == line {
		return line, false
	}
	return out, true
}

// rewriteTypedDictLine makes the JSON result's type explicit, which is what a
// typed Dictionary declaration needs once JSON.parse_string hands back a
// Variant. The cast goes after the call's own closing paren, found by matching
// parens rather than by taking the last one on the line, so a trailing comment
// or a second call cannot move it.
func rewriteTypedDictLine(line string) (string, bool) {
	m := typedDictJSONRe.FindStringSubmatch(line)
	if m == nil || m[1] != "" {
		return line, false
	}
	const call = "JSON.parse_string("
	i := strings.Index(line, call)
	if i < 0 {
		return line, false
	}
	end := matchParen(line, i+len(call)-1)
	if end < 0 {
		return line, false
	}
	rest := strings.TrimSpace(line[end+1:])
	if strings.HasPrefix(rest, "as ") {
		return line, false
	}
	return line[:end+1] + " as Dictionary" + line[end+1:], true
}

// rewriteRenameLine applies the first rename-table entry that carries a
// mechanical rewrite and matches the line.
func rewriteRenameLine(line string) (string, bool) {
	for _, r := range fixableRenames() {
		if strings.Contains(line, r.Search) {
			return strings.ReplaceAll(line, r.Search, r.Replace), true
		}
	}
	return line, false
}

// matchParen returns the index of the paren closing the one at open, ignoring
// parens inside string literals.
func matchParen(s string, open int) int {
	depth := 0
	var quote byte
	for i := open; i < len(s); i++ {
		c := s[i]
		if quote != 0 {
			if c == '\\' {
				i++
				continue
			}
			if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '"', '\'':
			quote = c
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// planTileMap builds the per-scene conversion. The extraction runs as one
// editor.run_script because the per-layer, per-cell alternative is four wire
// calls per cell, and the craft doc teaches this same script by hand.
func planTileMap(root string, open openReport) (fixPlan, error) {
	plan := fixPlan{Category: catTileMap, Edits: []fileEdit{}, Actions: []plannedAction{}, Blocked: []string{}}
	nodes, err := scanTileMapNodes(root)
	if err != nil {
		return plan, err
	}
	for _, n := range nodes {
		plan.Actions = append(plan.Actions,
			plannedAction{Method: "scene.open", Params: map[string]any{"path": n.File},
				Detail: "open " + n.File},
			plannedAction{Method: "editor.run_script", Params: map[string]any{"code": tileMapExtractCode(n.Path)},
				Detail: "extract every layer of " + n.Path + " into its own TileMapLayer"},
			plannedAction{Method: "node.delete", Params: map[string]any{"node_path": n.Path},
				Detail: "remove the TileMap once its cells have moved"},
			plannedAction{Method: "scene.save", Params: map[string]any{},
				Detail: "save " + n.File},
		)
	}
	return plan, nil
}

// tileMapExtractCode is the layer extractor. layer.owner = root is required:
// a node added without an owner is dropped when the scene is packed, and the
// loss reads as an empty level rather than as an error.
func tileMapExtractCode(nodePath string) string {
	return `var root = EditorInterface.get_edited_scene_root()
var old = root.get_node(` + strconv.Quote(nodePath) + `)
var parent = old.get_parent()
var made = []
for i in old.get_layers_count():
	var layer = TileMapLayer.new()
	layer.name = "%s_%d" % [old.name, i]
	layer.tile_set = old.tile_set
	layer.enabled = old.is_layer_enabled(i)
	layer.z_index = old.get_layer_z_index(i)
	layer.modulate = old.get_layer_modulate(i)
	layer.y_sort_origin = old.get_layer_y_sort_origin(i)
	layer.y_sort_enabled = old.is_layer_y_sort_enabled(i)
	layer.navigation_enabled = old.is_layer_navigation_enabled(i)
	layer.position = old.position
	for c in old.get_used_cells(i):
		layer.set_cell(c, old.get_cell_source_id(i, c), old.get_cell_atlas_coords(i, c), old.get_cell_alternative_tile(i, c))
	parent.add_child(layer)
	layer.owner = root
	made.append([layer.name, old.get_used_cells(i).size()])
emit(made)`
}

// --- applying ----------------------------------------------------------------

// applyPlan sends the plan through the addon's own commands, so every write
// goes through the same guards and undo bookkeeping any other caller gets.
func applyPlan(sess *addonSession, plan fixPlan) error {
	for _, e := range plan.Edits {
		reps := make([]map[string]any, 0, len(e.Search))
		for i := range e.Search {
			reps = append(reps, map[string]any{"search": e.Search[i], "replace": e.Repl[i]})
		}
		if _, err := sess.call("script.edit", map[string]any{"path": e.File, "replacements": reps}); err != nil {
			return fmt.Errorf("%s: %w", e.File, err)
		}
	}
	for _, a := range plan.Actions {
		if _, err := sess.callTimeout(5*time.Minute, a.Method, a.Params); err != nil {
			return fmt.Errorf("%s (%s): %w", a.Method, a.Detail, err)
		}
	}
	return nil
}

// proveDrive replays the scenario under the target binary as the last half of
// the proof, since a category can compile clean and still break the game.
func proveDrive(root, bin, scenario string, timeout time.Duration) (*driveCapture, error) {
	if scenario == "" {
		var base driveCapture
		if err := readUpgradeReport(root, filepath.Join("baseline", "baseline.json"), &base); err != nil {
			return nil, nil
		}
		scenario = base.Scenario
	}
	if scenario == "" {
		return nil, nil
	}
	rc := runUpgradeDrive(root, "fix", "drive", bin, scenario, 0, timeout, true, true)
	var capt driveCapture
	if err := readUpgradeReport(root, filepath.Join("fix", "drive.json"), &capt); err != nil {
		return nil, err
	}
	if rc != 0 {
		return &capt, fmt.Errorf("the drive did not complete cleanly")
	}
	if len(capt.Errors) > 0 {
		return &capt, fmt.Errorf("the game reported %d runtime errors during the drive", len(capt.Errors))
	}
	return &capt, nil
}

// --- rendering ---------------------------------------------------------------

// printPlan renders what a category would do: a unified diff where the change
// is text, the command list where it is not.
func printPlan(plan fixPlan) {
	for _, e := range plan.Edits {
		fmt.Print(unifiedDiff(e.File, e.Before, e.After))
	}
	if len(plan.Actions) > 0 {
		fmt.Println(ui.Out.Heading("commands"))
		for _, a := range plan.Actions {
			b, _ := json.Marshal(a.Params)
			fmt.Printf("  %s %s\n", ui.Out.Key(a.Method), ui.Out.Dim(string(b)))
			fmt.Printf("    %s\n", a.Detail)
		}
	}
	if len(plan.Blocked) > 0 {
		fmt.Println(ui.Out.Heading("needs a person"))
		for _, b := range plan.Blocked {
			fmt.Println("  " + b)
		}
	}
}

// unifiedDiff renders a diff of two versions of one file with three lines of
// context. The edits are line-for-line replacements, so the line counts match
// and a full diff algorithm would earn nothing here.
func unifiedDiff(name, before, after string) string {
	a := strings.Split(before, "\n")
	b := strings.Split(after, "\n")
	if len(a) != len(b) {
		return fmt.Sprintf("--- a/%s\n+++ b/%s\n(line counts differ; the rewrite is not line-for-line)\n", name, name)
	}
	var changed []int
	for i := range a {
		if a[i] != b[i] {
			changed = append(changed, i)
		}
	}
	if len(changed) == 0 {
		return ""
	}
	const ctx = 3
	var out strings.Builder
	fmt.Fprintf(&out, "--- a/%s\n+++ b/%s\n", name, name)
	i := 0
	for i < len(changed) {
		start := max(0, changed[i]-ctx)
		end := min(len(a)-1, changed[i]+ctx)
		j := i
		for j+1 < len(changed) && changed[j+1]-ctx <= end+1 {
			j++
			end = min(len(a)-1, changed[j]+ctx)
		}
		fmt.Fprintf(&out, "@@ -%d,%d +%d,%d @@\n", start+1, end-start+1, start+1, end-start+1)
		for k := start; k <= end; k++ {
			if a[k] == b[k] {
				out.WriteString(" " + a[k] + "\n")
				continue
			}
			out.WriteString("-" + a[k] + "\n")
			out.WriteString("+" + b[k] + "\n")
		}
		i = j + 1
	}
	return out.String()
}
