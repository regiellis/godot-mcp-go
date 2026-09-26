# At your service: walkthrough

Length: 469.433 seconds (7:49). Landscape 1920 × 1080, 30 fps.

| Time | Chapter |
| --- | --- |
| 0:00–0:29 | At your service |
| 0:29–1:04 | Why not just use the editor? |
| 1:04–1:51 | Connect the editor |
| 1:51–2:23 | Move and scale the lighthouse |
| 2:23–2:53 | Shape the shoreline |
| 2:53–3:28 | When the work scales up |
| 3:28–4:21 | Make it repeatable |
| 4:21–4:52 | Playtest and inspect |
| 4:52–5:31 | Try it live, then save the choice |
| 5:31–6:20 | What the AI actually does |
| 6:20–7:00 | Where MCP fits |
| 7:00–7:35 | Choose your workflow |
| 7:35–7:49 | Your game. Your workflow. |

The timeline plays take 4, recorded from `voiceover-draft.md` (draft 4) as one
continuous PSONA performance. `narration-take4-master.json` holds its script,
delivery tags and per-paragraph holds; the audio and forced alignment are in
`audio/take4/`. It is a listening cut: the chapter scenes keep their layouts,
the full-width card in the editor question is retitled to "Do it once. Run it
again." to match the new words, and the picture changes the draft lists are
not built yet. `voiceover.md` is the script of the earlier polished
cut (6:57, `audio/polish/`), whose timing is in git history at `3419ac0`.

`voiceover.md` contains the polished spoken copy and viewing directions.
`narration-polish-master.json` records the continuous performance and
paragraphs; its audio and forced alignment are in `audio/polish/`. `narration-revision.json` records their measured placements and
word alignment, which also drives `captions-revision.srt` and chapter metadata.
The established PSONA custom voice is retained. No take is sped up.

`shots-revision.json` records the 43 card windows. The editable chapter scenes
and `timeline/film_library.tres` are the source of truth for picture playback.
The lighthouse move and scale, rock placement, wave changes, camera movement,
and sunlight changes are retimed with the narration. Wave motion runs at
normal film speed during pauses. The agent demonstration has ten seconds
between paragraphs for applying changes, saving, and looking at the result.

Terminal and MCP results in `takes-v2.json` are the existing recorded evidence.
The demonstrations remain authored staging of those operations, not a captured
editor window or an invented AI conversation. Scale examples are explicitly
labeled as use cases; the calm plan is the small demonstrated workflow.
The runtime chapter explicitly plays a rough-water variation before adjusting
it live. The subsequent agent chapter saves the chosen value in the editor.

Music is the existing original ElevenLabs lo-fi cue, extended with two-second
crossfades. Narration sections receive static gains targeting -24 LUFS, preserving dynamics. Music has a -25 dBFS bed ceiling, with
manually timed opening/closing ramps. The PCM mix peaks at approximately
-5.7 dBFS. There is no speech-triggered ducking or added sound effect.

The render uses lossless PNG frames and Godot's captured WAV soundtrack,
then H.264 CRF 16 with AAC 256 kbps. English captions are embedded as a
selectable track and also available as an SRT. Chapter markers are included.
The 3D viewport uses 8× MSAA without FXAA; the build demonstration has a
closer field of view. The master and its assets remain editable in Godot.

Run `python trailers/render.py --godot /path/to/godot --output at-your-service-take4.mp4` from the sample folder.
The final file is `out/at-your-service-take4.mp4`. Previous MP4 exports are
preserved. See `EDITING.md` for the editing and short-render workflow, and
`REVISION.md` for the review findings and validation record.
