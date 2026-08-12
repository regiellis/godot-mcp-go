# Game videos and trailers: filming a Godot game with the engine itself

How an agent plans, stages, films, and cuts trailers and feature videos for a Godot game across
multiple lengths and delivery formats. The same rig should be able to produce a 15 to 30 second
hook, a 30 to 60 second store trailer, a 60 to 90 second extended cut, or a 2 to 3 minute
feature/gameplay trailer, then restage that cut for landscape, near-square, feed portrait, square,
or full vertical delivery.

The game renders its own footage: Godot's **movie writer** runs the project offline at a fixed
frame rate and writes every frame plus the master audio bus to a file, so the capture is
frame-perfect however slow the machine is. Screen-recording software is the wrong tool here,
because it films a game fighting for frames and cannot be re-run when a line of dialogue changes.

Because the film is rendered rather than captured, a trailer here is a **deterministic scene,
re-authored and re-rendered at will**. Duration, aspect ratio, camera framing, UI placement,
dialogue layout, title-card typography, and even which version of a shot is used are all inputs
to that scene.

The engine behaviour and the commands below were checked against **Godot 4.7.2** on 2026-08-09; the
staging patterns come from a two-film rig built with this CLI. Each idea pairs with a **Build:**
recipe; adapt them rather than running them end to end.

The division of labour: the **director scene** decides what happens on camera, the **movie writer**
records it, **ffmpeg** encodes it, and **godot-mcp** drives the iteration loop between takes so a
render is spent only on footage already known to be right.

The finished output is a matrix:

- **Editorial cut**: short hook, store trailer, extended trailer, or 2 to 3 minute feature.
- **Delivery profile**: 16:9, 5:4, 4:5, 1:1, 9:16, or another explicitly supported viewport.
- **Quality profile**: fast review render, final working render, or final encode.
- **Language/version profile**: optional alternate dialogue, localized cards, ratings card, or CTA.

The director owns editorial intent. The delivery profile owns composition. The render script owns
resolution and filenames. Keeping those concerns separate is what lets the same trailer concept
survive a move from a desktop store page to a phone without becoming a blind center-crop.

## The film is decided before the rig exists

Write the shot list first, as a file in the repo, and make it the source of record. The director
script is built *to* the shot list, and a change to the film starts there rather than in the code.

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

**Plan each length as its own film.** A 30 second trailer and a 3 minute trailer should not be
the same shot list with different amounts cut out. The longer film has room for
setup, contrast, explanation, and recovery beats that would kill the pace of a short promo.

## Plan by duration profile

These are starting structures. The track and the game bend them:

| Profile | Typical job | Editorial shape |
| --- | --- | --- |
| **Hook** (15 to 30 s) | short-form promo, teaser, announcement | one idea, one escalation, one payoff |
| **Store** (30 to 60 s) | store page, launch trailer, compact social cut | hook → premise → core loop → escalation → close |
| **Extended** (60 to 90 s) | feature-heavy trailer, publisher/social post | hook → premise → loop → depth → payoff → close |
| **Feature** (120 to 180 s) | gameplay overview, feature trailer, longer showcase | hook → setup → loop → depth → variation → climax → close |

A useful timing sketch:

**15 to 30 seconds**
- 0 to 3 s: immediate hook.
- 3 to 10 s: establish the verb, threat, character, or fantasy.
- 10 to 22 s: one or two escalating beats.
- final 3 to 6 s: payoff and end card.

**30 to 60 seconds**
- 0 to 4 s: hook.
- 4 to 15 s: premise and visual identity.
- 15 to 40 s: core loop shown through a continuous mini-story.
- 40 to 52 s: escalation, surprise, or strongest feature.
- final 6 to 10 s: payoff, title, CTA.

**60 to 90 seconds**
- 0 to 5 s: hook.
- 5 to 20 s: premise.
- 20 to 50 s: core loop with enough continuity to understand cause and effect.
- 50 to 72 s: systems, variation, rival/character beat, or secondary mechanic.
- final 10 to 18 s: climax and close.

**120 to 180 seconds**
- 0 to 8 s: hook that earns the longer watch.
- 8 to 35 s: world, goal, stakes, or player fantasy.
- 35 to 85 s: core loop shown clearly enough that the viewer understands what they do.
- 85 to 135 s: depth through variation, progression, secondary systems, characters, modes, or a change of pace.
- 135 to 160 s: strongest escalation or showcase sequence.
- final 10 to 20 s: release of tension, title, CTA, platform/date information.

**The long form needs breathing room.** Do not turn three minutes into a three-minute montage. Let
a few shots run long enough for an action to begin, resolve, and produce a consequence. The viewer
of a feature trailer has opted into explanation; use that permission.

**The short form needs the opposite discipline.** If a 20-second cut needs a paragraph of context
before the interesting action makes sense, it is probably the wrong shot for that cut.

## Write the shot list as data

The shot-list file should carry enough information for both duration and aspect-ratio variants:

| Field | Purpose |
| --- | --- |
| `id` | stable shot name used by the director |
| `time` / `duration` | intended film-time range |
| `beat` | hook, setup, loop, escalation, climax, end card |
| `action` | what actually happens |
| `dialogue` | exact authored line, if any |
| `audio` | music hit, SFX priority, silence, or transition |
| `landscape` | framing notes for 16:9 / 5:4 |
| `portrait` | framing notes for 4:5 / 9:16 |
| `short_cut` | whether/how the shot appears in 15 to 60 s versions |
| `long_cut` | whether/how the shot expands in 60 to 180 s versions |
| `exit` | visual/audio condition that makes the cut safe |

A shot can therefore be the same event without being the same composition. The winning throw may
be a wide two-character shot in 16:9, a tighter two-shot in 5:4, and an over-the-shoulder or
single-character composition in 9:16.

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
film gets its own scene and script rather than a shared base class. Keeping a finished film
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

The quit is load-bearing. The writer keeps recording until the engine exits, so a director that
falls off the end of its shot list produces a film that runs until somebody closes the window.

## One editorial cut, multiple delivery profiles

A film can have several delivery profiles without becoming several unrelated trailers. Keep the
story beats stable and let the director select explicit composition values for the target viewport.

Do not make aspect ratio an accidental side effect of `get_viewport_rect()`. Name it:

```gdscript
enum DeliveryProfile {
	LANDSCAPE_16_9,
	LANDSCAPE_5_4,
	PORTRAIT_4_5,
	SQUARE_1_1,
	VERTICAL_9_16,
}

var delivery_profile := DeliveryProfile.LANDSCAPE_16_9
var editorial_profile := &"store_60"
```

The render wrapper can pass those values through project metadata, command-line user arguments, a
small JSON manifest, or a dedicated exported property; any of them works. The rule is that **the
director knows the intended output before it stages frame one.**

Inside each shot, branch only where composition really changes:

```gdscript
func _shot_the_turn() -> void:
	match delivery_profile:
		DeliveryProfile.VERTICAL_9_16:
			_stage_turn_vertical()
		DeliveryProfile.PORTRAIT_4_5:
			_stage_turn_portrait()
		_:
			_stage_turn_landscape()

	await _play_turn()
```

The event `_play_turn()` stays the same. Only staging changes. That keeps the film honest while
avoiding five copies of gameplay logic.

For a finished film, prefer local profile tables inside that film's director over a shared global
trailer framework. The original reason for one scene/script per film still applies: changing film
two must not silently change a finished film one's render path.

## Five rules that keep a render honest

1. **Never write the developer's saves.** Progress, stats, and settings singletons get their
   persist flags turned off and their state driven from an in-memory fixture. A film that unlocks
   everything to shoot a roster must not leave the machine that way.
2. **Never go fullscreen.** The take is unattended and a fullscreen window is hostile to whoever is
   at the keyboard. Force windowed in `_enter_tree`, before the first frame.
3. **Drive the real handlers.** Call `_on_die_clicked`, `_select_mode`, the same entry points a
   player's input reaches, rather than writing the resulting state. What is filmed is then what a
   player gets. Where a handler cannot produce the frame the shot is about, replay that handler's
   own branch call for call instead of faking its result.
4. **Rig the randomness, do not remove it.** Seed the RNG, or load a scripted deck between
   `instantiate()` and `add_child()` so the dealt cards land on known faces. The shot list can then
   name a score, and the film matches it every render.
5. **No wait may strand the render.** Poll a predicate over frames with a ceiling, and treat a
   ceiling that fires as a wrong predicate rather than a slow game.

```gdscript
## Poll `cond` over frames with a wall-clock ceiling, so a surprised game cannot hang a render.
func _until(cond: Callable) -> void:
	var deadline := Time.get_ticks_msec() + int(WAIT_CEILING * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return
		await get_tree().process_frame
	push_warning("trailer: a wait hit its ceiling, footage may be off")
```

Predicates read the game's own idle state (not busy, player's turn, match not over), and anything
that animates gets polled per object. A fixed sleep after a staggered deal still races the last
tumble, which is how a die clicked as a 4 lands on a 3 on film.

## What rides film time, and what rides the wall clock

`--write-movie` forces `--fixed-fps`, which makes the reported delta identical every frame
regardless of how long that frame took to render. The whole rig is paced on that:

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

**Build:** the cover must size itself from the active viewport. A fixed 16:9 rectangle is not
enough once the same director can render 1080×1920.

```
godot-mcp node add --type CanvasLayer --parent-path . --name CoverLayer
godot-mcp node set --node-path CoverLayer --property layer --value 80
godot-mcp node add --type ColorRect --parent-path CoverLayer --name Cover
godot-mcp node set --node-path CoverLayer/Cover --property mouse_filter --value 2
```

Then size it in the director with a margin beyond every edge:

```gdscript
func _size_cover() -> void:
	var margin := Vector2(96.0, 96.0)
	var viewport_size := get_viewport_rect().size
	$CoverLayer/Cover.position = -margin
	$CoverLayer/Cover.size = viewport_size + margin * 2.0
```

Call `_size_cover()` before the first reveal. The movie viewport is fixed for a take, so it does
not need to be recomputed every frame.

## Words and sound

**Speak through the game's own dialogue path.** Calling the real "say this line" entry point gets
the real bubble, the real anchor, and the speaker's head animating; a Label dropped on top gets
none of it. Silence the spontaneous layer first so the scripted lines are the only ones that fire,
and give scripted lines a priority no game event can preempt.

A screen with no dialogue system of its own (a title, an end card) builds the bubble directly and
dresses it to match. Bubble placement geometry usually assumes a speaker sitting outside the
placement boxes, so a speaker standing inside one gets no legal candidate and the bubble lands on
their face: call the normal path for the build and entrance, then write the body position and tail
by hand for that page.

**Text layout is delivery-profile specific.** A line that is elegant in a 1920×1080 card can become
three ugly lines at 1080×1920. Give title cards and scripted bubbles explicit per-profile maximum
widths, line breaks, and anchor positions rather than relying on automatic wrapping. In vertical
cuts, reserve top and bottom breathing room for platform chrome by keeping critical copy toward the
interior of the frame; exact platform overlays can change, so the film should not depend on text
touching an edge.

**Sound:** the movie writer records the master bus, so the mix in the file is the mix the game
makes. The usual arrangement is the trailer's own music bed played by the director, the game's
music bus muted, and the game's SFX left live on camera and muted only backstage.

## Rendering

```
godot --path . res://trailers/trailer.tscn --write-movie out/trailer.avi --fixed-fps 60
```

- `--write-movie <file>` forces `--fixed-fps`; passing `--fixed-fps` as well sets the film's frame
  rate (`editor/movie_writer/fps`, default 60, is the fallback).
- `--quit-after <frames>` bounds the render for a test cut. Verified: `--quit-after 60` at
  `--fixed-fps 60` produced exactly 1.000 s.
- `--disable-vsync` speeds up writing.

The file extension picks the writer:

| Extension | Video | Audio | Notes |
| --- | --- | --- | --- |
| `.ogv` | Theora | Vorbis | Lossy, medium size, fast. Theora encoding is available in editor binaries only. |
| `.avi` | MJPEG | uncompressed PCM | Lossy, medium size, fast. No transparency, 4 GB file cap. |
| `.png` | PNG sequence | WAV beside it | Lossless, large, slow. Meant to be encoded afterwards. |

Quality dials live in project settings. Read the live defaults on 4.7.2 before touching any of
them:

```
godot-mcp project settings --section editor/movie_writer
# fps 60 · video_quality 0.75 · mix_rate 48000 · audio_bit_depth 16 · speaker_mode 0
# disable_vsync false · movie_file "" · ogv/audio_quality 0.5 · ogv/encoding_speed 4
# ogv/keyframe_interval 64
```

## The film's resolution is a project setting, not the window

`display/window/size/viewport_width` and `viewport_height` decide the recorded resolution.
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

## Delivery profiles are real viewports

Do not render one giant 16:9 master and assume every other version can be extracted from it. The
director should be staged and rendered at the actual delivery aspect ratio.

Useful profiles:

| Profile | Example viewport | Use |
| --- | --- | --- |
| 16:9 | 1920×1080 or 2560×1440 | desktop/store/video landscape |
| 5:4 | 1350×1080 | near-square landscape/feed placement |
| 4:5 | 1080×1350 | portrait feed |
| 1:1 | 1080×1080 | square feed/card |
| 9:16 | 1080×1920 | Shorts/Reels/TikTok-style full-screen vertical |
| 3:4 | 1080×1440 | optional portrait intermediary |

**5:4 and 4:5 are different products.** Keep both names explicit in scripts and filenames so a
near-square landscape render is never confused with a portrait-feed render.

For each profile, decide these before the shot runs:

- camera position, target, and FOV/zoom;
- whether the shot stays a two-shot or becomes a single-subject composition;
- where dialogue bubbles and HUD elements may live;
- title-card width and line breaks;
- whether environmental decoration needs to move inward;
- whether an action needs a different entrance direction;
- whether the shot should be replaced entirely because its idea does not read in that shape.

## Compose, do not crop

A vertical cut is a re-render with a vertical viewport, not a crop. Cropping a 16:9 frame can
remove the reacting character, the target of a throw, a HUD dependency, or the visual cause of the
next beat. Restaging is not optional when the composition depends on width.

Some shots can share staging across profiles. Classify them:

- **aspect-safe**: the important action already lives near center and survives every profile;
- **reframe**: same event, different camera/zoom/anchors;
- **relayout**: same game camera, but UI/dialogue/card positions change;
- **replace**: the landscape shot's visual idea does not work vertically, so use another shot.

Put that classification in `script.md`. It prevents the vertical pass from turning into a late
list of surprises.

## Keep an internal safe composition region

Do not confuse a safe composition region with a crop guide. The output still uses the whole frame.
The region is simply where information that must survive every platform treatment should prefer to
live.

For example, a 9:16 shot may use the full 1080×1920 image for environment and motion while keeping
faces, subtitles, interactable objects, and the key hit inside a more conservative interior area.
Decorative particles, sky, floor, and secondary motion can extend to the edges.

## Render a matrix, not one movie

A simple render manifest can make the expected outputs explicit:

```json
{
  "film": "launch",
  "cuts": ["hook_20", "store_60", "feature_150"],
  "profiles": {
    "16x9": [1920, 1080],
    "5x4": [1350, 1080],
    "4x5": [1080, 1350],
    "1x1": [1080, 1080],
    "9x16": [1080, 1920]
  }
}
```

Not every cut needs every aspect ratio. The manifest should list only products that will actually
ship.

The wrapper's job is:

1. remember the game's normal viewport;
2. set the requested trailer viewport;
3. launch the director with the chosen editorial and delivery profile;
4. wait for the movie writer to finish;
5. encode to a uniquely named deliverable;
6. restore the original project viewport even if the render fails.

Name outputs so there is no ambiguity:

```
out/launch_store_60__16x9_1920x1080.mp4
out/launch_store_60__9x16_1080x1920.mp4
out/launch_feature_150__16x9_1920x1080.mp4
out/launch_feature_150__4x5_1080x1350.mp4
```

## The encode, and the render script

MJPEG in an AVI is a working file, not a deliverable. Encode to H.264 for a store page:

```
ffmpeg -y -i out/trailer.avi -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p `
    -c:a aac -b:a 192k -movflags +faststart out/trailer.mp4
```

`yuv420p` is what makes the file play everywhere, and `+faststart` moves the index to the front so
it streams. Wrap both steps in one script that takes the scene as a parameter and names the output
after it, so two films cannot overwrite each other. If that script is PowerShell, keep it ASCII:
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

- **Screenshot the shot, not the film.** Play the director scene, grab frames at the moments the
  shot list names, and look at what is actually on screen: a bubble on a face, a card over a
  button, a hand frozen over dead space.
- **To catch a sub-second beat, drive `Engine.time_scale` from `runtime eval`.** A CLI round trip
  is around a second, so a 0.3 s flight is over before the next command lands. Slow the game,
  sample, restore, and put the whole sequence in one invocation.
- **Review every delivery profile, not just the landscape master.** A shot that is perfect in
  16:9 can hide a reaction, clip a bubble, or become visually empty in 9:16.
- **Review short and long editorial profiles independently.** The 150-second version can contain
  explanatory pauses that are correct there but fatal if they accidentally leak into a 30-second
  cut.

After the render, measure it. Duration against the shot list, then extract frames and look:

```
ffprobe -v error -show_entries format=duration -of default=nw=1 out/trailer.mp4
ffmpeg -i out/trailer.mp4 -vf fps=1/5 out/frame_%02d.png
```

A film that runs long usually has a wait ceiling in it. Find the frame the footage stalled on
before blaming pacing.

## Filming a performance instead of scripting one

Some footage is easier played than written: a fight, a platforming line, a drag across a map.
Record a real take through the CLI, then replay the events inside the film.

```
godot-mcp scene play
godot-mcp runtime start-recording
# play the take by hand
godot-mcp runtime stop-recording        # returns {events: [...], duration_ms: N}
```

Each event is a plain dict carrying `time_ms` and its shape (`key`, `mouse_button`,
`mouse_motion`, `action`). Save the array beside the director as JSON and let the director replay
it, paced against film time rather than the wall clock:

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

`runtime replay` exists for driving a live game and paces off `Time.get_ticks_msec()`, which
stretches a performance across a render. It also needs the editor's game channel, which a render
process launched from the command line does not have. Record with the CLI, replay from the
director.

## Delivery

A trailer campaign is a set of deliberate renders, not one master plus emergency crops.

**Landscape.** 16:9 is the main desktop/store/video version. 5:4 is a useful near-square variant
when a placement gives more height than 16:9 but still expects a landscape composition.

**Feed.** 4:5 gives a portrait feed version without committing to full-screen vertical. 1:1 is
useful where a square card or feed placement is still required.

**Full-screen mobile.** 9:16 is its own composition. Treat it as a phone-native film, not a
desktop trailer viewed through a slit.

The same editorial idea can exist in all of them, but the shot count does not have to be
identical. If a wide reveal only works in 16:9, the 9:16 cut can reach the same story beat with
two faster shots: subject first, consequence second.

**Long-form structure.** For a 2 to 3 minute feature trailer, preserve continuity across several
beats:

1. establish what the player is trying to do;
2. show the basic loop resolving at least once;
3. introduce variation or pressure;
4. show depth only after the base action is understood;
5. build to a sequence that could not have appeared in the opening 20 seconds;
6. give the ending room to land.

That structure also makes shorter derivatives easier. A 60-second cut can often take the hook, one
resolved loop, one depth beat, and the climax. A 20-second cut may take only the hook, a single
escalation, and the payoff.

**Pull stills from the actual render.** Pull store capsules, social stills, and thumbnails from
extracted frames of the delivery render they belong to rather than taking a fresh screenshot. The
still then matches the framing, state, lighting, and UI the viewer actually sees. For vertical
marketing art, extract from the vertical render; do not pull a 16:9 frame and crop it after the
fact unless the shot was explicitly marked aspect-safe.

## What goes wrong

- **The film never ends.** The director fell off its shot list without `get_tree().quit()`; the
  writer records until the engine exits.
- **The film is the wrong size.** The viewport project setting decides it, not the window and not
  `--resolution`.
- **The vertical version looks like a crop.** The director reused landscape staging instead of a
  vertical composition branch.
- **The 4:5 and 5:4 outputs were swapped.** The profile name was ambiguous; encode orientation and
  dimensions into both the manifest and filename.
- **The title card wraps differently on mobile.** Automatic wrapping was allowed to make an
  editorial decision. Set per-profile width and authored line breaks.
- **The short cut feels slow even though the long cut works.** A setup or recovery beat intended
  for the 2 to 3 minute version leaked into the short editorial profile.
- **The film runs long and a screen sits idle in it.** A wait predicate is wrong and burned its
  ceiling. Check the stalled frame.
- **An object was read before it settled.** A fixed sleep after a staggered animation races the
  last one. Poll per object.
- **A tween strands mid-animation on camera.** It started at the backstage `time_scale`. Anything
  filmed runs at 1.0.
- **Unscripted lines appear.** The spontaneous dialogue, tutorial, or hint layer was not silenced
  in the fixture.
- **The developer's save file changed after a render.** A persist flag was left on.
- **The rig shipped.** `trailers/*` was missing from a new export preset's `exclude_filter`.
- **The render script fails to parse.** A UTF-8 dash in an ANSI-read PowerShell file.
