package main

import (
	"reflect"
	"testing"
)

func TestCommandSuggestions(t *testing.T) {
	got := commandSuggestions("scene.tre", []string{"node.add", "scene.tree", "scene.create", "scene.stop"})
	if len(got) == 0 || got[0] != "swallowtail scene tree" || len(got) > 3 {
		t.Fatal(got)
	}
	if got := commandSuggestions("zzzzzzzzzzzz", []string{"scene.tree"}); len(got) != 0 {
		t.Fatal(got)
	}
	if !reflect.DeepEqual(commandSuggestions("node.gt", []string{"node.set", "node.get"}), commandSuggestions("node.gt", []string{"node.get", "node.set"})) {
		t.Fatal("unstable ordering")
	}
}

func TestAddonFlagsAreNotReserved(t *testing.T) {
	p, err := parseParams([]string{"--format", "png", "--port", "7777"})
	if err != nil || p["format"] != "png" || p["port"] != "7777" {
		t.Fatal(p, err)
	}
}
