package client

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// ProjectMismatch reports that the editor answering on the resolved port is
// serving a different Godot project than the one the caller is standing in.
//
// This is the failure the check exists for: port discovery falls back to the
// default port when the caller's project has no discovery file, so whichever
// godot-mcp editor happens to be running answers. Every write then lands in that
// project, silently and successfully, which once cost a whole debugging session
// chasing settings that "wouldn't persist" — they persisted, in another project.
type ProjectMismatch struct {
	Port      int
	Source    PortSource
	Expected  string // the caller's project root
	Answering string // the project the editor on that port is actually serving
}

func (m *ProjectMismatch) Error() string {
	return fmt.Sprintf("the editor on port %d is serving %s, not %s", m.Port, m.Answering, m.Expected)
}

// Fatal reports whether the mismatch should stop the command rather than warn.
// A port the CLI guessed (the default fallback, or a discovery file left behind
// by a dead editor) has no user intent behind it, so acting on it is a bug. An
// explicit --port or GODOT_MCP_PORT is a deliberate target, so it only warns.
func (m *ProjectMismatch) Fatal() bool {
	return m.Source == SourceDefault || m.Source == SourceDiscovery
}

// Action is the recovery guidance, phrased for an agent reading a tool result.
func (m *ProjectMismatch) Action() string {
	if m.Source == SourceFlag || m.Source == SourceEnv {
		return fmt.Sprintf("Drop the explicit port (%s) to reach %s's own editor, or open one for it.", m.Source, m.Expected)
	}
	return fmt.Sprintf("Open an editor for %s, then retry. Do not act on the result of the editor that answered.", m.Expected)
}

// NeedsProjectCheck reports whether the answering editor's project has to be
// confirmed before the call is trusted. A port read from a discovery file whose
// pid is still alive names that editor directly, so it needs no confirmation and
// the common case costs nothing. Every other route is a guess or an assertion the
// caller made, and both can land on another project's editor.
func (r Resolution) NeedsProjectCheck() bool {
	if r.Project == "" {
		return false // not inside a project: nothing to compare against
	}
	if r.Source == SourceDiscovery && r.Disc != nil && pidAlive(r.Disc.PID) {
		return false
	}
	return true
}

// CheckProject asks the editor on the resolved port which project it is serving
// and compares that to the caller's. It returns nil when they match, when the
// check is not warranted, or when the editor cannot answer — an unreachable or
// too-old editor is the caller's existing dial-failure path, not a mismatch.
func CheckProject(ctx context.Context, r Resolution) *ProjectMismatch {
	if !r.NeedsProjectCheck() {
		return nil
	}
	answering, err := AnsweringProject(ctx, r.Port)
	if err != nil || answering == "" {
		return nil
	}
	if SameProjectPath(answering, r.Project) {
		return nil
	}
	return &ProjectMismatch{Port: r.Port, Source: r.Source, Expected: r.Project, Answering: answering}
}

// AnsweringProject returns the absolute project path of the editor listening on
// port, via project.info. The call is given its own short deadline so a project
// check can never outlast the command it is guarding.
func AnsweringProject(ctx context.Context, port int) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	raw, err := Call(ctx, port, "project.info", nil)
	if err != nil {
		return "", err
	}
	var info struct {
		ProjectPath string `json:"project_path"`
	}
	if err := json.Unmarshal(raw, &info); err != nil {
		return "", err
	}
	return info.ProjectPath, nil
}

// SameProjectPath compares two project roots that reached us by different routes:
// the addon globalizes res:// (forward slashes, trailing separator) while the CLI
// walks up from cwd. Case folding follows the platform, so two projects differing
// only by case still register as different where the filesystem says they are.
func SameProjectPath(a, b string) bool {
	norm := func(p string) string {
		p = filepath.Clean(filepath.FromSlash(strings.TrimSpace(p)))
		if runtime.GOOS == "windows" {
			return strings.ToLower(p)
		}
		return p
	}
	if a == "" || b == "" {
		return false
	}
	return norm(a) == norm(b)
}
