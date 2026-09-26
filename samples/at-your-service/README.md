# At your service

A five-minute Swallowtail walkthrough and playable coastal scene, built in Godot 4.7 by an agent driving swallowtail.

Run it:

```sh
godot --path .
```

Hold right mouse to look, use WASD to move, Space to rise, Shift to descend,
and the mouse wheel to change speed.

## What it shows

The trailer is editable in Godot. Open `trailers/film.tscn`, select the root's
**Preview Time**, or scrub **Timeline > Film**. Nine chapter scenes contain
normal text, console, and mascot nodes; each chapter has a **Preview Step**
selector. See [the editor guide](trailers/EDITING.md) for layout, timing, camera,
and audio changes. F6 plays the trailer with sound.

The film follows one lighthouse scene through terminal commands, repeatable
checks, a playtest and adjustment, an agent task, and an MCP readback. Its
opening and closing cards use Swallowtail's mascot, typography, and colours.

```sh
godot --path . res://trailers/film.tscn
python trailers/render.py --godot /path/to/godot
```

Rendering requires Python, FFmpeg, and Godot with Forward+ support. The output
is `out/at-your-service-nodes.mp4`, 1920 by 1080 at 30 frames per second, with
chapter markers. The previous cut's optional `out/at-your-service-v2.srt`
captions remain valid until narration timing changes.

The film is an authored demonstration with cinematic camera moves and typeset
tool excerpts. It is not a screen recording of an agent conversation. CLI and
MCP outputs in `trailers/takes-v2.json` were recorded against this project; check
counts, water readbacks, transforms, and the MCP value were converted into
editable scene nodes and animation keys. Playback uses those authored scenes,
without replacing node edits from JSON. The agent chapter stages recorded tool
operations. Console result text is summarized for readability. Shader readback
snippets are formatted across lines without changing their operations.

The longer cut explains setup, distinguishes engine tasks from live editor
commands, moves and scales the lighthouse, duplicates shoreline geometry, runs
`trailers/calm.json` twice, and inspects a running playtest before changing its
water. The final MCP call edits the sunlight and reads its rotation back.

`trailers/script.md` contains the shot list. To record new tool results, install
and enable Swallowtail in this project, open its editor, then run
`python trailers/record_extended.py /path/to/swallowtail /path/to/godot`.
New recordings do not automatically rewrite the authored chapter scenes.
Remove the build-time plugin and its autoload settings before distributing.

## Credits and licence

The lighthouse, coastal assets, textures, and water shader originate in Daniel
Shervheim's Unity Stylized Water project, ported in the sibling lighthouse-demo
sample. The upstream BSD 3-Clause licence and README are included in
`assets/shervheim_demo`. The water port retains its attribution.

Manrope, Inter, and Source Code Pro retain their font licence files alongside
the fonts. Swallowtail's existing mascot artwork comes from this repository's
website brand assets. The film adds a mulberry lighthouse material and a
deterministic camera and editorial timeline.

The revised score and narration were generated with ElevenLabs. The maintainer
requested their PSONA custom voice, using Eleven v3 with inline delivery tags.
The script, voice identifier, model, and cue positions are recorded in
`trailers/narration-v2.json`. The lo-fi instrumental uses Rhodes, soft drums,
bass, and guitar, with crossfades extending the generated cue into a continuous
bed. Included audio files allow rendering without an API.

The mix uses fixed gains: voice cues peak at -8 dBFS, and music stays at a
-25 dBFS ceiling during narration. Planned opening and closing ramps raise the
music ceiling to -15 dBFS. There is no automatic ducking. The mixer writes
measured levels and cue durations to `out/mix-report.json`.

Two new mascot poses were generated with the built-in image generator from the
existing presenting pose. Their prompts and asset paths are recorded in
[`trailers/brand/poses.md`](trailers/brand/poses.md).
