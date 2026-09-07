package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func TestCompletionCandidates(t *testing.T) {
	c := cliCatalog{Methods: []string{"scene.tree", "custom.ping", "custom.bad;touch"}, Docs: map[string]commandDoc{"scene.tree": {Params: []paramDoc{{Name: "max_depth"}}}}}
	for _, tc := range []struct {
		words []string
		want  string
	}{
		{[]string{"sc"}, "scene"}, {[]string{"scene", "tr"}, "tree"}, {[]string{"scene", "tree", "--max"}, "--max-depth"}, {[]string{"doctor", "--j"}, "--json"},
		{[]string{"upgrade", "pre"}, "preflight"},
		{[]string{"upgrade", "preflight", "--old"}, "--old-godot"},
	} {
		if got := completionCandidates(tc.words, c); !slices.Contains(got, tc.want) {
			t.Fatal(tc, got)
		}
	}
	if got := completionCandidates([]string{"custom", ""}, c); len(got) != 2 || !slices.Contains(got, "ping") {
		t.Fatal(got)
	}
}

func TestCatalogIsolationAndCorruption(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	c := cliCatalog{Project: a, Port: 9081, Saved: time.Now(), Methods: []string{"custom.ping"}, Docs: map[string]commandDoc{}}
	saveCLICatalog(a, c)
	if got, err := readCLICatalog(a); err != nil || got.Methods[0] != "custom.ping" {
		t.Fatal(got, err)
	}
	raw, _ := json.Marshal(c)
	_ = os.MkdirAll(filepath.Join(b, ".godot"), 0755)
	_ = os.WriteFile(catalogPath(b), raw, 0600)
	if _, err := readCLICatalog(b); err == nil {
		t.Fatal("accepted another project's catalog")
	}
	_ = os.WriteFile(catalogPath(a), []byte("{bad"), 0600)
	if _, err := readCLICatalog(a); err == nil {
		t.Fatal("accepted corrupt cache")
	}
	c.Methods = []string{"custom.replaced"}
	saveCLICatalog(a, c)
	if got, err := readCLICatalog(a); err != nil || len(got.Methods) != 1 || got.Methods[0] != "custom.replaced" {
		t.Fatal(got, err)
	}
}
