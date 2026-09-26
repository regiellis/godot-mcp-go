"""Render the editable Godot film losslessly, then encode its recorded soundtrack.

Each run retains its own PNG frames and WAV for inspection/re-encoding.
Example: python trailers/render.py --godot /path/to/godot --seconds 5 --start 98
"""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--godot", default="godot")
parser.add_argument("--seconds", type=float, help="Render a short review cut")
parser.add_argument("--start", type=float, default=0, help="Review cut start in film seconds")
parser.add_argument("--output", help="MP4 filename under out/")
parser.add_argument("--encode-only", type=Path, help="Reuse a previous render directory")
args = parser.parse_args()
out = root / "out"
out.mkdir(exist_ok=True)
(out / ".gdignore").touch()
film = (root / "trailers/timeline/film_library.tres").read_text()
duration = float(re.search(r"^length = ([\d.]+)", film, re.M)[1])
if not 0 <= args.start < duration or (args.seconds is not None and args.seconds <= 0):
    parser.error("Review range must be inside the film and have positive duration")
project = (root / "project.godot").read_text()
for key, value in [("viewport_width", 1920), ("viewport_height", 1080)]:
    if not re.search(rf"window/size/{key}={value}\s", project):
        parser.error("The project viewport must be 1920x1080; --resolution alone is insufficient")
is_preview = args.seconds is not None or args.start != 0
output_name = args.output or ("at-your-service-review.mp4" if is_preview else "at-your-service-revised.mp4")
if Path(output_name).name != output_name or not output_name.endswith(".mp4"):
    parser.error("--output must be an MP4 filename, without a directory")
render_dir = args.encode_only or out / ("render-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
render_dir = render_dir.resolve()
if not args.encode_only:
    render_dir.mkdir()
    command = [args.godot, "--path", str(root), "res://trailers/film.tscn",
               "--resolution", "1920x1080", "--rendering-method", "forward_plus",
               "--write-movie", str(render_dir / "frame.png"), "--fixed-fps", "30",
               "--disable-vsync"]
    if args.seconds is not None:
        command += ["--quit-after", str(math.ceil(min(args.seconds, duration - args.start) * 30))]
    command += ["--", f"--start={args.start}"]
    print(f"Rendering to {render_dir}", flush=True)
    with (render_dir / "godot.log").open("w", encoding="utf-8") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    log_text = (render_dir / "godot.log").read_text()
    # Some development builds report resources still held during movie-writer
    # shutdown. Only tolerate that exact cleanup message after recording completed;
    # retain it in both the engine log and delivery metadata.
    errors = [line for line in log_text.splitlines() if "ERROR:" in line]
    fatal_errors = [line for line in errors if not ("Done recording movie at path:" in log_text and
                    re.fullmatch(r"ERROR: \d+ resources still in use at exit .*", line))]
    if fatal_errors:
        raise RuntimeError(f"Godot reported errors; inspect {render_dir / 'godot.log'}")
frames = sorted(render_dir.glob("frame*.png"))
if not frames:
    raise RuntimeError(f"No frames in {render_dir}")
expected_frames = round(min(args.seconds or duration, duration - args.start) * 30)
if len(frames) < expected_frames:
    raise RuntimeError(f"Incomplete render: {len(frames)} frames, expected {expected_frames}")
# Animation completion may record one extra frame at the end key. Deliver the
# requested half-open interval [start, end), with matching audio duration.
frame_count = expected_frames
match = re.fullmatch(r"frame(\d+)\.png", frames[0].name)
if not match:
    raise RuntimeError(f"Unexpected frame name: {frames[0].name}")
pattern = render_dir / f"frame%0{len(match[1])}d.png"
command = ["ffmpeg", "-y", "-hide_banner", "-framerate", "30", "-start_number", match[1],
           "-i", str(pattern), "-i", str(render_dir / "frame.wav")]
if not is_preview:
    command += ["-i", str(root / "trailers/chapters.ffmetadata"),
                "-i", str(root / "trailers/captions-revision.srt")]
command += ["-map", "0:v:0", "-map", "1:a:0"]
if not is_preview:
    command += ["-map", "3:s:0", "-map_metadata", "2", "-map_chapters", "2",
                "-c:s", "mov_text", "-metadata:s:s:0", "language=eng",
                "-metadata:s:s:0", "title=English"]
command += ["-frames:v", str(frame_count), "-t", str(frame_count / 30),
            "-c:v", "libx264", "-preset", "slow",
            "-crf", "16", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k",
            "-movflags", "+faststart", str(out / output_name)]
print(f"Encoding {frame_count} lossless frames to {output_name}", flush=True)
with (render_dir / "encode.log").open("w", encoding="utf-8") as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                        "-show_chapters", "-of", "json", str(out / output_name)],
                       capture_output=True, text=True, check=True)
report = json.loads(probe.stdout)
video = next(s for s in report["streams"] if s["codec_type"] == "video")
assert (video["width"], video["height"], video["r_frame_rate"]) == (1920, 1080, "30/1")
report["render_directory"] = str(render_dir)
report["source_frames"] = len(frames)
report["delivered_frames"] = frame_count
engine_log = render_dir / "godot.log"
report["engine_shutdown_diagnostics"] = [line for line in engine_log.read_text().splitlines()
    if "resources still in use at exit" in line or "ObjectDB instances were leaked" in line] if engine_log.exists() else []
(out / (Path(output_name).stem + ".json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
if not is_preview:
    (out / (Path(output_name).stem + ".srt")).write_bytes(
        (root / "trailers/captions-revision.srt").read_bytes())
print(out / output_name, flush=True)
