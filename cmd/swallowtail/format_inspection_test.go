package main

import (
	"encoding/json"
	"github.com/bynine/godot-mcp-go/internal/ui"
	"strings"
	"testing"
)

func TestInspectionTreesAndDetails(t *testing.T) {
	for _, method := range []string{"scene.tree", "runtime.tree"} {
		got, err := renderPretty(method, json.RawMessage(`{"tree":{"name":"Root","type":"Node","children":[{"name":"First","type":"Label","script":"res://x.gd"},{"name":"Last","type":"Node"}]},"truncated":true}`), ui.Plain)
		if err != nil || !strings.Contains(got, "├─ First") || !strings.Contains(got, "└─ Last") || !strings.Contains(got, "res://x.gd") || !strings.Contains(got, "truncated") {
			t.Fatal(got, err)
		}
	}
}

func TestInspectionDiagnosticsAndFallback(t *testing.T) {
	got, err := renderPretty("script.validate", json.RawMessage(`{"valid":false,"path":"res://bad.gd","diagnostics_available":false,"diagnostics":[{"file":"res://bad.gd","line":7,"severity":"error","message":"Unexpected token"}]}`), ui.Plain)
	if err != nil || !strings.Contains(got, "INVALID") || !strings.Contains(got, "res://bad.gd:7") || !strings.Contains(got, "diagnostics_available") {
		t.Fatal(got, err)
	}
	got, err = renderPretty("scene.tree", json.RawMessage(`{"tree":"future format"}`), ui.Plain)
	if err != nil || !strings.Contains(got, "future format") {
		t.Fatal(got, err)
	}
}

func TestInspectionNarrowOutput(t *testing.T) {
	t.Setenv("COLUMNS", "32")
	t.Setenv("NO_COLOR", "1")
	got, err := renderPretty("scene.tree", json.RawMessage(`{"tree":{"name":"Greeting","type":"Node","path":"res://hello.tscn"}}`), ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(got, "\n") {
		if len([]rune(line)) > 32 {
			t.Fatal(line)
		}
	}
	if strings.Contains(got, "\x1b") || !strings.Contains(strings.ReplaceAll(got, "\n", ""), "Greeting") {
		t.Fatal(got)
	}
}
