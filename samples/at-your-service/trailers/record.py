"""Record actual CLI operations and a real MCP call against the open sample editor."""
import json
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = shutil.which(sys.argv[1]) or str(Path(sys.argv[1]).resolve())
GODOT = sys.argv[2] if len(sys.argv) > 2 else "godot"
TAKES = {}


def take(name, args):
    run = subprocess.run([CLI, "--project", str(ROOT), *args], cwd=ROOT,
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    TAKES[name] = {"argv": args, "command": "swallowtail " + " ".join(args),
                   "output": run.stdout.strip(), "stderr": run.stderr, "exit": run.returncode}
    if run.returncode:
        raise RuntimeError(name + ": " + run.stdout + run.stderr)
    try:
        TAKES[name]["result"] = json.loads(run.stdout)
    except ValueError:
        pass
    (ROOT / "trailers/takes.json").write_text(json.dumps(TAKES, indent=2) + "\n")
    print(name + ": recorded", flush=True)
    return TAKES[name].get("result")


take("open", ["scene", "open", "--path", "res://lighthouse_demo.tscn"])
take("place", ["node", "set", "--node-path", "Dressing/Lighthouse", "--property", "position",
               "--value", "Vector3(7, 1.08, -7)"])
take("water", ["shader", "set-param", "--node-path", "Water", "--param", "wave1_amplitude",
               "--value", "0.25"])
take("save", ["scene", "save"])
take("check", ["check", ".", "--godot", GODOT])
take("validate", ["scene", "validate", "--path", "res://lighthouse_demo.tscn"])
take("play", ["scene", "play", "--mode", "main"])
time.sleep(2)
take("errors", ["runtime", "errors"])
take("move", ["input", "key", "--keycode", "W", "--pressed", "true"])
time.sleep(0.8)
take("release", ["input", "key", "--keycode", "W", "--pressed", "false"])
base = 'get_tree().current_scene.get_node("Water").material_override'
take("swell", ["runtime", "eval", "--code", base + '.set_shader_parameter("wave1_amplitude", 0.65)'])
take("before", ["runtime", "eval", "--code", 'emit(' + base + '.get_shader_parameter("wave1_amplitude"))'])
take("adjust", ["runtime", "eval", "--code", base + '.set_shader_parameter("wave1_amplitude", 0.18)'])
take("after", ["runtime", "eval", "--code", 'emit(' + base + '.get_shader_parameter("wave1_amplitude"))'])
take("capture", ["runtime", "screenshot", "--save-path", "user://lighthouse-playtest.png"])
take("stop", ["scene", "stop"])
take("agent_help", ["shader", "set-param", "--help"])
take("agent_water", ["shader", "set-param", "--node-path", "Water", "--param", "wave1_amplitude", "--value", "0.18"])
take("agent_light", ["node", "set", "--node-path", "Sun", "--properties",
                     json.dumps({"light_energy": 1.1, "light_color": "Color(1, 0.75, 0.5)",
                                 "rotation_degrees": "Vector3(-18, -40, 0)"})])
take("agent_save", ["scene", "save"])
take("agent_read", ["node", "get", "--node-path", "Sun", "--properties", '["light_energy","light_color"]'])
take("material_save", ["editor", "run-script", "--code",
     'var w = EditorInterface.get_edited_scene_root().get_node("Water"); emit(ResourceSaver.save(w.material_override, "res://water/shervheim_water_material.tres"))',
     "--allow-unsafe-editor-io"])

p = subprocess.Popen([CLI, "serve", "--project", str(ROOT), "--typed=false"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, encoding="utf-8")
replies = queue.Queue()
threading.Thread(target=lambda: [replies.put(line) for line in p.stdout], daemon=True).start()


def request(id, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\n")
    p.stdin.flush()
    while True:
        result = json.loads(replies.get(timeout=20))
        if result.get("id") == id:
            if "error" in result or result.get("result", {}).get("isError"):
                raise RuntimeError(result)
            return result


try:
    request(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "lighthouse-recorder", "version": "1"}})
    p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    p.stdin.flush()
    arguments = {"method": "node.get", "params": {"node_path": "Sun", "property": "light_energy"}}
    result = request(2, "tools/call", {"name": "godot_run", "arguments": arguments})
    TAKES["mcp"] = {"arguments": arguments, "response": result, "transport": "MCP stdio"}
    (ROOT / "trailers/takes.json").write_text(json.dumps(TAKES, indent=2) + "\n")
    print("mcp: recorded")
finally:
    p.terminate()
    p.wait(timeout=5)
