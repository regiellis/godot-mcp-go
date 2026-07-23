package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/dashboard"
)

// runDashboard starts the opt-in stats dashboard: an HTTP server that polls the
// editor addon's stats.snapshot and serves a live page. Long-lived.
func runDashboard(args []string) int {
	fs := flag.NewFlagSet("dashboard", flag.ContinueOnError)
	httpPort := fs.Int("port", 8090, "dashboard HTTP port")
	addonPort := fs.Int("addon-port", 0, "addon WebSocket port (0 = discover from --project/cwd)")
	project := fs.String("project", "", "Godot project dir for addon discovery (default: cwd)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "godot-mcp dashboard — live stats web dashboard\n\nUsage:\n  godot-mcp dashboard [--port 8090] [--project DIR] [--addon-port N]\n\nFlags:")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	cwd := *project
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	resolve := func() int { return client.ResolvePort(*addonPort, cwd) }

	if err := dashboard.Run(*httpPort, resolve); err != nil {
		fmt.Fprintln(os.Stderr, "dashboard:", err)
		return 1
	}
	return 0
}
