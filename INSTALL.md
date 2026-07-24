# Installing godot-mcp

A release bundle has three pieces. You need **Godot 4.7+**.

## Easiest: the `install` command

From an unpacked release bundle, the CLI installs the addon **and** the agent skill into a project for you:

```sh
godot-mcp install --project /path/to/your/project --enable
```

This copies `addons/godot_mcp/` and `.claude/skills/godot-mcp/` into the project and enables the plugin in `project.godot`. Flags: `--skill=false` to skip the skill, `--enable` to turn the plugin on (otherwise enable it in-editor), `--force` to overwrite, `--from DIR` to point at a different addon source. Omit `--project` to target the project containing your current directory.

Then open the project in Godot 4.7 — done. The manual steps below are the alternative if you'd rather copy things yourself.

## 1. The CLI

The bundle contains the `godot-mcp` binary (`godot-mcp.exe` on Windows). Put it somewhere on your `PATH`, or run it by full path.

```sh
godot-mcp --help
```

## 2. The Godot addon

Copy the `addons/godot_mcp/` folder into your Godot project so you end up with:

```
<your project>/addons/godot_mcp/
```

Then in Godot: **Project → Project Settings → Plugins → Godot MCP → Enable**.

On enable the addon starts a WebSocket server (`[MCP] Server listening on ws://127.0.0.1:9080`) plus a **streamable-HTTP MCP endpoint** (`[MCP-HTTP] MCP endpoint listening on http://127.0.0.1:9100/mcp`) that HTTP-capable MCP clients can connect to directly — no CLI binary needed. If your project doesn't already declare them, it also injects two autoloads (`MCPGameInspector`, `MCPGameInput`) that the `runtime`/`input` commands need. Disabling the plugin removes only the autoloads it added.

(Standalone `godot-mcp-addon_<version>.zip` extracts the `godot_mcp` folder directly — drop it into your project's `addons/`.)

## 3. The agent skill (optional)

To give a Claude Code agent full context on the tool, copy the skill so you have:

```
<your project>/.claude/skills/godot-mcp/SKILL.md     # project-scoped
# or, for all projects:
~/.claude/skills/godot-mcp/SKILL.md                  # global
```

(Standalone `godot-mcp-skill_<version>.zip` extracts the `godot-mcp` folder — drop it into `.claude/skills/`.)

## 4. Bundled greybox assets (optional)

The tool ships **CC0 asset packs** for prototyping. Install them into a project with:

```sh
godot-mcp install-assets --project /path/to/your/project
```

By default this copies every bundled pack into `<project>/assets/vendor/<pack>/`. Each pack is copied whole — its `License.txt` and source files included — so the CC0 attribution stays intact. Flags: `--list` to see what's bundled (no project needed), `--pack NAME` to install just one, `--dest DIR` to install somewhere else (project-relative or absolute), `--force` to overwrite an existing pack. Omit `--project` to target the project containing your current directory. (Like `install`, this is a local command — it doesn't need the editor running.)

Currently bundled:

- **`kenney_prototype_textures`** — Kenney's [Prototype Textures](https://kenney.nl/assets/prototype-textures) (CC0): grid/checker greybox skins in per-colour folders (`PNG/Dark`, `Green`, `Orange`, `Purple`, `Red`, `Light`). Apply one to a blockout mesh as a triplanar `StandardMaterial3D` — see the level-design skill (`skills/godot-mcp/level-design.md`) for the recipe and a greybox colour language.

## Pinning the MCP port (optional)

By default the addon binds the first free port in **9080-9095** and writes it to `<project>/.godot/godot-mcp.json`, so the CLI auto-discovers it — you rarely need to think about ports. Running **two projects at once**, pin each to a distinct port so they never contend:

**Project → Project Settings → General → Godot Mcp → Network → Port** (turn on *Advanced Settings* if you don't see it). Set it to e.g. `9091`; `0` means auto-pick. The value is saved in that project's `project.godot`, and the server rebinds to it the next time the plugin loads (toggle it off/on under *Plugins*, or run `godot-mcp editor reload-plugin`). `GODOT_MCP_PORT` in the environment still overrides everything. The default (`0`) is never written to `project.godot`, so leaving it alone keeps the file clean.

The **streamable-HTTP MCP endpoint** works the same way in its own range (**9100-9115**, recorded as `http_port` in the discovery file): pin it via **Network → Http Port** or `GODOT_MCP_HTTP_PORT`, turn it off via **Network → Mcp Http**, and set **Network → Http Typed** to off to expose only the generic `godot_run` tool to tool-limited clients.

## Adding your own commands (optional)

Extend the MCP with project-specific commands without forking the addon: drop a `.gd` file into a **`res://mcp_commands/`** folder in your project. On plugin enable the addon scans that folder and registers your commands next to the built-ins, so they show up in `godot-mcp help <group>`, `godot-mcp engine commands`, and the CLI automatically — no Go or addon changes.

A command file just has to instantiate to a Node and expose `get_commands() -> {"group.command": Callable}`. Extending the addon's `base_command.gd` gives you the `success()` / `error()` / `require_string()` helpers; a plain `extends Node` works too if you build the result dicts yourself. Minimal example (`res://mcp_commands/example_commands.gd`):

```gdscript
@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

func get_commands() -> Dictionary:
    return {
        "custom.ping": _ping,
        "custom.echo": _echo,
    }

func _ping(_params: Dictionary) -> Dictionary:
    return success({"pong": true})

func _echo(params: Dictionary) -> Dictionary:
    var r := require_string(params, "message")
    if r[1] != null:
        return r[1]
    return success({"message": r[0]})
```

Then `godot-mcp custom ping` and `godot-mcp custom echo --message hi` work. A file that fails to load or lacks `get_commands()` is skipped with a warning (it never breaks the plugin), and a name that collides with a built-in is skipped — built-ins win. Editing a command file needs a full editor restart to recompile (reloading the plugin re-runs registration but doesn't re-parse changed scripts).

## Driving a standalone game (optional)

`runtime`/`input` commands normally reach the running game through the open editor. To drive a game with **no editor at all** (QA rigs, packaged dev builds): enable **Project → Project Settings → Godot Mcp → Runtime → Direct Server**, run a **debug build** of the game, then:

```sh
godot-mcp --game runtime tree
godot-mcp --game runtime eval --code "emit(1+1)"
```

The game hosts its own `127.0.0.1`-only server (ports 9200-9215; `GODOT_MCP_GAME_PORT` pins one) and writes a discovery file in its `user://` dir, so `--game` finds it automatically from inside the project. Release exports never host this server — it is hard-gated to debug builds.

## Verify

1. Open your project in Godot 4.7+ (`godot`) and enable the plugin.
2. From a terminal **inside the project directory** (so the CLI auto-discovers the port):
   ```sh
   godot-mcp project info
   godot-mcp scene tree
   ```

If the CLI can't connect, run `godot-mcp doctor` (from inside the project, or with `--project DIR`) — it checks the godot binary, the addon install/enable state, the effective port, and whether an editor is actually reachable — or pass `--port 9080` explicitly.
