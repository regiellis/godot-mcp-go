package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A real export_presets.cfg, trimmed: two presets, each followed by its own
// [preset.N.options] section. Those option sections carry a "name" key of their
// own in some platforms, so reading them as presets would invent a third entry.
const presetsCfg = `[preset.0]

name="Windows Desktop"
platform="Windows Desktop"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
export_path="builds/windows/game.exe"
encryption_include_filters=""

[preset.0.options]

custom_template/debug=""
custom_template/release=""
binary_format/embed_pck=false
application/icon_interpolation=4

[preset.1]

name="Web"
platform="Web"
runnable=true
export_path="res://builds/web/index.html"

[preset.1.options]

custom_template/debug=""
variant/extensions_support=false
`

func TestParseExportPresets(t *testing.T) {
	presets := parseExportPresets(presetsCfg)
	if len(presets) != 2 {
		t.Fatalf("parsed %d presets, want 2: %+v", len(presets), presets)
	}
	if presets[0].Index != 0 || presets[0].Name != "Windows Desktop" ||
		presets[0].Platform != "Windows Desktop" || presets[0].ExportPath != "builds/windows/game.exe" {
		t.Errorf("preset 0 = %+v", presets[0])
	}
	if presets[1].Index != 1 || presets[1].Name != "Web" || presets[1].ExportPath != "res://builds/web/index.html" {
		t.Errorf("preset 1 = %+v", presets[1])
	}
}

// A project with no export config names the file, since "configure an export
// first" is the fix and an empty list says nothing.
func TestReadExportPresetsMissingFile(t *testing.T) {
	root := t.TempDir()
	_, err := readExportPresets(root)
	if err == nil {
		t.Fatal("readExportPresets succeeded with no export_presets.cfg")
	}
	if !strings.Contains(err.Error(), "export_presets.cfg") {
		t.Errorf("error = %q, want it to name export_presets.cfg", err)
	}
}

func TestFindExportPreset(t *testing.T) {
	presets := parseExportPresets(presetsCfg)
	if p, ok := findExportPreset(presets, "Web"); !ok || p.Index != 1 {
		t.Errorf("by name Web = %+v, %v", p, ok)
	}
	// The index is the fallback, so a preset whose name is awkward to quote on a
	// shell is still reachable.
	if p, ok := findExportPreset(presets, "0"); !ok || p.Name != "Windows Desktop" {
		t.Errorf("by index 0 = %+v, %v", p, ok)
	}
	if _, ok := findExportPreset(presets, "Nintendo"); ok {
		t.Error("findExportPreset matched a preset that is not there")
	}
}

func TestExportOutputPath(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "myproject")
	presets := parseExportPresets(presetsCfg)

	// A relative export_path is relative to the project directory, which is how
	// export_presets.cfg writes one.
	got, err := exportOutputPath(root, presets[0], "")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "builds", "windows", "game.exe"); got != want {
		t.Errorf("default output = %q, want %q", got, want)
	}

	// res:// resolves against the project root too.
	got, err = exportOutputPath(root, presets[1], "")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "builds", "web", "index.html"); got != want {
		t.Errorf("res:// output = %q, want %q", got, want)
	}

	// An absolute --out is taken as given. It has to be absolute on this OS, so
	// it comes from the test's own temp dir rather than a hand-built path that
	// Windows would read as drive-relative.
	abs := filepath.Join(t.TempDir(), "out.exe")
	if got, err := exportOutputPath(root, presets[0], abs); err != nil || got != abs {
		t.Errorf("absolute --out = %q, %v; want %q", got, err, abs)
	}

	// A preset with no export_path and no --out is an error naming the flag,
	// never an export into an empty path.
	empty := exportPreset{Name: "Bare"}
	if _, err := exportOutputPath(root, empty, ""); err == nil || !strings.Contains(err.Error(), "--out") {
		t.Errorf("empty export_path error = %v, want it to name --out", err)
	}
}

func TestExportArgs(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "games", "myproject")
	out := filepath.Join(root, "builds", "game.exe")

	cases := []struct {
		mode    string
		patches string
		want    []string
	}{
		{"release", "", []string{"--headless", "--path", root, "--export-release", "Win", out}},
		{"debug", "", []string{"--headless", "--path", root, "--export-debug", "Win", out}},
		{"pack", "", []string{"--headless", "--path", root, "--export-pack", "Win", out}},
		{"patch", "a.pck,b.pck", []string{"--headless", "--path", root, "--patches", "a.pck,b.pck", "--export-patch", "Win", out}},
		// --patches belongs to patch mode alone, so it never rides along elsewhere.
		{"release", "a.pck", []string{"--headless", "--path", root, "--export-release", "Win", out}},
	}
	for _, c := range cases {
		got := exportArgs(root, c.mode, "Win", out, c.patches)
		if strings.Join(got, "\x00") != strings.Join(c.want, "\x00") {
			t.Errorf("exportArgs(%s) = %v, want %v", c.mode, got, c.want)
		}
	}
}

func TestExportMode(t *testing.T) {
	cases := []struct {
		debug, pack, patch bool
		want               string
		wantErr            bool
	}{
		{false, false, false, "release", false},
		{true, false, false, "debug", false},
		{false, true, false, "pack", false},
		{false, false, true, "patch", false},
		{true, true, false, "", true},
		{true, false, true, "", true},
	}
	for _, c := range cases {
		got, err := exportMode(c.debug, c.pack, c.patch)
		if c.wantErr {
			if err == nil {
				t.Errorf("exportMode(%v,%v,%v) succeeded, want an exclusivity error", c.debug, c.pack, c.patch)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("exportMode(%v,%v,%v) = %q, %v; want %q", c.debug, c.pack, c.patch, got, err, c.want)
		}
	}
}

// The one case Godot's exit code gets wrong: a clean exit that wrote nothing,
// which is what a missing export template produces. That must not report success.
func TestExportOutcome(t *testing.T) {
	base := exportResult{OutputPath: "/games/p/builds/game.exe", Log: "/games/p/.godot/godot-mcp-export.log"}

	ok := base
	ok.Exists = true
	ok.SizeBytes = 1234
	if line, rc := exportOutcome(ok, false, 0); rc != 0 || !strings.Contains(line, "1234") {
		t.Errorf("clean export = %q, rc %d; want rc 0 naming the size", line, rc)
	}

	empty := base
	if line, rc := exportOutcome(empty, false, 0); rc != 1 || !strings.Contains(line, "export info") {
		t.Errorf("exit 0 with no file = %q, rc %d; want rc 1 pointing at export info", line, rc)
	}

	failed := base
	failed.ExitCode = 3
	if _, rc := exportOutcome(failed, false, 0); rc != 3 {
		t.Errorf("godot exit 3 gave rc %d, want it passed through", rc)
	}
}

// Export templates live in a directory named for the version config, which is
// the numbers plus the release status. The build hash and custom_build suffix
// that `--version` prints are not part of it.
func TestVersionConfigFrom(t *testing.T) {
	cases := map[string]string{
		"4.7.2.rc.custom_build.36a04fe52": "4.7.2.rc",
		"4.7.2.stable.mono":               "4.7.2.stable",
		"4.5.beta3.official.1a2b3c4":      "4.5.beta3",
		"4.7.2":                           "",
		"":                                "",
	}
	for in, want := range cases {
		if got := versionConfigFrom(in); got != want {
			t.Errorf("versionConfigFrom(%q) = %q, want %q", in, got, want)
		}
	}
}

// An export writes into a directory Godot requires to exist, and the preset's
// path can name one that does not. The subcommand creates it, so this proves the
// path it hands MkdirAll is the parent of the output rather than the output.
func TestExportOutputParentIsADirectory(t *testing.T) {
	root := t.TempDir()
	out, err := exportOutputPath(root, exportPreset{Name: "Win", ExportPath: "builds/windows/game.exe"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		t.Fatalf("creating the output directory: %v", err)
	}
	if fi, serr := os.Stat(filepath.Join(root, "builds", "windows")); serr != nil || !fi.IsDir() {
		t.Errorf("builds/windows was not created as a directory: %v", serr)
	}
}
