package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

type automationStep struct {
	Method string         `json:"method"`
	Params map[string]any `json:"params,omitempty"`
	Expect map[string]any `json:"expect,omitempty"`
}

type automationPlan struct {
	Steps []automationStep `json:"steps"`
}
type automationError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}
type automationResult struct {
	Index      int              `json:"index"`
	Method     string           `json:"method"`
	Status     string           `json:"status"`
	DurationMS int64            `json:"duration_ms"`
	Result     json.RawMessage  `json:"result,omitempty"`
	Error      *automationError `json:"error,omitempty"`
}
type automationReport struct {
	OK     bool               `json:"ok"`
	DryRun bool               `json:"dry_run"`
	Steps  []automationResult `json:"steps"`
	Error  *automationError   `json:"error,omitempty"`
}

var automationMethod = regexp.MustCompile(`^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`)

func readAutomationPlan(r io.Reader) (automationPlan, error) {
	var plan automationPlan
	b, err := io.ReadAll(io.LimitReader(r, (4<<20)+1))
	if err != nil {
		return plan, err
	}
	if len(b) > 4<<20 {
		return plan, fmt.Errorf("automation file exceeds 4 MiB")
	}
	b = bytes.TrimPrefix(b, []byte{0xef, 0xbb, 0xbf})
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err := d.Decode(&plan); err != nil {
		return plan, err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return plan, fmt.Errorf("expected one JSON plan")
	}
	if len(plan.Steps) == 0 || len(plan.Steps) > 1000 {
		return plan, fmt.Errorf("plan must contain 1 to 1000 steps")
	}
	for i, step := range plan.Steps {
		if !automationMethod.MatchString(step.Method) {
			return plan, fmt.Errorf("step %d: invalid dotted method %q", i, step.Method)
		}
		for pointer := range step.Expect {
			if _, err := pointerParts(pointer); err != nil {
				return plan, fmt.Errorf("step %d: %w", i, err)
			}
		}
	}
	return plan, nil
}

func pointerParts(pointer string) ([]string, error) {
	if pointer == "" {
		return nil, nil
	}
	if !strings.HasPrefix(pointer, "/") {
		return nil, fmt.Errorf("expect key %q must be a JSON pointer (for example /valid)", pointer)
	}
	parts := strings.Split(pointer[1:], "/")
	for i, part := range parts {
		for j := 0; j < len(part); j++ {
			if part[j] == '~' {
				if j+1 >= len(part) || (part[j+1] != '0' && part[j+1] != '1') {
					return nil, fmt.Errorf("invalid JSON pointer %q", pointer)
				}
				j++
			}
		}
		parts[i] = strings.ReplaceAll(strings.ReplaceAll(part, "~1", "/"), "~0", "~")
	}
	return parts, nil
}

func checkAutomationExpect(raw json.RawMessage, expect map[string]any) error {
	if len(expect) == 0 {
		return nil
	}
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return err
	}
	for _, pointer := range sortedKeys(expect) {
		value := root
		parts, err := pointerParts(pointer)
		if err != nil {
			return err
		}
		for _, part := range parts {
			switch node := value.(type) {
			case map[string]any:
				var found bool
				value, found = node[part]
				if !found {
					return fmt.Errorf("expected result path %q is missing", pointer)
				}
			case []any:
				index, err := strconv.Atoi(part)
				if err != nil || index < 0 || index >= len(node) || strconv.Itoa(index) != part {
					return fmt.Errorf("invalid result array index at %q", pointer)
				}
				value = node[index]
			default:
				return fmt.Errorf("expected result path %q is missing", pointer)
			}
		}
		if !reflect.DeepEqual(value, expect[pointer]) {
			return fmt.Errorf("result at %q did not match the expected value", pointer)
		}
	}
	return nil
}

type automationCall func(context.Context, string, map[string]any) (json.RawMessage, error)

func executeAutomation(ctx context.Context, plan automationPlan, timeout time.Duration, keepGoing, dryRun bool, call automationCall) automationReport {
	report := automationReport{OK: true, DryRun: dryRun, Steps: make([]automationResult, len(plan.Steps))}
	for i, step := range plan.Steps {
		report.Steps[i] = automationResult{Index: i, Method: step.Method, Status: "skipped"}
	}
	// Check the entire live method catalog before the first user command runs.
	preCtx, cancel := context.WithTimeout(ctx, timeout)
	raw, err := call(preCtx, "engine.commands", nil)
	cancel()
	var catalog struct {
		Methods []string `json:"methods"`
	}
	if err == nil {
		err = json.Unmarshal(raw, &catalog)
	}
	if err == nil && len(catalog.Methods) == 0 {
		err = fmt.Errorf("editor returned an empty command catalog")
	}
	if err != nil {
		report.OK = false
		report.Error = automationFailure(err)
		return report
	}
	available := map[string]bool{}
	for _, method := range catalog.Methods {
		available[method] = true
	}
	for i, step := range plan.Steps {
		if !available[step.Method] {
			report.OK = false
			report.Error = &automationError{Kind: "preflight", Message: fmt.Sprintf("step %d: method %s is unavailable in this editor", i, step.Method)}
			return report
		}
	}
	if dryRun {
		for i := range report.Steps {
			report.Steps[i].Status = "validated"
		}
		return report
	}
	retainedBytes := 0
	for i, step := range plan.Steps {
		if ctx.Err() != nil {
			report.OK = false
			report.Error = automationFailure(ctx.Err())
			break
		}
		start := time.Now()
		stepCtx, cancel := context.WithTimeout(ctx, timeout)
		raw, err := call(stepCtx, step.Method, step.Params)
		cancel()
		entry := &report.Steps[i]
		entry.DurationMS = time.Since(start).Milliseconds()
		entry.Result = raw
		entry.Status = "passed"
		retainedBytes += len(raw)
		if err != nil {
			entry.Error = automationFailure(err)
		} else if err = checkAutomationExpect(raw, step.Expect); err != nil {
			entry.Error = &automationError{Kind: "assertion", Message: err.Error()}
		}
		if entry.Error != nil {
			encoded, _ := json.Marshal(entry.Error)
			retainedBytes += len(encoded)
		}
		if retainedBytes > 64<<20 {
			entry.Result = nil
			entry.Status = "failed"
			entry.Error = &automationError{Kind: "output", Message: "report results exceed 64 MiB; use file-saving command options for large captures", Data: map[string]any{"outcome": "response_received"}}
			report.OK = false
			break
		}
		if entry.Error != nil {
			entry.Status = "failed"
			report.OK = false
			// An uncertain transport outcome or cancellation always stops the plan.
			if !keepGoing || (entry.Error.Kind != "command" && entry.Error.Kind != "assertion") {
				break
			}
		}
	}
	return report
}

func automationFailure(err error) *automationError {
	var rpc *protocol.Error
	if errors.As(err, &rpc) {
		return &automationError{Kind: "command", Message: rpc.Message, Data: rpc}
	}
	kind, data := transportFailure(err)
	return &automationError{Kind: kind, Message: err.Error(), Data: data}
}

func runAutomate(args []string) int {
	fs := flag.NewFlagSet("automate", flag.ContinueOnError)
	file := fs.String("file", "", "JSON plan path, or - for stdin")
	project := fs.String("project", "", "target Godot project")
	port := fs.Int("port", 0, "editor WebSocket port")
	timeout := fs.Duration("timeout", 30*time.Second, "timeout for each call, including preflight")
	dryRun := fs.Bool("dry-run", false, "validate plan structure and live method availability without executing its steps")
	keepGoing := fs.Bool("continue-on-error", false, "continue after command/assertion failures; transport failures always stop")
	fs.Usage = subHelp(fs, "run a checked sequence of editor commands", []string{"swallowtail automate --file plan.json --project DIR"},
		`Plans contain a steps array of {method, params, expect}. expect maps JSON pointers
to exact expected result values, for example {"/valid":true}. All steps are parsed
and checked against the editor's method catalog before execution. Dry run checks
structure and method availability, not parameter validity or scene state.
Output is one JSON report with passed, failed, skipped, or validated steps.
Exit 0 means all checks passed; 1 means execution/preflight failure; 2 means bad input.
Calls execute once in order. Completed effects are not rolled back. No automatic retries.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}
	if fs.NArg() != 0 || *file == "" || *timeout <= 0 {
		emitCLIError("usage", "automate requires --file and a positive --timeout, with no positional arguments", nil)
		return 2
	}
	var input io.Reader = os.Stdin
	if *file != "-" {
		f, err := os.Open(*file)
		if err != nil {
			emitCLIError("usage", err.Error(), nil)
			return 2
		}
		defer f.Close()
		input = f
	}
	plan, err := readAutomationPlan(input)
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		return 2
	}
	root, err := projectRootFor(*project)
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		return 2
	}
	resolution := client.ResolvePortSource(*port, root)
	if resolution.Err != nil {
		emitCLIError("usage", resolution.Err.Error(), nil)
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	// Automation requires an affirmative project identity check, even with --port.
	checkCtx, cancel := context.WithTimeout(ctx, *timeout)
	answering, err := client.AnsweringProject(checkCtx, resolution.Port)
	cancel()
	if err != nil {
		cliRPCError(err)
		return 1
	}
	if !client.SameProjectPath(answering, root) {
		emitCLIError("project", "automation refused: the answering editor does not match the target project", map[string]any{"expected": root, "answering": answering})
		return 1
	}
	report := executeAutomation(ctx, plan, *timeout, *keepGoing, *dryRun, func(ctx context.Context, method string, params map[string]any) (json.RawMessage, error) {
		return client.Call(ctx, resolution.Port, method, params)
	})
	if err := json.NewEncoder(os.Stdout).Encode(report); err != nil {
		emitCLIError("output", err.Error(), nil)
		return 1
	}
	if !report.OK {
		return 1
	}
	return 0
}
