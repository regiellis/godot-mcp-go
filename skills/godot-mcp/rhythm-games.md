# Rhythm & music minigames — clock, beatmaps, judging

The architecture of a timing game — standalone or embedded as a minigame in a larger game.
Pattern-mined from a shipped commercial Godot title's karaoke/rhythm module; the clock and
judging core validated headless against the live engine. The hard problem is **one clock**: everything
(notes, lyrics, judging, metronome) must read the *audio's* time, never the frame clock.

## The song clock (the whole game hangs on this)

`AudioStreamPlayer.get_playback_position()` alone is chunked to the mix buffer and lags the
speakers. The canonical correction:

```gdscript
func song_time_msec() -> float:
    return (asp.get_playback_position()
        + AudioServer.get_time_to_next_mix()
        + AudioServer.get_output_latency()) * 1000.0 - calibration_offset_ms
```

- Sample it once per frame into a `timestamp_msec` and **push it down** the tree (a setter that
  forwards to children) so every note/lyric/judge reads the same instant.
- `calibration_offset_ms` is a **user setting**, not a constant — hardware audio paths differ;
  ship a "tap to the beat" calibration screen and store the offset in the save config.
- Never accumulate `delta` for song time; pausing works by freezing the pushed timestamp (and
  accumulating a pause offset), not by pausing the tree.

## Beatmaps and lyrics are data — reuse existing formats

Don't invent a beatmap format: **parse `.osu`** (osu!mania). You inherit a mature ecosystem of
editors, and the format is a trivial INI-ish text parse: `[General]` (`AudioFilename`,
`AudioLeadIn`), `[TimingPoints]` (time, beat length, meter — enough for a metronome or beat
pulses), `[HitObjects]` (time, column, type bit-flags for tap vs hold, hold end time). For
karaoke, **parse `.lrc`** (timestamped lyric lines, per-word timing in enhanced LRC) — again an
existing authoring ecosystem. Load audio from the path the beatmap names, sibling to the file.

## Notes: position is a pure function of time

Spawn a note `lead_in_ms` before its target time; its speed is solved, not tuned:
`speed_px = lane_height / (lead_in_ms / 1000.0)`, and each frame it sits at
`y = hit_line_y - (target_ms - timestamp_msec) / 1000.0 * speed_px`. Scroll speed is then one
multiplier on `lead_in`. Notes live one `Node2D` lane per column; **input routes to the front
note of its column only** (`column.get_child(0).handle(input)`) — FIFO per lane is the entire
input-to-note mapping.

## Judging: timestamps in, typed result out

Keep the judge a pure `RefCounted`: compare an input `(timestamp, column, pressed)` against the
target note and bucket the absolute error into windows — e.g. ±120 ms perfect, ±300 great,
±320 miss, else ignore the input entirely (a stray tap far from any note is *no* result, not a
miss; misses come from notes crossing the window unhit). Return a typed `HitResult` whose
`score_value` and `affects_combo` are **derived getters on the result type**, so scoring rules
live in one place. Emit results as signals up through the spawner; score/combo/judgment-text UI
all subscribe. Holds judge twice: press near the head, release near the tail.

## Structure for embedding

Keep the module self-contained (own dir, own state machine: `Idle → Sing → Score`), driven by a
thin host component that: pushes a focus scope (so game input is captured), swaps music buses,
runs the minigame, and reports the score back to story state. Autoplay mode (the renderer fires
perfect inputs itself) is worth building day one — it is both the demo/attract mode and the
proof your clock and windows agree. A metronome driven from the beatmap's timing points is the
debugging tool for drift: if ticks pull away from the music, the clock is wrong, not the map.

## Build order (all with existing commands)

1. `scene2d` + `node.add` the lanes/hit-line layout; `input_map.set_action` per column.
2. `script.create` the parser, clock, judge (pure logic — test them headless before any visuals).
3. Notes as small scenes; spawner instances per hit-object.
4. `runtime.eval` to verify live: print `song_time_msec()` against a timing point's beat grid.
5. Calibration screen last; persist the offset with the save system.
