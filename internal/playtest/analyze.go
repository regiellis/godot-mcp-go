package playtest

import (
	"cmp"
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"
)

// ReportSchema versions the report document, separately from the session file.
const ReportSchema = 1

// DefaultTargetFPS sets the frame budget a report measures against when the
// caller names none.
const DefaultTargetFPS = 60

// Thresholds behind the spike and findings rules. They are named here so the
// report can quote them and a test can pin them.
const (
	spikeFactor      = 2.0  // a spike frame runs at least this many times the median...
	spikeMinExcessMS = 8.0  // ...and at least this many ms over it
	causeWindowMS    = 1000 // an input/event/mark this close before a spike is its candidate cause
	// A frame this far over budget counts as slow. 1.5x is a frame that ran
	// past one and a half refreshes, which a player sees as a hitch; 1.2x sat
	// inside ordinary vsync jitter on a live 60 Hz run (p95 19.4 ms) and turned
	// noise into a regression verdict.
	slowFrameFactor    = 1.5
	maxListedSpikes    = 20
	maxListedErrors    = 50
	shortSessionS      = 10.0
	shortSessionFrames = 300
	leakMinSessionS    = 60.0
	leakSlopeMBPerMin  = 1.0
	leakMinGrowthMB    = 2.0
	textureJumpMB      = 4.0
	staticJumpMB       = 8.0
	nodeJump           = 50.0
	nodeGrowthPerMin   = 20.0
	orphanMinEnd       = 10.0
	slowSectionFactor  = 1.5
	slowSectionFrames  = 60
	clusterMinEvents   = 3
	clusterMinShare    = 0.5
)

// Options tunes a report.
type Options struct {
	// TargetFPS sets the frame budget (1000/TargetFPS ms). Zero means 60.
	TargetFPS float64
}

// Report is the analysis of one session.
type Report struct {
	Schema   int          `json:"schema"`
	Kind     string       `json:"kind"`
	Source   string       `json:"source,omitempty"`
	Session  SessionInfo  `json:"session"`
	Frames   FrameStats   `json:"frames"`
	Spikes   SpikeStats   `json:"spikes"`
	Counters CounterStats `json:"counters"`
	Errors   ErrorStats   `json:"errors"`
	Events   EventStats   `json:"events"`
	Sections []Section    `json:"sections"`
	Input    InputStats   `json:"input"`
	Findings []Finding    `json:"findings"`
}

// SessionInfo is the session's identity and the context its numbers depend on.
type SessionInfo struct {
	Name          string         `json:"name"`
	ProjectName   string         `json:"project_name"`
	EngineVersion string         `json:"engine_version"`
	DisplayServer string         `json:"display_server"`
	Headless      bool           `json:"headless"`
	OS            string         `json:"os"`
	Renderer      string         `json:"renderer"`
	Adapter       string         `json:"adapter"`
	VsyncMode     int            `json:"vsync_mode"`
	MaxFPS        int            `json:"max_fps"`
	TimeScale     float64        `json:"time_scale"`
	ViewportSize  []int          `json:"viewport_size"`
	Scene         string         `json:"scene"`
	StartedUnix   float64        `json:"started_unix"`
	DurationS     float64        `json:"duration_s"`
	EndedBy       string         `json:"ended_by"`
	SampleEvery   int            `json:"sample_every"`
	ErrorsCapture string         `json:"errors_capture"`
	Truncated     bool           `json:"truncated"`
	Dropped       map[string]int `json:"dropped,omitempty"`
}

// FrameStats summarizes the per-frame wall-clock series. Percentiles are
// nearest-rank. A 1% low is the frame rate of the average of the slowest 1% of
// frames (at least one frame), the usual reading of the term.
type FrameStats struct {
	Count                 int     `json:"count"`
	TargetFPS             float64 `json:"target_fps"`
	BudgetMS              float64 `json:"budget_ms"`
	AvgMS                 float64 `json:"avg_ms"`
	AvgFPS                float64 `json:"avg_fps"`
	P50MS                 float64 `json:"p50_ms"`
	P95MS                 float64 `json:"p95_ms"`
	P99MS                 float64 `json:"p99_ms"`
	MaxMS                 float64 `json:"max_ms"`
	OnePercentLowFPS      float64 `json:"one_percent_low_fps"`
	PointOnePercentLowFPS float64 `json:"point_one_percent_low_fps"`
	SlowFramesPct         float64 `json:"slow_frames_pct"`
}

// SpikeStats counts spikes. Consecutive spike frames merge into one spike, so a
// half-second load reads as one hitch, not thirty.
type SpikeStats struct {
	ThresholdMS float64 `json:"threshold_ms"`
	Count       int     `json:"count"`
	Frames      int     `json:"frames"`
	PerMinute   float64 `json:"per_minute"`
	Worst       []Spike `json:"worst"`
}

// Spike is one hitch: where it happened, how long, what came just before it,
// and how the engine counters moved on that frame.
type Spike struct {
	TS         float64            `json:"t_s"`
	Frame      int64              `json:"frame"`
	Frames     int                `json:"frames"`
	WorstMS    float64            `json:"worst_ms"`
	TotalMS    float64            `json:"total_ms"`
	Section    string             `json:"section"`
	PrecededBy *Cause             `json:"preceded_by,omitempty"`
	Counters   map[string]float64 `json:"counter_deltas,omitempty"`
}

// Cause is the latest input, event, or checkpoint at most a second before a
// spike. GapMS is how long before the spike's frame began it happened; a small
// negative value means it landed inside that frame.
type Cause struct {
	Kind   string         `json:"kind"`
	Name   string         `json:"name"`
	GapMS  float64        `json:"gap_ms"`
	Source string         `json:"source,omitempty"`
	Data   map[string]any `json:"data,omitempty"`
}

// CounterStats summarizes the Performance samples.
type CounterStats struct {
	Samples    int      `json:"samples"`
	StaticMB   Trend    `json:"static_mb"`
	VideoMB    Trend    `json:"video_mb"`
	TextureMB  Trend    `json:"texture_mb"`
	Objects    Trend    `json:"objects"`
	Nodes      Trend    `json:"nodes"`
	Orphans    Trend    `json:"orphans"`
	DrawCalls  AvgMax   `json:"draw_calls"`
	Primitives AvgMax   `json:"primitives"`
	ProcessMS  AvgMax   `json:"process_ms"`
	PhysicsMS  AvgMax   `json:"physics_ms"`
	Notes      []string `json:"notes,omitempty"`
}

// Trend is a counter's first and last value, its peak, and its least-squares
// slope per minute.
type Trend struct {
	Start       float64 `json:"start"`
	End         float64 `json:"end"`
	Peak        float64 `json:"peak"`
	SlopePerMin float64 `json:"slope_per_min"`
}

// AvgMax is a counter's mean and maximum over the samples.
type AvgMax struct {
	Avg float64 `json:"avg"`
	Max float64 `json:"max"`
}

// ErrorStats lists the runtime errors recorded during the session.
type ErrorStats struct {
	Capture string         `json:"capture"`
	Count   int            `json:"count"`
	ByKind  map[string]int `json:"by_kind,omitempty"`
	List    []ErrorEntry   `json:"list,omitempty"`
}

// ErrorEntry is one runtime error. Where is the game-script location
// (backtrace[0]) when there is one, else the reported file and line.
type ErrorEntry struct {
	TS      float64 `json:"t_s"`
	Kind    string  `json:"kind"`
	Message string  `json:"message"`
	Where   string  `json:"where,omitempty"`
	Section string  `json:"section"`
}

// EventStats counts game events.
type EventStats struct {
	Total     int            `json:"total"`
	PerMinute float64        `json:"per_minute"`
	ByName    []NameCount    `json:"by_name"`
	Sources   map[string]int `json:"sources,omitempty"`
}

// NameCount is one event name's total.
type NameCount struct {
	Name      string  `json:"name"`
	Count     int     `json:"count"`
	PerMinute float64 `json:"per_minute"`
}

// Section is the stretch between one checkpoint and the next. Visit counts how
// many times this label had been marked by this point, so a retried section
// shows as visit 2, 3, and so on.
type Section struct {
	Index      int            `json:"index"`
	Label      string         `json:"label"`
	Visit      int            `json:"visit"`
	StartS     float64        `json:"start_s"`
	EndS       float64        `json:"end_s"`
	DurationS  float64        `json:"duration_s"`
	Frames     int            `json:"frames"`
	P95MS      float64        `json:"p95_ms"`
	Spikes     int            `json:"spikes"`
	Inputs     int            `json:"inputs"`
	Errors     int            `json:"errors"`
	EventTotal int            `json:"event_total"`
	Events     map[string]int `json:"events"`
}

// InputStats counts the events input.* commands injected.
type InputStats struct {
	Count     int            `json:"count"`
	PerMinute float64        `json:"per_minute"`
	ByType    map[string]int `json:"by_type,omitempty"`
}

// Finding names one concrete thing to look at.
type Finding struct {
	Severity string `json:"severity"`
	Code     string `json:"code"`
	Title    string `json:"title"`
	Detail   string `json:"detail,omitempty"`
	LookAt   string `json:"look_at,omitempty"`
}

// startSectionLabel names the stretch before the first checkpoint.
const startSectionLabel = "(start)"

// Analyze turns a session into a report.
func Analyze(s *Session, opts Options) Report {
	target := opts.TargetFPS
	if target <= 0 {
		target = DefaultTargetFPS
	}
	r := Report{
		Schema:  ReportSchema,
		Kind:    "swallowtail-playtest-report",
		Session: sessionInfo(s),
	}
	tl := newTimeline(s)
	r.Frames = frameStats(s.Frames.TimesMS, target)
	r.Sections = sections(s, tl)
	r.Spikes = spikes(s, tl, r.Frames, r.Sections)
	r.Counters = counters(s.Samples)
	r.Errors = errorStats(s, r.Sections)
	r.Events = eventStats(s)
	r.Input = inputStats(s)
	fillSections(s, tl, &r)
	r.Findings = findings(s, &r)
	return r
}

func sessionInfo(s *Session) SessionInfo {
	vp := make([]int, 0, len(s.ViewportSize))
	for _, v := range s.ViewportSize {
		vp = append(vp, int(v))
	}
	capture := s.ErrorsCapture
	if capture == "" {
		capture = "unknown"
	}
	return SessionInfo{
		Name: s.Name, ProjectName: s.ProjectName, EngineVersion: s.EngineVersion,
		DisplayServer: s.DisplayServer, Headless: s.Headless, OS: s.OS,
		Renderer: s.Renderer, Adapter: s.Adapter, VsyncMode: int(s.VsyncMode),
		MaxFPS: int(s.MaxFPS), TimeScale: s.TimeScale, ViewportSize: vp, Scene: s.Scene,
		StartedUnix: s.StartedUnix, DurationS: round(s.DurationMS/1000, 2), EndedBy: s.EndedBy,
		SampleEvery: int(s.SampleEvery), ErrorsCapture: capture,
		Truncated: s.Truncated, Dropped: s.Dropped,
	}
}

// timeline maps frame indices to session time.
type timeline struct {
	endMS []float64 // endMS[i]: when frame i ended, ms after the session started
}

func newTimeline(s *Session) timeline {
	end := make([]float64, len(s.Frames.TimesMS))
	t := s.Frames.FirstTickMS
	for i, ms := range s.Frames.TimesMS {
		t += ms
		end[i] = t
	}
	return timeline{end}
}

func (tl timeline) startMS(i int, times []float64) float64 { return tl.endMS[i] - times[i] }

func frameStats(times []float64, target float64) FrameStats {
	fs := FrameStats{Count: len(times), TargetFPS: target, BudgetMS: round(1000/target, 3)}
	if len(times) == 0 {
		return fs
	}
	sorted := slices.Clone(times)
	slices.Sort(sorted)
	total := 0.0
	slow := 0
	for _, ms := range sorted {
		total += ms
		if ms > fs.BudgetMS*slowFrameFactor {
			slow++
		}
	}
	avg := total / float64(len(sorted))
	fs.AvgMS = round(avg, 3)
	fs.AvgFPS = round(fpsOf(avg), 2)
	fs.P50MS = percentile(sorted, 0.50)
	fs.P95MS = percentile(sorted, 0.95)
	fs.P99MS = percentile(sorted, 0.99)
	fs.MaxMS = sorted[len(sorted)-1]
	fs.OnePercentLowFPS = round(fpsOf(worstMean(sorted, 0.01)), 2)
	fs.PointOnePercentLowFPS = round(fpsOf(worstMean(sorted, 0.001)), 2)
	fs.SlowFramesPct = round(100*float64(slow)/float64(len(sorted)), 2)
	return fs
}

// percentile is nearest-rank over an ascending slice.
func percentile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(q*float64(len(sorted)))) - 1
	return sorted[max(0, min(idx, len(sorted)-1))]
}

// worstMean is the mean of the slowest fraction q of an ascending slice, at
// least one value.
func worstMean(sorted []float64, q float64) float64 {
	k := max(1, int(math.Ceil(q*float64(len(sorted)))))
	sum := 0.0
	for _, ms := range sorted[len(sorted)-k:] {
		sum += ms
	}
	return sum / float64(k)
}

func fpsOf(ms float64) float64 {
	if ms <= 0 {
		return 0
	}
	return 1000 / ms
}

func spikes(s *Session, tl timeline, fs FrameStats, secs []Section) SpikeStats {
	times := s.Frames.TimesMS
	st := SpikeStats{}
	if len(times) < 2 {
		return st
	}
	st.ThresholdMS = round(max(fs.P50MS*spikeFactor, fs.P50MS+spikeMinExcessMS), 3)
	causes := causeList(s)
	var all []Spike
	for i := 0; i < len(times); i++ {
		if times[i] <= st.ThresholdMS {
			continue
		}
		j := i
		sp := Spike{}
		for j < len(times) && times[j] > st.ThresholdMS {
			sp.TotalMS += times[j]
			sp.WorstMS = max(sp.WorstMS, times[j])
			j++
		}
		start := tl.startMS(i, times)
		sp.TS = round(start/1000, 3)
		sp.Frame = int64(s.Frames.FirstFrame) + 1 + int64(i)
		sp.Frames = j - i
		sp.TotalMS = round(sp.TotalMS, 3)
		sp.Section = sectionLabelAt(secs, start)
		sp.PrecededBy = precedingCause(causes, start, tl.endMS[i])
		sp.Counters = spikeCounters(s.Samples, sp.Frame, sp.Frame+int64(sp.Frames)-1)
		st.Frames += sp.Frames
		all = append(all, sp)
		i = j - 1
	}
	st.Count = len(all)
	if mins := s.DurationMS / 60000; mins > 0 {
		st.PerMinute = round(float64(st.Count)/mins, 2)
	}
	slices.SortStableFunc(all, func(a, b Spike) int { return cmp.Compare(b.WorstMS, a.WorstMS) })
	if len(all) > maxListedSpikes {
		all = all[:maxListedSpikes]
	}
	st.Worst = all
	return st
}

type causeEntry struct {
	t      float64
	kind   string
	name   string
	source string
	data   map[string]any
}

func causeList(s *Session) []causeEntry {
	var out []causeEntry
	for _, in := range s.Inputs {
		out = append(out, causeEntry{in.TMS, "input", inputName(in), "agent", nil})
	}
	for _, ev := range s.Events {
		out = append(out, causeEntry{ev.TMS, "event", ev.Name, ev.Source, ev.Data})
	}
	for _, m := range s.Marks {
		out = append(out, causeEntry{m.TMS, "mark", m.Label, m.Source, nil})
	}
	slices.SortStableFunc(out, func(a, b causeEntry) int { return cmp.Compare(a.t, b.t) })
	return out
}

func inputName(in Input) string {
	state := ""
	if in.Pressed != nil {
		state = " up"
		if *in.Pressed {
			state = " down"
		}
	}
	switch in.Type {
	case "action":
		return "action " + in.Action + state
	case "key":
		return "key " + in.Keycode + state
	case "mouse_button":
		return fmt.Sprintf("mouse button %d%s", int(in.Button), state)
	case "mouse_motion":
		return "mouse motion"
	}
	return in.Type
}

// precedingCause is the latest cause no later than the end of the spike's first
// frame and no earlier than causeWindowMS before it began.
func precedingCause(causes []causeEntry, startMS, endMS float64) *Cause {
	idx := sort.Search(len(causes), func(k int) bool { return causes[k].t > endMS }) - 1
	if idx < 0 || causes[idx].t < startMS-causeWindowMS {
		return nil
	}
	c := causes[idx]
	return &Cause{Kind: c.kind, Name: c.name, GapMS: round(startMS-c.t, 1), Source: c.source, Data: c.data}
}

// spikeCounters is the change in the engine counters between the last regular
// sample before a spike and the spike sample the game took on it.
func spikeCounters(samples []Sample, first, last int64) map[string]float64 {
	at := -1
	for k, sm := range samples {
		if sm.Spike && int64(sm.Frame) >= first && int64(sm.Frame) <= last {
			at = k
			break
		}
	}
	if at <= 0 {
		return nil
	}
	prev := -1
	for k := at - 1; k >= 0; k-- {
		if !samples[k].Spike {
			prev = k
			break
		}
	}
	if prev < 0 {
		return nil
	}
	a, b := samples[prev], samples[at]
	return map[string]float64{
		"static_mb":  round((b.StaticMem-a.StaticMem)/mb, 2),
		"texture_mb": round((b.TextureMem-a.TextureMem)/mb, 2),
		"video_mb":   round((b.VideoMem-a.VideoMem)/mb, 2),
		"nodes":      b.Nodes - a.Nodes,
		"objects":    b.Objects - a.Objects,
	}
}

const mb = 1024 * 1024

// counters reads trends and averages off the regular every-N-frames samples
// only: a spike sample is taken on an anomalous frame, so letting it into a
// slope or an average would bend the steady-state numbers. It still counts
// toward a peak, since a peak is exactly what it caught.
func counters(all []Sample) CounterStats {
	cs := CounterStats{Samples: len(all)}
	var samples []Sample
	for _, sm := range all {
		if !sm.Spike {
			samples = append(samples, sm)
		}
	}
	if len(samples) == 0 {
		samples = all
	}
	if len(samples) == 0 {
		return cs
	}
	pick := func(f func(Sample) float64, scale float64) Trend {
		xs := make([]float64, len(samples))
		ys := make([]float64, len(samples))
		tr := Trend{Start: f(samples[0]) / scale, End: f(samples[len(samples)-1]) / scale}
		for k, sm := range samples {
			xs[k] = sm.TMS / 60000
			ys[k] = f(sm) / scale
		}
		for _, sm := range all {
			tr.Peak = max(tr.Peak, f(sm)/scale)
		}
		tr.SlopePerMin = slope(xs, ys)
		digits := 0
		if scale != 1 {
			digits = 2
		}
		tr.Start, tr.End, tr.Peak = round(tr.Start, digits), round(tr.End, digits), round(tr.Peak, digits)
		tr.SlopePerMin = round(tr.SlopePerMin, 3)
		return tr
	}
	avgMax := func(f func(Sample) float64) AvgMax {
		sum, top := 0.0, 0.0
		for _, sm := range samples {
			sum += f(sm)
			top = max(top, f(sm))
		}
		return AvgMax{Avg: round(sum/float64(len(samples)), 2), Max: round(top, 2)}
	}
	cs.StaticMB = pick(func(s Sample) float64 { return s.StaticMem }, mb)
	cs.VideoMB = pick(func(s Sample) float64 { return s.VideoMem }, mb)
	cs.TextureMB = pick(func(s Sample) float64 { return s.TextureMem }, mb)
	cs.Objects = pick(func(s Sample) float64 { return s.Objects }, 1)
	cs.Nodes = pick(func(s Sample) float64 { return s.Nodes }, 1)
	cs.Orphans = pick(func(s Sample) float64 { return s.Orphans }, 1)
	cs.DrawCalls = avgMax(func(s Sample) float64 { return s.DrawCalls })
	cs.Primitives = avgMax(func(s Sample) float64 { return s.Primitives })
	cs.ProcessMS = avgMax(func(s Sample) float64 { return s.ProcessMS })
	cs.PhysicsMS = avgMax(func(s Sample) float64 { return s.PhysicsMS })
	cs.Notes = append(cs.Notes, "process_ms and physics_ms come from Performance monitors the engine refreshes about once a second, so they are approximate; frame times come from the per-frame wall clock")
	if cs.DrawCalls.Max == 0 && cs.Primitives.Max == 0 {
		cs.Notes = append(cs.Notes, "draw calls and primitives read zero, which is what a headless or dummy renderer reports")
	}
	return cs
}

// slope is the least-squares slope of ys over xs, or 0 when xs do not vary.
func slope(xs, ys []float64) float64 {
	n := float64(len(xs))
	if n < 2 {
		return 0
	}
	var sx, sy, sxx, sxy float64
	for k := range xs {
		sx += xs[k]
		sy += ys[k]
		sxx += xs[k] * xs[k]
		sxy += xs[k] * ys[k]
	}
	den := n*sxx - sx*sx
	if den == 0 {
		return 0
	}
	return (n*sxy - sx*sy) / den
}

func errorStats(s *Session, secs []Section) ErrorStats {
	es := ErrorStats{Capture: s.ErrorsCapture, Count: len(s.Errors)}
	if es.Capture == "" {
		es.Capture = "unknown"
	}
	if len(s.Errors) == 0 {
		return es
	}
	es.ByKind = map[string]int{}
	for _, e := range s.Errors {
		es.ByKind[e.Kind]++
		if len(es.List) < maxListedErrors {
			es.List = append(es.List, ErrorEntry{
				TS: round(e.TMS/1000, 3), Kind: e.Kind, Message: e.Message,
				Where: errorWhere(e), Section: sectionLabelAt(secs, e.TMS),
			})
		}
	}
	return es
}

func errorWhere(e RuntimeError) string {
	if len(e.Backtrace) > 0 && e.Backtrace[0].File != "" {
		b := e.Backtrace[0]
		return fmt.Sprintf("%s:%d", b.File, int(b.Line))
	}
	if e.File != "" {
		return fmt.Sprintf("%s:%d", e.File, int(e.Line))
	}
	return ""
}

func perMinute(n int, durationMS float64) float64 {
	if durationMS <= 0 {
		return 0
	}
	return round(float64(n)/(durationMS/60000), 2)
}

func eventStats(s *Session) EventStats {
	es := EventStats{Total: len(s.Events), PerMinute: perMinute(len(s.Events), s.DurationMS)}
	counts := map[string]int{}
	for _, ev := range s.Events {
		counts[ev.Name]++
		if es.Sources == nil {
			es.Sources = map[string]int{}
		}
		es.Sources[ev.Source]++
	}
	for name, n := range counts {
		es.ByName = append(es.ByName, NameCount{name, n, perMinute(n, s.DurationMS)})
	}
	slices.SortFunc(es.ByName, func(a, b NameCount) int {
		if a.Count != b.Count {
			return cmp.Compare(b.Count, a.Count)
		}
		return strings.Compare(a.Name, b.Name)
	})
	return es
}

func inputStats(s *Session) InputStats {
	is := InputStats{Count: len(s.Inputs), PerMinute: perMinute(len(s.Inputs), s.DurationMS)}
	for _, in := range s.Inputs {
		if is.ByType == nil {
			is.ByType = map[string]int{}
		}
		is.ByType[in.Type]++
	}
	return is
}

// sections splits the session at its checkpoints. The stretch before the first
// mark is "(start)" and is listed only when it lasted longer than zero.
func sections(s *Session, tl timeline) []Section {
	marks := slices.Clone(s.Marks)
	slices.SortStableFunc(marks, func(a, b Mark) int { return cmp.Compare(a.TMS, b.TMS) })
	end := s.DurationMS
	if n := len(tl.endMS); n > 0 {
		end = max(end, tl.endMS[n-1])
	}
	var out []Section
	firstStart := end
	if len(marks) > 0 {
		firstStart = marks[0].TMS
	}
	if firstStart > 0 {
		out = append(out, Section{Label: startSectionLabel, Visit: 1, StartS: 0, EndS: firstStart / 1000})
	}
	visits := map[string]int{}
	for k, m := range marks {
		stop := end
		if k+1 < len(marks) {
			stop = marks[k+1].TMS
		}
		visits[m.Label]++
		out = append(out, Section{Label: m.Label, Visit: visits[m.Label], StartS: m.TMS / 1000, EndS: stop / 1000})
	}
	for k := range out {
		out[k].Index = k
		out[k].DurationS = round(out[k].EndS-out[k].StartS, 3)
		out[k].StartS = round(out[k].StartS, 3)
		out[k].EndS = round(out[k].EndS, 3)
		out[k].Events = map[string]int{}
	}
	return out
}

// sectionAt is the index of the section holding time tMS, or -1.
func sectionAt(secs []Section, tMS float64) int {
	if len(secs) == 0 {
		return -1
	}
	t := tMS / 1000
	idx := sort.Search(len(secs), func(k int) bool { return secs[k].StartS > t }) - 1
	return max(idx, 0)
}

func sectionLabelAt(secs []Section, tMS float64) string {
	if k := sectionAt(secs, tMS); k >= 0 {
		return sectionName(secs[k])
	}
	return ""
}

func sectionName(sec Section) string {
	if sec.Visit > 1 {
		return fmt.Sprintf("%s (visit %d)", sec.Label, sec.Visit)
	}
	return sec.Label
}

func fillSections(s *Session, tl timeline, r *Report) {
	secs := r.Sections
	if len(secs) == 0 {
		return
	}
	times := s.Frames.TimesMS
	perSection := make([][]float64, len(secs))
	for i, ms := range times {
		k := sectionAt(secs, tl.startMS(i, times))
		perSection[k] = append(perSection[k], ms)
		if ms > r.Spikes.ThresholdMS && r.Spikes.ThresholdMS > 0 && (i == 0 || times[i-1] <= r.Spikes.ThresholdMS) {
			secs[k].Spikes++
		}
	}
	for k := range secs {
		secs[k].Frames = len(perSection[k])
		if len(perSection[k]) > 0 {
			slices.Sort(perSection[k])
			secs[k].P95MS = percentile(perSection[k], 0.95)
		}
	}
	for _, in := range s.Inputs {
		secs[sectionAt(secs, in.TMS)].Inputs++
	}
	for _, e := range s.Errors {
		secs[sectionAt(secs, e.TMS)].Errors++
	}
	for _, ev := range s.Events {
		k := sectionAt(secs, ev.TMS)
		secs[k].Events[ev.Name]++
		secs[k].EventTotal++
	}
}

func round(v float64, digits int) float64 {
	p := math.Pow(10, float64(digits))
	return math.Round(v*p) / p
}
