package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

// fakeEditor answers engine.commands with methods and routes every other call
// to handle, recording the params each call received.
type fakeEditor struct {
	methods []string
	handle  func(n int, method string, params map[string]any) (json.RawMessage, error)
	calls   []string
	params  []map[string]any
}

func (f *fakeEditor) call(_ context.Context, method string, params map[string]any) (json.RawMessage, error) {
	if method == "engine.commands" {
		b, _ := json.Marshal(map[string]any{"methods": f.methods})
		return b, nil
	}
	f.calls = append(f.calls, method)
	f.params = append(f.params, params)
	return f.handle(len(f.calls), method, params)
}

func mustPlan(t *testing.T, src string) automationPlan {
	t.Helper()
	plan, err := readAutomationPlan(strings.NewReader(src))
	if err != nil {
		t.Fatalf("plan refused: %v\n%s", err, src)
	}
	return plan
}

func TestAutomationPlanRefusesBadChecksAndVariables(t *testing.T) {
	step := func(extra string) string { return `{"method":"node.get"` + extra + `}` }
	for _, tc := range []struct{ plan, want string }{
		{`{"steps":[` + step(`,"params":{"a":"{{id}}"}`) + `]}`, `variable "id" is not captured by an earlier step`},
		{`{"steps":[` + step(`,"capture":{"id":"/id"},"params":{"a":"{{id}}"}`) + `]}`, `variable "id" is not captured`},
		{`{"steps":[` + step(`,"params":{"a":["x {{id}}"]}`) + `,` + step(`,"capture":{"id":"/id"}`) + `]}`, `step 0: variable "id"`},
		{`{"steps":[` + step(`,"capture":{"id":"/id"}`) + `,` + step(`,"params":{"a":"{{ id }}"}`) + `]}`, `has spaces`},
		{`{"steps":[` + step(`,"capture":{"id":"/id"}`) + `,` + step(`,"capture":{"id":"/x"}`) + `]}`, `already captured by step 0`},
		{`{"steps":[` + step(`,"capture":{"1x":"/id"}`) + `]}`, `capture name "1x"`},
		{`{"steps":[` + step(`,"capture":{"id":"id"}`) + `]}`, `must be a JSON pointer`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"equals","value":1}]`) + `]}`, `unknown op "equals"`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"eq"}]`) + `]}`, `op eq needs a value`},
		{`{"steps":[` + step(`,"assert":[{"path":"a","op":"eq","value":1}]`) + `]}`, `must be a JSON pointer`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"gt","value":1,"tolerance":0.1}]`) + `]}`, `tolerance applies only to eq and neq`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"eq","value":1,"tolerance":-1}]`) + `]}`, `finite number of 0 or more`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"eq","value":"x","tolerance":1}]`) + `]}`, `tolerance needs a number value`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"lt","value":"5"}]`) + `]}`, `op lt needs a number value`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"exists","value":1}]`) + `]}`, `needs a boolean value`},
		{`{"steps":[` + step(`,"assert":[{"path":"/a","op":"eq","value":1,"why":1}]`) + `]}`, `unknown field`},
		{`{"steps":[` + step(`,"wait_until":{"timeout_ms":1000}`) + `]}`, `needs at least one expect or assert`},
		{`{"steps":[` + step(`,"expect":{"/a":1},"wait_until":{"timeout_ms":0}`) + `]}`, `timeout_ms must be 1 to 600000`},
		{`{"steps":[` + step(`,"expect":{"/a":1},"wait_until":{"timeout_ms":600001}`) + `]}`, `timeout_ms must be 1 to 600000`},
		{`{"steps":[` + step(`,"expect":{"/a":1},"wait_until":{"timeout_ms":1000,"interval_ms":10}`) + `]}`, `interval_ms must be 50 to 60000`},
		{`{"steps":[` + step(`,"expect":{"/a":1},"wait_until":{"timeout_ms":1.5}`) + `]}`, `cannot unmarshal`},
		{`{"steps":[` + step(`,"expect":{"/a":1},"wait_until":{"timeout_ms":100,"every":1}`) + `]}`, `unknown field`},
	} {
		_, err := readAutomationPlan(strings.NewReader(tc.plan))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("plan %s\n got %v, want %q", tc.plan, err, tc.want)
		}
	}
	// A literal brace pair that is not a reference passes through untouched.
	mustPlan(t, `{"steps":[{"method":"editor.run_script","params":{"code":"var d = {{}: 1}"}}]}`)
}

func TestAutomationCaptureKeepsTypesAndInterpolates(t *testing.T) {
	plan := mustPlan(t, `{"steps":[
		{"method":"node.find","capture":{"path":"/path","count":"/count","id":"/id","obj":"/obj","flag":"/flag"}},
		{"method":"node.get","params":{"node_path":"{{path}}","n":"{{count}}","id":"{{id}}","on":"{{flag}}",
			"label":"n={{count}} at {{path}} <{{obj}}>","nested":{"list":["{{obj}}","plain"]}},
			"assert":[{"path":"/echo","op":"eq","value":"{{path}}"},{"path":"/size","op":"gt","value":"{{count}}"}]}
	]}`)
	f := &fakeEditor{methods: []string{"node.find", "node.get"}, handle: func(n int, _ string, _ map[string]any) (json.RawMessage, error) {
		if n == 1 {
			return json.RawMessage(`{"path":"/root/Main","count":3,"id":9007199254740993,"obj":{"k":"v"},"flag":true}`), nil
		}
		return json.RawMessage(`{"echo":"/root/Main","size":4}`), nil
	}}
	r := executeAutomation(context.Background(), plan, time.Second, false, false, f.call)
	if !r.OK {
		t.Fatalf("%+v", r)
	}
	got := compactJSON(f.params[1])
	want := `{"id":9007199254740993,"label":"n=3 at /root/Main <{\"k\":\"v\"}>","n":3,"nested":{"list":[{"k":"v"},"plain"]},"node_path":"/root/Main","on":true}`
	if got != want {
		t.Fatalf("params\n got %s\nwant %s", got, want)
	}
	captures, _ := json.Marshal(r.Steps[0].Captures)
	if string(captures) != `{"count":3,"flag":true,"id":9007199254740993,"obj":{"k":"v"},"path":"/root/Main"}` {
		t.Fatal(string(captures))
	}
	// The plan's own params are never rewritten in place.
	if plan.Steps[1].Params["node_path"] != "{{path}}" {
		t.Fatal(plan.Steps[1].Params)
	}
}

func assertionFrom(t *testing.T, src string) automationAssertion {
	t.Helper()
	var a automationAssertion
	if err := json.Unmarshal([]byte(src), &a); err != nil {
		t.Fatal(err)
	}
	if err := validateAssertion(&a); err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	return a
}

func TestAutomationAssertionOperators(t *testing.T) {
	var root any
	_ = json.Unmarshal([]byte(`{"n":1.05,"s":"Hello world","list":[1,{"name":"Player"}],"obj":{"a":1},"nil":null,"zero":0}`), &root)
	vars := map[string]any{"min": json.Number("1"), "word": "world", "who": map[string]any{"name": "Player"}}
	for _, tc := range []struct {
		assertion string
		want      string // "" means pass; otherwise a substring of the message
	}{
		{`{"path":"/n","op":"eq","value":1.05}`, ""},
		{`{"path":"/n","op":"eq","value":1}`, `is 1.05, expected 1`},
		{`{"path":"/n","op":"eq","value":1,"tolerance":0.1}`, ""},
		{`{"path":"/n","op":"eq","value":1,"tolerance":0.01}`, `expected 1 within 0.01`},
		{`{"path":"/s","op":"eq","value":1,"tolerance":0.1}`, `is a string, not a number`},
		{`{"path":"/n","op":"neq","value":1,"tolerance":0.01}`, ""},
		{`{"path":"/n","op":"neq","value":1,"tolerance":0.1}`, `expected any other value`},
		{`{"path":"/s","op":"neq","value":"Hello"}`, ""},
		{`{"path":"/nil","op":"eq","value":null}`, ""},
		{`{"path":"/gone","op":"eq","value":null}`, `result path "/gone" is missing`},
		{`{"path":"/n","op":"gt","value":1}`, ""},
		{`{"path":"/n","op":"gt","value":2}`, `expected > 2`},
		{`{"path":"/n","op":"gte","value":1.05}`, ""},
		{`{"path":"/zero","op":"gte","value":1}`, `expected >= 1`},
		{`{"path":"/n","op":"lt","value":2}`, ""},
		{`{"path":"/n","op":"lt","value":1}`, `expected < 1`},
		{`{"path":"/n","op":"lte","value":1.05}`, ""},
		{`{"path":"/n","op":"lte","value":0}`, `expected <= 0`},
		{`{"path":"/s","op":"gt","value":1}`, `is a string, not a number, so gt cannot compare it`},
		{`{"path":"/nil","op":"lt","value":1}`, `is null, not a number`},
		{`{"path":"/n","op":"gt","value":"{{min}}"}`, ""},
		{`{"path":"/n","op":"gt","value":"{{word}}"}`, `op gt needs a number value, got a string`},
		{`{"path":"/s","op":"contains","value":"world"}`, ""},
		{`{"path":"/s","op":"contains","value":"{{word}}"}`, ""},
		{`{"path":"/s","op":"contains","value":"World"}`, `does not contain "World"`},
		{`{"path":"/s","op":"contains","value":1}`, `contains needs a string value`},
		{`{"path":"/list","op":"contains","value":{"name":"Player"}}`, ""},
		{`{"path":"/list","op":"contains","value":"{{who}}"}`, ""},
		{`{"path":"/list","op":"contains","value":2}`, `has no element equal to 2`},
		{`{"path":"/obj","op":"contains","value":"a"}`, `is an object; contains needs a string or an array`},
		{`{"path":"/obj","op":"exists","value":true}`, ""},
		{`{"path":"/nil","op":"exists","value":true}`, ""},
		{`{"path":"/gone","op":"exists","value":true}`, `is missing`},
		{`{"path":"/gone","op":"exists","value":false}`, ""},
		{`{"path":"/list/5","op":"exists","value":false}`, ""},
		{`{"path":"/obj","op":"exists","value":false}`, `exists, expected it to be absent`},
		{`{"path":"","op":"exists","value":true}`, ""},
	} {
		a := assertionFrom(t, tc.assertion)
		failures := evaluateAssertions(root, []automationAssertion{a}, vars)
		switch {
		case tc.want == "" && len(failures) != 0:
			t.Errorf("%s failed: %s", tc.assertion, failures[0].Message)
		case tc.want != "" && (len(failures) != 1 || !strings.Contains(failures[0].Message, tc.want)):
			t.Errorf("%s: got %+v, want message containing %q", tc.assertion, failures, tc.want)
		}
	}
	// A failure record says whether the path was missing or present as null.
	missing := evaluateAssertions(root, []automationAssertion{assertionFrom(t, `{"path":"/gone","op":"eq","value":null}`)}, nil)[0]
	present := evaluateAssertions(root, []automationAssertion{assertionFrom(t, `{"path":"/nil","op":"eq","value":1}`)}, nil)[0]
	if !missing.Missing || present.Missing || present.Actual != nil || present.Expected != float64(1) {
		t.Fatalf("%+v %+v", missing, present)
	}
	b, _ := json.Marshal(present)
	if !bytes.Contains(b, []byte(`"actual":null`)) {
		t.Fatal(string(b))
	}
}

func TestAutomationReportsEveryFailedAssertion(t *testing.T) {
	plan := mustPlan(t, `{"steps":[{"method":"scene.tree","expect":{"/valid":true},"assert":[{"path":"/count","op":"gte","value":2},{"path":"/name","op":"contains","value":"Main"}]}]}`)
	f := &fakeEditor{methods: []string{"scene.tree"}, handle: func(int, string, map[string]any) (json.RawMessage, error) {
		return json.RawMessage(`{"valid":false,"count":1,"name":"Main"}`), nil
	}}
	r := executeAutomation(context.Background(), plan, time.Second, false, false, f.call)
	s := r.Steps[0]
	if r.OK || s.Error.Kind != "assertion" || len(s.FailedAssertions) != 2 || !strings.HasPrefix(s.Error.Message, "2 checks failed; first: result at \"/valid\" did not match") {
		t.Fatalf("%+v", s)
	}
	if s.FailedAssertions[0].Op != "eq" || s.FailedAssertions[1].Op != "gte" || s.FailedAssertions[1].Actual != float64(1) {
		t.Fatalf("%+v", s.FailedAssertions)
	}
}

func TestAutomationWaitUntil(t *testing.T) {
	waitPlan := func(timeoutMS int) automationPlan {
		return mustPlan(t, `{"steps":[{"method":"runtime.get","expect":{"/ready":true},"wait_until":{"timeout_ms":`+strconv.Itoa(timeoutMS)+`,"interval_ms":50}},{"method":"scene.save"}]}`)
	}
	methods := []string{"runtime.get", "scene.save"}

	t.Run("passes after three attempts", func(t *testing.T) {
		f := &fakeEditor{methods: methods, handle: func(n int, m string, _ map[string]any) (json.RawMessage, error) {
			if m == "runtime.get" && n < 3 {
				return json.RawMessage(`{"ready":false}`), nil
			}
			return json.RawMessage(`{"ready":true}`), nil
		}}
		r := executeAutomation(context.Background(), waitPlan(5000), time.Second, false, false, f.call)
		if !r.OK || r.Steps[0].Attempts != 3 || r.Steps[0].Status != "passed" || r.Steps[0].FailedAssertions != nil || r.Steps[1].Attempts != 0 {
			t.Fatalf("%+v", r)
		}
	})
	t.Run("times out as an assertion", func(t *testing.T) {
		f := &fakeEditor{methods: methods, handle: func(int, string, map[string]any) (json.RawMessage, error) {
			return json.RawMessage(`{"ready":false}`), nil
		}}
		start := time.Now()
		r := executeAutomation(context.Background(), waitPlan(200), time.Second, false, false, f.call)
		s := r.Steps[0]
		if r.OK || s.Error.Kind != "assertion" || s.Attempts < 3 || !strings.Contains(s.Error.Message, "wait_until timed out after") || len(s.FailedAssertions) != 1 || r.Steps[1].Status != "skipped" {
			t.Fatalf("%+v", s)
		}
		data := s.Error.Data.(map[string]any)
		if data["last_failure"].(*automationError).Message != `result at "/ready" did not match the expected value` || time.Since(start) > 2*time.Second {
			t.Fatalf("%+v", data)
		}
	})
	t.Run("retries a not-found command error", func(t *testing.T) {
		f := &fakeEditor{methods: methods, handle: func(n int, _ string, _ map[string]any) (json.RawMessage, error) {
			if n == 1 {
				return nil, &protocol.Error{Code: -32001, Message: "Node not found"}
			}
			return json.RawMessage(`{"ready":true}`), nil
		}}
		r := executeAutomation(context.Background(), waitPlan(5000), time.Second, false, false, f.call)
		if !r.OK || r.Steps[0].Attempts != 2 {
			t.Fatalf("%+v", r)
		}
	})
	t.Run("never retries invalid params or transport loss", func(t *testing.T) {
		for _, failure := range []error{
			&protocol.Error{Code: -32602, Message: "Unknown param"},
			&client.CallError{Method: "runtime.get", Stage: "read response", Err: context.DeadlineExceeded},
		} {
			f := &fakeEditor{methods: methods, handle: func(int, string, map[string]any) (json.RawMessage, error) { return nil, failure }}
			r := executeAutomation(context.Background(), waitPlan(5000), time.Second, false, false, f.call)
			if r.OK || r.Steps[0].Attempts != 1 || len(f.calls) != 1 {
				t.Fatalf("%+v %v", r.Steps[0], f.calls)
			}
		}
	})
	t.Run("cancellation stops promptly", func(t *testing.T) {
		plan := mustPlan(t, `{"steps":[{"method":"runtime.get","expect":{"/ready":true},"wait_until":{"timeout_ms":60000,"interval_ms":30000}},{"method":"scene.save"}]}`)
		f := &fakeEditor{methods: methods, handle: func(int, string, map[string]any) (json.RawMessage, error) {
			return json.RawMessage(`{"ready":false}`), nil
		}}
		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(100*time.Millisecond, cancel)
		start := time.Now()
		r := executeAutomation(ctx, plan, time.Second, true, false, f.call)
		if time.Since(start) > 2*time.Second || r.OK || r.Steps[0].Error.Kind != "cancelled" || r.Steps[0].Attempts != 1 || r.Steps[1].Status != "skipped" || len(f.calls) != 1 {
			t.Fatalf("%+v", r)
		}
	})
}

func TestAutomationContinueOnErrorSkipsDependents(t *testing.T) {
	plan := mustPlan(t, `{"steps":[
		{"method":"node.find","capture":{"id":"/id"},"expect":{"/ok":true}},
		{"method":"node.get","params":{"id":"{{id}}"},"capture":{"name":"/name"}},
		{"method":"node.set","params":{"label":"for {{name}}"}},
		{"method":"scene.save"},
		{"method":"node.find","capture":{"other":"/missing"}},
		{"method":"node.get","params":{"id":"{{other}}"}}
	]}`)
	f := &fakeEditor{methods: []string{"node.find", "node.get", "node.set", "scene.save"}, handle: func(int, string, map[string]any) (json.RawMessage, error) {
		return json.RawMessage(`{"ok":false,"id":7}`), nil
	}}
	r := executeAutomation(context.Background(), plan, time.Second, true, false, f.call)
	statuses := []string{}
	for _, s := range r.Steps {
		statuses = append(statuses, s.Status)
	}
	if r.OK || strings.Join(statuses, ",") != "failed,skipped,skipped,passed,failed,skipped" {
		t.Fatalf("%v %+v", statuses, r)
	}
	if strings.Join(f.calls, ",") != "node.find,scene.save,node.find" {
		t.Fatalf("a step ran with an unresolved variable: %v", f.calls)
	}
	if r.Steps[0].Captures != nil || r.Steps[1].SkipReason != `variable "id" was not captured because step 0 did not pass` ||
		r.Steps[2].SkipReason != `variable "name" was not captured because step 1 did not pass` ||
		r.Steps[4].Error.Message != `capture "other": result path "/missing" is missing` || r.Steps[4].Error.Kind != "assertion" ||
		!strings.Contains(r.Steps[5].SkipReason, "step 4") {
		t.Fatalf("%+v", r.Steps)
	}
}

func TestAutomationRetainedLimitCountsAssertionData(t *testing.T) {
	saved := automationRetainedLimit
	automationRetainedLimit = 4096
	defer func() { automationRetainedLimit = saved }()
	plan := mustPlan(t, `{"steps":[{"method":"scene.tree","assert":[{"path":"/s","op":"eq","value":"short"}]},{"method":"scene.tree","assert":[{"path":"/s","op":"eq","value":"short"}]}]}`)
	// Each result is under half the limit, so only the failure records (which
	// repeat the actual value) can push the run over it.
	big, _ := json.Marshal(map[string]string{"s": strings.Repeat("x", 1200)})
	f := &fakeEditor{methods: []string{"scene.tree"}, handle: func(int, string, map[string]any) (json.RawMessage, error) { return big, nil }}
	r := executeAutomation(context.Background(), plan, time.Second, true, false, f.call)
	if r.OK || r.Steps[1].Error.Kind != "output" || r.Steps[1].Result != nil || r.Steps[1].FailedAssertions != nil {
		t.Fatalf("%+v", r.Steps)
	}
}

func TestAutomationJUnitAndReportFiles(t *testing.T) {
	plan := mustPlan(t, `{"steps":[
		{"method":"scene.tree","capture":{"root":"/root"}},
		{"method":"node.get","params":{"path":"{{root}}"},"assert":[{"path":"/count","op":"gt","value":5}]},
		{"method":"node.set"},
		{"method":"scene.save"}
	]}`)
	f := &fakeEditor{methods: []string{"scene.tree", "node.get", "node.set", "scene.save"}, handle: func(n int, m string, _ map[string]any) (json.RawMessage, error) {
		switch m {
		case "node.set":
			return nil, &protocol.Error{Code: -32001, Message: "Node not found"}
		case "scene.save":
			return nil, &client.CallError{Method: m, Stage: "read response", Err: context.DeadlineExceeded}
		}
		return json.RawMessage(`{"root":"Main","count":2}`), nil
	}}
	r := executeAutomation(context.Background(), plan, time.Second, true, false, f.call)
	dir := t.TempDir()
	out := automationOutputs{reportPath: filepath.Join(dir, "report.json"), junitPath: filepath.Join(dir, "junit.xml"), suiteClass: "smoke", started: time.Now()}
	if !out.write(r) {
		t.Fatal("write failed")
	}
	want, _ := encodeAutomationReport(r)
	if got, _ := os.ReadFile(out.reportPath); !bytes.Equal(got, want) {
		t.Fatalf("report file differs from stdout document:\n%s", got)
	}
	suite := readJUnit(t, out.junitPath)
	if suite.Name != "swallowtail.automate" || suite.Tests != 4 || suite.Failures != 1 || suite.Errors != 2 || suite.Skipped != 0 {
		t.Fatalf("%+v", suite)
	}
	c := suite.Cases
	if c[0].Name != "00 scene.tree" || c[0].Classname != "smoke" || c[0].Failure != nil || c[0].Error != nil || c[0].Skipped != nil {
		t.Fatalf("%+v", c[0])
	}
	if c[1].Failure == nil || c[1].Failure.Type != "assertion" || !strings.Contains(c[1].Failure.Body, `"failed_assertions"`) || !strings.Contains(c[1].Failure.Message, "expected > 5") {
		t.Fatalf("%+v", c[1])
	}
	if c[2].Error == nil || c[2].Error.Type != "command" || c[3].Error == nil || c[3].Error.Type != "timeout" {
		t.Fatalf("%+v %+v", c[2], c[3])
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("temporary files left behind: %v", entries)
	}
}

func readJUnit(t *testing.T, path string) junitSuite {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(b, []byte(xml.Header)) {
		t.Fatal("missing XML header")
	}
	var doc junitSuites
	if err := xml.Unmarshal(b, &doc); err != nil {
		t.Fatal(err, string(b))
	}
	if len(doc.Suites) != 1 || doc.Tests != doc.Suites[0].Tests || doc.Failures != doc.Suites[0].Failures || doc.Errors != doc.Suites[0].Errors {
		t.Fatalf("%+v", doc)
	}
	return doc.Suites[0]
}

func TestAutomationFilesOnPreflightFailureAndSkips(t *testing.T) {
	plan := mustPlan(t, `{"steps":[{"method":"node.set"},{"method":"missing.method"}]}`)
	f := &fakeEditor{methods: []string{"node.set"}}
	r := executeAutomation(context.Background(), plan, time.Second, false, false, f.call)
	dir := t.TempDir()
	out := automationOutputs{reportPath: filepath.Join(dir, "r.json"), junitPath: filepath.Join(dir, "j.xml"), suiteClass: "stdin", started: time.Now()}
	if !out.write(r) {
		t.Fatal("write failed")
	}
	suite := readJUnit(t, out.junitPath)
	if suite.Tests != 3 || suite.Skipped != 2 || suite.Errors != 1 || suite.Cases[2].Name != "plan" || suite.Cases[2].Error.Type != "preflight" ||
		!strings.Contains(suite.Cases[2].Error.Message, "missing.method is unavailable") || !strings.Contains(suite.SystemErr, "preflight") ||
		suite.Cases[0].Skipped.Message != "not run: the plan stopped before this step" {
		t.Fatalf("%+v", suite)
	}
	var report automationReport
	b, _ := os.ReadFile(out.reportPath)
	if err := json.Unmarshal(b, &report); err != nil || report.OK || report.Error.Kind != "preflight" {
		t.Fatal(err, string(b))
	}

	// A dry run records validated steps as passing test cases.
	dry := executeAutomation(context.Background(), mustPlan(t, `{"steps":[{"method":"node.set"}]}`), time.Second, false, true, f.call)
	b, _ = automationJUnit(dry, "plan", time.Now(), 0)
	var doc junitSuites
	if err := xml.Unmarshal(b, &doc); err != nil || doc.Tests != 1 || doc.Suites[0].Cases[0].SystemOut == "" || doc.Suites[0].Cases[0].Skipped != nil {
		t.Fatal(err, string(b))
	}
}

func TestWriteFileAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out.xml")
	for _, content := range []string{"first", "second"} {
		if err := writeFileAtomic(path, []byte(content)); err != nil {
			t.Fatal(err)
		}
		if got, _ := os.ReadFile(path); string(got) != content {
			t.Fatal(string(got))
		}
	}
	// Renaming onto a directory fails; the temp file must not survive.
	blocked := filepath.Join(dir, "blocked")
	_ = os.Mkdir(blocked, 0o755)
	_ = os.WriteFile(filepath.Join(blocked, "keep"), []byte("x"), 0o644)
	if err := writeFileAtomic(blocked, []byte("data")); err == nil {
		t.Fatal("wrote over a directory")
	}
	if err := writeFileAtomic(filepath.Join(dir, "absent", "x.json"), nil); err == nil {
		t.Fatal("wrote into a missing directory")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("temporary files left behind: %v", entries)
	}
	out := automationOutputs{junitPath: blocked, started: time.Now()}
	if out.write(automationReport{OK: true}) {
		t.Fatal("reported success for a failed write")
	}
}

func TestAutomationOutputPathsChecked(t *testing.T) {
	dir := t.TempDir()
	same := filepath.Join(dir, "r.json")
	for _, paths := range [][]string{{same, same}, {filepath.Join(dir, "missing", "r.json"), ""}, {dir, ""}} {
		if err := checkAutomationOutputs(paths...); err == nil {
			t.Errorf("accepted %v", paths)
		}
	}
	if err := checkAutomationOutputs(same, filepath.Join(dir, "j.xml")); err != nil {
		t.Fatal(err)
	}
}
