package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// runConfigure is a local subcommand (it never dials the addon) that writes an
// MCP-server config entry pointing an AI client at this binary's `serve` (stdio
// MCP) mode. It is a sibling of create/install/install-assets/status.
//
// Client config formats below are current as of 2026-07 and may need updating as
// the clients evolve:
//   - claude  project -> <project>/.mcp.json            {"mcpServers": {...}}
//   - cursor  project -> <project>/.cursor/mcp.json     {"mcpServers": {...}}
//   - cursor  global  -> ~/.cursor/mcp.json             {"mcpServers": {...}}
//   - vscode  project -> <project>/.vscode/mcp.json     {"servers": {"<n>": {"type":"stdio", ...}}}
//   - codex   global  -> ~/.codex/config.toml           [mcp_servers.<name>]
//
// The generated invocation is `<abs binary> serve --project <abs project>`. Note
// the serve subcommand's flag is --project (see serve.go), not --path; pointing
// it at an unknown flag would make flag parsing fail and the server never start.
func runConfigure(args []string) int {
	// Pull the positional <client> out so flags may sit on either side of it
	// (flag.Parse stops at the first non-flag token, so the common
	// `configure <client> --flags` form needs the client peeled off first).
	var clientName string
	if len(args) >= 1 && !strings.HasPrefix(args[0], "-") {
		clientName = args[0]
		args = args[1:]
	}

	fs := flag.NewFlagSet("configure", flag.ContinueOnError)
	project := fs.String("project", "", "Godot project dir to target (default: cwd)")
	global := fs.Bool("global", false, "write the user-global client config instead of a project-scoped file")
	printSnippet := fs.Bool("print", false, "print the config snippet and its target path without writing anything")
	name := fs.String("name", "godot-mcp", "MCP server key to write")
	force := fs.Bool("force", false, "replace an existing server entry of the same name")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `godot-mcp configure — point an AI client at godot-mcp's stdio MCP server

Usage:
  godot-mcp configure <client> [--project DIR] [--global] [--print] [--name NAME] [--force]

Clients: claude, cursor, vscode, codex

Flags:`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if clientName == "" {
		clientName = fs.Arg(0)
	}
	if clientName == "" {
		fmt.Fprintln(os.Stderr, "configure: a <client> is required (claude, cursor, vscode, codex)")
		fs.Usage()
		return 2
	}

	label, ok := clientLabels[clientName]
	if !ok {
		fmt.Fprintf(os.Stderr, "configure: unknown client %q — valid clients: claude, cursor, vscode, codex\n", clientName)
		fmt.Fprintln(os.Stderr, "Use --print to see the config snippet for a client without writing it.")
		return 2
	}

	// Resolve the target project to an absolute path — used both as serve's
	// --project arg and to locate project-scoped config files.
	proj := *project
	if proj == "" {
		proj, _ = os.Getwd()
	}
	absProj, err := filepath.Abs(proj)
	if err != nil {
		absProj = proj
	}

	// The command the client will launch: this binary's absolute path.
	exe, err := os.Executable()
	if err != nil || exe == "" {
		exe = "godot-mcp"
	} else if abs, e := filepath.Abs(exe); e == nil {
		exe = abs
	}
	srvArgs := []string{"serve", "--project", absProj}

	switch clientName {
	case "claude":
		if *global {
			// ~/.claude.json holds unrelated Claude Code state (projects, history);
			// merging into it programmatically is risky, so print instead.
			path := homePath(".claude.json")
			fmt.Fprintf(os.Stderr, "configure: the global %s config (%s) also stores unrelated Claude Code state; writing it automatically is risky.\n", label, path)
			fmt.Fprintln(os.Stderr, "Printing the snippet instead — add it under the top-level \"mcpServers\" object, or drop --global to use the project-scoped .mcp.json.")
			return configureJSON(path, "mcpServers", *name, exe, srvArgs, false, false, true, label)
		}
		path := filepath.Join(absProj, ".mcp.json")
		return configureJSON(path, "mcpServers", *name, exe, srvArgs, false, *force, *printSnippet, label)

	case "cursor":
		var path string
		if *global {
			home, herr := os.UserHomeDir()
			if herr != nil {
				fmt.Fprintln(os.Stderr, "configure: cannot resolve home dir:", herr)
				return 1
			}
			path = filepath.Join(home, ".cursor", "mcp.json")
		} else {
			path = filepath.Join(absProj, ".cursor", "mcp.json")
		}
		return configureJSON(path, "mcpServers", *name, exe, srvArgs, false, *force, *printSnippet, label)

	case "vscode":
		if *global {
			// VS Code's global MCP config lives inside the user settings.json, not a
			// standalone file we can safely locate/merge — print instead.
			fmt.Fprintln(os.Stderr, "configure: VS Code's global MCP config lives in your user settings.json (run \"MCP: Open User Configuration\"), not a standalone file.")
			fmt.Fprintln(os.Stderr, "Printing the snippet instead — paste it there, or drop --global to use the project-scoped .vscode/mcp.json.")
			return configureJSON("<VS Code user settings.json>", "servers", *name, exe, srvArgs, true, false, true, label)
		}
		path := filepath.Join(absProj, ".vscode", "mcp.json")
		return configureJSON(path, "servers", *name, exe, srvArgs, true, *force, *printSnippet, label)

	case "codex":
		// Codex has no project-scoped MCP config; it is global-only (~/.codex/config.toml).
		path := homePath(filepath.Join(".codex", "config.toml"))
		if !*global {
			fmt.Fprintf(os.Stderr, "configure: Codex has no project-scoped MCP config — it is configured globally in %s.\n", path)
			fmt.Fprintln(os.Stderr, "Printing the snippet instead — re-run with --global to write it.")
			return configureTOML(path, *name, exe, srvArgs, false, true, label)
		}
		return configureTOML(path, *name, exe, srvArgs, *force, *printSnippet, label)
	}
	return 2 // unreachable: clientLabels gate above
}

// clientLabels maps each supported client id to a human-facing name (used in
// messages) and doubles as the set of valid clients.
var clientLabels = map[string]string{
	"claude": "Claude Code",
	"cursor": "Cursor",
	"vscode": "VS Code",
	"codex":  "Codex",
}

// mcpEntry is our server entry in JSON client configs. Type is "stdio" only for
// VS Code (which keys on "servers" + an explicit type); claude/cursor omit it.
type mcpEntry struct {
	Type    string   `json:"type,omitempty"`
	Command string   `json:"command"`
	Args    []string `json:"args"`
}

// configureJSON writes (or prints) our server entry into a JSON client config,
// merging under parentKey ("mcpServers" or "servers") without clobbering other
// keys. It refuses to replace an existing entry of the same name unless force.
func configureJSON(path, parentKey, name, command string, cmdArgs []string, vscode, force, printOnly bool, label string) int {
	entry := mcpEntry{Command: command, Args: cmdArgs}
	if vscode {
		entry.Type = "stdio"
	}

	if printOnly {
		snippet := map[string]any{parentKey: map[string]any{name: entry}}
		b, err := json.MarshalIndent(snippet, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, "configure: encoding JSON:", err)
			return 1
		}
		fmt.Printf("Would write to: %s\n\n%s\n", path, string(b))
		return 0
	}

	// Load and merge into the existing file, if any.
	root := map[string]any{}
	if pathExists(path) {
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "configure: reading %s: %v\n", path, err)
			return 1
		}
		if len(strings.TrimSpace(string(data))) > 0 {
			if err := json.Unmarshal(data, &root); err != nil {
				fmt.Fprintf(os.Stderr, "configure: %s is not valid JSON: %v\n", path, err)
				return 1
			}
		}
	}

	parent, _ := root[parentKey].(map[string]any)
	if parent == nil {
		parent = map[string]any{}
	}
	if _, exists := parent[name]; exists && !force {
		fmt.Fprintf(os.Stderr, "configure: %s already defines an MCP server named %q (use --force to replace it)\n", path, name)
		return 1
	}
	parent[name] = entry
	root[parentKey] = parent

	b, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "configure: encoding JSON:", err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "configure: creating %s: %v\n", filepath.Dir(path), err)
		return 1
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "configure: writing %s: %v\n", path, err)
		return 1
	}
	fmt.Printf("configured %s -> %s\n", label, path)
	fmt.Printf("Next: restart %s to pick up the MCP server.\n", label)
	return 0
}

// configureTOML writes (or prints) our server as a [mcp_servers.<name>] block in
// a Codex-style config.toml. Text-based merge: it appends the block, refusing to
// replace an existing section of the same name unless force (a best-effort
// section-span removal, since we avoid a TOML dependency).
func configureTOML(path, name, command string, cmdArgs []string, force, printOnly bool, label string) int {
	block := codexTOMLBlock(name, command, cmdArgs)
	if printOnly {
		fmt.Printf("Would write to: %s\n\n%s", path, block)
		return 0
	}

	var existing string
	if pathExists(path) {
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "configure: reading %s: %v\n", path, err)
			return 1
		}
		existing = string(data)
	}

	if tomlHasSection(existing, name) {
		if !force {
			fmt.Fprintf(os.Stderr, "configure: %s already defines a [mcp_servers.%s] section (use --force to replace it)\n", path, tomlKey(name))
			return 1
		}
		existing = tomlRemoveSection(existing, name)
	}

	out := existing
	out = strings.TrimRight(out, "\n")
	if out != "" {
		out += "\n\n"
	}
	out += block
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "configure: creating %s: %v\n", filepath.Dir(path), err)
		return 1
	}
	if err := os.WriteFile(path, []byte(out), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "configure: writing %s: %v\n", path, err)
		return 1
	}
	fmt.Printf("configured %s -> %s\n", label, path)
	fmt.Printf("Next: restart %s to pick up the MCP server.\n", label)
	return 0
}

// codexTOMLBlock renders the [mcp_servers.<name>] TOML block.
func codexTOMLBlock(name, command string, cmdArgs []string) string {
	parts := make([]string, len(cmdArgs))
	for i, a := range cmdArgs {
		parts[i] = tomlString(a)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[mcp_servers.%s]\n", tomlKey(name))
	fmt.Fprintf(&b, "command = %s\n", tomlString(command))
	fmt.Fprintf(&b, "args = [%s]\n", strings.Join(parts, ", "))
	return b.String()
}

// tomlSectionHeaders returns the two header forms (bare and quoted) a
// [mcp_servers.<name>] section could take, for text detection/removal.
func tomlSectionHeaders(name string) []string {
	return []string{
		"[mcp_servers." + name + "]",
		`[mcp_servers."` + name + `"]`,
	}
}

func tomlHasSection(content, name string) bool {
	headers := tomlSectionHeaders(name)
	for _, line := range strings.Split(content, "\n") {
		t := strings.TrimSpace(line)
		for _, h := range headers {
			if t == h {
				return true
			}
		}
	}
	return false
}

// tomlRemoveSection drops the [mcp_servers.<name>] header and its body up to the
// next section header (or EOF). Best-effort text edit for --force replacement.
func tomlRemoveSection(content, name string) string {
	headers := map[string]bool{}
	for _, h := range tomlSectionHeaders(name) {
		headers[h] = true
	}
	var out []string
	inSection := false
	for _, line := range strings.Split(content, "\n") {
		t := strings.TrimSpace(line)
		if inSection {
			if strings.HasPrefix(t, "[") {
				inSection = false // next section starts — stop skipping
			} else {
				continue // skip the removed section's body
			}
		}
		if headers[t] {
			inSection = true
			continue // skip the header line itself
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// tomlKey renders a TOML table key: a bare key when it is safe, else quoted.
func tomlKey(name string) string {
	bare := name != ""
	for _, r := range name {
		if !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			bare = false
			break
		}
	}
	if bare {
		return name
	}
	return tomlString(name)
}

// tomlString renders a TOML basic (double-quoted) string, escaping so Windows
// backslash paths survive intact.
func tomlString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// homePath joins rel onto the user's home dir, falling back to a ~-prefixed
// display path when the home dir cannot be resolved (only reached in print/notice
// paths, which never write).
func homePath(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "~/" + filepath.ToSlash(rel)
	}
	return filepath.Join(home, rel)
}
