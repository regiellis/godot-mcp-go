package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
)

// The portable QA worker and report assets ship inside the CLI. Python's standard
// library handles runs; only PDF rendering needs the optional ReportLab package.
//
//go:embed qaassets/*.py qaassets/*.gd qaassets/*.ttf qaassets/*.txt qaassets/*.png
var qaAssets embed.FS

func runQA(args []string) int {
	python := os.Getenv("SWALLOWTAIL_PYTHON")
	if python == "" {
		for _, name := range []string{"python3", "python"} {
			if path, err := exec.LookPath(name); err == nil {
				python = path
				break
			}
		}
	}
	if python == "" {
		fmt.Fprintln(os.Stderr, "qa requires Python 3.10+; set SWALLOWTAIL_PYTHON to its executable")
		return 2
	}
	// A fresh directory prevents simultaneous invocations from rewriting each
	// other's worker. It is project-local and contains no user-authored files.
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "--project" {
			root = args[i+1]
		}
	}
	cache := filepath.Join(root, ".godot", "swallowtail-qa", "workers")
	if err = os.MkdirAll(cache, 0755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	dir, err := os.MkdirTemp(cache, "worker-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer os.RemoveAll(dir) // only this call's newly-created worker, never run evidence
	err = fs.WalkDir(qaAssets, "qaassets", func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		data, readErr := qaAssets.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		return os.WriteFile(filepath.Join(dir, filepath.Base(path)), data, 0644)
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	cmd := exec.Command(python, append([]string{filepath.Join(dir, "qa.py")}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err = cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode()
		}
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	return 0
}
