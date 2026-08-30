package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// Phase 2. A screenshot proves one frame. What catches a regression is a drive,
// written once and replayed identically on both sides of the port, so the
// scenario file baseline reads is the same file verify replays.
//
// The drive runs against the game's own direct channel rather than an editor,
// because the phase's requirement is the old binary and the direct channel is
// the only transport that needs no editor at all. The game has to be a debug
// build with godot_mcp/runtime/direct_server on, which is what godot-mcp run
// already requires.

// driveStep is one replayed step and what it produced.
type driveStep struct {
	Index  int            `json:"index"`
	Type   string         `json:"type"`
	OK     bool           `json:"ok"`
	Detail string         `json:"detail,omitempty"`
	Values map[string]any `json:"values,omitempty"`
	Image  string         `json:"image,omitempty"`
}

// driveCapture is one side of the comparison: what the game did under one
// binary. verify records the same shape under the new one and diffs the two.
type driveCapture struct {
	Phase         string           `json:"phase"`
	GeneratedUnix int64            `json:"generated_unix"`
	ProjectPath   string           `json:"project_path"`
	Binary        string           `json:"binary"`
	GodotVersion  string           `json:"godot_version"`
	Scenario      string           `json:"scenario,omitempty"`
	Mode          string           `json:"mode"`
	Port          int              `json:"port,omitempty"`
	Steps         []driveStep      `json:"steps,omitempty"`
	Numbers       map[string]any   `json:"numbers"`
	Screenshots   []string         `json:"screenshots"`
	Errors        []any            `json:"errors"`
	LogErrors     []engineLogEntry `json:"log_errors"`
	Frames        int              `json:"frames,omitempty"`
	Dir           string           `json:"dir"`
	ExitCode      *int             `json:"exit_code,omitempty"`
}

// scenarioStep mirrors the step list test.run_scenario takes, so one file
// serves the hand-run path and this one. assert steps are replayed as
// measurements: the recorded value is what the delta table diffs, and whether
// it satisfied an operator on the old build says nothing about the port.
type scenarioStep struct {
	Type        string   `json:"type"`
	Seconds     float64  `json:"seconds"`
	Action      string   `json:"action"`
	Keycode     string   `json:"keycode"`
	Pressed     *bool    `json:"pressed"`
	AutoRelease *bool    `json:"auto_release"`
	Strength    *float64 `json:"strength"`
	NodePath    string   `json:"node_path"`
	Property    string   `json:"property"`
	Properties  []string `json:"properties"`
	SavePath    string   `json:"save_path"`
}

// runUpgradeBaseline records how the game behaves under the old binary.
func runUpgradeBaseline(args []string) int {
	fs := flag.NewFlagSet("upgrade baseline", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	oldGodot := fs.String("old-godot", "", "path to the binary the project was built in (required)")
	scenario := fs.String("scenario", "", "JSON step list to replay, the same shape test run-scenario takes")
	frames := fs.Int("frames", 300, "frames to record when there is no scenario to replay")
	timeout := fs.Duration("timeout", 5*time.Minute, "how long to let the drive run")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "record how the game behaves under the old binary",
		[]string{"godot-mcp upgrade baseline --old-godot PATH [--scenario FILE] [--frames 300] [--json]"},
		`Runs the game standalone under the old binary and records what it did, into
`+"`"+upgradeReportDir+"/baseline/`"+`: the numbers, the screenshots, and the runtime errors.

With --scenario it replays the step list over the game's own direct channel,
which needs the godot_mcp/runtime/direct_server project setting and a debug
build. assert steps are replayed as measurements, so the value each one reads
is recorded rather than judged; verify replays the identical file and diffs the
two sets.

Without --scenario it records --frames frames with --write-movie at a fixed 60
fps and quits, which gives a frame sequence to compare and the run log's own
error lines.

Run the whole baseline twice and keep both sets. The spread between two runs of
the same build is the comparison threshold, and nothing in a real game replays
bit-identically.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}
	if *oldGodot == "" {
		fmt.Fprintf(os.Stderr, "%s upgrade baseline needs --old-godot: the whole point is the version the project came from, and it is never guessed\n", ui.Err.Fail("error:"))
		return 2
	}
	return runUpgradeDrive(root, "baseline", "baseline", *oldGodot, *scenario, *frames, *timeout, *asJSON, false)
}

// runUpgradeDrive plays the game under one binary and writes a driveCapture.
// baseline and verify are the same drive under different binaries, which is
// what makes their numbers comparable at all.
func runUpgradeDrive(root, relDir, phase, bin, scenarioPath string, frames int, timeout time.Duration, asJSON, quiet bool) int {
	resolved, berr := resolveGodotBinary(bin)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}
	version, verr := godotVersion(resolved)
	if verr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), verr)
		return 2
	}
	dir := filepath.Join(root, filepath.FromSlash(upgradeReportDir), relDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	capt := driveCapture{
		Phase:         phase,
		GeneratedUnix: time.Now().Unix(),
		ProjectPath:   root,
		Binary:        resolved,
		GodotVersion:  version,
		Scenario:      scenarioPath,
		Numbers:       map[string]any{},
		Screenshots:   []string{},
		Errors:        []any{},
		LogErrors:     []engineLogEntry{},
		Dir:           dir,
	}

	var steps []scenarioStep
	if scenarioPath != "" {
		s, serr := readScenario(scenarioPath)
		if serr != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), serr)
			return 2
		}
		steps = s
	}

	// A game already serving this project would have its discovery file
	// rewritten by a second one, and the drive would then talk to whichever
	// won. Same no-stacking rule godot-mcp run applies.
	if d, derr := client.ReadGameDiscovery(root); derr == nil && d.Port > 0 && client.PIDAlive(d.PID) {
		fmt.Fprintf(os.Stderr, "%s a game from this project is already running (pid %d, port %d); stop it first\n",
			ui.Err.Fail("error:"), d.PID, d.Port)
		return 1
	}

	logPath := godotLogPath(root, "upgrade-"+phase)
	if len(steps) == 0 {
		capt.Mode = "movie"
		rc := driveMovie(root, dir, resolved, logPath, frames, timeout, &capt)
		return finishDrive(root, relDir, phase, capt, asJSON, quiet, rc)
	}

	capt.Mode = "scenario"
	if !projectBoolSetting(root, "godot_mcp", "runtime/direct_server") {
		fmt.Fprintf(os.Stderr, "%s replaying a scenario needs the game's direct channel, which is off for this project.\n", ui.Err.Fail("error:"))
		fmt.Fprintln(os.Stderr, "Turn it on and commit the change: godot-mcp project set-setting --key godot_mcp/runtime/direct_server --value true")
		return 1
	}
	rc := driveScenario(root, dir, resolved, logPath, steps, timeout, &capt)
	return finishDrive(root, relDir, phase, capt, asJSON, quiet, rc)
}

// driveMovie records a fixed-length run to numbered PNGs. The engine writes
// frames until the scene quits, so --quit-after bounds it and the run is
// finite by construction. The PNG writer numbers the frames itself
// (frame00000000.png ...); a %d in the name is copied literally, not expanded.
func driveMovie(root, dir, bin, logPath string, frames int, timeout time.Duration, capt *driveCapture) int {
	pattern := filepath.Join(dir, "frame.png")
	argv := gameArgs(root, gameRunOptions{
		Movie:    pattern,
		FixedFPS: 60,
		Extra:    "--quit-after " + strconv.Itoa(frames),
	})
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	code, _, xerr := runGodotWait(ctx, bin, root, logPath, argv)
	if xerr != nil {
		fmt.Fprintf(os.Stderr, "%s could not run %s: %v\n", ui.Err.Fail("error:"), bin, xerr)
		return 2
	}
	capt.ExitCode = &code
	errs, _ := splitEngineLog(readEngineLog(logPath))
	capt.LogErrors = orEmpty(errs)
	shots, _ := filepath.Glob(filepath.Join(dir, "frame*.png"))
	sort.Strings(shots)
	capt.Frames = len(shots)
	capt.Screenshots = shots
	if code != 0 {
		return 1
	}
	return 0
}

// driveScenario starts the game, replays the step list over the direct
// channel, and reads the runtime errors back before quitting it.
func driveScenario(root, dir, bin, logPath string, steps []scenarioStep, timeout time.Duration, capt *driveCapture) int {
	pid, serr := spawnGodot(bin, root, logPath, gameArgs(root, gameRunOptions{}))
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s could not launch %s: %v\n", ui.Err.Fail("error:"), bin, serr)
		return 2
	}
	_ = pid

	d := waitForGame(root, timeout)
	if d == nil {
		errs, _ := splitEngineLog(readEngineLog(logPath))
		capt.LogErrors = orEmpty(errs)
		fmt.Fprintf(os.Stderr, "%s the game's direct server did not bind; see %s\n", ui.Err.Fail("error:"), logPath)
		return 1
	}
	capt.Port = d.Port

	game := &gameSession{port: d.Port, timeout: 60 * time.Second}
	userDir, _ := client.GameUserDataDir(root)
	deadline := time.Now().Add(timeout)

	for i, st := range steps {
		if time.Now().After(deadline) {
			capt.Steps = append(capt.Steps, driveStep{Index: i, Type: st.Type, OK: false, Detail: "the drive ran out of time before this step"})
			break
		}
		capt.Steps = append(capt.Steps, replayStep(game, i, st, dir, userDir, capt))
	}

	if raw, rerr := game.call("runtime.errors", nil); rerr == nil {
		var payload struct {
			Errors []any `json:"errors"`
		}
		if json.Unmarshal(raw, &payload) == nil && payload.Errors != nil {
			capt.Errors = payload.Errors
		}
	}
	// Quit through the game itself rather than killing the process, so the
	// discovery file is cleared the way a clean exit clears it.
	_, _ = game.call("runtime.eval", map[string]any{"code": "get_tree().quit()"})
	waitForGameGone(root, 15*time.Second)

	errs, _ := splitEngineLog(readEngineLog(logPath))
	capt.LogErrors = orEmpty(errs)
	for _, s := range capt.Steps {
		if !s.OK {
			return 1
		}
	}
	return 0
}

// replayStep runs one scenario step against the running game.
func replayStep(game *gameSession, i int, st scenarioStep, dir, userDir string, capt *driveCapture) driveStep {
	out := driveStep{Index: i, Type: st.Type}
	switch strings.ToLower(st.Type) {
	case "wait":
		secs := st.Seconds
		if secs <= 0 {
			secs = 0.5
		}
		time.Sleep(time.Duration(secs * float64(time.Second)))
		out.OK = true
		out.Detail = fmt.Sprintf("waited %.3gs", secs)

	case "input":
		pressed := true
		if st.Pressed != nil {
			pressed = *st.Pressed
		}
		method, params := "input.action", map[string]any{"action": st.Action, "pressed": pressed}
		if st.Action == "" {
			method = "input.key"
			params = map[string]any{"keycode": st.Keycode, "pressed": pressed}
			if st.AutoRelease != nil {
				params["auto_release"] = *st.AutoRelease
			}
		} else if st.Strength != nil {
			params["strength"] = *st.Strength
		}
		if _, err := game.call(method, params); err != nil {
			out.Detail = err.Error()
			return out
		}
		out.OK = true
		// input.action carries no auto-release of its own, so a press that the
		// step wanted released gets its release here and a held press stays
		// held. That is the same distinction the craft doc calls the silent one.
		if method == "input.action" && pressed && (st.AutoRelease == nil || *st.AutoRelease) {
			_, _ = game.call("input.action", map[string]any{"action": st.Action, "pressed": false})
			out.Detail = "pressed and released " + st.Action
		} else if method == "input.action" && pressed {
			out.Detail = "holding " + st.Action
		} else {
			out.Detail = method + " sent"
		}

	case "assert", "measure":
		props := st.Properties
		if len(props) == 0 && st.Property != "" {
			props = []string{st.Property}
		}
		raw, err := game.call("runtime.get", map[string]any{"node_path": st.NodePath, "properties": props})
		if err != nil {
			out.Detail = err.Error()
			return out
		}
		var payload struct {
			Properties map[string]any `json:"properties"`
			Missing    []string       `json:"missing"`
		}
		if jerr := json.Unmarshal(raw, &payload); jerr != nil {
			out.Detail = jerr.Error()
			return out
		}
		out.Values = payload.Properties
		for k, v := range payload.Properties {
			capt.Numbers[st.NodePath+"."+k] = v
		}
		out.OK = len(payload.Missing) == 0
		if !out.OK {
			out.Detail = "properties the node does not have: " + strings.Join(payload.Missing, ", ")
		}

	case "screenshot":
		name := fmt.Sprintf("shot%02d.png", i)
		save := "user://godot-mcp-upgrade/" + name
		if _, err := game.call("runtime.screenshot", map[string]any{"save_path": save}); err != nil {
			out.Detail = err.Error()
			return out
		}
		dst := filepath.Join(dir, name)
		src := filepath.Join(userDir, "godot-mcp-upgrade", name)
		if cerr := copyFileTo(src, dst); cerr != nil {
			out.Detail = "the game saved the frame but it could not be collected: " + cerr.Error()
			return out
		}
		capt.Screenshots = append(capt.Screenshots, dst)
		out.Image = dst
		out.OK = true

	default:
		out.Detail = "unknown step type " + strconv.Quote(st.Type)
	}
	return out
}

// finishDrive writes the capture and renders the summary.
func finishDrive(root, relDir, phase string, capt driveCapture, asJSON, quiet bool, rc int) int {
	path, werr := writeUpgradeReport(root, filepath.Join(relDir, phase+".json"), capt)
	if werr != nil {
		fmt.Fprintf(os.Stderr, "%s writing the capture: %v\n", ui.Err.Fail("error:"), werr)
		return 2
	}
	rows := [][2]string{
		{"project", root},
		{"binary", capt.Binary},
		{"version", capt.GodotVersion},
		{"mode", capt.Mode},
		{"numbers", strconv.Itoa(len(capt.Numbers))},
		{"screenshots", strconv.Itoa(len(capt.Screenshots))},
		{"runtime errors", strconv.Itoa(len(capt.Errors))},
		{"log errors", strconv.Itoa(len(capt.LogErrors))},
		{"capture", path},
	}
	if quiet {
		// A drive run as somebody else's proof must not print: fix and verify
		// own stdout for that command, and a second document on it is what a
		// caller parsing the result trips over.
		return rc
	}
	line := fmt.Sprintf("%s recorded under %s: %d numbers, %d images, %d runtime errors",
		phase, capt.GodotVersion, len(capt.Numbers), len(capt.Screenshots), len(capt.Errors))
	emitResult("upgrade "+phase, capt, asJSON, line, rows)
	return rc
}

// readScenario loads a step list, accepting either a bare JSON array or an
// object with a steps key, which is how the same file feeds test run-scenario.
func readScenario(path string) ([]scenarioStep, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading the scenario: %w", err)
	}
	trimmed := strings.TrimSpace(string(b))
	if strings.HasPrefix(trimmed, "{") {
		var wrapper struct {
			Steps []scenarioStep `json:"steps"`
		}
		if jerr := json.Unmarshal(b, &wrapper); jerr != nil {
			return nil, fmt.Errorf("parsing the scenario: %w", jerr)
		}
		return wrapper.Steps, nil
	}
	var steps []scenarioStep
	if jerr := json.Unmarshal(b, &steps); jerr != nil {
		return nil, fmt.Errorf("parsing the scenario: %w", jerr)
	}
	if len(steps) == 0 {
		return nil, fmt.Errorf("%s has no steps", path)
	}
	return steps, nil
}

// copyFileTo copies the game's saved frame out of its user data dir and into
// the report directory, so the whole comparison lives in one place.
func copyFileTo(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if merr := os.MkdirAll(filepath.Dir(dst), 0o755); merr != nil {
		return merr
	}
	out, cerr := os.Create(dst)
	if cerr != nil {
		return cerr
	}
	defer out.Close()
	_, werr := io.Copy(out, in)
	return werr
}

// waitForGameGone waits for the game's discovery file to clear after a quit, so
// the next phase does not see a game that is on its way out.
func waitForGameGone(root string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d, err := client.ReadGameDiscovery(root)
		if err != nil || d.Port == 0 || !client.PIDAlive(d.PID) {
			return
		}
		time.Sleep(300 * time.Millisecond)
	}
}
