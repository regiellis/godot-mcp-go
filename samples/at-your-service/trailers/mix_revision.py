"""Assemble the approved narration with real viewing holds, never tempo changes.

Source takes and alignment are preserved under audio/revision or audio/polish.
The resulting edit manifest is also the timing source for captions and picture.
"""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import textwrap

import numpy as np

ROOT = Path(__file__).resolve().parent
AUDIO = ROOT / "audio/revision"
OUT = ROOT.parent / "out"
RATE = 48000
MINIMUM_WINDOWS = [20, 35, 35, 30, 30, 35, 35, 30, 35, 40, 40, 15, 10]
# Silence after each paragraph, including time to inspect the final result.
HOLDS = [[3], [2, 2], [2, 3], [3, 2], [3, 3, 2], [2, 2],
         [3, 3, 2], [3, 2], [4, 2, 2], [10, 2], [2, 3, 3], [2], [1, 3]]


def run(args):
    return subprocess.run(args, check=True, capture_output=True)


def decode(path):
    raw = run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le",
               "-ar", str(RATE), "-ac", "2", "-"]).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).copy()


def save_audio(path, data):
    result = subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "f32le",
                             "-ar", str(RATE), "-ac", "2", "-i", "-",
                             "-c:a", "libvorbis", "-q:a", "8", str(path)],
                            input=data.astype("<f4").tobytes(), capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode())


def stamp(t):
    ms = round(t * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--performance', type=Path, help='Continuous performance provenance JSON')
    args = parser.parse_args()
    OUT.mkdir(exist_ok=True)
    audio_dir = AUDIO
    master = None
    if args.performance:
        performance = json.loads(args.performance.read_text(encoding='utf-8'))
        sources = performance['cues']
        audio_dir = ROOT / performance.get('audio_dir', 'audio/polish')
        master = decode(audio_dir / 'master.mp3')
        aligned = json.loads((audio_dir / 'master.aligned.json').read_text(encoding='utf-8'))['result']['characters']
        master_timing = {'characters': [c['text'] for c in aligned],
                         'character_start_times_seconds': [c['start'] for c in aligned],
                         'character_end_times_seconds': [c['end'] for c in aligned]}
    else:
        sources = json.loads((ROOT / "narration-revision-sources.json").read_text(encoding='utf-8'))
    chapters, clips, words = [], [], []
    cursor = 0.0
    for cue in sources:
        index = cue["index"]
        holds = cue.get("holds", HOLDS[index])
        source = audio_dir / ('master.mp3' if master is not None else f'voice_{index:02}.mp3')
        signal = master if master is not None else decode(source)
        timing = master_timing if master is not None else json.loads(source.with_suffix('.timing.json').read_text(encoding='utf-8'))['alignment']
        transcript = "".join(timing["characters"])
        if master is not None:
            first_char = transcript.index(cue['paragraphs'][0])
            final_char = transcript.index(cue['paragraphs'][-1], first_char) + len(cue['paragraphs'][-1]) - 1
            measure_start = timing['character_start_times_seconds'][first_char]
            measure_end = timing['character_end_times_seconds'][final_char]
            measure = run(['ffmpeg', '-hide_banner', '-ss', str(measure_start), '-t', str(measure_end-measure_start),
                           '-i', str(source), '-af', 'loudnorm=I=-24:TP=-3:LRA=11:print_format=json', '-f', 'null', '-'])
            stats = json.loads(re.search(r'\{\s*"input_i".*?\}', measure.stderr.decode(), re.S)[0])
            # Static gain only: preserve inflection and dynamics, match perceived section loudness.
            gain_db = min(-24 - float(stats['input_i']), -3 - float(stats['input_tp']))
        else:
            gain_db = -8 - 20 * math.log10(max(float(np.abs(signal).max()), 1e-9))
        chapter = {"index": index, "title": cue["title"], "start": cursor,
                   "source": str(source.relative_to(ROOT)), "tempo": 1.0, "gain_db": gain_db, "paragraphs": []}
        position = cursor + (0.8 if index == 0 else 0.65)
        scan = 0
        for pi, paragraph in enumerate(cue["paragraphs"]):
            begin = transcript.index(paragraph, scan)
            finish = begin + len(paragraph)
            scan = finish
            # Cut only between paragraphs, retaining consonant tails and room tone.
            first = timing["character_start_times_seconds"][begin]
            last = timing["character_end_times_seconds"][finish - 1]
            cut_in = max(0, first - 0.08)
            cut_out = min(len(signal) / RATE, last + 0.16)
            if pi + 1 < len(cue["paragraphs"]):
                following = transcript.index(cue["paragraphs"][pi + 1], finish)
                next_start = timing["character_start_times_seconds"][following]
                cut_out = min(cut_out, (last + next_start) / 2)
            part = signal[round(cut_in * RATE):round(cut_out * RATE)].copy()
            part *= 10 ** (gain_db / 20)
            # A short edge fade prevents clicks at editorial cuts.
            fade = min(240, len(part) // 2)
            part[:fade] *= np.linspace(0, 1, fade)[:, None]
            part[-fade:] *= np.linspace(1, 0, fade)[:, None]
            end = position + len(part) / RATE
            entry = {"text": paragraph, "start": position, "end": end,
                     "source_in": cut_in, "source_out": cut_out,
                     "hold_after": holds[pi], "words": []}
            for match in re.finditer(r"\S+", paragraph):
                a, b = begin + match.start(), begin + match.end() - 1
                word = {"text": match[0],
                        "start": position + timing["character_start_times_seconds"][a] - cut_in,
                        "end": position + timing["character_end_times_seconds"][b] - cut_in}
                entry["words"].append(word)
                words.append(word)
            chapter["paragraphs"].append(entry)
            clips.append((position, part))
            position = end + holds[pi]
        cursor = math.ceil(max(cursor + MINIMUM_WINDOWS[index], position) * 30) / 30
        chapter["end"] = cursor
        chapters.append(chapter)

    length = round(cursor * RATE)
    voice = np.zeros((length, 2), dtype=np.float32)
    for start, signal in clips:
        a = round(start * RATE)
        voice[a:a + len(signal)] += signal
    music = decode(ROOT / "audio/v2/music.mp3")
    crossfade = 2 * RATE
    bed = music.copy()
    while len(bed) < length:
        blend = np.linspace(0, 1, crossfade)[:, None]
        overlap = bed[-crossfade:] * (1 - blend) + music[:crossfade] * blend
        bed = np.concatenate((bed[:-crossfade], overlap, music[crossfade:])).astype(np.float32)
    bed = bed[:length]
    bed *= 10 ** (-25 / 20) / float(np.abs(bed).max())
    time = np.arange(length) / RATE
    last_voice = chapters[-1]["paragraphs"][-1]["end"]
    # The music level is fixed throughout speech. Only intro and outro ramps change it.
    envelope = np.interp(time, [0, .2, .65, last_voice + .3, cursor - 1.2, cursor],
                         [0, 10 ** .5, 1, 1, 10 ** .5, 0])
    bed *= envelope[:, None]
    save_audio(audio_dir / "voiceover.ogg", voice)
    save_audio(audio_dir / "music-bed.ogg", bed)
    mixed = voice + bed
    assert np.max(np.abs(mixed)) < 1, "Mix clips"
    report = {"duration": cursor, "voice_peak_dbfs": float(20 * np.log10(np.abs(voice).max())),
              "music_bed_peak_ceiling_dbfs": -25, "ducking": False,
              "mixed_peak_dbfs": float(20 * np.log10(np.abs(mixed).max())),
              "voice_id": "bYXvTprZQHr4vlg4TPx7", "chapters": chapters}
    if args.performance:
        report['performance'] = args.performance.name
        report['voice_loudness_target_lufs'] = -24
        report['gain_method'] = 'static gain per chapter, capped at -3 dBTP'
    (ROOT / "narration-revision.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    blocks, group = [], []
    for i, word in enumerate(words):
        group.append(word)
        body = " ".join(w["text"] for w in group)
        gap = i == len(words) - 1 or words[i + 1]["start"] - word["end"] > .7
        if len(body) >= 65 or word["text"].endswith((".", "?", "!")) or gap:
            blocks.append(f"{len(blocks) + 1}\n{stamp(group[0]['start'])} --> {stamp(word['end'])}\n"
                          + textwrap.fill(body, 44, break_long_words=False) + "\n")
            group = []
    (ROOT / "captions-revision.srt").write_text("\n".join(blocks), encoding="utf-8")
    metadata = [";FFMETADATA1", "title=Swallowtail — At your service"]
    for chapter in chapters:
        metadata += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={round(chapter['start'] * 1000)}",
                     f"END={round(chapter['end'] * 1000)}", f"title={chapter['title']}"]
    (ROOT / "chapters.ffmetadata").write_text("\n".join(metadata) + "\n", encoding="utf-8")
    print(f"Mixed {len(chapters)} chapters, {cursor:.3f}s; natural tempo; peak {report['mixed_peak_dbfs']:.1f} dBFS")
    for chapter in chapters:
        print(f"{chapter['start']:7.2f}–{chapter['end']:7.2f} {chapter['title']}")


if __name__ == "__main__":
    main()
