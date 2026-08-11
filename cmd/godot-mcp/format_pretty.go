package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

const (
	// maxPrettyCell caps one table cell; longer values truncate with an
	// ellipsis. The pretty format is a lossy human view — --format json is the
	// exact one.
	maxPrettyCell = 60
	// maxBoxWidth caps the key/value box border. Body lines longer than this
	// (a script source, a long path list) print whole and overrun the border
	// rather than being cut.
	maxBoxWidth = 100
)

// renderPretty renders a successful result for a terminal: a top-level object
// as a titled key/value box, an array of objects as a table, an array of
// scalars as a list, a bare scalar as its value. Layout is unconditional;
// color rides on the palette, so NO_COLOR keeps the shape and drops the paint.
func renderPretty(method string, result json.RawMessage, p ui.Palette) (string, error) {
	t := bytes.TrimSpace(result)
	if len(t) == 0 {
		return p.Dim("(no result)"), nil
	}
	switch t[0] {
	case '{':
		return prettyObject(method, t, p)
	case '[':
		return prettyArray(method, t, p)
	default:
		return styleScalar(t, p)
	}
}

// prettyObject renders key/value rows, keys sorted, inside a titled rounded
// border (top and bottom only, so a long row never breaks alignment). A
// multi-line string value drops to an indented block under its key instead of
// being newline-escaped onto one line.
func prettyObject(title string, raw json.RawMessage, p ui.Palette) (string, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return "", err
	}
	keys := slices.Sorted(maps.Keys(m))
	if len(keys) == 0 {
		return p.Heading(title) + " " + p.Dim("(empty)"), nil
	}

	kw := 0
	for _, k := range keys {
		kw = max(kw, utf8.RuneCountInString(k))
	}
	inner := utf8.RuneCountInString(title) + 4
	var lines []string
	for _, k := range keys {
		if s, ok := stringValue(m[k]); ok && strings.ContainsAny(s, "\n\r") {
			lines = append(lines, "  "+p.Key(k))
			for _, ln := range strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n") {
				inner = max(inner, 4+utf8.RuneCountInString(ln))
				lines = append(lines, strings.TrimRight("    "+ln, " "))
			}
			continue
		}
		plain, err := cellFromRaw(m[k])
		if err != nil {
			return "", err
		}
		// A nested value that no longer reads on one line (a scene tree, an
		// autoload map) drops to an indented pretty-JSON block under its key.
		vt := bytes.TrimSpace(m[k])
		if len(vt) > 0 && (vt[0] == '{' || vt[0] == '[') && utf8.RuneCountInString(plain) > maxPrettyCell {
			var buf bytes.Buffer
			if ierr := json.Indent(&buf, vt, "", "  "); ierr != nil {
				return "", ierr
			}
			lines = append(lines, "  "+p.Key(k))
			for _, ln := range strings.Split(buf.String(), "\n") {
				inner = max(inner, 4+utf8.RuneCountInString(ln))
				lines = append(lines, "    "+p.Dim(ln))
			}
			continue
		}
		inner = max(inner, 2+kw+2+utf8.RuneCountInString(plain))
		lines = append(lines, "  "+p.Key(padRight(k, kw))+"  "+styleCell(m[k], plain, p))
	}
	inner = min(inner, maxBoxWidth)

	var b strings.Builder
	tail := max(1, inner-utf8.RuneCountInString(title)-2)
	b.WriteString(p.Dim("╭─ ") + p.Heading(title) + p.Dim(" "+strings.Repeat("─", tail)+"╮"))
	for _, l := range lines {
		b.WriteByte('\n')
		b.WriteString(l)
	}
	b.WriteByte('\n')
	b.WriteString(p.Dim("╰" + strings.Repeat("─", inner+1) + "╯"))
	return b.String(), nil
}

// prettyArray renders a table when every element is an object (columns are the
// sorted union of keys, like the TSV renderer), otherwise a bulleted list.
func prettyArray(title string, raw json.RawMessage, p ui.Palette) (string, error) {
	var elems []json.RawMessage
	if err := json.Unmarshal(raw, &elems); err != nil {
		return "", err
	}
	if len(elems) == 0 {
		return p.Heading(title) + " " + p.Dim("(empty)"), nil
	}

	allObjects := true
	for _, e := range elems {
		et := bytes.TrimSpace(e)
		if len(et) == 0 || et[0] != '{' {
			allObjects = false
			break
		}
	}

	head := p.Heading(title) + p.Dim(fmt.Sprintf(" · %d items", len(elems)))
	if !allObjects {
		var b strings.Builder
		b.WriteString(head)
		for _, e := range elems {
			s, err := styleScalar(e, p)
			if err != nil {
				return "", err
			}
			b.WriteString("\n  " + p.Dim("•") + " " + s)
		}
		return b.String(), nil
	}

	rows := make([]map[string]json.RawMessage, len(elems))
	keySet := map[string]struct{}{}
	for i, e := range elems {
		if err := json.Unmarshal(e, &rows[i]); err != nil {
			return "", err
		}
		for k := range rows[i] {
			keySet[k] = struct{}{}
		}
	}
	keys := slices.Sorted(maps.Keys(keySet))

	// Plain cells first, truncated, so the width math never sees a color code.
	cells := make([][]string, len(rows))
	widths := make([]int, len(keys))
	for i, k := range keys {
		widths[i] = utf8.RuneCountInString(k)
	}
	for i, m := range rows {
		cells[i] = make([]string, len(keys))
		for j, k := range keys {
			if v, ok := m[k]; ok {
				c, err := cellFromRaw(v)
				if err != nil {
					return "", err
				}
				cells[i][j] = truncateCell(c)
			}
			widths[j] = max(widths[j], utf8.RuneCountInString(cells[i][j]))
		}
	}

	var b strings.Builder
	b.WriteString(head)
	hdr := make([]string, len(keys))
	rule := make([]string, len(keys))
	for j, k := range keys {
		hdr[j] = p.Key(padRight(k, widths[j]))
		rule[j] = p.Dim(strings.Repeat("─", widths[j]))
	}
	b.WriteString("\n  " + strings.TrimRight(strings.Join(hdr, "  "), " "))
	b.WriteString("\n  " + strings.Join(rule, "  "))
	for i, m := range rows {
		out := make([]string, len(keys))
		for j, k := range keys {
			out[j] = styleCell(m[k], padRight(cells[i][j], widths[j]), p)
		}
		b.WriteString("\n" + strings.TrimRight("  "+strings.Join(out, "  "), " "))
	}
	return b.String(), nil
}

// styleCell colors one flattened value by its JSON type: numbers yellow, bools
// magenta, null and nested structures dim. Strings stay unpainted — they are
// most of every result, and painting them all is noise.
func styleCell(raw json.RawMessage, plain string, p ui.Palette) string {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 {
		return plain
	}
	switch {
	case t[0] == '{' || t[0] == '[':
		return p.Dim(plain)
	case t[0] == '"':
		return plain
	case bytes.Equal(t, []byte("true")) || bytes.Equal(t, []byte("false")):
		return p.Bool(plain)
	case bytes.Equal(t, []byte("null")):
		return p.Dim(plain)
	default:
		return p.Num(plain)
	}
}

// styleScalar flattens one JSON value (via the TSV cell rules) and colors it.
func styleScalar(raw json.RawMessage, p ui.Palette) (string, error) {
	plain, err := cellFromRaw(raw)
	if err != nil {
		return "", err
	}
	return styleCell(raw, plain, p), nil
}

// stringValue unwraps raw when it is a JSON string.
func stringValue(raw json.RawMessage) (string, bool) {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 || t[0] != '"' {
		return "", false
	}
	var s string
	if err := json.Unmarshal(t, &s); err != nil {
		return "", false
	}
	return s, true
}

// padRight pads s with spaces to w runes. Never truncates.
func padRight(s string, w int) string {
	if n := utf8.RuneCountInString(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

// truncateCell caps a cell at maxPrettyCell runes, marking the cut with an
// ellipsis.
func truncateCell(s string) string {
	if utf8.RuneCountInString(s) <= maxPrettyCell {
		return s
	}
	return string([]rune(s)[:maxPrettyCell-1]) + "…"
}
