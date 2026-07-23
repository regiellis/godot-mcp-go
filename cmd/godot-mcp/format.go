package main

import (
	"bytes"
	"encoding/json"
	"maps"
	"slices"
	"strings"
)

// cellEscaper renders tabs and newlines inside a value so they never break the
// TSV grid. A literal tab/CR/LF in a string cell becomes its two-char escape.
var cellEscaper = strings.NewReplacer("\t", `\t`, "\r", `\r`, "\n", `\n`)

// formatTSV re-renders a successful JSON-RPC result as tab-separated text for
// shell pipelines. The rules (see CLAUDE.md / the CLI --format flag):
//
//   - Top-level array of objects → a header row of the sorted union of keys,
//     then one row per element (missing keys → empty cell).
//   - Top-level array of scalars → one value per line.
//   - Top-level object → key<TAB>value rows, keys sorted.
//   - A nested array/object value renders as compact single-line JSON in-cell.
//   - Strings render raw (no quotes); tabs/newlines inside a value are escaped.
//
// A bare top-level scalar (rare for a command result) renders as its raw value
// on one line. The returned string carries no trailing newline; the caller adds
// one when printing.
func formatTSV(result json.RawMessage) (string, error) {
	t := bytes.TrimSpace(result)
	if len(t) == 0 {
		return "", nil
	}
	switch t[0] {
	case '[':
		return tsvArray(t)
	case '{':
		return tsvObject(t)
	default:
		// Top-level scalar: emit its raw value (validated by round-tripping it).
		return cellFromRaw(t)
	}
}

// tsvArray renders a top-level array. When every element is an object it becomes
// a header + rows table over the sorted union of keys; otherwise (scalars or a
// mix) it becomes one cell per line.
func tsvArray(raw json.RawMessage) (string, error) {
	var elems []json.RawMessage
	if err := json.Unmarshal(raw, &elems); err != nil {
		return "", err
	}
	if len(elems) == 0 {
		return "", nil
	}

	allObjects := true
	for _, e := range elems {
		et := bytes.TrimSpace(e)
		if len(et) == 0 || et[0] != '{' {
			allObjects = false
			break
		}
	}

	if allObjects {
		rows := make([]map[string]json.RawMessage, len(elems))
		keySet := map[string]struct{}{}
		for i, e := range elems {
			var m map[string]json.RawMessage
			if err := json.Unmarshal(e, &m); err != nil {
				return "", err
			}
			rows[i] = m
			for k := range m {
				keySet[k] = struct{}{}
			}
		}
		keys := slices.Sorted(maps.Keys(keySet))

		var b strings.Builder
		header := make([]string, len(keys))
		for i, k := range keys {
			header[i] = cellEscaper.Replace(k)
		}
		b.WriteString(strings.Join(header, "\t"))
		for _, m := range rows {
			b.WriteByte('\n')
			cells := make([]string, len(keys))
			for i, k := range keys {
				if v, ok := m[k]; ok {
					c, err := cellFromRaw(v)
					if err != nil {
						return "", err
					}
					cells[i] = c
				}
			}
			b.WriteString(strings.Join(cells, "\t"))
		}
		return b.String(), nil
	}

	// Array of scalars (or mixed): one value per line.
	var b strings.Builder
	for i, e := range elems {
		if i > 0 {
			b.WriteByte('\n')
		}
		c, err := cellFromRaw(e)
		if err != nil {
			return "", err
		}
		b.WriteString(c)
	}
	return b.String(), nil
}

// tsvObject renders a top-level object as key<TAB>value rows, keys sorted.
func tsvObject(raw json.RawMessage) (string, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return "", err
	}
	keys := slices.Sorted(maps.Keys(m))
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteByte('\n')
		}
		c, err := cellFromRaw(m[k])
		if err != nil {
			return "", err
		}
		b.WriteString(cellEscaper.Replace(k))
		b.WriteByte('\t')
		b.WriteString(c)
	}
	return b.String(), nil
}

// cellFromRaw renders one JSON value into a single TSV cell: strings unquoted,
// numbers/bools/null as their literal, and nested arrays/objects as compact
// single-line JSON. Tabs and newlines are escaped in every case.
func cellFromRaw(raw json.RawMessage) (string, error) {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 {
		return "", nil
	}
	switch t[0] {
	case '{', '[':
		var buf bytes.Buffer
		if err := json.Compact(&buf, t); err != nil {
			return "", err
		}
		return cellEscaper.Replace(buf.String()), nil
	case '"':
		var s string
		if err := json.Unmarshal(t, &s); err != nil {
			return "", err
		}
		return cellEscaper.Replace(s), nil
	default:
		// number, bool, or null — keep the literal form verbatim.
		return cellEscaper.Replace(string(t)), nil
	}
}
