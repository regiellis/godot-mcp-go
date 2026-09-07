package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/bynine/godot-mcp-go/internal/client"
)

var cliProjectRoot string

func resolveCLIProject(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	st, err := os.Stat(abs)
	if err != nil {
		return "", err
	}
	if !st.IsDir() {
		return "", fmt.Errorf("--project must name a project directory")
	}
	root, err := client.FindProjectRoot(abs)
	if err != nil {
		return "", err
	}
	return root, nil
}

func cliWorkingDirectory() string {
	if cliProjectRoot != "" {
		return cliProjectRoot
	}
	cwd, _ := os.Getwd()
	return cwd
}
