package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/bynine/godot-mcp-go/internal/client"
	"os"
	"sort"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/protocol"
)

var cliErrorFormat = "text"

// emitCLIError keeps structured stderr separate from successful stdout.
func emitCLIError(kind, message string, data any) {
	if cliErrorFormat == "json" {
		_ = json.NewEncoder(os.Stderr).Encode(map[string]any{"error": map[string]any{
			"kind": kind, "message": message, "data": data,
		}})
		return
	}
	fmt.Fprintln(os.Stderr, "error:", message)
}

func cliRPCError(err error) {
	var rpc *protocol.Error
	if !errors.As(err, &rpc) {
		kind, data := transportFailure(err)
		emitCLIError(kind, err.Error(), data)
		if cliErrorFormat != "json" {
			fmt.Fprintln(os.Stderr, data["action"])
		}
		return
	}
	if cliErrorFormat == "json" {
		emitCLIError("command", rpc.Message, rpc)
		return
	}
	fmt.Fprintf(os.Stderr, "error [%d]: %s\n", rpc.Code, rpc.Message)
	if rpc.Code == -32601 {
		method := strings.TrimPrefix(rpc.Message, "Method not found: ")
		var methods []string
		b, _ := json.Marshal(rpc.Data["available_methods"])
		_ = json.Unmarshal(b, &methods)
		if choices := commandSuggestions(method, methods); len(choices) > 0 {
			fmt.Fprintln(os.Stderr, "Try:", strings.Join(choices, ", "))
		}
		group, _, _ := strings.Cut(method, ".")
		fmt.Fprintf(os.Stderr, "Help: swallowtail %s --help\n", group)
		return
	}
	if rpc.Code == -32602 {
		b, _ := json.Marshal(rpc.Data["unknown_params"])
		var unknown []string
		_ = json.Unmarshal(b, &unknown)
		for _, key := range unknown {
			switch key {
			case "format", "port", "timeout", "errors", "project", "params_file":
				fmt.Fprintf(os.Stderr, "--%s is also a CLI flag. Put CLI flags before the group: swallowtail --%s VALUE <group> <command>\n", key, key)
			}
		}
	}
	if len(rpc.Data) > 0 {
		b, _ := json.MarshalIndent(rpc.Data, "", "  ")
		fmt.Fprintln(os.Stderr, string(b))
	}
}

func transportFailure(err error) (string, map[string]any) {
	kind := "transport"
	if errors.Is(err, context.DeadlineExceeded) {
		kind = "timeout"
	}
	if errors.Is(err, context.Canceled) {
		kind = "cancelled"
	}
	data := map[string]any{"outcome": "unknown", "action": "Inspect the editor state before repeating a mutation. A missing response does not prove the command failed."}
	var call *client.CallError
	if errors.As(err, &call) {
		data["method"] = call.Method
		data["stage"] = call.Stage
	}
	var dial *client.DialError
	if errors.As(err, &dial) {
		data["outcome"] = "not_sent"
		data["port"] = dial.Port
		data["action"] = "Run swallowtail doctor --json for this project, then check that its editor and Swallowtail addon are running."
	}
	return kind, data
}

func commandSuggestions(want string, methods []string) []string {
	type choice struct {
		name     string
		distance int
	}
	var choices []choice
	for _, m := range methods {
		d := editDistance(want, m)
		if d <= 3 {
			choices = append(choices, choice{m, d})
		}
	}
	sort.Slice(choices, func(i, j int) bool {
		if choices[i].distance == choices[j].distance {
			return choices[i].name < choices[j].name
		}
		return choices[i].distance < choices[j].distance
	})
	var out []string
	for _, c := range choices[:min(3, len(choices))] {
		out = append(out, "swallowtail "+strings.ReplaceAll(strings.ReplaceAll(c.name, ".", " "), "_", "-"))
	}
	return out
}

func editDistance(a, b string) int {
	x, y := []rune(a), []rune(b)
	row := make([]int, len(y)+1)
	for j := range row {
		row[j] = j
	}
	for i, c := range x {
		prev := row[0]
		row[0] = i + 1
		for j, d := range y {
			old := row[j+1]
			cost := 0
			if c != d {
				cost = 1
			}
			row[j+1] = min(row[j]+1, row[j+1]+1, prev+cost)
			prev = old
		}
	}
	return row[len(y)]
}
