package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// parseParams turns CLI args after `<group> <command>` into a JSON params map.
//
// Forms accepted (keys are kebab- or snake-case; '-' is normalized to '_'):
//
//	--key value      string "value"
//	--key=value      string "value"
//	--key=true       bool true   (likewise false)
//	--flag           bool true   (no following value)
//
// Numeric values stay strings; the addon coerces them toward the target
// property type (so a numeric node name survives intact).
func parseParams(args []string) (map[string]any, error) {
	params := map[string]any{}
	for i := 0; i < len(args); {
		tok := args[i]
		if !strings.HasPrefix(tok, "--") {
			return nil, fmt.Errorf("unexpected argument %q (expected --key value)", tok)
		}
		body := tok[2:]
		if body == "" {
			return nil, fmt.Errorf("empty flag %q", tok)
		}

		var key, val string
		hasVal := false
		if eq := strings.IndexByte(body, '='); eq >= 0 {
			key, val, hasVal = body[:eq], body[eq+1:], true
			i++
		} else {
			key = body
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
				val, hasVal = args[i+1], true
				i += 2
			} else {
				i++
			}
		}

		key = strings.ReplaceAll(key, "-", "_")
		switch {
		case !hasVal:
			params[key] = true
		case val == "true":
			params[key] = true
		case val == "false":
			params[key] = false
		default:
			params[key] = jsonOrString(val)
		}
	}
	return params, nil
}

// jsonOrString parses a value that looks like a JSON array/object (`[...]` or
// `{...}`) into the real structure, so flags like --properties '["text"]' reach
// the addon as an array. Anything else (including Godot literals like
// "Vector2(1, 2)") stays a string for the addon to coerce.
func jsonOrString(val string) any {
	t := strings.TrimSpace(val)
	if len(t) == 0 || (t[0] != '[' && t[0] != '{') {
		return val
	}
	var parsed any
	if err := json.Unmarshal([]byte(t), &parsed); err != nil {
		return val
	}
	return parsed
}
