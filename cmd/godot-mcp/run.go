package main

import (
	"context"
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

// runResult is the JSON shape of `run --json` (and of piped output).
type runResult struct {
	ProjectPath  string   `json:"project_path"`
	Scene        string   `json:"scene,omitempty"`
	Command      []string `json:"command"`
	Log          string   `json:"log"`
	PID          int      `json:"pid"`
	DirectServer bool     `json:"direct_server"`
	Port         int      `json:"port,omitempty"`
	GamePID      int      `json:"game_pid,omitempty"`
	Connected    bool     `json:"connected"`
	Movie        string   `json:"movie,omitempty"`
	MovieExists  bool     `json:"movie_exists,omitempty"`
	ExitCode     *int     `json:"exit_code,omitempty"`
	Hint         string   `json:"hint,omitempty"`
}

// runRun is a local subcommand that starts the game standalone, with no editor
// in the picture. It is the counterpart to launch: launch brings up the editor
// so the addon binds, this brings up the game so its own direct server binds,
// and both refuse to stack a second instance on a live one.
//
// The engine flags it fronts are the ones a debugging session actually reaches
// for (the four debug overlays, fixed timing, fps and gpu profiling, movie
// writing); anything else goes through --extra verbatim.
func runRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	collisions := fs.Bool("debug-collisions", false, "draw collision shapes")
	paths := fs.Bool("debug-paths", false, "draw path lines")
	navigation := fs.Bool("debug-navigation", false, "draw navigation polygons")
	avoidance := fs.Bool("debug-avoidance", false, "draw navigation avoidance visuals")
	fixedFPS := fs.Int("fixed-fps", 0, "force a fixed frame rate, which also disables real-time sync")
	timeScale := fs.Float64("time-scale", 0, "force a time scale (1.0 is normal speed)")
	printFPS := fs.Bool("print-fps", false, "print the frame rate to the log")
	gpuProfile := fs.Bool("gpu-profile", false, "print a GPU profile of the slowest frame tasks")
	benchmarkFile := fs.String("benchmark-file", "", "write engine startup benchmarks to this JSON file")
	movie := fs.String("write-movie", "", "record the run to this .avi or .png path (forces fixed-fps)")
	maxFPS := fs.Int("max-fps", 0, "cap the frame rate (0 is unlimited)")
	disableVsync := fs.Bool("disable-vsync", false, "disable vertical sync, which speeds up movie writing")
	resolution := fs.String("resolution", "", "window size as WxH")
	windowed := fs.Bool("windowed", false, "force windowed mode")
	headless := fs.Bool("headless", false, "run with no window and a dummy audio driver")
	verbose := fs.Bool("verbose", false, "run the engine in verbose stdout mode")
	extra := fs.String("extra", "", "extra engine flags, appended verbatim and split on spaces")
	wait := fs.Bool("wait", true, "wait for the game's direct server to bind (or, with --write-movie, for the run to finish)")
	timeout := fs.Duration("timeout", 60*time.Second, "how long to wait")
	godot := fs.String("godot", "", "path to the Godot binary (default: godot on PATH)")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "run the game standalone, with no editor",
		[]string{"godot-mcp run [scene] [--headless] [--debug-collisions] [--wait=false] [--project DIR] [--json]"},
		`Starts godot --path <project> [scene] with the flags below, detached, and sends
its stdout and stderr to <project>/.godot/godot-mcp-run.log. The scene is
optional (the project's main scene runs otherwise) and takes either a res:// path
or a path on disk inside the project.

With --wait (the default) it polls the game's own discovery file until the direct
server binds, then reports the port to drive with godot-mcp --game. That channel
needs the godot_mcp/runtime/direct_server project setting; without it the command
returns as soon as the game is spawned and says so.

--write-movie ends the run when the scene quits, so with it --wait waits for the
process to exit and reports whether the movie file landed.

--extra is appended verbatim and split on spaces, with no quote handling: use it
for one-word flags and their values.`)
	positional, rc := parseSubPositional(fs, args)
	if rc >= 0 {
		return rc
	}

	if len(positional) > 1 {
		fmt.Fprintf(os.Stderr, "%s run takes at most one scene path\n", ui.Err.Fail("error:"))
		return 2
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}

	scene := ""
	if len(positional) == 1 {
		s, serr := toResPath(root, positional[0])
		if serr != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), serr)
			return 2
		}
		scene = s
	}

	// The same no-stacking rule launch applies to the editor: a second game
	// binding the direct-server range rewrites the discovery file the first one
	// wrote, and --game then talks to whichever won.
	if d, derr := client.ReadGameDiscovery(root); derr == nil && d.Port > 0 && client.PIDAlive(d.PID) {
		fmt.Fprintf(os.Stderr, "%s a game from this project is already running (pid %d, port %d); not starting another. Close it, or drive it with godot-mcp --game.\n",
			ui.Err.Fail("error:"), d.PID, d.Port)
		return 1
	}

	bin, berr := resolveGodotBinary(*godot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}

	opts := gameRunOptions{
		Scene:           scene,
		DebugCollisions: *collisions,
		DebugPaths:      *paths,
		DebugNavigation: *navigation,
		DebugAvoidance:  *avoidance,
		FixedFPS:        *fixedFPS,
		TimeScale:       *timeScale,
		PrintFPS:        *printFPS,
		GPUProfile:      *gpuProfile,
		Headless:        *headless,
		Verbose:         *verbose,
		DisableVsync:    *disableVsync,
		Windowed:        *windowed,
		Resolution:      *resolution,
		MaxFPS:          *maxFPS,
		Extra:           *extra,
	}
	if *benchmarkFile != "" {
		abs, aerr := filepath.Abs(*benchmarkFile)
		if aerr != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), aerr)
			return 2
		}
		opts.BenchmarkFile = abs
	}
	moviePath := ""
	if *movie != "" {
		abs, aerr := filepath.Abs(*movie)
		if aerr != nil {
			fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), aerr)
			return 2
		}
		moviePath = abs
		opts.Movie = abs
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "%s creating the movie directory: %v\n", ui.Err.Fail("error:"), err)
			return 2
		}
	}

	argv := gameArgs(root, opts)
	logPath := godotLogPath(root, "run")
	direct := projectBoolSetting(root, "godot_mcp", "runtime/direct_server")

	res := runResult{
		ProjectPath:  root,
		Scene:        scene,
		Command:      append([]string{bin}, argv...),
		Log:          logPath,
		DirectServer: direct,
		Movie:        moviePath,
	}

	// A movie run is finite by definition: the engine writes frames until the
	// scene quits. Waiting for the direct server there would report a port that
	// is about to disappear, so wait for the process instead.
	if moviePath != "" && *wait {
		ctx, cancel := context.WithTimeout(context.Background(), *timeout)
		defer cancel()
		code, elapsed, xerr := runGodotWait(ctx, bin, root, logPath, argv)
		if xerr != nil {
			fmt.Fprintf(os.Stderr, "%s could not run %s: %v\n", ui.Err.Fail("error:"), bin, xerr)
			return 2
		}
		res.ExitCode = &code
		if fi, serr := os.Stat(moviePath); serr == nil {
			res.MovieExists = !fi.IsDir()
		}
		line := fmt.Sprintf("run finished in %s (exit %d); movie at %s", elapsed.Round(time.Millisecond), code, moviePath)
		rc := code
		if ctx.Err() != nil {
			line = fmt.Sprintf("run did not finish within %s; see %s", *timeout, logPath)
			rc = 1
		} else if !res.MovieExists {
			line = fmt.Sprintf("run exited %d but wrote no movie to %s; see %s", code, moviePath, logPath)
			if rc == 0 {
				rc = 1
			}
		}
		emitRun(res, *asJSON, line)
		return rc
	}

	pid, serr := spawnGodot(bin, root, logPath, argv)
	if serr != nil {
		fmt.Fprintf(os.Stderr, "%s could not launch %s: %v\n", ui.Err.Fail("error:"), bin, serr)
		return 2
	}
	res.PID = pid

	switch {
	case !direct:
		res.Hint = "godot-mcp project set-setting --path godot_mcp/runtime/direct_server --value true"
		emitRun(res, *asJSON, fmt.Sprintf("game started (pid %d); the direct game channel is off for this project, so nothing to wait for", pid))
		return 0
	case !*wait:
		emitRun(res, *asJSON, fmt.Sprintf("game started (pid %d); not waiting for the direct server", pid))
		return 0
	}

	d := waitForGame(root, *timeout)
	if d == nil {
		emitRun(res, *asJSON, fmt.Sprintf("game started (pid %d) but its direct server did not bind within %s; see %s",
			pid, *timeout, logPath))
		return 1
	}
	res.Port = d.Port
	res.GamePID = d.PID
	res.Connected = true
	res.Hint = fmt.Sprintf("godot-mcp --game runtime tree   (port %d)", d.Port)
	emitRun(res, *asJSON, fmt.Sprintf("game running on the direct channel, port %d (pid %d)", d.Port, d.PID))
	return 0
}

// gameRunOptions is the flag set gameArgs turns into engine arguments, split out
// so argv construction is testable without a flag.FlagSet.
type gameRunOptions struct {
	Scene           string
	DebugCollisions bool
	DebugPaths      bool
	DebugNavigation bool
	DebugAvoidance  bool
	FixedFPS        int
	TimeScale       float64
	PrintFPS        bool
	GPUProfile      bool
	BenchmarkFile   string
	Movie           string
	MaxFPS          int
	DisableVsync    bool
	Resolution      string
	Windowed        bool
	Headless        bool
	Verbose         bool
	Extra           string
}

// gameArgs builds the child's argv. --path anchors the run on this project, and
// the scene rides as a positional res:// path after it, which is how the engine
// takes a scene to start.
func gameArgs(root string, o gameRunOptions) []string {
	args := []string{"--path", root}
	if o.Scene != "" {
		args = append(args, o.Scene)
	}
	if o.Headless {
		args = append(args, "--headless")
	}
	if o.Verbose {
		args = append(args, "--verbose")
	}
	if o.DebugCollisions {
		args = append(args, "--debug-collisions")
	}
	if o.DebugPaths {
		args = append(args, "--debug-paths")
	}
	if o.DebugNavigation {
		args = append(args, "--debug-navigation")
	}
	if o.DebugAvoidance {
		args = append(args, "--debug-avoidance")
	}
	if o.FixedFPS > 0 {
		args = append(args, "--fixed-fps", strconv.Itoa(o.FixedFPS))
	}
	if o.TimeScale > 0 {
		args = append(args, "--time-scale", strconv.FormatFloat(o.TimeScale, 'g', -1, 64))
	}
	if o.PrintFPS {
		args = append(args, "--print-fps")
	}
	if o.GPUProfile {
		args = append(args, "--gpu-profile")
	}
	if o.BenchmarkFile != "" {
		args = append(args, "--benchmark-file", o.BenchmarkFile)
	}
	if o.Movie != "" {
		args = append(args, "--write-movie", o.Movie)
	}
	if o.MaxFPS > 0 {
		args = append(args, "--max-fps", strconv.Itoa(o.MaxFPS))
	}
	if o.DisableVsync {
		args = append(args, "--disable-vsync")
	}
	if o.Resolution != "" {
		args = append(args, "--resolution", o.Resolution)
	}
	if o.Windowed {
		args = append(args, "--windowed")
	}
	// Verbatim, split on spaces and nothing else: quoting rules here would be a
	// second shell nobody asked for, and a flag that needs one belongs in a wrapper.
	args = append(args, strings.Fields(o.Extra)...)
	return args
}

// waitForGame polls the game's discovery file until the direct server has bound
// with a live pid, or the deadline passes. The file is written on bind and
// cleared on a clean exit, so its presence plus a live pid is the whole signal.
func waitForGame(root string, timeout time.Duration) *client.GameDiscovery {
	deadline := time.Now().Add(timeout)
	for {
		if d, err := client.ReadGameDiscovery(root); err == nil && d.Port > 0 && client.PIDAlive(d.PID) {
			return d
		}
		if !time.Now().Before(deadline) {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// emitRun renders the outcome through the shared local-subcommand emitter.
func emitRun(res runResult, asJSON bool, line string) {
	rows := [][2]string{{"project", res.ProjectPath}}
	if res.Scene != "" {
		rows = append(rows, [2]string{"scene", res.Scene})
	}
	if res.PID > 0 {
		rows = append(rows, [2]string{"pid", strconv.Itoa(res.PID)})
	}
	rows = append(rows, [2]string{"direct server", fmt.Sprint(res.DirectServer)})
	if res.Port > 0 {
		rows = append(rows,
			[2]string{"port", strconv.Itoa(res.Port)},
			[2]string{"game pid", strconv.Itoa(res.GamePID)})
	}
	if res.Movie != "" {
		rows = append(rows,
			[2]string{"movie", res.Movie},
			[2]string{"movie exists", fmt.Sprint(res.MovieExists)})
	}
	if res.ExitCode != nil {
		rows = append(rows, [2]string{"exit", strconv.Itoa(*res.ExitCode)})
	}
	rows = append(rows, [2]string{"log", res.Log})
	if res.Hint != "" {
		rows = append(rows, [2]string{"next", res.Hint})
	}
	emitResult("run", res, asJSON, line, rows)
}
