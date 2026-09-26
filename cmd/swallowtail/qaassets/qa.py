"""Swallowtail QA v1: durable local runs, explicit coverage, comparable evidence."""
import argparse
import csv
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ERRORS = re.compile(r"(?mi)^.*(?:SCRIPT ERROR:|ERROR:|Parse Error|WARNING:.*(?:leaked|still in use)).*$")


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, data):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temp.replace(path)


def local_path(root, value):
    path = (Path(root) / value).resolve()
    if not path.is_relative_to(Path(root).resolve()):
        raise ValueError("artifact path escapes the run: " + value)
    return path


def verify_artifacts(root, run):
    for name, receipt in run.get("artifacts", {}).items():
        path = local_path(root, name)
        if not path.is_file() or digest(path) != receipt["sha256"]:
            raise ValueError("evidence file missing or changed: " + name)


def metric(values):
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("frame samples must be nonempty, finite and nonnegative")
    values = sorted(values)
    return {"samples": len(values), "median_ms": statistics.median(values),
            "p99_ms": values[math.ceil(len(values) * .99) - 1], "max_ms": values[-1],
            "over_33_333_ms": sum(v > 1000 / 30 for v in values),
            "over_100_ms": sum(v > 100 for v in values)}


def frames(path, presentmon=False):
    groups = {}
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        required = {"MsBetweenPresents"} if presentmon else {"frame_ms", "phase"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError("unsupported frame CSV columns")
        for row in reader:
            key = "present/all" if presentmon else "process_frame/" + row["phase"]
            value = float(row["MsBetweenPresents" if presentmon else "frame_ms"])
            groups.setdefault(key, []).append(value)
    if not groups:
        raise ValueError("frame capture has no samples")
    return {key: metric(values) for key, values in groups.items()}


def executable(value, project):
    path = (project / value).resolve()
    found = str(path) if path.is_file() else shutil.which(value)
    if not found:
        raise ValueError("executable not found: " + value)
    # No shell interpretation, including Windows .cmd wrappers.
    if Path(found).suffix.lower() in (".cmd", ".bat"):
        raise ValueError("use the actual executable, not a .cmd/.bat wrapper: " + value)
    return found


def validate(config):
    allowed = {"schema", "name", "kind", "executable", "args", "scenario", "timeout_seconds",
               "commands", "manual_checks", "budgets", "environment", "boot_pattern"}
    if config.get("schema") != 1 or set(config) - allowed:
        raise ValueError("expected QA schema 1 with documented fields")
    if config.get("kind") not in ("source", "package"):
        raise ValueError("kind must be source or package")
    for key in ("name", "executable"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError(key + " must be a nonempty string")
    timeout = config.get("timeout_seconds", 120)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 1 <= timeout <= 3600:
        raise ValueError("timeout_seconds must be between 1 and 3600")
    args = config.get("args", [])
    if not isinstance(args, list) or any(not isinstance(a, str) for a in args):
        raise ValueError("args must be an array of strings")
    if any(a.split("=")[0] in ("--path", "--script", "-s", "--log-file", "--") for a in args):
        raise ValueError("QA owns --path, --script, --log-file, and user arguments")
    if config["kind"] == "source" and not isinstance(config.get("scenario"), str):
        raise ValueError("source runs require a GDScript scenario")
    if config["kind"] == "package" and config.get("scenario"):
        raise ValueError("package runs do not inject scripts; use a source scenario separately")
    names = config.get("manual_checks", [])
    if not isinstance(names, list) or any(not isinstance(n, str) or not n for n in names) or len(set(names)) != len(names):
        raise ValueError("manual_checks must contain unique nonempty names")
    for cmd in config.get("commands", []):
        if set(cmd) - {"name", "argv", "pass_pattern", "timeout_seconds"} or not cmd.get("name"):
            raise ValueError("invalid command check")
        if not isinstance(cmd.get("argv"), list) or not cmd["argv"] or any(not isinstance(a, str) for a in cmd["argv"]):
            raise ValueError("command argv must be a nonempty string array")
        if not 1 <= cmd.get("timeout_seconds", 120) <= 3600:
            raise ValueError("invalid command timeout")
        re.compile(cmd.get("pass_pattern", "."))
    for phase, limits in config.get("budgets", {}).items():
        for key, limit in limits.items():
            if key not in ("median_ms", "p99_ms", "max_ms", "over_33_333_ms", "over_100_ms") or not isinstance(limit, (int, float)) or not math.isfinite(limit) or limit < 0:
                raise ValueError("invalid frame budget: " + phase + "/" + key)
    re.compile(config.get("boot_pattern", "Godot Engine"))


def finish(run):
    statuses = [c["status"] for c in run["checks"]]
    run["status"] = "fail" if "fail" in statuses else "incomplete" if "pending" in statuses or not statuses else "pass"
    return run


def add_check(run, name, passed, detail=""):
    run["checks"].append({"name": name, "status": "pass" if passed else "fail", "detail": detail})


def command(argv, cwd, env, log, timeout):
    timed_out = False
    with Path(log).open("wb") as stream:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()
            proc.wait()
    return proc.returncode, timed_out


def git_info(project):
    def git(*args):
        p = subprocess.run(["git", "-C", str(project), *args], capture_output=True, text=True, timeout=10)
        return p.stdout.strip() if p.returncode == 0 else None
    try:
        return {"commit": git("rev-parse", "HEAD"), "status": git("status", "--porcelain")}
    except (OSError, subprocess.TimeoutExpired):
        return {"commit": None, "status": "unavailable"}


def run_capture(args):
    project = Path(args.project).resolve()
    config_path = (project / args.config).resolve()
    config = read_json(config_path)
    validate(config)
    exe = executable(config["executable"], project)
    presentmon = executable(args.presentmon, project) if args.presentmon else None
    scenario = (project / config.get("scenario", "")).resolve()
    if config["kind"] == "source" and (not scenario.is_file() or not (project / "project.godot").is_file()):
        raise ValueError("source run requires an existing scenario and project.godot")
    out = (project / (args.out or (".godot/swallowtail-qa/runs/" + datetime.now().strftime("%Y%m%d-%H%M%S-%f")))).resolve()
    out.mkdir(parents=True, exist_ok=False)
    write_json(out / "config.json", config)
    run = {"schema": 1, "name": config["name"], "started": now(), "kind": config["kind"],
           "scope": "instrumented source scenario" if config["kind"] == "source" else "packaged launch; manual checks require operator evidence",
           "project": str(project), "git": git_info(project), "checks": [], "metrics": {},
           "screenshots": [], "artifacts": {}, "notes": [], "warnings": [],
           "limitations": ["One machine/run is not a supported-hardware matrix.",
                           "Process-frame timing is not displayed-frame timing. Screenshots are separate phases."]}
    env = os.environ.copy()
    # Godot user:// defaults and common game save locations are isolated. Games
    # writing absolute/custom cloud locations must supply their own test adapter.
    for key, folder in (("APPDATA", "appdata"), ("LOCALAPPDATA", "localappdata"),
                        ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config")):
        (out / "saves" / folder).mkdir(parents=True, exist_ok=True)
        env[key] = str(out / "saves" / folder)
    run["limitations"].append("Save isolation covers Windows APPDATA/LOCALAPPDATA and Linux XDG paths; macOS, custom absolute paths and cloud saves need a game adapter.")
    run["target"] = {"executable": exe, "sha256": digest(exe)}
    pck = Path(exe).with_suffix(".pck")
    if config["kind"] == "package" and pck.is_file():
        run["target"]["pck_sha256"] = digest(pck)
    run["comparison_context"] = {"host": platform.node(), "os": platform.platform(),
        "machine": platform.machine(), "environment": config.get("environment", "unspecified"),
        "kind": config["kind"], "executable_sha256": digest(exe), "args": config.get("args", []),
        "scenario_sha256": digest(scenario) if config["kind"] == "source" else None,
        "runner_sha256": digest(HERE / "runner.gd") if config["kind"] == "source" else None,
        "presentmon_sha256": digest(presentmon) if presentmon else None,
        "capture": "presentmon" if args.presentmon else "process_frame" if config["kind"] == "source" else "none"}
    try:
        for index, cmd in enumerate(config.get("commands", [])):
            argv = [executable(cmd["argv"][0], project), *cmd["argv"][1:]]
            log = out / ("command-%02d.log" % index)
            code, timeout = command(argv, project, env, log, cmd.get("timeout_seconds", 120))
            raw = log.read_text(encoding="utf-8", errors="replace")
            passed = code == 0 and not timeout and not ERRORS.search(raw) and re.search(cmd.get("pass_pattern", "."), raw) is not None
            add_check(run, cmd["name"], passed, f"exit={code}; timeout={timeout}; full log={log.name}")
        argv = [exe, *config.get("args", []), "--log-file", str(out / "engine.log")]
        if config["kind"] == "source":
            shutil.copyfile(HERE / "runner.gd", out / "runner.gd")
            shutil.copyfile(scenario, out / "scenario.gd")
            # Keep original script location for relative dependencies; archived copy
            # and digest record the exact code that ran.
            argv += ["--path", str(project), "--script", str(out / "runner.gd"), "--", str(out), str(scenario)]
        run["argv"] = argv
        write_json(out / "run.json", {**run, "status": "running"})
        capture = None
        with (out / "console.log").open("wb") as log, (out / "presentmon.log").open("wb") as pm_log:
            game = subprocess.Popen(argv, cwd=project if config["kind"] == "source" else Path(exe).parent,
                                    env=env, stdout=log, stderr=subprocess.STDOUT)
            print(json.dumps({"run": str(out), "pid": game.pid}), flush=True)
            timeout = False
            try:
                if args.presentmon:
                    capture = subprocess.Popen([presentmon, "--process_id", str(game.pid), "--output_file", str(out / "presentmon.csv"),
                        "--timed", str(math.ceil(config.get("timeout_seconds", 120))), "--terminate_after_timed",
                        "--session_name", "SwallowtailQA-" + str(game.pid), "--no_console_stats", "--qpc_time_ms"],
                        stdout=pm_log, stderr=subprocess.STDOUT)
                try:
                    game.wait(timeout=config.get("timeout_seconds", 120))
                except subprocess.TimeoutExpired:
                    timeout = True
                    game.kill()
                    game.wait()
            finally:
                if game.poll() is None:
                    game.kill()
                    game.wait()
                if capture:
                    try:
                        capture.wait(timeout=config.get("timeout_seconds", 120) + 15)
                    except subprocess.TimeoutExpired:
                        capture.kill()
                        capture.wait()
            add_check(run, "process exit", game.returncode == 0 and not timeout, f"exit={game.returncode}; timeout={timeout}")
        raw = (out / "console.log").read_text(encoding="utf-8", errors="replace")
        if (out / "engine.log").exists():
            raw += "\n" + (out / "engine.log").read_text(encoding="utf-8", errors="replace")
        diagnostics = sorted(set(ERRORS.findall(raw)))
        run["warnings"] = sorted(set(re.findall(r"(?m)^.*WARNING:.*$", raw)))
        add_check(run, "complete engine log", not diagnostics, "\n".join(diagnostics) or "no engine errors or shutdown leaks")
        add_check(run, "boot receipt", re.search(config.get("boot_pattern", "Godot Engine"), raw) is not None)
        run["comparison_context"]["render_log"] = sorted(set(re.findall(r"(?m)^.*(?:Vulkan|OpenGL|D3D12).*Using Device.*$", raw)))
        if config["kind"] == "source":
            receipt = read_json(out / "scenario.json") if (out / "scenario.json").exists() else {}
            add_check(run, "scenario completion", receipt.get("schema") == 1 and receipt.get("complete") is True and bool(receipt.get("checks")))
            for check in receipt.get("checks", []):
                if check.get("status") not in ("pass", "fail", "skip") or not check.get("name"):
                    raise ValueError("invalid scenario assertion")
                run["checks"].append(check)
            for shot in receipt.get("screenshots", []):
                local_path(out, shot["path"])
                run["screenshots"].append(shot)
            run["comparison_context"]["runtime"] = {key: receipt.get(key) for key in ("engine", "renderer", "device", "viewport")}
            run["metrics"].update(frames(out / "frames.csv"))
        if args.presentmon:
            add_check(run, "PresentMon exit", capture is not None and capture.returncode == 0)
            run["metrics"].update(frames(out / "presentmon.csv", True))
        for phase, limits in config.get("budgets", {}).items():
            for key, limit in limits.items():
                actual = run["metrics"].get(phase, {}).get(key)
                add_check(run, phase + "/" + key + " budget", actual is not None and actual <= limit,
                          f"actual={actual}; maximum={limit}")
    except KeyboardInterrupt:
        add_check(run, "QA runner", False, "interrupted by operator")
    except Exception as error:
        add_check(run, "QA runner", False, str(error))
    for name in config.get("manual_checks", []):
        run["checks"].append({"name": name, "status": "pending", "manual": True, "detail": "operator evidence required"})
    run["finished"] = now()
    for path in out.iterdir():
        if path.is_file() and path.name != "run.json":
            run["artifacts"][path.name] = {"sha256": digest(path), "bytes": path.stat().st_size}
    finish(run)
    write_json(out / "run.json", run)
    print(json.dumps({"status": run["status"], "report": str(out / "run.json")}), flush=True)
    if args.pdf:
        report(out, out / "report.pdf")
    return 0 if run["status"] == "pass" else 1


def compare(current_dir, baseline_dir, percent):
    current, baseline = read_json(current_dir / "run.json"), read_json(baseline_dir / "run.json")
    verify_artifacts(current_dir, current)
    verify_artifacts(baseline_dir, baseline)
    def context(run):
        result = dict(run["comparison_context"])
        # Early schema-1 runs retained the runner hash in their artifact manifest.
        # Derive it from that verified evidence rather than weakening comparison.
        result.setdefault("runner_sha256", run.get("artifacts", {}).get("runner.gd", {}).get("sha256"))
        result.setdefault("presentmon_sha256", None)
        return result
    current_context, baseline_context = context(current), context(baseline)
    mismatch = [key for key in set(current_context) | set(baseline_context)
                if current_context.get(key) != baseline_context.get(key)]
    result = {"schema": 1, "current": str(current_dir), "baseline": str(baseline_dir),
              "tolerance_percent": percent, "mismatch": mismatch, "deltas": [], "status": "incompatible"}
    if not mismatch:
        result["status"] = "pass"
        keys = set(current["metrics"]) | set(baseline["metrics"])
        if not keys:
            result["status"] = "incomplete"
        for phase in sorted(keys):
            old, new = baseline["metrics"].get(phase), current["metrics"].get(phase)
            if not old or not new:
                result["deltas"].append({"phase": phase, "status": "missing"})
                result["status"] = "incomplete"
                continue
            for key in ("median_ms", "p99_ms", "max_ms"):
                regressed = new[key] > old[key] * (1 + percent / 100)
                result["deltas"].append({"phase": phase, "metric": key, "before": old[key], "after": new[key], "regressed": regressed})
                if regressed:
                    result["status"] = "regression"
        if current["status"] != "pass" or baseline["status"] != "pass":
            result["status"] = "incomplete"
    write_json(current_dir / "comparison.json", result)
    return result


def assessment_for(run, path=None):
    """Editorial conclusions never replace check receipts or imply owner approval."""
    if path is None:
        status = finish({"checks": run["checks"]})["status"]
        return {"schema": 1, "prepared_by": "Swallowtail automatic scope summary",
                "tests": [{"name": c["name"],
                           "conclusion": c["status"].upper() + ": " + c.get("detail", "Recorded check result."),
                           "fix_status": "No fix is established by this check alone.",
                           "next_action": "Retain this regression check; no failure found in its recorded scope." if c["status"] == "pass" else "Investigate the recorded failure and rerun." if c["status"] == "fail" else "Complete the missing check and record evidence.",
                           "evidence": "run.json: " + c["name"]} for c in run["checks"]],
                "readiness": {"verdict": "hold" if status != "pass" else "not_assessed",
                              "summary": "This run does not establish release readiness. " + ("Failed or pending checks require closure." if status != "pass" else "Passing checks cover only the recorded scope."),
                              "required": ["Review the exact shipping build against the game's release criteria, remaining coverage and findings."],
                              "follow_up": [], "acceptance": ["Record an evidence-based release assessment and the release owner's decision."]}}
    value = read_json(path)
    def nonempty(text):
        return isinstance(text, str) and bool(text.strip())
    if not isinstance(value, dict) or value.get("schema") != 1 or not nonempty(value.get("prepared_by")):
        raise ValueError("assessment requires schema 1 and prepared_by")
    tests = value.get("tests")
    if not isinstance(tests, list) or not tests or any(not isinstance(t, dict) or any(not nonempty(t.get(k)) for k in ("name", "conclusion", "fix_status", "next_action", "evidence")) for t in tests):
        raise ValueError("assessment tests require name, conclusion, fix_status, next_action and evidence")
    readiness = value.get("readiness")
    if not isinstance(readiness, dict) or readiness.get("verdict") not in ("hold", "conditional", "ready", "not_assessed") or not nonempty(readiness.get("summary")):
        raise ValueError("assessment requires an explicit readiness verdict and summary")
    for key in ("required", "follow_up", "acceptance"):
        if not isinstance(readiness.get(key), list) or any(not nonempty(t) for t in readiness[key]):
            raise ValueError("assessment readiness requires string lists: " + key)
    if readiness["verdict"] == "ready" and (finish({"checks": run["checks"]})["status"] != "pass" or run.get("kind") != "package" or readiness["required"]):
        raise ValueError("ready requires a passing package run and no required work; source checks cannot sign off a release")
    return value


def report(run_dir, output, assessment_path=None):
    try:
        from reportlab.lib import colors
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.utils import ImageReader
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, KeepTogether
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
    except ImportError as error:
        raise ValueError("PDF rendering needs ReportLab: install with your Python's -m pip install 'reportlab>=4,<5'") from error
    run = read_json(run_dir / "run.json")
    verify_artifacts(run_dir, run)
    assessment = assessment_for(run, assessment_path)
    pdfmetrics.registerFont(TTFont("QABody", str(HERE / "Inter-Regular.ttf")))
    pdfmetrics.registerFont(TTFont("QABold", str(HERE / "Inter-SemiBold.ttf")))
    pdfmetrics.registerFontFamily("QABody", normal="QABody", bold="QABold", italic="QABody", boldItalic="QABold")
    styles = getSampleStyleSheet()
    for style in styles.byName.values():
        style.fontName = "QABody"
        style.textColor = colors.HexColor("#211c25")
    styles["Title"].fontName = styles["Heading1"].fontName = styles["Heading2"].fontName = "QABold"
    styles["Title"].alignment = 0
    # Long tables must be allowed to split on the current page, rather than
    # being pulled wholesale to the next page by a heading's keep-with-next.
    styles["Heading1"].keepWithNext = False
    styles["Heading2"].keepWithNext = True
    styles["BodyText"].leading = 14
    styles.add(ParagraphStyle("SmallQA", fontName="QABody", fontSize=8, leading=11, textColor=colors.HexColor("#665b63"), wordWrap="CJK"))
    def para(value, style="BodyText"):
        return Paragraph(html.escape(str(value)).replace("\n", "<br/>"), styles[style])
    story = [para("SWALLOWTAIL / GAME QA", "Heading2"), Spacer(1, 12), para(run["name"], "Title"),
             para(run["status"].upper() + "  |  " + run["scope"], "Heading2"),
             para("Recorded " + run["started"], "SmallQA"), Spacer(1, 12)]
    def table(rows, widths):
        obj = Table([[para(str(cell)[:2000] + (" [continued in raw evidence]" if len(str(cell)) > 2000 else ""), "SmallQA") for cell in row] for row in rows], colWidths=widths, repeatRows=1, hAlign="LEFT")
        obj.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f3e7eb")),
            ("LINEBELOW", (0, 0), (-1, -1), .4, colors.HexColor("#e1d7ce")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"), ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 7)]))
        return obj
    readiness = assessment["readiness"]
    story += [para("Ship-readiness conclusion", "Heading1"),
              para(readiness["verdict"].upper().replace("_", " "), "Heading2"), para(readiness["summary"]),
              para("Assessment: " + assessment["prepared_by"] + ". Advisory assessment; not a release-owner approval or an automated test result.", "SmallQA")]
    for key, heading in (("required", "Required before sign-off"), ("follow_up", "Follow-up and accepted-risk candidates"), ("acceptance", "Evidence needed to close")):
        if readiness[key]:
            story += [para(heading, "Heading2")]
            for item in readiness[key]:
                story += [para(item), Spacer(1, 7)]
    story += [Spacer(1, 12), para("Coverage and checks", "Heading1"), table([["Check", "Result", "Evidence"]] +
        [[c["name"], c["status"].upper() + (" / manual" if c.get("manual") else ""), c.get("detail", "")] for c in run["checks"]], [180, 72, 255])]
    if run["metrics"]:
        story += [Spacer(1, 12), KeepTogether([para("Frame timing", "Heading1"), para("Nearest-rank p99; all samples retained. Process-frame intervals measure the test loop. PresentMon intervals measure submitted presents, not guaranteed display delivery.", "SmallQA")]), Spacer(1, 8),
                  table([["Phase / source", "Frames", "Median ms", "p99 ms", "Peak ms", ">33.33 ms"]] +
                        [[k, v["samples"], f'{v["median_ms"]:.2f}', f'{v["p99_ms"]:.2f}', f'{v["max_ms"]:.2f}', v["over_33_333_ms"]] for k, v in run["metrics"].items()], [167, 50, 75, 65, 70, 80])]
    story += [Spacer(1, 12), para("Test conclusions and remaining work", "Heading1")]
    for item in assessment["tests"]:
        block = [para(item["name"], "Heading2")]
        for key, label in (("conclusion", "Conclusion"), ("fix_status", "Fix status"), ("next_action", "Next action"), ("evidence", "Evidence")):
            block += [para(label + ": " + item[key], "SmallQA" if key == "evidence" else "BodyText"), Spacer(1, 5)]
        story.append(KeepTogether(block))
    comparison = run_dir / "comparison.json"
    if comparison.exists():
        comp = read_json(comparison)
        story += [para("Baseline comparison", "Heading1"), para(comp["status"].upper() + ": " + (", ".join(comp["mismatch"]) or f'{comp["tolerance_percent"]}% tolerance'))]
        if comp["deltas"]:
            story.append(table([["Phase", "Metric", "Before", "After"]] + [[d["phase"], d.get("metric", d.get("status")), d.get("before", "-"), d.get("after", "-")] for d in comp["deltas"]], [197, 110, 100, 100]))
    for shot in run.get("screenshots", []):
        path = local_path(run_dir, shot["path"])
        width, height = ImageReader(str(path)).getSize()
        scale = min(507 / width, 430 / height)
        story.append(KeepTogether([Spacer(1, 14), Image(str(path), width * scale, height * scale), para(shot.get("caption", path.name), "SmallQA")]))
    story += [para("Limitations and observations", "Heading1")]
    for note in run["limitations"] + run["warnings"] + [n["text"] for n in run["notes"]]:
        story += [para(note), Spacer(1, 7)]
    story += [KeepTogether([para("Provenance", "Heading1"), para("Source commit: " + str(run["git"]["commit"]), "SmallQA")]),
              para("Working tree: " + (run["git"]["status"] or "clean"), "SmallQA"), para(json.dumps(run["target"], indent=2), "SmallQA"),
              para(json.dumps(run["comparison_context"], indent=2), "SmallQA"), Spacer(1, 12), para("Evidence files (SHA-256)", "Heading2")]
    for name, receipt in run["artifacts"].items():
        story += [para(name + "  " + receipt["sha256"], "SmallQA"), Spacer(1, 4)]
    if assessment_path:
        story += [para("Editorial assessment: " + str(assessment_path) + "  SHA-256 " + digest(assessment_path), "SmallQA")]
    output.parent.mkdir(parents=True, exist_ok=True)
    def page(canvas, doc):
        canvas.saveState()
        canvas.setFillColor(colors.HexColor("#faf6ef")); canvas.rect(0, 0, 595.276, 841.89, fill=1, stroke=0)
        canvas.setFillColor(colors.HexColor("#81485f")); canvas.rect(0, 829.89, 595.276, 12, fill=1, stroke=0)
        canvas.drawImage(str(HERE / "mascot.png"), 503, 760, 45, 57, preserveAspectRatio=True, anchor="c", mask="auto")
        canvas.setFont("QABody", 8); canvas.setFillColor(colors.HexColor("#665b63"))
        canvas.drawString(44, 27, "Swallowtail / evidence-led game testing")
        canvas.drawRightString(551, 27, str(doc.page)); canvas.restoreState()
    SimpleDocTemplate(str(output), pagesize=(595.276, 841.89), leftMargin=44, rightMargin=44, topMargin=86, bottomMargin=48,
                      title=run["name"] + " - Swallowtail QA", author="Swallowtail").build(story, onFirstPage=page, onLaterPages=page)
    print(json.dumps({"pdf": str(output)}))


def main(argv=None):
    # The global CLI may put --project before the nested command.
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--project" and len(argv) >= 3:
        argv = [argv[2], *argv[:2], *argv[3:]]
    if argv == ["help"] or not argv:
        argv = ["--help"]
    parser = argparse.ArgumentParser(description="Swallowtail local game QA (Python 3.10+; ReportLab for PDFs)")
    subs = parser.add_subparsers(dest="action", required=True)
    for name in ("init", "run", "compare", "report", "attest"):
        sub = subs.add_parser(name)
        sub.add_argument("--project", default=".")
        if name in ("init", "run"):
            sub.add_argument("--config", default="qa/config.json")
        if name == "run":
            sub.add_argument("--out"); sub.add_argument("--presentmon"); sub.add_argument("--pdf", action="store_true")
        if name in ("compare", "report", "attest"):
            sub.add_argument("--run", required=True)
        if name == "compare":
            sub.add_argument("--baseline", required=True); sub.add_argument("--tolerance-percent", type=float, default=10)
        if name == "report":
            sub.add_argument("--out"); sub.add_argument("--assessment", help="schema-1 editorial conclusions and ship-readiness JSON")
        if name == "attest":
            sub.add_argument("--check", required=True); sub.add_argument("--status", choices=["pass", "fail"], required=True); sub.add_argument("--detail", required=True)
    args = parser.parse_args(argv)
    project = Path(args.project).resolve()
    if args.action == "init":
        config_path = (project / args.config).resolve()
        scenario_path = config_path.parent / "smoke.gd"
        if config_path.exists() or scenario_path.exists():
            raise ValueError("QA configuration/scenario already exists; nothing overwritten")
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config = {"schema": 1, "name": project.name, "kind": "source", "executable": "godot",
                  "args": ["--windowed", "--resolution", "1280x720"], "scenario": str(scenario_path.relative_to(project)),
                  "timeout_seconds": 60, "environment": "Record GPU, display refresh, power mode and renderer here",
                  "commands": [], "manual_checks": ["Visual and audio review"], "budgets": {}}
        write_json(config_path, config)
        shutil.copyfile(HERE / "example.gd", scenario_path)
        print(str(config_path)); return 0
    if args.action == "run":
        return run_capture(args)
    run_dir = (project / args.run).resolve()
    if args.action == "report":
        report(run_dir, (project / args.out).resolve() if args.out else run_dir / "report.pdf",
               (project / args.assessment).resolve() if args.assessment else None); return 0
    if args.action == "compare":
        if not math.isfinite(args.tolerance_percent) or args.tolerance_percent < 0:
            raise ValueError("tolerance must be finite and nonnegative")
        result = compare(run_dir, (project / args.baseline).resolve(), args.tolerance_percent)
        print(json.dumps(result, indent=2)); return 0 if result["status"] == "pass" else 1
    run = read_json(run_dir / "run.json")
    matches = [check for check in run["checks"] if check.get("manual") and check["name"] == args.check]
    if len(matches) != 1 or not args.detail.strip():
        raise ValueError("attest requires a named manual check and substantive operator evidence")
    previous = dict(matches[0])
    matches[0].update(status=args.status, detail=args.detail)
    run["notes"].append({"at": now(), "text": f"Operator attestation: {args.check}: {args.status}: {args.detail}", "previous": previous})
    finish(run); write_json(run_dir / "run.json", run)
    print(run["status"]); return 0 if run["status"] == "pass" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print("QA error: " + str(error), file=sys.stderr)
        sys.exit(2)
