// Command godot-mcp is the CLI that drives a running Godot editor via the MCP
// addon. It maps `<group> <command> [--param value ...]` to the addon's dotted
// JSON-RPC methods (<group>.<command>) and prints the result.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"maps"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
)

func main() {
	port := flag.Int("port", 0, "addon WebSocket port (0 = env GODOT_MCP_PORT, then discovery file, then default 9080)")
	timeout := flag.Duration("timeout", 30*time.Second, "request timeout")
	format := flag.String("format", "json", "result format for the <group> <command> path: json (pretty) or tsv")
	game := flag.Bool("game", false, "route runtime.*/input.* to the running game's direct server (no editor); port resolves via --port, GODOT_MCP_GAME_PORT, the game discovery file, then 9200")
	flag.Usage = usage
	flag.Parse()

	args := flag.Args()
	// Local subcommands (not <group> <command>).
	if len(args) >= 1 && args[0] == "create" {
		os.Exit(runCreate(args[1:]))
	}
	if len(args) >= 1 && args[0] == "install" {
		os.Exit(runInstall(args[1:]))
	}
	if len(args) >= 1 && args[0] == "install-assets" {
		os.Exit(runInstallAssets(args[1:]))
	}
	if len(args) >= 1 && args[0] == "configure" {
		os.Exit(runConfigure(args[1:]))
	}
	if len(args) >= 1 && args[0] == "serve" {
		os.Exit(runServe(args[1:]))
	}
	if len(args) >= 1 && args[0] == "dashboard" {
		os.Exit(runDashboard(args[1:]))
	}
	if len(args) >= 1 && args[0] == "status" {
		os.Exit(runStatus(args[1:]))
	}
	if len(args) >= 1 && args[0] == "doctor" {
		os.Exit(runDoctor(args[1:]))
	}
	// Nested help: `help [group [command]]`, `<group> --help`, `<group> help`,
	// `<group> <command> --help`. The catalog lives in the addon, so these list
	// it live (see runHelp).
	if len(args) >= 1 && args[0] == "help" {
		if len(args) == 1 {
			usage()
			os.Exit(0)
		}
		cmd := ""
		if len(args) >= 3 {
			cmd = args[2]
		}
		os.Exit(runHelp(*port, args[1], cmd))
	}
	if hi := helpIndex(args); hi > 0 {
		cmd := ""
		if hi >= 2 {
			cmd = args[1]
		}
		os.Exit(runHelp(*port, args[0], cmd))
	}
	if len(args) < 2 {
		usage()
		os.Exit(2)
	}
	// Methods are dotted snake_case; allow kebab-case on the CLI (node set-anchor).
	group := strings.ReplaceAll(args[0], "-", "_")
	command := strings.ReplaceAll(args[1], "-", "_")
	method := group + "." + command

	if *format != "json" && *format != "tsv" {
		fmt.Fprintf(os.Stderr, "error: unknown --format %q (want json or tsv)\n", *format)
		os.Exit(2)
	}

	params, err := parseParams(args[2:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	cwd, _ := os.Getwd()
	var resolved int
	if *game {
		resolved = client.ResolveGamePort(*port, cwd)
	} else {
		resolved = client.ResolvePort(*port, cwd)
	}

	// A dotnet build's first NuGet restore can run minutes; floor the default
	// timeout for build-backed methods unless the user set -timeout explicitly.
	userTimeout := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "timeout" {
			userTimeout = true
		}
	})
	deadline := *timeout
	if !userTimeout {
		deadline = methodTimeout(method, params, deadline)
	}
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()

	result, err := client.Call(ctx, resolved, method, params)
	if err != nil {
		var de *client.DialError
		if errors.As(err, &de) {
			if *game {
				printGameDialError(de.Port)
			} else {
				printDiagnosis(client.Diagnose(cwd, resolved))
			}
		} else {
			printError(err)
		}
		os.Exit(1)
	}

	if *format == "tsv" {
		tsv, terr := formatTSV(result)
		if terr != nil {
			fmt.Fprintln(os.Stderr, "error: rendering result as tsv:", terr)
			os.Exit(1)
		}
		fmt.Println(tsv)
		return
	}

	// Pretty-print the result JSON.
	var pretty json.RawMessage = result
	out, err := json.MarshalIndent(pretty, "", "  ")
	if err != nil {
		fmt.Println(string(result))
		return
	}
	fmt.Println(string(out))
}

// methodTimeout floors the per-call timeout for methods that legitimately run
// long because they proxy `dotnet build`: the csharp group, and script.validate
// on a .cs path (C# validates by building the project).
func methodTimeout(method string, params map[string]any, base time.Duration) time.Duration {
	const buildFloor = 5 * time.Minute
	long := strings.HasPrefix(method, "csharp.")
	if method == "script.validate" {
		if p, ok := params["path"].(string); ok && strings.HasSuffix(strings.ToLower(p), ".cs") {
			long = true
		}
	}
	if long && base < buildFloor {
		return buildFloor
	}
	return base
}

// helpIndex returns the index of the first help token after the group
// (--help / -h anywhere, or a bare "help" directly after the group so a
// positional value that happens to be "help" never triggers it), or -1.
func helpIndex(args []string) int {
	for i, a := range args {
		if i == 0 {
			continue
		}
		if a == "--help" || a == "-h" || (a == "help" && i == 1) {
			return i
		}
	}
	return -1
}

// runHelp prints nested help for `<group>` or `<group> <command>`, or the
// whole catalog grouped by category for `all`. The CLI is deliberately
// generic (adding an addon command needs no CLI change), so the command
// catalog — and the per-command param docs, where a group carries them — lives
// in the addon and this lists it live, which needs a running editor.
func runHelp(port int, group, command string) int {
	group = strings.ReplaceAll(strings.TrimPrefix(group, "--"), "-", "_")
	command = strings.ReplaceAll(command, "-", "_")

	cwd, _ := os.Getwd()
	resolved := client.ResolvePort(port, cwd)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if group == "all" {
		methods, err := fetchMethods(ctx, resolved)
		if err != nil {
			return helpFetchError(err, cwd, resolved)
		}
		byGroup := groupMethods(methods)
		names := slices.Sorted(maps.Keys(byGroup))
		fmt.Printf("godot-mcp — %d commands in %d groups (live from the addon):\n\n", len(methods), len(names))
		for _, g := range names {
			fmt.Printf("  %-14s %s\n", g, strings.Join(byGroup[g], ", "))
		}
		fmt.Println("\nUsage: godot-mcp <group> <command> [--param value ...]")
		fmt.Println("godot-mcp <group> --help narrows to one group; JSON form: godot-mcp engine commands.")
		return 0
	}

	methods, docs, err := fetchGroupDocs(ctx, resolved, group)
	if err != nil {
		var rpc *protocol.Error
		switch {
		case errors.As(err, &rpc) && rpc.Code == -32001:
			// The addon answered: this group doesn't exist. Show what does.
			all, ferr := fetchMethods(ctx, resolved)
			if ferr != nil {
				return helpFetchError(ferr, cwd, resolved)
			}
			printUnknownGroup(group, groupMethods(all))
			return 2
		case errors.As(err, &rpc) && rpc.Code == -32601:
			// Old addon without engine.commands: harvest the flat method list
			// from the -32601 payload (fetchMethods does this); no docs.
			all, ferr := fetchMethods(ctx, resolved)
			if ferr != nil {
				return helpFetchError(ferr, cwd, resolved)
			}
			byGroup := groupMethods(all)
			if len(byGroup[group]) == 0 {
				printUnknownGroup(group, byGroup)
				return 2
			}
			methods = methods[:0]
			for _, c := range byGroup[group] {
				methods = append(methods, group+"."+c)
			}
		default:
			return helpFetchError(err, cwd, resolved)
		}
	}

	var cmds []string
	for _, m := range methods {
		if _, c, ok := strings.Cut(m, "."); ok {
			cmds = append(cmds, c)
		}
	}
	slices.Sort(cmds)

	if command != "" {
		if !slices.Contains(cmds, command) {
			fmt.Fprintf(os.Stderr, "unknown command %q in group %q — commands: %s\n",
				command, group, strings.Join(cmds, ", "))
			return 2
		}
		printCommandHelp(group, command, docs[group+"."+command])
		return 0
	}
	printGroupHelp(group, cmds, docs)
	return 0
}

// helpFetchError reports a failed catalog fetch: a dial failure gets the
// standard editor-unreachable diagnosis, anything else prints as an RPC error.
func helpFetchError(err error, cwd string, port int) int {
	var de *client.DialError
	if errors.As(err, &de) {
		fmt.Fprintln(os.Stderr, "help lists a group's commands live from the addon, so it needs a running editor")
		printDiagnosis(client.Diagnose(cwd, port))
	} else {
		printError(err)
	}
	return 1
}

// groupMethods splits dotted methods into group -> sorted short command names.
func groupMethods(methods []string) map[string][]string {
	byGroup := map[string][]string{}
	for _, m := range methods {
		if g, c, ok := strings.Cut(m, "."); ok {
			byGroup[g] = append(byGroup[g], c)
		}
	}
	for _, cs := range byGroup {
		slices.Sort(cs)
	}
	return byGroup
}

func printUnknownGroup(group string, byGroup map[string][]string) {
	names := slices.Sorted(maps.Keys(byGroup))
	fmt.Fprintf(os.Stderr, "unknown group %q — %d groups registered (godot-mcp help all lists their commands):\n", group, len(names))
	for _, g := range names {
		fmt.Fprintf(os.Stderr, "  %-14s %d commands\n", g, len(byGroup[g]))
	}
}

// printGroupHelp lists a group's commands with one-line descriptions where the
// addon carries docs; groups without docs keep the generic dynamic-params hint.
func printGroupHelp(group string, cmds []string, docs map[string]commandDoc) {
	fmt.Printf("godot-mcp %s — %d commands (live from the addon):\n\n", group, len(cmds))
	w := 0
	for _, c := range cmds {
		w = max(w, len(c))
	}
	for _, c := range cmds {
		if d := docs[group+"."+c].Description; d != "" {
			fmt.Printf("  %-*s  %s\n", w, c, d)
		} else {
			fmt.Printf("  %s\n", c)
		}
	}
	kebab := strings.ReplaceAll(group, "_", "-")
	fmt.Printf("\nUsage: godot-mcp %s <command> [--param value ...]   (kebab-case works too)\n", kebab)
	fmt.Printf("Per-command params: godot-mcp %s <command> --help\n", kebab)
	if len(docs) == 0 {
		fmt.Println()
		printParamHint()
	}
}

// printCommandHelp renders one command's param table from the addon's docs, or
// the generic dynamic-params hint when the command has no authored docs yet.
func printCommandHelp(group, command string, doc commandDoc) {
	head := fmt.Sprintf("godot-mcp %s %s", group, command)
	if doc.Description != "" {
		fmt.Printf("%s — %s\n", head, doc.Description)
	} else {
		fmt.Printf("%s — registered as %s.%s (live from the addon)\n", head, group, command)
	}
	if len(doc.Params) == 0 {
		fmt.Println()
		if doc.Description != "" {
			fmt.Println("Takes no parameters.")
		} else {
			printParamHint()
		}
		return
	}
	fmt.Println("\nParams:")
	nameW, typeW := 0, 0
	for _, p := range doc.Params {
		nameW = max(nameW, len(p.Name)+2) // +2 for the -- prefix
		typeW = max(typeW, len(p.Type))
	}
	for _, p := range doc.Params {
		flagName := "--" + strings.ReplaceAll(p.Name, "_", "-")
		req := "optional"
		if p.Required {
			req = "required"
		}
		fmt.Printf("  %-*s  %-*s  %-8s  %s\n", nameW, flagName, typeW, p.Type, req, p.Desc)
	}
}

// printParamHint explains how to find a command's params: they are dynamic
// (the addon coerces values toward the target type), so there is no static
// flag table to print.
func printParamHint() {
	fmt.Println(`Params are dynamic: --key value / --key=value, bare --flag for booleans,
Godot literals as strings (--value "Vector2(100, 200)"), JSON for arrays/objects.
Running a command without its required params returns an error naming them.
Recipes and full catalog: the godot-mcp skill (skills/godot-mcp/SKILL.md).`)
}

// paramDoc / commandDoc mirror the addon's get_command_docs() shape.
type paramDoc struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Required bool   `json:"required"`
	Desc     string `json:"desc"`
}

type commandDoc struct {
	Description string     `json:"description"`
	Params      []paramDoc `json:"params"`
}

// fetchGroupDocs asks the addon for one group's methods plus their param docs
// (engine.commands attaches docs whenever group is given). Errors pass through
// for the caller to classify (-32001 unknown group, -32601 pre-docs addon).
func fetchGroupDocs(ctx context.Context, port int, group string) ([]string, map[string]commandDoc, error) {
	raw, err := client.Call(ctx, port, "engine.commands", map[string]any{"group": group})
	if err != nil {
		return nil, nil, err
	}
	var payload struct {
		Methods []string              `json:"methods"`
		Docs    map[string]commandDoc `json:"docs"`
	}
	if jerr := json.Unmarshal(raw, &payload); jerr != nil {
		return nil, nil, jerr
	}
	return payload.Methods, payload.Docs, nil
}

// fetchMethods asks the addon for its registered method list, preferring
// engine.commands. An older addon without that command still answers: its
// -32601 reply carries the same list as available_methods.
func fetchMethods(ctx context.Context, port int) ([]string, error) {
	raw, err := client.Call(ctx, port, "engine.commands", nil)
	if err == nil {
		var payload struct {
			Methods []string `json:"methods"`
		}
		if jerr := json.Unmarshal(raw, &payload); jerr != nil {
			return nil, jerr
		}
		return payload.Methods, nil
	}
	var rpc *protocol.Error
	if errors.As(err, &rpc) && rpc.Code == -32601 {
		if avail, ok := rpc.Data["available_methods"].([]any); ok && len(avail) > 0 {
			methods := make([]string, 0, len(avail))
			for _, v := range avail {
				if s, sok := v.(string); sok {
					methods = append(methods, s)
				}
			}
			return methods, nil
		}
	}
	return nil, err
}

// printError writes a JSON-RPC error's message plus any structured data
// (suggestions, available_methods, …) to stderr; transport errors print plainly.
func printError(err error) {
	var rpc *protocol.Error
	if !errors.As(err, &rpc) {
		fmt.Fprintln(os.Stderr, "error:", err)
		return
	}
	fmt.Fprintf(os.Stderr, "error [%d]: %s\n", rpc.Code, rpc.Message)
	if len(rpc.Data) > 0 {
		if b, e := json.MarshalIndent(rpc.Data, "", "  "); e == nil {
			fmt.Fprintln(os.Stderr, string(b))
		}
	}
}

// printDiagnosis renders a dial-failure verdict (crashed / closed / starting) to
// stderr: a human line, the agent guidance, and the JSON status so a tool-driving
// agent can parse the verdict instead of guessing whether to relaunch.
func printDiagnosis(st client.Status) {
	fmt.Fprintf(os.Stderr, "error: editor not reachable [%s] — %s\n", st.Verdict, st.Message)
	fmt.Fprintln(os.Stderr, st.Action)
	if b, err := json.MarshalIndent(st, "", "  "); err == nil {
		fmt.Fprintln(os.Stderr, string(b))
	}
}

// printGameDialError reports a failed dial on the --game channel. Unlike the
// editor channel there is no discovery-file lifecycle to derive a crash/close
// verdict from, so it names the three things that make the game unreachable.
func printGameDialError(port int) {
	fmt.Fprintf(os.Stderr, "error: could not reach the game's direct server on 127.0.0.1:%d\n", port)
	fmt.Fprintln(os.Stderr, "--game talks to a running game, not the editor. Check that:")
	fmt.Fprintln(os.Stderr, "  - the game is actually running")
	fmt.Fprintln(os.Stderr, "  - it was launched as a debug build (an exported release build never serves this)")
	fmt.Fprintln(os.Stderr, "  - the godot_mcp/runtime/direct_server project setting is enabled")
}

func usage() {
	fmt.Fprintln(os.Stderr, `godot-mcp — drive a running Godot editor via the MCP addon

Usage:
  godot-mcp [flags] <group> <command> [--param value ...]

Examples:
  godot-mcp create --path ./mygame --install   # bootstrap a new Godot 4.7 project + addon
  godot-mcp install --project ./mygame      # copy addon + skill into a project
  godot-mcp install-assets --pack kenney_prototype_textures  # greybox textures -> assets/vendor/
  godot-mcp configure claude --project ./mygame   # point an AI client at the stdio MCP server
  godot-mcp project info
  godot-mcp scene tree
  godot-mcp node add --type Sprite2D --name Player --parent-path .
  godot-mcp node set --node-path Player --property position --value "Vector2(100, 200)"
  godot-mcp node --help                     # list a group's commands (live; needs a running editor)
  godot-mcp help <group> [<command>]        # same
  godot-mcp help all                        # every command, grouped (JSON: godot-mcp engine commands)
  godot-mcp --game runtime tree             # drive a STANDALONE running game directly (no editor)

Subcommands: create (bootstrap a new Godot 4.7 project),
install, install-assets (bundled CC0 packs -> assets/vendor/),
configure <client> (write an MCP-server config for claude/cursor/vscode/codex),
serve (MCP over stdio), dashboard (live stats web UI),
status (is the editor running / crashed / closed — preflight before launching),
doctor (environment preflight: godot binary, project, addon, port, editor, dotnet).
Otherwise <group> <command>.
Global flags must precede the group; --format json|tsv sets the result format
(tsv for shell pipelines). --game routes runtime.*/input.* to a standalone
running game's own server (no editor), resolving its port from the game
discovery file (default 9200). Flags:`)
	flag.PrintDefaults()
}
