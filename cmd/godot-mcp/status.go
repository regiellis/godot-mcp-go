package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/bynine/godot-mcp-go/internal/client"
)

// runStatus is a local subcommand (it never dials through the addon) that reports
// whether the editor is reachable and, if not, whether it crashed or was closed
// cleanly. Agents run this as a preflight before deciding to (re)launch — so they
// never stack a second editor onto a running one, and can tell a crash from a
// deliberate close. Exit 0 when reachable, 1 otherwise.
func runStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	port := fs.Int("port", 0, "addon WebSocket port (0 = env/discovery/default)")
	project := fs.String("project", "", "Godot project dir (default: cwd)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	cwd := *project
	if cwd == "" {
		cwd, _ = os.Getwd()
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
