package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestServeCancellationAndProgress(t *testing.T) {
	closed := make(chan struct{})
	brokenClosed := make(chan struct{})
	called := make(chan string, 4)
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
		called <- req.Method
		if req.Method == "test.broken" {
			conn.Read(r.Context())
			close(brokenClosed)
			return
		}
		if req.Method == "test.slow" {
			wsjson.Write(r.Context(), conn, map[string]any{"jsonrpc": "2.0", "method": "godot/progress", "params": map[string]any{"progress": 1, "total": 3}})
			conn.Read(r.Context())
			close(closed)
			return
		}
		wsjson.Write(r.Context(), conn, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"ok": true}})
	}))
	defer backend.Close()
	port, _ := strconv.Atoi(strings.TrimPrefix(backend.URL, "http://127.0.0.1:"))
	in, send := io.Pipe()
	out, output := io.Pipe()
	defer send.Close()
	defer out.Close()
	s := &mcpServer{flagPort: port, timeout: time.Minute, out: bufio.NewWriter(output)}
	done := make(chan struct{})
	go func() { s.serve(in); output.Close(); close(done) }()
	messages := make(chan rpcMsg, 20)
	go func() {
		dec := json.NewDecoder(out)
		for {
			var msg rpcMsg
			if dec.Decode(&msg) != nil {
				return
			}
			messages <- msg
		}
	}()
	write := func(line string) {
		t.Helper()
		if _, err := io.WriteString(send, line+"\n"); err != nil {
			t.Fatal(err)
		}
	}
	next := func() rpcMsg {
		t.Helper()
		select {
		case m := <-messages:
			return m
		case <-time.After(4 * time.Second):
			t.Fatal("stdio response stalled")
			return rpcMsg{}
		}
	}
	write(`{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"godot_run","arguments":{"method":"test.slow"},"_meta":{"progressToken":0}}}`)
	for want := 0; want < 2; want++ {
		m := next()
		var p struct {
			Progress      int
			ProgressToken int
		}
		json.Unmarshal(m.Params, &p)
		if m.Method != "notifications/progress" || p.Progress != want || p.ProgressToken != 0 {
			t.Fatalf("bad progress: %+v", m)
		}
	}
	write(`{"method":"notifications/cancelled","params":{"requestId":1}}`) // numeric != string
	write(`{"id":"ping","method":"ping"}`)
	if string(next().ID) != `"ping"` {
		t.Fatal("ping blocked")
	}
	select {
	case <-closed:
		t.Fatal("wrong id cancelled request")
	default:
	}
	write(`{"id":"queued","method":"tools/call","params":{"name":"godot_run","arguments":{"method":"test.never"}}}`)
	write(`{"method":"notifications/cancelled","params":{"requestId":"queued"}}`)
	write(`{"method":"notifications/cancelled","params":{"requestId":"1"}}`)
	select {
	case <-closed:
	case <-time.After(4 * time.Second):
		t.Fatal("backend connection not cancelled")
	}
	write(`{"id":"fast","method":"tools/call","params":{"name":"godot_run","arguments":{"method":"test.fast"}}}`)
	if string(next().ID) != `"fast"` {
		t.Fatal("cancelled request responded or worker stuck")
	}
	if <-called != "test.slow" || <-called != "test.fast" {
		t.Fatal("cancelled queued call executed")
	}
	write(`{"method":"notifications/cancelled","params":{"requestId":"fast"}}`)
	write(`{"method":"notifications/cancelled","params":{"requestId":{}}}`)
	write(`{"id":99,"method":"ping"}`)
	if string(next().ID) != "99" {
		t.Fatal("late cancellation broke transport")
	}
	// A broken transport, unlike a clean EOF, cannot deliver an answer, so the
	// in-flight call is cancelled rather than drained.
	write(`{"id":"broken","method":"tools/call","params":{"name":"godot_run","arguments":{"method":"test.broken"}}}`)
	select {
	case method := <-called:
		if method != "test.broken" {
			t.Fatal(method)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("read-error probe did not start")
	}
	send.CloseWithError(errors.New("stdin transport failure"))
	select {
	case <-brokenClosed:
	case <-time.After(4 * time.Second):
		t.Fatal("read error left backend running")
	}
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("read error did not shut down")
	}
}

func TestCancellationIDsAndInitialization(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	call := &activeCall{ctx: ctx, cancel: cancel, method: "initialize"}
	s := &mcpServer{calls: map[string]*activeCall{requestKey(json.RawMessage(`"a"`)): call}}
	s.cancelRequest(json.RawMessage(`{"requestId":"a"}`))
	if ctx.Err() != nil {
		t.Fatal("initialize was cancelled")
	}
	call.method = "tools/call"
	s.cancelRequest(json.RawMessage(`{"requestId":"\u0061"}`))
	if ctx.Err() == nil {
		t.Fatal("equivalent escaped string id did not cancel")
	}
}

func TestProgressTokenTypes(t *testing.T) {
	for raw, want := range map[string]bool{`0`: true, `""`: true, `"token"`: true, `null`: false, `true`: false, `{}`: false, `1.5`: false} {
		if validProgressToken(json.RawMessage(raw)) != want {
			t.Errorf("token %s", raw)
		}
	}
}

// A batch client that writes its requests and closes stdin still gets every
// answer: EOF drains the queue instead of cancelling it.
func TestServeDrainsQueuedRequestsOnEOF(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close() // no editor answers, so tools/list degrades to godot_run alone
	var output bytes.Buffer
	s := &mcpServer{flagPort: port, cwd: t.TempDir(), timeout: 5 * time.Second, typed: true, out: bufio.NewWriter(&output)}
	input := strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}` + "\n" +
		`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n" +
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}` + "\n")
	done := make(chan struct{})
	go func() { s.serve(input); close(done) }()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("serve did not return after EOF")
	}
	answered := map[float64]bool{}
	var tools []struct {
		Name string `json:"name"`
	}
	dec := json.NewDecoder(bytes.NewReader(output.Bytes()))
	for {
		var msg struct {
			ID     *float64 `json:"id"`
			Result struct {
				Tools []struct {
					Name string `json:"name"`
				} `json:"tools"`
			} `json:"result"`
		}
		if dec.Decode(&msg) != nil {
			break
		}
		if msg.ID == nil {
			continue
		}
		answered[*msg.ID] = true
		if *msg.ID == 2 {
			tools = msg.Result.Tools
		}
	}
	if !answered[1] || !answered[2] {
		t.Fatalf("EOF dropped queued responses: %s", output.String())
	}
	if len(tools) != 1 || tools[0].Name != "godot_run" {
		t.Fatalf("tools/list without an editor: %v", tools)
	}
}
