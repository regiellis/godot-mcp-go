package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"regexp"
	"strconv"
	"strings"
)

// automationAssertion is one entry of a step's assert array. Value keeps its
// raw bytes so a missing value and an explicit null stay distinct.
type automationAssertion struct {
	Path      string          `json:"path"`
	Op        string          `json:"op"`
	Value     json.RawMessage `json:"value"`
	Tolerance *float64        `json:"tolerance,omitempty"`

	value      any
	fromExpect bool
}

// automationAssertionFailure is the report record for one failed check.
// Actual is always present; Missing says the path was absent rather than null.
type automationAssertionFailure struct {
	Path      string   `json:"path"`
	Op        string   `json:"op"`
	Expected  any      `json:"expected"`
	Tolerance *float64 `json:"tolerance,omitempty"`
	Actual    any      `json:"actual"`
	Missing   bool     `json:"missing,omitempty"`
	Message   string   `json:"message"`
}

var (
	automationOps     = map[string]bool{"eq": true, "neq": true, "gt": true, "gte": true, "lt": true, "lte": true, "contains": true, "exists": true}
	automationVarName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	automationRef     = regexp.MustCompile(`\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}`)
	automationExact   = regexp.MustCompile(`^\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}$`)
	// A padded name such as {{ id }} is almost always a typo for {{id}}; refuse it
	// rather than send the braces through as literal text.
	automationLooseRef = regexp.MustCompile(`\{\{\s*[A-Za-z_][A-Za-z0-9_]*\s*\}\}`)
)

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

// lookupPointer resolves a validated pointer. An out-of-range or non-numeric
// array index counts as missing.
func lookupPointer(root any, pointer string) (any, bool) {
	parts, err := pointerParts(pointer)
	if err != nil {
		return nil, false
	}
	value := root
	for _, part := range parts {
		switch node := value.(type) {
		case map[string]any:
			var found bool
			if value, found = node[part]; !found {
				return nil, false
			}
		case []any:
			index, err := strconv.Atoi(part)
			if err != nil || index < 0 || index >= len(node) || strconv.Itoa(index) != part {
				return nil, false
			}
			value = node[index]
		default:
			return nil, false
		}
	}
	return value, true
}

// validateAssertion checks one assertion at parse time. Values that are an
// exact {{name}} reference are typed at run time instead.
func validateAssertion(a *automationAssertion) error {
	if !automationOps[a.Op] {
		return fmt.Errorf("unknown op %q (use eq, neq, gt, gte, lt, lte, contains, or exists)", a.Op)
	}
	if _, err := pointerParts(a.Path); err != nil {
		return fmt.Errorf("path %q must be a JSON pointer (for example /valid)", a.Path)
	}
	if len(a.Value) == 0 {
		return fmt.Errorf("op %s needs a value", a.Op)
	}
	if err := json.Unmarshal(a.Value, &a.value); err != nil {
		return fmt.Errorf("value: %w", err)
	}
	isRef := false
	if s, ok := a.value.(string); ok {
		isRef = automationExact.MatchString(s)
	}
	_, isNumber := a.value.(float64)
	switch a.Op {
	case "exists":
		if _, ok := a.value.(bool); !ok {
			return fmt.Errorf("op exists needs a boolean value (true for present, false for absent)")
		}
	case "gt", "gte", "lt", "lte":
		if !isNumber && !isRef {
			return fmt.Errorf("op %s needs a number value", a.Op)
		}
	}
	if a.Tolerance != nil {
		if a.Op != "eq" && a.Op != "neq" {
			return fmt.Errorf("tolerance applies only to eq and neq, not %s", a.Op)
		}
		if math.IsNaN(*a.Tolerance) || math.IsInf(*a.Tolerance, 0) || *a.Tolerance < 0 {
			return fmt.Errorf("tolerance must be a finite number of 0 or more")
		}
		if !isNumber && !isRef {
			return fmt.Errorf("tolerance needs a number value")
		}
	}
	return nil
}

// collectRefs adds every {{name}} found in string values anywhere inside v.
func collectRefs(v any, into map[string]bool) error {
	switch x := v.(type) {
	case string:
		for _, loose := range automationLooseRef.FindAllString(x, -1) {
			if !automationRef.MatchString(loose) {
				return fmt.Errorf("variable reference %q has spaces; write it as {{%s}}", loose, strings.TrimSpace(loose[2:len(loose)-2]))
			}
		}
		for _, m := range automationRef.FindAllStringSubmatch(x, -1) {
			into[m[1]] = true
		}
	case map[string]any:
		for _, item := range x {
			if err := collectRefs(item, into); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range x {
			if err := collectRefs(item, into); err != nil {
				return err
			}
		}
	}
	return nil
}

// interpolate returns a copy of v with references replaced. A string that is
// exactly one reference takes the captured value with its JSON type; a
// reference inside a longer string is spliced in as text.
func interpolate(v any, vars map[string]any) any {
	switch x := v.(type) {
	case string:
		if m := automationExact.FindStringSubmatch(x); m != nil {
			return vars[m[1]]
		}
		return automationRef.ReplaceAllStringFunc(x, func(ref string) string {
			value := vars[ref[2:len(ref)-2]]
			if s, ok := value.(string); ok {
				return s
			}
			return compactJSON(value)
		})
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, item := range x {
			out[k] = interpolate(item, vars)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, item := range x {
			out[i] = interpolate(item, vars)
		}
		return out
	}
	return v
}

func compactJSON(v any) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	_ = e.Encode(v)
	return strings.TrimSuffix(b.String(), "\n")
}

// normalizeNumbers turns json.Number (exact captures) into float64 so values
// compare the way decoded results do.
func normalizeNumbers(v any) any {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return x.String()
		}
		return f
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, item := range x {
			out[k] = normalizeNumbers(item)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, item := range x {
			out[i] = normalizeNumbers(item)
		}
		return out
	}
	return v
}

func jsonTypeName(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "a boolean"
	case float64, json.Number:
		return "a number"
	case string:
		return "a string"
	case []any:
		return "an array"
	case map[string]any:
		return "an object"
	}
	return fmt.Sprintf("%T", v)
}

func shortJSON(v any) string {
	s := compactJSON(v)
	if len(s) > 120 {
		s = s[:117] + "..."
	}
	return s
}

// expectAssertions turns the expect shorthand into eq assertions, in pointer
// order, keeping expect's original failure wording.
func expectAssertions(expect map[string]any) []automationAssertion {
	out := make([]automationAssertion, 0, len(expect))
	for _, pointer := range sortedKeys(expect) {
		out = append(out, automationAssertion{Path: pointer, Op: "eq", value: expect[pointer], fromExpect: true})
	}
	return out
}

// evaluateAssertions runs every check against a decoded result and returns
// all failures, so the report names each one instead of the first.
func evaluateAssertions(root any, checks []automationAssertion, vars map[string]any) []automationAssertionFailure {
	var failures []automationAssertionFailure
	for _, a := range checks {
		expected := a.value
		if !a.fromExpect {
			expected = normalizeNumbers(interpolate(a.value, vars))
		}
		actual, found := lookupPointer(root, a.Path)
		if msg := assertionMessage(a, expected, actual, found); msg != "" {
			failures = append(failures, automationAssertionFailure{Path: a.Path, Op: a.Op, Expected: expected, Tolerance: a.Tolerance, Actual: actual, Missing: !found, Message: msg})
		}
	}
	return failures
}

// assertionMessage returns "" on a pass, or why the check failed.
func assertionMessage(a automationAssertion, expected, actual any, found bool) string {
	at := fmt.Sprintf("result at %q", a.Path)
	if a.Op == "exists" {
		want := expected.(bool)
		switch {
		case want && !found:
			return fmt.Sprintf("result path %q is missing", a.Path)
		case !want && found:
			return fmt.Sprintf("result path %q exists, expected it to be absent", a.Path)
		}
		return ""
	}
	if !found {
		if a.fromExpect {
			return fmt.Sprintf("expected result path %q is missing", a.Path)
		}
		return fmt.Sprintf("result path %q is missing", a.Path)
	}
	switch a.Op {
	case "eq", "neq":
		equal := reflect.DeepEqual(actual, expected)
		if a.Tolerance != nil {
			want, wantOK := expected.(float64)
			got, gotOK := actual.(float64)
			if !wantOK {
				return fmt.Sprintf("op %s with a tolerance needs a number value, got %s", a.Op, jsonTypeName(expected))
			}
			if !gotOK {
				return fmt.Sprintf("%s is %s, not a number, so %s within a tolerance cannot compare it", at, jsonTypeName(actual), a.Op)
			}
			equal = math.Abs(got-want) <= *a.Tolerance
		}
		if a.Op == "eq" && !equal {
			if a.fromExpect {
				return fmt.Sprintf("%s did not match the expected value", at)
			}
			if a.Tolerance != nil {
				return fmt.Sprintf("%s is %s, expected %s within %s", at, shortJSON(actual), shortJSON(expected), shortJSON(*a.Tolerance))
			}
			return fmt.Sprintf("%s is %s, expected %s", at, shortJSON(actual), shortJSON(expected))
		}
		if a.Op == "neq" && equal {
			return fmt.Sprintf("%s is %s, expected any other value", at, shortJSON(actual))
		}
	case "gt", "gte", "lt", "lte":
		want, wantOK := expected.(float64)
		got, gotOK := actual.(float64)
		if !wantOK {
			return fmt.Sprintf("op %s needs a number value, got %s", a.Op, jsonTypeName(expected))
		}
		if !gotOK {
			return fmt.Sprintf("%s is %s, not a number, so %s cannot compare it", at, jsonTypeName(actual), a.Op)
		}
		pass := map[string]bool{"gt": got > want, "gte": got >= want, "lt": got < want, "lte": got <= want}[a.Op]
		symbol := map[string]string{"gt": ">", "gte": ">=", "lt": "<", "lte": "<="}[a.Op]
		if !pass {
			return fmt.Sprintf("%s is %s, expected %s %s", at, shortJSON(actual), symbol, shortJSON(expected))
		}
	case "contains":
		switch got := actual.(type) {
		case string:
			want, ok := expected.(string)
			if !ok {
				return fmt.Sprintf("%s is a string, so contains needs a string value, got %s", at, jsonTypeName(expected))
			}
			if !strings.Contains(got, want) {
				return fmt.Sprintf("%s does not contain %s", at, shortJSON(want))
			}
		case []any:
			for _, item := range got {
				if reflect.DeepEqual(item, expected) {
					return ""
				}
			}
			return fmt.Sprintf("%s has no element equal to %s", at, shortJSON(expected))
		default:
			return fmt.Sprintf("%s is %s; contains needs a string or an array", at, jsonTypeName(actual))
		}
	}
	return ""
}

// checkAutomationExpect keeps the expect shorthand callable on its own.
func checkAutomationExpect(raw json.RawMessage, expect map[string]any) error {
	if len(expect) == 0 {
		return nil
	}
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return err
	}
	if failures := evaluateAssertions(root, expectAssertions(expect), nil); len(failures) > 0 {
		return fmt.Errorf("%s", failures[0].Message)
	}
	return nil
}
