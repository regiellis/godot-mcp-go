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
	write(filepath.Join(root, "mcp_commands", "custom.gd"), legacyCommand)
	write(filepath.Join(root, "mcp_commands", "plain.gd"), plainCommand)
	write(filepath.Join(root, "mcp_commands", "lib", "helper.gd"), legacyHelper)
	return root, source, original
}

const (
	legacyCommand = "@tool\nextends \"res://addons/godot_mcp/commands/base_command.gd\"\n"
	plainCommand  = "extends Node\n"
	legacyHelper  = "const Base = preload(\"res://addons/godot_mcp/commands/base_command.gd\")\n"
)

func readText(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestMigrationPreviewApplyRollback(t *testing.T) {
	root, source, original := migrationFixture(t)
	if err := migrateProject(root, source, false, false); err != nil {
		t.Fatal(err)
	}
	if pathExists(filepath.Join(root, ".swallowtail-migration")) {
		t.Fatal("preview wrote backup")
	}
	custom := filepath.Join(root, "mcp_commands", "custom.gd")
	helper := filepath.Join(root, "mcp_commands", "lib", "helper.gd")
	plain := filepath.Join(root, "mcp_commands", "plain.gd")
	if readText(t, custom) != legacyCommand {
		t.Fatal("preview rewrote a command file")
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
	for _, path := range []string{custom, helper} {
		text := readText(t, path)
		if strings.Contains(text, "addons/godot_mcp/") || !strings.Contains(text, "res://addons/swallowtail/commands/base_command.gd") {
			t.Fatalf("command file not rewritten: %s", text)
		}
	}
	if readText(t, plain) != plainCommand {
		t.Fatal("rewrote a command file with no legacy reference")
	}
	if pathExists(custom + ".swallowtail-migration.tmp") {
		t.Fatal("temp file left behind")
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
	if readText(t, custom) != legacyCommand || readText(t, helper) != legacyHelper {
		t.Fatal("rollback did not restore command files")
	}
}

func TestMigrationRollbackPreservesEditedCommandFile(t *testing.T) {
	root, source, _ := migrationFixture(t)
	if err := migrateProject(root, source, true, false); err != nil {
		t.Fatal(err)
	}
	custom := filepath.Join(root, "mcp_commands", "custom.gd")
	edited := readText(t, custom) + "\n# subsequent edit\n"
	os.WriteFile(custom, []byte(edited), 0600)
	if err := migrateProject(root, source, false, true); err == nil {
		t.Fatal("rollback overwrote an edited command file")
	}
	if readText(t, custom) != edited {
		t.Fatal("later edit lost")
	}
	if !fileExists(filepath.Join(root, "addons", "swallowtail", "plugin.cfg")) {
		t.Fatal("refused rollback moved the addon anyway")
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
	if readText(t, filepath.Join(root, "mcp_commands", "custom.gd")) != legacyCommand {
		t.Fatal("staging failure changed a command file")
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
