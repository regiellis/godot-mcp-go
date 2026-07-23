package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// doctorCheck is one row of the preflight table: a check name, its status
// (ok/warn/fail/skip), and a one-line human detail. It doubles as the JSON
// shape emitted by `doctor --json`.
type doctorCheck struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

const (
	statusOK   = "ok"
	statusWarn = "warn"
	statusFail = "fail"
	statusSkip = "skip"
)

// runDoctor is a local subcommand (it never dials through the addon for a
// command; it only probes the environment) that reports whether this machine is
// set up to drive a Godot editor: the godot binary, a resolvable project, the
// addon install/enable state, the effective port source, the editor's liveness
// verdict, and dotnet for C# work. Exit 1 if any check fails, else 0 (warns do
// not fail the run — doctor may legitimately run before an editor is launched).
func runDoctor(args []string) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	asJSON := fs.Bool("json", false, "emit the checks as JSON instead of a table")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `godot-mcp doctor — environment preflight

Usage:
  godot-mcp doctor [--project DIR] [--json]

Reports ok/warn/fail for: the godot binary, a resolvable project, the addon
install + enable state, the effective port source, the editor liveness verdict,
and dotnet (for C# projects). Exit 1 only if a check fails.

Flags:`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	var checks []doctorCheck

	// 1. godot binary — absent is a warn, not a fail: the CLI can still talk to
	// an already-running editor, it just cannot launch one.
	checks = append(checks, checkGodotBinary())

	// 2. project — the anchor for checks 3-6. Missing = fail.
	start := *project
	if start == "" {
		start, _ = os.Getwd()
	}
	root, rerr := client.FindProjectRoot(start)
	if rerr != nil {
		checks = append(checks, doctorCheck{"project", statusFail,
			fmt.Sprintf("no project.godot found from %s upward — pass --project or run inside a project", start)})
		// 3-6 depend on a project root; mark them skipped explicitly.
		for _, name := range []string{"addon installed", "addon enabled", "port config", "editor"} {
			checks = append(checks, doctorCheck{name, statusSkip, "skipped (no project)"})
		}
	} else {
		checks = append(checks, doctorCheck{"project", statusOK, root})
		checks = append(checks, checkAddonInstalled(root))
		checks = append(checks, checkAddonEnabled(root))
		checks = append(checks, checkPortConfig(root))
		checks = append(checks, checkEditor(start))
	}

	// 7. dotnet — not gated on a project (a machine can be C#-ready or not
	// regardless of which project is at hand). Absent is a warn.
	checks = append(checks, checkDotnet())

	return emitDoctor(checks, *asJSON)
}

// checkGodotBinary looks for the godot launcher on PATH ("godot", then the
// Windows shim name "godot.cmd") and, when found, reports its --version string.
func checkGodotBinary() doctorCheck {
	path, err := exec.LookPath("godot")
	if err != nil {
		path, err = exec.LookPath("godot.cmd")
	}
	if err != nil {
		return doctorCheck{"godot binary", statusWarn,
			"godot not found on PATH — the CLI can still drive an already-running editor, but cannot launch one"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, verr := exec.CommandContext(ctx, path, "--version").Output()
	if verr != nil {
		return doctorCheck{"godot binary", statusWarn,
			fmt.Sprintf("found %s but `--version` failed: %v", path, verr)}
	}
	ver := firstLine(strings.TrimSpace(string(out)))
	if ver == "" {
		ver = "unknown version"
	}
	return doctorCheck{"godot binary", statusOK, fmt.Sprintf("%s (%s)", ver, path)}
}

// checkAddonInstalled reports whether addons/godot_mcp/plugin.cfg is present.
func checkAddonInstalled(root string) doctorCheck {
	p := filepath.Join(root, "addons", "godot_mcp", "plugin.cfg")
	if fileExists(p) {
		return doctorCheck{"addon installed", statusOK, "addons/godot_mcp/plugin.cfg present"}
	}
	return doctorCheck{"addon installed", statusFail,
		"addon not found — run: godot-mcp install --project " + root}
}

// checkAddonEnabled reports whether project.godot enables the plugin. The signal
// is the plugin.cfg path appearing in [editor_plugins] enabled — the same marker
// enablePlugin writes (install.go).
func checkAddonEnabled(root string) doctorCheck {
	data, err := os.ReadFile(filepath.Join(root, "project.godot"))
	if err != nil {
		return doctorCheck{"addon enabled", statusWarn,
			fmt.Sprintf("could not read project.godot: %v", err)}
	}
	if strings.Contains(string(data), pluginEntry) {
		return doctorCheck{"addon enabled", statusOK, "godot_mcp plugin enabled in project.godot"}
	}
	return doctorCheck{"addon enabled", statusWarn,
		"plugin not enabled — run: godot-mcp install --enable, or enable Godot MCP in Project Settings > Plugins"}
}

// checkPortConfig reports the effective port source without contacting anything:
// GODOT_MCP_PORT env pins it; else the per-project [godot_mcp] network/port pin;
// else the auto range. Informational (ok) unless env and the pin disagree, which
// is worth a warn because the env value silently wins.
func checkPortConfig(root string) doctorCheck {
	env := strings.TrimSpace(os.Getenv("GODOT_MCP_PORT"))
	pin, hasPin := readPortPin(root)

	switch {
	case env != "" && hasPin:
		if env == strconv.Itoa(pin) {
			return doctorCheck{"port config", statusOK,
				fmt.Sprintf("GODOT_MCP_PORT=%s (matches project pin godot_mcp/network/port)", env)}
		}
		return doctorCheck{"port config", statusWarn,
			fmt.Sprintf("GODOT_MCP_PORT=%s overrides project pin godot_mcp/network/port=%d — they disagree", env, pin)}
	case env != "":
		return doctorCheck{"port config", statusOK, "GODOT_MCP_PORT=" + env}
	case hasPin:
		return doctorCheck{"port config", statusOK,
			fmt.Sprintf("project pin godot_mcp/network/port=%d", pin)}
	default:
		return doctorCheck{"port config", statusOK, "auto (9080-9095)"}
	}
}

// checkEditor runs the same liveness diagnosis as `godot-mcp status`. Only
// running is ok; closed/crashed/starting are warns (doctor may run before a
// launch), never fails.
func checkEditor(start string) doctorCheck {
	st := client.Diagnose(start, 0)
	status := statusWarn
	var detail string
	switch st.Verdict {
	case client.VerdictRunning:
		status = statusOK
		detail = fmt.Sprintf("editor running and reachable on port %d", st.Port)
	case client.VerdictStarting:
		detail = fmt.Sprintf("editor booting on port %d — not accepting connections yet", st.Port)
	case client.VerdictCrashed:
		detail = fmt.Sprintf("editor appears crashed (stale discovery file, pid %d gone, port %d)", st.PID, st.Port)
	case client.VerdictClosed:
		detail = fmt.Sprintf("no editor running on port %d (closed cleanly or never started)", st.Port)
	default:
		detail = fmt.Sprintf("%s (port %d)", st.Verdict, st.Port)
	}
	return doctorCheck{"editor", status, detail}
}

// checkDotnet reports the dotnet SDK version. Absent is a warn: dotnet is only
// needed for C# Godot projects.
func checkDotnet() doctorCheck {
	path, err := exec.LookPath("dotnet")
	if err != nil {
		return doctorCheck{"dotnet", statusWarn, "dotnet not found on PATH — only needed for C# projects"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, verr := exec.CommandContext(ctx, path, "--version").Output()
	if verr != nil {
		return doctorCheck{"dotnet", statusWarn, fmt.Sprintf("found %s but `--version` failed: %v", path, verr)}
	}
	ver := firstLine(strings.TrimSpace(string(out)))
	return doctorCheck{"dotnet", statusOK, fmt.Sprintf("dotnet %s (%s)", ver, path)}
}

// readPortPin reads the per-project port pin from project.godot: the setting
// godot_mcp/network/port, stored under section [godot_mcp] as key network/port.
// Returns (0, false) when absent or unparseable.
func readPortPin(root string) (int, bool) {
	data, err := os.ReadFile(filepath.Join(root, "project.godot"))
	if err != nil {
		return 0, false
	}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
			section = strings.TrimSpace(t[1 : len(t)-1])
			continue
		}
		if section != "godot_mcp" {
			continue
		}
		k, v, ok := strings.Cut(t, "=")
		if !ok || strings.TrimSpace(k) != "network/port" {
			continue
		}
		if p, perr := strconv.Atoi(strings.TrimSpace(v)); perr == nil {
			return p, true
		}
	}
	return 0, false
}

// firstLine returns s up to the first CR or LF (godot --version can print a
// trailing blank line).
func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return s[:i]
	}
	return s
}

// emitDoctor renders the checks as a table or JSON and returns the exit code
// (1 iff any check failed).
func emitDoctor(checks []doctorCheck, asJSON bool) int {
	anyFail := false
	var okN, warnN, failN, skipN int
	for _, c := range checks {
		switch c.Status {
		case statusOK:
			okN++
		case statusWarn:
			warnN++
		case statusFail:
			failN++
			anyFail = true
		case statusSkip:
			skipN++
		}
	}

	if asJSON {
		payload := struct {
			Checks []doctorCheck `json:"checks"`
			OK     bool          `json:"ok"`
		}{checks, !anyFail}
		b, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, "doctor: encoding JSON:", err)
			return 2
		}
		fmt.Println(string(b))
	} else {
		fmt.Println("godot-mcp doctor — environment preflight")
		fmt.Println()
		for _, c := range checks {
			fmt.Printf("  %-6s %-16s %s\n", "["+c.Status+"]", c.Name, c.Detail)
		}
		fmt.Println()
		summary := fmt.Sprintf("summary: %d ok, %d warn, %d fail", okN, warnN, failN)
		if skipN > 0 {
			summary += fmt.Sprintf(", %d skipped", skipN)
		}
		fmt.Println(summary)
	}

	if anyFail {
		return 1
	}
	return 0
}
