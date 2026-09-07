package client

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestLostResponseHasUnknownOutcomeAndNoReplay(t *testing.T) {
	var received atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		var req json.RawMessage
		if wsjson.Read(r.Context(), conn, &req) == nil {
			received.Add(1)
		}
		// Simulate the server completing a mutation then losing the connection.
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(u.Port())
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := Call(ctx, port, "scene.save", nil)
	var call *CallError
	if !errors.As(err, &call) || call.Method != "scene.save" || call.Stage != "read response" || received.Load() != 1 {
		t.Fatalf("%v, calls=%d", err, received.Load())
	}
}
