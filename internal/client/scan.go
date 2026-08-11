package client

import (
	"context"
	"encoding/json"
	"os"
	"slices"
	"strconv"
	"sync"
	"time"
)

// EditorInstance is one live godot-mcp editor server found by ScanInstances,
// identified by asking it project.info. PID comes from that project's own
// discovery file, so it is present only when the file agrees on the port.
type EditorInstance struct {
	Port         int    `json:"port"`
	ProjectName  string `json:"project_name,omitempty"`
	ProjectPath  string `json:"project_path,omitempty"`
	GodotVersion string `json:"godot_version,omitempty"`
	PID          int    `json:"pid,omitempty"`
	ThisProject  bool   `json:"this_project"`
}

// GameInstance is a live direct game server. That channel serves only
// runtime.*/input.* and carries no project identity to ask for, so a TCP
// probe is all the scan reports.
type GameInstance struct {
	Port int `json:"port"`
}

// ScanInstances probes the editor auto range (9080-9095) plus any env- or
// discovery-pinned port for live editors, and the game auto range (9200-9215)
// for direct game servers, all concurrently. cwd anchors the this_project
// marker. Ports that accept TCP but do not answer project.info are dropped —
// whatever is listening there is not an editor of ours.
func ScanInstances(ctx context.Context, cwd string) ([]EditorInstance, []GameInstance) {
	ports := map[int]struct{}{}
	for p := 9080; p <= 9095; p++ {
		ports[p] = struct{}{}
	}
	if env := os.Getenv("GODOT_MCP_PORT"); env != "" {
		if p, err := strconv.Atoi(env); err == nil && p > 0 {
			ports[p] = struct{}{}
		}
	}
	var project string
	if root, err := FindProjectRoot(cwd); err == nil {
		project = root
		if d, derr := ReadDiscovery(root); derr == nil && d.Port > 0 {
			ports[d.Port] = struct{}{}
		}
	}

	var (
		mu      sync.Mutex
		editors []EditorInstance
		games   []GameInstance
		wg      sync.WaitGroup
	)
	for p := range ports {
		wg.Add(1)
		go func(port int) {
			defer wg.Done()
			if !probe(port) {
				return
			}
			cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			raw, err := Call(cctx, port, "project.info", nil)
			if err != nil {
				return
			}
			var info struct {
				ProjectName  string `json:"project_name"`
				ProjectPath  string `json:"project_path"`
				GodotVersion struct {
					String string `json:"string"`
				} `json:"godot_version"`
			}
			if json.Unmarshal(raw, &info) != nil {
				return
			}
			inst := EditorInstance{
				Port:         port,
				ProjectName:  info.ProjectName,
				ProjectPath:  info.ProjectPath,
				GodotVersion: info.GodotVersion.String,
			}
			if d, derr := ReadDiscovery(info.ProjectPath); derr == nil && d.Port == port {
				inst.PID = d.PID
			}
			if project != "" {
				inst.ThisProject = SameProjectPath(info.ProjectPath, project)
			}
			mu.Lock()
			editors = append(editors, inst)
			mu.Unlock()
		}(p)
	}
	for p := 9200; p <= 9215; p++ {
		wg.Add(1)
		go func(port int) {
			defer wg.Done()
			if probe(port) {
				mu.Lock()
				games = append(games, GameInstance{Port: port})
				mu.Unlock()
			}
		}(p)
	}
	wg.Wait()

	slices.SortFunc(editors, func(a, b EditorInstance) int { return a.Port - b.Port })
	slices.SortFunc(games, func(a, b GameInstance) int { return a.Port - b.Port })
	return editors, games
}
