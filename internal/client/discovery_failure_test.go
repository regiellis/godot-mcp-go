package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPortConfigurationFailures(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte("config_version=5\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, ".godot"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".godot", "godot-mcp.json"), []byte(`{"port":9093}`), 0600); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"abc", "0", "-1", "65536", "999999999999999999999", "9080.5"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("GODOT_MCP_PORT", value)
			t.Setenv("GODOT_MCP_GAME_PORT", value)
			res := ResolvePortSource(0, root)
			if res.Err == nil || !strings.Contains(res.Err.Error(), "GODOT_MCP_PORT") {
				t.Fatalf("invalid env silently resolved: %+v", res)
			}
			if _, err := ResolvePort(0, root); err == nil {
				t.Fatal("ResolvePort ignored invalid config")
			}
			if _, err := ResolveGamePort(0, root); err == nil {
				t.Fatal("game ignored invalid config")
			}
			if got := Diagnose(root, 0); got.Verdict != VerdictConfigError || got.Reachable {
				t.Fatalf("bad diagnostic: %+v", got)
			}
			if got := ResolvePortSource(9099, root); got.Err != nil || got.Port != 9099 {
				t.Fatalf("explicit port should win: %+v", got)
			}
			if got, err := ResolveGamePort(9299, root); err != nil || got != 9299 {
				t.Fatalf("game explicit port: %d %v", got, err)
			}
		})
	}
	t.Setenv("GODOT_MCP_PORT", "")
	for _, port := range []int{-1, 65536} {
		if got := ResolvePortSource(port, root); got.Err == nil {
			t.Fatalf("accepted flag port %d", port)
		}
	}
	for _, port := range []int{1, 65535} {
		if got := ResolvePortSource(port, root); got.Err != nil {
			t.Fatal(got.Err)
		}
	}
	if got := ResolvePortSource(0, root); got.Err != nil || got.Port != 9093 {
		t.Fatalf("valid discovery: %+v", got)
	}
	if err := os.WriteFile(filepath.Join(root, ".godot", "godot-mcp.json"), []byte(`{"port":65536}`), 0600); err != nil {
		t.Fatal(err)
	}
	if got := ResolvePortSource(0, root); got.Err == nil {
		t.Fatal("accepted invalid discovery port")
	}
}
