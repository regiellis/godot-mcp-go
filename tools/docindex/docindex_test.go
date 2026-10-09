package main

import (
	"fmt"
	"strings"
	"testing"
)

func doc(lines ...string) string { return strings.Join(lines, "\n") + "\n" }

func TestRenderListsSectionsWithExactRanges(t *testing.T) {
	in := doc(
		"---",
		"name: x",
		"---",
		"",
		"# Title",
		"",
		"Intro.",
		"",
		"## First section",
		"",
		"```sh",
		"# a shell comment, not a heading",
		"```",
		"",
		"## Second: `code` & more",
		"body",
	)
	out := Render(in)
	got := strings.Split(out, "\n")

	// Each listed range must start on its heading and end on real content.
	for _, l := range got {
		var n, start, end int
		var rest string
		if _, err := fmt.Sscanf(l, "%d. %s", &n, &rest); err != nil || !strings.Contains(l, "(lines ") {
			continue
		}
		fmt.Sscanf(l[strings.LastIndex(l, "(lines ")+len("(lines "):], "%d-%d", &start, &end)
		if !strings.HasPrefix(got[start-1], "## ") {
			t.Errorf("range start %d is %q, want a heading", start, got[start-1])
		}
		if strings.TrimSpace(got[end-1]) == "" {
			t.Errorf("range end %d is blank", end)
		}
	}
	for _, want := range []string{
		"1. [First section](#first-section) (lines 16-20)",
		"2. [Second: `code` & more](#second-code--more) (lines 22-23)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if !strings.Contains(out, "23 lines.") {
		t.Errorf("total line count wrong:\n%s", out)
	}
	if !strings.HasPrefix(out, "---\nname: x\n---\n\n# Title\n\n## Contents\n") {
		t.Errorf("block not placed after the title:\n%s", out)
	}
}

func TestRenderIsIdempotentAndPreservesCRLF(t *testing.T) {
	in := strings.ReplaceAll(doc("# T", "", "## A", "a", "", "## B", "b"), "\n", "\r\n")
	once := Render(in)
	if Render(once) != once {
		t.Fatalf("second render changed the doc:\n%s", once)
	}
	if strings.Count(once, "\n") != strings.Count(once, "\r\n") {
		t.Fatal("line endings changed")
	}
	if !strings.Contains(once, "## Contents") {
		t.Fatal("no block")
	}
}

func TestRenderKeepsAMovedBlockInPlace(t *testing.T) {
	// A stale block placed below the lead paragraph, as the README does.
	in := doc("# T", "", "Lead paragraph.", "", "## Contents", "", blockStart+" stale -->", "1. stale", blockEnd, "", "## A", "a", "", "## B", "b")
	out := Render(in)
	got := strings.Split(out, "\n")
	if got[2] != "Lead paragraph." || got[4] != "## Contents" || got[11] != "## A" || got[14] != "## B" {
		t.Fatalf("block moved:\n%s", out)
	}
	if got[7] != "1. [A](#a) (lines 12-13)" || got[8] != "2. [B](#b) (lines 15-16)" {
		t.Fatalf("ranges wrong:\n%s", out)
	}
}

func TestRenderSkipsDocsWithOneSection(t *testing.T) {
	in := doc("# T", "", "## Only", "text")
	if out := Render(in); out != in {
		t.Fatalf("expected no change, got\n%s", out)
	}
}

func TestRenderListsSubsectionsOfLongSections(t *testing.T) {
	lines := []string{"# T", "", "## Short", "x", "", "### Hidden", "y", "", "## Long", "", "### Shown"}
	for i := 0; i < readWindow; i++ {
		lines = append(lines, "filler")
	}
	out := Render(doc(lines...))
	if strings.Contains(out, "[Hidden]") || !strings.Contains(out, "   - [Shown](#shown)") {
		t.Fatalf("subsection listing wrong:\n%s", out[:400])
	}
}

func TestHeadingKeepsTrailingHash(t *testing.T) {
	heads := parseHeadings([]string{"## Calling GDScript from C#", "## Closed ##"})
	if heads[0].title != "Calling GDScript from C#" || heads[1].title != "Closed" {
		t.Fatalf("titles: %q, %q", heads[0].title, heads[1].title)
	}
}

func TestSlugMatchesGitHub(t *testing.T) {
	for in, want := range map[string]string{
		"1. The dual-grid fix: type corners, not cells": "1-the-dual-grid-fix-type-corners-not-cells",
		"Write like a Godot developer (read these)":     "write-like-a-godot-developer-read-these",
		"`scene save` & [links](x)":                     "scene-save--links",
	} {
		if got := slug(in); got != want {
			t.Errorf("slug(%q) = %q, want %q", in, got, want)
		}
	}
}

// The shipped docs must carry current indexes; this is what makes task check fail
// when a heading moves without a regenerate.
func TestRepoDocsAreIndexed(t *testing.T) {
	stale, err := run("../..", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(stale) > 0 {
		t.Fatalf("stale doc indexes, run go run ./tools/docindex: %v", stale)
	}
}
