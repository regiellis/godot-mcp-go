package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
)

func TestMCPInvalidPortResponses(t *testing.T) {
	t.Setenv("GODOT_MCP_PORT", "invalid")
	t.Setenv("GODOT_MCP_GAME_PORT", "invalid")
	for _, request := range []string{
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"godot_run","arguments":{"method":"project.info"}}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"godot_run","arguments":{"method":"runtime.tree","game":true}}}`,
		`{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"godot://project/info"}}`,
	} {
		var output bytes.Buffer
		server := &mcpServer{cwd: t.TempDir(), timeout: time.Millisecond, out: bufio.NewWriter(&output)}
		server.handle([]byte(request))
		var response struct {
			ID     int
			Error  *rpcErr
			Result struct {
				IsError bool `json:"isError"`
			}
		}
		if err := json.Unmarshal(output.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.ID != 1 || (response.Error == nil && !response.Result.IsError) || !strings.Contains(output.String(), "must be an integer") {
			t.Fatalf("configuration error not reported: %s", output.String())
		}
	}
}

func TestInvalidPortDoesNotLaunch(t *testing.T) {
	t.Setenv("GODOT_MCP_PORT", "invalid")
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "project.godot"), []byte("config_version=5\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if rc := runLaunch([]string{"--project", root, "--godot", "must-not-be-executed"}); rc != 2 {
		t.Fatalf("exit %d", rc)
	}
	if action, _ := decideLaunch(client.Status{Verdict: client.VerdictConfigError}); action != actionRefuse {
		t.Fatal("configuration failure allowed launch")
	}
	if _, err := os.Stat(filepath.Join(root, ".godot")); !os.IsNotExist(err) {
		t.Fatalf("launch wrote files: %v", err)
	}
	if _, err := newAddonSession(root); err == nil {
		t.Fatal("upgrade accepted invalid configuration")
	}
}
