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
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

type automationStep struct {
	Method    string                `json:"method"`
	Params    map[string]any        `json:"params,omitempty"`
	Expect    map[string]any        `json:"expect,omitempty"`
	Assert    []automationAssertion `json:"assert,omitempty"`
	Capture   map[string]string     `json:"capture,omitempty"`
	WaitUntil *automationWait       `json:"wait_until,omitempty"`

	refs []string // variables read by params and assert values, set at parse
}

// automationWait repeats a step's call until its checks pass or time runs out.
type automationWait struct {
	TimeoutMS  int `json:"timeout_ms"`
	IntervalMS int `json:"interval_ms"`
}

const (
	automationWaitMaxMS           = 600_000
	automationWaitMinIntervalMS   = 50
	automationWaitMaxIntervalMS   = 60_000
	automationWaitDefaultInterval = 500
)

// automationRetainedLimit caps what a report keeps across all steps; a var so
// tests can exercise the cap without 64 MiB of data.
var automationRetainedLimit = 64 << 20

type automationPlan struct {
	Steps []automationStep `json:"steps"`
}
type automationError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}
type automationResult struct {
	Index            int                          `json:"index"`
	Method           string                       `json:"method"`
	Status           string                       `json:"status"`
	DurationMS       int64                        `json:"duration_ms"`
	Attempts         int                          `json:"attempts,omitempty"`
	Result           json.RawMessage              `json:"result,omitempty"`
	Error            *automationError             `json:"error,omitempty"`
	FailedAssertions []automationAssertionFailure `json:"failed_assertions,omitempty"`
	Captures         map[string]any               `json:"captures,omitempty"`
	SkipReason       string                       `json:"skip_reason,omitempty"`
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
	capturedBy := map[string]int{}
	for i := range plan.Steps {
		step := &plan.Steps[i]
		if !automationMethod.MatchString(step.Method) {
			return plan, fmt.Errorf("step %d: invalid dotted method %q", i, step.Method)
		}
		for pointer := range step.Expect {
			if _, err := pointerParts(pointer); err != nil {
				return plan, fmt.Errorf("step %d: %w", i, err)
			}
		}
		for j := range step.Assert {
			if err := validateAssertion(&step.Assert[j]); err != nil {
				return plan, fmt.Errorf("step %d: assert %d: %w", i, j, err)
			}
		}
		if w := step.WaitUntil; w != nil {
			if w.TimeoutMS < 1 || w.TimeoutMS > automationWaitMaxMS {
				return plan, fmt.Errorf("step %d: wait_until timeout_ms must be 1 to %d", i, automationWaitMaxMS)
			}
			if w.IntervalMS == 0 {
				w.IntervalMS = automationWaitDefaultInterval
			}
			if w.IntervalMS < automationWaitMinIntervalMS || w.IntervalMS > automationWaitMaxIntervalMS {
				return plan, fmt.Errorf("step %d: wait_until interval_ms must be %d to %d", i, automationWaitMinIntervalMS, automationWaitMaxIntervalMS)
			}
			if len(step.Expect) == 0 && len(step.Assert) == 0 {
				return plan, fmt.Errorf("step %d: wait_until needs at least one expect or assert entry to wait for", i)
			}
		}
		refs := map[string]bool{}
		for _, v := range step.Params {
			if err := collectRefs(v, refs); err != nil {
				return plan, fmt.Errorf("step %d: params: %w", i, err)
			}
		}
		for j, a := range step.Assert {
			if err := collectRefs(a.value, refs); err != nil {
				return plan, fmt.Errorf("step %d: assert %d: %w", i, j, err)
			}
		}
		for _, name := range sortedKeys(refs) {
			if _, ok := capturedBy[name]; !ok {
				return plan, fmt.Errorf("step %d: variable %q is not captured by an earlier step", i, name)
			}
			step.refs = append(step.refs, name)
		}
		for _, name := range sortedKeys(step.Capture) {
			if !automationVarName.MatchString(name) {
				return plan, fmt.Errorf("step %d: capture name %q must match [A-Za-z_][A-Za-z0-9_]*", i, name)
			}
			if _, err := pointerParts(step.Capture[name]); err != nil {
				return plan, fmt.Errorf("step %d: capture %q: path %q must be a JSON pointer", i, name, step.Capture[name])
			}
			if first, ok := capturedBy[name]; ok {
				return plan, fmt.Errorf("step %d: variable %q is already captured by step %d", i, name, first)
			}
			capturedBy[name] = i
		}
	}
	return plan, nil
}

type automationCall func(context.Context, string, map[string]any) (json.RawMessage, error)

func newAutomationReport(plan automationPlan, dryRun bool) automationReport {
	report := automationReport{OK: true, DryRun: dryRun, Steps: make([]automationResult, len(plan.Steps))}
	for i, step := range plan.Steps {
		report.Steps[i] = automationResult{Index: i, Method: step.Method, Status: "skipped"}
	}
	return report
}

func executeAutomation(ctx context.Context, plan automationPlan, timeout time.Duration, keepGoing, dryRun bool, call automationCall) automationReport {
	report := newAutomationReport(plan, dryRun)
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
	vars := map[string]any{}
	// lostBy names the step whose capture never happened, for dependent skips.
	lostBy := map[string]int{}
	retainedBytes := 0
	for i, step := range plan.Steps {
		if ctx.Err() != nil {
			report.OK = false
			report.Error = automationFailure(ctx.Err())
			break
		}
		entry := &report.Steps[i]
		if name, ok := firstLostVariable(step.refs, vars); ok {
			// Under --continue-on-error a step never runs with an unresolved reference.
			entry.SkipReason = fmt.Sprintf("variable %q was not captured because step %d did not pass", name, lostBy[name])
			for captured := range step.Capture {
				lostBy[captured] = i
			}
			continue
		}
		start := time.Now()
		runAutomationStep(ctx, step, timeout, vars, call, entry)
		entry.DurationMS = time.Since(start).Milliseconds()
		if entry.Error == nil && len(step.Capture) > 0 {
			captureAutomationValues(step, vars, entry)
		}
		entry.Status = "passed"
		if entry.Error != nil {
			entry.Status = "failed"
			for captured := range step.Capture {
				lostBy[captured] = i
			}
		}
		// Count everything the report keeps for this step, not only the result.
		encoded, _ := json.Marshal(entry)
		retainedBytes += len(encoded)
		if retainedBytes > automationRetainedLimit {
			entry.Result, entry.FailedAssertions, entry.Captures = nil, nil, nil
			entry.Status = "failed"
			entry.Error = &automationError{Kind: "output", Message: "report results exceed 64 MiB; use file-saving command options for large captures", Data: map[string]any{"outcome": "response_received"}}
			report.OK = false
			break
		}
		if entry.Error != nil {
			report.OK = false
			// An uncertain transport outcome or cancellation always stops the plan.
			if !keepGoing || (entry.Error.Kind != "command" && entry.Error.Kind != "assertion") {
				break
			}
		}
	}
	return report
}

func firstLostVariable(refs []string, vars map[string]any) (string, bool) {
	for _, name := range refs {
		if _, ok := vars[name]; !ok {
			return name, true
		}
	}
	return "", false
}

// runAutomationStep makes the step's call, once or under wait_until, and
// fills the entry's result, error, failed assertions and attempt count.
func runAutomationStep(ctx context.Context, step automationStep, timeout time.Duration, vars map[string]any, call automationCall, entry *automationResult) {
	var params map[string]any
	if step.Params != nil {
		params = interpolate(step.Params, vars).(map[string]any)
	}
	checks := append(expectAssertions(step.Expect), step.Assert...)
	attempt := func() (bool, error) {
		stepCtx, cancel := context.WithTimeout(ctx, timeout)
		raw, err := call(stepCtx, step.Method, params)
		cancel()
		entry.Result, entry.Error, entry.FailedAssertions = raw, nil, nil
		if err != nil {
			entry.Error = automationFailure(err)
			return false, err
		}
		if len(checks) == 0 {
			return true, nil
		}
		var root any
		if err := json.Unmarshal(raw, &root); err != nil {
			entry.Error = &automationError{Kind: "assertion", Message: "result is not JSON: " + err.Error()}
			return false, nil
		}
		entry.FailedAssertions = evaluateAssertions(root, checks, vars)
		switch n := len(entry.FailedAssertions); {
		case n == 1:
			entry.Error = &automationError{Kind: "assertion", Message: entry.FailedAssertions[0].Message}
		case n > 1:
			entry.Error = &automationError{Kind: "assertion", Message: fmt.Sprintf("%d checks failed; first: %s", n, entry.FailedAssertions[0].Message)}
		}
		return entry.Error == nil, nil
	}
	if step.WaitUntil == nil {
		attempt()
		return
	}
	interval := time.Duration(step.WaitUntil.IntervalMS) * time.Millisecond
	start := time.Now()
	deadline := start.Add(time.Duration(step.WaitUntil.TimeoutMS) * time.Millisecond)
	for {
		entry.Attempts++
		passed, err := attempt()
		if passed || !waitRetryable(entry.Error, err) {
			return
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			last := entry.Error
			entry.Error = &automationError{
				Kind:    "assertion",
				Message: fmt.Sprintf("wait_until timed out after %d attempts in %d ms; last failure: %s", entry.Attempts, time.Since(start).Milliseconds(), last.Message),
				Data:    map[string]any{"last_failure": last, "timeout_ms": step.WaitUntil.TimeoutMS, "interval_ms": step.WaitUntil.IntervalMS},
			}
			return
		}
		timer := time.NewTimer(min(interval, remaining))
		select {
		case <-ctx.Done():
			timer.Stop()
			entry.Error = automationFailure(ctx.Err())
			entry.FailedAssertions = nil
			return
		case <-timer.C:
		}
	}
}

// waitRetryable decides whether a waiting step tries again. Assertion misses
// and command errors such as "node not found" can clear as the game runs; an
// unknown method or invalid params cannot, and transport loss always stops.
func waitRetryable(failure *automationError, err error) bool {
	if failure == nil {
		return false
	}
	if failure.Kind == "assertion" {
		return true
	}
	var rpc *protocol.Error
	if failure.Kind == "command" && errors.As(err, &rpc) {
		return rpc.Code != -32601 && rpc.Code != -32602
	}
	return false
}

// captureAutomationValues stores each named value from a passed step. The
// result is decoded with exact numbers so large integers such as instance
// IDs pass through to later params unchanged.
func captureAutomationValues(step automationStep, vars map[string]any, entry *automationResult) {
	d := json.NewDecoder(bytes.NewReader(entry.Result))
	d.UseNumber()
	var root any
	if err := d.Decode(&root); err != nil {
		entry.Error = &automationError{Kind: "assertion", Message: "capture needs a JSON result: " + err.Error()}
		return
	}
	captured := map[string]any{}
	names := sortedKeys(step.Capture)
	for _, name := range names {
		value, found := lookupPointer(root, step.Capture[name])
		if !found {
			entry.Error = &automationError{Kind: "assertion", Message: fmt.Sprintf("capture %q: result path %q is missing", name, step.Capture[name])}
			return
		}
		captured[name] = value
	}
	for _, name := range names {
		vars[name] = captured[name]
	}
	entry.Captures = captured
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
	reportPath := fs.String("report", "", "also write the JSON report to this file")
	junitPath := fs.String("junit", "", "write a JUnit XML report to this file")
	fs.Usage = subHelp(fs, "run a checked sequence of editor commands", []string{"swallowtail automate --file plan.json --project DIR [--report FILE] [--junit FILE]"},
		`Plans contain a steps array. Each step takes method and optional params, expect,
assert, capture and wait_until. All steps are parsed and checked against the
editor's method catalog before execution. Dry run checks structure and method
availability, not parameter validity or scene state.

expect maps JSON pointers to exact values, for example {"/valid":true}.
assert is a list of {path, op, value, tolerance}. op is eq, neq, gt, gte, lt,
lte, contains (substring, or an array element) or exists (value true or false).
tolerance applies to eq and neq on numbers. Comparing a non-number with gt, gte,
lt or lte fails the check.

capture maps a name to a JSON pointer, for example {"node":"/path"}, and runs
after the step passes. Later params and assert values use {{node}}: a string
that is exactly {{node}} takes the captured value and its type; inside longer
text the value is spliced in. A name must be captured by an earlier step. Under
--continue-on-error, a step whose variable was never captured is skipped.

wait_until {"timeout_ms":N,"interval_ms":M} repeats the call until its expect
and assert entries pass. timeout_ms is 1 to 600000; interval_ms is 50 to 60000,
default 500. Command errors other than unknown method or invalid params are
retried. A timeout fails the step as an assertion. --timeout still bounds each call.

Output is one JSON report with passed, failed, skipped, or validated steps.
--report writes the same document to a file; --junit writes JUnit XML with one
test case per step. Both files are written even when the run fails, including
setup failures that print nothing on stdout.
Exit 0 means all checks passed; 1 means execution/preflight failure; 2 means bad input.
Completed effects are not rolled back. Only wait_until repeats a call.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}
	if fs.NArg() != 0 || *file == "" || *timeout <= 0 {
		emitCLIError("usage", "automate requires --file and a positive --timeout, with no positional arguments", nil)
		return 2
	}
	if err := checkAutomationOutputs(*reportPath, *junitPath); err != nil {
		emitCLIError("usage", err.Error(), nil)
		return 2
	}
	var input io.Reader = os.Stdin
	suiteClass := "stdin"
	if *file != "-" {
		f, err := os.Open(*file)
		if err != nil {
			emitCLIError("usage", err.Error(), nil)
			return 2
		}
		defer f.Close()
		input = f
		suiteClass = strings.TrimSuffix(filepath.Base(*file), filepath.Ext(*file))
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
	outputs := automationOutputs{reportPath: *reportPath, junitPath: *junitPath, suiteClass: suiteClass, started: time.Now()}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	// Automation requires an affirmative project identity check, even with --port.
	checkCtx, cancel := context.WithTimeout(ctx, *timeout)
	answering, err := client.AnsweringProject(checkCtx, resolution.Port)
	cancel()
	if err != nil {
		cliRPCError(err)
		setup := newAutomationReport(plan, *dryRun)
		setup.OK, setup.Error = false, automationFailure(err)
		outputs.write(setup)
		return 1
	}
	if !client.SameProjectPath(answering, root) {
		message := "automation refused: the answering editor does not match the target project"
		data := map[string]any{"expected": root, "answering": answering}
		emitCLIError("project", message, data)
		setup := newAutomationReport(plan, *dryRun)
		setup.OK, setup.Error = false, &automationError{Kind: "project", Message: message, Data: data}
		outputs.write(setup)
		return 1
	}
	report := executeAutomation(ctx, plan, *timeout, *keepGoing, *dryRun, func(ctx context.Context, method string, params map[string]any) (json.RawMessage, error) {
		return client.Call(ctx, resolution.Port, method, params)
	})
	rc := 0
	if !report.OK {
		rc = 1
	}
	doc, err := encodeAutomationReport(report)
	if err == nil {
		_, err = os.Stdout.Write(doc)
	}
	if err != nil {
		emitCLIError("output", err.Error(), nil)
		rc = 1
	}
	if !outputs.write(report) {
		rc = 1
	}
	return rc
}
