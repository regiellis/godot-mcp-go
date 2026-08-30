package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// exportPreset is one [preset.N] section of export_presets.cfg, reduced to the
// three fields an export needs: which preset to name on the command line, where
// it writes, and which platform it targets.
type exportPreset struct {
	Index      int    `json:"index"`
	Name       string `json:"name"`
	Platform   string `json:"platform,omitempty"`
	ExportPath string `json:"export_path,omitempty"`
}

// exportResult is the JSON shape of `export --json` (and of piped output).
type exportResult struct {
	ProjectPath        string           `json:"project_path"`
	Preset             string           `json:"preset"`
	Platform           string           `json:"platform,omitempty"`
	Mode               string           `json:"mode"`
	Command            []string         `json:"command"`
	Log                string           `json:"log"`
	ExitCode           int              `json:"exit_code"`
	DurationMS         int64            `json:"duration_ms"`
	OutputPath         string           `json:"output_path"`
	Exists             bool             `json:"exists"`
	SizeBytes          int64            `json:"size_bytes"`
	TemplatesDir       string           `json:"templates_dir,omitempty"`
	TemplatesInstalled bool             `json:"templates_installed"`
	Errors             []engineLogEntry `json:"errors"`
	Warnings           []engineLogEntry `json:"warnings"`
}

// runExport is a local subcommand: it runs the headless export command line that
// export.project only returns, waits for it, and reports what landed on disk.
// The addon cannot export from inside the editor (Godot 4 has no plugin-side
// export API), so this is the Go half of that pair and needs no editor at all.
//
// Exit code is Godot's, with one addition: an export that exits 0 and produced
// no file exits 1 here. Missing export templates are exactly that case, and a
// success envelope over a missing binary is the failure this must not repeat.
func runExport(args []string) int {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir (default: the project containing the cwd)")
	presetFlag := fs.String("preset", "", "preset to export, when naming it positionally would read as an addon command")
	debug := fs.Bool("debug", false, "export with debug features (--export-debug) instead of release")
	pack := fs.Bool("pack", false, "export project data only (--export-pack); the output extension picks PCK or ZIP")
	patch := fs.Bool("patch", false, "export a patch pack of changed files only (--export-patch)")
	patches := fs.String("patches", "", "comma-separated packs the patch builds on, for --patch")
	out := fs.String("out", "", "output file (default: the preset's export_path from export_presets.cfg)")
	timeout := fs.Duration("timeout", 20*time.Minute, "how long to let the export run")
	godot := fs.String("godot", "", "path to the Godot binary (default: godot on PATH)")
	asJSON := fs.Bool("json", false, "emit the result as JSON instead of a human summary")
	fs.Usage = subHelp(fs, "export a preset headlessly and report what it produced",
		[]string{"godot-mcp export <preset> [--debug|--pack|--patch] [--out PATH] [--project DIR] [--timeout 20m] [--json]"},
		`Runs godot --headless --path <project> --export-release <preset> <out> in the
foreground and exits with Godot's own code. The preset is named as it appears in
export_presets.cfg; an unknown name lists the presets that exist.

The output path defaults to the preset's export_path. Godot requires the target
directory to exist, so it is created first. An export that exits 0 without
producing the file exits 1 here and reports exists false, which is what a missing
export template looks like: check godot-mcp export info and godot-mcp doctor.

Godot's stdout and stderr go to <project>/.godot/godot-mcp-export.log, with the
ERROR and WARNING lines parsed into the result.

The addon's export group keeps this name: godot-mcp export list-presets, export
project and export info still reach the editor. A preset called one of those
three is reachable as godot-mcp export --preset info.`)
	positional, prc := parseSubPositional(fs, args)
	if prc >= 0 {
		return prc
	}

	presetName := *presetFlag
	switch {
	case presetName != "" && len(positional) > 0:
		fmt.Fprintf(os.Stderr, "%s name the preset once: as the argument or with --preset\n", ui.Err.Fail("error:"))
		return 2
	case presetName == "" && len(positional) != 1:
		fmt.Fprintf(os.Stderr, "%s export takes one preset name (godot-mcp export \"Windows Desktop\")\n", ui.Err.Fail("error:"))
		return 2
	case presetName == "":
		presetName = positional[0]
	}

	mode, merr := exportMode(*debug, *pack, *patch)
	if merr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), merr)
		return 2
	}
	if *patches != "" && mode != "patch" {
		fmt.Fprintf(os.Stderr, "%s --patches only applies to --patch\n", ui.Err.Fail("error:"))
		return 2
	}

	root, rerr := projectRootFor(*project)
	if rerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), rerr)
		return 2
	}

	presets, perr := readExportPresets(root)
	if perr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), perr)
		return 2
	}
	preset, found := findExportPreset(presets, presetName)
	if !found {
		fmt.Fprintf(os.Stderr, "%s no preset named %q in %s\n", ui.Err.Fail("error:"), presetName,
			filepath.Join(root, "export_presets.cfg"))
		for _, p := range presets {
			fmt.Fprintf(os.Stderr, "  %s  %s\n", ui.Err.Key(p.Name), p.Platform)
		}
		return 2
	}

	outPath, oerr := exportOutputPath(root, preset, *out)
	if oerr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), oerr)
		return 2
	}
	// Godot refuses an export whose target directory does not exist, and says so
	// only in the log. Creating it here is what makes a fresh clone exportable.
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "%s creating the output directory: %v\n", ui.Err.Fail("error:"), err)
		return 2
	}

	bin, berr := resolveGodotBinary(*godot)
	if berr != nil {
		fmt.Fprintf(os.Stderr, "%s %v\n", ui.Err.Fail("error:"), berr)
		return 2
	}

	// The editor holds the same .godot/ cache this export reads. That is not a
	// conflict (the export reads the imported files, it does not rewrite them),
	// but an unsaved scene is not in them, so say so once and continue.
	if st := client.Diagnose(root, 0); st.Verdict == client.VerdictRunning {
		fmt.Fprintf(os.Stderr, "%s an editor is running on this project (port %d). The export reads the files on disk, so anything unsaved in that editor is not in it.\n",
			ui.Err.Warn("note:"), st.Port)
	}

	templatesDir, templatesOK, tdetail := checkExportTemplates(bin)
	if !templatesOK {
		fmt.Fprintf(os.Stderr, "%s %s. A preset naming its own template path is fine; otherwise install them from Editor > Manage Export Templates.\n",
			ui.Err.Warn("warning:"), tdetail)
	}

	argv := exportArgs(root, mode, preset.Name, outPath, *patches)
	logPath := godotLogPath(root, "export")

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	code, elapsed, xerr := runGodotWait(ctx, bin, root, logPath, argv)
	if xerr != nil {
		fmt.Fprintf(os.Stderr, "%s could not run %s: %v\n", ui.Err.Fail("error:"), bin, xerr)
		return 2
	}
	timedOut := ctx.Err() != nil

	errs, warns := splitEngineLog(readEngineLog(logPath))
	res := exportResult{
		ProjectPath:        root,
		Preset:             preset.Name,
		Platform:           preset.Platform,
		Mode:               mode,
		Command:            append([]string{bin}, argv...),
		Log:                logPath,
		ExitCode:           code,
		DurationMS:         elapsed.Milliseconds(),
		OutputPath:         outPath,
		TemplatesDir:       templatesDir,
		TemplatesInstalled: templatesOK,
		Errors:             orEmpty(errs),
		Warnings:           orEmpty(warns),
	}
	if fi, serr := os.Stat(outPath); serr == nil && !fi.IsDir() {
		res.Exists = true
		res.SizeBytes = fi.Size()
	} else if serr == nil && fi.IsDir() {
		// A macOS .app bundle and an Android AAB directory are real outputs.
		res.Exists = true
	}

	line, rc := exportOutcome(res, timedOut, *timeout)
	emitResult("export", res, *asJSON, line, [][2]string{
		{"project", res.ProjectPath},
		{"preset", res.Preset},
		{"mode", res.Mode},
		{"exit", strconv.Itoa(res.ExitCode)},
		{"output", res.OutputPath},
		{"exists", fmt.Sprint(res.Exists)},
		{"size", fmt.Sprintf("%d bytes", res.SizeBytes)},
		{"errors", strconv.Itoa(len(res.Errors))},
		{"warnings", strconv.Itoa(len(res.Warnings))},
		{"duration", elapsed.Round(time.Millisecond).String()},
		{"log", res.Log},
	})
	if rc != 0 {
		for _, e := range res.Errors {
			fmt.Fprintln(os.Stderr, ui.Err.Fail("  "+e.String()))
		}
	}
	return rc
}

// exportOutcome reads the run into a headline and an exit code. Godot's own code
// passes through; the one case it gets wrong is a clean exit with nothing on
// disk, which is what a missing export template produces.
func exportOutcome(res exportResult, timedOut bool, timeout time.Duration) (string, int) {
	switch {
	case timedOut:
		return fmt.Sprintf("export did not finish within %s; see %s", timeout, res.Log), 1
	case res.ExitCode != 0:
		return fmt.Sprintf("godot exited %d; see %s", res.ExitCode, res.Log), res.ExitCode
	case !res.Exists:
		return fmt.Sprintf("godot exited 0 but wrote nothing to %s. Check export templates (godot-mcp export info, godot-mcp doctor) and the preset's own settings; see %s",
			res.OutputPath, res.Log), 1
	default:
		return fmt.Sprintf("exported %s (%d bytes)", res.OutputPath, res.SizeBytes), 0
	}
}

// exportMode names the one export the flags asked for. The four are exclusive:
// Godot has a separate flag per mode and no debug variant of pack or patch.
func exportMode(debug, pack, patch bool) (string, error) {
	n := 0
	for _, b := range []bool{debug, pack, patch} {
		if b {
			n++
		}
	}
	if n > 1 {
		return "", fmt.Errorf("--debug, --pack and --patch are exclusive: pick one")
	}
	switch {
	case debug:
		return "debug", nil
	case pack:
		return "pack", nil
	case patch:
		return "patch", nil
	default:
		return "release", nil
	}
}

// exportArgs builds the child's argv. --path anchors the export on this project
// rather than whatever the binary last opened, and --headless keeps the editor
// window out of it.
func exportArgs(root, mode, preset, out, patches string) []string {
	args := []string{"--headless", "--path", root}
	if mode == "patch" && patches != "" {
		args = append(args, "--patches", patches)
	}
	flagFor := map[string]string{
		"release": "--export-release",
		"debug":   "--export-debug",
		"pack":    "--export-pack",
		"patch":   "--export-patch",
	}
	return append(args, flagFor[mode], preset, out)
}

// exportOutputPath decides where the export writes: --out when given, else the
// preset's export_path. Both are resolved to an absolute path so the result can
// state exactly what to look for, and so the size check reads the right file.
func exportOutputPath(root string, preset exportPreset, out string) (string, error) {
	p := out
	if p == "" {
		p = preset.ExportPath
	}
	if p == "" {
		return "", fmt.Errorf("preset %q has no export_path in export_presets.cfg; pass --out PATH", preset.Name)
	}
	if rest, ok := strings.CutPrefix(p, "res://"); ok {
		return filepath.Join(root, filepath.FromSlash(rest)), nil
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p), nil
	}
	// Godot reads a relative export path as relative to the project directory,
	// which is also how export_presets.cfg writes one.
	if out != "" {
		abs, err := filepath.Abs(p)
		if err != nil {
			return "", err
		}
		return abs, nil
	}
	return filepath.Join(root, filepath.FromSlash(p)), nil
}

// readExportPresets loads the project's export presets. A missing file names it,
// since "configure exports in Project > Export first" is the fix and the caller
// otherwise sees an unhelpful empty list.
func readExportPresets(root string) ([]exportPreset, error) {
	path := filepath.Join(root, "export_presets.cfg")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no export_presets.cfg at %s. Configure an export in Project > Export first (godot-mcp export list-presets lists them from a running editor)", path)
		}
		return nil, err
	}
	return parseExportPresets(string(data)), nil
}

// parseExportPresets reads the [preset.N] sections of export_presets.cfg. The
// per-preset [preset.N.options] sections carry platform settings and are skipped:
// only the top section holds the name, platform and export_path.
func parseExportPresets(text string) []exportPreset {
	var presets []exportPreset
	idx := -1
	for _, line := range strings.Split(text, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
			idx = -1
			name := strings.TrimSpace(t[1 : len(t)-1])
			num, ok := strings.CutPrefix(name, "preset.")
			if !ok || strings.Contains(num, ".") {
				continue
			}
			n, cerr := strconv.Atoi(num)
			if cerr != nil {
				continue
			}
			presets = append(presets, exportPreset{Index: n})
			idx = len(presets) - 1
			continue
		}
		if idx < 0 {
			continue
		}
		k, v, ok := strings.Cut(t, "=")
		if !ok {
			continue
		}
		value := unquoteCfg(strings.TrimSpace(v))
		switch strings.TrimSpace(k) {
		case "name":
			presets[idx].Name = value
		case "platform":
			presets[idx].Platform = value
		case "export_path":
			presets[idx].ExportPath = value
		}
	}
	return presets
}

// findExportPreset matches a preset by name, then by 0-based index so the same
// argument works for a preset whose name is awkward to quote on a shell.
func findExportPreset(presets []exportPreset, want string) (exportPreset, bool) {
	for _, p := range presets {
		if p.Name == want {
			return p, true
		}
	}
	if n, err := strconv.Atoi(want); err == nil {
		for _, p := range presets {
			if p.Index == n {
				return p, true
			}
		}
	}
	return exportPreset{}, false
}

// unquoteCfg strips the surrounding quotes Godot's ConfigFile writes around a
// string value, leaving bools and numbers as written.
func unquoteCfg(v string) string {
	if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
		return strings.ReplaceAll(v[1:len(v)-1], `\"`, `"`)
	}
	return v
}

// checkExportTemplates reports whether a template directory for the binary's
// version exists, mirroring what the addon's export.info computes from
// OS.get_data_dir(). It is advisory and deliberately coarse: which files a
// preset needs is per-platform, and a preset may name a custom template path, so
// this warns and never refuses. A directory that exists but lacks the platform's
// own binaries still fails, and the engine's error then names each missing file,
// which is why the export result carries the parsed detail lines.
func checkExportTemplates(bin string) (dir string, ok bool, detail string) {
	dir = exportTemplatesDir()
	if dir == "" {
		return "", true, ""
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return dir, false, fmt.Sprintf("no export templates found at %s", dir)
	}
	var installed []string
	for _, e := range entries {
		if e.IsDir() {
			installed = append(installed, e.Name())
		}
	}
	if len(installed) == 0 {
		return dir, false, fmt.Sprintf("no export templates installed in %s", dir)
	}
	want := godotVersionConfig(bin)
	if want == "" {
		return dir, true, ""
	}
	for _, name := range installed {
		if name == want || strings.HasPrefix(name, want+".") {
			return dir, true, ""
		}
	}
	return dir, false, fmt.Sprintf("no export templates for %s in %s (installed: %s)",
		want, dir, strings.Join(installed, ", "))
}

// exportTemplatesDir is Godot's OS.get_data_dir()/export_templates per platform,
// the same path export.info reports from inside the editor.
func exportTemplatesDir() string {
	switch runtime.GOOS {
	case "windows":
		if appdata := os.Getenv("APPDATA"); appdata != "" {
			return filepath.Join(appdata, "Godot", "export_templates")
		}
	case "darwin":
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, "Library", "Application Support", "Godot", "export_templates")
		}
	default:
		if x := os.Getenv("XDG_DATA_HOME"); x != "" {
			return filepath.Join(x, "godot", "export_templates")
		}
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, ".local", "share", "godot", "export_templates")
		}
	}
	return ""
}

// godotVersionConfig reduces `godot --version` to the string Godot names an
// export template directory with: the three version numbers plus the release
// status. "4.7.2.rc.custom_build.36a04fe52" becomes "4.7.2.rc". An unreadable
// version yields "", which turns the template check into a presence check.
func godotVersionConfig(bin string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "--version").Output()
	if err != nil {
		return ""
	}
	return versionConfigFrom(firstLine(strings.TrimSpace(string(out))))
}

// versionConfigFrom keeps the leading numeric fields plus the first field that
// is not a number, which is the release status ("stable", "rc", "beta3").
func versionConfigFrom(version string) string {
	fields := strings.Split(strings.TrimSpace(version), ".")
	var kept []string
	for _, f := range fields {
		kept = append(kept, f)
		if _, err := strconv.Atoi(f); err != nil {
			// The first non-numeric field is the status, and the config ends there.
			if len(kept) == 1 {
				return ""
			}
			return strings.Join(kept, ".")
		}
	}
	return ""
}

// orEmpty renders an absent diagnostic list as [] rather than null, which is
// kinder to jq and to typed parsers on the other side.
func orEmpty(entries []engineLogEntry) []engineLogEntry {
	if entries == nil {
		return []engineLogEntry{}
	}
	return entries
}
