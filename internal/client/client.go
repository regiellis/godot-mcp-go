// Package client dials the Godot editor addon's WebSocket server and performs
// a single JSON-RPC request/response. The addon is the server; the CLI is a
// short-lived client (see CLAUDE.md "Protocol").
package client

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/bynine/godot-mcp-go/internal/protocol"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// DialError marks a failure to reach the addon's WebSocket server (as opposed to
// a protocol.Error from a reachable server). Callers detect it with errors.As to
// run Diagnose and tell a crash from a deliberate close.
type DialError struct {
	Port int
	Err  error
}

func (e *DialError) Error() string {
	return fmt.Sprintf("dial ws://127.0.0.1:%d: %v", e.Port, e.Err)
}

func (e *DialError) Unwrap() error { return e.Err }

// Call connects to 127.0.0.1:port, sends one request, and returns the matching
// response's raw result. Control/heartbeat and mismatched-id frames are skipped.
func Call(ctx context.Context, port int, method string, params map[string]any) (json.RawMessage, error) {
	url := fmt.Sprintf("ws://127.0.0.1:%d", port)
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		return nil, &DialError{Port: port, Err: err}
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(64 << 20) // 64MB — responses (screenshots, trees) exceed the 32KB default

	const id = 1
	req := protocol.NewRequest(id, method, params)
	if err := wsjson.Write(ctx, conn, req); err != nil {
		return nil, fmt.Errorf("write request: %w", err)
	}

	for {
		var resp protocol.Response
		if err := wsjson.Read(ctx, conn, &resp); err != nil {
			return nil, fmt.Errorf("read response: %w", err)
		}
		if !resp.IDEquals(id) {
			continue // heartbeat or a frame meant for another in-flight call
		}
		if resp.Error != nil {
			return nil, resp.Error
		}
		return resp.Result, nil
	}
}
