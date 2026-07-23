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

// ResolvePort picks the port to connect to, in precedence order:
// explicit flag (>0) > GODOT_MCP_PORT env > discovery file under cwd's
// project root > DefaultPort.
func ResolvePort(flagPort int, cwd string) int {
	if flagPort > 0 {
		return flagPort
	}
	if env := os.Getenv("GODOT_MCP_PORT"); env != "" {
		if p, err := strconv.Atoi(env); err == nil {
			return p
		}
	}
	if root, err := FindProjectRoot(cwd); err == nil {
		if d, err := ReadDiscovery(root); err == nil && d.Port > 0 {
			return d.Port
		}
	}
	return DefaultPort
}
