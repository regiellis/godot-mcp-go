package main

import (
	"os"
	"os/exec"
	"testing"
)

func TestQAWorkerContracts(t *testing.T) {
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
	cmd := exec.Command(python, "../../scripts/test_qa.py")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("QA worker: %v\n%s", err, output)
	}
}
