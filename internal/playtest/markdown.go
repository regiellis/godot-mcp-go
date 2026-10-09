package playtest

import (
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"
)

// maxEventColumns caps the event columns in the sections table; the events
// table below it still lists every name.
const maxEventColumns = 6

// Markdown renders a report.
func Markdown(r Report) string {
	var b strings.Builder
	s := r.Session
	name := s.Name
	if name == "" {
		name = "session"
	}
	fmt.Fprintf(&b, "# Playtest report: %s\n\n", cell(name))
	ctx := []string{}
	if s.ProjectName != "" {
		ctx = append(ctx, s.ProjectName)
	}
	if s.EngineVersion != "" {
		ctx = append(ctx, "Godot "+s.EngineVersion)
	}
	display := s.DisplayServer
	if s.Headless && !strings.EqualFold(display, "headless") {
		display += " (headless)"
	}
	ctx = append(ctx, display, fmt.Sprintf("%.1fs", s.DurationS))
	if s.StartedUnix > 0 {
		ctx = append(ctx, "started "+time.Unix(int64(s.StartedUnix), 0).Format("2006-01-02 15:04:05"))
	}
	fmt.Fprintf(&b, "%s. Ended by %s.\n", strings.Join(ctx, ", "), orDash(s.EndedBy))
	if s.Scene != "" {
		fmt.Fprintf(&b, "Scene `%s`", s.Scene)
		if len(s.ViewportSize) == 2 {
			fmt.Fprintf(&b, " at %dx%d", s.ViewportSize[0], s.ViewportSize[1])
		}
		if s.Adapter != "" {
			fmt.Fprintf(&b, " on %s", s.Adapter)
		}
		b.WriteString(".\n")
	}
	if r.Source != "" {
		fmt.Fprintf(&b, "Session file: `%s`\n", r.Source)
	}

	b.WriteString("\n## Findings\n\n")
	if len(r.Findings) == 0 {
		b.WriteString("Nothing stood out.\n")
	}
	for _, f := range r.Findings {
		fmt.Fprintf(&b, "- **%s** %s.", f.Severity, strings.TrimSuffix(f.Title, "."))
		if f.Detail != "" {
			b.WriteString(" " + f.Detail)
		}
		if f.LookAt != "" {
			b.WriteString(" Look at: " + f.LookAt + ".")
		}
		b.WriteString("\n")
	}

	fr := r.Frames
	b.WriteString("\n## Frame time\n\n")
	if fr.Count == 0 {
		b.WriteString("No frames were recorded.\n")
	} else {
		fmt.Fprintf(&b, "Budget %.2f ms for a %g fps target. Wall-clock time between frames, so vsync and pacing count.\n\n", fr.BudgetMS, fr.TargetFPS)
		b.WriteString("| Metric | Value |\n| --- | --- |\n")
		fmt.Fprintf(&b, "| Frames | %d |\n", fr.Count)
		fmt.Fprintf(&b, "| Average | %s ms (%s fps) |\n", num(fr.AvgMS, 2), num(fr.AvgFPS, 1))
		fmt.Fprintf(&b, "| p50 / p95 / p99 | %s / %s / %s ms |\n", num(fr.P50MS, 2), num(fr.P95MS, 2), num(fr.P99MS, 2))
		fmt.Fprintf(&b, "| Worst frame | %s ms |\n", num(fr.MaxMS, 2))
		fmt.Fprintf(&b, "| 1%% low / 0.1%% low | %s / %s fps |\n", num(fr.OnePercentLowFPS, 1), num(fr.PointOnePercentLowFPS, 1))
		fmt.Fprintf(&b, "| Frames over %s ms | %s%% |\n", num(fr.BudgetMS*slowFrameFactor, 2), num(fr.SlowFramesPct, 2))
	}

	sp := r.Spikes
	b.WriteString("\n## Spikes\n\n")
	if sp.Count == 0 {
		if sp.ThresholdMS > 0 {
			fmt.Fprintf(&b, "None over the %s ms threshold.\n", num(sp.ThresholdMS, 2))
		} else {
			b.WriteString("Not enough frames to judge.\n")
		}
	} else {
		fmt.Fprintf(&b, "%d spike(s) over %s ms (twice the median and at least 8 ms over it), %s per minute, %d frame(s) in total. Worst first:\n\n",
			sp.Count, num(sp.ThresholdMS, 2), num(sp.PerMinute, 2), sp.Frames)
		b.WriteString("| Time | Worst | Frames | Section | Preceded by | Counter change on the frame |\n| --- | --- | --- | --- | --- | --- |\n")
		for _, s := range sp.Worst {
			cause := "nothing in the last second"
			if c := s.PrecededBy; c != nil {
				// A negative gap is a cause recorded inside the slow frame itself,
				// which is the usual reading when game code does the slow work.
				when := num(c.GapMS, 0) + " ms before"
				if c.GapMS < 0 {
					when = num(-c.GapMS, 0) + " ms into the frame"
				}
				cause = fmt.Sprintf("%s '%s'%s, %s", c.Kind, cell(c.Name), cell(causeData(c)), when)
			}
			fmt.Fprintf(&b, "| %ss | %s ms | %d | %s | %s | %s |\n", num(s.TS, 2), num(s.WorstMS, 1), s.Frames, cell(s.Section), cause, counterDeltas(s.Counters))
		}
	}

	c := r.Counters
	b.WriteString("\n## Memory and engine counters\n\n")
	if c.Samples == 0 {
		b.WriteString("No counter samples were recorded.\n")
	} else {
		fmt.Fprintf(&b, "%d samples, one every %d frames plus one on each spike frame.\n\n", c.Samples, s.SampleEvery)
		b.WriteString("| Counter | Start | End | Peak | Slope per minute |\n| --- | --- | --- | --- | --- |\n")
		for _, row := range []struct {
			label string
			t     Trend
			d     int
		}{
			{"Static memory (MB)", c.StaticMB, 2}, {"Video memory (MB)", c.VideoMB, 2}, {"Texture memory (MB)", c.TextureMB, 2},
			{"Objects", c.Objects, 0}, {"Nodes", c.Nodes, 0}, {"Orphan nodes", c.Orphans, 0},
		} {
			fmt.Fprintf(&b, "| %s | %s | %s | %s | %s |\n", row.label, num(row.t.Start, row.d), num(row.t.End, row.d), num(row.t.Peak, row.d), signed(row.t.SlopePerMin, 2))
		}
		b.WriteString("\n| Counter | Average | Max |\n| --- | --- | --- |\n")
		fmt.Fprintf(&b, "| Draw calls | %s | %s |\n", num(c.DrawCalls.Avg, 1), num(c.DrawCalls.Max, 0))
		fmt.Fprintf(&b, "| Primitives | %s | %s |\n", num(c.Primitives.Avg, 0), num(c.Primitives.Max, 0))
		fmt.Fprintf(&b, "| Process time (ms) | %s | %s |\n", num(c.ProcessMS.Avg, 2), num(c.ProcessMS.Max, 2))
		fmt.Fprintf(&b, "| Physics time (ms) | %s | %s |\n", num(c.PhysicsMS.Avg, 2), num(c.PhysicsMS.Max, 2))
		for _, n := range c.Notes {
			fmt.Fprintf(&b, "\nNote: %s.\n", n)
		}
	}

	b.WriteString("\n## Sections\n\n")
	if len(r.Sections) == 0 {
		b.WriteString("No sections.\n")
	} else {
		cols := eventColumns(r)
		b.WriteString("Each checkpoint (playtest mark) starts a section.\n\n")
		b.WriteString("| # | Section | Start | Duration | Frames | p95 ms | Spikes | Inputs | Errors |")
		for _, col := range cols {
			b.WriteString(" " + cell(col) + " |")
		}
		b.WriteString("\n|" + strings.Repeat(" --- |", 9+len(cols)) + "\n")
		for _, sec := range r.Sections {
			fmt.Fprintf(&b, "| %d | %s | %ss | %ss | %d | %s | %d | %d | %d |", sec.Index, cell(sectionName(sec)), num(sec.StartS, 1), num(sec.DurationS, 1),
				sec.Frames, num(sec.P95MS, 2), sec.Spikes, sec.Inputs, sec.Errors)
			for _, col := range cols {
				fmt.Fprintf(&b, " %d |", sec.Events[col])
			}
			b.WriteString("\n")
		}
	}

	ev := r.Events
	b.WriteString("\n## Events\n\n")
	if ev.Total == 0 {
		b.WriteString("None. Game code reports events with `MCPGameInspector.playtest_event(name, data)`; the CLI posts them with `playtest event`.\n")
	} else {
		fmt.Fprintf(&b, "%d event(s), %s per minute (", ev.Total, num(ev.PerMinute, 2))
		var src []string
		for _, k := range slices.Sorted(maps.Keys(ev.Sources)) {
			src = append(src, fmt.Sprintf("%d from %s", ev.Sources[k], k))
		}
		b.WriteString(strings.Join(src, ", ") + ").\n\n| Event | Count | Per minute |\n| --- | --- | --- |\n")
		for _, nc := range ev.ByName {
			fmt.Fprintf(&b, "| %s | %d | %s |\n", cell(nc.Name), nc.Count, num(nc.PerMinute, 2))
		}
	}

	in := r.Input
	b.WriteString("\n## Input\n\n")
	if in.Count == 0 {
		b.WriteString("No input.* events were injected while recording.\n")
	} else {
		var parts []string
		for _, k := range slices.Sorted(maps.Keys(in.ByType)) {
			parts = append(parts, fmt.Sprintf("%s %d", k, in.ByType[k]))
		}
		fmt.Fprintf(&b, "%d injected event(s), %s per minute: %s.\n", in.Count, num(in.PerMinute, 1), strings.Join(parts, ", "))
	}

	er := r.Errors
	b.WriteString("\n## Runtime errors\n\n")
	switch {
	case er.Capture == "unavailable":
		b.WriteString("Not captured: the game's engine predates the error logger (Godot 4.5).\n")
	case er.Count == 0:
		b.WriteString("None.\n")
	default:
		fmt.Fprintf(&b, "%d error(s).\n\n| Time | Kind | Section | Message | Where |\n| --- | --- | --- | --- | --- |\n", er.Count)
		for _, e := range er.List {
			fmt.Fprintf(&b, "| %ss | %s | %s | %s | %s |\n", num(e.TS, 2), e.Kind, cell(e.Section), cell(e.Message), cell(orDash(e.Where)))
		}
		if er.Count > len(er.List) {
			fmt.Fprintf(&b, "\n%d more not listed; the JSON report and the session file carry them all.\n", er.Count-len(er.List))
		}
	}
	return b.String()
}

// CompareMarkdown renders a comparison.
func CompareMarkdown(c Comparison) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Playtest comparison: %s vs %s\n\n", cell(refName(c.Before)), cell(refName(c.After)))
	fmt.Fprintf(&b, "Verdict: **%s**. Before %.1fs, after %.1fs.\n", c.Verdict, c.Before.DurationS, c.After.DurationS)
	if c.Before.Source != "" || c.After.Source != "" {
		fmt.Fprintf(&b, "Before: `%s`\nAfter: `%s`\n", c.Before.Source, c.After.Source)
	}
	if len(c.Warnings) > 0 {
		b.WriteString("\nRead the numbers with these differences in mind:\n\n")
		for _, w := range c.Warnings {
			fmt.Fprintf(&b, "- %s\n", w)
		}
	}
	b.WriteString("\n## Metrics\n\nA change counts once it exceeds 5% of the before value and the metric's own floor. The memory slope is graded only when both sessions ran a minute or longer, p95 frame time only past 200 frames each, and p99, the worst frame and the 1% low only past 1000, unless a shorter run moved them by 50% or more.\n\n")
	b.WriteString("| Metric | Before | After | Change | Verdict |\n| --- | --- | --- | --- | --- |\n")
	for _, m := range c.Metrics {
		change := signed(m.Delta, 2)
		if m.DeltaPct != nil {
			change += fmt.Sprintf(" (%s%%)", signed(*m.DeltaPct, 1))
		}
		fmt.Fprintf(&b, "| %s (%s) | %s | %s | %s | %s |\n", m.Name, m.Unit, num(m.Before, 2), num(m.After, 2), change, m.Verdict)
	}
	if len(c.Events) > 0 {
		b.WriteString("\n## Events\n\n| Event | Before | After | Before per minute | After per minute |\n| --- | --- | --- | --- | --- |\n")
		for _, e := range c.Events {
			fmt.Fprintf(&b, "| %s | %d | %d | %s | %s |\n", cell(e.Name), e.Before, e.After, num(e.BeforePerMinute, 2), num(e.AfterPerMinute, 2))
		}
	}
	if len(c.Sections) > 0 {
		b.WriteString("\n## Sections (first visit of each checkpoint)\n\n| Section | Duration before | Duration after | p95 before | p95 after | Events before | Events after |\n| --- | --- | --- | --- | --- | --- | --- |\n")
		for _, s := range c.Sections {
			if s.Missing != "" {
				fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s | %s |\n", cell(s.Label),
					missing(s.Missing == "before", num(s.BeforeDurationS, 1)+"s"), missing(s.Missing == "after", num(s.AfterDurationS, 1)+"s"),
					missing(s.Missing == "before", num(s.BeforeP95MS, 2)), missing(s.Missing == "after", num(s.AfterP95MS, 2)),
					missing(s.Missing == "before", strconv.Itoa(s.BeforeEvents)), missing(s.Missing == "after", strconv.Itoa(s.AfterEvents)))
				continue
			}
			fmt.Fprintf(&b, "| %s | %ss | %ss | %s | %s | %d | %d |\n", cell(s.Label), num(s.BeforeDurationS, 1), num(s.AfterDurationS, 1),
				num(s.BeforeP95MS, 2), num(s.AfterP95MS, 2), s.BeforeEvents, s.AfterEvents)
		}
	}
	return b.String()
}

func missing(absent bool, v string) string {
	if absent {
		return "not reached"
	}
	return v
}

func refName(r SessionRef) string {
	if r.Name == "" {
		return "session"
	}
	if r.Started > 0 {
		return r.Name + " (" + time.Unix(int64(r.Started), 0).Format("2006-01-02 15:04") + ")"
	}
	return r.Name
}

func eventColumns(r Report) []string {
	var cols []string
	for _, nc := range r.Events.ByName {
		if len(cols) == maxEventColumns {
			break
		}
		cols = append(cols, nc.Name)
	}
	return cols
}

func counterDeltas(m map[string]float64) string {
	if m == nil {
		return "no sample"
	}
	var parts []string
	for _, k := range []string{"static_mb", "texture_mb", "video_mb", "nodes", "objects"} {
		v := m[k]
		if v == 0 {
			continue
		}
		unit := ""
		label := k
		if strings.HasSuffix(k, "_mb") {
			unit = " MB"
			label = strings.TrimSuffix(k, "_mb")
		}
		parts = append(parts, fmt.Sprintf("%s %s%s", label, signed(v, 2), unit))
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, ", ")
}

// num formats with at most `digits` decimals and no trailing zeros.
func num(v float64, digits int) string {
	s := strconv.FormatFloat(v, 'f', digits, 64)
	if strings.Contains(s, ".") {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	if s == "-0" {
		s = "0"
	}
	return s
}

func signed(v float64, digits int) string {
	s := num(v, digits)
	if v > 0 && s != "0" {
		return "+" + s
	}
	return s
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// cell makes text safe inside a Markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", `\|`)
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.ReplaceAll(s, "\n", " ")
}
