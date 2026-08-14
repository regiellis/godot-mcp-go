package main

import (
	"encoding/json"
	"io"
	"os"
	"testing"
)

// A completed --all scan is a successful command whatever it found: an empty
// editor list is the answer "nothing is running", and exiting 1 on it made the
// preflight look like a broken call. Whether this machine has an editor up while
// the test runs is beside the point; the exit code must not depend on it.
func TestStatusAllExitsZeroWhateverItFinds(t *testing.T) {
	out := captureStdout(t, func() {
		if rc := runStatusAll(t.TempDir()); rc != 0 {
			t.Fatalf("runStatusAll exit = %d, want 0", rc)
		}
	})

	var payload struct {
		Editors []struct{ Port int } `json:"editors"`
		Games   []struct{ Port int } `json:"games"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("output is not the JSON payload: %v (%q)", err, out)
	}
	if payload.Editors == nil || payload.Games == nil {
		t.Errorf("empty lists must render as [] rather than null: %q", out)
	}
}

// runStatusAll writes its payload to stdout; keep that out of the test log.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	saved := os.Stdout
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	restored := false
	restore := func() {
		if restored {
			return
		}
		restored = true
		os.Stdout = saved
		_ = w.Close()
	}
	defer restore()
	fn()
	restore()
	return <-done
}
