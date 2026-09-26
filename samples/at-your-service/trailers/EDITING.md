# Edit the trailer in Godot

Open `res://trailers/film.tscn`. Press F6 to play the film (7:49, take 4) with
its voice and music. F5 still starts the playable lighthouse sample.

Select the `AtYourService` root and change **Preview Time** in the Inspector
to see any point in the film, silently. For example, 114 shows the lighthouse
placement command, 279 the live water adjustment, and 396 the MCP result.

Select `Timeline`, choose **Film** in the Animation panel, and scrub or play
the timeline. The animation library is saved in `timeline/film_library.tres`.
It contains card visibility, camera movement, object transforms, shader values,
lighting, transitions, and the two audio tracks.

## Text, console panels, and mascots

Open a chapter scene from `trailers/chapters/`, either in the FileSystem dock or
with the scene icon beside its instance under `Chapters` in the main scene.

Select the chapter root and use **Preview Step** to choose the card to edit.
The children are numbered and named, such as `S06_GiveItAHome` in `building.tscn`.
F6 also previews the selected card when running a chapter by itself.

- `Title`, `Subtitle`, `Note`, and `SceneCaption` are normal Label nodes.
- `Console` groups its background, heading, command-line Labels, and result.
- `SeatedMascot` and `CheckingMascot` are TextureRect nodes. Move or resize them
  with the 2D handles. `MascotPlinth` is a separate ColorRect.
- Colours, fonts, font sizes, and label text are Inspector properties. The
  shared display font is `timeline/display_font.tres`.

Save the chapter scene to update its instance in the trailer. The old JSON
shot list and recordings are provenance; playback does not load them or replace
the text in these nodes. Edits to the scene nodes are the source of truth.

The layouts preserve their original 1920 by 1080 canvas. Text is left aligned
and sized explicitly. After changing copy, check it against the console bounds
and the mascot, especially on the longer command lines.

## Timing and scene changes

In the master scene, each card has a `visible` track on `Timeline`. Move its
true/false keys to adjust when it appears. Preview Step is an editing aid for
standalone chapters; the master visibility tracks determine the film timing.
The start/end metadata on card roots matches the delivered revision; update
it with any future timing edits. `shots-revision.json` is a delivery snapshot.

The coast is an editable scene instance under `WorldViewport/Viewport/Coast`.
The animation tracks address the camera, Sun, Water material, Lighthouse, and
ShoreRock. Edit the relevant keys for animated properties; an Inspector change
to an animated property is replaced when that track is evaluated. Static
properties and chapter layouts remain ordinary node edits.

The original staging was converted to a reduced set of property keys. No
runtime script recreates the artwork or calculates the camera path. The small
player script only starts playback, supports preview seeking, and ends a movie
render. The chapter script only switches the standalone editing preview.

## Audio and rendering

`Audio/Voiceover` and `Audio/Music` are separate AudioStreamPlayer nodes. Their
included Ogg streams in `audio/take4/` contain the cue spacing and fixed
levels. Earlier takes remain in `audio/polish/`, `audio/revision/` and `audio/v2/` for comparison.
Use each node's **Volume dB** to adjust its overall level. To replace a stream
or move its start, edit its audio key in **Timeline > Film**. The current music
has its opening and closing ramps baked into the stream; no ducking is used.

```sh
python trailers/render.py --godot /path/to/godot --output at-your-service-take4.mp4
```

This renders `out/at-your-service-take4.mp4` using lossless PNG frames and
the audio recorded by Godot from the scene, then encodes H.264 CRF 16 with
AAC audio, English selectable captions, and chapter markers. Each run retains
its frames, WAV, engine log, and encoder log in a timestamped `out/render-*`
folder. It does not recreate chapter layouts or overwrite node edits.

For a short motion check:

```sh
python trailers/render.py --godot /path/to/godot --start 106 --seconds 9
```

To encode an existing full set of frames again, pass
`--encode-only out/render-YYYYMMDD-HHMMSS`. When re-encoding a preview, also
pass the original `--start` and `--seconds` so it does not receive full-film
captions and chapter metadata. `--output` accepts a filename under `out/`.

The new recording script is `voiceover.md`. `mix_revision.py` uses NumPy and
FFmpeg to assemble the continuous performance at normal speed, inserting the
specified paragraph holds. Rebuild the current performance with:

```sh
python trailers/mix_revision.py --performance trailers/narration-take4-master.json
```

A performance record may name its own `audio_dir` and give each cue a
`holds` list, one entry per paragraph; the take-4 record does both.

This applies a static gain per chapter targeting -24 LUFS with a -3 dBTP
ceiling. It does not compress, change pitch, or stretch the delivery. Without
`--performance`, the mixer rebuilds the older separate-take revision.
Install NumPy with `python -m pip install numpy`
if needed. It writes the two Ogg stems, measured placements
in `narration-revision.json`, captions, and chapter metadata. It does not
retime the Godot picture: if new takes change the timing, adjust the native
animation keys to the measured placements before rendering again.

The old `mix_v2.py` and `captions_v2.py` belong to the earlier five-minute cut.
Do not use them to rebuild this revision. In particular, the old speed table
and 300-second trim do not apply to the new narration.

After a timeline edit, update the captions and `chapters.ffmetadata` as needed;
the render wrapper embeds those files but cannot infer changed speech timing.
