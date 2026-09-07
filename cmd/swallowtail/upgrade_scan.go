package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// The offline half of the harvest. Nothing here needs an editor, which is what
// lets preflight read the whole project before the first launch rewrites any of
// it, and lets fix --dry-run render a diff without touching the tree.

// walkProjectFiles collects every file under root with one of the given
// extensions, as slash-separated paths relative to root. .godot/ and .git/ are
// always skipped, and addons/ with them: third-party code is the addon author's
// to port, and rewriting it is how a port loses an upstream update.
func walkProjectFiles(root string, exts ...string) ([]string, error) {
	want := map[string]bool{}
	for _, e := range exts {
		want[strings.ToLower(e)] = true
	}
	var out []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			switch d.Name() {
			case ".godot", ".git", "addons":
				return filepath.SkipDir
			}
			return nil
		}
		if !want[strings.ToLower(filepath.Ext(path))] {
			return nil
		}
		rel, rerr := filepath.Rel(root, path)
		if rerr != nil {
			return rerr
		}
		out = append(out, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

// resURI turns a root-relative path into the res:// form every addon command
// takes.
func resURI(rel string) string { return "res://" + filepath.ToSlash(rel) }

// --- GDExtension -------------------------------------------------------------

// gdextLibrary is one entry of a .gdextension file's [libraries] section: the
// platform key, the binary it names, and whether that binary is actually on
// disk for the platform this machine runs.
type gdextLibrary struct {
	Key      string `json:"key"`
	Path     string `json:"path"`
	Exists   bool   `json:"exists"`
	Platform bool   `json:"matches_platform"`
}

// gdextFile is one .gdextension and what it promises. HasPlatformBuild is the
// question preflight refuses on: those binaries are compiled against a specific
// engine ABI and only the addon's author can rebuild them, so a port cannot
// start until each one has a build for the machine doing the porting.
type gdextFile struct {
	File                 string         `json:"file"`
	CompatibilityMinimum string         `json:"compatibility_minimum,omitempty"`
	Libraries            []gdextLibrary `json:"libraries"`
	HasPlatformBuild     bool           `json:"has_platform_build"`
}

// gdextKeyValueRe matches one key = value line of a .gdextension file, which is
// a Godot ConfigFile: unquoted keys, values usually quoted.
var gdextKeyValueRe = regexp.MustCompile(`^([A-Za-z0-9_.]+)\s*=\s*(.*)$`)

// platformToken names this machine the way a .gdextension library key does.
// Godot writes linuxbsd as "linux" in extension keys and macOS as "macos".
func platformToken() string {
	switch runtime.GOOS {
	case "darwin":
		return "macos"
	case "windows":
		return "windows"
	default:
		return "linux"
	}
}

// keyMatchesPlatform reports whether a [libraries] key targets this machine.
// Keys are dot-separated feature tags (windows.debug.x86_64), so a token match
// is the whole test; linuxbsd is accepted as a spelling of linux.
func keyMatchesPlatform(key, platform string) bool {
	for _, tok := range strings.Split(strings.ToLower(key), ".") {
		if tok == platform || (platform == "linux" && tok == "linuxbsd") {
			return true
		}
	}
	return false
}

// parseGDExtension reads a .gdextension file's configuration and libraries.
// exists reports whether a res:// path the file names is on disk; the caller
// supplies it so the parser stays testable without a project on disk.
func parseGDExtension(name, text, platform string, exists func(resPath string) bool) gdextFile {
	out := gdextFile{File: name}
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		m := gdextKeyValueRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		key, value := m[1], strings.Trim(strings.TrimSpace(m[2]), `"`)
		switch section {
		case "configuration":
			if key == "compatibility_minimum" {
				out.CompatibilityMinimum = value
			}
		case "libraries":
			lib := gdextLibrary{Key: key, Path: value, Platform: keyMatchesPlatform(key, platform)}
			lib.Exists = exists(value)
			if lib.Platform && lib.Exists {
				out.HasPlatformBuild = true
			}
			out.Libraries = append(out.Libraries, lib)
		}
	}
	return out
}

// scanGDExtensions reads every .gdextension under the project, addons/
// included: this is the one scan whose whole subject lives there.
func scanGDExtensions(root string) ([]gdextFile, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		if d.IsDir() {
			switch d.Name() {
			case ".godot", ".git":
				return filepath.SkipDir
			}
			return nil
		}
		if strings.EqualFold(filepath.Ext(path), ".gdextension") {
			rel, rerr := filepath.Rel(root, path)
			if rerr != nil {
				return rerr
			}
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	platform := platformToken()
	exists := func(p string) bool {
		local, ok := strings.CutPrefix(p, "res://")
		if !ok {
			return false
		}
		if _, serr := os.Stat(filepath.Join(root, filepath.FromSlash(local))); serr == nil {
			return true
		}
		// A framework bundle on macOS is a directory, and a path naming one
		// resolves the same way; anything else missing is genuinely missing.
		return false
	}
	out := make([]gdextFile, 0, len(files))
	for _, f := range files {
		b, rerr := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
		if rerr != nil {
			continue
		}
		out = append(out, parseGDExtension(f, string(b), platform, exists))
	}
	return out, nil
}

// --- ext_resource references -------------------------------------------------

// extResourceRe pulls the path out of an [ext_resource ...] header in a .tscn
// or .tres. Godot writes one per line, so a line-wise match is enough and a
// path containing a quote is not expressible in the format.
var extResourceRe = regexp.MustCompile(`\[ext_resource\b[^\]]*\bpath="([^"]+)"`)

// scanExtResources reports every ext_resource whose path is not on disk. This
// is the offline half of what scene validate answers in the editor: a dead
// reference loads as a placeholder rather than an error, so nothing about a
// scene opening proves its references resolved.
func scanExtResources(root string) ([]upgradeFinding, error) {
	files, err := walkProjectFiles(root, ".tscn", ".tres", ".escn")
	if err != nil {
		return nil, err
	}
	var findings []upgradeFinding
	for _, rel := range files {
		b, rerr := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if rerr != nil {
			continue
		}
		for i, line := range strings.Split(string(b), "\n") {
			m := extResourceRe.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			target := m[1]
			local, ok := strings.CutPrefix(target, "res://")
			if !ok {
				continue
			}
			if _, serr := os.Stat(filepath.Join(root, filepath.FromSlash(local))); serr == nil {
				continue
			}
			findings = append(findings, upgradeFinding{
				Category: catMissingRef,
				Source:   srcOffline,
				File:     resURI(rel),
				Line:     i + 1,
				Detail:   "ext_resource path " + target + " does not exist",
			})
		}
	}
	return findings, nil
}

// --- TileMap nodes in scenes -------------------------------------------------

// tileMapNodeRe matches a scene's TileMap node header. The closing quote is
// what keeps TileMapLayer out of the match.
var tileMapNodeRe = regexp.MustCompile(`\[node name="([^"]+)" type="TileMap"(?:\s+parent="([^"]*)")?`)

// tileMapNode is one TileMap found in a scene, with the scene-relative node
// path fix --category tilemap will address it by.
type tileMapNode struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Name   string `json:"name"`
	Parent string `json:"parent"`
	Path   string `json:"path"`
}

// scanTileMapNodes finds every TileMap node in the project's scenes. TileMap is
// deprecated since 4.3 in favour of one TileMapLayer per layer, and it still
// ships in 4.7, so a scene carrying one opens and runs while nothing reports it.
func scanTileMapNodes(root string) ([]tileMapNode, error) {
	files, err := walkProjectFiles(root, ".tscn")
	if err != nil {
		return nil, err
	}
	var out []tileMapNode
	for _, rel := range files {
		b, rerr := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if rerr != nil {
			continue
		}
		for i, line := range strings.Split(string(b), "\n") {
			m := tileMapNodeRe.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			node := tileMapNode{File: resURI(rel), Line: i + 1, Name: m[1], Parent: m[2]}
			node.Path = scenePathOf(m[2], m[1])
			out = append(out, node)
		}
	}
	return out, nil
}

// scenePathOf builds the node path relative to the scene root that scene.tree
// and node.* report and take. A node with no parent attribute is the root; a
// parent of "." is a direct child.
func scenePathOf(parent, name string) string {
	switch parent {
	case "":
		return "."
	case ".":
		return name
	default:
		return parent + "/" + name
	}
}

// --- GDScript source scans ---------------------------------------------------

// exportFileRe matches the @export_file annotation but not @export_file_path,
// which is the 4.5 annotation that forces the old res:// shape back.
var exportFileRe = regexp.MustCompile(`@export_file\b(?:_path)?`)

// resPrefixMatchRe matches code that tests a path against the res:// prefix,
// which is what 4.4 broke by making @export_file return a uid:// path.
var resPrefixMatchRe = regexp.MustCompile(`(?:begins_with|match|==|!=)\s*\(?\s*["']res://`)

// typedDictJSONRe matches a Dictionary declaration assigned straight from
// JSON.parse_string, whose Variant result stopped assigning into a typed one in
// 4.4. The optional bracket group is the element-typed form, which no cast can
// satisfy, so it is reported rather than rewritten.
var typedDictJSONRe = regexp.MustCompile(`:\s*Dictionary(\[[^\]]*\])?\s*=\s*JSON\.parse_string\b`)

// scriptScan is the per-file result of the GDScript text sweep, kept so fix can
// rewrite exactly the lines the scan named.
type scriptScan struct {
	ExportFileLines []int
	ResMatchLines   []int
	TypedDictLines  []int
	// TypedDictTyped runs parallel to TypedDictLines: true where the
	// declaration names an element type, which no cast can satisfy.
	TypedDictTyped []bool
	RenameHits     []renameHit
}

// renameHit is one line matching a rename-table entry.
type renameHit struct {
	Line int
	Rule renameRule
}

// scanScriptText runs every GDScript text rule over one file's source. It is
// pure text on purpose: a renamed method called on an untyped variable compiles
// clean and fails at runtime, so the compiler cannot find it and the text can.
func scanScriptText(text string) scriptScan {
	var out scriptScan
	for i, line := range strings.Split(text, "\n") {
		n := i + 1
		code, _, _ := strings.Cut(line, "#")
		if m := exportFileRe.FindString(code); m == "@export_file" {
			out.ExportFileLines = append(out.ExportFileLines, n)
		}
		if resPrefixMatchRe.MatchString(code) {
			out.ResMatchLines = append(out.ResMatchLines, n)
		}
		// The scan asks the rewrite whether there is anything left to do, so a
		// line already carrying the explicit cast stops being a finding. Keeping
		// the two apart is what made fix apply the cast, recount, still see the
		// declaration, and restore its own correct work.
		if m := typedDictJSONRe.FindStringSubmatch(code); m != nil {
			typed := m[1] != ""
			if _, changes := rewriteTypedDictLine(line); typed || changes {
				out.TypedDictLines = append(out.TypedDictLines, n)
				out.TypedDictTyped = append(out.TypedDictTyped, typed)
			}
		}
		for _, rule := range renameTable {
			if strings.Contains(code, rule.Search) {
				out.RenameHits = append(out.RenameHits, renameHit{Line: n, Rule: rule})
			}
		}
	}
	return out
}

// scanScripts sweeps every project script and returns the findings, bucketed
// into the categories fix can act on. @export_file is reported only where the
// same file also string-matches res://: the annotation alone still works, and
// what 4.4 broke is code comparing its result to a res:// prefix.
func scanScripts(root string) ([]upgradeFinding, map[string]scriptScan, error) {
	files, err := walkProjectFiles(root, ".gd")
	if err != nil {
		return nil, nil, err
	}
	scans := map[string]scriptScan{}
	var findings []upgradeFinding
	for _, rel := range files {
		b, rerr := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if rerr != nil {
			continue
		}
		res := resURI(rel)
		scan := scanScriptText(string(b))
		scans[res] = scan
		if len(scan.ResMatchLines) > 0 {
			for _, line := range scan.ExportFileLines {
				findings = append(findings, upgradeFinding{
					Category: catExportFile, Source: srcOffline, File: res, Line: line, Fixable: true,
					Detail: "@export_file returns a uid:// path since 4.4 and this file compares paths against res:// (line " +
						strconv.Itoa(scan.ResMatchLines[0]) + "); @export_file_path forces the old shape",
				})
			}
		}
		for i, line := range scan.TypedDictLines {
			detail := "JSON.parse_string returns a Variant, which stopped assigning into a typed Dictionary in 4.4; an explicit cast makes the assignment survive"
			fixable := true
			if scan.TypedDictTyped[i] {
				detail = "JSON.parse_string returns an untyped Dictionary, which does not assign into one declared with element types; the entries have to be copied across with their types"
				fixable = false
			}
			findings = append(findings, upgradeFinding{
				Category: catTypedDict, Source: srcOffline, File: res, Line: line, Fixable: fixable,
				Detail: detail,
			})
		}
		for _, hit := range scan.RenameHits {
			findings = append(findings, upgradeFinding{
				Category: catRenames, Source: srcRenameSweep, File: res, Line: hit.Line,
				Fixable: hit.Rule.Replace != "",
				Detail:  hit.Rule.Search + ": " + hit.Rule.Detail,
			})
		}
	}
	return findings, scans, nil
}

// --- .uid sidecars -----------------------------------------------------------

// scanUIDSidecars reports every script and shader with no .uid file beside it.
// Godot writes those from 4.4 on and they have to be committed and moved with
// their file, so a project coming from 4.3 adopts them as part of the port.
func scanUIDSidecars(root string) ([]upgradeFinding, error) {
	files, err := walkProjectFiles(root, ".gd", ".gdshader")
	if err != nil {
		return nil, err
	}
	var findings []upgradeFinding
	for _, rel := range files {
		if _, serr := os.Stat(filepath.Join(root, filepath.FromSlash(rel)+".uid")); serr == nil {
			continue
		}
		findings = append(findings, upgradeFinding{
			Category: catUID, Source: srcOffline, File: resURI(rel), Fixable: true,
			Detail: "no .uid sidecar; the editor writes one on scan from 4.4 on and it has to be committed",
		})
	}
	return findings, nil
}

// --- the resave diff ---------------------------------------------------------

// The first open rewrites scenes, resources and project.godot. A property the
// new version dropped prints nothing anywhere, so this diff is the only place
// it shows up.

var (
	diffFileRe    = regexp.MustCompile(`^\+\+\+ b/(.+)$`)
	diffSectionRe = regexp.MustCompile(`^\[([a-z_]+)\b([^\]]*)\]`)
	diffNodeName  = regexp.MustCompile(`name="([^"]+)"`)
	diffKeyRe     = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_/.]*)\s*=`)
)

// parseResaveDiff turns a unified diff of the editor's resave into one finding
// per property that went missing, as file, node, property. A key that also
// appears as an addition in the same hunk changed rather than dropped, and
// changes are format noise; only the drops matter.
func parseResaveDiff(diff string) []upgradeFinding {
	var findings []upgradeFinding
	file := ""
	section := ""
	added := map[string]bool{}
	readded := map[string]bool{}
	var hunk []string

	flush := func() {
		if len(hunk) == 0 {
			return
		}
		// First pass: every key this hunk adds, under the section it lands in.
		sec := section
		for _, line := range hunk {
			body := line[1:]
			if s, ok := diffSection(body); ok {
				sec = s
				// A header rewritten in place is format, not damage: 4.7 adds a
				// unique_id attribute to every node line, so the old header
				// arrives as a removal and the new one as an addition. Only a
				// name that never comes back is a node the resave dropped.
				if strings.HasPrefix(line, "+") {
					readded[s] = true
				}
				continue
			}
			if strings.HasPrefix(line, "+") {
				if m := diffKeyRe.FindStringSubmatch(strings.TrimSpace(body)); m != nil {
					added[sec+"\x00"+m[1]] = true
				}
			}
		}
		// Second pass: removals the hunk never added back.
		sec = section
		for _, line := range hunk {
			body := line[1:]
			if s, ok := diffSection(body); ok {
				sec = s
				if strings.HasPrefix(line, "-") && strings.HasPrefix(strings.TrimSpace(body), "[node ") && !readded[sec] {
					findings = append(findings, upgradeFinding{
						Category: catResaveDrop, Source: srcResaveDiff, File: file, Node: sec,
						Detail: "node removed by the resave",
					})
				}
				continue
			}
			if !strings.HasPrefix(line, "-") {
				continue
			}
			m := diffKeyRe.FindStringSubmatch(strings.TrimSpace(body))
			if m == nil || added[sec+"\x00"+m[1]] {
				continue
			}
			findings = append(findings, upgradeFinding{
				Category: catResaveDrop, Source: srcResaveDiff, File: file, Node: sec, Property: m[1],
				Detail: "dropped by the resave: " + strings.TrimSpace(body),
			})
		}
		section = sec
		hunk = nil
		added = map[string]bool{}
		readded = map[string]bool{}
	}

	for _, line := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			flush()
			file, section = "", ""
		case strings.HasPrefix(line, "+++ "):
			flush()
			if m := diffFileRe.FindStringSubmatch(line); m != nil {
				file = resURI(m[1])
			}
			section = ""
		case strings.HasPrefix(line, "--- "), strings.HasPrefix(line, "index "),
			strings.HasPrefix(line, "new file"), strings.HasPrefix(line, "deleted file"),
			strings.HasPrefix(line, "similarity "), strings.HasPrefix(line, "rename "),
			strings.HasPrefix(line, "old mode"), strings.HasPrefix(line, "new mode"),
			strings.HasPrefix(line, "Binary files"):
			// header noise
		case strings.HasPrefix(line, "@@"):
			flush()
		case line == "":
			// A blank line inside a hunk is context with its leading space
			// stripped by some diff writers; it carries nothing either way.
		default:
			if file == "" {
				continue
			}
			hunk = append(hunk, line)
		}
	}
	flush()
	return findings
}

// diffSection reads a scene, resource, or project.godot section header out of a
// diff line's body and returns the label a finding names it by.
func diffSection(body string) (string, bool) {
	t := strings.TrimSpace(body)
	if !strings.HasPrefix(t, "[") {
		return "", false
	}
	m := diffSectionRe.FindStringSubmatch(t)
	if m == nil {
		// project.godot sections are plain [application] style names.
		if strings.HasSuffix(t, "]") && !strings.ContainsAny(t, " =") {
			return strings.Trim(t, "[]"), true
		}
		return "", false
	}
	if n := diffNodeName.FindStringSubmatch(m[2]); n != nil {
		return n[1], true
	}
	return m[1], true
}
