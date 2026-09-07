package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/bynine/godot-mcp-go/internal/client"
)

type cliCatalog struct {
	Project string                `json:"project"`
	Port    int                   `json:"port"`
	Saved   time.Time             `json:"saved"`
	Methods []string              `json:"methods"`
	Docs    map[string]commandDoc `json:"docs"`
}

var errCatalogOwner = errors.New("editor belongs to another project")

const maxCatalogBytes = 4 << 20

func catalogPath(root string) string {
	return filepath.Join(root, ".godot", "swallowtail-cli-catalog.json")
}

func readCLICatalog(root string) (cliCatalog, error) {
	var c cliCatalog
	f, err := os.Open(catalogPath(root))
	if errors.Is(err, os.ErrNotExist) {
		f, err = os.Open(filepath.Join(root, ".godot", "godot-mcp-cli-catalog.json"))
	}
	if err != nil {
		return c, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return c, err
	}
	if st.Size() > maxCatalogBytes {
		return c, fmt.Errorf("catalog too large")
	}
	if err = json.NewDecoder(f).Decode(&c); err != nil {
		return c, err
	}
	if !client.SameProjectPath(root, c.Project) || len(c.Methods) == 0 || c.Saved.IsZero() {
		return c, fmt.Errorf("catalog does not belong to this project")
	}
	return c, nil
}

func saveCLICatalog(root string, c cliCatalog) {
	if root == "" {
		return
	}
	b, err := json.Marshal(c)
	if err != nil || len(b) > maxCatalogBytes {
		return
	}
	dir := filepath.Dir(catalogPath(root))
	if os.MkdirAll(dir, 0755) != nil {
		return
	}
	f, err := os.CreateTemp(dir, ".cli-catalog-*")
	if err != nil {
		return
	}
	name := f.Name()
	defer os.Remove(name)
	_, err = f.Write(b)
	closeErr := f.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(name, catalogPath(root))
	}
}

// Only connection failures can use saved help. A bad live response never silently
// resurrects a previous command list. Cached help never authorizes dispatch.
func loadCLICatalog(ctx context.Context, port int, explicit bool) (cliCatalog, bool, error) {
	cwd := cliWorkingDirectory()
	root, _ := client.FindProjectRoot(cwd)
	raw, err := client.Call(ctx, port, "engine.commands", map[string]any{"docs": true})
	if err != nil {
		var dial *client.DialError
		if root != "" && (errors.As(err, &dial) || errors.Is(err, context.DeadlineExceeded)) {
			if c, e := readCLICatalog(root); e == nil && (!explicit || c.Port == port) {
				return c, true, nil
			}
		}
		return cliCatalog{}, false, err
	}
	var c cliCatalog
	if err = json.Unmarshal(raw, &c); err != nil {
		return c, false, err
	}
	if len(c.Methods) == 0 || c.Docs == nil {
		return c, false, fmt.Errorf("editor returned an incomplete command catalog")
	}
	c.Project, c.Port, c.Saved = root, port, time.Now().UTC()
	if root != "" {
		owner, e := client.AnsweringProject(ctx, port)
		if e != nil {
			return c, false, e
		}
		if !client.SameProjectPath(root, owner) {
			if !explicit {
				if cached, e := readCLICatalog(root); e == nil {
					return cached, true, nil
				}
			}
			return c, false, fmt.Errorf("%w: port %d; launch this project or select the intended project", errCatalogOwner, port)
		}
		saveCLICatalog(root, c)
	}
	return c, false, nil
}

func runCatalogHelp(port int, group, command string) (int, bool) {
	cwd := cliWorkingDirectory()
	resolved, err := client.ResolvePort(port, cwd)
	if err != nil {
		emitCLIError("usage", err.Error(), nil)
		return 2, true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	c, cached, err := loadCLICatalog(ctx, resolved, port != 0 || client.Env("SWALLOWTAIL_PORT") != "")
	if err != nil {
		if errors.Is(err, errCatalogOwner) {
			emitCLIError("project", err.Error(), nil)
			return 1, true
		}
		return 0, false
	} // Preserve older addons' existing help fallback.
	if cached {
		fmt.Fprintf(os.Stderr, "Cached help from %s; editor unavailable. Commands may have changed.\n", c.Saved.Format(time.RFC3339))
	}
	byGroup := groupMethods(c.Methods)
	if group == "all" {
		for _, g := range sortedKeys(byGroup) {
			printGroupHelp(g, byGroup[g], c.Docs)
		}
		return 0, true
	}
	if len(byGroup[group]) == 0 {
		printUnknownGroup(group, byGroup)
		return 2, true
	}
	if command == "" {
		printGroupHelp(group, byGroup[group], c.Docs)
		return 0, true
	}
	for _, name := range byGroup[group] {
		if name == command {
			printCommandHelp(group, command, c.Docs[group+"."+command])
			return 0, true
		}
	}
	fmt.Fprintf(os.Stderr, "Unknown command %s.%s. Try swallowtail %s --help.\n", group, command, group)
	return 2, true
}
