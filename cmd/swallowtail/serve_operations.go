package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"math"
	"sync"
)

type activeCall struct {
	id       json.RawMessage
	ctx      context.Context
	cancel   context.CancelFunc
	method   string
	token    json.RawMessage
	progress float64
}

func (s *mcpServer) requestContext() context.Context {
	if s.operationContext != nil {
		return s.operationContext
	}
	return context.Background()
}

// Keep editor requests ordered while the reader remains available for pings
// and cancellation. The queue is bounded; disconnect cancels queued and active
// calls. Only the worker touches catalog state or operationContext.
func (s *mcpServer) serve(input io.Reader) {
	type job struct {
		line []byte
		id   string
		call *activeCall
	}
	queue := make(chan job, 64)
	var worker sync.WaitGroup
	worker.Add(1)
	go func() {
		defer worker.Done()
		for j := range queue {
			s.operationContext = j.call.ctx
			if j.call.ctx.Err() == nil {
				if j.call.method == "tools/call" {
					s.forwardProgress(j.call.id, json.RawMessage(`{"progress":0,"message":"Running Godot operation"}`))
				}
				s.handle(j.line)
			}
			j.call.cancel()
			s.callsMu.Lock()
			delete(s.calls, j.id)
			s.callsMu.Unlock()
		}
	}()
	reader := bufio.NewReaderSize(input, 16*1024*1024)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			var msg rpcMsg
			if json.Unmarshal(line, &msg) == nil {
				switch msg.Method {
				case "notifications/cancelled":
					s.cancelRequest(msg.Params)
				case "ping":
					s.reply(msg.ID, map[string]any{}, nil)
				default:
					ctx, cancel := context.WithCancel(context.Background())
					call := &activeCall{id: msg.ID, ctx: ctx, cancel: cancel, method: msg.Method, progress: -1}
					var p struct {
						Meta struct {
							Token json.RawMessage `json:"progressToken"`
						} `json:"_meta"`
					}
					if json.Unmarshal(msg.Params, &p) == nil && validProgressToken(p.Meta.Token) {
						call.token = p.Meta.Token
					}
					id := requestKey(msg.ID)
					s.callsMu.Lock()
					if s.calls == nil {
						s.calls = make(map[string]*activeCall)
					}
					_, duplicate := s.calls[id]
					if !duplicate {
						s.calls[id] = call
					}
					s.callsMu.Unlock()
					if duplicate {
						cancel()
						logf("ignored duplicate active request id")
						break
					}
					select {
					case queue <- job{line, id, call}:
					default:
						s.reply(msg.ID, nil, &rpcErr{Code: -32000, Message: "Request queue is full"})
						cancel()
						s.callsMu.Lock()
						delete(s.calls, id)
						s.callsMu.Unlock()
					}
				}
			} else {
				logf("invalid JSON request")
			}
		}
		if err != nil {
			if err != io.EOF {
				logf("stdin read error: %v", err)
			}
			break
		}
	}
	s.callsMu.Lock()
	for _, call := range s.calls {
		call.cancel()
	}
	s.callsMu.Unlock()
	close(queue)
	worker.Wait()
}

func validProgressToken(raw json.RawMessage) bool {
	var token any
	if json.Unmarshal(raw, &token) != nil {
		return false
	}
	switch v := token.(type) {
	case string:
		return true
	case float64:
		return math.Trunc(v) == v
	}
	return false
}

func (s *mcpServer) cancelRequest(raw json.RawMessage) {
	var p struct {
		ID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(raw, &p) != nil || !validProgressToken(p.ID) {
		return
	}
	s.callsMu.Lock()
	defer s.callsMu.Unlock()
	if call := s.calls[requestKey(p.ID)]; call != nil && call.method != "initialize" {
		call.cancel()
	}
}

func (s *mcpServer) forwardProgress(id json.RawMessage, raw json.RawMessage) {
	var p struct {
		Progress float64  `json:"progress"`
		Total    *float64 `json:"total,omitempty"`
		Message  string   `json:"message,omitempty"`
	}
	if json.Unmarshal(raw, &p) != nil {
		return
	}
	s.callsMu.Lock()
	defer s.callsMu.Unlock()
	call := s.calls[requestKey(id)]
	if call == nil || call.ctx.Err() != nil || call.token == nil || p.Progress <= call.progress {
		return
	}
	if p.Total != nil && (*p.Total < p.Progress || *p.Total < 0) {
		return
	}
	call.progress = p.Progress
	params := map[string]any{"progressToken": call.token, "progress": p.Progress, "message": p.Message}
	if p.Total != nil {
		params["total"] = *p.Total
	}
	b, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "notifications/progress", "params": params})
	if err == nil {
		s.writeFrame(b)
	}
}

// Decode string ids so equivalent JSON escapes match without conflating numeric ids.
func requestKey(raw json.RawMessage) string {
	var value string
	if json.Unmarshal(raw, &value) == nil && len(raw) > 0 && raw[0] == '"' {
		return "string:" + value
	}
	return string(raw)
}
