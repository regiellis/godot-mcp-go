package protocol

import (
	"encoding/json"
	"testing"
)

func TestRequestRoundTrip(t *testing.T) {
	req := NewRequest(1, "project.info", map[string]any{"path": "res://"})
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var got Request
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.JSONRPC != Version || got.ID != 1 || got.Method != "project.info" {
		t.Fatalf("round trip mismatch: %+v", got)
	}
}

func TestResponseError(t *testing.T) {
	raw := `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found: x"}}`
	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error == nil || resp.Error.Code != -32601 {
		t.Fatalf("expected error -32601, got %+v", resp.Error)
	}
	if resp.Result != nil {
		t.Fatalf("expected nil result, got %s", resp.Result)
	}
}
