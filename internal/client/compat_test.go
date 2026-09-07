package client

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestEnvironmentMigration(t *testing.T) {
	t.Setenv("GODOT_MCP_PORT", "9084")
	t.Setenv("SWALLOWTAIL_PORT", "")
	if p, err := ResolvePort(0, t.TempDir()); err != nil || p != 9084 {
		t.Fatalf("legacy: %d %v", p, err)
	}
	t.Setenv("SWALLOWTAIL_PORT", "9085")
	if p, err := ResolvePort(0, t.TempDir()); err != nil || p != 9085 {
		t.Fatalf("primary: %d %v", p, err)
	}
	t.Setenv("SWALLOWTAIL_PORT", "invalid")
	if _, err := ResolvePort(0, t.TempDir()); err == nil {
		t.Fatal("invalid primary silently fell back")
	}
	if p, err := ResolvePort(9090, t.TempDir()); err != nil || p != 9090 {
		t.Fatalf("flag: %d %v", p, err)
	}
}

func TestDiscoveryMigration(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".godot")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	write := func(name string, pid, port int) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(fmt.Sprintf(`{"pid":%d,"port":%d}`, pid, port)), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("godot-mcp.json", os.Getpid(), 9084)
	d, err := ReadDiscovery(root)
	if err != nil || d.Port != 9084 {
		t.Fatalf("legacy: %v %v", d, err)
	}
	write("swallowtail.json", 0, 9085)
	d, err = ReadDiscovery(root)
	if err != nil || d.Port != 9084 {
		t.Fatalf("stale primary: %v %v", d, err)
	}
	write("swallowtail.json", os.Getpid(), 9085)
	if _, err := ReadDiscovery(root); !errors.Is(err, ErrDiscoveryConflict) {
		t.Fatalf("conflict: %v", err)
	}
	write("swallowtail.json", os.Getpid(), 9084)
	if _, err := ReadDiscovery(root); err != nil {
		t.Fatal(err)
	}
}
