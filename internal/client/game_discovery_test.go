package client

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseProjectGodot(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    projectConfig
	}{
		{
			name: "plain name, no custom dir",
			content: `config_version=5

[application]

config/name="Godot MCP Test"
run/main_scene="res://main.tscn"

[display]

window/size/viewport_width=2560
`,
			want: projectConfig{Name: "Godot MCP Test"},
		},
		{
			name: "custom user dir enabled",
			content: `[application]
config/name="My Game"
config/use_custom_user_dir=true
config/custom_user_dir_name="my_studio/my_game"
`,
			want: projectConfig{Name: "My Game", UseCustomUserDir: true, CustomUserDirName: "my_studio/my_game"},
		},
		{
			name: "name key outside application section is ignored",
			content: `[application]
config/name="Real Name"

[other]
config/name="Wrong"
`,
			want: projectConfig{Name: "Real Name"},
		},
		{
			name:    "no application section",
			content: "config_version=5\n",
			want:    projectConfig{},
		},
		{
			name: "escaped quotes in name",
			content: `[application]
config/name="A \"Quoted\" Game"
`,
			want: projectConfig{Name: `A "Quoted" Game`},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "project.godot")
			if err := os.WriteFile(path, []byte(tt.content), 0o644); err != nil {
				t.Fatal(err)
			}
			got, err := parseProjectGodot(path)
			if err != nil {
				t.Fatalf("parseProjectGodot: %v", err)
			}
			if got != tt.want {
				t.Errorf("parseProjectGodot = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParseProjectGodotMissingFile(t *testing.T) {
	_, err := parseProjectGodot(filepath.Join(t.TempDir(), "nope.godot"))
	if err == nil {
		t.Fatal("expected an error for a missing project.godot")
	}
}

func TestUserDataDir(t *testing.T) {
	tests := []struct {
		name     string
		cfg      projectConfig
		goos     string
		dataRoot string
		want     string
	}{
		{
			name:     "windows default",
			cfg:      projectConfig{Name: "Godot MCP Test"},
			goos:     "windows",
			dataRoot: `C:\Users\dev\AppData\Roaming`,
			want:     filepath.Join(`C:\Users\dev\AppData\Roaming`, "Godot", "app_userdata", "Godot MCP Test"),
		},
		{
			name:     "linux uses lowercase godot dir",
			cfg:      projectConfig{Name: "Godot MCP Test"},
			goos:     "linux",
			dataRoot: "/home/dev/.local/share",
			want:     filepath.Join("/home/dev/.local/share", "godot", "app_userdata", "Godot MCP Test"),
		},
		{
			name:     "macos application support",
			cfg:      projectConfig{Name: "My Game"},
			goos:     "darwin",
			dataRoot: "/Users/dev/Library/Application Support",
			want:     filepath.Join("/Users/dev/Library/Application Support", "Godot", "app_userdata", "My Game"),
		},
		{
			name:     "custom user dir bypasses app_userdata",
			cfg:      projectConfig{Name: "My Game", UseCustomUserDir: true, CustomUserDirName: "studio/game"},
			goos:     "linux",
			dataRoot: "/home/dev/.local/share",
			want:     filepath.Join("/home/dev/.local/share", "studio", "game"),
		},
		{
			name:     "custom user dir empty falls back to sanitized name",
			cfg:      projectConfig{Name: "My Game", UseCustomUserDir: true, CustomUserDirName: ""},
			goos:     "linux",
			dataRoot: "/home/dev/.local/share",
			want:     filepath.Join("/home/dev/.local/share", "My Game"),
		},
		{
			name:     "invalid chars in name are sanitized",
			cfg:      projectConfig{Name: `Bad:Name*?`},
			goos:     "windows",
			dataRoot: `C:\data`,
			want:     filepath.Join(`C:\data`, "Godot", "app_userdata", "Bad_Name__"),
		},
		{
			name:     "empty name uses unnamed project",
			cfg:      projectConfig{Name: ""},
			goos:     "linux",
			dataRoot: "/home/dev/.local/share",
			want:     filepath.Join("/home/dev/.local/share", "godot", "app_userdata", "[unnamed project]"),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := userDataDir(tt.cfg, tt.goos, tt.dataRoot)
			if got != tt.want {
				t.Errorf("userDataDir = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestSafeDirName(t *testing.T) {
	tests := []struct {
		in         string
		allowPaths bool
		want       string
	}{
		{"Godot MCP Test", false, "Godot MCP Test"},
		{"  spaced  ", false, "spaced"},
		{"a/b\\c", false, "a_b_c"},
		{"a/b", true, "a/b"},
		{"a\\b", true, "a/b"},
		{"climb/../up", true, "climb/_/up"},
		{`na:me*?"<>|`, false, "na_me______"},
	}
	for _, tt := range tests {
		got := safeDirName(tt.in, tt.allowPaths)
		if got != tt.want {
			t.Errorf("safeDirName(%q, %v) = %q, want %q", tt.in, tt.allowPaths, got, tt.want)
		}
	}
}

func TestResolveGamePortEnv(t *testing.T) {
	t.Setenv("GODOT_MCP_GAME_PORT", "9207")
	if got := ResolveGamePort(0, t.TempDir()); got != 9207 {
		t.Errorf("ResolveGamePort with env = %d, want 9207", got)
	}
	// Explicit flag wins over env.
	if got := ResolveGamePort(9300, t.TempDir()); got != 9300 {
		t.Errorf("ResolveGamePort with flag = %d, want 9300", got)
	}
}

func TestResolveGamePortDefault(t *testing.T) {
	t.Setenv("GODOT_MCP_GAME_PORT", "")
	// A dir with no project.godot and no discovery file falls back to the default.
	if got := ResolveGamePort(0, t.TempDir()); got != DefaultGamePort {
		t.Errorf("ResolveGamePort default = %d, want %d", got, DefaultGamePort)
	}
}
