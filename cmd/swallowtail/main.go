// Command swallowtail is the CLI that drives a running Godot editor via the MCP
// addon. It maps `<group> <command> [--param value ...]` to the addon's dotted
// JSON-RPC methods (<group>.<command>) and prints the result.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/protocol"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// cliVersion is reported to MCP clients in the initialize handshake. Keep it in
// step with the addon's plugin.cfg version and the CHANGELOG heading at release
// time; the addon reads its own from plugin.cfg, so this is the only literal.
const cliVersion = "0.13.0"

func main() {
	if strings.EqualFold(strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe"), "godot-mcp") && ui.IsTerminal(os.Stdout) && ui.IsTerminal(os.Stderr) {
		if legacyNoticeAllowed(os.Args[1:]) {
			fmt.Fprintln(os.Stderr, "godot-mcp is deprecated; use swallowtail. Both commands run the same implementation.")
		}
	}

	flag.CommandLine.Init(os.Args[0], flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	project := flag.String("project", "", "target Godot project for editor commands and local project subcommands")
	paramsFile := flag.String("params-file", "", "editor params JSON object from a file, or - for stdin; explicit params override its keys")
	port := flag.Int("port", 0, "addon WebSocket port (0 = env SWALLOWTAIL_PORT, then discovery file, then default 9080)")
	timeout := flag.Duration("timeout", 30*time.Second, "request timeout")
	format := flag.String("format", "", "result format for the <group> <command> path: pretty (tables/color, the terminal default), json (the piped default), tsv, or ndjson; env SWALLOWTAIL_FORMAT applies when the flag is unset")
	game := flag.Bool("game", false, "route runtime.*/input.* to the running game's direct server (no editor); port resolves via --port, SWALLOWTAIL_GAME_PORT, the game discovery file, then 9200")
	version := flag.Bool("version", false, "print the CLI version and exit")
	flag.StringVar(&cliErrorFormat, "errors", "text", "editor-command stderr: text or json (global flag)")
	flag.Usage = usage
	if parseErr := flag.CommandLine.Parse(os.Args[1:]); parseErr != nil {
		if errors.Is(parseErr, flag.ErrHelp) {
			return
		}
		emitCLIError("usage", parseErr.Error(), nil)
		os.Exit(2)
	}

	if *version {
		os.Exit(runVersion(nil))
	}

	if cliErrorFormat != "text" && cliErrorFormat != "json" {
		emitCLIError("usage", "--errors must be text or json", nil)
		os.Exit(2)
	}
	if *timeout <= 0 {
		emitCLIError("usage", "--timeout must be positive", nil)
		os.Exit(2)
	}
	var projectErr error
	cliProjectRoot, projectErr = resolveCLIProject(*project)
	if projectErr != nil {
		emitCLIError("usage", "--project: "+projectErr.Error(), nil)
		os.Exit(2)
	}
	args := flag.Args()
	// Nothing at all is a person at the front door, not a usage mistake.
	if len(args) == 0 {
		if *paramsFile != "" {
			emitCLIError("usage", "--params-file requires a group and command", nil)
			os.Exit(2)
		}
		printBanner()
		return
	}
	// Local subcommands (not <group> <command>).
	localSubs := map[string]func([]string) int{
		"create":         runCreate,
		"completion":     runCompletion,
		"__complete":     runComplete,
		"install":        runInstall,
		"install-assets": runInstallAssets,
		"migrate":        runMigrate,
		"configure":      runConfigure,
		"serve":          runServe,
		"dashboard":      runDashboard,
		"launch":         runLaunch,
		"run":            runRun,
		"import":         runImport,
		"check":          runCheck,
		"test":           runTest,
		"export":         runExport,
		"upgrade":        runUpgrade,
		"status":         runStatus,
		"doctor":         runDoctor,
		"automate":       runAutomate,
		"version":        runVersion,
	}
	if fn, ok := localSubs[args[0]]; ok && !routesToAddon(args[0], args[1:]) {
		if *paramsFile != "" {
			emitCLIError("usage", "--params-file applies to <group> <command>, not local subcommands", nil)
			os.Exit(2)
		}
		rest := args[1:]
		if cliProjectRoot != "" && args[0] != "__complete" && args[0] != "completion" && args[0] != "version" {
			if args[0] == "upgrade" {
				if len(rest) > 0 && slices.Contains(upgradeCompletionFlags[rest[0]], "--project") {
					rest = append([]string{rest[0], "--project", cliProjectRoot}, rest[1:]...)
				}
			} else if !slices.Contains(localCompletionFlags[args[0]], "--project") {
				emitCLIError("usage", "this subcommand does not accept --project; use its own help", nil)
				os.Exit(2)
			}
			if args[0] != "upgrade" {
				rest = append([]string{"--project", cliProjectRoot}, rest...)
			}
		}
		os.Exit(fn(rest))
	}
	// Nested help: `help [group [command]]`, `<group> --help`, `<group> help`,
	// `<group> <command> --help`. A subcommand name routes to that subcommand's
	// own help; the command catalog lives in the addon, so group help lists it
	// live (see runHelp).
	if len(args) >= 1 && args[0] == "help" {
		if len(args) == 1 {
			usage()
			os.Exit(0)
		}
		if fn, ok := localSubs[args[1]]; ok && len(args) == 2 {
			os.Exit(fn([]string{"help"}))
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

	// Resolution: flag > SWALLOWTAIL_FORMAT > auto (the human render on a
	// terminal, exact JSON when piped, so agents and pipelines never see
	// layout or color they'd have to strip). A bad env value warns and falls
	// through to auto rather than breaking every call in that shell.
	if *format == "" {
		if env := strings.TrimSpace(client.Env("SWALLOWTAIL_FORMAT")); env != "" {
			if validFormat(env) {
				*format = env
			} else {
				fmt.Fprintf(os.Stderr, "%s ignoring SWALLOWTAIL_FORMAT=%q (want pretty, json, tsv, or ndjson)\n", ui.Err.Warn("warning:"), env)
			}
		}
	}
	if *format == "" {
		if ui.IsTerminal(os.Stdout) {
			*format = "pretty"
		} else {
			*format = "json"
		}
	}
	if !validFormat(*format) {
		emitCLIError("usage", fmt.Sprintf("unknown --format %q (want pretty, json, tsv, or ndjson)", *format), nil)
		os.Exit(2)
	}

	params, err := parseParams(args[2:])
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		os.Exit(2)
	}

	if *paramsFile != "" {
		input, inputErr := readParamsInput(*paramsFile, os.Stdin)
		if inputErr != nil {
			emitCLIError("usage", inputErr.Error(), nil)
			os.Exit(2)
		}
		maps.Copy(input, params)
		params = input
	}
	cwd := cliWorkingDirectory()
	var resolved int
	var portRes client.Resolution
	if *game {
		resolved, err = client.ResolveGamePort(*port, cwd)
	} else {
		portRes = client.ResolvePortSource(*port, cwd)
		resolved = portRes.Port
		err = portRes.Err
	}
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		os.Exit(2)
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
	interruptCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(interruptCtx, deadline)
	defer cancel()

	// Confirm whose editor is answering before the call mutates anything. Skipped
	// when the port came from this project's own live discovery file, which is the
	// common case and costs nothing.
	if !*game {
		if cliProjectRoot != "" {
			portRes.Disc = nil
		}
		if mm := client.CheckProject(ctx, portRes); mm != nil {
			if cliErrorFormat == "json" {
				emitCLIError("project", mm.Error(), map[string]any{"expected": mm.Expected, "answering": mm.Answering, "action": mm.Action()})
			} else {
				printMismatch(mm)
			}
			if mm.Fatal() || cliProjectRoot != "" {
				os.Exit(1)
			}
		}
	}

	result, err := client.Call(ctx, resolved, method, params)
	if err != nil {
		var de *client.DialError
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			printError(err)
		} else if errors.As(err, &de) {
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
			emitCLIError("output", "rendering result as tsv: "+terr.Error(), nil)
			os.Exit(1)
		}
		fmt.Println(tsv)
		return
	}

	if *format == "ndjson" {
		nd, nerr := formatNDJSON(result)
		if nerr != nil {
			emitCLIError("output", "rendering result as ndjson: "+nerr.Error(), nil)
			os.Exit(1)
		}
		fmt.Println(nd)
		return
	}

	if *format == "pretty" {
		out, perr := renderPretty(method, result, ui.Out)
		if perr != nil {
			// A shape the renderer can't handle still prints, as the raw JSON.
			fmt.Println(string(result))
			return
		}
		fmt.Println(out)
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

// Keep protocol streams and explicitly structured output free of notices.
func legacyNoticeAllowed(args []string) bool {
	for _, arg := range args {
		if arg == "serve" || arg == "__complete" || arg == "completion" || arg == "--json" || arg == "--errors" || strings.HasPrefix(arg, "--errors=") || arg == "--format" || strings.HasPrefix(arg, "--format=") {
			return false
		}
	}
	return client.Env("SWALLOWTAIL_FORMAT") == ""
}

// shadowedAddonCommands lists the addon commands whose group shares a name with
// a local subcommand. `swallowtail export` runs the headless export while
// `swallowtail export info` still reaches the addon's export group, and the same
// for import. Both groups are closed sets of three, which is why naming them
// here beats a general rule: the local export's own argument is a preset name,
// so nothing else in that position can be told apart offline.
//
// A preset genuinely named "info" or "project" is reachable as
// `swallowtail export --preset info`, which takes no positional at all.
var shadowedAddonCommands = map[string][]string{
	"export": {"list_presets", "project", "info"},
	"import": {"info", "set", "reimport"},
	"test":   {"run_scenario", "assert_node_state", "assert_screen_text", "run_stress_test", "report"},
}

// routesToAddon reports whether an invocation of a local subcommand's name is
// really a <group> <command> call for the addon group of the same name.
func routesToAddon(name string, rest []string) bool {
	cmds, shadowed := shadowedAddonCommands[name]
	if !shadowed || len(rest) == 0 {
		return false
	}
	first := strings.ReplaceAll(rest[0], "-", "_")
	return slices.Contains(cmds, first)
}

// runVersion prints the binary's version, the same string serve reports in the
// MCP handshake. Reached as `swallowtail version` and as the --version flag, since
// both spellings are reflexes and the flag used to fail the parse outright. The
// addon carries its own version in plugin.cfg, which project.info reports.
func runVersion([]string) int {
	fmt.Println("swallowtail " + cliVersion)
	return 0
}

// validFormat reports whether s names a result format the CLI can render.
func validFormat(s string) bool {
	switch s {
	case "pretty", "json", "tsv", "ndjson":
		return true
	}
	return false
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
// catalog (and the per-command param docs, where a group carries them) lives
// in the addon and this lists it live, which needs a running editor.
func runHelp(port int, group, command string) int {
	group = strings.ReplaceAll(strings.TrimPrefix(group, "--"), "-", "_")
	command = strings.ReplaceAll(command, "-", "_")
	if rc, handled := runCatalogHelp(port, group, command); handled {
		return rc
	}

	cwd := cliWorkingDirectory()
	resolved, err := client.ResolvePort(port, cwd)
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if group == "all" {
		methods, err := fetchMethods(ctx, resolved)
		if err != nil {
			return helpFetchError(err, cwd, resolved)
		}
		byGroup := groupMethods(methods)
		names := slices.Sorted(maps.Keys(byGroup))
		w := 14
		for _, g := range names {
			w = max(w, len(g))
		}
		fmt.Printf("%s: %d commands in %d groups (live from the addon):\n\n",
			ui.Out.Heading("swallowtail"), len(methods), len(names))
		for _, g := range names {
			fmt.Printf("  %s %s\n", ui.Out.Key(padRight(g, w)), strings.Join(byGroup[g], ", "))
		}
		fmt.Println("\n" + ui.Out.Dim("Usage: swallowtail <group> <command> [--param value ...]"))
		fmt.Println(ui.Out.Dim("swallowtail <group> --help narrows to one group; JSON form: swallowtail engine commands."))
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
			fmt.Fprintf(os.Stderr, "unknown command %q in group %q. Commands: %s\n",
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
	fmt.Fprintf(os.Stderr, "%s unknown group %q. %d groups registered (swallowtail help all lists their commands):\n",
		ui.Err.Fail("error:"), group, len(names))
	for _, g := range names {
		fmt.Fprintf(os.Stderr, "  %s %d commands\n", ui.Err.Key(padRight(g, 14)), len(byGroup[g]))
	}
}

// printGroupHelp lists a group's commands with one-line descriptions where the
// addon carries docs; groups without docs keep the generic dynamic-params hint.
func printGroupHelp(group string, cmds []string, docs map[string]commandDoc) {
	fmt.Printf("%s: %d commands (addon catalog):\n\n", ui.Out.Heading("swallowtail "+group), len(cmds))
	w := 0
	for _, c := range cmds {
		w = max(w, len(c))
	}
	for _, c := range cmds {
		if d := docs[group+"."+c].Description; d != "" {
			fmt.Printf("  %s  %s\n", ui.Out.Key(padRight(c, w)), d)
		} else {
			fmt.Printf("  %s\n", ui.Out.Key(c))
		}
	}
	kebab := strings.ReplaceAll(group, "_", "-")
	fmt.Println("\n" + ui.Out.Dim(fmt.Sprintf("Usage: swallowtail %s <command> [--param value ...]   (kebab-case works too)", kebab)))
	fmt.Println(ui.Out.Dim(fmt.Sprintf("Per-command params: swallowtail %s <command> --help", kebab)))
	if len(docs) == 0 {
		fmt.Println()
		printParamHint()
	}
}

// printCommandHelp renders one command's param table from the addon's docs, or
// the generic dynamic-params hint when the command has no authored docs yet.
func printCommandHelp(group, command string, doc commandDoc) {
	head := ui.Out.Heading(fmt.Sprintf("swallowtail %s %s", group, command))
	if doc.Description != "" {
		fmt.Printf("%s: %s\n", head, doc.Description)
	} else {
		fmt.Printf("%s: registered as %s.%s (addon catalog)\n", head, group, command)
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
	fmt.Println("\n" + ui.Out.Heading("Params:"))
	nameW, typeW := 0, 0
	for _, p := range doc.Params {
		nameW = max(nameW, len(p.Name)+2) // +2 for the -- prefix
		typeW = max(typeW, len(p.Type))
	}
	for _, p := range doc.Params {
		flagName := "--" + strings.ReplaceAll(p.Name, "_", "-")
		req := ui.Out.Dim(padRight("optional", 8))
		if p.Required {
			req = ui.Out.Warn(padRight("required", 8))
		}
		fmt.Printf("  %s  %s  %s  %s\n",
			ui.Out.Key(padRight(flagName, nameW)), ui.Out.Dim(padRight(p.Type, typeW)), req, p.Desc)
	}
}

// printParamHint explains how to find a command's params: they are dynamic
// (the addon coerces values toward the target type), so there is no static
// flag table to print.
func printParamHint() {
	fmt.Println(`Params are dynamic: --key value / --key=value, bare --flag for booleans,
Godot literals as strings (--value "Vector2(100, 200)"), JSON for arrays/objects.
Running a command without its required params returns an error naming them.
Recipes and full catalog: the swallowtail skill (skills/swallowtail/SKILL.md).`)
}

// paramDoc / commandDoc mirror the addon's get_command_docs() shape.
type paramDoc struct {
	Name     string         `json:"name"`
	Type     string         `json:"type"`
	Required bool           `json:"required"`
	Desc     string         `json:"desc"`
	Schema   map[string]any `json:"schema,omitempty"`
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
func printError(err error) { cliRPCError(err) }

// printDiagnosis renders a dial-failure verdict (crashed / closed / starting) to
// stderr: a human line, the agent guidance, and the JSON status so a tool-driving
// agent can parse the verdict instead of guessing whether to relaunch.
func printDiagnosis(st client.Status) {
	if cliErrorFormat == "json" {
		emitCLIError("connection", st.Message, struct {
			client.Status
			Outcome string `json:"outcome"`
		}{st, "not_sent"})
		return
	}
	fmt.Fprintf(os.Stderr, "%s editor not reachable [%s]: %s\n",
		ui.Err.Fail("error:"), styleVerdict(st.Verdict, ui.Err), st.Message)
	fmt.Fprintln(os.Stderr, st.Action)
	if b, err := json.MarshalIndent(st, "", "  "); err == nil {
		fmt.Fprintln(os.Stderr, ui.Err.Dim(string(b)))
	}
}

// styleVerdict colors a liveness verdict as its severity: crashed red,
// starting yellow, running green, closed (a clean non-state) dim.
func styleVerdict(v client.Verdict, p ui.Palette) string {
	switch v {
	case client.VerdictRunning:
		return p.OK(string(v))
	case client.VerdictStarting:
		return p.Warn(string(v))
	case client.VerdictCrashed:
		return p.Fail(string(v))
	default:
		return p.Dim(string(v))
	}
}

// printMismatch reports that the editor answering is serving another project.
// A guessed port aborts the command; an explicitly targeted one warns and
// continues, since asking for that port is a statement of intent.
func printMismatch(mm *client.ProjectMismatch) {
	label := ui.Err.Warn("warning:")
	if mm.Fatal() {
		label = ui.Err.Fail("error:")
	}
	fmt.Fprintf(os.Stderr, "%s wrong editor: %s\n", label, mm.Error())
	fmt.Fprintf(os.Stderr, "port %d came from: %s\n", mm.Port, mm.Source)
	fmt.Fprintln(os.Stderr, mm.Action())
}

// printGameDialError reports a failed dial on the --game channel. Unlike the
// editor channel there is no discovery-file lifecycle to derive a crash/close
// verdict from, so it names the three things that make the game unreachable.
func printGameDialError(port int) {
	if cliErrorFormat == "json" {
		emitCLIError("connection", fmt.Sprintf("could not reach the game's direct server on 127.0.0.1:%d", port), map[string]any{
			"port": port, "outcome": "not_sent", "action": "Start a debug game with swallowtail/runtime/direct_server enabled; --game targets the game, not the editor.",
		})
		return
	}
	fmt.Fprintf(os.Stderr, "%s could not reach the game's direct server on 127.0.0.1:%d\n", ui.Err.Fail("error:"), port)
	fmt.Fprintln(os.Stderr, "--game talks to a running game, not the editor. Check that:")
	fmt.Fprintln(os.Stderr, "  - the game is actually running")
	fmt.Fprintln(os.Stderr, "  - it was launched as a debug build (an exported release build never serves this)")
	fmt.Fprintln(os.Stderr, "  - the swallowtail/runtime/direct_server project setting is enabled")
}

// usage renders the top-level help: name line, usage forms, subcommand table,
// examples, and the global flags, each section aligned and color-coded like
// the rest of the help surfaces. It goes to stderr (usage errors exit 2).
func usage() {
	p := ui.Err
	w := os.Stderr

	fmt.Fprintln(w, p.Heading("swallowtail")+": automate Godot from your terminal")
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Usage:"))
	fmt.Fprintln(w, "  "+tintSlots("swallowtail [flags] <group> <command> [--param value ...]", p))
	fmt.Fprintln(w, "  "+tintSlots("swallowtail <subcommand> [flags]", p))

	subs := [][2]string{
		{"create", "bootstrap a new Godot 4.7 project (--install adds the addon, --enable turns it on)"},
		{"install", "copy the addon + agent skill into a project"},
		{"migrate", "preview, apply, or roll back a legacy addon migration"},
		{"install-assets", "copy bundled CC0 asset packs into a project (assets/vendor/)"},
		{"configure", "write an MCP-server config for claude, cursor, vscode, or codex"},
		{"serve", "MCP over stdio for AI clients"},
		{"dashboard", "live stats web UI"},
		{"launch", "launch one editor for this project, respecting the discovery verdict (never stacks)"},
		{"run", "run the game standalone, no editor, and report its direct-server port"},
		{"import", "import the project's assets headlessly (import info/set/reimport still reach the addon)"},
		{"check", "parse .gd files cold with --check-only, in parallel"},
		{"test", "run pure-logic GDScript tests cold (test.* scenario commands still reach the addon)"},
		{"export", "export a preset headlessly (export list-presets/project/info still reach the addon)"},
		{"upgrade", "port a 4.3+ project to a newer Godot: preflight, baseline, open, fix, verify"},
		{"status", "editor liveness preflight: running, starting, crashed, or closed (--all lists every live instance)"},
		{"doctor", "environment preflight: binary, project, addon, port, editor, dotnet"},
		{"automate", "run a JSON command plan with preflight checks, assertions, and step reports"},
		{"version", "print the CLI version (--version does the same)"},
		{"completion", "generate Bash or PowerShell shell completion"},
		{"help", "help all, or help <group> [<command>] (live catalog, or project cache offline)"},
	}
	nameW := 0
	for _, s := range subs {
		nameW = max(nameW, len(s[0]))
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Subcommands:"))
	for _, s := range subs {
		fmt.Fprintf(w, "  %s  %s\n", p.Key(padRight(s[0], nameW)), s[1])
	}

	examples := [][2]string{
		{"swallowtail project info", ""},
		{"swallowtail scene tree", ""},
		{"swallowtail node add --type Sprite2D --name Player --parent-path .", ""},
		{`swallowtail node set --node-path Player --property position --value "Vector2(100, 200)"`, ""},
		{"swallowtail node --help", "one group's commands and params, live"},
		{"swallowtail create --path ./mygame --install", "new project with the addon in place"},
		{"swallowtail --game runtime tree", "drive a STANDALONE running game (no editor)"},
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Examples:"))
	for _, e := range examples {
		if e[1] == "" {
			fmt.Fprintf(w, "  %s\n", e[0])
		} else {
			fmt.Fprintf(w, "  %s   %s\n", e[0], p.Dim("# "+e[1]))
		}
	}

	fmt.Fprintln(w)
	fmt.Fprintln(w, p.Heading("Flags")+" "+p.Dim("(before the group; groups and commands accept kebab-case):"))
	printFlagTable(w, p, flag.VisitAll)
}
