package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveCLIProject(t *testing.T) {
	root := filepath.Join(t.TempDir(), "project with spaces 日本語")
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte("config_version=5"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := resolveCLIProject(root)
	if err != nil || got != root {
		t.Fatal(got, err)
	}
	if _, err := resolveCLIProject(filepath.Join(root, "missing")); err == nil {
		t.Fatal("accepted missing target")
	}
	if _, err := resolveCLIProject(filepath.Join(root, "project.godot")); err == nil {
		t.Fatal("accepted file as directory")
	}
}
