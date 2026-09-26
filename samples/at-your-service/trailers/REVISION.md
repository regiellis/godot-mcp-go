# Trailer revision after the hand-edited script

## Voice polish follow-up

The current cut is **416.733 seconds (6:57)**, exported as
`out/at-your-service-polished.mp4`. PSONA now performs the full script in one
continuous take, with paragraph-level delivery directions and a consistent
voice configuration. This avoids independently generated section voices.
Static chapter gains target -24 LUFS instead of matching peaks; the older
peak-normalized sections differed by about 3 dB in perceived loudness.
Natural tempo, dynamics, and the established viewing holds remain intact.

The closing sentence is “Swallowtail is at your service.” The project spelling
is retained. The accepted performance omits the nonessential “Before we start”
lead-in; the script, alignment, and captions follow what is actually spoken.
The installation prerequisites are retained in a clearer opening sentence.
`narration-polish-master.json`, `narration-polish-qc.json`, and `audio/polish/`
preserve generation provenance, the independent transcript, and forced alignment.

The previous export was checked against its lossless frames at eleven points.
World-panel SSIM ranged from 0.9887 to 0.9956; this did not isolate the reported
uneven picture quality. The new export retains native 1080p, 8× MSAA, lossless
intermediate frames, and CRF 16 encoding. A timestamp is still needed to identify
any particular shot whose appearance needs adjustment.

The polished delivery passed a complete video/audio decode, native 1920 × 1080
at 30 fps, all 13 chapter markers, and 104 English caption blocks. The 12,502
delivered frames cover 416.733 seconds. AAC audio peaks at -5.6 dBFS. Measured
narration section loudness spans 1.24 dB. The captured soundtrack matches the
reference stems with correlation approximately 1.0 and a 1.375 ms offset.
All 43 card layouts and the paragraph-hold schedule passed validation; the
independent transcript matches all 760 normalized words of the accepted script.
The closing card remains visible on the last frame. Detailed reports are in
`out/polish-delivery-validation.json`, `out/polish-loudness-validation.json`,
and `out/polish-audio-sync.json`.

## Previous production (before voice polish)

The polished script is recorded in the established PSONA voice. The measured
cut is **432.333 seconds (7:12)**, with thirteen narration sections and 43
editable shot cards. The preliminary 6:30 target was extended to preserve
the measured delivery and viewing holds; no speech was accelerated.

The new sections answer why someone would use this alongside the editor,
explain repeated work at scale, and distinguish an agent's feedback loop
from MCP's role as an interface. The hand-written additions were treated as
editorial notes and developed into complete spoken paragraphs.

The native Godot scenes and timeline now include the revision. New cards
cover the editor question, scale examples, CLI/MCP interfaces, and workflow
choice. Existing commands, object changes, lighting, and camera motion are
retimed to the actual words. The lighthouse demonstration is framed closer.
The end-card URL and title spacing are corrected.

Audio sources and alignment are preserved in `audio/revision/`.
`narration-revision.json` records exact paragraph and word placements.
The same placements produce `captions-revision.srt` and chapter metadata.
The mixer inserts viewing holds of two to four seconds, plus a ten-second
agent demonstration interval; it retains the fixed-level music approach.

The render uses PNG frames and Godot's recorded WAV, followed by H.264 CRF 16
and AAC 256 kbps. The 3D viewport uses 8× MSAA without FXAA. The new film is
`out/at-your-service-revised.mp4`, with English selectable subtitles and
chapter markers. Earlier MP4s remain available for comparison.

## Findings from the previous cut

- The hand-edited commits `8237786` and `60a7a06` followed the narration
  generation in `6991afd`. Their additions had not reached that audio.
- The previous `voiceover.md` had stale word counts and fixed cue windows
  after its paragraphs grew. `narration-v2.json` contained the earlier copy.
- The old export was already 1920 × 1080 at 30 fps, with a 1080p project and
  3D viewport. The quality complaint was not explained by a sub-1080p export.
- The older composition made the lighthouse relatively small, reducing the
  visible detail of the edit. It also used an MJPEG intermediate and an
  additional FXAA pass. Those were plausible contributors to softness, not
  a proven single cause of the regression.
- The old mixer sped up five cues by factors of 1.03 to 1.13. Its first four
  gaps were only about 0.75, 0.78, 0.82, and 0.78 seconds.
- The old caption builder had a different speed table from the mixer, and
  the old render wrapper did not embed or regenerate captions.

## Previous export validation

- Godot imported the new audio and loaded the revised scenes.
- All 43 shot cards passed the visibility and text-width audit. Representative
  native-resolution frames were inspected, including the new sections,
  lighthouse movement, shoreline, live adjustment, and closing card.
- The schedule audit passed: all requested paragraph holds are present,
  word placements and shot cards do not overlap, all animation keys are
  ordered, and the audio and picture durations agree.
- A nine-second rendered motion test contained 270 frames at 1920 × 1080,
  with the expected audio. Its recorded soundtrack correlates with the
  reference mix at 0.999999, with a measured offset of about 1.4 ms.
- All thirteen generated takes were independently transcribed. No substantive
  line was missing; `narration-revision-qc.json` preserves the transcript
  comparison. Recognition heard “and scripts” for “in scripts” once.
- The complete MP4 decoded without picture or audio errors. It contains 13
  correctly placed chapter markers and 93 English subtitle blocks. The AAC
  soundtrack peaks at -7.4 dBFS, with no clipping.
- Final-frame inspection caught an extra frame after the closing card. The
  wrapper now delivers exactly the timeline's frame count, and the closing
  card remains visible at the animation's end key. The corrected cut has
  12,970 frames at 30 fps (432.333 seconds).
- `out/delivery-validation.json` records final dimensions, duration, codecs,
  chapter/caption counts, peak level, and extracted review frames. The full
  render completed without the cleanup diagnostics seen in the bounded preview.

## Editing and provenance

`script.md` lists the delivered section boundaries. `voiceover.md` carries
the spoken script and pauses. The chapter scenes and native animation library
remain the picture master; the render wrapper does not regenerate them.
See `EDITING.md` for preview, mixing, and rendering commands.

The existing `takes-v2.json` supplies the recorded CLI and MCP results.
This is an authored walkthrough using those results, not a captured editor
window or an AI conversation. The scale section labels larger scenarios as
use cases, and the calm plan demonstrates a small repeatable workflow. No
hundred-object benchmark or new agent session is claimed.

The development build reported resource-cleanup diagnostics when a short
preview was stopped with `--quit-after`. These are retained in its render log;
there were no scene/script failures in the visibility audit or frame previews.
