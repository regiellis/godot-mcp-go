package main

import "testing"

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
