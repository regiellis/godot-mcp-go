package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// runInstall copies the bundled Godot addon (and optionally the agent skill)
// into a target project, optionally enabling the plugin in project.godot.
// Sources default to `addons/godot_mcp` and `skills/godot-mcp` next to the
// binary — the release-bundle layout — and are overridable with --from.
func runInstall(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	project := fs.String("project", "", "target Godot project dir (default: the project containing the cwd)")
	from := fs.String("from", "", "addon source dir (default: addons/godot_mcp next to the binary)")
	skill := fs.Bool("skill", true, "install the agent skill into <project>/.claude/skills/godot-mcp (use --skill=false to skip)")
	enable := fs.Bool("enable", false, "enable the plugin in project.godot")
	force := fs.Bool("force", false, "overwrite an existing addon/skill install")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `godot-mcp install — copy the addon into a Godot project

Usage:
  godot-mcp install [--project DIR] [--from DIR] [--skill] [--enable] [--force]

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

	addonSrc := *from
	if addonSrc == "" {
		addonSrc = assetDir("addons", "godot_mcp")
	}
	if !fileExists(filepath.Join(addonSrc, "plugin.cfg")) {
		fmt.Fprintf(os.Stderr, "install: addon source not found at %q (pass --from with the path to addons/godot_mcp)\n", addonSrc)
		return 1
	}

	addonDst := filepath.Join(root, "addons", "godot_mcp")
	if pathExists(addonDst) && !*force {
		fmt.Fprintf(os.Stderr, "install: %q already exists (use --force to overwrite)\n", addonDst)
		return 1
	}
	if err := copyDir(addonSrc, addonDst); err != nil {
		fmt.Fprintln(os.Stderr, "install: copying addon:", err)
		return 1
	}
	fmt.Printf("installed addon  -> %s\n", addonDst)

	if *skill {
		skillSrc := assetDir("skills", "godot-mcp")
		if !fileExists(filepath.Join(skillSrc, "SKILL.md")) {
			fmt.Fprintf(os.Stderr, "install: skill source not found at %q (skipping --skill)\n", skillSrc)
		} else {
			skillDst := filepath.Join(root, ".claude", "skills", "godot-mcp")
			if pathExists(skillDst) && !*force {
				fmt.Fprintf(os.Stderr, "install: %q already exists (use --force)\n", skillDst)
			} else if err := copyDir(skillSrc, skillDst); err != nil {
				fmt.Fprintln(os.Stderr, "install: copying skill:", err)
			} else {
				fmt.Printf("installed skill  -> %s\n", skillDst)
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

// assetDir resolves a bundled asset dir next to the running binary.
func assetDir(parts ...string) string {
	exe, err := os.Executable()
	if err != nil {
		return filepath.Join(parts...)
	}
	return filepath.Join(append([]string{filepath.Dir(exe)}, parts...)...)
}

func fileExists(p string) bool { fi, err := os.Stat(p); return err == nil && !fi.IsDir() }
func pathExists(p string) bool { _, err := os.Stat(p); return err == nil }

func copyDir(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(path, target)
	})
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
