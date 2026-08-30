package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// importResult is the JSON shape of `import --json` (and of piped output).
type importResult struct {
	ProjectPath string           `json:"project_path"`
	Command     []string         `json:"command"`
	Log         string           `json:"log"`
	ExitCode    int              `json:"exit_code"`
	DurationMS  int64            `json:"duration_ms"`
	Errors      []engineLogEntry `json:"errors"`
	Warnings    []engineLogEntry `json:"warnings"`
}

// runImport is a local subcommand that reimports the project's assets from a
// cold start, which is what a fresh clone or a CI checkout needs before anything
// else will open. It runs the editor headless purely to build .godot/, then quits.
//
// It refuses while an editor is running on the same project. That editor owns
// the same .godot/ cache, and two writers on it is the one case in this group
// that genuinely corrupts state rather than merely reading stale files.
func runImport(args []string) int {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	timeout := fs.Duration("timeout", 10*time.Minute, "how long to let the import run")
	godot := fs.String("godot", "", "path to the Godot binary (default: godot on PATH)")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "import the project's assets headlessly",
		[]string{"godot-mcp import [--project DIR] [--timeout 10m] [--godot PATH] [--json]"},
		`Runs godot --headless --path <project> --import --quit in the foreground and
exits with Godot's own code. Use it on a fresh clone or in CI, before launch or
export, so the .godot/ import cache exists.

It refuses while an editor is running on this project, because that editor is
writing the same cache. Reimport a file in the open editor instead, with
godot-mcp import reimport --path res://....

Godot's stdout and stderr go to <project>/.godot/godot-mcp-import.log, with the
ERROR and WARNING lines parsed into the result.

The addon's import group keeps this name: godot-mcp import info, import set and
import reimport still reach the editor.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}

	if st := client.Diagnose(root, 0); st.Verdict == client.VerdictRunning {
		fmt.Fprintf(os.Stderr, "%s an editor is running on this project (port %d) and owns the same .godot/ import cache; a headless import would fight it.\n",
			ui.Err.Fail("error:"), st.Port)
		fmt.Fprintln(os.Stderr, "Close that editor and retry, or reimport in place: godot-mcp import reimport --path res://your/file.png")
		return 1
	}

	bin, berr := resolveGodotBinary(*godot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}

	argv := importArgs(root)
	logPath := godotLogPath(root, "import")

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	code, elapsed, xerr := runGodotWait(ctx, bin, root, logPath, argv)
	if xerr != nil {
		fmt.Fprintf(os.Stderr, "%s could not run %s: %v\n", ui.Err.Fail("error:"), bin, xerr)
		return 2
	}

	errs, warns := splitEngineLog(readEngineLog(logPath))
	res := importResult{
		ProjectPath: root,
		Command:     append([]string{bin}, argv...),
		Log:         logPath,
		ExitCode:    code,
		DurationMS:  elapsed.Milliseconds(),
		Errors:      orEmpty(errs),
		Warnings:    orEmpty(warns),
	}

	line := fmt.Sprintf("imported in %s", elapsed.Round(time.Millisecond))
	rc := 0
	switch {
	case ctx.Err() != nil:
		line = fmt.Sprintf("import did not finish within %s; see %s", *timeout, logPath)
		rc = 1
	case code != 0:
		line = fmt.Sprintf("godot exited %d; see %s", code, logPath)
		rc = code
	case len(errs) > 0:
		line = fmt.Sprintf("imported in %s with %d error lines; see %s", elapsed.Round(time.Millisecond), len(errs), logPath)
	}

	emitResult("import", res, *asJSON, line, [][2]string{
		{"project", res.ProjectPath},
		{"exit", strconv.Itoa(res.ExitCode)},
		{"duration", elapsed.Round(time.Millisecond).String()},
		{"errors", strconv.Itoa(len(res.Errors))},
		{"warnings", strconv.Itoa(len(res.Warnings))},
		{"log", res.Log},
	})
	for _, e := range res.Errors {
		fmt.Fprintln(os.Stderr, ui.Err.Fail("  "+e.String()))
	}
	return rc
}

// importArgs builds the child's argv. --import starts the editor, waits for
// every resource to import, and quits; --quit makes that explicit for a build
// that would otherwise sit on the first iteration.
func importArgs(root string) []string {
	return []string{"--headless", "--path", root, "--import", "--quit"}
}
