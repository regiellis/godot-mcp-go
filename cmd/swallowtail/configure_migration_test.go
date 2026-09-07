package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestConfigureRefusesDuplicateLegacyServer(t *testing.T) {
	for _, kind := range []string{"json", "toml"} {
		t.Run(kind, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config."+kind)
			original := []byte(`{"mcpServers":{"godot-mcp":{"command":"godot-mcp","args":["serve"]},"other":{"command":"keep"}}}`)
			if kind == "toml" {
				original = []byte("[mcp_servers.godot-mcp]\ncommand = \"godot-mcp\"\nargs = [\"serve\"]\n")
			}
			if err := os.WriteFile(path, original, 0600); err != nil {
				t.Fatal(err)
			}
			rc := 0
			if kind == "json" {
				rc = configureJSON(path, "mcpServers", "swallowtail", "swallowtail", []string{"serve"}, false, true, false, "client")
			} else {
				rc = configureTOML(path, "swallowtail", "swallowtail", []string{"serve"}, true, false, "client")
			}
			if rc == 0 {
				t.Fatal("created duplicate server")
			}
			after, _ := os.ReadFile(path)
			if !bytes.Equal(after, original) {
				t.Fatal("modified existing configuration")
			}
		})
	}
}
