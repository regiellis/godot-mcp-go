package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// placeholderRe matches the fill-in slots of a usage line: <angle-bracket>
// forms and the ALL-CAPS value names (DIR, NAME, N). Applied only to usage
// lines this package authors, never to arbitrary text.
var placeholderRe = regexp.MustCompile(`<[^>]+>|\b[A-Z][A-Z0-9-]*\b`)

// tintSlots paints a usage line's placeholders, the way the engine's own help
// does, so the fixed words read separately from the fill-ins.
func tintSlots(s string, p ui.Palette) string {
	return placeholderRe.ReplaceAllStringFunc(s, p.Slot)
}

// subHelp returns a fs.Usage that renders a local subcommand's help in the
// same shape and palette as the top-level help: heading, usage forms, note
// lines, then the flag table.
func subHelp(fs *flag.FlagSet, oneLiner string, usageLines []string, notes ...string) func() {
	return func() {
		p := ui.Err
		w := os.Stderr
		fmt.Fprintln(w, p.Heading("godot-mcp "+fs.Name())+" — "+oneLiner)
		fmt.Fprintln(w)
		fmt.Fprintln(w, p.Heading("Usage:"))
		for _, u := range usageLines {
			fmt.Fprintln(w, "  "+tintSlots(u, p))
		}
		for _, n := range notes {
			fmt.Fprintln(w)
			fmt.Fprintln(w, n)
		}
		fmt.Fprintln(w)
		fmt.Fprintln(w, p.Heading("Flags:"))
		printFlagTable(w, p, fs.VisitAll)
	}
}

// parseSub parses a subcommand's args, treating a leading bare "help" like
// --help (so `godot-mcp create help` shows help instead of running). It
// returns -1 to continue, 0 when help was shown, 2 on a bad flag.
func parseSub(fs *flag.FlagSet, args []string) int {
	if len(args) > 0 && args[0] == "help" {
		fs.Usage()
		return 0
	}
	switch err := fs.Parse(args); {
	case errors.Is(err, flag.ErrHelp):
		return 0
	case err != nil:
		return 2
	}
	return -1
}

// printFlagTable renders a flag set as an aligned, accent-keyed table using
// the -- form the docs use. visit is flag.VisitAll (globals) or fs.VisitAll.
// Zero-value defaults stay silent; real ones print dim.
func printFlagTable(w io.Writer, p ui.Palette, visit func(fn func(*flag.Flag))) {
	type row struct{ label, use, def string }
	var rows []row
	labelW := 0
	visit(func(f *flag.Flag) {
		typ, use := flag.UnquoteUsage(f)
		label := "--" + f.Name
		if typ != "" {
			label += " " + typ
		}
		def := ""
		if f.DefValue != "" && f.DefValue != "0" && f.DefValue != "false" {
			def = " (default " + f.DefValue + ")"
		}
		rows = append(rows, row{label, use, def})
		labelW = max(labelW, len(label))
	})
	for _, r := range rows {
		fmt.Fprintf(w, "  %s  %s%s\n", p.Key(padRight(r.label, labelW)), r.use, p.Dim(r.def))
	}
}
