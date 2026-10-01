"""Non-engine QA receipt/process contracts, invoked by qa_test.go."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "cmd/swallowtail/qaassets/qa.py"
spec = importlib.util.spec_from_file_location("qa", WORKER)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7xkAAAAASUVORK5CYII=")
CSV = b"time_us,frame_ms,phase\n1000,1,boot\n3000,2,boot\n"


def receipt(complete=True):
    return {"schema": 2, "complete": complete, "checkpoint": 3,
            "checks": [{"name": name, "status": "pass"} for name in ("booted", "input", "captured")],
            "screenshots": [{"path": "screenshot-00.png", "caption": "Before interruption",
                             "sha256": hashlib.sha256(PNG).hexdigest()}],
            "frames": {"path": "frames.csv", "samples": 2, "bytes": len(CSV),
                       "chunks": [{"offset": 0, "bytes": len(CSV), "sha256": hashlib.sha256(CSV).hexdigest()}]},
            "engine": "test double", "renderer": "none", "device": "none", "viewport": "(1, 1)"}


def empty_run():
    return {"checks": [], "screenshots": [], "metrics": {}, "limitations": [],
            "comparison_context": {}, "scope": "instrumented source scenario"}


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        (self.out / "frames.csv").write_bytes(CSV)
        (self.out / "screenshot-00.png").write_bytes(PNG)

    def ingest(self, value, interruption=""):
        qa.write_json(self.out / "scenario.json", value)
        run = empty_run()
        qa.source_evidence(run, self.out, interruption)
        return qa.finish(run)

    def test_complete_and_legacy_receipts(self):
        for schema in (1, 2):
            with self.subTest(schema=schema):
                value = receipt()
                value["schema"] = schema
                run = self.ingest(value)
                self.assertEqual(run["status"], "pass")
                self.assertEqual(run["metrics"]["process_frame/boot"]["samples"], 2)
                self.assertEqual(run["screenshots"][0]["caption"], "Before interruption")

    def test_partial_prefix_excludes_uncommitted_truncated_tail(self):
        (self.out / "frames.csv").write_bytes(CSV + b"5000,invalid uncommitted row")
        run = self.ingest(receipt(False), "process timeout")
        self.assertEqual(run["status"], "fail")
        self.assertEqual(run["scenario"]["coverage"], "checkpointed")
        self.assertGreater(run["scenario"]["uncommitted_frame_bytes"], 0)
        self.assertEqual(run["metrics"]["process_frame/boot"]["max_ms"], 2)
        self.assertEqual(len(run["screenshots"]), 1)
        self.assertEqual(qa.assessment_for(run)["readiness"]["verdict"], "hold")

    def test_multiple_checksum_segments_cover_prefix(self):
        value = receipt()
        split = len(CSV.splitlines(keepends=True)[0])
        value["frames"]["chunks"] = [
            {"offset": offset, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for offset, data in ((0, CSV[:split]), (split, CSV[split:]))]
        self.assertEqual(self.ingest(value)["status"], "pass")

    def test_complete_receipt_without_assertions_fails(self):
        value = receipt()
        value["checks"] = []
        self.assertEqual(self.ingest(value)["status"], "fail")

    def test_startup_checkpoint_with_no_samples(self):
        value = receipt(False)
        data = CSV.splitlines(keepends=True)[0]
        (self.out / "frames.csv").write_bytes(data)
        value.update(checks=[], screenshots=[])
        value["frames"].update(samples=0, bytes=len(data), chunks=[
            {"offset": 0, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}])
        run = self.ingest(value, "process timeout")
        self.assertEqual(run["metrics"], {})
        value["complete"] = True
        with self.assertRaisesRegex(ValueError, "no samples"):
            self.ingest(value)

    def test_missing_receipt_only_expected_during_interruption(self):
        (self.out / "frames.csv").unlink()
        run = empty_run()
        qa.source_evidence(run, self.out, "process timeout")
        self.assertEqual(qa.finish(run)["status"], "fail")
        self.assertEqual(run["scenario"]["coverage"], "missing")
        self.assertEqual(run["metrics"], {})
        with self.assertRaisesRegex(ValueError, "missing after normal exit"):
            qa.source_evidence(empty_run(), self.out, "")

    def test_declared_artifacts_required_even_for_partial_receipt(self):
        for name in ("frames.csv", "screenshot-00.png"):
            with self.subTest(name=name):
                path = self.out / name
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    self.ingest(receipt(False), "process timeout")
                path.write_bytes(original)

    def test_corrupt_manifest_and_assertions_are_rejected(self):
        cases = [
            ("schema", True), ("complete", "false"), ("checks", {}),
            ("checks", [{"name": "forged", "status": "pending"}]),
            ("screenshots", [{"path": "../escape.png", "caption": "escape"}]),
            ("checkpoint", 0), ("frames", {"path": "../frames.csv"}),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                bad = receipt(False)
                bad[key] = value
                with self.assertRaises(ValueError):
                    self.ingest(bad, "process timeout")
        for mutate in (
            lambda f: f.update(samples=3), lambda f: f.update(bytes=len(CSV) + 1),
            lambda f: f.update(samples=True), lambda f: f.update(chunks=[]),
            lambda f: f["chunks"][0].update(offset=1),
            lambda f: f["chunks"][0].update(sha256="0" * 64),
        ):
            bad = receipt(False)
            mutate(bad["frames"])
            with self.assertRaises(ValueError):
                self.ingest(bad, "process timeout")

    def test_tampered_frames_and_captures_fail_checksum(self):
        (self.out / "frames.csv").write_bytes(CSV.replace(b",2,", b",9,"))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.ingest(receipt(False), "process timeout")
        (self.out / "frames.csv").write_bytes(CSV)
        (self.out / "screenshot-00.png").write_bytes(b"corrupt PNG")
        with self.assertRaisesRegex(ValueError, "screenshot checksum mismatch"):
            self.ingest(receipt(False), "process timeout")

    def test_complete_requires_exact_coverage_and_valid_csv(self):
        (self.out / "frames.csv").write_bytes(CSV + b"4000,3,boot\n")
        with self.assertRaisesRegex(ValueError, "byte count mismatch"):
            self.ingest(receipt())
        data = b"time_us,frame_ms,phase\n1000,nan,boot\n"
        (self.out / "frames.csv").write_bytes(data)
        value = receipt(False)
        value["frames"].update(bytes=len(data), samples=1, chunks=[
            {"offset": 0, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}])
        with self.assertRaisesRegex(ValueError, "finite"):
            self.ingest(value, "process timeout")

    def test_corrupt_json_is_not_treated_as_missing(self):
        (self.out / "scenario.json").write_text("{", encoding="utf-8")
        with self.assertRaises(json.JSONDecodeError):
            qa.source_evidence(empty_run(), self.out, "process timeout")

    def test_failed_partial_run_cannot_be_passing_baseline(self):
        partial = self.ingest(receipt(False), "process timeout")
        complete = self.ingest(receipt())
        for name, run in (("partial", partial), ("complete", complete)):
            folder = self.out / name
            folder.mkdir()
            run.update(schema=1, artifacts={})
            qa.write_json(folder / "run.json", run)
        result = qa.compare(self.out / "partial", self.out / "complete", 10)
        self.assertEqual(result["status"], "incomplete")


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "project.godot").write_text("; non-engine fixture\n", encoding="utf-8")
        (self.project / "scenario.gd").write_text("; never executed by Godot\n", encoding="utf-8")
        # Exercise the real worker/process lifecycle, not any engine or renderer.
        fake = self.project / "fake.py"
        fake.write_text("""import json, os, signal, sys, time
from pathlib import Path
mode = sys.argv[1]
out = Path(sys.argv[sys.argv.index('--') + 1])
print('Godot Engine (test double; no engine)', flush=True)
if mode not in ('missing', 'early-timeout'):
    (out / 'frames.csv').write_bytes(DATA)
    (out / 'screenshot-00.png').write_bytes(IMAGE)
    value = dict(RECEIPT)
    value['complete'] = mode == 'complete'
    temp = out / 'scenario.json.tmp'
    temp.write_text(json.dumps(value), encoding='utf-8')
    temp.replace(out / 'scenario.json')
if mode == 'timeout-corrupt':
    (out / 'scenario.json').write_text('{', encoding='utf-8')
    time.sleep(60)
elif mode in ('timeout', 'operator'):
    with (out / 'frames.csv').open('ab') as stream:
        stream.write(b'uncommitted tail')
    time.sleep(60)
elif mode == 'early-timeout':
    time.sleep(60)
elif mode == 'terminated':
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == 'corrupt':
    (out / 'scenario.json').write_text('{', encoding='utf-8')
""".replace("DATA", repr(CSV)).replace("IMAGE", repr(PNG)).replace("RECEIPT", repr(receipt())), encoding="utf-8")
        self.fake = fake

    def argv(self, mode):
        config = {"schema": 1, "name": "non-engine contracts", "kind": "source",
                  "executable": sys.executable, "args": [str(self.fake), mode],
                  "scenario": "scenario.gd", "timeout_seconds": 1 if mode != "operator" else 20,
                  "budgets": {"process_frame/boot": {"p99_ms": 3}}}
        qa.write_json(self.project / "config.json", config)
        return [sys.executable, str(WORKER), "run", "--project", str(self.project),
                "--config", "config.json", "--out", "result-" + mode]

    def test_normal_timeout_termination_and_missing_evidence(self):
        for mode in ("complete", "timeout", "terminated", "missing", "corrupt", "early-timeout", "timeout-corrupt"):
            with self.subTest(mode=mode):
                proc = subprocess.run(self.argv(mode), capture_output=True, text=True, timeout=6)
                out = self.project / ("result-" + mode)
                run = qa.read_json(out / "run.json")
                self.assertEqual(proc.returncode, 0 if mode == "complete" else 1, proc.stderr)
                self.assertEqual(run["status"], "pass" if mode == "complete" else "fail")
                qa.verify_artifacts(out, run)
                if mode in ("timeout", "terminated"):
                    self.assertEqual(len(run["screenshots"]), 1)
                    self.assertEqual(run["metrics"]["process_frame/boot"]["samples"], 2)
                    self.assertFalse(run["scenario"]["complete"])
                    self.assertNotEqual(run["process"]["exit_code"], 0)
                    self.assertFalse(any(c["name"] in ("QA runner", "scenario evidence") for c in run["checks"]))
                    self.assertEqual(run["checks"][-1]["status"], "pending")
                if mode == "timeout":
                    self.assertTrue(run["process"]["timed_out"])
                if mode == "early-timeout":
                    self.assertEqual(run["scenario"]["coverage"], "missing")
                    self.assertFalse(any(c["name"] == "scenario evidence" for c in run["checks"]))
                if mode == "timeout-corrupt":
                    self.assertTrue(run["process"]["timed_out"])
                    self.assertTrue(any(c["name"] == "scenario evidence" and c["status"] == "fail" for c in run["checks"]))

    @unittest.skipUnless(os.name == "posix", "POSIX worker signal finalization")
    def test_operator_signals_preserve_checkpoint_and_reap_child(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                target = self.project / "result-operator"
                proc = subprocess.Popen(self.argv("operator"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                child = None
                try:
                    launch = json.loads(proc.stdout.readline())
                    child = launch["pid"]
                    deadline = time.monotonic() + 4
                    while not (target / "scenario.json").exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue((target / "scenario.json").exists())
                    proc.send_signal(sig)
                    _stdout, stderr = proc.communicate(timeout=5)
                    self.assertEqual(proc.returncode, 1, stderr)
                    run = qa.read_json(target / "run.json")
                    self.assertEqual(run["status"], "fail")
                    self.assertEqual(len(run["screenshots"]), 1)
                    self.assertEqual(run["metrics"]["process_frame/boot"]["samples"], 2)
                    self.assertTrue(any(c["name"] == "QA runner" and c["status"] == "fail" for c in run["checks"]))
                    self.assertFalse(any(c["name"] == "scenario evidence" for c in run["checks"]))
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.communicate()
                    if child is not None:
                        try:
                            os.kill(child, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                for path in sorted(target.rglob("*"), reverse=True):
                    path.unlink() if path.is_file() else path.rmdir()
                target.rmdir()


if __name__ == "__main__":
    unittest.main()
