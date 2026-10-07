package main

import (
	"os"
	"os/exec"
	"testing"
)

func TestQAWorkerContracts(t *testing.T) {
	// scripts/ is maintainer-only and the public mirror leaves it out.
	const script = "../../scripts/test_qa.py"
	if _, err := os.Stat(script); err != nil {
		t.Skip("QA worker contract script not in this checkout")
	}
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
		t.Skip("QA worker tests require Python 3.10+")
	}
	cmd := exec.Command(python, script)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("QA worker: %v\n%s", err, output)
	}
}
