package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParamsInput(t *testing.T) {
	if _, err := readParamsInput("-", strings.NewReader("{\"text\":\"\xff\"}")); err == nil {
		t.Fatal("accepted invalid UTF-8")
	}
	m, err := readParamsInput("-", strings.NewReader("\ufeff"+`{"node-path":"Greeting","value":"こんにちは","array":[true,4],"large":9007199254740993}`))
	if err != nil || m["node_path"] != "Greeting" || m["value"] != "こんにちは" || m["large"] != json.Number("9007199254740993") {
		t.Fatal(m, err)
	}
	for _, raw := range []string{`[]`, `null`, `{bad`, `{} {}`, `{"node-path":1,"node_path":2}`, `{"":1}`} {
		if _, err := readParamsInput("-", strings.NewReader(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	if _, err := readParamsInput("-", strings.NewReader(strings.Repeat(" ", maxParamsBytes+1))); err == nil {
		t.Fatal("accepted oversized input")
	}
}
