package main

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/bynine/godot-mcp-go/internal/client"
	"github.com/bynine/godot-mcp-go/internal/ui"
)

// printBanner renders the bare-invocation banner: the butler beside the
// wordmark, the version, and where to go next. Running the binary with no
// arguments at all is a person exploring, not a script (scripts always name
// a command), so this goes to stdout and the caller exits 0. Every other
// path (usage errors, --help, help) still gets the structured help from
// usage(). The lettering is our own wordmark, not the Godot logo (same rule
// as the addon icon), and the art is the approved mascot (mascot.go).
func printBanner() {
	fmt.Print(bannerText(ui.Out, editorLine()))
}

// bannerText lays the text column out beside the mascot, one line per art
// row, with the text starting a row down so the wordmark sits level with
// the hair line rather than above the head. A text column shorter than the
// art leaves the remaining rows to the art alone.
func bannerText(p ui.Palette, editor string) string {
	text := []string{
		p.Heading("Swallowtail") + "   " + p.Dim("v"+cliVersion),
		p.Key("Godot automation. At your service."),
		p.URL("https://regiellis.github.io/godot-mcp-go"),
	}
	if editor != "" {
		text = append(text, editor)
	}
	text = append(text,
		"",
		p.Dim(strings.Repeat("─", 44)),
		"",
		fmt.Sprintf("Type %s to see every command and subcommand.", p.Key("swallowtail help")),
		fmt.Sprintf("%s checks this machine, %s the editor.", p.Key("swallowtail doctor"), p.Key("swallowtail status")),
	)
	art := mascotLines(p)
	const textStartRow = 1
	rows := len(art)
	if n := textStartRow + len(text); n > rows {
		rows = n
	}
	var b strings.Builder
	b.WriteString("\n")
	for i := 0; i < rows; i++ {
		left := strings.Repeat(" ", mascotWidth)
		if i < len(art) {
			left = art[i]
		}
		right := ""
		if t := i - textStartRow; t >= 0 && t < len(text) {
			right = text[t]
		}
		line := "  " + left + "   " + right
		b.WriteString(strings.TrimRight(line, " ") + "\n")
	}
	b.WriteString("\n")
	return b.String()
}

// editorLine gives the banner its live context, the way the engine's own bare
// invocation prints version and device: one line on this project's editor,
// from the same diagnosis the status verdicts use. Outside a project there is
// no editor to speak for, so no line (and no probe of a port that might
// belong to someone else's project).
func editorLine() string {
	p := ui.Out
	cwd := cliWorkingDirectory()
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
