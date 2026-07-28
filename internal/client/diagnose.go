package client

import (
	"context"
	"fmt"
	"net"
	"time"
)

// Verdict classifies why the editor is or isn't reachable. The disambiguation
// rests on the addon's lifecycle: a clean shutdown deletes the discovery file
// (websocket_server.gd stop() -> _remove_discovery()), while a crash leaves it
// stale with a now-dead pid. That, plus a liveness probe, tells crash from close.
type Verdict string

const (
	VerdictRunning  Verdict = "running"  // server accepts connections
	VerdictStarting Verdict = "starting" // process alive, server not bound yet
	VerdictCrashed  Verdict = "crashed"  // stale discovery file, process gone
	VerdictClosed   Verdict = "closed"   // no discovery file: closed cleanly or never started
)

// Status is the result of Diagnose — a machine- and agent-readable verdict plus
// guidance. It is emitted by `godot-mcp status` and attached to dial failures so
// the agent can tell a crash from a deliberate close and avoid stacking editors.
type Status struct {
	Verdict     Verdict `json:"verdict"`
	Reachable   bool    `json:"reachable"`
	Port        int     `json:"port"`
	PID         int     `json:"pid,omitempty"`
	StartedUnix int64   `json:"started_unix,omitempty"`
	Message     string  `json:"message"`
	Action      string  `json:"action"`

	// PortSource, ProjectPath, and ProjectMatch answer "whose editor is this?".
	// Port discovery falls back to the default port, so a reachable editor is not
	// necessarily this project's, and every command would land in the other one.
	PortSource   PortSource `json:"port_source"`
	ProjectPath  string     `json:"project_path,omitempty"`  // project the answering editor serves
	ProjectMatch *bool      `json:"project_match,omitempty"` // nil when it could not be determined
}

// Diagnose decides the editor's state for the project at cwd. flagPort (>0) pins
// the port; otherwise it resolves via env/discovery/default. It performs a short
// TCP probe and, when a discovery file exists but the probe fails, a pid-liveness
// check to separate a crash (process gone) from a still-booting editor.
func Diagnose(cwd string, flagPort int) Status {
	// Resolve the port ONCE (flag > env > discovery > default) so the probed port
	// and the port reported in the verdict never diverge.
	res := ResolvePortSource(flagPort, cwd)
	disc := res.Disc

	reachable := probe(res.Port)
	alive := disc != nil && pidAlive(disc.PID)
	st := classify(disc, res.Port, reachable, alive)
	st.PortSource = res.Source

	// Which project answered. This is the preflight, so it is worth one call: a
	// reachable editor that serves a different project is the failure mode a
	// verdict of "running" would otherwise wave straight through.
	if !reachable || res.Project == "" {
		return st
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	answering, err := AnsweringProject(ctx, res.Port)
	if err != nil || answering == "" {
		return st
	}
	st.ProjectPath = answering
	match := SameProjectPath(answering, res.Project)
	st.ProjectMatch = &match
	if match {
		return st
	}

	// Something answered, but not this project's editor, so as far as THIS project
	// is concerned nothing is serving it. Re-derive the verdict as if the probe had
	// failed: that is what makes the launch policy produce the right move ("you may
	// launch one") instead of "running, proceed" against a stranger's editor.
	st = classify(disc, res.Port, false, alive)
	st.PortSource = res.Source
	st.ProjectPath = answering
	st.ProjectMatch = &match
	st.Message = fmt.Sprintf("An editor answered on port %d, but it is serving %s, not %s — this project has no editor of its own.", res.Port, answering, res.Project)
	st.Action = (&ProjectMismatch{Port: res.Port, Source: res.Source, Expected: res.Project, Answering: answering}).Action()
	return st
}

// classify is the pure decision from the three observable facts: whether the
// discovery file exists (intent — a clean close deletes it), whether the server
// answers (reachable), and whether its recorded pid is alive. Kept separate from
// the probes so the verdict logic is unit-testable.
func classify(disc *Discovery, port int, reachable, alive bool) Status {
	if reachable {
		s := Status{
			Verdict: VerdictRunning, Reachable: true, Port: port,
			Message: "Editor is running and reachable.",
			Action:  "Proceed. Do NOT launch another editor — a second instance would stack.",
		}
		if disc != nil {
			s.PID = disc.PID
			s.StartedUnix = disc.StartedUnix
		}
		return s
	}

	// Not reachable. The discovery file (present vs absent) is the intent signal.
	if disc == nil {
		return Status{
			Verdict: VerdictClosed, Port: port,
			Message: "No editor reachable and no discovery file — the editor was closed cleanly or was never started.",
			Action:  "You may launch ONE editor (godot --path <project> --editor) if the task needs it. Never launch a second.",
		}
	}
	if alive {
		return Status{
			Verdict: VerdictStarting, Port: port, PID: disc.PID, StartedUnix: disc.StartedUnix,
			Message: "Editor process is alive but not accepting connections yet — it is still booting or the addon has not bound.",
			Action:  "Wait a few seconds and retry. Do NOT launch another editor.",
		}
	}
	return Status{
		Verdict: VerdictCrashed, Port: port, PID: disc.PID, StartedUnix: disc.StartedUnix,
		Message: fmt.Sprintf("Editor appears to have crashed — a stale discovery file remains but its process (pid %d) is gone.", disc.PID),
		Action:  "Tell the user it crashed. You may relaunch ONE editor. Never launch a second.",
	}
}

// probe reports whether something is accepting TCP connections on the addon port.
func probe(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 1500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
