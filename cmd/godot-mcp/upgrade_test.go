package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseGDExtension(t *testing.T) {
	const text = `[configuration]

entry_symbol = "example_init"
compatibility_minimum = "4.2"

[libraries]

windows.debug.x86_64 = "res://bin/example.windows.debug.x86_64.dll"
windows.release.x86_64 = "res://bin/example.windows.release.x86_64.dll"
linux.debug.x86_64 = "res://bin/libexample.linux.debug.x86_64.so"
macos.debug = "res://bin/libexample.macos.framework"
`
	onDisk := map[string]bool{
		"res://bin/example.windows.debug.x86_64.dll":   true,
		"res://bin/libexample.linux.debug.x86_64.so":   true,
		"res://bin/example.windows.release.x86_64.dll": false,
	}
	got := parseGDExtension("addons/example/example.gdextension", text, "windows", func(p string) bool { return onDisk[p] })

	if got.CompatibilityMinimum != "4.2" {
		t.Errorf("compatibility_minimum = %q, want 4.2", got.CompatibilityMinimum)
	}
	if len(got.Libraries) != 4 {
		t.Fatalf("libraries = %d, want 4", len(got.Libraries))
	}
	if !got.HasPlatformBuild {
		t.Error("HasPlatformBuild = false; the windows debug binary is on disk")
	}
	for _, lib := range got.Libraries {
		wantPlatform := strings.HasPrefix(lib.Key, "windows")
		if lib.Platform != wantPlatform {
			t.Errorf("%s: Platform = %v, want %v", lib.Key, lib.Platform, wantPlatform)
		}
	}

	// The same file on a machine with no build for its platform is the hard
	// refusal preflight makes before anything else runs.
	mac := parseGDExtension("x.gdextension", text, "macos", func(p string) bool { return onDisk[p] })
	if mac.HasPlatformBuild {
		t.Error("HasPlatformBuild = true on macos; the framework is not on disk")
	}
}

func TestKeyMatchesPlatform(t *testing.T) {
	cases := []struct {
		key, platform string
		want          bool
	}{
		{"windows.debug.x86_64", "windows", true},
		{"linux.release.arm64", "linux", true},
		{"linuxbsd.debug", "linux", true},
		{"macos", "macos", true},
		{"android.debug.arm64", "windows", false},
		{"web.debug.wasm32", "linux", false},
	}
	for _, c := range cases {
		if got := keyMatchesPlatform(c.key, c.platform); got != c.want {
			t.Errorf("keyMatchesPlatform(%q, %q) = %v, want %v", c.key, c.platform, got, c.want)
		}
	}
}

func TestScanExtResources(t *testing.T) {
	root := t.TempDir()
	write(t, root, "icon.png", "not really a png")
	write(t, root, "scenes/ok.tscn", `[gd_scene load_steps=2 format=3]

[ext_resource type="Texture2D" path="res://icon.png" id="1_a"]

[node name="Ok" type="Node2D"]
`)
	write(t, root, "scenes/broken.tscn", `[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://scenes/gone.tscn" id="1_b"]

[node name="Broken" type="Node2D"]
`)

	got, err := scanExtResources(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("findings = %d, want 1: %+v", len(got), got)
	}
	f := got[0]
	if f.Category != catMissingRef || f.File != "res://scenes/broken.tscn" || f.Line != 3 {
		t.Errorf("finding = %+v, want the broken scene at line 3", f)
	}
	if !strings.Contains(f.Detail, "res://scenes/gone.tscn") {
		t.Errorf("detail = %q, want it to name the missing path", f.Detail)
	}
}

func TestScanTileMapNodes(t *testing.T) {
	root := t.TempDir()
	write(t, root, "scenes/level.tscn", `[gd_scene format=3]

[node name="Level" type="Node2D"]

[node name="Ground" type="TileMap" parent="."]

[node name="Props" type="TileMapLayer" parent="World"]

[node name="Deep" type="TileMap" parent="World/Sub"]
`)
	got, err := scanTileMapNodes(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("nodes = %d, want 2 (TileMapLayer is not TileMap): %+v", len(got), got)
	}
	if got[0].Path != "Ground" {
		t.Errorf("path = %q, want Ground", got[0].Path)
	}
	if got[1].Path != "World/Sub/Deep" {
		t.Errorf("path = %q, want World/Sub/Deep", got[1].Path)
	}
}

func TestScanScriptText(t *testing.T) {
	const src = `extends Node

@export_file("*.json") var config_path: String = ""
@export_file_path("*.cfg") var already_fixed: String = ""

func _ready() -> void:
	if config_path.begins_with("res://"):
		pass

func load_it(text: String) -> void:
	var plain: Dictionary = JSON.parse_string(text)
	var cast: Dictionary = JSON.parse_string(text) as Dictionary
	var typed: Dictionary[String, int] = JSON.parse_string(text)

func layers(map: Node) -> int:
	return map.get_layers_count()

# get_layers_count() in a comment is not a call site
`
	got := scanScriptText(src)

	if len(got.ExportFileLines) != 1 || got.ExportFileLines[0] != 3 {
		t.Errorf("ExportFileLines = %v, want [3]; @export_file_path is already the fix", got.ExportFileLines)
	}
	if len(got.ResMatchLines) != 1 || got.ResMatchLines[0] != 7 {
		t.Errorf("ResMatchLines = %v, want [7]", got.ResMatchLines)
	}
	if len(got.TypedDictLines) != 2 {
		t.Fatalf("TypedDictLines = %v, want the plain and the element-typed one, not the line already cast", got.TypedDictLines)
	}
	if got.TypedDictLines[0] != 11 || got.TypedDictTyped[0] {
		t.Errorf("first typed-dict hit = line %d typed=%v, want line 11 untyped", got.TypedDictLines[0], got.TypedDictTyped[0])
	}
	if got.TypedDictLines[1] != 13 || !got.TypedDictTyped[1] {
		t.Errorf("second typed-dict hit = line %d typed=%v, want line 13 typed", got.TypedDictLines[1], got.TypedDictTyped[1])
	}
	if len(got.RenameHits) != 1 || got.RenameHits[0].Line != 16 {
		t.Errorf("RenameHits = %+v, want one at line 16; a comment is not a call site", got.RenameHits)
	}
}

// TestParseResaveDiff feeds the parser a real git diff of what the 4.7 editor
// rewrote, captured from the live bed project on 2026-08-30. Every node line
// grew a unique_id attribute and the header lost load_steps, which is format
// rather than damage; the one genuine drop is the property removed with no
// addition to match it.
func TestParseResaveDiff(t *testing.T) {
	const diff = `diff --git a/scenes/main.tscn b/scenes/main.tscn
index 1173a67..ca6b207 100644
--- a/scenes/main.tscn
+++ b/scenes/main.tscn
@@ -1,4 +1,4 @@
-[gd_scene load_steps=7 format=3 uid="uid://cdl4hvrn3nxf2"]
+[gd_scene format=3 uid="uid://cdl4hvrn3nxf2"]

 [ext_resource type="Environment" uid="uid://cm77bbr0io118" path="res://scenes/main-environment.tres" id="1_x8oc8"]

@@ -7,12 +7,11 @@
-[node name="Main" type="Node3D"]
+[node name="Main" type="Node3D" unique_id=617358373]

-[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
+[node name="WorldEnvironment" type="WorldEnvironment" parent="." unique_id=1716984466]
 environment = ExtResource("1_x8oc8")

-[node name="Floor" type="CSGBox3D" parent="."]
+[node name="Floor" type="CSGBox3D" parent="." unique_id=1456196414]
 size = Vector3(100, 0.001, 100)
-legacy_only_property = 3

-[node name="Gone" type="Node3D" parent="."]
`
	got := parseResaveDiff(diff)
	if len(got) != 2 {
		t.Fatalf("findings = %d, want 2 (one dropped property, one dropped node): %+v", len(got), got)
	}
	prop, node := got[0], got[1]
	if prop.Node != "Floor" || prop.Property != "legacy_only_property" {
		t.Errorf("first finding = %+v, want Floor.legacy_only_property", prop)
	}
	if prop.File != "res://scenes/main.tscn" || prop.Source != srcResaveDiff || prop.Category != catResaveDrop {
		t.Errorf("first finding = %+v, want the scene, the resave source and the resave category", prop)
	}
	if node.Node != "Gone" || node.Property != "" {
		t.Errorf("second finding = %+v, want the Gone node with no property", node)
	}
}

func TestParseResaveDiffIgnoresProjectSettingsRewrite(t *testing.T) {
	// A settings key that moves from one section to another arrives as a
	// removal and an addition under different sections, and only the removal
	// counts, because the addition is not in the section that lost it.
	const diff = `diff --git a/project.godot b/project.godot
--- a/project.godot
+++ b/project.godot
@@ -1,6 +1,6 @@
 [application]
 config/name="Bed"
-run/main_scene="res://scenes/main.tscn"
+run/main_scene="res://scenes/start.tscn"
`
	if got := parseResaveDiff(diff); len(got) != 0 {
		t.Errorf("findings = %+v, want none: the key was changed, not dropped", got)
	}
}

func TestBucketing(t *testing.T) {
	findings := []upgradeFinding{
		{Category: catExportFile, Source: srcOffline, File: "res://a.gd"},
		{Category: catExportFile, Source: srcOffline, File: "res://a.gd"},
		{Category: catExportFile, Source: srcOffline, File: "res://b.gd"},
		{Category: catRenames, Source: srcRenameSweep, File: "res://a.gd"},
		{Category: catWarning, Source: srcWarnings},
	}
	counts := countByCategory(findings)
	if counts[catExportFile] != 3 || counts[catRenames] != 1 || counts[catWarning] != 1 {
		t.Errorf("counts = %v", counts)
	}
	files := filesByCategory(findings)
	if len(files[catExportFile]) != 2 || files[catExportFile]["res://a.gd"] != 2 {
		t.Errorf("files = %v, want two files with a.gd carrying two findings", files)
	}
	if _, ok := files[catWarning]; ok {
		t.Error("a finding with no file must not create a file bucket")
	}

	sources := summarizeSources(findings, map[string]string{srcOffline: "read it", srcWarnings: "read it too"})
	if len(sources) != 8 {
		t.Fatalf("sources = %d, want all seven plus the offline scan", len(sources))
	}
	byName := map[string]sourceSummary{}
	for _, s := range sources {
		byName[s.Source] = s
	}
	if !byName[srcOffline].Read || byName[srcOffline].Count != 3 {
		t.Errorf("offline = %+v", byName[srcOffline])
	}
	if byName[srcRenameSweep].Read {
		t.Error("a source nobody read must not report as read; found nothing and not looked at are different answers")
	}
	if byName[srcDrive].Count != 0 || byName[srcDrive].Read {
		t.Errorf("drive = %+v, want unread and empty", byName[srcDrive])
	}
}

func TestPhaseArgv(t *testing.T) {
	root := filepath.FromSlash("/projects/bed")

	if got := checkArgs(root, "res://scripts/loader.gd"); strings.Join(got, " ") !=
		"--headless --path "+root+" --script res://scripts/loader.gd --check-only" {
		t.Errorf("cold parse argv = %v", got)
	}
	if got := editorArgs(root, true); strings.Join(got, " ") != "--path "+root+" --editor --headless" {
		t.Errorf("open argv = %v", got)
	}

	// The movie fallback baseline uses when there is no scenario to replay.
	movie := filepath.Join(root, ".godot", "upgrade", "baseline", "frame%d.png")
	got := gameArgs(root, gameRunOptions{Movie: movie, FixedFPS: 60, Extra: "--quit-after 300"})
	want := []string{"--path", root, "--write-movie", movie, "--quit-after", "300"}
	for _, w := range want {
		if !containsArg(got, w) {
			t.Errorf("movie argv %v is missing %q", got, w)
		}
	}
	if !containsArg(got, "--fixed-fps") {
		t.Errorf("movie argv %v is missing --fixed-fps; frames have to be written on a fixed clock", got)
	}
}

func TestSetProjectSettings(t *testing.T) {
	const before = `; Engine configuration file.

config_version=5

[application]

config/name="Bed"
config/features=PackedStringArray("4.6", "Forward Plus")

[rendering]

anti_aliasing/quality/msaa_3d=2
`
	got := setProjectSettings(before, map[string]string{
		"debug/gdscript/warnings/enable":          "true",
		"debug/gdscript/warnings/unused_variable": "1",
		"rendering/anti_aliasing/quality/msaa_3d": "4",
	})

	if !strings.Contains(got, "[debug]") {
		t.Error("a missing section must be created")
	}
	if !strings.Contains(got, "gdscript/warnings/unused_variable=1") {
		t.Error("the warning key was not written")
	}
	if strings.Contains(got, "msaa_3d=2") || !strings.Contains(got, "msaa_3d=4") {
		t.Error("an existing key must be replaced in place, not duplicated")
	}
	if !strings.Contains(got, `config/features=PackedStringArray("4.6", "Forward Plus")`) {
		t.Error("every untouched line must survive verbatim")
	}
	if strings.Count(got, "[application]") != 1 {
		t.Error("sections must not be duplicated")
	}

	back := readProjectSettings(got)
	if back["debug/gdscript/warnings/unused_variable"] != "1" {
		t.Errorf("round trip lost the key: %v", back["debug/gdscript/warnings/unused_variable"])
	}
	if back["config_version"] != "5" {
		t.Errorf("the preamble did not round trip: %q", back["config_version"])
	}
}

func TestWarningSettingsKeepsAnEscalatedWarning(t *testing.T) {
	values := warningSettings(map[string]string{
		"debug/gdscript/warnings/unused_variable": "2",
	})
	if values["debug/gdscript/warnings/unused_variable"] != "2" {
		t.Error("a warning the project escalated to error must keep the error")
	}
	if values["debug/gdscript/warnings/enable"] != "true" {
		t.Error("the warning system has to be switched on")
	}
	if values["debug/gdscript/warnings/native_method_override"] != "2" {
		t.Error("a key the engine itself defaults to error must not be lowered to warn")
	}
	if values["debug/gdscript/warnings/unsafe_cast"] != "1" {
		t.Error("an ordinary key has to reach warn")
	}
	if _, ok := values["debug/gdscript/warnings/directory_rules"]; ok {
		t.Error("directory_rules is a Dictionary, not a level, and must be left alone")
	}
}

func TestRewriteLines(t *testing.T) {
	cases := []struct {
		name       string
		fn         func(string) (string, bool)
		in, want   string
		wantChange bool
	}{
		{"export_file", rewriteExportFileLine,
			`@export_file("*.json") var p: String = ""`,
			`@export_file_path("*.json") var p: String = ""`, true},
		{"export_file already fixed", rewriteExportFileLine,
			`@export_file_path("*.json") var p: String = ""`,
			`@export_file_path("*.json") var p: String = ""`, false},
		{"typed dict", rewriteTypedDictLine,
			`	var d: Dictionary = JSON.parse_string(text)`,
			`	var d: Dictionary = JSON.parse_string(text) as Dictionary`, true},
		{"typed dict with a trailing comment", rewriteTypedDictLine,
			`	var d: Dictionary = JSON.parse_string(read(")")) # note`,
			`	var d: Dictionary = JSON.parse_string(read(")")) as Dictionary # note`, true},
		{"typed dict already cast", rewriteTypedDictLine,
			`	var d: Dictionary = JSON.parse_string(text) as Dictionary`,
			`	var d: Dictionary = JSON.parse_string(text) as Dictionary`, false},
		{"element-typed dict has no mechanical fix", rewriteTypedDictLine,
			`	var d: Dictionary[String, int] = JSON.parse_string(text)`,
			`	var d: Dictionary[String, int] = JSON.parse_string(text)`, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := c.fn(c.in)
			if got != c.want || changed != c.wantChange {
				t.Errorf("got %q (changed=%v), want %q (changed=%v)", got, changed, c.want, c.wantChange)
			}
		})
	}
}

func TestFeatureTag(t *testing.T) {
	root := t.TempDir()
	write(t, root, "project.godot", `config_version=5

[application]

config/features=PackedStringArray("4.6", "Forward Plus")
`)
	got := scanFeatureTag(root, "4.7")
	if len(got) != 1 || got[0].Category != catSettings || !got[0].Fixable {
		t.Fatalf("findings = %+v, want one fixable settings finding", got)
	}
	value := featureTagValue(root, "4.7")
	if len(value) != 2 || value[0] != "4.7" || value[1] != "Forward Plus" {
		t.Errorf("feature tag = %v, want the target version plus the renderer the project already used", value)
	}
	if again := scanFeatureTag(root, "4.6"); len(again) != 0 {
		t.Errorf("findings = %+v, want none when the tag already names the target", again)
	}
}

func TestUnifiedDiff(t *testing.T) {
	before := "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
	after := "a\nb\nc\nd\ne\nf\ng\nH\ni\nj\n"
	got := unifiedDiff("res://x.gd", before, after)
	if !strings.HasPrefix(got, "--- a/res://x.gd\n+++ b/res://x.gd\n") {
		t.Errorf("diff has no file header:\n%s", got)
	}
	if !strings.Contains(got, "-h\n+H\n") {
		t.Errorf("diff does not carry the change:\n%s", got)
	}
	if strings.Contains(got, " a\n") {
		t.Errorf("context should stop three lines out:\n%s", got)
	}
	if unifiedDiff("res://x.gd", before, before) != "" {
		t.Error("an unchanged file must produce no diff")
	}
}

func TestShortVersion(t *testing.T) {
	cases := map[string]string{
		"4.7.2.rc.custom_build.36a04fe52": "4.7",
		"4.3.stable.official":             "4.3",
		"4.6":                             "4.6",
	}
	for in, want := range cases {
		if got := shortVersion(in); got != want {
			t.Errorf("shortVersion(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestScanUIDSidecars(t *testing.T) {
	root := t.TempDir()
	write(t, root, "scripts/with.gd", "extends Node\n")
	write(t, root, "scripts/with.gd.uid", "uid://abc\n")
	write(t, root, "scripts/without.gd", "extends Node\n")
	write(t, root, "shaders/plain.gdshader", "shader_type canvas_item;\n")

	got, err := scanUIDSidecars(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("findings = %+v, want the script and the shader with no sidecar", got)
	}
	for _, f := range got {
		if f.Category != catUID || !f.Fixable {
			t.Errorf("finding = %+v, want a fixable uid finding", f)
		}
	}
}

// write puts a file under root, creating its directories.
func write(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// containsArg reports whether argv carries an exact argument.
func containsArg(argv []string, want string) bool {
	for _, a := range argv {
		if a == want {
			return true
		}
	}
	return false
}

func TestEngineInternalLine(t *testing.T) {
	cases := []struct {
		name string
		e    engineLogEntry
		want bool
	}{
		{"dummy renderer null", engineLogEntry{Level: "ERROR", Message: `Parameter "t" is null.`, File: `.\servers/rendering/dummy/storage/texture_storage.h`, Line: 110}, true},
		{"engine line naming a project file", engineLogEntry{Level: "ERROR", Message: "Failed loading resource: res://scenes/deleted_prop.tscn.", File: `core\io\resource_loader.cpp`, Line: 317}, false},
		{"script error", engineLogEntry{Level: "SCRIPT ERROR", Message: "Parse Error", File: "res://scripts/loader.gd", Line: 4}, false},
		{"no source at all", engineLogEntry{Level: "ERROR", Message: "something"}, false},
	}
	for _, c := range cases {
		if got := engineInternalLine(c.e); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestComparePayloadDecode(t *testing.T) {
	// The exact result shape editor.compare_screenshots returns (editor_commands.gd).
	raw := `{"identical":false,"changed_pixels":97964,"total_pixels":921600,"diff_percentage":10.63,"threshold":10,"width":1280,"height":720}`
	var p comparePayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	if p.ChangedPixels != 97964 || p.ChangedPercent != 10.63 {
		t.Errorf("decoded %+v; the percentage must come from diff_percentage", p)
	}
}
