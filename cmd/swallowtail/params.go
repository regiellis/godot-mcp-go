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

		flagName := "--" + key
		key = strings.ReplaceAll(key, "-", "_")
		switch {
		case !hasVal:
			params[key] = true
		case val == "true":
			params[key] = true
		case val == "false":
			params[key] = false
		default:
			v, err := jsonOrString(flagName, val)
			if err != nil {
				return nil, err
			}
			params[key] = v
		}
	}
	return params, nil
}

// jsonOrString parses a value that looks like a JSON array/object (`[...]` or
// `{...}`) into the real structure, so flags like --properties '["text"]' reach
// the addon as an array. Anything else (including Godot literals like
// "Vector2(1, 2)") stays a string for the addon to coerce.
//
// A value that opens with `[` or `{` and does NOT parse is an error, never a
// string. The addon's typed params (require_array, require_dict, the
// TYPE_DICTIONARY branch of PropertyParser) discard a string they cannot read
// and fall back to a default, so a mis-escaped --properties '[\"health\"]' used
// to return every property with a success envelope: the flag went nowhere and
// nothing said so. A value that genuinely starts with a bracket or brace goes
// through the backslash escape below.
func jsonOrString(flag, val string) (any, error) {
	t := strings.TrimSpace(val)
	if len(t) == 0 {
		return val, nil
	}
	// Escape hatch: \[ or \{ sends the rest verbatim as a string.
	if t[0] == '\\' && len(t) > 1 && (t[1] == '[' || t[1] == '{') {
		return t[1:], nil
	}
	if t[0] != '[' && t[0] != '{' {
		return val, nil
	}
	var parsed any
	if err := json.Unmarshal([]byte(t), &parsed); err != nil {
		return nil, fmt.Errorf("%s: value opens with %q so it is read as JSON, but it does not parse: %v\n"+
			"Check the quoting (a shell often eats the inner quotes: use %s '[\"one\",\"two\"]').\n"+
			"To send a literal string that starts with %q, prefix it with a backslash: %s '\\%s'",
			flag, t[:1], err, flag, t[:1], flag, t)
	}
	return parsed, nil
}
