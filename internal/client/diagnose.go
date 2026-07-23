package client

import (
	"fmt"
	"net"
	"os"
	"strconv"
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
}

// Diagnose decides the editor's state for the project at cwd. flagPort (>0) pins
// the port; otherwise it resolves via env/discovery/default. It performs a short
// TCP probe and, when a discovery file exists but the probe fails, a pid-liveness
// check to separate a crash (process gone) from a still-booting editor.
func Diagnose(cwd string, flagPort int) Status {
	var disc *Discovery
	if root, err := FindProjectRoot(cwd); err == nil {
		if d, err := ReadDiscovery(root); err == nil {
			disc = d
		}
	}
	// Resolve the port ONCE, reusing the disc we already read (flag > env > disc >
	// default) so the probed port and the port reported in the verdict never diverge.
	port := flagPort
	if port <= 0 {
		if env := os.Getenv("GODOT_MCP_PORT"); env != "" {
			if p, err := strconv.Atoi(env); err == nil {
				port = p
			}
		}
	}
	if port <= 0 && disc != nil && disc.Port > 0 {
		port = disc.Port
	}
	if port <= 0 {
		port = DefaultPort
	}

	reachable := probe(port)
	alive := disc != nil && pidAlive(disc.PID)
	return classify(disc, port, reachable, alive)
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
