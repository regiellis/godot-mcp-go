package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// project.godot is a Godot ConfigFile, and every phase after preflight changes
// it through project.set_setting in the open editor, which is the rule the
// craft doc states and this file does not break. preflight is the one place
// with no editor to talk to: it runs before the first launch on purpose,
// because launching is what starts rewriting the project. So it edits the text,
// and it edits it the way Godot writes it, keeping every other line untouched.

// setProjectSettings applies key/value pairs to project.godot text and returns
// the new text. A key is a full setting path (debug/gdscript/warnings/unused_variable);
// its first component is the section and the rest is the key inside it, which is
// how Godot splits them on disk.
func setProjectSettings(text string, values map[string]string) string {
	lines := strings.Split(text, "\n")
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, full := range keys {
		section, key, ok := strings.Cut(full, "/")
		if !ok {
			// A key with no section is a top-level entry such as config_version.
			section, key = "", full
		}
		lines = setConfigKey(lines, section, key, values[full])
	}
	return strings.Join(lines, "\n")
}

// setConfigKey writes one key inside one section, replacing it in place when it
// is already there and appending it to the end of the section otherwise. A
// missing section is created at the end of the file, which is where Godot puts
// a late-registered one anyway.
func setConfigKey(lines []string, section, key, value string) []string {
	start, end := settingSectionBounds(lines, section)
	if start < 0 {
		out := append([]string{}, lines...)
		if len(out) > 0 && strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, "")
		}
		out = append(out, "["+section+"]", "", key+"="+value, "")
		return out
	}
	for i := start; i < end; i++ {
		k, _, ok := strings.Cut(lines[i], "=")
		if ok && strings.TrimSpace(k) == key {
			out := append([]string{}, lines...)
			out[i] = key + "=" + value
			return out
		}
	}
	insert := end
	for insert > start && strings.TrimSpace(lines[insert-1]) == "" {
		insert--
	}
	out := append([]string{}, lines[:insert]...)
	out = append(out, key+"="+value)
	return append(out, lines[insert:]...)
}

// settingSectionBounds returns the line range of a section's body, exclusive of
// its header, reusing install.go's sectionBounds for the ordinary case. An
// empty section name is the file's preamble, before any header, which is where
// config_version lives.
func settingSectionBounds(lines []string, section string) (int, int) {
	if section != "" {
		return sectionBounds(lines, section)
	}
	for i, l := range lines {
		if isSectionHeader(l) {
			return 0, i
		}
	}
	return 0, len(lines)
}

// isSectionHeader reports whether a line is a [section] header. Godot writes
// them alone on their line, so anything with a value on it is a key.
func isSectionHeader(line string) bool {
	t := strings.TrimSpace(line)
	return strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") && !strings.Contains(t, "=")
}

// readProjectFile loads project.godot as text.
func readProjectFile(root string) (string, error) {
	b, err := os.ReadFile(filepath.Join(root, "project.godot"))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// writeProjectFile writes project.godot back.
func writeProjectFile(root, text string) error {
	return os.WriteFile(filepath.Join(root, "project.godot"), []byte(text), 0o644)
}

// gdscriptWarningLevels is the list of debug/gdscript/warnings settings
// preflight forces on, with the level to write for each. It is hand-kept and
// read off a running editor with
//
//	godot-mcp project settings --filter gdscript/warnings
//
// rather than written from memory. Refresh it the same way when the engine adds
// a warning: an unknown key here is harmless, since Godot keeps a setting it
// does not recognise, but a missing one is a warning the harvest never sees.
//
// Read off Godot 4.7.2-rc (36a04fe52) on 2026-08-30: 52 settings, of which 49
// are levels and three are not. 1 is warn and 2 is error, and the four keys
// carrying 2 below are the ones the engine itself defaults to error. Writing 1
// over those would quietly lower a project's severity during the port, which is
// the opposite of what forcing warnings on is for, so they keep the level they
// already had.
//
// The three that are not levels are left alone. enable is a bool and is set
// separately; renamed_in_godot_4_hint is a bool; and directory_rules is a
// Dictionary, which in 4.7 replaced the old exclude_addons switch and defaults
// to { "res://addons": 0 }. Third-party addon code is the addon author's to
// port, so that default is correct for a harvest and preflight keeps it.
var gdscriptWarningLevels = map[string]string{
	"assert_always_false":               "1",
	"assert_always_true":                "1",
	"confusable_capture_reassignment":   "1",
	"confusable_identifier":             "1",
	"confusable_local_declaration":      "1",
	"confusable_local_usage":            "1",
	"confusable_temporary_modification": "1",
	"constant_used_as_function":         "1",
	"deprecated_keyword":                "1",
	"empty_file":                        "1",
	"enum_variable_without_default":     "1",
	"function_used_as_property":         "1",
	"get_node_default_without_onready":  "2",
	"incompatible_ternary":              "1",
	"inference_on_variant":              "2",
	"inferred_declaration":              "1",
	"int_as_enum_without_cast":          "1",
	"int_as_enum_without_match":         "1",
	"integer_division":                  "1",
	"missing_await":                     "1",
	"missing_tool":                      "1",
	"narrowing_conversion":              "1",
	"native_method_override":            "2",
	"onready_with_export":               "2",
	"property_used_as_function":         "1",
	"redundant_await":                   "1",
	"redundant_static_unload":           "1",
	"return_value_discarded":            "1",
	"shadowed_global_identifier":        "1",
	"shadowed_variable":                 "1",
	"shadowed_variable_base_class":      "1",
	"standalone_expression":             "1",
	"standalone_ternary":                "1",
	"static_called_on_instance":         "1",
	"unassigned_variable":               "1",
	"unassigned_variable_op_assign":     "1",
	"unreachable_code":                  "1",
	"unreachable_pattern":               "1",
	"unsafe_call_argument":              "1",
	"unsafe_cast":                       "1",
	"unsafe_method_access":              "1",
	"unsafe_property_access":            "1",
	"unsafe_void_return":                "1",
	"untyped_declaration":               "1",
	"unused_local_constant":             "1",
	"unused_parameter":                  "1",
	"unused_private_class_variable":     "1",
	"unused_signal":                     "1",
	"unused_variable":                   "1",
}

// warningSettings builds the map preflight commits: the warning system on, and
// every level at warn or above. current is project.godot as it stands, so a
// project that already escalated a warning to error keeps the error.
func warningSettings(current map[string]string) map[string]string {
	out := map[string]string{"debug/gdscript/warnings/enable": "true"}
	for k, level := range gdscriptWarningLevels {
		full := "debug/gdscript/warnings/" + k
		if current[full] == "2" {
			level = "2"
		}
		out[full] = level
	}
	return out
}

// readProjectSettings reads every key of project.godot back as full setting
// paths, which is what lets warningSettings keep an escalated warning.
func readProjectSettings(text string) map[string]string {
	out := map[string]string{}
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		if isSectionHeader(line) {
			section = strings.Trim(line, "[]")
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key := strings.TrimSpace(k)
		if section != "" {
			key = section + "/" + key
		}
		out[key] = strings.TrimSpace(v)
	}
	return out
}

// warningSettingKeys lists the settings warningSettings writes, sorted, for the
// preflight report.
func warningSettingKeys(values map[string]string) []string {
	out := make([]string, 0, len(values))
	for k := range values {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// verifyProjectSettings re-reads project.godot and reports any key that did not
// come back with the value just written. The engine is not involved, so this is
// the offline half of "the file still opens"; preflight runs a cold parse under
// the target binary for the other half.
func verifyProjectSettings(root string, values map[string]string) []string {
	text, err := readProjectFile(root)
	if err != nil {
		return []string{"project.godot could not be re-read: " + err.Error()}
	}
	lines := strings.Split(text, "\n")
	var bad []string
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, full := range keys {
		section, key, ok := strings.Cut(full, "/")
		if !ok {
			section, key = "", full
		}
		start, end := settingSectionBounds(lines, section)
		found := false
		for i := start; i >= 0 && i < end; i++ {
			k, v, has := strings.Cut(lines[i], "=")
			if has && strings.TrimSpace(k) == key && strings.TrimSpace(v) == values[full] {
				found = true
				break
			}
		}
		if !found {
			bad = append(bad, full)
		}
	}
	return bad
}
