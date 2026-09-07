package client

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Env accepts both namespaces. A nonempty Swallowtail value takes precedence.
func Env(name string) string {
	suffix := strings.TrimPrefix(strings.TrimPrefix(name, "GODOT_MCP_"), "SWALLOWTAIL_")
	if value := os.Getenv("SWALLOWTAIL_" + suffix); value != "" {
		return value
	}
	return os.Getenv("GODOT_MCP_" + suffix)
}

var ErrDiscoveryConflict = errors.New("conflicting live Swallowtail and legacy discovery records; close the duplicate editor before continuing")

// ReadCompatibleDiscovery prefers a live record over a stale record. Both names
// describe one endpoint; two distinct live owners must never be guessed between.
func ReadCompatibleDiscovery(dir, name, legacy string) ([]byte, error) {
	current, err := os.ReadFile(filepath.Join(dir, name))
	old, oldErr := os.ReadFile(filepath.Join(dir, legacy))
	if errors.Is(err, os.ErrNotExist) {
		return old, oldErr
	}
	if err != nil {
		return nil, err
	}
	if oldErr != nil {
		return current, nil
	}
	var a, b struct {
		PID  int `json:"pid"`
		Port int `json:"port"`
	}
	if json.Unmarshal(current, &a) != nil || json.Unmarshal(old, &b) != nil {
		return current, nil
	}
	if PIDAlive(b.PID) {
		if !PIDAlive(a.PID) {
			return old, nil
		}
		if a.PID != b.PID || a.Port != b.Port {
			return nil, ErrDiscoveryConflict
		}
	}
	return current, nil
}
