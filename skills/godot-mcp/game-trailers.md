# Game videos and trailers — filming a Godot game with the engine itself

How an agent plans, stages, films, and cuts a trailer or a feature video for a Godot game. The
game renders its own footage: Godot's **movie writer** runs the project offline at a fixed frame
rate and writes every frame plus the master audio bus to a file, so the capture is frame-perfect
however slow the machine is. Screen-recording software is the wrong tool here — it films a game
fighting for frames, and it cannot be re-run when a line of dialogue changes.

The engine behaviour and the commands below were checked against **Godot 4.7.2** on 2026-08-09; the
staging patterns come from a two-film rig built with this CLI. Each idea pairs with a **Build:**
recipe; adapt them rather than running them end to end.

The division of labour: the **director scene** decides what happens on camera, the **movie writer**
records it, **ffmpeg** encodes it, and **godot-mcp** drives the iteration loop between takes so a
render is spent only on footage already known to be right.

## The film is decided before the rig exists

Write the shot list first, as a file in the repo, and make it the source of record. The director
script is built *to* the shot list, and a change to the film starts there rather than in the code.
A table carries it: number, timecode, what the shot is, what is on screen, what is said.

What separates a trailer that works from a screen tour:

- **The hook is a character or a verb inside four seconds**, not a logo. Somebody talks trash, a
  body falls, a door opens. A title card that opens on nothing spends the only seconds a viewer
  reliably gives.
- **One continuous story beats a feature list**. Taunt, bluff, win the round, rival tilts, rematch.
  Modes and systems then appear as *escalations of that story*, so the film never stops to
  enumerate anything.
- **Say it in the game's own voice**. Dialogue through the game's real speech system reads as the
  game; a caption reads as marketing.
- **A text card is its own beat, never an overlay**. Parked over a live screen it lands on a button
  and looks like a mistake. Cut to the card on an opaque cover, hold it, cut back.
- **Cut to the music**. Compose or pick the bed first, mark its hits, and place the cuts on them.
  Shot lengths are then a consequence of the track rather than a guess.
- **Every word on camera is the script's**. Spontaneous chatter, tutorial nudges, and hint systems
  all have to be silenced for the take, or the film says something nobody wrote.

Length: a store trailer runs 30 to 60 seconds; a feature video can run longer because its viewer
already opted in. Both are cheaper to shorten than to pad, so cut the shot list before building it.

**Build:** write `trailers/script.md`, then create the rig beside it.

```
godot-mcp fs mkdir --path res://trailers
godot-mcp scene create --path res://trailers/trailer.tscn --root-type Control
godot-mcp scene open --path res://trailers/trailer.tscn
godot-mcp script create --path res://trailers/trailer_director.gd --extends Control
godot-mcp script attach --node-path . --script-path res://trailers/trailer_director.gd
```

## The director scene

One scene plus one script per film. It is dev-only tooling and never ships: add `trailers/*` to
every export preset's `exclude_filter`, beside whatever holds the project's other tools. A second
film gets its own scene and script rather than a shared base class — keeping a finished film
byte-identical outranks avoiding duplication, and a shared helper puts every later change to film
two into film one's render path.

The spine is a list of awaited shots and a quit:

```gdscript
func _ready() -> void:
	_guard()            # fixtures in memory, nothing of the developer's touched
	_build_overlay()    # the cover and the card layer
	_start_music()
	await _shot_cold_open()
	await _shot_the_turn()
	await _shot_end_card()
	get_tree().quit()   # quitting is what finalises the movie file
```

**The quit is load-bearing.** The writer keeps recording until the engine exits, so a director that
falls off the end of its shot list produces a film that runs until somebody closes the window.

### Five rules that keep a render honest

- **Never write the developer's saves**. Progress, stats, and settings singletons get their persist
  flags turned off and their state driven from an in-memory fixture. A film that unlocks everything
  to shoot a roster must not leave the machine that way.
- **Never go fullscreen**. The take is unattended and a fullscreen window is hostile to whoever is
  at the keyboard. Force windowed in `_enter_tree`, before the first frame.
- **Drive the real handlers**. Call `_on_die_clicked`, `_select_mode`, the same entry points a
  player's input reaches, rather than writing the resulting state. What is filmed is then what a
  player gets. Where a handler cannot produce the frame the shot is about, replay *that handler's
  own branch* call for call instead of faking its result.
- **Rig the randomness, do not remove it**. Seed the RNG, or load a scripted deck between
  `instantiate()` and `add_child()` so the dealt cards land on known faces. The shot list can then
  name a score, and the film matches it every render.
- **No wait may strand the render**. Poll a predicate over frames with a ceiling, and treat a
  ceiling that fires as a wrong predicate rather than a slow game.

```gdscript
## Poll `cond` over frames with a wall-clock ceiling, so a surprised game cannot hang a render.
func _until(cond: Callable) -> void:
	var deadline := Time.get_ticks_msec() + int(WAIT_CEILING * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return
		await get_tree().process_frame
	push_warning("trailer: a wait hit its ceiling — footage may be off")
```

Predicates read the game's own idle state (not busy, player's turn, match not over), and anything
that animates gets polled per object. A fixed sleep after a staggered deal still races the last
tumble, which is how a die clicked as a 4 lands on a 3 on film.

## What rides film time, and what rides the wall clock

This is the mechanical fact the whole rig is paced on. `--write-movie` forces `--fixed-fps`, which
makes the reported `delta` identical every frame regardless of how long that frame took to render.
So:

- **Tweens, `SceneTreeTimer`, `AnimationPlayer`, and anything driven by `delta` measure film
  seconds.** A 0.35 s fade is 0.35 s of footage at any render speed. Pace the film with these.
- **`Time.get_ticks_msec()` measures real elapsed time**, which during an offline render runs far
  behind the film. Measured on this machine: 3.05 s of 60 fps footage took about 12 s of wall clock
  to write. Use the wall clock only for safety ceilings, never for timing a beat.
- **`Engine.time_scale` scales the whole simulation together**, so it is the dial for making the
  game do slow work quickly while nobody is looking.

## Cutting: the cover, and the world running backstage

A cut is a fade through an opaque rectangle on a high `CanvasLayer`, and the space behind it is
where the next shot is built. While the cover is up, run `Engine.time_scale` at 8 to 10 and mute
the SFX bus: the next screen deals, animates, and settles into position in a fifth of the film time
and none of it is heard. Restore both before anything is revealed.

```gdscript
func _backstage(on: bool) -> void:
	Engine.time_scale = 10.0 if on else 1.0
	var bus := AudioServer.get_bus_index(&"SFX")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, on)
```

**Anything that has to look right must happen at `time_scale` 1.0.** A click issued at the
backstage clock reads a face the object has not landed on yet, and a tween started there strands
mid-size. Drop to 1.0 for the moment that matters, then speed back up.

**Build:** the cover, sized past the viewport so a camera knock cannot reveal an edge.

```
godot-mcp node add --type CanvasLayer --parent-path . --name CoverLayer
godot-mcp node set --node-path CoverLayer --property layer --value 80
godot-mcp node add --type ColorRect --parent-path CoverLayer --name Cover
godot-mcp node set --node-path CoverLayer/Cover --properties '{"size":"Vector2(2720,1600)","position":"Vector2(-80,-80)","mouse_filter":2}'
```

## Words and sound

**Speak through the game's own dialogue path.** Calling the real "say this line" entry point gets
the real bubble, the real anchor, and the speaker's head animating; a `Label` dropped on top gets
none of it. Silence the spontaneous layer first so the scripted lines are the only ones that fire,
and give scripted lines a priority no game event can preempt.

A screen with no dialogue system of its own (a title, an end card) builds the bubble directly and
dresses it to match. Bubble placement geometry usually assumes a speaker sitting outside the
placement boxes, so a speaker standing inside one gets no legal candidate and the bubble lands on
their face: call the normal path for the build and entrance, then write the body position and tail
by hand for that page.

**Sound: the movie writer records the master bus**, so the mix in the file is the mix the game
makes. The usual arrangement is the trailer's own music bed played by the director, the game's
music bus muted, and the game's SFX left live on camera and muted only backstage.

## Rendering

```powershell
godot --path . res://trailers/trailer.tscn --write-movie out/trailer.avi --fixed-fps 60
```

- `--write-movie <file>` forces `--fixed-fps`; passing `--fixed-fps` as well sets the film's frame
  rate (`editor/movie_writer/fps`, default 60, is the fallback).
- `--quit-after <frames>` bounds the render for a test cut. Verified: `--quit-after 60` at
  `--fixed-fps 60` produced exactly 1.000 s.
- `--disable-vsync` speeds up writing.
- The **file extension picks the writer**:

| Extension | Video | Audio | Notes |
| --- | --- | --- | --- |
| `.ogv` | Theora | Vorbis | Lossy, medium size, fast. Theora encoding is available in **editor binaries only**. |
| `.avi` | MJPEG | uncompressed PCM | Lossy, medium size, fast. No transparency, 4 GB file cap. |
| `.png` | PNG sequence | WAV beside it | Lossless, large, slow. Meant to be encoded afterwards. |

Quality dials live in project settings, and the live defaults on 4.7.2 are worth knowing before
touching any of them:

```
godot-mcp project settings --section editor/movie_writer
# fps 60 · video_quality 0.75 · mix_rate 48000 · audio_bit_depth 16 · speaker_mode 0
# disable_vsync false · movie_file "" · ogv/audio_quality 0.5 · ogv/encoding_speed 4
# ogv/keyframe_interval 64
```

### The film's resolution is a project setting, not the window

**`display/window/size/viewport_width` and `viewport_height` decide the recorded resolution.**
Resizing the window from the director does not move it, and neither does `--resolution`: a project
whose viewport is 2560×1440, filmed in a window forced to 1280×720 with `--resolution 1280x720`
passed as well, still wrote a 2560×1440 film. The same scene in a project whose viewport is
1280×720 wrote 720p. So set the viewport to the delivery resolution and let the window be whatever
is convenient.

```
godot-mcp project settings --key display/window/size/viewport_width
godot-mcp project set-setting --key display/window/size/viewport_width --value 1920
godot-mcp project set-setting --key display/window/size/viewport_height --value 1080
```

That write persists to `project.godot`, so a film rendered at a resolution the game does not
normally use means changing the setting, rendering, and changing it back.

### The encode, and the render script

MJPEG in an AVI is a working file, not a deliverable. Encode to H.264 for a store page:

```powershell
ffmpeg -y -i out/trailer.avi -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p `
    -c:a aac -b:a 192k -movflags +faststart out/trailer.mp4
```

`yuv420p` is what makes the file play everywhere, and `+faststart` moves the index to the front so
it streams. Wrap both steps in one script that takes the scene as a parameter and names the output
after it, so two films cannot overwrite each other. If that script is PowerShell, **keep it ASCII**:
`powershell.exe` 5 reads an unmarked file as ANSI, and a UTF-8 em dash inside a string is a parse
error.

## Verify before spending a render

A render costs minutes and an unattended window. The editor loop costs seconds, so prove the
staging there first.

```
godot-mcp scene play --mode res://trailers/trailer.tscn
godot-mcp runtime screenshot --save-path user://t.png       # repeat along the timeline
godot-mcp runtime capture-frames --count 8 --frame-interval 30
```

- **Screenshot the shot, not the film**. Play the director scene, grab frames at the moments the
  shot list names, and look at what is actually on screen — a bubble on a face, a card over a
  button, a hand frozen over dead space.
- **To catch a sub-second beat, drive `Engine.time_scale` from `runtime eval`**. A CLI round trip is
  around a second, so a 0.3 s flight is over before the next command lands. Slow the game, sample,
  restore, and put the whole sequence in one invocation.
- **After the render, measure it**. Duration against the shot list, then extract frames and look:

```powershell
ffprobe -v error -show_entries format=duration -of default=nw=1 out/trailer.mp4
ffmpeg -i out/trailer.mp4 -vf fps=1/5 out/frame_%02d.png
```

A film that runs long usually has a wait ceiling in it. Find the frame the footage stalled on
before blaming pacing.

## Filming a performance instead of scripting one

Some footage is easier played than written — a fight, a platforming line, a drag across a map.
Record a real take through the CLI, then replay the events inside the film.

```
godot-mcp scene play
godot-mcp runtime start-recording
# play the take by hand
godot-mcp runtime stop-recording        # returns {events: [...], duration_ms: N}
```

Each event is a plain dict carrying `time_ms` and its shape (`key`, `mouse_button`, `mouse_motion`,
`action`). Save the array beside the director as JSON and let the director replay it, paced against
**film time** rather than the wall clock:

```gdscript
func _replay(events: Array) -> void:
	var elapsed := 0.0
	for data: Dictionary in events:
		var at := float(data.get("time_ms", 0)) / 1000.0
		while elapsed < at:
			elapsed += get_process_delta_time()
			await get_tree().process_frame
		var event := _rebuild(data)   # InputEventKey / MouseButton / Action from the dict
		if event != null:
			Input.parse_input_event(event)
```

`runtime replay` exists for driving a *live* game and paces off `Time.get_ticks_msec()`, which
stretches a performance across a render. It also needs the editor's game channel, which a render
process launched from the command line does not have. Record with the CLI, replay from the
director.

## Delivery

Keep one 16:9 master at the game's native resolution and cut everything else from it. A vertical
cut is a **re-render with a vertical viewport**, not a crop — a crop of a 16:9 frame throws away the
composition the shot was staged for, and the director can restage its bespoke pages for the taller
frame. Pull the store capsule still from an extracted frame rather than a new screenshot, so it
matches footage the viewer will actually see.

## What goes wrong

- **The film never ends**. The director fell off its shot list without `get_tree().quit()`; the
  writer records until the engine exits.
- **The film is the wrong size**. The viewport project setting decides it, not the window and not
  `--resolution`.
- **The film runs long and a screen sits idle in it**. A wait predicate is wrong and burned its
  ceiling. Check the stalled frame.
- **An object was read before it settled**. A fixed sleep after a staggered animation races the last
  one. Poll per object.
- **A tween strands mid-animation on camera**. It started at the backstage `time_scale`. Anything
  filmed runs at 1.0.
- **Unscripted lines appear**. The spontaneous dialogue, tutorial, or hint layer was not silenced in
  the fixture.
- **The developer's save file changed after a render**. A persist flag was left on.
- **The rig shipped**. `trailers/*` was missing from a new export preset's `exclude_filter`.
- **The render script fails to parse**. A UTF-8 dash in an ANSI-read PowerShell file.
