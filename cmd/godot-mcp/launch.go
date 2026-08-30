package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// launchAction is what the discovery verdict licenses. It exists so the launch
// policy the skill teaches in prose (never stack an editor; wait on starting;
// relaunch once after a crash) is one testable decision rather than a chain of
// ifs around a process spawn.
type launchAction int

const (
	actionSpawn  launchAction = iota // nothing serves this project: start one editor
	actionWait                       // an editor of ours is booting: wait, never spawn
	actionRefuse                     // an editor is already running: do nothing
)

// launchResult is the JSON shape of `launch --json` (and of piped output).
type launchResult struct {
	Verdict     client.Verdict `json:"verdict"`
	Port        int            `json:"port"`
	PID         int            `json:"pid,omitempty"`
	Launched    bool           `json:"launched"`
	Headless    bool           `json:"headless"`
	Log         string         `json:"log"`
	ProjectPath string         `json:"project_path"`
}

// runLaunch is a local subcommand (it never dials a command through the addon;
// its only network work is the same liveness probe `status` runs) that brings up
// exactly one editor for this project, applying the discovery verdict rather
// than launching blindly. Exit 0 when an editor is running (or already was),
// non-zero when the wait timed out or nothing could be started.
func runLaunch(args []string) int {
	fs := flag.NewFlagSet("launch", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	headless := fs.Bool("headless", false, "launch the editor with --headless (no window)")
	wait := fs.Bool("wait", true, "wait for the editor to accept connections before returning")
	timeout := fs.Duration("timeout", 90*time.Second, "how long to wait for the editor to come up")
	godot := fs.String("godot", "", "path to the Godot binary (default: godot on PATH)")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "launch one editor for this project",
		[]string{"godot-mcp launch [--project DIR] [--headless] [--wait=false] [--timeout 90s] [--godot PATH] [--json]"},
		`Applies the discovery verdict instead of launching blindly: running refuses
(a second editor stacks and breaks discovery), starting waits, crashed and
closed each start one. The editor is detached and its stdout/stderr go to
<project>/.godot/godot-mcp-launch.log, never to this terminal.

With --wait=false the verdict reported is the one that licensed the launch, and
the pid is the process this CLI started, which on Windows is the launcher shim
rather than the editor itself. Run status afterwards for the editor's own pid.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, err := projectRootFor(*project)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), err)
		return 2
	}
	logPath := godotLogPath(root, "launch")

	// The verdict already accounts for a stranger's editor answering on a guessed
	// port: Diagnose re-derives closed/crashed on a project mismatch, because as
	// far as this project is concerned nothing is serving it.
	st := client.Diagnose(root, 0)
	action, reason := decideLaunch(st)

	switch action {
	case actionRefuse:
		emitLaunch(launchResult{st.Verdict, st.Port, st.PID, false, *headless, logPath, root}, *asJSON, reason)
		return 0
	case actionWait:
		if !*wait {
			emitLaunch(launchResult{st.Verdict, st.Port, st.PID, false, *headless, logPath, root}, *asJSON, reason)
			return 0
		}
	case actionSpawn:
		bin, berr := resolveGodotBinary(*godot)
		if berr != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
			return 2
		}
		pid, serr := spawnGodot(bin, root, logPath, editorArgs(root, *headless))
		if serr != nil {
			fmt.Fprintf(os.Stderr, "%s could not launch %s: %v\n", ui.Err.Fail("error:"), bin, serr)
			return 2
		}
		st.PID = pid
		if !*wait {
			emitLaunch(launchResult{st.Verdict, st.Port, pid, true, *headless, logPath, root},
				*asJSON, fmt.Sprintf("launched %s (pid %d); not waiting", bin, pid))
			return 0
		}
	}

	launched := action == actionSpawn
	final := waitForEditor(root, *timeout)
	if final.PID == 0 {
		final.PID = st.PID
	}
	res := launchResult{final.Verdict, final.Port, final.PID, launched, *headless, logPath, root}
	if final.Verdict == client.VerdictRunning {
		emitLaunch(res, *asJSON, fmt.Sprintf("editor running on port %d", final.Port))
		return 0
	}
	emitLaunch(res, *asJSON, fmt.Sprintf("editor did not come up within %s (verdict %s); see %s",
		*timeout, final.Verdict, logPath))
	return 1
}

// decideLaunch turns a liveness verdict into the one move the launch policy
// allows, with the line to show for it. Refusing on running is what keeps a
// second editor off the port, and nothing overrides it: stacking breaks
// discovery for every client on the machine, not just this caller.
func decideLaunch(st client.Status) (launchAction, string) {
	switch st.Verdict {
	case client.VerdictRunning:
		return actionRefuse, fmt.Sprintf("editor already running on port %d; not launching another", st.Port)
	case client.VerdictStarting:
		return actionWait, fmt.Sprintf("editor already booting on port %d (pid %d); waiting rather than launching", st.Port, st.PID)
	case client.VerdictCrashed:
		return actionSpawn, fmt.Sprintf("previous editor crashed (pid %d is gone); launching one", st.PID)
	case client.VerdictClosed:
		return actionSpawn, "no editor is serving this project; launching one"
	default:
		return actionRefuse, fmt.Sprintf("unknown verdict %q; not launching", st.Verdict)
	}
}

// editorArgs builds the child's argv. --path anchors the editor on this
// project's root, which is what makes the addon bind for THIS project rather
// than whatever the binary last opened.
func editorArgs(root string, headless bool) []string {
	args := []string{"--path", root, "--editor"}
	if headless {
		args = append(args, "--headless")
	}
	return args
}

// resolveGodotBinary finds the Godot launcher: an explicit path wins, else
// "godot" on PATH, else the Windows shim name. It deliberately never resolves
// "godot-dev": that slot tracks engine master, and work here targets the stable
// build. Shared with doctor's binary check so both report the same binary.
func resolveGodotBinary(override string) (string, error) {
	if override != "" {
		path, err := exec.LookPath(override)
		if err != nil {
			return "", fmt.Errorf("--godot %s is not runnable: %w", override, err)
		}
		return path, nil
	}
	path, err := exec.LookPath("godot")
	if err != nil {
		path, err = exec.LookPath("godot.cmd")
	}
	if err != nil {
		return "", fmt.Errorf("godot not found on PATH (pass --godot PATH)")
	}
	return path, nil
}

// waitForEditor polls the same diagnosis `status` reports until the editor is
// reachable or the deadline passes, returning whatever verdict it ended on.
func waitForEditor(root string, timeout time.Duration) client.Status {
	deadline := time.Now().Add(timeout)
	for {
		st := client.Diagnose(root, 0)
		if st.Verdict == client.VerdictRunning {
			return st
		}
		if !time.Now().Before(deadline) {
			return st
		}
		time.Sleep(time.Second)
	}
}

// emitLaunch renders the outcome through the shared local-subcommand emitter:
// JSON when asked for or when piped, the key/value summary on a terminal.
func emitLaunch(res launchResult, asJSON bool, line string) {
	rows := [][2]string{
		{"project", res.ProjectPath},
		{"verdict", string(res.Verdict)},
		{"port", fmt.Sprint(res.Port)},
	}
	if res.PID > 0 {
		rows = append(rows, [2]string{"pid", fmt.Sprint(res.PID)})
	}
	rows = append(rows,
		[2]string{"launched", fmt.Sprint(res.Launched)},
		[2]string{"headless", fmt.Sprint(res.Headless)},
		[2]string{"log", res.Log})
	emitResult("launch", res, asJSON, line, rows)
}
