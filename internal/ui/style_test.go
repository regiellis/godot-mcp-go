package ui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlainPassesThrough(t *testing.T) {
	if got := Plain.Fail("boom"); got != "boom" {
		t.Errorf("Plain styled its input: %q", got)
	}
}

func TestEnabledPaletteWrapsAndResets(t *testing.T) {
	p := Palette{on: true}
	got := p.Key("name")
	if !strings.HasPrefix(got, "\x1b[38;5;172m") || !strings.HasSuffix(got, "\x1b[0m") {
		t.Errorf("Key(name) = %q, want accent-wrapped with reset", got)
	}
	if p.Key("") != "" {
		t.Error("styling an empty string must stay empty, not emit bare escapes")
	}
}

func TestForFileIsPlain(t *testing.T) {
	f, err := os.Create(filepath.Join(t.TempDir(), "out"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if For(f).Enabled() {
		t.Error("a regular file is not a terminal; palette must be plain")
	}
}
