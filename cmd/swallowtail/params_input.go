package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"
)

const maxParamsBytes = 16 << 20

// JSON files are parameter objects, not JSON-RPC envelopes. Explicit flags win.
// A leading @ remains a literal value; only --params-file opts into file access.
func readParamsInput(path string, stdin io.Reader) (map[string]any, error) {
	var r io.Reader = stdin
	if path != "-" {
		f, err := os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("--params-file: %w", err)
		}
		defer f.Close()
		r = f
	}
	b, err := io.ReadAll(io.LimitReader(r, maxParamsBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > maxParamsBytes {
		return nil, fmt.Errorf("--params-file exceeds 16 MiB")
	}
	b = bytes.TrimPrefix(b, []byte{0xef, 0xbb, 0xbf}) // PowerShell UTF-8 files may carry a BOM.
	if !utf8.Valid(b) {
		return nil, fmt.Errorf("--params-file must be UTF-8")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if err = dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("--params-file needs a JSON object: %w", err)
	}
	if m == nil {
		return nil, fmt.Errorf("--params-file needs an object, not null")
	}
	var tail any
	if err = dec.Decode(&tail); err != io.EOF {
		return nil, fmt.Errorf("--params-file must contain exactly one JSON object")
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		key := strings.ReplaceAll(k, "-", "_")
		if key == "" {
			return nil, fmt.Errorf("--params-file contains an empty parameter name")
		}
		if _, exists := out[key]; exists {
			return nil, fmt.Errorf("--params-file contains colliding parameter names for %q", key)
		}
		out[key] = v
	}
	return out, nil
}
