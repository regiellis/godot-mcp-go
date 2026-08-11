package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// printBanner renders the bare-invocation banner: the wordmark, the version,
// and where to go next. Running the binary with no arguments at all is a
// person exploring, not a script (scripts always name a command), so this
// goes to stdout and the caller exits 0. Every other path — usage errors,
// --help, help — still gets the structured help from usage(). The lettering
// is our own wordmark, not the Godot logo (same rule as the addon icon).
func printBanner() {
	p := ui.Out
	// The tile is the brand mark (website/public/brand/mark.svg) in block
	// glyphs: frame and chevron in the accent, the cursor bar plain, the
	// status dot green.
	logo := []string{
		p.Heading("▛▀▀▀▀▀▀▀") + p.OK("●") + p.Heading("▜"),
		p.Heading("▌") + "        " + p.Heading("▐"),
		p.Heading("▌  ❯") + "     " + p.Heading("▐"),
		p.Heading("▌") + "     " + "▄▄" + " " + p.Heading("▐"),
		p.Heading("▌") + "        " + p.Heading("▐"),
		p.Heading("▙▄▄▄▄▄▄▄▄▟"),
	}
	art := []string{
		" ██████╗  ██████╗ ██████╗  ██████╗ ████████╗",
		"██╔════╝ ██╔═══██╗██╔══██╗██╔═══██╗╚══██╔══╝",
		"██║  ███╗██║   ██║██║  ██║██║   ██║   ██║",
		"██║   ██║██║   ██║██║  ██║██║   ██║   ██║",
		"╚██████╔╝╚██████╔╝██████╔╝╚██████╔╝   ██║",
		" ╚═════╝  ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝",
	}
	fmt.Println()
	for i := range art {
		fmt.Println("  " + logo[i] + "  " + p.Heading(art[i]))
	}
	fmt.Println()
	fmt.Println("  " + p.Key("M C P C L I") + "   " + p.Dim("v"+cliVersion))
	fmt.Println("  " + p.URL("https://regiellis.github.io/godot-mcp-go"))
	if line := editorLine(); line != "" {
		fmt.Println("  " + line)
	}
	fmt.Println()
	fmt.Println("  " + p.Dim(strings.Repeat("─", 44)))
	fmt.Println()
	fmt.Printf("  Type %s to see every command and subcommand.\n", p.Key("godot-mcp help"))
	fmt.Printf("  %s checks this machine, %s the editor.\n", p.Key("godot-mcp doctor"), p.Key("godot-mcp status"))
	fmt.Println()
}

// editorLine gives the banner its live context, the way the engine's own bare
// invocation prints version and device: one line on this project's editor,
// from the same diagnosis the status verdicts use. Outside a project there is
// no editor to speak for, so no line (and no probe of a port that might
// belong to someone else's project).
func editorLine() string {
	p := ui.Out
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	root, err := client.FindProjectRoot(cwd)
	if err != nil {
		return ""
	}
	st := client.Diagnose(cwd, 0)
	if st.ProjectMatch != nil && !*st.ProjectMatch {
		return p.Warn("●") + fmt.Sprintf(" port %d serves %s, not this project", st.Port, st.ProjectPath)
	}
	switch st.Verdict {
	case client.VerdictRunning:
		s := p.OK("●") + fmt.Sprintf(" editor running: %s on port %d", filepath.Base(root), st.Port)
		if st.PID > 0 {
			s += p.Dim(fmt.Sprintf(" (pid %d)", st.PID))
		}
		return s
	case client.VerdictStarting:
		return p.Warn("●") + fmt.Sprintf(" editor starting on port %d", st.Port)
	case client.VerdictCrashed:
		return p.Fail("●") + " editor crashed" + p.Dim(fmt.Sprintf(" (stale pid %d, port %d)", st.PID, st.Port))
	default:
		return p.Dim("○ no editor running for " + filepath.Base(root))
	}
}
