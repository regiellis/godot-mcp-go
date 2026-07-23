package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

// runCreate bootstraps a brand-new Godot 4.7 project from nothing: it writes a
// minimal project.godot, a placeholder icon.svg, and a .gitignore. No editor is
// required and it does not dial the addon. With --install it then runs the same
// addon+skill copy flow as `godot-mcp install --project <dir>` (reusing
// runInstall, not duplicating the copy logic).
func runCreate(args []string) int {
	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	path := fs.String("path", "", "target project dir (created if missing) — required")
	name := fs.String("name", "", "project name (default: base name of the target dir)")
	install := fs.Bool("install", false, "also copy the MCP addon + skill into the new project")
	enable := fs.Bool("enable", false, "enable the plugin in project.godot (requires --install)")
	force := fs.Bool("force", false, "proceed even if the target dir exists and is non-empty (never overwrites an existing project.godot)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `godot-mcp create — bootstrap a new Godot 4.7 project

Usage:
  godot-mcp create --path DIR [--name NAME] [--install] [--enable] [--force]

Flags:`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *path == "" {
		fmt.Fprintln(os.Stderr, "create: --path is required")
		fs.Usage()
		return 2
	}
	if *enable && !*install {
		fmt.Fprintln(os.Stderr, "create: --enable is only meaningful with --install")
		return 2
	}

	dir := *path
	projName := *name
	if projName == "" {
		projName = filepath.Base(filepath.Clean(dir))
	}

	// Never overwrite an existing project, even with --force.
	if pathExists(filepath.Join(dir, "project.godot")) {
		fmt.Fprintf(os.Stderr, "create: %q already contains a project.godot — refusing to overwrite an existing project\n", dir)
		return 1
	}
	// Refuse a non-empty target dir unless --force.
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 && !*force {
		fmt.Fprintf(os.Stderr, "create: %q exists and is not empty (use --force to proceed)\n", dir)
		return 1
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "create: making project dir:", err)
		return 1
	}

	files := []struct {
		name string
		body string
	}{
		{"project.godot", projectGodot(projName)},
		{"icon.svg", placeholderIconSVG},
		{".gitignore", ".godot/\n"},
	}
	for _, f := range files {
		dst := filepath.Join(dir, f.name)
		if err := os.WriteFile(dst, []byte(f.body), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "create: writing %s: %v\n", f.name, err)
			return 1
		}
		fmt.Printf("created          -> %s\n", dst)
	}

	if *install {
		installArgs := []string{"--project", dir}
		if *enable {
			installArgs = append(installArgs, "--enable")
		}
		if *force {
			installArgs = append(installArgs, "--force")
		}
		if code := runInstall(installArgs); code != 0 {
			return code
		}
	}

	fmt.Printf("Next: godot --path %s --editor\n", dir)
	return 0
}

// projectGodot renders a minimal Godot 4.7 project.godot for the given name.
func projectGodot(name string) string {
	return fmt.Sprintf(`; Engine configuration file.
; It's actually a "ProjectSettings" file in INI text format.

config_version=5

[application]

config/name=%q
config/features=PackedStringArray("4.7")
config/icon="res://icon.svg"
`, name)
}

// placeholderIconSVG is an original 128x128 placeholder icon: a rounded square
// with a subtle two-tone diagonal split. Deliberately not the Godot logo, which
// is third-party licensed art.
const placeholderIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <defs>
    <clipPath id="r">
      <rect x="8" y="8" width="112" height="112" rx="24" ry="24"/>
    </clipPath>
  </defs>
  <g clip-path="url(#r)">
    <rect x="8" y="8" width="112" height="112" fill="#3b4a6b"/>
    <polygon points="8,120 120,8 120,120" fill="#4f6493"/>
  </g>
  <rect x="8" y="8" width="112" height="112" rx="24" ry="24" fill="none" stroke="#6f86bd" stroke-width="4"/>
</svg>
`
