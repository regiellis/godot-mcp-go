package client

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// DefaultGamePort is used for the --game channel when no flag, env, or game
// discovery file provides one. The in-game direct server scans 9200-9215.
const DefaultGamePort = 9200

// GameDiscovery is the JSON the in-game direct server (game_server.gd) writes to
// the game's user data dir as godot-mcp-game.json when it binds. The CLI reads it
// (with --game) for zero-config connect to a standalone running game.
type GameDiscovery struct {
	Port        int    `json:"port"`
	PID         int    `json:"pid"`
	ProjectName string `json:"project_name"`
	StartedUnix int64  `json:"started_unix"`
}

// projectConfig holds the fields of project.godot that determine the game's
// user:// data directory.
type projectConfig struct {
	Name              string
	UseCustomUserDir  bool
	CustomUserDirName string
}

// GameUserDataDir computes the running game's user data directory (where user://
// resolves, and thus where godot-mcp-game.json lands) from the project's
// project.godot, following Godot's platform defaults. It honors
// application/config/use_custom_user_dir + custom_user_dir_name.
func GameUserDataDir(projectRoot string) (string, error) {
	cfg, err := parseProjectGodot(filepath.Join(projectRoot, "project.godot"))
	if err != nil {
		return "", err
	}
	return userDataDir(cfg, runtime.GOOS, platformDataRoot()), nil
}

// ReadGameDiscovery reads godot-mcp-game.json from the game's user data dir. A
// missing file is reported as os.ErrNotExist so callers fall back to the default.
func ReadGameDiscovery(projectRoot string) (*GameDiscovery, error) {
	dir, err := GameUserDataDir(projectRoot)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(dir, "godot-mcp-game.json"))
	if err != nil {
		return nil, err
	}
	var d GameDiscovery
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// ResolveGamePort picks the port for the --game channel, in precedence order:
// explicit flag (>0) > GODOT_MCP_GAME_PORT env > the game discovery file under
// cwd's project root > DefaultGamePort.
func ResolveGamePort(flagPort int, cwd string) int {
	if flagPort > 0 {
		return flagPort
	}
	if env := os.Getenv("GODOT_MCP_GAME_PORT"); env != "" {
		if p, err := strconv.Atoi(env); err == nil {
			return p
		}
	}
	if root, err := FindProjectRoot(cwd); err == nil {
		if d, err := ReadGameDiscovery(root); err == nil && d.Port > 0 {
			return d.Port
		}
	}
	return DefaultGamePort
}

// userDataDir reconstructs Godot's OS.get_user_data_dir() from the parsed config,
// the target OS, and the platform data root. Split out (goos + dataRoot passed in)
// so the path construction is unit-testable without touching the real filesystem.
func userDataDir(cfg projectConfig, goos, dataRoot string) string {
	name := safeDirName(cfg.Name, false)
	if cfg.UseCustomUserDir {
		custom := safeDirName(cfg.CustomUserDirName, true)
		if custom == "" {
			custom = name
		}
		// custom_user_dir_name allows path separators; join each segment.
		return filepath.Join(append([]string{dataRoot}, strings.Split(custom, "/")...)...)
	}
	godotDir := "Godot"
	if goos == "linux" {
		godotDir = "godot"
	}
	if name == "" {
		name = "[unnamed project]"
	}
	return filepath.Join(dataRoot, godotDir, "app_userdata", name)
}

// safeDirName mirrors Godot's OS::get_safe_dir_name: strip surrounding whitespace
// and replace characters invalid in a filename with '_'. With allowPaths, path
// separators survive (but ".." does not) — used for custom_user_dir_name.
func safeDirName(s string, allowPaths bool) string {
	var invalid []string
	if allowPaths {
		s = strings.ReplaceAll(s, "\\", "/")
		s = strings.TrimSpace(s)
		invalid = []string{":", "*", "?", "\"", "<", ">", "|", ".."}
	} else {
		s = strings.TrimSpace(s)
		invalid = []string{":", "*", "?", "\"", "<", ">", "|", "/", "\\"}
	}
	for _, c := range invalid {
		s = strings.ReplaceAll(s, c, "_")
	}
	return s
}

// platformDataRoot returns Godot's per-platform data path (get_data_path): the
// parent of the "Godot"/"godot" app_userdata tree, or of a custom user dir.
func platformDataRoot() string {
	switch runtime.GOOS {
	case "windows":
		return os.Getenv("APPDATA")
	case "darwin":
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "Application Support")
	default: // linux and other unix
		if x := os.Getenv("XDG_DATA_HOME"); x != "" {
			return x
		}
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".local", "share")
	}
}

// parseProjectGodot reads the [application] fields of a project.godot that decide
// the user data dir. project.godot is a Godot ConfigFile (INI-like); values are
// Variant-encoded (quoted strings, true/false bools).
func parseProjectGodot(path string) (projectConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return projectConfig{}, err
	}
	defer f.Close()

	var cfg projectConfig
	section := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		if section != "application" {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		switch key {
		case "config/name":
			cfg.Name = unquoteGodot(val)
		case "config/custom_user_dir_name":
			cfg.CustomUserDirName = unquoteGodot(val)
		case "config/use_custom_user_dir":
			cfg.UseCustomUserDir = strings.EqualFold(val, "true")
		}
	}
	if err := sc.Err(); err != nil {
		return projectConfig{}, err
	}
	return cfg, nil
}

// unquoteGodot strips the surrounding double quotes from a Godot ConfigFile string
// value and unescapes the two escapes Godot writes (\" and \\). Falls back to the
// trimmed raw value if it isn't a simple quoted string.
func unquoteGodot(v string) string {
	v = strings.TrimSpace(v)
	if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
		inner := v[1 : len(v)-1]
		inner = strings.ReplaceAll(inner, "\\\"", "\"")
		inner = strings.ReplaceAll(inner, "\\\\", "\\")
		return inner
	}
	return v
}
