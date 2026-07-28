package client

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
)

// DefaultPort is used when no flag, env, or discovery file provides one.
const DefaultPort = 9080

// Discovery is the JSON the addon writes to <project>/.godot/godot-mcp.json
// when its WebSocket server binds. The CLI reads it for zero-config connect.
type Discovery struct {
	Port         int    `json:"port"`
	PID          int    `json:"pid"`
	GodotVersion string `json:"godot_version"`
	ProjectPath  string `json:"project_path"`
	StartedUnix  int64  `json:"started_unix"`
}

// FindProjectRoot walks up from start (a dir) until it finds project.godot,
// returning that directory. It returns an error if none is found.
func FindProjectRoot(start string) (string, error) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "project.godot")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("no project.godot found in any parent directory")
		}
		dir = parent
	}
}

// ReadDiscovery reads the discovery file under a project root. A missing file
// is reported as os.ErrNotExist so callers can fall back to the default port.
func ReadDiscovery(projectRoot string) (*Discovery, error) {
	path := filepath.Join(projectRoot, ".godot", "godot-mcp.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d Discovery
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// PortSource records where the connect port came from. It decides how far the CLI
// can trust that the editor answering there is this project's: a port read from a
// live discovery file names its own editor, while the default fallback names
// whichever editor happens to hold 9080.
type PortSource string

const (
	SourceFlag      PortSource = "flag"
	SourceEnv       PortSource = "env"
	SourceDiscovery PortSource = "discovery"
	SourceDefault   PortSource = "default"
)

// Resolution is a resolved port plus the context needed to judge it: where the
// port came from, which project the caller is standing in, and that project's
// discovery file if it has one.
type Resolution struct {
	Port    int
	Source  PortSource
	Project string     // caller's project root; "" when cwd is not inside a project
	Disc    *Discovery // the caller's discovery file, when present
}

// ResolvePortSource picks the port to connect to and reports how it got there, in
// precedence order: explicit flag (>0) > GODOT_MCP_PORT env > discovery file under
// cwd's project root > DefaultPort.
func ResolvePortSource(flagPort int, cwd string) Resolution {
	r := Resolution{Port: DefaultPort, Source: SourceDefault}
	if root, err := FindProjectRoot(cwd); err == nil {
		r.Project = root
		if d, err := ReadDiscovery(root); err == nil {
			r.Disc = d
		}
	}
	switch {
	case flagPort > 0:
		r.Port, r.Source = flagPort, SourceFlag
	case os.Getenv("GODOT_MCP_PORT") != "":
		if p, err := strconv.Atoi(os.Getenv("GODOT_MCP_PORT")); err == nil {
			r.Port, r.Source = p, SourceEnv
		}
	case r.Disc != nil && r.Disc.Port > 0:
		r.Port, r.Source = r.Disc.Port, SourceDiscovery
	}
	return r
}

// ResolvePort picks the port to connect to. See ResolvePortSource for precedence.
func ResolvePort(flagPort int, cwd string) int {
	return ResolvePortSource(flagPort, cwd).Port
}
