package main

import (
	"strings"
	"testing"
)

func TestParseParams(t *testing.T) {
	got, err := parseParams([]string{
		"--type", "Sprite2D",
		"--parent-path", ".",
		"--value=Vector2(1, 2)",
		"--keep-offsets",
		"--named-only=false",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"type":         "Sprite2D",
		"parent_path":  ".",
		"value":        "Vector2(1, 2)",
		"keep_offsets": true,
		"named_only":   false,
	}
	if len(got) != len(want) {
		t.Fatalf("len mismatch: got %v want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q: got %v (%T) want %v (%T)", k, got[k], got[k], v, v)
		}
	}
}

func TestParseParamsRejectsBareArg(t *testing.T) {
	if _, err := parseParams([]string{"oops"}); err == nil {
		t.Fatal("expected error for non-flag argument")
	}
}

func TestParseParamsJSONValues(t *testing.T) {
	got, err := parseParams([]string{"--properties", `["text","visible"]`, "--value", "Vector2(1, 2)"})
	if err != nil {
		t.Fatal(err)
	}
	arr, ok := got["properties"].([]any)
	if !ok || len(arr) != 2 || arr[0] != "text" || arr[1] != "visible" {
		t.Fatalf("properties not parsed as JSON array: %#v", got["properties"])
	}
	// Godot literals must stay strings, not be mistaken for JSON.
	if got["value"] != "Vector2(1, 2)" {
		t.Fatalf("value should stay a string, got %#v", got["value"])
	}
}

func TestParseParamsRejectsMalformedJSON(t *testing.T) {
	// A bracketed value that does not parse used to pass through as a string,
	// which the addon's typed params discard for a default: the call succeeded
	// and the flag went nowhere. It has to fail loudly instead, naming the flag.
	cases := []struct {
		name string
		args []string
	}{
		{"shell-mangled array", []string{"--properties", `[\"health\"]`}},
		{"unterminated array", []string{"--properties", `["health"`}},
		{"single-quoted object", []string{"--value", `{'a': 1}`}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := parseParams(c.args)
			if err == nil {
				t.Fatal("expected an error for a value that opens as JSON but does not parse")
			}
			if !strings.Contains(err.Error(), c.args[0]) {
				t.Errorf("error does not name the flag %q: %v", c.args[0], err)
			}
			// The escape hatch has to be in the message, or the error is a dead end.
			if !strings.Contains(err.Error(), `\`) {
				t.Errorf("error does not offer the backslash escape: %v", err)
			}
		})
	}
}

func TestParseParamsStringFallbacksSurvive(t *testing.T) {
	// Only bracketed values are read as JSON. Everything else, Godot literals
	// included, still reaches the addon verbatim, and a backslash sends a literal
	// value that genuinely starts with a bracket or brace.
	got, err := parseParams([]string{
		"--value", "Vector2(1, 2)",
		"--code", "print(1)",
		"--text", `\[not json]`,
		"--tags", `\{literal}`,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"value": "Vector2(1, 2)",
		"code":  "print(1)",
		"text":  "[not json]",
		"tags":  "{literal}",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q: got %#v, want %q", k, got[k], v)
		}
	}
}
