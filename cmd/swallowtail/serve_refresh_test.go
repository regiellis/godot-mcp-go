package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestTypedCatalogRefresh(t *testing.T) {
	var catalog atomic.Value
	catalog.Store(`{"docs":{"scene.old":{"description":"old"}}}`)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		var req rpcMsg
		if wsjson.Read(r.Context(), conn, &req) != nil {
			return
		}
		wsjson.Write(context.Background(), conn, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": json.RawMessage(catalog.Load().(string))})
	}))
	defer backend.Close()
	port, _ := strconv.Atoi(strings.TrimPrefix(backend.URL, "http://127.0.0.1:"))
	var output bytes.Buffer
	s := &mcpServer{typed: true, flagPort: port, out: bufio.NewWriter(&output)}
	s.refreshTypedTools()
	if s.nameToMethod["scene_old"] != "scene.old" {
		t.Fatal("initial catalog missing")
	}
	output.Reset()
	s.refreshTypedTools()
	if output.Len() != 0 {
		t.Fatal("unchanged catalog notified")
	}
	catalog.Store(`{"docs":{"scene.new":{"description":"new","params":[{"name":"path","type":"String","required":true}]}}}`)
	s.refreshTypedTools()
	if len(s.nameToMethod) != 1 || s.nameToMethod["scene_new"] != "scene.new" || !strings.Contains(output.String(), "notifications/tools/list_changed") {
		t.Fatal("replacement catalog not published")
	}
	catalog.Store(`{"docs":{}}`)
	s.refreshTypedTools()
	if s.typedFetched || len(s.typedTools) != 0 || len(s.nameToMethod) != 0 {
		t.Fatal("stale catalog survived invalid docs")
	}
	catalog.Store(`{"docs":{"scene.recovered":{"description":"recovered"}}}`)
	s.refreshTypedTools()
	if s.nameToMethod["scene_recovered"] != "scene.recovered" {
		t.Fatal("catalog did not recover")
	}
	backend.Close()
	s.refreshTypedTools()
	if len(s.typedTools) != 0 {
		t.Fatal("stale catalog survived editor shutdown")
	}
}
