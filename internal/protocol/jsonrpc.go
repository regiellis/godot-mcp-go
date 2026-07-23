// Package protocol defines the JSON-RPC 2.0 envelope spoken between the Go
// client and the Godot editor addon over WebSocket. See CLAUDE.md "Protocol".
package protocol

import "encoding/json"

// Version is the only JSON-RPC version we speak.
const Version = "2.0"

// Request is a host -> addon call. Method is dotted: "<group>.<command>".
type Request struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      int            `json:"id"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
}

// NewRequest builds a Request with the protocol version pre-filled.
func NewRequest(id int, method string, params map[string]any) Request {
	return Request{JSONRPC: Version, ID: id, Method: method, Params: params}
}

// Response is an addon -> host reply. Exactly one of Result/Error is set.
// ID is a json.Number because Godot's JSON.stringify re-emits integer ids as
// floats ("1.0"); comparing as a Number tolerates either form.
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.Number     `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// IDEquals reports whether the response id matches the given integer request
// id, accepting both "1" and "1.0" encodings.
func (r Response) IDEquals(id int) bool {
	if f, err := r.ID.Float64(); err == nil {
		return f == float64(id)
	}
	return false
}

// Error is the JSON-RPC error object. Codes mirror the addon's base_command
// (e.g. -32601 method not found, -32602 invalid params, -32000 no scene).
type Error struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *Error) Error() string { return e.Message }
