package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/bynine/godot-mcp-go/internal/protocol"
)

// Recovery holds only paths the plan can write. Never infer ownership from a
// dirty working tree: another editor or person may have created those changes.
type recoveryFile struct {
	Path   string
	Data   []byte
	Mode   os.FileMode
	Exists bool
}

type fixRecovery struct {
	Files    []recoveryFile
	Scene    string
	Scenes   []string
	Settings []recoverySetting
}

type recoverySetting struct {
	Key    string
	Exists bool
	Value  any
}

type recoveryCaller interface {
	callTimeout(time.Duration, string, map[string]any) (json.RawMessage, error)
}

func captureFixCheckpoint(sess recoveryCaller, label string, needsScene bool) (string, bool, error) {
	raw, err := sess.callTimeout(time.Minute, "scene.tree", map[string]any{"max_depth": 0})
	if err != nil {
		var rpc *protocol.Error
		if !needsScene && errors.As(err, &rpc) && rpc.Code == -32000 {
			return "", false, nil
		}
		return "", false, err
	}
	var scene struct {
		ScenePath string `json:"scene_path"`
	}
	if err := json.Unmarshal(raw, &scene); err != nil {
		return "", false, err
	}
	_, err = sess.callTimeout(time.Minute, "authoring.checkpoint", map[string]any{"action": "capture", "label": label})
	return scene.ScenePath, err == nil, err
}

func captureFixFiles(root string, plan fixPlan) (*fixRecovery, error) {
	paths := map[string]bool{}
	for _, edit := range plan.Edits {
		paths[edit.File] = true
	}
	for _, action := range plan.Actions {
		switch action.Method {
		case "scene.open":
			path, _ := action.Params["path"].(string)
			paths[path] = true
		case "project.set_setting":
			paths["project.godot"] = true
		}
	}
	if plan.Category == catUID {
		missing, err := scanUIDSidecars(root)
		if err != nil {
			return nil, err
		}
		for _, finding := range missing {
			paths[finding.File+".uid"] = true
		}
	}
	var names []string
	for path := range paths {
		names = append(names, path)
	}
	sort.Strings(names)
	recovery := &fixRecovery{}
	for _, action := range plan.Actions {
		if action.Method != "project.set_setting" {
			continue
		}
		key, _ := action.Params["key"].(string)
		if key != "application/config/features" {
			return nil, fmt.Errorf("no recovery capture for setting %s", key)
		}
		raw, exists := projectSetting(root, "application", "config/features")
		values := []string{}
		for _, match := range regexp.MustCompile(`"([^"]*)"`).FindAllStringSubmatch(raw, -1) {
			values = append(values, match[1])
		}
		recovery.Settings = append(recovery.Settings, recoverySetting{key, exists, values})
	}
	for _, name := range names {
		path, err := recoveryPath(root, name)
		if err != nil {
			return nil, err
		}
		file := recoveryFile{Path: name}
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			recovery.Files = append(recovery.Files, file)
			continue
		}
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("recovery requires a regular file: %s", name)
		}
		file.Data, err = os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		file.Exists, file.Mode = true, info.Mode().Perm()
		recovery.Files = append(recovery.Files, file)
		if strings.HasSuffix(name, ".tscn") || strings.HasSuffix(name, ".scn") {
			recovery.Scenes = append(recovery.Scenes, name)
		}
	}
	return recovery, nil
}

// Recheck containment at recovery time too, including symlinked parents.
func recoveryPath(root, name string) (string, error) {
	rel := filepath.FromSlash(strings.TrimPrefix(name, "res://"))
	if rel == "" || rel == "." || filepath.IsAbs(rel) || filepath.VolumeName(rel) != "" {
		return "", fmt.Errorf("invalid recovery path: %s", name)
	}
	rel = filepath.Clean(rel)
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("recovery path escapes project: %s", name)
	}
	base, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	base, err = filepath.Abs(base)
	if err != nil {
		return "", err
	}
	path := filepath.Join(base, rel)
	parent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		return "", err
	}
	parentRel, err := filepath.Rel(base, parent)
	if err != nil || parentRel == ".." || strings.HasPrefix(parentRel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("recovery parent escapes project: %s", name)
	}
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return "", fmt.Errorf("recovery refuses non-regular file: %s", name)
	} else if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	return path, nil
}

func restoreFix(root string, sess recoveryCaller, report *fixReport) {
	report.Restored = false
	report.RecoveryErrors = nil
	fail := func(step string, err error) {
		if err != nil {
			report.RecoveryErrors = append(report.RecoveryErrors, step+": "+err.Error())
		}
	}
	if report.recovery == nil {
		fail("capture", fmt.Errorf("no recovery snapshot; nothing was overwritten"))
		return
	}
	// Restore editor settings before disk bytes, since setting commands save the
	// whole project file in the current engine's serialization format.
	for _, setting := range report.recovery.Settings {
		method := "project.remove_setting"
		params := map[string]any{"key": setting.Key}
		if setting.Exists {
			method = "project.set_setting"
			params["value"] = setting.Value
		}
		_, err := sess.callTimeout(time.Minute, method, params)
		fail("restore setting "+setting.Key, err)
	}
	for _, file := range report.recovery.Files {
		path, err := recoveryPath(root, file.Path)
		if err == nil {
			if file.Exists {
				err = os.WriteFile(path, file.Data, file.Mode)
			} else {
				err = os.Remove(path)
				if os.IsNotExist(err) {
					err = nil
				}
			}
		}
		fail("restore "+file.Path, err)
	}
	_, err := sess.callTimeout(5*time.Minute, "editor.reload", nil)
	fail("editor reload", err)
	for _, file := range report.recovery.Files {
		if !file.Exists || !strings.HasSuffix(file.Path, ".gd") {
			continue
		}
		if _, err := recoveryPath(root, file.Path); err != nil {
			continue
		}
		uri := "res://" + strings.TrimPrefix(filepath.ToSlash(file.Path), "res://")
		_, err := sess.callTimeout(time.Minute, "script.edit", map[string]any{"path": uri, "content": string(file.Data)})
		fail("refresh script "+file.Path, err)
	}
	// Scene writes start only from saved tabs. Reload each affected scene from
	// its recovered file; transform checkpoints alone cannot undo node deletion.
	for _, scene := range report.recovery.Scenes {
		if len(report.RecoveryErrors) > 0 {
			break
		}
		_, err = sess.callTimeout(time.Minute, "scene.open", map[string]any{"path": scene, "force": true})
		fail("reload scene "+scene, err)
	}
	// Checkpoints contain transforms, not complete scenes. Select the captured
	// scene before restoring and verify the full checkpoint diff afterwards.
	canRestore := true
	if report.recovery.Scene != "" {
		_, err = sess.callTimeout(time.Minute, "scene.open", map[string]any{"path": report.recovery.Scene})
		fail("select checkpoint scene", err)
		canRestore = err == nil
	}
	if canRestore && report.Checkpoint != "" {
		_, err = sess.callTimeout(time.Minute, "authoring.checkpoint", map[string]any{"action": "restore", "label": report.Checkpoint})
		fail("checkpoint restore", err)
		raw, err := sess.callTimeout(time.Minute, "authoring.checkpoint", map[string]any{"action": "diff", "label": report.Checkpoint})
		if err == nil {
			var diff struct{ Added, Removed, Moved []string }
			err = json.Unmarshal(raw, &diff)
			if err == nil && (diff.Added == nil || diff.Removed == nil || diff.Moved == nil) {
				err = fmt.Errorf("checkpoint diff omitted required node lists")
			}
			if err == nil && (len(diff.Added)+len(diff.Removed)+len(diff.Moved) > 0) {
				err = fmt.Errorf("scene still differs: %d added, %d removed, %d moved nodes", len(diff.Added), len(diff.Removed), len(diff.Moved))
			}
		}
		fail("checkpoint verification", err)
	}
	// A rescan can rewrite files (notably .uid sidecars), so verify after it.
	for _, file := range report.recovery.Files {
		path, err := recoveryPath(root, file.Path)
		if err == nil {
			var data []byte
			data, err = os.ReadFile(path)
			if !file.Exists && os.IsNotExist(err) {
				err = nil
			} else if err == nil && (!file.Exists || !bytes.Equal(data, file.Data)) {
				err = fmt.Errorf("file does not match recovery snapshot")
			}
		}
		fail("verify "+file.Path, err)
	}
	report.Restored = len(report.RecoveryErrors) == 0
}

func requireSavedScenes(sess recoveryCaller) error {
	const code = `if not EditorInterface.has_method("get_unsaved_scenes"):
	emit(JSON.stringify({"available": false}))
else:
	emit(JSON.stringify({"available": true, "unsaved": EditorInterface.call("get_unsaved_scenes")}))`
	raw, err := sess.callTimeout(time.Minute, "editor.run_script", map[string]any{"code": code})
	if err != nil {
		return err
	}
	var result struct {
		Output []string
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return err
	}
	var state struct {
		Available bool
		Unsaved   []string
	}
	if len(result.Output) != 1 {
		return fmt.Errorf("saved-scene probe returned no state")
	}
	if err := json.Unmarshal([]byte(result.Output[0]), &state); err != nil {
		return err
	}
	if !state.Available || state.Unsaved == nil {
		return fmt.Errorf("cannot verify saved scene tabs; scene recovery requires an editor with get_unsaved_scenes")
	}
	if len(state.Unsaved) > 0 {
		return fmt.Errorf("save scene tabs before upgrade fix: %s", strings.Join(state.Unsaved, ", "))
	}
	return nil
}
