// Package ui holds the CLI's terminal styling: role-named ANSI color tokens
// gated on the stream actually being an interactive terminal. Piped output —
// the agent/pipeline case — always renders plain, so nothing downstream ever
// has to strip escape codes. The serve path never writes through this package;
// its stdout is the MCP transport.
package ui

import "os"

// Palette renders ANSI-styled text for one output stream, or the text
// unchanged when styling is off (piped stream, NO_COLOR, TERM=dumb, or a
// console that cannot process escapes).
type Palette struct{ on bool }

// Plain never styles. Use it in tests and anywhere layout is wanted without
// color.
var Plain = Palette{}

// Out and Err are the palettes for the process's stdout and stderr, probed
// once at startup.
var (
	Out = For(os.Stdout)
	Err = For(os.Stderr)
)

// For probes f and returns a Palette that styles only when f is an
// interactive terminal, the environment does not veto color (NO_COLOR set to
// anything, or TERM=dumb), and the console accepts VT escapes.
func For(f *os.File) Palette {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return Plain
	}
	if !IsTerminal(f) {
		return Plain
	}
	return Palette{on: enableVT(f)}
}

// IsTerminal reports whether f is an interactive terminal (a character
// device). A pipe or file is not, which is what keeps agent-captured output
// plain. Note Git Bash's mintty presents as a pipe, so it renders plain too —
// accepted; PowerShell and Windows Terminal are the interactive surfaces here.
func IsTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// Enabled reports whether this palette emits escapes at all.
func (p Palette) Enabled() bool { return p.on }

func (p Palette) wrap(code, s string) string {
	if !p.on || s == "" {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

// Tokens are named for role, not color, so every surface stays consistent:
// headings and keys/identifiers in the accent (a burnt yellow, 256-color 172 —
// distinct from the plain-yellow warn/number tokens), ok/warn/fail
// traffic-light, numbers yellow, bools magenta, secondary text dim. 256-color
// works everywhere the VT gate lets escapes through (Windows 10+, any modern
// Unix terminal).

func (p Palette) Heading(s string) string { return p.wrap("1;38;5;172", s) }
func (p Palette) Key(s string) string     { return p.wrap("38;5;172", s) }
func (p Palette) Num(s string) string     { return p.wrap("33", s) }
func (p Palette) Bool(s string) string    { return p.wrap("35", s) }
func (p Palette) OK(s string) string      { return p.wrap("32", s) }
func (p Palette) Warn(s string) string    { return p.wrap("33", s) }
func (p Palette) Fail(s string) string    { return p.wrap("1;31", s) }
func (p Palette) Bold(s string) string    { return p.wrap("1", s) }
func (p Palette) Dim(s string) string     { return p.wrap("2", s) }
func (p Palette) Slot(s string) string    { return p.wrap("35", s) } // a fill-in placeholder in a usage line
func (p Palette) URL(s string) string     { return p.wrap("2;4", s) }
