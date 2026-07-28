package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// runInstall copies the bundled Godot addon (and optionally the agent skill)
// into a target project, optionally enabling the plugin in project.godot.
// Sources resolve across both shipped layouts (see resolveAsset) and are
// overridable with --from and --skill-from.
func runInstall(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	project := fs.String("project", "", "target Godot project dir (default: the project containing the cwd)")
	from := fs.String("from", "", "addon source dir (default: addons/godot_mcp beside the binary, or project/addons/godot_mcp in a checkout)")
	skillFrom := fs.String("skill-from", "", "skill source dir (default: skills/godot-mcp beside the binary or repo root)")
	skill := fs.Bool("skill", true, "install the agent skill into <project>/.claude/skills/godot-mcp (use --skill=false to skip)")
	enable := fs.Bool("enable", false, "enable the plugin in project.godot")
	force := fs.Bool("force", false, "overwrite an existing addon/skill install")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `godot-mcp install — copy the addon into a Godot project

Usage:
  godot-mcp install [--project DIR] [--from DIR] [--skill-from DIR] [--skill] [--enable] [--force]

Flags:`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	start := *project
	if start == "" {
		start, _ = os.Getwd()
	}
	root, err := client.FindProjectRoot(start)
	if err != nil {
		fmt.Fprintln(os.Stderr, "install: no Godot project found —", err)
		return 1
	}

	addonSrc, tried := resolveAsset(*from, "plugin.cfg",
		[]string{"addons", "godot_mcp"},            // release archive: beside the binary
		[]string{"project", "addons", "godot_mcp"}, // repo checkout: under project/
	)
	if addonSrc == "" {
		fmt.Fprintln(os.Stderr, "install: addon source not found. Looked in:")
		for _, p := range tried {
			fmt.Fprintf(os.Stderr, "  %s\n", p)
		}
		fmt.Fprintln(os.Stderr, "Run install from the extracted release folder (the binary sits beside addons/),")
		fmt.Fprintln(os.Stderr, "or pass --from with the path to an addons/godot_mcp directory.")
		return 1
	}

	addonDst := filepath.Join(root, "addons", "godot_mcp")
	if samePath(addonSrc, addonDst) {
		fmt.Fprintf(os.Stderr, "install: source and destination are the same directory (%q); nothing to do\n", addonDst)
		return 1
	}
	if pathExists(addonDst) && !*force {
		fmt.Fprintf(os.Stderr, "install: %q already exists (use --force to overwrite)\n", addonDst)
		return 1
	}
	skipped, err := copyDir(addonSrc, addonDst)
	if err != nil {
		fmt.Fprintln(os.Stderr, "install: copying addon:", err)
		return 1
	}
	fmt.Printf("installed addon  -> %s\n", addonDst)
	reportSkipped(skipped)
	warnStaleContextDocs(addonDst)

	if *skill {
		// Same relative path in both layouts, so one candidate covers the archive
		// (beside the binary) and a checkout (repo root, one level up from bin/).
		skillSrc, skillTried := resolveAsset(*skillFrom, "SKILL.md", []string{"skills", "godot-mcp"})
		if skillSrc == "" {
			fmt.Fprintln(os.Stderr, "install: skill source not found, skipping it. Looked in:")
			for _, p := range skillTried {
				fmt.Fprintf(os.Stderr, "  %s\n", p)
			}
			fmt.Fprintln(os.Stderr, "Pass --skill-from with the path to a skills/godot-mcp directory, or --skill=false to silence this.")
		} else {
			skillDst := filepath.Join(root, ".claude", "skills", "godot-mcp")
			if pathExists(skillDst) && !*force {
				fmt.Fprintf(os.Stderr, "install: %q already exists (use --force)\n", skillDst)
			} else if skillSkipped, err := copyDir(skillSrc, skillDst); err != nil {
				fmt.Fprintln(os.Stderr, "install: copying skill:", err)
			} else {
				fmt.Printf("installed skill  -> %s\n", skillDst)
				reportSkipped(skillSkipped)
			}
		}
	}

	if *enable {
		if err := enablePlugin(root); err != nil {
			fmt.Fprintln(os.Stderr, "install: could not enable plugin:", err)
		} else {
			fmt.Println("enabled plugin in project.godot")
		}
	} else {
		fmt.Println("Next: open the project in Godot 4.7 and enable Godot MCP in Project Settings > Plugins.")
	}
	return 0
}

// resolveAsset finds a bundled asset directory, identified by a marker file it
// must contain. An explicit override wins outright (and is reported as tried, so
// a typo names itself). Otherwise it walks the candidate layouts against two
// bases: the binary's own directory, which is the release archive (exe beside
// addons/ and skills/), and its parent, which is a repo checkout (bin/godot-mcp
// with the sources at the repo root).
//
// Both bases are anchored to the executable, never the working directory: a cwd
// search could reach into the *target* project and offer its existing addon as
// the source, i.e. copy a directory onto itself.
//
// Returns the resolved dir and every path considered, so a failure can say where
// it looked instead of naming one guess. A binary copied onto PATH alone matches
// nothing, which is the case this reporting exists for.
func resolveAsset(override, marker string, layouts ...[]string) (string, []string) {
	var tried []string
	check := func(dir string) bool {
		tried = append(tried, dir)
		return fileExists(filepath.Join(dir, marker))
	}
	if override != "" {
		if check(override) {
			return override, tried
		}
		return "", tried
	}
	exe, err := os.Executable()
	if err != nil {
		return "", tried
	}
	exeDir := filepath.Dir(exe)
	for _, base := range []string{exeDir, filepath.Dir(exeDir)} {
		for _, layout := range layouts {
			if dir := filepath.Join(append([]string{base}, layout...)...); check(dir) {
				return dir, tried
			}
		}
	}
	return "", tried
}

// reportSkipped names anything copyDir left behind, so the install is not
// quietly different from its source.
func reportSkipped(skipped []string) {
	for _, s := range skipped {
		fmt.Printf("  skipped %s (repo-internal doc, not shipped)\n", s)
	}
}

// warnStaleContextDocs flags a dev context doc an EARLIER install left in the
// project. It only warns: the file now sits in the user's tree, possibly
// committed, and deleting files inside someone's project is not this command's
// call to make.
func warnStaleContextDocs(dst string) {
	_ = filepath.WalkDir(dst, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && devContextDoc(d.Name()) {
			fmt.Fprintf(os.Stderr, "install: %s is left over from an earlier install and is not part of the addon; delete it.\n", path)
		}
		return nil
	})
}

func fileExists(p string) bool { fi, err := os.Stat(p); return err == nil && !fi.IsDir() }
func pathExists(p string) bool { _, err := os.Stat(p); return err == nil }

// samePath reports whether two paths name the same directory, so a copy can
// refuse to run source-onto-destination.
func samePath(a, b string) bool {
	aa, err1 := filepath.Abs(a)
	bb, err2 := filepath.Abs(b)
	if err1 != nil || err2 != nil {
		return false
	}
	if runtime.GOOS == "windows" {
		return strings.EqualFold(filepath.Clean(aa), filepath.Clean(bb))
	}
	return filepath.Clean(aa) == filepath.Clean(bb)
}

// devContextDoc reports whether a file is repo-internal guidance that must not
// land in a consumer project. This is the same rule scripts/release.ps1 applies
// when staging an archive; keep the two in step. Installing from an archive never
// hits it (the file was stripped at package time), but installing from a source
// checkout copies whatever is on disk.
func devContextDoc(name string) bool {
	return strings.EqualFold(name, "CLAUDE.md")
}

// copyDir copies a tree, skipping dev context docs at any depth. It returns the
// paths it skipped so the caller can say so rather than silently differing from
// the source.
func copyDir(src, dst string) ([]string, error) {
	var skipped []string
	err := filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if !d.IsDir() && devContextDoc(d.Name()) {
			skipped = append(skipped, rel)
			return nil
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(path, target)
	})
	return skipped, err
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

const pluginEntry = "res://addons/godot_mcp/plugin.cfg"

// enablePlugin adds the addon to project.godot's [editor_plugins] enabled list,
// idempotently. Best-effort text edit — Godot rewrites the file cleanly on open.
func enablePlugin(root string) error {
	p := filepath.Join(root, "project.godot")
	data, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	s := string(data)
	if strings.Contains(s, pluginEntry) {
		return nil // already enabled
	}
	const marker = "enabled=PackedStringArray("
	if i := strings.Index(s, marker); i >= 0 {
		open := i + len(marker)
		closeRel := strings.Index(s[open:], ")")
		if closeRel < 0 {
			return fmt.Errorf("malformed [editor_plugins] in project.godot")
		}
		closePos := open + closeRel
		inner := strings.TrimSpace(s[open:closePos])
		newInner := `"` + pluginEntry + `"`
		if inner != "" {
			newInner = inner + ", " + newInner
		}
		s = s[:open] + newInner + s[closePos:]
	} else {
		if !strings.HasSuffix(s, "\n") {
			s += "\n"
		}
		s += "\n[editor_plugins]\n\nenabled=PackedStringArray(\"" + pluginEntry + "\")\n"
	}
	return os.WriteFile(p, []byte(s), 0o644)
}
