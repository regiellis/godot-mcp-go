package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestJSONSchemaType(t *testing.T) {
	cases := map[string]string{
		"String":     "string",
		"NodePath":   "string",
		"Vector2":    "string",
		"Vector3":    "string",
		"Color":      "string",
		"int":        "integer",
		"float":      "number",
		"bool":       "boolean",
		"Array":      "array",
		"Dictionary": "object",
		"JSON":       "", // any — the type key is omitted
		"Mystery":    "", // unknown — also omitted
	}
	for in, want := range cases {
		if got := jsonSchemaType(in); got != want {
			t.Errorf("jsonSchemaType(%q) = %q, want %q", in, got, want)
		}
	}
}

// cannedDocs exercises the type mapping, required extraction, name collision,
// and the runtime/input game-property injection.
func cannedDocs() map[string]commandDoc {
	return map[string]commandDoc{
		"node.add": {
			Description: "Add a node.",
			Params: []paramDoc{
				{Name: "type", Type: "String", Required: true, Desc: "class name"},
				{Name: "name", Type: "String", Required: false, Desc: "node name"},
				{Name: "count", Type: "int", Required: false, Desc: "how many"},
				{Name: "props", Type: "JSON", Required: false, Desc: "free-form"},
			},
		},
		"project.info": {Description: "Project info.", Params: nil}, // no params
		"runtime.eval": {
			Description: "Eval code in the running game.",
			Params: []paramDoc{
				{Name: "code", Type: "String", Required: true, Desc: "GDScript"},
			},
		},
		"input.action": {
			Description: "Fire an input action.",
			Params: []paramDoc{
				{Name: "action", Type: "String", Required: true, Desc: "action name"},
			},
		},
		// Collides with "a.b_c" -> both map to "a_b_c". Sorted order puts
		// "a.b.c" first ('.' < '_'), so it wins and "a.b_c" is skipped.
		"a.b.c": {Description: "kept", Params: nil},
		"a.b_c": {Description: "skipped", Params: nil},
	}
}

func schemaOf(tool map[string]any) map[string]any { return tool["inputSchema"].(map[string]any) }
func propsOf(tool map[string]any) map[string]any {
	return schemaOf(tool)["properties"].(map[string]any)
}

func TestBuildToolTypeMappingAndRequired(t *testing.T) {
	tool := buildTool("node_add", "node.add", cannedDocs()["node.add"])
	if tool["name"] != "node_add" {
		t.Fatalf("name = %v, want node_add", tool["name"])
	}
	if tool["description"] != "Add a node." {
		t.Fatalf("description = %v", tool["description"])
	}
	props := propsOf(tool)

	// type mapping + description passthrough
	typ := props["type"].(map[string]any)
	if typ["type"] != "string" || typ["description"] != "class name" {
		t.Errorf("type prop = %#v", typ)
	}
	if props["count"].(map[string]any)["type"] != "integer" {
		t.Errorf("count prop = %#v", props["count"])
	}
	// JSON type => no "type" key at all.
	jsonProp := props["props"].(map[string]any)
	if _, ok := jsonProp["type"]; ok {
		t.Errorf("JSON param must omit the type key, got %#v", jsonProp)
	}
	if jsonProp["description"] != "free-form" {
		t.Errorf("JSON param description = %#v", jsonProp)
	}

	// required array = only the required param.
	req := schemaOf(tool)["required"].([]string)
	if len(req) != 1 || req[0] != "type" {
		t.Errorf("required = %#v, want [type]", req)
	}

	// node.add is not a runtime/input method — no game property.
	if _, ok := props["game"]; ok {
		t.Errorf("node.add must not get a game property")
	}
}

func TestBuildToolGamePropertyInjection(t *testing.T) {
	docs := cannedDocs()
	for _, method := range []string{"runtime.eval", "input.action"} {
		tool := buildTool(strings.ReplaceAll(method, ".", "_"), method, docs[method])
		g, ok := propsOf(tool)["game"].(map[string]any)
		if !ok {
			t.Fatalf("%s missing game property", method)
		}
		if g["type"] != "boolean" || g["description"] != gamePropDesc {
			t.Errorf("%s game property = %#v", method, g)
		}
		// game is optional — never in required.
		req := schemaOf(tool)["required"].([]string)
		for _, r := range req {
			if r == "game" {
				t.Errorf("%s: game must not be required", method)
			}
		}
	}
}

func TestBuildToolNoParamsHasEmptyRequired(t *testing.T) {
	tool := buildTool("project_info", "project.info", cannedDocs()["project.info"])
	req := schemaOf(tool)["required"].([]string)
	if len(req) != 0 {
		t.Errorf("required = %#v, want empty", req)
	}
	if len(propsOf(tool)) != 0 {
		t.Errorf("properties = %#v, want empty", propsOf(tool))
	}
}

func TestBuildTypedToolsCollisionAndNameMap(t *testing.T) {
	tools, nameToMethod := buildTypedTools(cannedDocs())

	// 6 docs, but "a.b_c" collides with "a.b.c" and is skipped -> 5 tools.
	if len(tools) != 5 {
		t.Fatalf("len(tools) = %d, want 5", len(tools))
	}
	if len(nameToMethod) != 5 {
		t.Fatalf("len(nameToMethod) = %d, want 5", len(nameToMethod))
	}

	// Collision winner: sorted order puts "a.b.c" before "a.b_c".
	if got := nameToMethod["a_b_c"]; got != "a.b.c" {
		t.Errorf("a_b_c -> %q, want a.b.c (first in sorted order wins)", got)
	}

	// Name mapping round-trips through the explicit map (never parsed back).
	for _, tool := range tools {
		name := tool["name"].(string)
		method, ok := nameToMethod[name]
		if !ok {
			t.Errorf("tool %q missing from nameToMethod", name)
			continue
		}
		if strings.ReplaceAll(method, ".", "_") != name {
			t.Errorf("name %q does not map back to method %q", name, method)
		}
	}

	// Tools are sorted by name.
	for i := 1; i < len(tools); i++ {
		if tools[i-1]["name"].(string) > tools[i]["name"].(string) {
			t.Errorf("tools not sorted: %q before %q", tools[i-1]["name"], tools[i]["name"])
		}
	}

	// The skipped method is genuinely absent from the map's values.
	for _, m := range nameToMethod {
		if m == "a.b_c" {
			t.Errorf("skipped method a.b_c should not appear in nameToMethod")
		}
	}
}

// The built schema must marshal to valid JSON with the expected shape (a JSON
// param leaves the property with no "type", required present as an array).
func TestBuildToolMarshals(t *testing.T) {
	tool := buildTool("node_add", "node.add", cannedDocs()["node.add"])
	b, err := json.Marshal(tool)
	if err != nil {
		t.Fatal(err)
	}
	var round map[string]any
	if err := json.Unmarshal(b, &round); err != nil {
		t.Fatal(err)
	}
	props := round["inputSchema"].(map[string]any)["properties"].(map[string]any)
	if _, ok := props["props"].(map[string]any)["type"]; ok {
		t.Errorf("marshaled JSON param still carries a type: %s", b)
	}
	if _, ok := round["inputSchema"].(map[string]any)["required"]; !ok {
		t.Errorf("marshaled schema missing required key: %s", b)
	}
}
