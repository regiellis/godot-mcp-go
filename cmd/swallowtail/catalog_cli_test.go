package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestCatalogRefusesOtherEditorAndPreservesOwnOfflineHelp(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	_ = os.WriteFile(filepath.Join(root, "project.godot"), []byte("config_version=5"), 0600)
	other := t.TempDir()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		var req rpcMsg
		if wsjson.Read(r.Context(), c, &req) != nil {
			return
		}
		var result any = map[string]any{"methods": []string{"other.secret"}, "docs": map[string]any{}}
		if req.Method == "project.info" {
			result = map[string]any{"project_path": other}
		}
		_ = wsjson.Write(context.Background(), c, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
	}))
	defer server.Close()
	port, _ := strconv.Atoi(strings.TrimPrefix(server.URL, "http://127.0.0.1:"))
	_, _, err := loadCLICatalog(context.Background(), port, false)
	if !errors.Is(err, errCatalogOwner) {
		t.Fatal(err)
	}
	if _, err = os.Stat(catalogPath(root)); !os.IsNotExist(err) {
		t.Fatal("cached another project's catalog")
	}
	saveCLICatalog(root, cliCatalog{Project: root, Port: 9081, Saved: time.Now(), Methods: []string{"own.ping"}, Docs: map[string]commandDoc{}})
	c, cached, err := loadCLICatalog(context.Background(), port, false)
	if err != nil || !cached || c.Methods[0] != "own.ping" {
		t.Fatal(c, cached, err)
	}
	_, _, err = loadCLICatalog(context.Background(), port, true)
	if !errors.Is(err, errCatalogOwner) {
		t.Fatal("explicit port borrowed unrelated cache", err)
	}
	raw, _ := json.Marshal(c)
	if strings.Contains(string(raw), "other.secret") {
		t.Fatal(string(raw))
	}
}
