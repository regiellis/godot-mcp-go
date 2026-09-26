"""Record the longer tutorial's real commands and MCP edit. Requires the editor addon."""
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
    item = {"argv": args, "output": run.stdout.strip(), "exit": run.returncode}
    if run.returncode:
        raise RuntimeError(name + ": " + run.stdout + run.stderr)
    try:
        item["result"] = json.loads(run.stdout)
    except ValueError:
        pass
    TAKES[name] = item
    save()
    print(name + ": recorded", flush=True)
    return item.get("result")


def save():
    (ROOT / "trailers/takes-v2.json").write_text(json.dumps(TAKES, indent=2) + "\n", encoding="utf-8")


def set_node(name, path, prop, value):
    return take(name, ["node", "set", "--node-path", path, "--property", prop, "--value", value])


take("status", ["status"])
take("help", ["node", "set", "--help"])
take("open", ["scene", "open", "--path", "res://lighthouse_demo.tscn"])
take("tree", ["scene", "tree"])
set_node("home", "Dressing/Lighthouse", "position", "Vector3(-4, 1.08, -7)")
set_node("small", "Dressing/Lighthouse", "scale", "Vector3(0.5, 0.5, 0.5)")
take("inspect", ["node", "get", "--node-path", "Dressing/Lighthouse", "--properties", '["position","scale"]'])
set_node("place", "Dressing/Lighthouse", "position", "Vector3(7, 1.08, -7)")
set_node("scale", "Dressing/Lighthouse", "scale", "Vector3(0.7, 0.7, 0.7)")
# Re-recording replaces only the named demonstration copy.
tree = json.dumps(TAKES["tree"]["result"])
if '"ShoreRock"' in tree:
    take("remove_copy", ["node", "delete", "--node-path", "Dressing/ShoreRock"])
take("duplicate", ["node", "duplicate", "--node-path", "Dressing/Scatter0", "--name", "ShoreRock"])
set_node("rock", "Dressing/ShoreRock", "position", "Vector3(12, 0.5, 1)")
set_node("rock_scale", "Dressing/ShoreRock", "scale", "Vector3(2, 2, 2)")
take("waves", ["shader", "set-param", "--node-path", "Water", "--param", "wave1_amplitude", "--value", "0.65"])
take("save", ["scene", "save"])
take("plan", ["automate", "--file", "trailers/calm.json"])
take("plan_again", ["automate", "--file", "trailers/calm.json"])
take("check", ["check", ".", "--godot", GODOT])
take("rough", ["shader", "set-param", "--node-path", "Water", "--param", "wave1_amplitude", "--value", "0.65"])
take("play", ["scene", "play", "--mode", "current"])
time.sleep(2)
take("camera", ["runtime", "get", "--node-path", "Camera", "--properties", '["movement_speed"]'])
take("move", ["input", "key", "--keycode", "W", "--pressed", "true"])
time.sleep(1)
take("release", ["input", "key", "--keycode", "W", "--pressed", "false"])
base = 'get_tree().current_scene.get_node("Water").material_override'
take("live_rough", ["runtime", "eval", "--code", base + '.set_shader_parameter("wave1_amplitude", 0.65)'])
take("before", ["runtime", "eval", "--code", 'emit(' + base + '.get_shader_parameter("wave1_amplitude"))'])
take("adjust", ["runtime", "eval", "--code", 'var water = get_tree().current_scene.get_node("Water")\nwater.material_override.set_shader_parameter("wave1_amplitude", 0.18)'])
take("after", ["runtime", "eval", "--code", 'emit(' + base + '.get_shader_parameter("wave1_amplitude"))'])
take("errors", ["runtime", "errors"])
take("capture", ["runtime", "screenshot", "--save-path", "user://coast-reviewed.png"])
take("stop", ["scene", "stop"])
take("agent_help", ["shader", "set-param", "--help"])
take("agent_water", ["shader", "set-param", "--node-path", "Water", "--param", "wave1_amplitude", "--value", "0.18"])
set_node("agent_light", "Sun", "rotation_degrees", "Vector3(-18, -40, 0)")
set_node("agent_color", "Sun", "light_color", "Color(1, 0.75, 0.5)")
take("agent_save", ["scene", "save"])
take("agent_read", ["node", "get", "--node-path", "Sun", "--properties", '["rotation_degrees","light_color"]'])

p = subprocess.Popen([CLI, "serve", "--project", str(ROOT), "--typed=false"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, encoding="utf-8")
replies = queue.Queue()
threading.Thread(target=lambda: [replies.put(line) for line in p.stdout], daemon=True).start()


def request(identifier, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
    p.stdin.flush()
    while True:
        result = json.loads(replies.get(timeout=20))
        if result.get("id") == identifier:
            if "error" in result or result.get("result", {}).get("isError"):
                raise RuntimeError(result)
            return result


try:
    request(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "coast-tutorial", "version": "2"}})
    p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    p.stdin.flush()
    for identifier, name, method, params in [
        (2, "mcp_edit", "node.set", {"node_path": "Sun", "property": "rotation_degrees", "value": "Vector3(-8, -40, 0)"}),
        (3, "mcp_read", "node.get", {"node_path": "Sun", "property": "rotation_degrees"}),
    ]:
        arguments = {"method": method, "params": params}
        TAKES[name] = {"arguments": arguments, "response": request(identifier, "tools/call", {"name": "godot_run", "arguments": arguments})}
        save()
finally:
    p.terminate()
    p.wait(timeout=5)
take("final_save", ["scene", "save"])
take("material_save", ["editor", "run-script", "--code",
     'var w = EditorInterface.get_edited_scene_root().get_node("Water"); emit(ResourceSaver.save(w.material_override, "res://water/shervheim_water_material.tres"))',
     "--allow-unsafe-editor-io"])
