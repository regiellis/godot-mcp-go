package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// inspectionPretty specializes read-heavy commands, leaving unknown shapes intact.
func inspectionPretty(method string, raw json.RawMessage, p ui.Palette) (string, bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return "", false
	}
	if method == "scene.tree" || method == "runtime.tree" {
		var root inspectionNode
		if json.Unmarshal(m["tree"], &root) != nil || root.Name == "" {
			return "", false
		}
		var b strings.Builder
		b.WriteString(p.Heading(method))
		if path, ok := stringValue(m["scene_path"]); ok {
			b.WriteString("\n" + p.Dim(path))
		}
		var walk func(inspectionNode, string, string, int)
		walk = func(n inspectionNode, indent, branch string, depth int) {
			b.WriteString("\n" + p.Dim(indent+branch) + p.Key(n.Name) + " " + p.Dim("("+n.Type+")"))
			if n.Path != "" {
				b.WriteString(" " + p.Dim(n.Path))
			}
			if len(n.Extra) > 0 {
				extra, _ := json.Marshal(n.Extra)
				b.WriteString(" " + string(extra))
			}
			if depth > 64 {
				b.WriteString("\n" + indent + "  ... use --format json for the full tree")
				return
			}
			for i, child := range n.Children {
				next, mark := indent, "├─ "
				if branch == "├─ " {
					next += "│  "
				} else if branch != "" {
					next += "   "
				}
				if i == len(n.Children)-1 {
					mark = "└─ "
				}
				walk(child, next, mark, depth+1)
			}
		}
		walk(root, "", "", 0)
		// Preserve supplemental fields (counts, truncation markers, etc.).
		delete(m, "tree")
		delete(m, "scene_path")
		if len(m) > 0 {
			extra, _ := json.Marshal(m)
			s := inspectionDetails(extra)
			b.WriteString("\n" + s)
		}
		return b.String(), true
	}
	if method != "scene.validate" && method != "script.validate" {
		return "", false
	}
	var valid bool
	if json.Unmarshal(m["valid"], &valid) != nil {
		return "", false
	}
	label := "VALID"
	if !valid {
		label = "INVALID"
	}
	var b strings.Builder
	b.WriteString(p.Heading(method) + ": " + label)
	for _, k := range []string{"path", "scene_path"} {
		if s, ok := stringValue(m[k]); ok {
			b.WriteString("\n" + s)
		}
	}
	for _, key := range []string{"issues", "diagnostics"} {
		var entries []map[string]json.RawMessage
		if json.Unmarshal(m[key], &entries) != nil {
			continue
		}
		entryLabel := key
		if len(entries) == 1 {
			entryLabel = strings.TrimSuffix(key, "s")
		}
		fmt.Fprintf(&b, "\n%d %s", len(entries), entryLabel)
		for _, entry := range entries {
			file, _ := stringValue(entry["file"])
			line := ""
			if n := strings.TrimSpace(string(entry["line"])); n != "" {
				if _, err := strconv.ParseFloat(n, 64); err == nil {
					line = ":" + n
				}
			}
			b.WriteString("\n  " + file + line)
			for _, k := range []string{"severity", "type", "message", "detail", "node", "property", "path", "track_path"} {
				if s, ok := stringValue(entry[k]); ok {
					b.WriteString(" " + k + "=" + s)
					delete(entry, k)
				}
			}
			delete(entry, "file")
			delete(entry, "line")
			if len(entry) > 0 {
				extra, _ := json.Marshal(entry)
				b.WriteString(" " + string(extra))
			}
		}
		delete(m, key)
	}
	for _, k := range []string{"valid", "path", "scene_path"} {
		delete(m, k)
	}
	if len(m) > 0 {
		extra, _ := json.Marshal(m)
		s := inspectionDetails(extra)
		b.WriteString("\n" + s)
	}
	return b.String(), true
}

type inspectionNode struct {
	Name     string                     `json:"name"`
	Type     string                     `json:"type"`
	Path     string                     `json:"path"`
	Children []inspectionNode           `json:"children"`
	Extra    map[string]json.RawMessage `json:"-"`
}

func (n *inspectionNode) UnmarshalJSON(raw []byte) error {
	type plain inspectionNode
	if err := json.Unmarshal(raw, (*plain)(n)); err != nil {
		return err
	}
	if err := json.Unmarshal(raw, &n.Extra); err != nil {
		return err
	}
	for _, k := range []string{"name", "type", "path", "children"} {
		delete(n.Extra, k)
	}
	return nil
}

// Wrap specialized inspection output without truncating identifiers or diagnostics.
// COLUMNS provides a predictable override in small terminals and captured examples.
func wrapInspection(s string) string {
	width := 80
	if n, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && n >= 20 && n <= 500 {
		width = n
	}
	var out []string
	for _, line := range strings.Split(s, "\n") {
		// Preserve long identifiers intact so file:line remains copyable.
		if strings.Contains(line, "\x1b") {
			out = append(out, line)
			continue
		}
		indent := line[:len(line)-len(strings.TrimLeft(line, " "))]
		current := indent
		for _, word := range strings.Fields(line) {
			if len([]rune(current))+1+len([]rune(word)) > width && strings.TrimSpace(current) != "" {
				out = append(out, current)
				current = indent
			}
			if strings.TrimSpace(current) != "" {
				current += " "
			}
			current += word
		}
		out = append(out, current)
	}
	return strings.Join(out, "\n")
}

func inspectionDetails(raw []byte) string {
	var m map[string]json.RawMessage
	_ = json.Unmarshal(raw, &m)
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var rows []string
	for _, k := range keys {
		v, _ := cellFromRaw(m[k])
		rows = append(rows, k+": "+v)
	}
	return strings.Join(rows, "\n")
}
