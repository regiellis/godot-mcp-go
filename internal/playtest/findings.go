package playtest

import (
	"cmp"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
)

// Severities, most urgent first. The report lists findings in this order.
const (
	SeverityError = "error"
	SeverityWarn  = "warn"
	SeverityInfo  = "info"
)

func severityRank(s string) int {
	switch s {
	case SeverityError:
		return 0
	case SeverityWarn:
		return 1
	}
	return 2
}

// findings applies the report's rules. Each one names a number from the report
// and a concrete place to look; none of them changes the game.
func findings(s *Session, r *Report) []Finding {
	var out []Finding
	add := func(sev, code, title, detail, lookAt string) {
		out = append(out, Finding{Severity: sev, Code: code, Title: title, Detail: detail, LookAt: lookAt})
	}
	f := r.Frames
	dur := r.Session.DurationS

	if len(s.Errors) > 0 {
		first := r.Errors.List[0]
		detail := fmt.Sprintf("First at %.1fs in %s: %s", first.TS, first.Section, sentence(first.Message))
		add(SeverityError, "runtime_errors", fmt.Sprintf("%d runtime error(s) while recording", len(s.Errors)), detail, first.Where)
	}

	if r.Session.Truncated {
		var parts []string
		for _, k := range slices.Sorted(maps.Keys(r.Session.Dropped)) {
			parts = append(parts, fmt.Sprintf("%s %d", k, r.Session.Dropped[k]))
		}
		add(SeverityWarn, "truncated", "The session hit a recorder cap and is partial",
			"Dropped: "+strings.Join(parts, ", ")+". Numbers cover what was kept.",
			"record shorter sessions, or raise playtest start --sample-every to keep samples under the cap")
	}

	if f.Count > 0 && f.P50MS > f.BudgetMS*1.1 {
		add(SeverityWarn, "below_target",
			fmt.Sprintf("Median frame time %.2f ms is over the %.2f ms budget for %g fps", f.P50MS, f.BudgetMS, f.TargetFPS),
			fmt.Sprintf("Average %.1f fps; %.1f%% of frames ran over %.2f ms.", f.AvgFPS, f.SlowFramesPct, f.BudgetMS*slowFrameFactor),
			worstSectionHint(r.Sections))
	}

	if f.Count > 0 && f.P99MS > f.BudgetMS*2 {
		add(SeverityWarn, "frame_tail",
			fmt.Sprintf("Frame-time tail: p99 %.2f ms, 1%% low %.1f fps", f.P99MS, f.OnePercentLowFPS),
			fmt.Sprintf("The slowest 1%% of frames take more than twice the %.2f ms budget, which a player feels as stutter even when the average is fine.", f.BudgetMS),
			worstSpikeHint(r.Spikes))
	}

	out = append(out, spikeFindings(r)...)
	out = append(out, memoryFindings(r, dur)...)

	if r.Frames.P95MS > 0 {
		for _, sec := range r.Sections {
			if sec.Frames < slowSectionFrames || sec.P95MS < r.Frames.P95MS*slowSectionFactor || sec.P95MS <= f.BudgetMS {
				continue
			}
			add(SeverityWarn, "slow_section",
				fmt.Sprintf("Section '%s' runs slow: p95 %.2f ms against %.2f ms overall", sectionName(sec), sec.P95MS, r.Frames.P95MS),
				fmt.Sprintf("%.1fs long, %d spike(s) inside it.", sec.DurationS, sec.Spikes),
				fmt.Sprintf("what the game does between %.1fs and %.1fs (the '%s' checkpoint)", sec.StartS, sec.EndS, sec.Label))
		}
	}

	out = append(out, eventFindings(r)...)

	if f.Count > 0 && (dur < shortSessionS || f.Count < shortSessionFrames) {
		add(SeverityInfo, "short_session",
			fmt.Sprintf("Short session: %.1fs, %d frames", dur, f.Count),
			"Percentiles and slopes from a session this short move a lot between runs.",
			"record at least a minute of play before comparing numbers")
	}
	if r.Session.Headless {
		add(SeverityInfo, "headless",
			"Recorded headless: frame times are not what a player sees",
			"A headless game renders nothing, so frame times measure game logic under the engine's pacing and draw counters read zero.",
			"repeat the session in a windowed game for rendering numbers")
	}
	if r.Errors.Capture == "unavailable" {
		add(SeverityInfo, "errors_unavailable", "Runtime errors were not captured",
			"Error capture needs Godot 4.5 or newer in the game.", "")
	}
	if r.Events.Total == 0 {
		add(SeverityInfo, "no_events", "No game events recorded",
			"Difficulty numbers (deaths, damage, retries per section) exist only where the game reports them.",
			"call MCPGameInspector.playtest_event(\"death\", {...}) where the game decides those facts, or post them with playtest event")
	}
	if r.Input.Count == 0 {
		add(SeverityInfo, "no_input", "No agent input recorded",
			"The session measured the game running on its own; nothing was sent through input.*.", "")
	}

	slices.SortStableFunc(out, func(a, b Finding) int { return cmp.Compare(severityRank(a.Severity), severityRank(b.Severity)) })
	return out
}

func spikeFindings(r *Report) []Finding {
	var out []Finding
	sp := r.Spikes
	if sp.Count == 0 {
		return nil
	}
	// Which input or event most often comes just before a spike. The worst list
	// is capped, so count over it: those are the spikes worth explaining.
	type tally struct {
		kind, name string
		n          int
		worst      float64
	}
	byCause := map[string]*tally{}
	for _, s := range sp.Worst {
		if s.PrecededBy == nil {
			continue
		}
		key := s.PrecededBy.Kind + "\x00" + s.PrecededBy.Name
		t := byCause[key]
		if t == nil {
			t = &tally{kind: s.PrecededBy.Kind, name: s.PrecededBy.Name}
			byCause[key] = t
		}
		t.n++
		t.worst = max(t.worst, s.WorstMS)
	}
	tallies := make([]*tally, 0, len(byCause))
	for _, t := range byCause {
		tallies = append(tallies, t)
	}
	slices.SortFunc(tallies, func(a, b *tally) int {
		if a.n != b.n {
			return cmp.Compare(b.n, a.n)
		}
		return strings.Compare(a.name, b.name)
	})
	for _, t := range tallies {
		if t.n < 2 || float64(t.n) < 0.3*float64(len(sp.Worst)) {
			continue
		}
		out = append(out, Finding{
			Severity: SeverityWarn, Code: "spike_cause",
			Title:  fmt.Sprintf("%d of %d spikes follow %s '%s' within a second", t.n, len(sp.Worst), t.kind, t.name),
			Detail: fmt.Sprintf("Worst of them %.1f ms against a %.1f ms spike threshold.", t.worst, sp.ThresholdMS),
			LookAt: lookAtFor(t.kind, t.name),
		})
	}
	for _, s := range sp.Worst {
		if s.Counters == nil {
			continue
		}
		switch {
		case s.Counters["texture_mb"] >= textureJumpMB:
			out = append(out, Finding{
				Severity: SeverityWarn, Code: "spike_texture_upload",
				Title:  fmt.Sprintf("Spike at %.1fs (%.1f ms) came with +%.1f MB of texture memory", s.TS, s.WorstMS, s.Counters["texture_mb"]),
				Detail: "A texture loaded and uploaded on the main thread on that frame.",
				LookAt: "load or preload that texture before the moment it is shown" + causeSuffix(s.PrecededBy),
			})
		case s.Counters["static_mb"] >= staticJumpMB:
			out = append(out, Finding{
				Severity: SeverityWarn, Code: "spike_allocation",
				Title:  fmt.Sprintf("Spike at %.1fs (%.1f ms) came with +%.1f MB of static memory", s.TS, s.WorstMS, s.Counters["static_mb"]),
				Detail: "A large allocation (a resource load or a big array) happened on that frame.",
				LookAt: "move the load ahead of play or onto a background thread" + causeSuffix(s.PrecededBy),
			})
		case s.Counters["nodes"] >= nodeJump:
			out = append(out, Finding{
				Severity: SeverityWarn, Code: "spike_instancing",
				Title:  fmt.Sprintf("Spike at %.1fs (%.1f ms) added %d nodes in one frame", s.TS, s.WorstMS, int(s.Counters["nodes"])),
				Detail: "A scene was instanced mid-play.",
				LookAt: "instance it ahead of time, pool it, or spread the work over frames" + causeSuffix(s.PrecededBy),
			})
		}
	}
	return out
}

// sentence closes text with a period unless it already ends in punctuation.
func sentence(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || strings.ContainsAny(s[len(s)-1:], ".!?") {
		return s
	}
	return s + "."
}

func causeSuffix(c *Cause) string {
	if c == nil {
		return ""
	}
	return fmt.Sprintf(" (it followed %s '%s'%s)", c.Kind, c.Name, causeData(c))
}

// causeData is an event's data as compact JSON, which is what tells one coin,
// enemy or wave from the next when they share an event name.
func causeData(c *Cause) string {
	if c == nil || len(c.Data) == 0 {
		return ""
	}
	b, err := json.Marshal(c.Data)
	if err != nil {
		return ""
	}
	s := string(b)
	if len(s) > 60 {
		s = s[:57] + "..."
	}
	return " " + s
}

func lookAtFor(kind, name string) string {
	switch kind {
	case "input":
		return fmt.Sprintf("the code that reacts to %s", name)
	case "event":
		return fmt.Sprintf("the code around the playtest_event(\"%s\") call", name)
	}
	return fmt.Sprintf("what the game starts at the '%s' checkpoint", name)
}

func worstSpikeHint(sp SpikeStats) string {
	if len(sp.Worst) == 0 {
		return "profile a section with the Godot profiler (Debugger > Profiler)"
	}
	w := sp.Worst[0]
	hint := fmt.Sprintf("the worst spike: %.1f ms at %.1fs in '%s'", w.WorstMS, w.TS, w.Section)
	return hint + causeSuffix(w.PrecededBy)
}

func worstSectionHint(secs []Section) string {
	best := -1
	for k, s := range secs {
		if s.Frames < slowSectionFrames {
			continue
		}
		if best < 0 || s.P95MS > secs[best].P95MS {
			best = k
		}
	}
	if best < 0 || len(secs) < 2 {
		return "profile the scene with the Godot profiler (Debugger > Profiler) and the visual profiler"
	}
	return fmt.Sprintf("section '%s' has the slowest p95 (%.2f ms)", sectionName(secs[best]), secs[best].P95MS)
}

func memoryFindings(r *Report, dur float64) []Finding {
	var out []Finding
	c := r.Counters
	if c.Samples < 3 {
		return nil
	}
	if dur >= leakMinSessionS && c.StaticMB.SlopePerMin > leakSlopeMBPerMin && c.StaticMB.End-c.StaticMB.Start > leakMinGrowthMB {
		out = append(out, Finding{
			Severity: SeverityWarn, Code: "memory_growth",
			Title: fmt.Sprintf("Static memory grows %.2f MB per minute (%.1f to %.1f MB)", c.StaticMB.SlopePerMin, c.StaticMB.Start, c.StaticMB.End),
			Detail: "A steady climb over a whole session is a leak signal: something allocates and is never released. " +
				fmt.Sprintf("Objects went %d to %d.", int(c.Objects.Start), int(c.Objects.End)),
			LookAt: "resources or arrays that grow per event or per frame (caches, logs, spawned-object lists)",
		})
	}
	if c.Orphans.End > c.Orphans.Start && c.Orphans.End >= orphanMinEnd {
		out = append(out, Finding{
			Severity: SeverityWarn, Code: "orphan_growth",
			Title:  fmt.Sprintf("Orphan nodes rose from %d to %d", int(c.Orphans.Start), int(c.Orphans.End)),
			Detail: "An orphan is a node removed from the tree and never freed. They are counted in debug builds only.",
			LookAt: "remove_child calls without a matching queue_free, and nodes kept in arrays after leaving the tree",
		})
	}
	if dur >= leakMinSessionS && c.Nodes.SlopePerMin > nodeGrowthPerMin && c.Nodes.End > c.Nodes.Start*1.2+10 {
		out = append(out, Finding{
			Severity: SeverityWarn, Code: "node_growth",
			Title:  fmt.Sprintf("Node count climbs %.0f per minute (%d to %d)", c.Nodes.SlopePerMin, int(c.Nodes.Start), int(c.Nodes.End)),
			Detail: "Spawned nodes are not being freed as fast as they are created.",
			LookAt: "projectiles, effects, and pickups that never call queue_free when they leave play",
		})
	}
	return out
}

func eventFindings(r *Report) []Finding {
	var out []Finding
	total := r.Session.DurationS
	if len(r.Sections) >= 2 && total > 0 {
		for _, nc := range r.Events.ByName {
			if nc.Count < clusterMinEvents {
				continue
			}
			best, bestN := -1, 0
			for k, sec := range r.Sections {
				if n := sec.Events[nc.Name]; n > bestN {
					best, bestN = k, n
				}
			}
			if best < 0 {
				continue
			}
			share := float64(bestN) / float64(nc.Count)
			timeShare := r.Sections[best].DurationS / total
			if share < clusterMinShare || share < 2*timeShare {
				continue
			}
			sec := r.Sections[best]
			out = append(out, Finding{
				Severity: SeverityInfo, Code: "event_cluster",
				Title: fmt.Sprintf("'%s' concentrates in section '%s': %d of %d", nc.Name, sectionName(sec), bestN, nc.Count),
				Detail: fmt.Sprintf("That section is %.0f%% of the session time and holds %.0f%% of these events. If '%s' is a failure (a death, a hit), this is the difficulty spike.",
					100*timeShare, 100*share, nc.Name),
				LookAt: fmt.Sprintf("the tuning of the '%s' section (%.1fs to %.1fs)", sec.Label, sec.StartS, sec.EndS),
			})
		}
	}
	visits := map[string]int{}
	for _, sec := range r.Sections {
		if sec.Label != startSectionLabel {
			visits[sec.Label] = max(visits[sec.Label], sec.Visit)
		}
	}
	for _, label := range slices.Sorted(maps.Keys(visits)) {
		if visits[label] < 2 {
			continue
		}
		out = append(out, Finding{
			Severity: SeverityInfo, Code: "section_retries",
			Title:  fmt.Sprintf("Section '%s' was entered %d times", label, visits[label]),
			Detail: "Marking the same checkpoint again records a retry. Each visit is its own row in the sections table.",
			LookAt: fmt.Sprintf("what sends play back to the '%s' checkpoint", label),
		})
	}
	return out
}
