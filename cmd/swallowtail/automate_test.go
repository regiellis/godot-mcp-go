package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

func TestAutomationRejectsMalformedPlans(t *testing.T) {
	for _, input := range []string{
		`{"steps":[]}`, `{"steps":[{"method":"node.set","param":{}}]}`,
		`{"steps":[{"method":"node.set"},{"method":"bad"}]}`,
		`{"steps":[{"method":"node.set","params":[]}]}`,
		`{"steps":[{"method":"scene.tree","expect":{"valid":true}}]}`,
		`{"steps":[{"method":"scene.tree","expect":{"/~2":true}}]}`,
		`{"steps":[{"method":"scene.tree"}]} {}`,
	} {
		if _, err := readAutomationPlan(strings.NewReader(input)); err == nil {
			t.Errorf("accepted %s", input)
		}
	}
}

func TestAutomationPreflightDoesNotPartiallyExecute(t *testing.T) {
	var calls []string
	plan := automationPlan{Steps: []automationStep{{Method: "node.set"}, {Method: "missing.method"}}}
	r := executeAutomation(context.Background(), plan, time.Second, false, false, func(_ context.Context, m string, _ map[string]any) (json.RawMessage, error) {
		calls = append(calls, m)
		return json.RawMessage(`{"methods":["node.set"]}`), nil
	})
	if r.OK || r.Error.Kind != "preflight" || !reflect.DeepEqual(calls, []string{"engine.commands"}) {
		t.Fatal(r, calls)
	}
	for _, step := range r.Steps {
		if step.Status != "skipped" {
			t.Fatal(step)
		}
	}
}

func TestAutomationStopsAndReportsFailures(t *testing.T) {
	for _, tc := range []struct {
		name      string
		err       error
		keep      bool
		wantCalls int
		kind      string
	}{
		{"command stops", &protocol.Error{Code: -32000, Message: "No scene"}, false, 1, "command"},
		{"command continues", &protocol.Error{Code: -32000, Message: "No scene"}, true, 2, "command"},
		{"timeout never continues", &client.CallError{Method: "node.set", Stage: "read response", Err: context.DeadlineExceeded}, true, 1, "timeout"},
		{"disconnect never continues", &client.CallError{Method: "node.set", Stage: "read response", Err: errors.New("closed")}, true, 1, "transport"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			plan := automationPlan{Steps: []automationStep{{Method: "node.set"}, {Method: "node.set"}}}
			r := executeAutomation(context.Background(), plan, time.Second, tc.keep, false, func(_ context.Context, m string, _ map[string]any) (json.RawMessage, error) {
				if m == "engine.commands" {
					return json.RawMessage(`{"methods":["node.set"]}`), nil
				}
				calls++
				if calls == 1 {
					return nil, tc.err
				}
				return json.RawMessage(`{"ok":true}`), nil
			})
			if r.OK || calls != tc.wantCalls || r.Steps[0].Error.Kind != tc.kind {
				t.Fatal(r, calls)
			}
		})
	}
}

func TestAutomationAssertionsAndDryRun(t *testing.T) {
	plan, err := readAutomationPlan(strings.NewReader(`{"steps":[{"method":"scene.validate","expect":{"/valid":true}},{"method":"scene.save"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, dry := range []bool{false, true} {
		calls := 0
		r := executeAutomation(context.Background(), plan, time.Second, false, dry, func(_ context.Context, m string, _ map[string]any) (json.RawMessage, error) {
			if m == "engine.commands" {
				return json.RawMessage(`{"methods":["scene.validate","scene.save"]}`), nil
			}
			calls++
			return json.RawMessage(`{"valid":false}`), nil
		})
		if dry {
			if !r.OK || calls != 0 || r.Steps[0].Status != "validated" {
				t.Fatal(r, calls)
			}
		} else {
			if r.OK || calls != 1 || r.Steps[0].Error.Kind != "assertion" || r.Steps[1].Status != "skipped" {
				t.Fatal(r, calls)
			}
		}
	}
	if err := checkAutomationExpect(json.RawMessage(`{"a/b":{"~key":[null,2]}}`), map[string]any{"/a~1b/~0key/0": nil, "/a~1b/~0key/1": float64(2)}); err != nil {
		t.Fatal(err)
	}
	if err := checkAutomationExpect(json.RawMessage(`{}`), map[string]any{"/missing": nil}); err == nil {
		t.Fatal("missing path matched null")
	}
}

func TestTransportFailureOutcomes(t *testing.T) {
	for _, tc := range []struct {
		err           error
		kind, outcome string
	}{
		{&client.DialError{Port: 9080, Err: errors.New("refused")}, "transport", "not_sent"},
		{&client.CallError{Method: "scene.save", Stage: "read response", Err: context.DeadlineExceeded}, "timeout", "unknown"},
		{&client.CallError{Method: "scene.save", Stage: "read response", Err: context.Canceled}, "cancelled", "unknown"},
	} {
		kind, data := transportFailure(tc.err)
		if kind != tc.kind || data["outcome"] != tc.outcome {
			t.Fatal(kind, data)
		}
	}
}
