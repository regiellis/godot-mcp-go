package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// runInstallAssets copies bundled CC0 asset packs (e.g. Kenney prototype
// textures for greyboxing) from the addon's assets/ dir into a target project.
// Default destination is <project>/assets/vendor/; --dest overrides (relative to
// the project root, or an absolute path). Each pack folder is copied whole —
// License/source files included — so the CC0 attribution stays intact.
func runInstallAssets(args []string) int {
	fs := flag.NewFlagSet("install-assets", flag.ContinueOnError)
	project := fs.String("project", "", "target Godot project dir (default: the project containing the cwd)")
	from := fs.String("from", "", "asset source dir (default: addons/godot_mcp/assets next to the binary)")
	dest := fs.String("dest", "assets/vendor", "destination, relative to the project root or an absolute path")
	pack := fs.String("pack", "", "install only this pack folder (default: every pack in the source)")
	list := fs.Bool("list", false, "list the bundled packs and exit (no project needed)")
	force := fs.Bool("force", false, "overwrite a pack dir that already exists")
	fs.Usage = subHelp(fs, "copy bundled CC0 asset packs into a project",
		[]string{
			"godot-mcp install-assets [--project DIR] [--dest assets/vendor] [--pack NAME] [--force]",
			"godot-mcp install-assets --list",
		})
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}

	// Resolve the source assets dir across both shipped layouts. The marker is
	// `.gdignore`, which the assets dir carries by design (it stops the editor
	// scanning the pack sources) and which is present whatever packs ship.
	src, tried := resolveAsset(*from, ".gdignore",
		[]string{"addons", "godot_mcp", "assets"},            // release archive
		[]string{"project", "addons", "godot_mcp", "assets"}, // repo checkout
	)
	if src == "" {
		fmt.Fprintln(os.Stderr, "install-assets: no asset source found. Looked in:")
		for _, p := range tried {
			fmt.Fprintf(os.Stderr, "  %s\n", p)
		}
		fmt.Fprintln(os.Stderr, "Run it from the extracted release folder, or pass --from with the path to addons/godot_mcp/assets.")
		return 1
	}
	packs, err := listPacks(src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "install-assets: cannot read asset source %q: %v\n", src, err)
		return 1
	}
	if len(packs) == 0 {
		fmt.Fprintf(os.Stderr, "install-assets: no packs found under %q\n", src)
		return 1
	}

	if *list {
		fmt.Printf("Bundled asset packs in %s:\n", src)
		for _, p := range packs {
			fmt.Printf("  %s\n", p)
		}
		return 0
	}

	// Narrow to a single pack if requested.
	if *pack != "" {
		if !contains(packs, *pack) {
			fmt.Fprintf(os.Stderr, "install-assets: pack %q not found (have: %s)\n", *pack, strings.Join(packs, ", "))
			return 1
		}
		packs = []string{*pack}
	}

	// Resolve the project and the destination dir.
	start := *project
	if start == "" {
		start, _ = os.Getwd()
	}
	root, err := client.FindProjectRoot(start)
	if err != nil {
		fmt.Fprintln(os.Stderr, "install-assets: no Godot project found —", err)
		return 1
	}
	destDir := *dest
	if !filepath.IsAbs(destDir) {
		destDir = filepath.Join(root, destDir)
	}

	installed := 0
	for _, name := range packs {
		dstPack := filepath.Join(destDir, name)
		if pathExists(dstPack) && !*force {
			fmt.Fprintf(os.Stderr, "install-assets: %q already exists (use --force)\n", dstPack)
			continue
		}
		skipped, err := copyDir(filepath.Join(src, name), dstPack)
		if err != nil {
			fmt.Fprintf(os.Stderr, "install-assets: copying %s: %v\n", name, err)
			continue
		}
		fmt.Printf("installed pack   -> %s\n", dstPack)
		reportSkipped(skipped)
		if res := resPath(root, dstPack); res != "" {
			fmt.Printf("  reference as     %s/...\n", res)
		}
		installed++
	}
	if installed == 0 {
		return 1
	}
	fmt.Println("Godot will import the new files when the editor next has focus (or run `editor reload`).")
	return 0
}

// listPacks returns the names of immediate sub-directories of src (each a pack).
func listPacks(src string) ([]string, error) {
	entries, err := os.ReadDir(src)
	if err != nil {
		return nil, err
	}
	var packs []string
	for _, e := range entries {
		if e.IsDir() {
			packs = append(packs, e.Name())
		}
	}
	sort.Strings(packs)
	return packs, nil
}

// resPath renders a path inside the project as a res:// URI, or "" if it falls
// outside the project root (an absolute --dest elsewhere).
func resPath(root, p string) string {
	rel, err := filepath.Rel(root, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return ""
	}
	return "res://" + filepath.ToSlash(rel)
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
