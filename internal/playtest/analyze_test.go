package playtest

import (
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fixture builds a 1000-frame session with known numbers:
//   - 995 frames at 16 ms; spikes at index 200 (50 ms), 500-502 (40, 45, 40 ms,
//     one merged spike) and 800 (60 ms); first_tick_ms 10, first_frame 100, so
//     frame index i is process frame 101+i and starts at 10+sum(times[:i]).
//   - an action input 10 ms before the index-200 spike, a "death" event 44 ms
//     before the merged spike and 5 ms before the index-800 spike.
//   - marks: wave 1 at 1 s, wave 2 at 5 s, wave 1 again at 9 s (a retry).
//   - four deaths, three of them inside wave 2.
//   - one script error at 4 s from res://enemy.gd:42.
//   - a spike sample on frame 901 carrying +6 MB of texture memory.
func fixture() *Session {
	times := make([]float64, 1000)
	for i := range times {
		times[i] = 16
	}
	times[200] = 50
	times[500], times[501], times[502] = 40, 45, 40
	times[800] = 60
	start := func(i int) float64 {
		t := 10.0
		for _, ms := range times[:i] {
			t += ms
		}
		return t
	}
	pressed := true
	s := &Session{
		Schema: 1, Kind: SessionKind, Name: "fixture", ProjectName: "Fixture", EngineVersion: "4.7.2",
		DisplayServer: "Windows", Renderer: "forward_plus", Adapter: "GPU", VsyncMode: 1,
		ViewportSize: []float64{1280, 720}, Scene: "res://main.tscn",
		DurationMS: start(1000), EndedBy: "stop", SampleEvery: 30, ErrorsCapture: "on",
		Frames: FrameSeries{FirstFrame: 100, FirstTickMS: 10, Count: 1000, TimesMS: times},
		Marks: []Mark{
			{TMS: 1000, Label: "wave 1", Source: "cli"},
			{TMS: 5000, Label: "wave 2", Source: "cli"},
			{TMS: 9000, Label: "wave 1", Source: "game"},
		},
		Inputs: []Input{{TMS: start(200) - 10, Type: "key", Keycode: "KEY_W", Pressed: &pressed}},
		Events: []Event{
			{TMS: 6000, Name: "death", Source: "game"},
			{TMS: 7000, Name: "death", Source: "game"},
			{TMS: start(500) - 44, Name: "death", Source: "game"},
			{TMS: start(800) - 5, Name: "death", Source: "game"},
			{TMS: 2000, Name: "pickup", Source: "cli"},
		},
		Errors: []RuntimeError{{
			TMS: 4000, Kind: "script", Message: "Invalid access to property 'hp'",
			File: "core/variant.cpp", Line: 10,
			Backtrace: []BacktraceFrame{{Function: "_on_hit", File: "res://enemy.gd", Line: 42}},
		}},
	}
	for k := 0; k*30 < 1000; k++ {
		i := k * 30
		s.Samples = append(s.Samples, Sample{TMS: start(i), Frame: float64(101 + i), StaticMem: 100 * mb, TextureMem: 50 * mb, Nodes: 400, Objects: 3000, DrawCalls: 120, Primitives: 9000})
		if i == 780 { // the regular sample before the index-800 spike
			s.Samples = append(s.Samples, Sample{TMS: start(801), Frame: 901, StaticMem: 100 * mb, TextureMem: 56 * mb, Nodes: 400, Objects: 3001, Spike: true, FrameMS: 60})
		}
	}
	return s
}

func near(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol {
		t.Errorf("%s = %v, want %v", what, got, want)
	}
}

func findingCodes(r Report) []string {
	var out []string
	for _, f := range r.Findings {
		out = append(out, f.Code)
	}
	return out
}

func TestPercentileAndLows(t *testing.T) {
	vals := make([]float64, 100)
	for i := range vals {
		vals[i] = float64(i + 1)
	}
	if got := percentile(vals, 0.50); got != 50 {
		t.Errorf("p50 = %v", got)
	}
	if got := percentile(vals, 0.95); got != 95 {
		t.Errorf("p95 = %v", got)
	}
	if got := percentile(vals, 0.99); got != 99 {
		t.Errorf("p99 = %v", got)
	}
	// 1% of 100 frames is one frame, the slowest: 100 ms is 10 fps.
	if got := fpsOf(worstMean(vals, 0.01)); got != 10 {
		t.Errorf("1%% low = %v", got)
	}
	// Ten frames: 1% rounds up to one frame, never zero.
	if got := worstMean(vals[:10], 0.01); got != 10 {
		t.Errorf("worstMean of a short series = %v", got)
	}
}

func TestAnalyzeFrames(t *testing.T) {
	r := Analyze(fixture(), Options{})
	f := r.Frames
	if f.Count != 1000 || f.TargetFPS != 60 {
		t.Fatalf("count/target = %d/%v", f.Count, f.TargetFPS)
	}
	near(t, "budget", f.BudgetMS, 16.667, 0.001)
	if f.P50MS != 16 || f.P95MS != 16 || f.P99MS != 16 || f.MaxMS != 60 {
		t.Errorf("percentiles = %v/%v/%v/%v", f.P50MS, f.P95MS, f.P99MS, f.MaxMS)
	}
	// Worst 1% is ten frames: 60+50+45+40+40 and five at 16 = 315 ms, mean 31.5.
	near(t, "1% low", f.OnePercentLowFPS, 31.75, 0.01)
	// 16155 ms over 1000 frames.
	near(t, "avg fps", f.AvgFPS, 61.9, 0.01)
	near(t, "slow frames pct", f.SlowFramesPct, 0.5, 0.001)
}

func TestAnalyzeSpikesAttributeCauseAndCounters(t *testing.T) {
	r := Analyze(fixture(), Options{})
	sp := r.Spikes
	// Threshold: max(2 x 16, 16 + 8) = 32. The three-frame run merges.
	if sp.ThresholdMS != 32 || sp.Count != 3 || sp.Frames != 5 {
		t.Fatalf("threshold/count/frames = %v/%d/%d", sp.ThresholdMS, sp.Count, sp.Frames)
	}
	worst := sp.Worst[0]
	if worst.WorstMS != 60 || worst.Frame != 901 || worst.Frames != 1 {
		t.Fatalf("worst spike = %+v", worst)
	}
	if worst.PrecededBy == nil || worst.PrecededBy.Kind != "event" || worst.PrecededBy.Name != "death" || worst.PrecededBy.GapMS != 5 {
		t.Errorf("worst spike cause = %+v", worst.PrecededBy)
	}
	if worst.Counters["texture_mb"] != 6 || worst.Counters["objects"] != 1 {
		t.Errorf("worst spike counters = %v", worst.Counters)
	}
	if worst.Section != "wave 1 (visit 2)" {
		t.Errorf("worst spike section = %q", worst.Section)
	}
	second := sp.Worst[1]
	if second.WorstMS != 50 || second.PrecededBy == nil || second.PrecededBy.Name != "key KEY_W down" || second.PrecededBy.GapMS != 10 {
		t.Errorf("second spike = %+v cause %+v", second, second.PrecededBy)
	}
	merged := sp.Worst[2]
	if merged.Frames != 3 || merged.TotalMS != 125 || merged.WorstMS != 45 || merged.PrecededBy == nil || merged.PrecededBy.GapMS != 44 {
		t.Errorf("merged spike = %+v cause %+v", merged, merged.PrecededBy)
	}
}

func TestAnalyzeSectionsFunnelAndFindings(t *testing.T) {
	r := Analyze(fixture(), Options{})
	labels := []string{}
	for _, s := range r.Sections {
		labels = append(labels, sectionName(s))
	}
	want := []string{"(start)", "wave 1", "wave 2", "wave 1 (visit 2)"}
	if !slices.Equal(labels, want) {
		t.Fatalf("sections = %v, want %v", labels, want)
	}
	w2 := r.Sections[2]
	if w2.Events["death"] != 3 || w2.DurationS != 4 || w2.Spikes != 1 {
		t.Errorf("wave 2 = %+v", w2)
	}
	if r.Sections[1].Errors != 1 || r.Sections[1].Events["pickup"] != 1 {
		t.Errorf("wave 1 = %+v", r.Sections[1])
	}
	if r.Sections[0].Inputs != 0 || r.Sections[1].Inputs != 1 {
		t.Errorf("inputs per section = %d/%d", r.Sections[0].Inputs, r.Sections[1].Inputs)
	}
	if r.Events.Total != 5 || r.Events.ByName[0].Name != "death" || r.Events.ByName[0].Count != 4 {
		t.Errorf("events = %+v", r.Events)
	}
	if r.Errors.Count != 1 || r.Errors.List[0].Where != "res://enemy.gd:42" || r.Errors.List[0].Section != "wave 1" {
		t.Errorf("errors = %+v", r.Errors)
	}
	codes := findingCodes(r)
	for _, code := range []string{"runtime_errors", "spike_cause", "spike_texture_upload", "event_cluster", "section_retries"} {
		if !slices.Contains(codes, code) {
			t.Errorf("findings %v lack %s", codes, code)
		}
	}
	for _, code := range []string{"memory_growth", "headless", "short_session", "no_events", "below_target"} {
		if slices.Contains(codes, code) {
			t.Errorf("findings %v should not hold %s", codes, code)
		}
	}
	if r.Findings[0].Severity != SeverityError || r.Findings[0].LookAt != "res://enemy.gd:42" {
		t.Errorf("first finding = %+v", r.Findings[0])
	}
	for _, f := range r.Findings {
		if f.Code == "spike_cause" && !strings.Contains(f.Title, "2 of 3 spikes follow event 'death'") {
			t.Errorf("spike_cause title = %q", f.Title)
		}
		if f.Code == "event_cluster" && !strings.Contains(f.Title, "'death' concentrates in section 'wave 2': 3 of 4") {
			t.Errorf("event_cluster title = %q", f.Title)
		}
	}
}

// leaky is two minutes of steady frames with static memory climbing 2 MB a
// minute and orphans climbing to 30, recorded headless with no input or events.
func leaky() *Session {
	times := make([]float64, 7200)
	for i := range times {
		times[i] = 1000.0 / 60
	}
	s := &Session{
		Schema: 1, Kind: SessionKind, Name: "leaky", Headless: true, DisplayServer: "headless",
		DurationMS: 120000, SampleEvery: 60, ErrorsCapture: "on",
		Frames: FrameSeries{FirstFrame: 0, Count: 7200, TimesMS: times},
	}
	for k := 0; k <= 120; k++ {
		tm := float64(k) * 1000
		s.Samples = append(s.Samples, Sample{
			TMS: tm, Frame: float64(k * 60), StaticMem: 100*mb + 2*mb*tm/60000,
			Orphans: float64(k / 4), Nodes: 300,
		})
	}
	return s
}

func TestAnalyzeMemorySlopeAndLeakFindings(t *testing.T) {
	r := Analyze(leaky(), Options{})
	near(t, "static slope", r.Counters.StaticMB.SlopePerMin, 2, 0.001)
	if r.Counters.StaticMB.Start != 100 || r.Counters.StaticMB.End != 104 || r.Counters.Orphans.End != 30 {
		t.Errorf("counters = %+v", r.Counters)
	}
	codes := findingCodes(r)
	for _, code := range []string{"memory_growth", "orphan_growth", "headless", "no_events", "no_input"} {
		if !slices.Contains(codes, code) {
			t.Errorf("findings %v lack %s", codes, code)
		}
	}
	if slices.Contains(codes, "node_growth") || r.Spikes.Count != 0 {
		t.Errorf("unexpected node_growth or spikes: %v, %d", codes, r.Spikes.Count)
	}
}

func TestTargetFPSMovesTheBudget(t *testing.T) {
	r := Analyze(fixture(), Options{TargetFPS: 120})
	near(t, "budget", r.Frames.BudgetMS, 8.333, 0.001)
	if !slices.Contains(findingCodes(r), "below_target") {
		t.Errorf("a 16 ms median against a 120 fps target should be below_target: %v", findingCodes(r))
	}
}

func TestParseGodotStyleFixture(t *testing.T) {
	s, err := Load(filepath.Join("testdata", "session_godot.json"))
	if err != nil {
		t.Fatal(err)
	}
	r := Analyze(s, Options{})
	if r.Frames.Count != 400 || r.Frames.MaxMS != 48.5 || r.Spikes.Count != 2 {
		t.Fatalf("frames %d max %v spikes %d", r.Frames.Count, r.Frames.MaxMS, r.Spikes.Count)
	}
	if c := r.Spikes.Worst[0].PrecededBy; c == nil || c.Name != "action jump down" || c.GapMS != 10 {
		t.Errorf("worst spike cause = %+v", c)
	}
	if c := r.Spikes.Worst[1].PrecededBy; c == nil || c.Name != "death" || c.Source != "game" {
		t.Errorf("second spike cause = %+v", c)
	}
	if r.Session.ViewportSize[0] != 1280 || r.Counters.DrawCalls.Max != 118 {
		t.Errorf("session/counters = %+v %+v", r.Session, r.Counters.DrawCalls)
	}
}

func TestParseRefusesOtherDocuments(t *testing.T) {
	for _, doc := range []string{
		`{"schema":1,"kind":"something-else"}`,
		`{"schema":2,"kind":"swallowtail-playtest"}`,
		`[1,2,3]`,
	} {
		if _, err := Parse([]byte(doc)); err == nil {
			t.Errorf("Parse(%s) accepted it", doc)
		}
	}
}

func TestNewestOrdersByModTimeAndSkipsPartials(t *testing.T) {
	dir := t.TempDir()
	base := time.Now().Add(-time.Hour)
	for i, name := range []string{"20261008-100000_a.json", "20261008-110000_b.json", "20261008-120000_c.json"} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
		mt := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(dir, "20261008-130000_d.json.part"), []byte("{"), 0o644)
	_ = os.Mkdir(filepath.Join(dir, "sub.json"), 0o755)
	got, err := Newest(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, p := range got {
		names = append(names, filepath.Base(p))
	}
	want := []string{"20261008-120000_c.json", "20261008-110000_b.json", "20261008-100000_a.json"}
	if !slices.Equal(names, want) {
		t.Errorf("Newest = %v, want %v", names, want)
	}
	if _, err := Newest(filepath.Join(dir, "missing")); err == nil {
		t.Error("Newest on a missing dir succeeded")
	}
}

func TestCompareVerdicts(t *testing.T) {
	before := Analyze(fixture(), Options{})

	smooth := fixture()
	for i := range smooth.Frames.TimesMS {
		smooth.Frames.TimesMS[i] = 16
	}
	smooth.Errors = nil
	after := Analyze(smooth, Options{})
	c := Compare(before, after)
	if c.Verdict != VerdictImproved {
		t.Errorf("verdict = %s", c.Verdict)
	}
	byName := map[string]MetricDelta{}
	for _, m := range c.Metrics {
		byName[m.Name] = m
	}
	if byName["frame_max"].Verdict != VerdictImproved || byName["runtime_errors"].Verdict != VerdictImproved {
		t.Errorf("metrics = %+v / %+v", byName["frame_max"], byName["runtime_errors"])
	}
	if byName["frame_p50"].Verdict != VerdictUnchanged {
		t.Errorf("p50 = %+v", byName["frame_p50"])
	}

	slow := fixture()
	for i := range slow.Frames.TimesMS {
		slow.Frames.TimesMS[i] += 4
	}
	slow.Headless = true
	c = Compare(before, Analyze(slow, Options{}))
	if c.Verdict != VerdictRegressed {
		t.Errorf("slower run verdict = %s", c.Verdict)
	}
	if len(c.Warnings) == 0 || !strings.Contains(c.Warnings[0], "headless differs") {
		t.Errorf("warnings = %v", c.Warnings)
	}
	md := CompareMarkdown(c)
	if !strings.Contains(md, "Verdict: **regressed**") || !strings.Contains(md, "| frame_p50 (ms) | 16 | 20 | +4 (+25%) | regressed |") {
		t.Errorf("compare markdown:\n%s", md)
	}
}

// Two short calm runs must not read as a regression from tail noise.
func TestCompareLeavesShortTailsUngraded(t *testing.T) {
	short := func(spike float64) Report {
		s := fixture()
		s.Frames.TimesMS = make([]float64, 180)
		for i := range s.Frames.TimesMS {
			s.Frames.TimesMS[i] = 16.6
		}
		// Two slow frames, so p99 and the 1% low move along with the worst frame.
		s.Frames.TimesMS[60] = spike
		s.Frames.TimesMS[120] = spike
		s.Frames.Count = float64(len(s.Frames.TimesMS))
		s.Errors = nil
		return Analyze(s, Options{})
	}
	c := Compare(short(18.2), short(21.5))
	byName := map[string]MetricDelta{}
	for _, m := range c.Metrics {
		byName[m.Name] = m
	}
	for _, name := range []string{"frame_p99", "frame_max", "one_percent_low_fps"} {
		if byName[name].Verdict != VerdictUngraded {
			t.Errorf("%s = %+v, want ungraded on 180 frames", name, byName[name])
		}
	}
	if c.Verdict == VerdictRegressed {
		t.Errorf("verdict = regressed on two calm 180-frame runs: %+v", c.Metrics)
	}

	// A stall removed is a multiple, not jitter: a short run still grades it.
	fixed := Compare(short(245), short(17))
	for _, m := range fixed.Metrics {
		if m.Name == "frame_max" && m.Verdict != VerdictImproved {
			t.Errorf("frame_max 245 -> 17 ms on 180 frames = %+v, want improved", m)
		}
	}
}

// Two events sharing a name are told apart by their data, so a spike's cause
// carries it into both report forms.
func TestSpikeCauseCarriesEventData(t *testing.T) {
	s := fixture()
	for i := range s.Events {
		if s.Events[i].Name == "death" {
			s.Events[i].Data = map[string]any{"name": "Coin2"}
		}
	}
	r := Analyze(s, Options{})
	found := false
	for _, sp := range r.Spikes.Worst {
		if c := sp.PrecededBy; c != nil && c.Name == "death" && c.Data["name"] == "Coin2" {
			found = true
		}
	}
	if !found {
		t.Errorf("no spike cause carries the event data: %+v", r.Spikes.Worst)
	}
	if md := Markdown(r); !strings.Contains(md, `event 'death' {"name":"Coin2"}, 5 ms before`) {
		t.Errorf("markdown spike row lacks the event data:\n%s", md)
	}
}

func TestMarkdownCarriesTheNumbers(t *testing.T) {
	md := Markdown(Analyze(fixture(), Options{}))
	for _, want := range []string{
		"# Playtest report: fixture",
		"| p50 / p95 / p99 | 16 / 16 / 16 ms |",
		"| 1% low / 0.1% low | 31.8 / 16.7 fps |",
		"| 12.92s | 60 ms | 1 | wave 1 (visit 2) | event 'death', 5 ms before | texture +6 MB, objects +1 |",
		"| 2 | wave 2 | 5s | 4s |",
		"**error** 1 runtime error(s) while recording.",
	} {
		if !strings.Contains(md, want) {
			t.Errorf("markdown lacks %q\n%s", want, md)
		}
	}
	if strings.ContainsRune(md, '—') {
		t.Error("markdown carries an em dash")
	}
}
