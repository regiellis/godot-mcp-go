package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// Migration keeps a recoverable journal outside .godot, which Godot may clear.
type migrationJournal struct {
	Original []byte `json:"original_project"`
	Migrated []byte `json:"migrated_project"`
}

func migrationIdle(root string) error {
	for _, name := range []string{"swallowtail.json", "godot-mcp.json"} {
		b, err := os.ReadFile(filepath.Join(root, ".godot", name))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		var d client.Discovery
		if err == nil {
			if err = json.Unmarshal(b, &d); err != nil {
				return fmt.Errorf("unreadable discovery record: %w", err)
			}
			if client.PIDAlive(d.PID) {
				return fmt.Errorf("close this project's editor before migration")
			}
		}
	}
	if d, err := client.ReadGameDiscovery(root); err == nil && client.PIDAlive(d.PID) {
		return fmt.Errorf("stop this project's standalone game before migration")
	}
	return nil
}

func migrationProject(data []byte) ([]byte, error) {
	text := string(data)
	if strings.Contains(text, "res://addons/swallowtail/") {
		return nil, fmt.Errorf("project already references Swallowtail; resolve the mixed install before migration")
	}
	if strings.Contains(text, "[swallowtail]") && strings.Contains(text, "[godot_mcp]") {
		return nil, fmt.Errorf("both setting sections exist; merge their values before migration")
	}
	lines := strings.Split(text, "\n")
	start, end := sectionBounds(lines, "autoload")
	for _, entry := range gameAutoloads {
		if value, found := autoloadValue(lines, start, end, entry[0]); found && strings.TrimPrefix(value, "*") != strings.ReplaceAll(entry[1], "addons/swallowtail/", "addons/godot_mcp/") {
			return nil, fmt.Errorf("autoload %s belongs to another script; refusing to change it", entry[0])
		}
	}
	text = strings.ReplaceAll(text, "res://addons/godot_mcp/", "res://addons/swallowtail/")
	text = strings.ReplaceAll(text, "[godot_mcp]", "[swallowtail]")
	return []byte(text), nil
}

func runMigrate(args []string) int {
	fs := flag.NewFlagSet("migrate", flag.ContinueOnError)
	project := fs.String("project", "", "project to migrate")
	apply := fs.Bool("apply", false, "apply the previewed addon migration")
	rollback := fs.Bool("rollback", false, "restore the saved pre-migration addon and project settings")
	from := fs.String("from", "", "Swallowtail addon source")
	fs.Usage = subHelp(fs, "migrate an installed godot_mcp addon to Swallowtail; preview by default", []string{"swallowtail migrate --project DIR [--apply | --rollback]"})
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}
	if *apply && *rollback {
		fmt.Fprintln(os.Stderr, "choose --apply or --rollback")
		return 2
	}
	root, err := client.FindProjectRoot(*project)
	if *project == "" {
		root, err = client.FindProjectRoot(cliWorkingDirectory())
	}
	if err == nil {
		err = migrateProject(root, *from, *apply, *rollback)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "migration:", err)
		return 1
	}
	return 0
}

func migrateProject(root, from string, apply, rollback bool) (resultErr error) {
	if err := migrationIdle(root); err != nil {
		return err
	}
	oldDir := filepath.Join(root, "addons", "godot_mcp")
	newDir := filepath.Join(root, "addons", "swallowtail")
	backup := filepath.Join(root, ".swallowtail-migration")
	config := filepath.Join(root, "project.godot")
	journalPath := filepath.Join(backup, "journal.json")
	if rollback {
		return rollbackMigration(config, oldDir, newDir, backup, journalPath)
	}
	if pathExists(backup) {
		return fmt.Errorf("migration journal already exists at %s; use --rollback to recover", backup)
	}
	if !fileExists(filepath.Join(oldDir, "plugin.cfg")) {
		return fmt.Errorf("no legacy addon installed at %s", oldDir)
	}
	if pathExists(newDir) {
		return fmt.Errorf("%s already exists; refusing to enable two addon copies", newDir)
	}
	original, err := os.ReadFile(config)
	if err != nil {
		return err
	}
	migrated, err := migrationProject(original)
	if err != nil {
		return err
	}
	source, _ := resolveAsset(from, "plugin.cfg", []string{"addons", "swallowtail"}, []string{"project", "addons", "swallowtail"})
	if source == "" {
		return fmt.Errorf("Swallowtail addon source not found; keep addons beside the executable or use --from")
	}
	// Never follow a linked installation or source tree outside its owning project.
	for _, path := range []string{filepath.Join(root, "addons"), oldDir, source} {
		if err := rejectMigrationLinks(path); err != nil {
			return err
		}
	}
	fmt.Printf("Move addon: %s -> %s\nUpdate owned paths and setting namespace in project.godot\nPreserve runtime autoload names for existing scripts\nBackup and recovery journal: %s\n", oldDir, newDir, backup)
	if !apply {
		fmt.Println("Preview only. Add --apply to migrate with the editor closed.")
		return nil
	}
	if err = os.Mkdir(backup, 0700); err != nil {
		return err
	}
	journal, _ := json.MarshalIndent(migrationJournal{original, migrated}, "", "  ")
	if err = os.WriteFile(journalPath, journal, 0600); err != nil {
		return err
	}
	defer func() {
		if resultErr != nil {
			if recoveryErr := rollbackMigration(config, oldDir, newDir, backup, journalPath); recoveryErr != nil {
				resultErr = fmt.Errorf("%w; automatic recovery failed: %v; journal: %s", resultErr, recoveryErr, backup)
			}
		}
	}()
	stage := filepath.Join(backup, "staged-addon")
	if _, err = copyDir(source, stage); err != nil {
		return fmt.Errorf("staging failed; original install unchanged; use --rollback: %w", err)
	}
	if !fileExists(filepath.Join(stage, "services", "game_inspector.gd")) || !fileExists(filepath.Join(stage, "identity.gd")) {
		return fmt.Errorf("incomplete Swallowtail addon; original install unchanged; use --rollback")
	}
	if err = os.Rename(oldDir, filepath.Join(backup, "legacy-addon")); err != nil {
		return err
	}
	if err = os.Rename(stage, newDir); err != nil {
		return fmt.Errorf("staged addon activation failed; use --rollback: %w", err)
	}
	// Recheck the file just before replacing it, so an external edit is not lost.
	current, err := os.ReadFile(config)
	if err != nil {
		return err
	}
	if !bytes.Equal(current, original) {
		return fmt.Errorf("project.godot changed during migration; backup retained for manual recovery at %s", backup)
	}
	tmp := filepath.Join(root, ".swallowtail-project.tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(migrated)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(tmp, config); err != nil {
		return fmt.Errorf("settings activation failed; use --rollback: %w", err)
	}
	check, err := os.ReadFile(config)
	if err != nil {
		return err
	}
	if !bytes.Equal(check, migrated) {
		return fmt.Errorf("settings verification failed; use --rollback")
	}
	fmt.Println("Migration complete. Run swallowtail doctor, then launch and test your project. Keep .swallowtail-migration until verified.")
	return nil
}

func rejectMigrationLinks(root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("migration refuses linked path %s", path)
		}
		return nil
	})
}

func rollbackMigration(config, oldDir, newDir, backup, journalPath string) error {
	b, err := os.ReadFile(journalPath)
	if err != nil {
		return err
	}
	var j migrationJournal
	if err = json.Unmarshal(b, &j); err != nil {
		return err
	}
	if len(j.Original) == 0 || len(j.Migrated) == 0 {
		return fmt.Errorf("invalid migration journal")
	}
	current, err := os.ReadFile(config)
	if err != nil {
		return err
	}
	if !bytes.Equal(current, j.Original) && !bytes.Equal(current, j.Migrated) {
		return fmt.Errorf("project.godot changed since migration; refusing to overwrite your edits; backup: %s", backup)
	}
	legacy := filepath.Join(backup, "legacy-addon")
	if pathExists(legacy) {
		if pathExists(oldDir) {
			return fmt.Errorf("legacy destination already exists; refusing to overwrite")
		}
		if pathExists(newDir) {
			if err = os.Rename(newDir, filepath.Join(backup, "reverted-addon")); err != nil {
				return err
			}
		}
		if err = os.Rename(legacy, oldDir); err != nil {
			return err
		}
	}
	if err = os.WriteFile(config, j.Original, 0600); err != nil {
		return err
	}
	fmt.Printf("Restored original project settings and addon. Retained migration files at %s\n", backup)
	return nil
}
