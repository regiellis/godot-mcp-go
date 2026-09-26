"""Mix the generated score and eight narrated cues into the 143 second film bed."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / "trailers/audio"
OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)
items = json.loads((ROOT / "trailers/narration-sources.json").read_text())
command = ["ffmpeg", "-y", "-v", "error", "-i", str(AUDIO / "music.mp3")]
for i in range(len(items)):
    command += ["-i", str(AUDIO / ("voice_%02d.mp3" % i))]
filters = ["[0:a]loudnorm=I=-25:TP=-3:LRA=9,afade=t=in:d=1,afade=t=out:st=139:d=4[music]"]
for i, item in enumerate(items):
    delay = round(item["start"] * 1000)
    filters.append(f"[{i+1}:a]atempo=0.9,loudnorm=I=-17:TP=-2:LRA=7,adelay={delay}|{delay}[v{i}]")
inputs = "[music]" + "".join(f"[v{i}]" for i in range(len(items)))
filters.append(inputs + "amix=inputs=9:normalize=0,alimiter=limit=0.89,apad,atrim=duration=143[out]")
command += ["-filter_complex", ";".join(filters), "-map", "[out]", "-ar", "48000",
            "-ac", "2", str(OUT / "soundtrack.wav")]
subprocess.run(command, check=True)
print("Mixed: " + str(OUT / "soundtrack.wav"))
