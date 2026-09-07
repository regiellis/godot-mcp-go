package client

import (
	"encoding/json"
	"errors"
	"fmt"
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
	data, err := ReadCompatibleDiscovery(filepath.Join(projectRoot, ".godot"), "swallowtail.json", "godot-mcp.json")
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
	Err     error // invalid configuration; callers must not dial when set
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
		} else if errors.Is(err, ErrDiscoveryConflict) {
			r.Err = err
			return r
		}
	}
	switch {
	case flagPort != 0:
		r.Port, r.Source = flagPort, SourceFlag
		r.Err = ValidatePort(flagPort, "--port")
	case Env("GODOT_MCP_PORT") != "":
		r.Source = SourceEnv
		r.Port, r.Err = environmentPort("GODOT_MCP_PORT")
	case r.Disc != nil:
		r.Port, r.Source = r.Disc.Port, SourceDiscovery
		r.Err = ValidatePort(r.Port, "discovery file port")
	}
	return r
}

// ResolvePort picks the port to connect to. See ResolvePortSource for precedence.
func ResolvePort(flagPort int, cwd string) (int, error) {
	r := ResolvePortSource(flagPort, cwd)
	return r.Port, r.Err
}

// ValidatePort checks a concrete TCP port; zero is only a discovery flag default.
func ValidatePort(port int, source string) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("%s must be an integer from 1 to 65535", source)
	}
	return nil
}

func environmentPort(name string) (int, error) {
	p, err := strconv.Atoi(Env(name))
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer from 1 to 65535", name)
	}
	return p, ValidatePort(p, name)
}
