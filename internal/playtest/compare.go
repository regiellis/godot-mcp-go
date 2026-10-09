package playtest

import (
	"fmt"
	"math"
	"slices"
	"strings"
)

// Verdicts for one metric and for a whole comparison.
const (
	VerdictImproved  = "improved"
	VerdictRegressed = "regressed"
	VerdictUnchanged = "unchanged"
	VerdictChanged   = "changed"  // a metric with no better direction moved
	VerdictUngraded  = "ungraded" // a session was too short for this metric to mean anything
)

// relativeTolerance is the share of the before value a metric must move by,
// on top of its absolute floor, before it counts as a change. Run-to-run noise
// on the same build sits inside it.
const relativeTolerance = 0.05

// Comparison diffs two reports: the same numbers side by side, a verdict per
// metric, and one overall verdict over the performance metrics.
type Comparison struct {
	Schema   int            `json:"schema"`
	Kind     string         `json:"kind"`
	Before   SessionRef     `json:"before"`
	After    SessionRef     `json:"after"`
	Verdict  string         `json:"verdict"`
	Warnings []string       `json:"warnings,omitempty"`
	Metrics  []MetricDelta  `json:"metrics"`
	Events   []EventDelta   `json:"events,omitempty"`
	Sections []SectionDelta `json:"sections,omitempty"`
}

// SessionRef identifies one side of a comparison.
type SessionRef struct {
	Source    string  `json:"source,omitempty"`
	Name      string  `json:"name"`
	Started   float64 `json:"started_unix"`
	DurationS float64 `json:"duration_s"`
}

// MetricDelta is one metric before and after. Better is "lower", "higher", or
// "none" for a number that describes the run rather than grades it.
type MetricDelta struct {
	Name     string   `json:"name"`
	Unit     string   `json:"unit"`
	Before   float64  `json:"before"`
	After    float64  `json:"after"`
	Delta    float64  `json:"delta"`
	DeltaPct *float64 `json:"delta_pct,omitempty"`
	Better   string   `json:"better"`
	Verdict  string   `json:"verdict"`
}

// EventDelta is one event name's count and rate on each side.
type EventDelta struct {
	Name            string  `json:"name"`
	Before          int     `json:"before"`
	After           int     `json:"after"`
	BeforePerMinute float64 `json:"before_per_minute"`
	AfterPerMinute  float64 `json:"after_per_minute"`
}

// SectionDelta compares the first visit of a checkpoint label on each side.
type SectionDelta struct {
	Label           string  `json:"label"`
	BeforeDurationS float64 `json:"before_duration_s"`
	AfterDurationS  float64 `json:"after_duration_s"`
	BeforeP95MS     float64 `json:"before_p95_ms"`
	AfterP95MS      float64 `json:"after_p95_ms"`
	BeforeEvents    int     `json:"before_events"`
	AfterEvents     int     `json:"after_events"`
	Missing         string  `json:"missing,omitempty"`
}

type metricSpec struct {
	name, unit, better string
	floor              float64
	get                func(Report) float64
	// minDurationS, when set, is how long both sessions must run before the
	// metric is graded. A memory slope over twenty seconds is noise.
	minDurationS float64
}

var metricSpecs = []metricSpec{
	{"frame_p50", "ms", "lower", 0.5, func(r Report) float64 { return r.Frames.P50MS }, 0},
	{"frame_p95", "ms", "lower", 0.5, func(r Report) float64 { return r.Frames.P95MS }, 0},
	{"frame_p99", "ms", "lower", 1, func(r Report) float64 { return r.Frames.P99MS }, 0},
	{"frame_max", "ms", "lower", 2, func(r Report) float64 { return r.Frames.MaxMS }, 0},
	{"avg_fps", "fps", "higher", 1, func(r Report) float64 { return r.Frames.AvgFPS }, 0},
	{"one_percent_low_fps", "fps", "higher", 1, func(r Report) float64 { return r.Frames.OnePercentLowFPS }, 0},
	{"slow_frames", "%", "lower", 1, func(r Report) float64 { return r.Frames.SlowFramesPct }, 0},
	{"spikes_per_minute", "/min", "lower", 0.5, func(r Report) float64 { return r.Spikes.PerMinute }, 0},
	{"static_mem_peak", "MB", "lower", 2, func(r Report) float64 { return r.Counters.StaticMB.Peak }, 0},
	{"static_mem_slope", "MB/min", "lower", 0.25, func(r Report) float64 { return r.Counters.StaticMB.SlopePerMin }, leakMinSessionS},
	{"texture_mem_peak", "MB", "lower", 2, func(r Report) float64 { return r.Counters.TextureMB.Peak }, 0},
	{"nodes_peak", "nodes", "lower", 5, func(r Report) float64 { return r.Counters.Nodes.Peak }, 0},
	{"orphans_end", "nodes", "lower", 1, func(r Report) float64 { return r.Counters.Orphans.End }, 0},
	{"draw_calls_avg", "calls", "lower", 5, func(r Report) float64 { return r.Counters.DrawCalls.Avg }, 0},
	{"primitives_avg", "prims", "lower", 100, func(r Report) float64 { return r.Counters.Primitives.Avg }, 0},
	{"runtime_errors", "errors", "lower", 0.5, func(r Report) float64 { return float64(r.Errors.Count) }, 0},
	{"input_per_minute", "/min", "none", 1, func(r Report) float64 { return r.Input.PerMinute }, 0},
	{"events_per_minute", "/min", "none", 0.5, func(r Report) float64 { return r.Events.PerMinute }, 0},
	{"duration", "s", "none", 1, func(r Report) float64 { return r.Session.DurationS }, 0},
}

// tailMinFrames is how many frames both sessions need before a tail metric is
// graded: enough that the tail holds about ten frames. On a few hundred frames
// the 1% low is two frames of vsync jitter, and grading it called two calm
// three-second runs a regression. The worst frame is one frame on any run; real
// hitches still grade through spikes_per_minute.
var tailMinFrames = map[string]int{
	"frame_p95":           200,
	"frame_p99":           1000,
	"frame_max":           1000,
	"one_percent_low_fps": 1000,
}

// shortTailGrossPct is how far a tail metric must move before a short run grades
// it anyway. Jitter moves a short run's tail by single-digit percents; a stall
// removed or added moves it by multiples, and hiding a 245 ms to 32 ms worst
// frame as ungraded threw away the one number the comparison was run for.
const shortTailGrossPct = 50.0

func grossChange(d MetricDelta) bool {
	return d.DeltaPct != nil && math.Abs(*d.DeltaPct) >= shortTailGrossPct
}

// Compare diffs two reports. The overall verdict is "regressed" when any graded
// metric got worse past its tolerance, "improved" when at least one got better
// and none got worse, and "unchanged" otherwise.
func Compare(before, after Report) Comparison {
	c := Comparison{
		Schema: ReportSchema,
		Kind:   "swallowtail-playtest-compare",
		Before: ref(before),
		After:  ref(after),
	}
	c.Warnings = contextWarnings(before, after)
	improved, regressed := 0, 0
	for _, m := range metricSpecs {
		d := delta(m, m.get(before), m.get(after))
		tooShort := m.minDurationS > 0 && min(before.Session.DurationS, after.Session.DurationS) < m.minDurationS
		tooFew := min(before.Frames.Count, after.Frames.Count) < tailMinFrames[m.name] && !grossChange(d)
		if (tooShort || tooFew) && d.Verdict != VerdictUnchanged {
			d.Verdict = VerdictUngraded
		}
		switch d.Verdict {
		case VerdictImproved:
			improved++
		case VerdictRegressed:
			regressed++
		}
		c.Metrics = append(c.Metrics, d)
	}
	switch {
	case regressed > 0:
		c.Verdict = VerdictRegressed
	case improved > 0:
		c.Verdict = VerdictImproved
	default:
		c.Verdict = VerdictUnchanged
	}
	c.Events = eventDeltas(before, after)
	c.Sections = sectionDeltas(before, after)
	return c
}

func ref(r Report) SessionRef {
	return SessionRef{Source: r.Source, Name: r.Session.Name, Started: r.Session.StartedUnix, DurationS: r.Session.DurationS}
}

func delta(m metricSpec, before, after float64) MetricDelta {
	d := MetricDelta{Name: m.name, Unit: m.unit, Before: before, After: after, Delta: round(after-before, 3), Better: m.better}
	if before != 0 {
		pct := round(100*(after-before)/math.Abs(before), 1)
		d.DeltaPct = &pct
	}
	tol := max(m.floor, relativeTolerance*math.Abs(before))
	switch {
	case math.Abs(after-before) <= tol:
		d.Verdict = VerdictUnchanged
	case m.better == "none":
		d.Verdict = VerdictChanged
	case (after < before) == (m.better == "lower"):
		d.Verdict = VerdictImproved
	default:
		d.Verdict = VerdictRegressed
	}
	return d
}

// contextWarnings names every difference in how the two sessions were run that
// moves frame times on its own, so a "regression" caused by a different window
// size or a headless run is read as that.
func contextWarnings(a, b Report) []string {
	var w []string
	sa, sb := a.Session, b.Session
	check := func(what string, x, y any) {
		if fmt.Sprint(x) != fmt.Sprint(y) {
			w = append(w, fmt.Sprintf("%s differs: %v before, %v after", what, x, y))
		}
	}
	check("headless", sa.Headless, sb.Headless)
	check("display server", sa.DisplayServer, sb.DisplayServer)
	check("engine version", sa.EngineVersion, sb.EngineVersion)
	check("renderer", sa.Renderer, sb.Renderer)
	check("GPU", sa.Adapter, sb.Adapter)
	check("vsync mode", sa.VsyncMode, sb.VsyncMode)
	check("max_fps", sa.MaxFPS, sb.MaxFPS)
	check("time scale", sa.TimeScale, sb.TimeScale)
	check("viewport size", sa.ViewportSize, sb.ViewportSize)
	check("project", sa.ProjectName, sb.ProjectName)
	check("scene", sa.Scene, sb.Scene)
	if a.Frames.TargetFPS != b.Frames.TargetFPS {
		w = append(w, fmt.Sprintf("the reports used different --target-fps (%g and %g)", a.Frames.TargetFPS, b.Frames.TargetFPS))
	}
	for _, side := range []struct {
		label string
		r     Report
	}{{"before", a}, {"after", b}} {
		if side.r.Session.DurationS < shortSessionS || side.r.Frames.Count < shortSessionFrames {
			w = append(w, fmt.Sprintf("the %s session is short (%.1fs, %d frames), so its percentiles are noisy", side.label, side.r.Session.DurationS, side.r.Frames.Count))
		}
		if side.r.Session.Truncated {
			w = append(w, fmt.Sprintf("the %s session hit a recorder cap and is partial", side.label))
		}
	}
	return w
}

func eventDeltas(a, b Report) []EventDelta {
	rows := map[string]*EventDelta{}
	var names []string
	get := func(name string) *EventDelta {
		if rows[name] == nil {
			rows[name] = &EventDelta{Name: name}
			names = append(names, name)
		}
		return rows[name]
	}
	for _, nc := range a.Events.ByName {
		d := get(nc.Name)
		d.Before, d.BeforePerMinute = nc.Count, nc.PerMinute
	}
	for _, nc := range b.Events.ByName {
		d := get(nc.Name)
		d.After, d.AfterPerMinute = nc.Count, nc.PerMinute
	}
	slices.Sort(names)
	out := make([]EventDelta, 0, len(names))
	for _, n := range names {
		out = append(out, *rows[n])
	}
	return out
}

func sectionDeltas(a, b Report) []SectionDelta {
	first := func(r Report) (map[string]Section, []string) {
		m := map[string]Section{}
		var order []string
		for _, s := range r.Sections {
			if s.Visit != 1 {
				continue
			}
			if _, ok := m[s.Label]; !ok {
				m[s.Label] = s
				order = append(order, s.Label)
			}
		}
		return m, order
	}
	ma, oa := first(a)
	mb, ob := first(b)
	seen := map[string]bool{}
	var out []SectionDelta
	for _, label := range append(oa, ob...) {
		if seen[label] {
			continue
		}
		seen[label] = true
		x, okA := ma[label]
		y, okB := mb[label]
		d := SectionDelta{Label: label}
		if okA {
			d.BeforeDurationS, d.BeforeP95MS, d.BeforeEvents = x.DurationS, x.P95MS, x.EventTotal
		}
		if okB {
			d.AfterDurationS, d.AfterP95MS, d.AfterEvents = y.DurationS, y.P95MS, y.EventTotal
		}
		switch {
		case !okA:
			d.Missing = "before"
		case !okB:
			d.Missing = "after"
		}
		out = append(out, d)
	}
	if len(out) == 1 && strings.EqualFold(out[0].Label, startSectionLabel) {
		return nil
	}
	return out
}
