"""Fixed-level voice/music mix. No sidechain, compressor, or automatic ducking."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
AUDIO = ROOT / "trailers/audio/v2"
CUES = json.loads((ROOT / "trailers/narration-v2.json").read_text(encoding="utf-8"))
SPEED = {0: 1.03, 1: 1.10, 2: 1.10, 3: 1.13, 7: 1.03}


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def peak(path):
    result = run(["ffmpeg", "-hide_banner", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"])
    return float(re.search(r"max_volume: ([-\d.]+) dB", result.stderr)[1])


def duration(path):
    return float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                      "-of", "default=nw=1:nk=1", str(path)]).stdout)


# Crossfade repeated phrases into a continuous bed; all gains are fixed by time.
music = AUDIO / "music.mp3"
length = duration(music)
command = ["ffmpeg", "-y", "-v", "error"]
for _ in range(5):
    command += ["-i", str(music)]
filters = ["[0:a][1:a]acrossfade=d=2:c1=tri:c2=tri[m1]"]
for index in range(2, 5):
    filters.append(f"[m{index-1}][{index}:a]acrossfade=d=2:c1=tri:c2=tri[m{index}]")
command += ["-filter_complex", ";".join(filters), "-map", "[m4]", "-t", "300", "-ar", "48000",
            str(OUT / "music-continuous.wav")]
run(command)
music_peak = peak(OUT / "music-continuous.wav")
# -25 dBFS bed; -15 dBFS intro/outro. Smooth manually timed transitions only.
envelope = "if(lt(t,0.2),3.1623,if(lt(t,0.6),3.1623-(t-0.2)/0.4*2.1623,if(lt(t,295.6),1,if(lt(t,297.2),1+(t-295.6)/1.6*2.1623,3.1623))))"
run(["ffmpeg", "-y", "-v", "error", "-i", str(OUT / "music-continuous.wav"),
     "-af", f"volume={-25-music_peak}dB,volume='{envelope}':eval=frame,afade=t=in:d=0.5,afade=t=out:st=299:d=1",
     str(OUT / "music-bed.wav")])
command = ["ffmpeg", "-y", "-v", "error"]
report = {"voice_target_peak_dbfs": -8, "music_bed_peak_ceiling_dbfs": -25,
          "music_intro_outro_peak_ceiling_dbfs": -15, "ducking": False, "cues": []}
for i, cue in enumerate(CUES):
    source = AUDIO / f"voice_{i:02}.mp3"
    tempo = SPEED.get(i, 1.0)
    intermediate = OUT / f"voice-paced-{i:02}.wav"
    run(["ffmpeg", "-y", "-v", "error", "-i", str(source), "-af", f"atempo={tempo}", "-ac", "2", str(intermediate)])
    measured = peak(intermediate)
    target = OUT / f"voice-levelled-{i:02}.wav"
    run(["ffmpeg", "-y", "-v", "error", "-i", str(intermediate), "-af", f"volume={-8-measured}dB", str(target)])
    report["cues"].append({"index": i, "start": cue["start"], "duration": duration(target),
                           "tempo": tempo, "peak_dbfs": peak(target)})
    command += ["-i", str(target)]
filters = []
for i, cue in enumerate(CUES):
    delay = round(cue["start"] * 1000)
    filters.append(f"[{i}:a]adelay={delay}|{delay}[v{i}]")
inputs = "".join(f"[v{i}]" for i in range(len(CUES)))
filters.append(inputs + f"amix=inputs={len(CUES)}:normalize=0,apad,atrim=duration=300[voice]")
run(command + ["-filter_complex", ";".join(filters), "-map", "[voice]", "-ar", "48000", "-ac", "2",
               str(OUT / "voiceover.wav")])
run(["ffmpeg", "-y", "-v", "error", "-i", str(OUT / "voiceover.wav"),
     "-i", str(OUT / "music-bed.wav"), "-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0",
     "-t", "300", "-ar", "48000", "-ac", "2", str(OUT / "soundtrack-v2.wav")])
report["mixed_peak_dbfs"] = peak(OUT / "soundtrack-v2.wav")
(OUT / "mix-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(json.dumps(report, indent=2))

# Publish the stems referenced by the editable Godot timeline.
for stem in ("voiceover", "music-bed"):
    run(["ffmpeg", "-y", "-v", "error", "-i", str(OUT / f"{stem}.wav"),
         "-c:a", "libvorbis", "-q:a", "6", str(AUDIO / f"{stem}.ogg")])
