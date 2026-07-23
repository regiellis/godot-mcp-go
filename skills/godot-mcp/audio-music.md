# Audio & music (4.7) — buses, SFX, interactive scores

Building a game's sound the Godot way, mapped to the CLI. Audio is a resource pipeline:
`AudioStream` resources feed `AudioStreamPlayer` nodes routed through `AudioServer`
buses. **Verify every class against the live engine** (`engine class-info --class
AudioStreamInteractive`) — the names below were confirmed on 4.7.1, but signatures evolve.

Two rules thread through everything here:
- **The multi-clip stream resources (`Interactive`, `Synchronized`, `Playlist`,
  `Randomizer`) can't be fully built with `node set` / `resource create`** — their clips,
  stems, and transitions live behind indexed *method* calls (`set_clip_stream`,
  `add_transition`). Author them with `editor run-script` + `ResourceSaver.save`, then reference
  the saved `.tres`. Scalar-only streams (`Polyphonic`) do build with `resource create`.
- **`audio add-bus-effect` covers the common effects** (reverb, chorus, delay, compressor —
  including `sidechain` — limiter, hardlimiter, phaser, distortion, low/high/band-pass filter,
  amplify, eq, pitchshift, spectrum, record, capture). Anything beyond its param sets is an
  `editor run-script` on `AudioServer` away.

For **timing-critical** work (rhythm games, beat-locked gameplay), the audio *clock* is a
separate problem — read `rhythm-games.md`. This doc owns the mixer, SFX juice, and music.

## Bus architecture — the mixer is the foundation

Route every sound through a named bus *before* you place a single player, so volume, ducking,
and a pause-menu mute all have somewhere to attach. A standard layout: **Master** ← **Music**,
**SFX**, **UI**, **VO**. Each bus `send`s to a parent (default `Master`); effects on a bus
process in chain order, then the send carries the result upstream.

**Volume is decibels, not linear.** A 0..1 UI slider maps through `linear_to_db()`
(`db_to_linear()` inverts it); roughly −6 dB ≈ half power, −80 dB ≈ silence. Never assign a
0..1 value straight to `volume_db`.

Build the layout (note: `audio add-bus` **persists `default_bus_layout.tres`** — revert it if
this was a throwaway test):
```
audio add-bus --name Music --send Master --volume-db -6
audio add-bus --name SFX --send Master
audio add-bus --name UI --send Master
audio add-bus --name VO --send Master
audio get-bus-layout                       # read back: names, volumes, sends, effect chains
audio set-bus --name Music --volume-db -12  # or --mute true / --solo true / --bypass-effects true
```
Wire a slider from GDScript with the dB conversion:
```gdscript
func set_music_volume(linear: float) -> void:  # linear is a 0..1 slider value
    var bus := AudioServer.get_bus_index("Music")
    AudioServer.set_bus_volume_db(bus, linear_to_db(linear))
```
Add players onto their bus with `audio add-player` (`--bus Music`, `--autoplay`, `--stream`), or
set `bus` on any `AudioStreamPlayer*`. `audio get-info --node-path .` lists every player under a
subtree with its bus/volume/stream.

## SFX that doesn't fatigue: AudioStreamRandomizer

The #1 audio-juice pattern. A single sound replayed identically reads as fake fast; an
`AudioStreamRandomizer` wraps a **pool of streams** and, per play, picks one and jitters its
pitch and volume. Point one player's `stream` at it and every trigger sounds fresh.

Knobs (verified): `random_pitch` (a scale, e.g. `1.1` = ±10%), `random_pitch_semitones`,
`random_volume_offset_db`, `playback_mode` (`PLAYBACK_RANDOM_NO_REPEATS` avoids repeating the
last pick — use it; `PLAYBACK_RANDOM`, `PLAYBACK_SEQUENTIAL`). `add_stream(index, stream,
weight)` appends at `index = -1`; `weight` biases the pick.

**Build** (streams need method calls, so `editor run-script`):
```gdscript
var rz := AudioStreamRandomizer.new()
rz.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
rz.random_pitch = 1.1                 # ±10% pitch
rz.random_volume_offset_db = 3.0      # up to 3 dB quieter, randomly
for p in ["res://sfx/step1.wav", "res://sfx/step2.wav", "res://sfx/step3.wav"]:
    rz.add_stream(-1, load(p) as AudioStream, 1.0)
ResourceSaver.save(rz, "res://sfx/footstep.tres")
```
Then `audio add-player --node-path . --name Footsteps --stream res://sfx/footstep.tres --bus SFX`
and call `.play()` on each footfall. (The scalar knobs alone can be set with
`resource create --type AudioStreamRandomizer --properties '{...}'`; the pool still needs the script.)

## Many overlapping one-shots: AudioStreamPolyphonic

For rapid-fire, self-overlapping SFX (gunfire, coin pickups, UI clicks) you don't want a player
node per shot. An `AudioStreamPolyphonic` lets **one** player voice N concurrent sounds: set it
as the stream, `play()` the player once, then push streams into its live playback.

`polyphony` caps simultaneous voices. `play_stream(stream, from_offset, volume_db, pitch_scale,
…)` returns an int voice id you can later `set_stream_volume(id, db)` or `stop_stream(id)`.

**Build** (this stream *is* scalar-only, so `resource create` works):
```
resource create --path res://sfx/shots.tres --type AudioStreamPolyphonic --properties '{"polyphony":16}'
audio add-player --node-path . --name Shots --stream res://sfx/shots.tres --bus SFX --autoplay true
```
```gdscript
@onready var shots: AudioStreamPlayer = $Shots
func fire() -> void:
    var pb := shots.get_stream_playback() as AudioStreamPlaybackPolyphonic
    pb.play_stream(preload("res://sfx/laser.wav"), 0.0, -3.0, randf_range(0.95, 1.05))
```

## Interactive music (the flagship): AudioStreamInteractive

The engine's built-in adaptive-music system — no custom crossfade code. You author named
**clips** (explore / combat / boss) and **transitions** between them; at runtime you request a
clip and the engine handles the musical crossfade. It replaces the old "two players + a manual
tween" hack.

Per clip: `set_clip_name`, `set_clip_stream`, and `set_clip_auto_advance` +
`set_clip_auto_advance_next_clip` (a clip set `AUTO_ADVANCE_ENABLED` flows into another when it
ends — the loop-and-continue backbone; `AUTO_ADVANCE_DISABLED`, `AUTO_ADVANCE_RETURN_TO_HOLD`).

`add_transition(from, to, from_time, to_time, fade_mode, fade_beats, use_filler, filler, hold_previous)`:
- **`from_time`** — when to leave the current clip, quantized to the musical grid:
  `TRANSITION_FROM_TIME_IMMEDIATE` / `NEXT_BEAT` / `NEXT_BAR` / `END`. Quantized values need the
  source clip's **bpm/bar metadata** (see Formats below) or they fall back to immediate.
- **`to_time`** — where the destination starts: `TRANSITION_TO_TIME_START` / `SAME_POSITION`.
- **`fade_mode`** — `FADE_DISABLED` / `FADE_IN` / `FADE_OUT` / `FADE_CROSS` / `FADE_AUTOMATIC`;
  `fade_beats` is the crossfade length in beats.
- **filler** — an optional stinger clip played between the two (`CLIP_ANY` = −1 = none);
  `hold_previous` keeps the old clip under the new one.

**Build the score:**
```gdscript
var m := AudioStreamInteractive.new()
m.clip_count = 2
m.set_clip_name(0, "explore"); m.set_clip_stream(0, load("res://music/explore.ogg") as AudioStream)
m.set_clip_name(1, "combat");  m.set_clip_stream(1, load("res://music/combat.ogg") as AudioStream)
m.set_initial_clip(0)
# cross-fade over 2 beats, starting on the next bar, in both directions:
m.add_transition(0, 1, AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BAR,
    AudioStreamInteractive.TRANSITION_TO_TIME_START,
    AudioStreamInteractive.FADE_CROSS, 2.0, false, AudioStreamInteractive.CLIP_ANY, false)
m.add_transition(1, 0, AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BAR,
    AudioStreamInteractive.TRANSITION_TO_TIME_START,
    AudioStreamInteractive.FADE_CROSS, 4.0, false, AudioStreamInteractive.CLIP_ANY, false)
ResourceSaver.save(m, "res://music/score.tres")
```
**Switch clips at runtime** through the player's playback object — the resource holds the map,
the playback drives it:
```gdscript
@onready var music: AudioStreamPlayer = $Music   # stream = res://music/score.tres, autoplay on
func enter_combat() -> void:
    var pb := music.get_stream_playback() as AudioStreamPlaybackInteractive
    pb.switch_to_clip_by_name("combat")          # or switch_to_clip(1); get_current_clip_index()
```

## Layered stems in lockstep: AudioStreamSynchronized

The other adaptive approach: one song split into **stems** (drums, bass, lead, pads) that always
play sample-locked, and you raise/mute layers to track intensity. `AudioStreamSynchronized`
guarantees the lock — `set_stream_count`, `set_sync_stream(i, stream)`, and per-stem
`set_sync_stream_volume(i, db)` (start inactive layers near −60 dB).
```gdscript
var s := AudioStreamSynchronized.new()
s.set_stream_count(3)
s.set_sync_stream(0, load("res://music/drums.ogg") as AudioStream)
s.set_sync_stream(1, load("res://music/bass.ogg") as AudioStream)
s.set_sync_stream(2, load("res://music/lead.ogg") as AudioStream)  # the "combat" layer
s.set_sync_stream_volume(2, -60.0)                                 # silent until it's earned
ResourceSaver.save(s, "res://music/layered.tres")
```
For **smooth live crossfades** between intensities, give each stem its own player on its own bus
and *tween the bus volumes* — bus automation is continuous, whereas a resource's stem volume is
read at play time. Use `Synchronized` for guaranteed sample-lock; separate players + bus tweens
when you need to slide a layer in over seconds.

## Shuffle/loop a soundtrack: AudioStreamPlaylist

For ambient/menu music that should rotate through several tracks with a gapless crossfade,
`AudioStreamPlaylist` sequences streams: `set_stream_count`, `set_list_stream(i, stream)`,
`shuffle`, `loop`, `fade_time` (crossfade seconds between tracks).
```gdscript
var pl := AudioStreamPlaylist.new()
pl.set_stream_count(3)
pl.set_list_stream(0, load("res://music/a.ogg") as AudioStream)
pl.set_list_stream(1, load("res://music/b.ogg") as AudioStream)
pl.set_list_stream(2, load("res://music/c.ogg") as AudioStream)
pl.shuffle = true; pl.loop = true; pl.fade_time = 2.0
ResourceSaver.save(pl, "res://music/ambient.tres")
```

## Ducking music under SFX/VO: compressor sidechain

Classic mix move: when the player speaks or a big SFX hits, the music dips automatically. Put an
`AudioEffectCompressor` on the **Music** bus and point its `sidechain` at the bus whose level
should trigger the dip (`sidechain` is a bus name):
```
audio add-bus-effect --bus Music --effect-type compressor \
  --params '{"threshold":-18,"ratio":6,"attack_us":20,"release_ms":250,"sidechain":"VO"}'
audio get-bus-layout    # read back: the Music bus chain now shows the compressor + its sidechain
```
Louder VO → more gain reduction on Music. Tune `threshold` (how loud the sidechain must get
before ducking starts), `ratio` (how hard), and `release_ms` (how fast music recovers after the
trigger stops).

## Music-reactive visuals: the spectrum analyzer

For visuals that pulse to the music (bars, glow, camera bob), read the live FFT off the bus. Add
an `AudioEffectSpectrumAnalyzer` to the bus, grab its **instance** from the running server, and
sample `get_magnitude_for_frequency_range(from_hz, to_hz)` each frame. It returns a `Vector2`
(left, right magnitude); average or `max()` the channels.
```
audio add-bus-effect --bus Music --effect-type spectrum
```
```gdscript
extends Node2D
var _spectrum: AudioEffectSpectrumAnalyzerInstance
func _ready() -> void:                        # effect index 0 on the Music bus
    _spectrum = AudioServer.get_bus_effect_instance(AudioServer.get_bus_index("Music"), 0) \
        as AudioEffectSpectrumAnalyzerInstance
func _process(_delta: float) -> void:
    var bass := _spectrum.get_magnitude_for_frequency_range(20.0, 250.0)  # low band
    var energy := (bass.x + bass.y) * 0.5     # default mode is MAGNITUDE_MAX
    scale = Vector2.ONE * (1.0 + energy * 8.0)  # thump on the kick
```
This is *reactive juice* — it reads the audio and follows. For gameplay that must be **on** the
beat (notes, judging, spawns), that's a clock problem, not an FFT problem: use `rhythm-games.md`.

## Formats & loop points: WAV / Ogg / MP3

Pick by role, and put the loop settings where that format keeps them:
- **WAV** — short SFX. Uncompressed, zero decode cost, sample-accurate loops. Loop lives on the
  stream: `loop_mode` (`LOOP_DISABLED` / `LOOP_FORWARD` / `LOOP_PINGPONG` / `LOOP_BACKWARD`),
  `loop_begin` / `loop_end` (in frames). Usually set via the `.wav`'s **import options**; reach
  the resource directly with `AudioStreamWAV.load_from_file(path, {})`.
- **OggVorbis** — music and long loops. Compressed (small), seamless looping: `loop = true`,
  `loop_offset` (seconds — where the loop restarts). Also carries `bpm` / `bar_beats` /
  `beat_count` — **set these for `AudioStreamInteractive`'s bar/beat-quantized transitions**.
- **MP3** — same `loop` / `loop_offset` / `bpm` fields as Ogg; prefer Ogg unless a source is
  MP3-only (patent-free, generally better at size/quality for game music).

Default to **Ogg for music, WAV for SFX**. Confirm import-time loop settings with `import info
--path <asset>.import`; flip stream-level fields (`loop_offset`, `bpm`) via run-script.

## Positional audio (2D & 3D)

Spatial SFX — panning, distance attenuation, 3D falloff models, `max_polyphony`, per-world-SFX
bus routing — is already covered in **`game-patterns.md`** ("Positional audio (2D & 3D)"). Use
`AudioStreamPlayer2D` / `3D`, set `max_distance` and the attenuation model, and route to the
`SFX` bus so the ducking and pause-menu mute above apply. Don't duplicate that here — read it there.

## Procedural & capture, briefly

- **`AudioStreamGenerator`** — synthesize samples at runtime (tones, retro blips). Set it as a
  player's stream, then push frames into its playback each frame while buffer space is free:
  ```gdscript
  var pb := player.get_stream_playback() as AudioStreamGeneratorPlayback
  while pb.get_frames_available() > 0:
      pb.push_frame(Vector2(sample, sample))   # one stereo frame, values in −1..1
  ```
  Reach for it only when a sound is genuinely computed (parametric SFX, a chiptune synth).
- **`AudioEffectRecord`** — a bus effect that captures its input to an `AudioStreamWAV`
  (`set_recording_active(true)` → `get_recording()`); for a mic/voice-memo or capturing gameplay
  audio.
- **`AudioEffectCapture`** — pulls the bus's raw frames into a ring buffer
  (`can_get_buffer(n)` → `get_buffer(n)`) for analysis or streaming; the read side of
  `AudioServer` DSP.

## Common mistakes to avoid

- Assigning a 0..1 value to `volume_db`. It's decibels — convert with `linear_to_db()`.
- Authoring `Interactive`/`Synchronized`/`Playlist`/`Randomizer` streams with `node set`. Their
  clips/stems/transitions are method-driven — build with `editor run-script` + `ResourceSaver.save`.
- A player node per rapid one-shot. Use one `AudioStreamPolyphonic` player, or `max_polyphony`.
- Hand-rolling music crossfades with two players and a tween — that's `AudioStreamInteractive`.
- Forgetting bar/beat metadata on the music stream, then wondering why `NEXT_BAR` fires immediately.
- Routing everything to `Master`. Give Music/SFX/UI/VO their own buses so ducking, muting, and
  per-category volume have somewhere to attach.
- Trusting a remembered signature — confirm 4.7 with `engine class-info` / `engine search`.
