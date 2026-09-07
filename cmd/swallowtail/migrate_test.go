package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func migrationFixture(t *testing.T) (string, string, []byte) {
	t.Helper()
	root := t.TempDir()
	source := t.TempDir()
	write := func(path, text string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	original := []byte("config_version=5\n[autoload]\nMCPGameInspector=\"*res://addons/godot_mcp/services/game_inspector.gd\"\n[editor_plugins]\nenabled=PackedStringArray(\"res://addons/godot_mcp/plugin.cfg\")\n[godot_mcp]\nnetwork/port=9094\n")
	write(filepath.Join(root, "project.godot"), string(original))
	write(filepath.Join(root, "addons", "godot_mcp", "plugin.cfg"), "legacy marker")
	write(filepath.Join(source, "plugin.cfg"), "new marker")
	write(filepath.Join(source, "identity.gd"), "extends RefCounted")
	write(filepath.Join(source, "services", "game_inspector.gd"), "extends Node")
	return root, source, original
}

func TestMigrationPreviewApplyRollback(t *testing.T) {
	root, source, original := migrationFixture(t)
	if err := migrateProject(root, source, false, false); err != nil {
		t.Fatal(err)
	}
	if pathExists(filepath.Join(root, ".swallowtail-migration")) {
		t.Fatal("preview wrote backup")
	}
	if err := migrateProject(root, source, true, false); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(root, "project.godot"))
	if strings.Contains(string(b), "godot_mcp") || !strings.Contains(string(b), "[swallowtail]") {
		t.Fatalf("settings: %s", b)
	}
	if pathExists(filepath.Join(root, "addons", "godot_mcp")) {
		t.Fatal("duplicate addon remains")
	}
	if err := migrateProject(root, source, false, true); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(filepath.Join(root, "project.godot"))
	if !bytes.Equal(b, original) {
		t.Fatal("rollback changed project bytes")
	}
	if !fileExists(filepath.Join(root, "addons", "godot_mcp", "plugin.cfg")) {
		t.Fatal("rollback missed addon")
	}
}

func TestMigrationStagingFailurePreservesOriginal(t *testing.T) {
	root, source, original := migrationFixture(t)
	if err := os.Remove(filepath.Join(source, "identity.gd")); err != nil {
		t.Fatal(err)
	}
	if err := migrateProject(root, source, true, false); err == nil {
		t.Fatal("accepted incomplete addon")
	}
	b, _ := os.ReadFile(filepath.Join(root, "project.godot"))
	if !bytes.Equal(b, original) {
		t.Fatal("staging failure changed settings")
	}
	if !fileExists(filepath.Join(root, "addons", "godot_mcp", "plugin.cfg")) {
		t.Fatal("lost original addon")
	}
}

func TestMigrationRefusesLiveEditor(t *testing.T) {
	root, source, _ := migrationFixture(t)
	dir := filepath.Join(root, ".godot")
	os.MkdirAll(dir, 0755)
	os.WriteFile(filepath.Join(dir, "godot-mcp.json"), []byte(fmt.Sprintf(`{"pid":%d}`, os.Getpid())), 0600)
	if err := migrateProject(root, source, true, false); err == nil {
		t.Fatal("migrated open editor")
	}
}

func TestMigrationRollbackPreservesLaterEdits(t *testing.T) {
	root, source, _ := migrationFixture(t)
	if err := migrateProject(root, source, true, false); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(root, "project.godot")
	b, _ := os.ReadFile(config)
	b = append(b, []byte("\n; subsequent edit\n")...)
	os.WriteFile(config, b, 0600)
	if err := migrateProject(root, source, false, true); err == nil {
		t.Fatal("rollback overwrote later edit")
	}
	after, _ := os.ReadFile(config)
	if !bytes.Equal(after, b) {
		t.Fatal("later edit lost")
	}
}

func TestMigrationRefusesForeignAutoloadAndMixedSettings(t *testing.T) {
	for _, text := range []string{"[autoload]\nMCPGameInspector=\"*res://custom.gd\"", "[godot_mcp]\n[swallowtail]"} {
		if _, err := migrationProject([]byte(text)); err == nil {
			t.Fatalf("accepted %s", text)
		}
	}
}
