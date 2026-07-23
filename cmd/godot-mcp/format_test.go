package main

import (
	"encoding/json"
	"testing"
)

func TestFormatTSV(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Rule 1: array of objects → sorted-union header + one row per element,
		// missing keys become empty cells.
		{
			name: "array of objects, uniform keys",
			in:   `[{"name":"Player","type":"Sprite2D"},{"name":"Enemy","type":"Node2D"}]`,
			want: "name\ttype\nPlayer\tSprite2D\nEnemy\tNode2D",
		},
		{
			name: "array of objects, ragged keys → union, empty cells",
			in:   `[{"a":1,"b":2},{"b":3,"c":4}]`,
			want: "a\tb\tc\n1\t2\t\n\t3\t4",
		},
		// Rule 2: array of scalars → one value per line.
		{
			name: "array of scalars",
			in:   `["text","visible","position"]`,
			want: "text\nvisible\nposition",
		},
		{
			name: "array of numbers",
			in:   `[1,2,3]`,
			want: "1\n2\n3",
		},
		// Rule 3: object → key<TAB>value, keys sorted.
		{
			name: "flat object, keys sorted",
			in:   `{"type":"Sprite2D","name":"Player","visible":true}`,
			want: "name\tPlayer\ntype\tSprite2D\nvisible\ttrue",
		},
		// Rule 4: nested array/object value → compact single-line JSON in-cell.
		{
			name: "object with nested value",
			in:   `{"name":"Player","children":["A","B"],"pos":{"x":1,"y":2}}`,
			want: "children\t[\"A\",\"B\"]\nname\tPlayer\npos\t{\"x\":1,\"y\":2}",
		},
		{
			name: "array of objects with nested cell",
			in:   `[{"n":"a","tags":["x","y"]}]`,
			want: "n\ttags\na\t[\"x\",\"y\"]",
		},
		// Rule 5: strings raw (no quotes); tabs/newlines escaped.
		{
			name: "string value rendered raw",
			in:   `{"msg":"hello world"}`,
			want: "msg\thello world",
		},
		{
			name: "tab and newline in string escaped",
			in:   `{"msg":"a\tb\nc"}`,
			want: `msg` + "\t" + `a\tb\nc`,
		},
		// Bare top-level scalar (extension beyond the five rules).
		{
			name: "top-level scalar string",
			in:   `"just text"`,
			want: "just text",
		},
		{
			name: "top-level scalar bool",
			in:   `true`,
			want: "true",
		},
		// Mixed array (extension): objects mixed with scalars → one cell per line,
		// objects render as compact JSON.
		{
			name: "mixed array → one per line",
			in:   `["a",{"k":"v"},2]`,
			want: "a\n{\"k\":\"v\"}\n2",
		},
		// Empty containers.
		{
			name: "empty array",
			in:   `[]`,
			want: "",
		},
		{
			name: "empty object",
			in:   `{}`,
			want: "",
		},
		{
			name: "null value in object",
			in:   `{"a":null}`,
			want: "a\tnull",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := formatTSV(json.RawMessage(c.in))
			if err != nil {
				t.Fatalf("formatTSV(%s) error: %v", c.in, err)
			}
			if got != c.want {
				t.Errorf("formatTSV(%s)\n got: %q\nwant: %q", c.in, got, c.want)
			}
		})
	}
}

func TestFormatTSVInvalidJSON(t *testing.T) {
	if _, err := formatTSV(json.RawMessage(`{not json`)); err == nil {
		t.Fatal("expected an error for malformed JSON")
	}
}
