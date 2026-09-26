"""Caption the generated narration without reading delivery tags on screen."""
import json
from pathlib import Path
import textwrap

root = Path(__file__).resolve().parents[1]
cues = json.loads((root / "trailers/narration-v2.json").read_text(encoding="utf-8"))
speeds = {1: 1.13, 2: 1.08, 3: 1.10, 7: 1.15}
blocks = []


def stamp(seconds):
    value = round(seconds * 1000)
    return f"{value // 3600000:02}:{value // 60000 % 60:02}:{value // 1000 % 60:02},{value % 1000:03}"


for index, cue in enumerate(cues):
    source = root / f"trailers/audio/v2/voice_{index:02}.timing.json"
    timing = json.loads(source.read_text(encoding="utf-8"))["alignment"]
    speed = speeds.get(index, 1.0)
    words = []
    word = ""
    begin = 0
    in_tag = False
    for pos, char in enumerate(timing["characters"] + [" "]):
        if char == "[":
            in_tag = True
        if in_tag:
            if char == "]":
                in_tag = False
            continue
        if char.isspace():
            if word:
                words.append((word, begin, min(pos - 1, len(timing["characters"]) - 1)))
                word = ""
        else:
            if not word:
                begin = pos
            word += char
    group = []
    for number, item in enumerate(words):
        group.append(item)
        text = " ".join(w[0] for w in group)
        if len(text) < 68 and not item[0].endswith((".", "!", "?")) and number < len(words) - 1:
            continue
        start = cue["start"] + timing["character_start_times_seconds"][group[0][1]] / speed
        end = cue["start"] + timing["character_end_times_seconds"][group[-1][2]] / speed
        lines = textwrap.fill(text, width=44)
        blocks.append(f"{len(blocks) + 1}\n{stamp(start)} --> {stamp(end)}\n{lines}\n")
        group = []
(root / "out/at-your-service-v2.srt").write_text("\n".join(blocks), encoding="utf-8")
