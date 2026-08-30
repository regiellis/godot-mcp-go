package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// This file holds what every local subcommand that runs the engine binary needs:
// resolving the project, starting the child with its output going to a log under
// .godot/, and reading Godot's own ERROR/WARNING lines back out of that log.
// launch, export, run, import and check are thin layers on top of it, so the
// child never inherits the caller's terminal and every result can name the exact
// argv it ran.

// projectRootFor resolves the project a local subcommand operates on: --project
// when given, else the project containing the cwd, found by walking up to the
// directory holding project.godot.
func projectRootFor(project string) (string, error) {
	start := project
	if start == "" {
		start, _ = os.Getwd()
	}
	root, err := client.FindProjectRoot(start)
	if err != nil {
		return "", fmt.Errorf("no project.godot found from %s upward (pass --project or run inside a project)", start)
	}
	return root, nil
}

// godotLogPath names the per-subcommand log under the project's session-scoped,
// git-ignored .godot/. One file per subcommand, truncated per run: the log
// answers "what did the run I just started print", and a growing file buries
// that under old sessions.
func godotLogPath(root, name string) string {
	return filepath.Join(root, ".godot", "godot-mcp-"+name+".log")
}

// startGodot starts a Godot child with stdout and stderr going to logPath, and
// returns the running command plus the open log file for the caller to close.
// detached severs the child from this process and its console, which is what
// lets a short-lived CLI exit while the game or editor lives on; a foreground
// run leaves it attached so a Ctrl+C in the calling shell reaches it.
func startGodot(ctx context.Context, bin, root, logPath string, args []string, detached bool) (*exec.Cmd, *os.File, error) {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return nil, nil, fmt.Errorf("creating the log directory: %w", err)
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, nil, fmt.Errorf("opening %s: %w", logPath, err)
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = root
	cmd.Stdin = nil
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if detached {
		cmd.SysProcAttr = detachedAttr()
	}
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return nil, nil, err
	}
	return cmd, logFile, nil
}

// spawnGodot starts a detached child and returns its pid. Release drops every
// handle this process holds on it: no wait, no lifetime tie, and no zombie left
// behind on Unix when the CLI exits first. On Windows the pid can belong to the
// launcher shim rather than the engine, so a discovery file's pid outranks it.
func spawnGodot(bin, root, logPath string, args []string) (int, error) {
	cmd, logFile, err := startGodot(context.Background(), bin, root, logPath, args, true)
	if err != nil {
		return 0, err
	}
	defer logFile.Close()
	pid := cmd.Process.Pid
	_ = cmd.Process.Release()
	return pid, nil
}

// runGodotWait runs a child to completion in the foreground and returns its exit
// code and wall time. A non-zero exit is the engine's answer, not a Go error, so
// it comes back as a code with a nil error; only a failure to run at all errors.
func runGodotWait(ctx context.Context, bin, root, logPath string, args []string) (int, time.Duration, error) {
	started := time.Now()
	cmd, logFile, err := startGodot(ctx, bin, root, logPath, args, false)
	if err != nil {
		return -1, 0, err
	}
	werr := cmd.Wait()
	_ = logFile.Close()
	elapsed := time.Since(started)
	if werr != nil {
		var ee *exec.ExitError
		if errors.As(werr, &ee) {
			return ee.ExitCode(), elapsed, nil
		}
		return -1, elapsed, werr
	}
	return 0, elapsed, nil
}

// engineLogEntry is one diagnostic Godot printed: an ERROR, WARNING or SCRIPT
// ERROR line with its "at:" continuation folded in, and the source location
// pulled out of that continuation where the engine gave one.
type engineLogEntry struct {
	Level   string   `json:"level"`
	Message string   `json:"message"`
	Detail  []string `json:"detail,omitempty"`
	At      string   `json:"at,omitempty"`
	File    string   `json:"file,omitempty"`
	Line    int      `json:"line,omitempty"`
}

// String renders an entry as one line, leading with the source location when the
// engine named one, which is the form an agent can act on directly.
func (e engineLogEntry) String() string {
	msg := e.Message
	if len(e.Detail) > 0 {
		msg += " " + strings.Join(e.Detail, " ")
	}
	if e.File != "" && e.Line > 0 {
		return fmt.Sprintf("%s:%d: %s", e.File, e.Line, msg)
	}
	if e.At != "" {
		return msg + " (at " + e.At + ")"
	}
	return msg
}

// engineLevels are the diagnostic prefixes Godot writes, longest first so
// "SCRIPT ERROR:" is matched before "ERROR:" would swallow it. The USER forms
// come from push_error and push_warning in project code.
var engineLevels = []string{
	"USER SCRIPT ERROR:",
	"USER WARNING:",
	"USER ERROR:",
	"SCRIPT ERROR:",
	"WARNING:",
	"ERROR:",
}

// atLocationRe pulls the file and line out of an "at:" continuation, whose tail
// is always "(<file>:<line>)", as in "at: GDScript::reload (res://player.gd:12)".
var atLocationRe = regexp.MustCompile(`\(([^()]+):(\d+)\)\s*$`)

// parseEngineLog reads Godot's stdout/stderr and returns its diagnostics in
// order. An entry runs from its level line to the indented "at:" line that
// closes it, and everything between the two is the engine's own detail: a failed
// export names each missing template file there, which is the only part of that
// message worth reading. Lines in that gap count as detail solely when an "at:"
// arrives to close the entry, so ordinary print() output after an unclosed error
// is never absorbed into it.
func parseEngineLog(r io.Reader) []engineLogEntry {
	var entries []engineLogEntry
	var pending []string
	open := -1

	closeEntry := func() {
		pending = nil
		open = -1
	}

	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		trimmed := strings.TrimSpace(sc.Text())
		if after, ok := strings.CutPrefix(trimmed, "at: "); ok && open >= 0 {
			last := &entries[open]
			last.At = strings.TrimSpace(after)
			if m := atLocationRe.FindStringSubmatch(last.At); m != nil {
				last.File = m[1]
				last.Line, _ = strconv.Atoi(m[2])
			}
			last.Detail = pending
			closeEntry()
			continue
		}
		matched := false
		for _, level := range engineLevels {
			if rest, ok := strings.CutPrefix(trimmed, level); ok {
				closeEntry()
				entries = append(entries, engineLogEntry{
					Level:   strings.TrimSuffix(level, ":"),
					Message: strings.TrimSpace(rest),
				})
				open = len(entries) - 1
				matched = true
				break
			}
		}
		if matched || open < 0 || trimmed == "" {
			continue
		}
		pending = append(pending, trimmed)
	}
	return entries
}

// readEngineLog parses a log file written by startGodot. A log that cannot be
// read yields no entries rather than an error: the run's exit code is the
// authority on success, and the parsed lines are the detail on top of it.
func readEngineLog(path string) []engineLogEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	return parseEngineLog(f)
}

// splitEngineLog separates diagnostics into errors and warnings. Anything whose
// level names ERROR counts as an error, which folds in SCRIPT ERROR and the USER
// forms without listing every spelling at each call site.
func splitEngineLog(entries []engineLogEntry) (errs, warns []engineLogEntry) {
	for _, e := range entries {
		switch {
		case strings.Contains(e.Level, "ERROR"):
			errs = append(errs, e)
		case strings.Contains(e.Level, "WARNING"):
			warns = append(warns, e)
		}
	}
	return errs, warns
}

// projectSetting reads one raw value from a section of project.godot. The file
// is a Godot ConfigFile, so values are Variant-encoded and returned as written.
func projectSetting(root, section, key string) (string, bool) {
	data, err := os.ReadFile(filepath.Join(root, "project.godot"))
	if err != nil {
		return "", false
	}
	current := ""
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
			current = strings.TrimSpace(t[1 : len(t)-1])
			continue
		}
		if current != section {
			continue
		}
		k, v, ok := strings.Cut(t, "=")
		if !ok || strings.TrimSpace(k) != key {
			continue
		}
		return strings.TrimSpace(v), true
	}
	return "", false
}

// projectBoolSetting reads a bool project setting. An absent key is false, which
// matches Godot: a setting registered with set_initial_value stays out of the
// file while it holds its default.
func projectBoolSetting(root, section, key string) bool {
	v, ok := projectSetting(root, section, key)
	return ok && strings.EqualFold(v, "true")
}

// toResPath turns a scene or script path into the res:// form the engine takes. An
// already-res:// path passes through; anything else is resolved against the cwd
// and must land inside the project, since res:// cannot name a file outside it.
func toResPath(root, p string) (string, error) {
	if strings.HasPrefix(p, "res://") {
		return p, nil
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("%s is outside the project at %s", p, root)
	}
	return "res://" + filepath.ToSlash(rel), nil
}

// emitResult renders a local subcommand's outcome: JSON when asked for or when
// piped (agents and pipelines never get layout they would have to strip), the
// key/value summary on a terminal.
func emitResult(name string, res any, asJSON bool, line string, rows [][2]string) {
	if asJSON || !ui.IsTerminal(os.Stdout) {
		b, err := json.MarshalIndent(res, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: encoding JSON: %v\n", name, err)
			return
		}
		fmt.Println(string(b))
		return
	}
	fmt.Println(ui.Out.Heading("godot-mcp "+name) + ": " + line)
	fmt.Println()
	w := 0
	for _, r := range rows {
		w = max(w, len(r[0]))
	}
	for _, r := range rows {
		fmt.Printf("  %s  %s\n", ui.Out.Key(padRight(r[0], w)), r[1])
	}
}

// entryStrings flattens diagnostics for a summary row or a human line.
func entryStrings(entries []engineLogEntry) []string {
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.String())
	}
	return out
}
