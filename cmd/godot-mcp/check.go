package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// checkFile is one script's verdict: the res:// path, whether it parsed, the
// diagnostics the engine printed for it, and the argv that produced them.
type checkFile struct {
	Path    string           `json:"path"`
	OK      bool             `json:"ok"`
	Command []string         `json:"command"`
	Errors  []engineLogEntry `json:"errors"`
}

// checkResult is the JSON shape of `check --json` (and of piped output).
type checkResult struct {
	ProjectPath string      `json:"project_path"`
	Log         string      `json:"log"`
	Total       int         `json:"total"`
	Failed      int         `json:"failed"`
	DurationMS  int64       `json:"duration_ms"`
	Files       []checkFile `json:"files"`
}

// runCheck is a local subcommand that parses GDScript cold: one headless engine
// per file with --check-only, no editor involved. It is the compile step a CI
// job wants and the fast feedback loop an agent wants after writing a script.
//
// This is a parse check. The engine loads the script and reports parse and
// resolution errors; it does not run the project, resolve autoloads beyond what
// loading performs, or apply the editor's own script warnings. For the in-editor
// form, which does see the open project, use godot-mcp script validate.
func runCheck(args []string) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	jobs := fs.Int("jobs", 4, "how many engine processes to run at once")
	timeout := fs.Duration("timeout", 5*time.Minute, "how long to let the whole sweep run")
	godot := fs.String("godot", "", "path to the Godot binary (default: godot on PATH)")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "parse GDScript files cold, with no editor",
		[]string{"godot-mcp check <file|dir>... [--jobs 4] [--project DIR] [--json]"},
		`Runs godot --headless --path <project> --script <file> --check-only per .gd
file and exits 1 if any of them fails. Directories are walked recursively;
.godot/ is always skipped, and addons/ is skipped unless the path you name is
itself inside addons.

This checks parsing only. There is no editor, so it sees no open scene and none
of the editor's own script warnings. The in-editor form is godot-mcp script
validate --path res://your/script.gd.

The full engine output for every file is written to
<project>/.godot/godot-mcp-check.log.`)
	positional, prc := parseSubPositional(fs, args)
	if prc >= 0 {
		return prc
	}
	if len(positional) == 0 {
		fmt.Fprintf(os.Stderr, "%s check needs at least one file or directory\n", ui.Err.Fail("error:"))
		return 2
	}
	if *jobs < 1 {
		*jobs = 1
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}

	scripts, cerr := collectScripts(root, positional)
	if cerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), cerr)
		return 2
	}
	if len(scripts) == 0 {
		fmt.Fprintf(os.Stderr, "%s no .gd files under %s\n", ui.Err.Warn("warning:"), strings.Join(positional, ", "))
		return 0
	}

	bin, berr := resolveGodotBinary(*godot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	started := time.Now()
	files, transcript := checkScripts(ctx, bin, root, scripts, *jobs)
	elapsed := time.Since(started)

	// One engine per file writing to one log would interleave, so the transcripts
	// are collected in memory (they are a handful of lines each) and written in
	// file order once the sweep is done.
	logPath := godotLogPath(root, "check")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err == nil {
		_ = os.WriteFile(logPath, []byte(transcript), 0o644)
	}

	failed := 0
	for _, f := range files {
		if !f.OK {
			failed++
		}
	}
	res := checkResult{
		ProjectPath: root,
		Log:         logPath,
		Total:       len(files),
		Failed:      failed,
		DurationMS:  elapsed.Milliseconds(),
		Files:       files,
	}

	line := fmt.Sprintf("%d files parsed clean in %s", res.Total, elapsed.Round(time.Millisecond))
	rc := 0
	if failed > 0 {
		line = fmt.Sprintf("%d of %d files failed to parse", failed, res.Total)
		rc = 1
	}
	if ctx.Err() != nil {
		line = fmt.Sprintf("the sweep did not finish within %s; see %s", *timeout, logPath)
		rc = 1
	}

	emitResult("check", res, *asJSON, line, [][2]string{
		{"project", res.ProjectPath},
		{"files", strconv.Itoa(res.Total)},
		{"failed", strconv.Itoa(res.Failed)},
		{"duration", elapsed.Round(time.Millisecond).String()},
		{"log", res.Log},
	})
	for _, f := range files {
		if f.OK {
			continue
		}
		fmt.Fprintln(os.Stderr, ui.Err.Fail(f.Path))
		for _, e := range f.Errors {
			fmt.Fprintln(os.Stderr, "  "+e.String())
		}
	}
	return rc
}

// checkScripts runs the parse check over every script, jobs at a time, and
// returns the per-file verdicts in the order given plus the combined transcript
// for the log.
func checkScripts(ctx context.Context, bin, root string, scripts []string, jobs int) ([]checkFile, string) {
	files := make([]checkFile, len(scripts))
	transcripts := make([]string, len(scripts))

	var wg sync.WaitGroup
	slots := make(chan struct{}, jobs)
	for i, script := range scripts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			files[i], transcripts[i] = checkOne(ctx, bin, root, script)
		}()
	}
	wg.Wait()

	var log strings.Builder
	for i, t := range transcripts {
		log.WriteString("=== " + scripts[i] + " ===\n")
		log.WriteString(t)
		if !strings.HasSuffix(t, "\n") {
			log.WriteString("\n")
		}
	}
	return files, log.String()
}

// checkOne parses a single script and returns its verdict plus the raw engine
// output. The engine's own exit code decides ok; the SCRIPT ERROR lines are the
// detail on top of it, and when it fails without any, the plain ERROR lines
// stand in so a failure is never reported with an empty cause.
func checkOne(ctx context.Context, bin, root, script string) (checkFile, string) {
	argv := checkArgs(root, script)
	cmd := exec.CommandContext(ctx, bin, argv...)
	cmd.Dir = root
	cmd.Stdin = nil
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()

	entries := parseEngineLog(bytes.NewReader(buf.Bytes()))
	errs, _ := splitEngineLog(entries)
	var scriptErrs []engineLogEntry
	for _, e := range errs {
		if strings.Contains(e.Level, "SCRIPT ERROR") {
			scriptErrs = append(scriptErrs, e)
		}
	}
	if len(scriptErrs) == 0 {
		scriptErrs = errs
	}

	f := checkFile{Path: script, OK: err == nil, Command: append([]string{bin}, argv...), Errors: orEmpty(scriptErrs)}
	if f.OK {
		// A clean exit is the verdict, so anything the engine printed about
		// other files is noise here.
		f.Errors = []engineLogEntry{}
	}
	return f, buf.String()
}

// checkArgs builds the child's argv for one script. --check-only makes --script
// parse and quit rather than run, and --headless keeps a window out of it.
func checkArgs(root, script string) []string {
	return []string{"--headless", "--path", root, "--script", script, "--check-only"}
}

// collectScripts expands the caller's paths into res:// script paths, sorted and
// deduplicated. A named file is taken as given; a directory is walked.
func collectScripts(root string, paths []string) ([]string, error) {
	seen := map[string]bool{}
	for _, p := range paths {
		local, err := localPath(root, p)
		if err != nil {
			return nil, err
		}
		info, serr := os.Stat(local)
		if serr != nil {
			return nil, fmt.Errorf("%s: %w", p, serr)
		}
		if !info.IsDir() {
			if !strings.EqualFold(filepath.Ext(local), ".gd") {
				return nil, fmt.Errorf("%s is not a .gd file", p)
			}
			res, rerr := toResPath(root, local)
			if rerr != nil {
				return nil, rerr
			}
			seen[res] = true
			continue
		}
		// addons/ holds third-party code the caller did not write, so a sweep of
		// the project skips it. Naming a path inside addons is the opt-in.
		skipAddons := !underAddons(root, local)
		werr := filepath.WalkDir(local, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				name := d.Name()
				if name == ".godot" || (skipAddons && name == "addons") {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.EqualFold(filepath.Ext(path), ".gd") {
				return nil
			}
			res, rerr := toResPath(root, path)
			if rerr != nil {
				return rerr
			}
			seen[res] = true
			return nil
		})
		if werr != nil {
			return nil, werr
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out, nil
}

// localPath turns a caller-supplied path, which may be a res:// URI, into a path
// on disk inside the project.
func localPath(root, p string) (string, error) {
	if rest, ok := strings.CutPrefix(p, "res://"); ok {
		return filepath.Join(root, filepath.FromSlash(rest)), nil
	}
	return filepath.Abs(p)
}

// underAddons reports whether a path sits inside the project's addons/ tree,
// which is what turns the addons skip off for that sweep.
func underAddons(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if part == "addons" {
			return true
		}
	}
	return false
}
