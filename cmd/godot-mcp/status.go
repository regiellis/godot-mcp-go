package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// runStatus is a local subcommand (it never dials through the addon) that reports
// whether the editor is reachable and, if not, whether it crashed or was closed
// cleanly. Agents run this as a preflight before deciding to (re)launch, so they
// never stack a second editor onto a running one, and can tell a crash from a
// deliberate close. Exit 0 when reachable, 1 otherwise.
func runStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	port := fs.Int("port", 0, "addon WebSocket port (0 = env/discovery/default)")
	project := fs.String("project", "", "Godot project dir (default: cwd)")
	all := fs.Bool("all", false, "scan the editor (9080-9095) and game (9200-9215) ranges plus pinned ports and list every live instance")
	fs.Usage = subHelp(fs, "editor liveness preflight",
		[]string{
			"godot-mcp status [--project DIR] [--port N]",
			"godot-mcp status --all",
		},
		`The verdict (running / starting / crashed / closed) drives the launch policy:
never start a second editor when one is running. Exit 0 when reachable.`)
	if rc := parseSub(fs, args); rc >= 0 {
		return rc
	}
	cwd := *project
	if cwd == "" {
		cwd, _ = os.Getwd()
	}

	if *all {
		return runStatusAll(cwd)
	}

	st := client.Diagnose(cwd, *port)
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 2
	}
	fmt.Println(string(b))
	if st.Reachable {
		return 0
	}
	return 1
}

// runStatusAll lists every live godot-mcp instance on this machine: editors
// found across the auto range and pinned ports (identified via project.info),
// and direct game servers (TCP presence only, since that channel has no identity
// to ask for). A terminal gets the table render; piped output is JSON, same
// contract as command results. Exit 0 when at least one editor is live.
func runStatusAll(cwd string) int {
	editors, games := client.ScanInstances(context.Background(), cwd)

	// Empty scans render as [] rather than null, which is kinder to jq and typed parsers.
	if editors == nil {
		editors = []client.EditorInstance{}
	}
	if games == nil {
		games = []client.GameInstance{}
	}

	if !ui.IsTerminal(os.Stdout) {
		payload := struct {
			Editors []client.EditorInstance `json:"editors"`
			Games   []client.GameInstance   `json:"games"`
		}{editors, games}
		b, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 2
		}
		fmt.Println(string(b))
	} else {
		if len(editors) == 0 {
			fmt.Println(ui.Out.Heading("editors") + " " + ui.Out.Dim("(none live in 9080-9095 or on pinned ports)"))
		} else if b, err := json.Marshal(editors); err == nil {
			if out, perr := renderPretty("editors", b, ui.Out); perr == nil {
				fmt.Println(out)
			}
		}
		if len(games) > 0 {
			fmt.Println()
			for _, g := range games {
				fmt.Printf("%s direct game server on port %s\n", ui.Out.Heading("game"), ui.Out.Key(fmt.Sprint(g.Port)))
			}
		}
	}

	if len(editors) > 0 {
		return 0
	}
	return 1
}
