package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// The pretty renderer is asserted with the Plain palette: layout is the
// contract, color is presentation the palette owns.

func TestRenderPrettyObjectBox(t *testing.T) {
	got, err := renderPretty("scene.info", json.RawMessage(`{"name":"hi","a":1}`), ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"╭─ scene.info ──╮",
		"  a     1",
		"  name  hi",
		"╰───────────────╯",
	}, "\n")
	if got != want {
		t.Errorf("object box:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRenderPrettyObjectMultilineString(t *testing.T) {
	got, err := renderPretty("script.get", json.RawMessage(`{"source":"line1\nline2"}`), ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"╭─ script.get ──╮",
		"  source",
		"    line1",
		"    line2",
		"╰───────────────╯",
	}, "\n")
	if got != want {
		t.Errorf("multi-line value:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRenderPrettyObjectBigNestedValue(t *testing.T) {
	long := strings.Repeat("z", 70)
	raw := json.RawMessage(`{"a":{"x":1,"y":"` + long + `"}}`)
	got, err := renderPretty("p.q", raw, ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	// The widest body line is `  "y": "<70 z's>"` at block indent 4 → inner 83.
	want := strings.Join([]string{
		"╭─ p.q " + strings.Repeat("─", 78) + "╮",
		"  a",
		"    {",
		`      "x": 1,`,
		`      "y": "` + long + `"`,
		"    }",
		"╰" + strings.Repeat("─", 84) + "╯",
	}, "\n")
	if got != want {
		t.Errorf("nested block:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRenderPrettyTable(t *testing.T) {
	got, err := renderPretty("node.list", json.RawMessage(`[{"a":1,"b":"x"},{"a":22}]`), ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"node.list · 2 items",
		"  a   b",
		"  ──  ─",
		"  1   x",
		"  22",
	}, "\n")
	if got != want {
		t.Errorf("table:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRenderPrettyScalarList(t *testing.T) {
	got, err := renderPretty("x.y", json.RawMessage(`["a",3,true]`), ui.Plain)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"x.y · 3 items",
		"  • a",
		"  • 3",
		"  • true",
	}, "\n")
	if got != want {
		t.Errorf("scalar list:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRenderPrettyEmptyAndScalar(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{`{}`, "x.y (empty)"},
		{`[]`, "x.y (empty)"},
		{`42`, "42"},
		{`"ok"`, "ok"},
	} {
		got, err := renderPretty("x.y", json.RawMessage(tc.in), ui.Plain)
		if err != nil {
			t.Fatalf("%s: %v", tc.in, err)
		}
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestTruncateCell(t *testing.T) {
	long := strings.Repeat("ab", maxPrettyCell)
	got := truncateCell(long)
	if n := len([]rune(got)); n != maxPrettyCell {
		t.Errorf("truncated width = %d, want %d", n, maxPrettyCell)
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("truncated cell %q missing ellipsis", got)
	}
	if short := "abc"; truncateCell(short) != short {
		t.Errorf("short cell modified")
	}
}
