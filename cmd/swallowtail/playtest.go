package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/playtest"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// playtest is split across the wire. Recording runs in the game through the
// addon's playtest group (start, mark, event, status, stop), which main routes
// to the editor through shadowedAddonCommands. Reading a recording is local and
// needs no editor: `report` analyzes one session file and `compare` diffs two.

// runPlaytest dispatches the local half of `swallowtail playtest`.
func runPlaytest(args []string) int {
	if len(args) == 0 {
		playtestUsage()
		return 2
	}
	switch args[0] {
	case "help", "--help", "-h":
		playtestUsage()
		return 0
	case "report":
		return runPlaytestReport(args[1:])
	case "compare":
		return runPlaytestCompare(args[1:])
	}
	fmt.Fprintf(os.Stderr, "%s unknown playtest command %q\n", ui.Err.Fail("error:"), args[0])
	playtestUsage()
	return 2
}

func playtestUsage() {
	p := ui.Err
	w := os.Stderr
	fmt.Fprintln(w, p.Heading("swallowtail playtest")+": record a play session in the running game, then report on it")
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Usage:"))
	for _, u := range []string{
		"swallowtail playtest start [--name NAME] [--sample-every N]",
		"swallowtail playtest mark --label LABEL",
		"swallowtail playtest event --name NAME [--data JSON]",
		"swallowtail playtest status",
		"swallowtail playtest stop",
		"swallowtail playtest report <session.json>|--latest [--format md|json] [--out FILE]",
		"swallowtail playtest compare <before.json> <after.json> [--format md|json] [--out FILE]",
	} {
		fmt.Fprintln(w, "  "+tintSlots(u, p))
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, `start, mark, event, status, and stop run in the playing game through the editor
(or a standalone debug game with --game before the group). stop writes the session to
the game's user://swallowtail-playtests/ and prints its path.

report and compare run locally with no editor. --latest reads the newest session in
the game's user-data dir, found from the project's project.godot (--project DIR, or
the project containing the current directory). compare --latest diffs the two newest
sessions, or the one path you give against the newest.

Game code reports its own facts with one line, a no-op when nothing is recording:
  MCPGameInspector.playtest_event("death", {"wave": 3})`)
}

// playtestFlags are the flags report and compare share.
type playtestFlags struct {
	format    *string
	out       *string
	latest    *bool
	project   *string
	targetFPS *float64
}

func newPlaytestFlags(fs *flag.FlagSet) playtestFlags {
	return playtestFlags{
		format:    fs.String("format", "md", "md (Markdown) or json"),
		out:       fs.String("out", "", "write the result to FILE instead of stdout (written atomically)"),
		latest:    fs.Bool("latest", false, "use the newest session in the game's user-data dir"),
		project:   fs.String("project", "", "Godot project dir, for --latest (default: the project containing the cwd)"),
		targetFPS: fs.Float64("target-fps", playtest.DefaultTargetFPS, "frame-rate target the budget and findings measure against"),
	}
}

func (f playtestFlags) validate() error {
	if *f.format != "md" && *f.format != "json" {
		return fmt.Errorf("--format must be md or json, got %q", *f.format)
	}
	if *f.targetFPS <= 0 || *f.targetFPS > 1000 {
		return fmt.Errorf("--target-fps must be between 0 and 1000, got %g", *f.targetFPS)
	}
	return nil
}

func runPlaytestReport(args []string) int {
	fs := flag.NewFlagSet("playtest report", flag.ContinueOnError)
	pf := newPlaytestFlags(fs)
	fs.Usage = subHelp(fs, "analyze one recorded playtest session, with no editor",
		[]string{
			"swallowtail playtest report <session.json> [--format md|json] [--out FILE]",
			"swallowtail playtest report --latest [--project DIR] [--target-fps 60]",
		},
		`Reports frame-time percentiles and 1% lows, spikes with the input or event that came
just before each, memory and node trends, runtime errors, per-section numbers, the
event funnel, input rate, and findings that name something concrete to look at.`)
	positional, rc := parseSubPositional(fs, args)
	if rc >= 0 {
		return rc
	}
	if err := pf.validate(); err != nil {
		return playtestUsageError(err)
	}
	var path string
	switch {
	case *pf.latest && len(positional) == 0:
		paths, err := latestPlaytestSessions(*pf.project)
		if err != nil {
			return playtestFail(err)
		}
		path = paths[0]
	case !*pf.latest && len(positional) == 1:
		path = positional[0]
	default:
		return playtestUsageError(errors.New("report takes one session file, or --latest"))
	}
	report, err := loadPlaytestReport(path, *pf.targetFPS)
	if err != nil {
		return playtestFail(err)
	}
	var out []byte
	if *pf.format == "json" {
		out, err = json.MarshalIndent(report, "", "  ")
		if err != nil {
			return playtestFail(err)
		}
		out = append(out, '\n')
	} else {
		out = []byte(playtest.Markdown(report))
	}
	return emitPlaytestOutput(out, *pf.out)
}

func runPlaytestCompare(args []string) int {
	fs := flag.NewFlagSet("playtest compare", flag.ContinueOnError)
	pf := newPlaytestFlags(fs)
	fs.Usage = subHelp(fs, "diff two recorded playtest sessions, with no editor",
		[]string{
			"swallowtail playtest compare <before.json> <after.json> [--format md|json] [--out FILE]",
			"swallowtail playtest compare <before.json> --latest",
			"swallowtail playtest compare --latest   (the two newest sessions)",
		},
		`Puts the same numbers side by side with a delta and a verdict per metric
(improved, regressed, unchanged; changed for a metric with no better direction),
then an overall verdict. A change counts once it passes 5% of the before value and
the metric's own floor. Differences in how the two sessions ran (headless, window
size, vsync, GPU, engine version) are listed first, since each moves frame times.`)
	positional, rc := parseSubPositional(fs, args)
	if rc >= 0 {
		return rc
	}
	if err := pf.validate(); err != nil {
		return playtestUsageError(err)
	}
	var before, after string
	switch {
	case !*pf.latest && len(positional) == 2:
		before, after = positional[0], positional[1]
	case *pf.latest && len(positional) <= 1:
		paths, err := latestPlaytestSessions(*pf.project)
		if err != nil {
			return playtestFail(err)
		}
		if len(positional) == 1 {
			before, after = positional[0], paths[0]
		} else {
			if len(paths) < 2 {
				return playtestFail(fmt.Errorf("compare --latest needs two sessions and %s holds one", filepath.Dir(paths[0])))
			}
			before, after = paths[1], paths[0]
		}
	default:
		return playtestUsageError(errors.New("compare takes two session files, one file plus --latest, or --latest alone"))
	}
	if sameFile(before, after) {
		return playtestUsageError(fmt.Errorf("before and after are the same file: %s", before))
	}
	a, err := loadPlaytestReport(before, *pf.targetFPS)
	if err != nil {
		return playtestFail(err)
	}
	b, err := loadPlaytestReport(after, *pf.targetFPS)
	if err != nil {
		return playtestFail(err)
	}
	cmp := playtest.Compare(a, b)
	var out []byte
	if *pf.format == "json" {
		out, err = json.MarshalIndent(cmp, "", "  ")
		if err != nil {
			return playtestFail(err)
		}
		out = append(out, '\n')
	} else {
		out = []byte(playtest.CompareMarkdown(cmp))
	}
	return emitPlaytestOutput(out, *pf.out)
}

func loadPlaytestReport(path string, targetFPS float64) (playtest.Report, error) {
	s, err := playtest.Load(path)
	if err != nil {
		return playtest.Report{}, fmt.Errorf("%s: %w", path, err)
	}
	r := playtest.Analyze(s, playtest.Options{TargetFPS: targetFPS})
	if abs, aerr := filepath.Abs(path); aerr == nil {
		r.Source = abs
	} else {
		r.Source = path
	}
	return r, nil
}

// latestPlaytestSessions lists the project's recorded sessions, newest first.
// The folder is the game's user-data dir, derived from project.godot exactly as
// the --game channel finds the game's discovery file.
func latestPlaytestSessions(project string) ([]string, error) {
	root, err := projectRootFor(project)
	if err != nil {
		return nil, err
	}
	dir, err := client.GameUserDataDir(root)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", filepath.Join(root, "project.godot"), err)
	}
	paths, err := playtest.Newest(filepath.Join(dir, playtest.SessionsDir))
	if err != nil {
		if errors.Is(err, playtest.ErrNoSessions) {
			return nil, fmt.Errorf("%w; record one with playtest start, then playtest stop", err)
		}
		return nil, err
	}
	return paths, nil
}

func emitPlaytestOutput(out []byte, dest string) int {
	if dest == "" {
		if _, err := os.Stdout.Write(out); err != nil {
			return playtestFail(err)
		}
		return 0
	}
	if err := writePlaytestFile(dest, out); err != nil {
		return playtestFail(err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s\n", dest)
	return 0
}

// writePlaytestFile writes data to path through a temporary file in the same
// directory and a rename, so a reader never sees a half-written report and a
// failed write leaves any earlier file at that path intact.
func writePlaytestFile(path string, data []byte) (err error) {
	dir := filepath.Dir(path)
	if err = os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if _, err = tmp.Write(data); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func sameFile(a, b string) bool {
	ia, errA := os.Stat(a)
	ib, errB := os.Stat(b)
	return errA == nil && errB == nil && os.SameFile(ia, ib)
}

func playtestUsageError(err error) int {
	fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
	return 2
}

func playtestFail(err error) int {
	fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
	return 1
}
