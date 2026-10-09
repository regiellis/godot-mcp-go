// Package playtest reads the session files the addon's playtest recorder writes
// (services/playtest_recorder.gd) and turns them into reports and comparisons.
// It is local and pure: no editor, no game, no network. The CLI's
// `swallowtail playtest report|compare` subcommands are thin layers over it.
package playtest

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// SessionSchema is the session file version this package reads. The recorder
// writes `schema: 1`; a different number is refused rather than half-read.
const SessionSchema = 1

// SessionKind is the `kind` stamp every session file carries.
const SessionKind = "swallowtail-playtest"

// SessionsDir is the folder under the game's user-data dir the recorder writes to.
const SessionsDir = "swallowtail-playtests"

// maxSessionBytes bounds what Load will read. An hour of frames is a few MB, so
// this leaves room for long runs while refusing a file that is clearly not one.
const maxSessionBytes = 256 << 20

// Session is one recorded playtest, as the game wrote it. Every number is a
// float64: Godot's JSON writer prints an int as `30` and a float as `30.0`, and
// reading both through one type keeps a value whose type drifts between engine
// versions from failing the whole file.
type Session struct {
	Schema        int            `json:"schema"`
	Kind          string         `json:"kind"`
	Name          string         `json:"name"`
	ProjectName   string         `json:"project_name"`
	EngineVersion string         `json:"engine_version"`
	DisplayServer string         `json:"display_server"`
	Headless      bool           `json:"headless"`
	DebugBuild    bool           `json:"debug_build"`
	OS            string         `json:"os"`
	Renderer      string         `json:"renderer"`
	Adapter       string         `json:"adapter"`
	VsyncMode     float64        `json:"vsync_mode"`
	MaxFPS        float64        `json:"max_fps"`
	PhysicsTicks  float64        `json:"physics_ticks_per_second"`
	TimeScale     float64        `json:"time_scale"`
	ViewportSize  []float64      `json:"viewport_size"`
	Scene         string         `json:"scene"`
	StartedUnix   float64        `json:"started_unix"`
	StoppedUnix   float64        `json:"stopped_unix"`
	DurationMS    float64        `json:"duration_ms"`
	EndedBy       string         `json:"ended_by"`
	SampleEvery   float64        `json:"sample_every"`
	Frames        FrameSeries    `json:"frames"`
	Samples       []Sample       `json:"samples"`
	Marks         []Mark         `json:"marks"`
	Events        []Event        `json:"events"`
	Inputs        []Input        `json:"inputs"`
	Errors        []RuntimeError `json:"errors"`
	ErrorsCapture string         `json:"errors_capture"`
	Truncated     bool           `json:"truncated"`
	Dropped       map[string]int `json:"dropped"`
}

// FrameSeries is every frame's wall-clock length in milliseconds. Frame i ended
// FirstTickMS + sum(TimesMS[0..i]) after the session started, and was the
// game's process frame FirstFrame+1+i.
type FrameSeries struct {
	FirstFrame  float64   `json:"first_frame"`
	FirstTickMS float64   `json:"first_tick_ms"`
	Count       float64   `json:"count"`
	TimesMS     []float64 `json:"times_ms"`
}

// Sample is one snapshot of the engine's Performance monitors. Memory is in
// bytes. Spike samples are taken on a frame the game itself saw as slow, on top
// of the regular every-N-frames cadence.
type Sample struct {
	TMS        float64 `json:"t_ms"`
	Frame      float64 `json:"frame"`
	FPS        float64 `json:"fps"`
	ProcessMS  float64 `json:"process_ms"`
	PhysicsMS  float64 `json:"physics_ms"`
	StaticMem  float64 `json:"static_mem"`
	VideoMem   float64 `json:"video_mem"`
	TextureMem float64 `json:"texture_mem"`
	Objects    float64 `json:"objects"`
	Nodes      float64 `json:"nodes"`
	Orphans    float64 `json:"orphans"`
	DrawCalls  float64 `json:"draw_calls"`
	Primitives float64 `json:"primitives"`
	Spike      bool    `json:"spike"`
	FrameMS    float64 `json:"frame_ms"`
}

// Mark is a checkpoint. Each one starts a report section.
type Mark struct {
	TMS    float64 `json:"t_ms"`
	Frame  float64 `json:"frame"`
	Label  string  `json:"label"`
	Source string  `json:"source"`
}

// Event is a game fact, posted by the CLI (`playtest event`) or by game code
// (`MCPGameInspector.playtest_event`).
type Event struct {
	TMS    float64        `json:"t_ms"`
	Frame  float64        `json:"frame"`
	Name   string         `json:"name"`
	Source string         `json:"source"`
	Data   map[string]any `json:"data"`
}

// Input is one event an input.* command injected into the game.
type Input struct {
	TMS     float64 `json:"t_ms"`
	Frame   float64 `json:"frame"`
	Type    string  `json:"type"`
	Keycode string  `json:"keycode,omitempty"`
	Action  string  `json:"action,omitempty"`
	Button  float64 `json:"button,omitempty"`
	Pressed *bool   `json:"pressed,omitempty"`
}

// RuntimeError is one error or warning the game logged while recording.
type RuntimeError struct {
	TMS       float64          `json:"t_ms"`
	Frame     float64          `json:"frame"`
	Kind      string           `json:"kind"`
	Message   string           `json:"message"`
	File      string           `json:"file"`
	Line      float64          `json:"line"`
	Function  string           `json:"function"`
	Backtrace []BacktraceFrame `json:"backtrace"`
}

// BacktraceFrame is one script frame of a runtime error's backtrace.
type BacktraceFrame struct {
	Function string  `json:"function"`
	File     string  `json:"file"`
	Line     float64 `json:"line"`
}

// Load reads and validates a session file.
func Load(path string) (*Session, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		return nil, fmt.Errorf("%s is a directory, not a session file", path)
	}
	if info.Size() > maxSessionBytes {
		return nil, fmt.Errorf("%s is %d bytes, over the %d MiB a session file can be", path, info.Size(), maxSessionBytes>>20)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(data)
}

// Parse decodes and validates session JSON.
func Parse(data []byte) (*Session, error) {
	var s Session
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("not a playtest session: %w", err)
	}
	if s.Kind != SessionKind {
		return nil, fmt.Errorf("not a playtest session: kind is %q, want %q", s.Kind, SessionKind)
	}
	if s.Schema != SessionSchema {
		return nil, fmt.Errorf("session schema %d is not supported (this CLI reads schema %d); update swallowtail", s.Schema, SessionSchema)
	}
	return &s, nil
}

// ErrNoSessions is returned by Newest when the folder holds no session file.
var ErrNoSessions = errors.New("no playtest sessions recorded yet")

// Newest returns the paths of session files in dir, newest first by
// modification time (file name breaks ties, and the recorder's names start with
// a timestamp). In-progress `.part` files are skipped.
func Newest(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s does not exist", ErrNoSessions, dir)
		}
		return nil, err
	}
	type found struct {
		path string
		mod  int64
		name string
	}
	var files []found
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		files = append(files, found{filepath.Join(dir, e.Name()), info.ModTime().UnixNano(), e.Name()})
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("%w in %s", ErrNoSessions, dir)
	}
	slices.SortFunc(files, func(a, b found) int {
		if a.mod != b.mod {
			if a.mod > b.mod {
				return -1
			}
			return 1
		}
		return strings.Compare(b.name, a.name)
	})
	out := make([]string, len(files))
	for i, f := range files {
		out[i] = f.path
	}
	return out, nil
}
