package main

import (
	"regexp"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

var ansiEscape = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// The grid is the art: every row the same width, only the five classes, and
// the features a 24-pixel butler must keep (two eyes, a bow tie).
func TestMascotGridShape(t *testing.T) {
	for i, row := range mascotRows {
		if len(row) != mascotWidth {
			t.Fatalf("row %d is %d wide, want %d", i, len(row), mascotWidth)
		}
		if strings.Trim(row, "HSCB ") != "" {
			t.Fatalf("row %d holds a class outside H/S/C/B/space: %q", i, row)
		}
	}
	if strings.Count(mascotRows[14], "H") < 2 {
		t.Fatalf("row 14 should carry both eyes: %q", mascotRows[14])
	}
	if !strings.Contains(mascotRows[21], "BBBB") {
		t.Fatalf("row 21 should carry the bow tie: %q", mascotRows[21])
	}
}

// Plain rendering is textures only, no escapes, twelve lines of the grid's
// width; styled rendering is the same shape once the escapes are stripped.
func TestMascotLinesPlainAndStyled(t *testing.T) {
	plain := mascotLines(ui.Plain)
	if len(plain) != len(mascotRows)/2 {
		t.Fatalf("plain: %d lines, want %d", len(plain), len(mascotRows)/2)
	}
	for i, l := range plain {
		if strings.Contains(l, "\x1b") {
			t.Fatalf("plain line %d carries an escape", i)
		}
		if n := utf8.RuneCountInString(l); n != mascotWidth {
			t.Fatalf("plain line %d is %d runes wide, want %d", i, n, mascotWidth)
		}
	}
	styled := mascotLines(ui.Forced)
	for i, l := range styled {
		if !strings.Contains(l, "\x1b[38;5;") {
			t.Fatalf("styled line %d carries no color", i)
		}
		if n := utf8.RuneCountInString(ansiEscape.ReplaceAllString(l, "")); n != mascotWidth {
			t.Fatalf("styled line %d is %d visible runes wide, want %d", i, n, mascotWidth)
		}
	}
	if !strings.Contains(strings.Join(styled, ""), "\x1b[38;5;132") {
		t.Fatal("styled art never uses the bow tie color")
	}
}

// The banner keeps the text column aligned beside the art whether or not an
// editor line is present, and every line starts with the art's indent.
func TestBannerTextLayout(t *testing.T) {
	for _, editor := range []string{"", "● editor running: project on port 9080"} {
		out := bannerText(ui.Plain, editor)
		lines := strings.Split(strings.Trim(out, "\n"), "\n")
		if len(lines) != len(mascotRows)/2 {
			t.Fatalf("editor=%q: %d lines, want %d", editor, len(lines), len(mascotRows)/2)
		}
		if !strings.Contains(lines[1], "Swallowtail") {
			t.Fatalf("wordmark should sit on the second row: %q", lines[1])
		}
		for i, l := range lines {
			if !strings.HasPrefix(l, "  ") {
				t.Fatalf("line %d lacks the indent: %q", i, l)
			}
		}
		if editor != "" && !strings.Contains(out, editor) {
			t.Fatal("editor line missing from the banner")
		}
		if !strings.Contains(out, "swallowtail help") {
			t.Fatal("help pointer missing from the banner")
		}
	}
}
