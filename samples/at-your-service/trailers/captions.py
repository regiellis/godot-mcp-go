"""Create optional captions from voice alignment, accounting for the slower mix."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cues = json.loads((root / "trailers/narration-sources.json").read_text(encoding="utf-8"))
blocks = []


def stamp(seconds):
    value = round(seconds * 1000)
    return f"{value // 3600000:02}:{value // 60000 % 60:02}:{value // 1000 % 60:02},{value % 1000:03}"


for index, cue in enumerate(cues):
    source = root / f"trailers/audio/voice_{index:02}.timing.json"
    timing = json.loads(source.read_text(encoding="utf-8"))["alignment"]
    chars = timing["characters"]
    start = 0
    for end, char in enumerate(chars):
        if char not in ".!?" and end != len(chars) - 1:
            continue
        text = "".join(chars[start:end + 1]).strip()
        if text:
            begin = cue["start"] + timing["character_start_times_seconds"][start] / 0.9
            finish = cue["start"] + timing["character_end_times_seconds"][end] / 0.9
            blocks.append(f"{len(blocks) + 1}\n{stamp(begin)} --> {stamp(finish)}\n{text}\n")
        start = end + 1
(root / "out").mkdir(exist_ok=True)
(root / "out/at-your-service.srt").write_text("\n".join(blocks), encoding="utf-8")
