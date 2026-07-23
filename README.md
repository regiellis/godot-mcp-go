# godot-mcp-go

[![Godot 4.7+](https://img.shields.io/badge/Godot-4.7%2B-478CBF?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Go 1.26+](https://img.shields.io/badge/Go-1.26%2B-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Commands](https://img.shields.io/badge/commands-311-blue)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)

Drive a running **Godot 4.7** editor from the command line — and from AI agents — to build scenes, write GDScript or C#, play and inspect the game, and introspect the engine's real API. A Go CLI talks to a GDScript editor addon over WebSocket. **311 commands across 49 groups**, every one verified against a live editor.

> [!NOTE]
> **This repository is a one-way public mirror**, published as a squashed snapshot — it shares no commit history with the canonical development repo, so **pull requests can't be merged directly**. For bugs, feature requests, or changes, please open an [**Issue**](../../issues) or start a [**Discussion**](../../discussions). That's where development is tracked.

## How is this different from other Godot MCPs?

Plenty of Godot MCP servers exist, and the good ones are editor-native — so "runs in the editor" isn't the differentiator. This one is a **co-developer** that goes deeper on the axes that matter once an agent is actually *building and testing* a game:

- **It drives the running game.** The `runtime` and `input` groups inspect and control the live game over a two-hop IPC — read the running scene tree, set/read node state, `eval`, capture frames, `await_signal`, poll `runtime.errors`, inject input for deterministic playtesting. Most editor-time MCPs stop at "the scene is assembled"; this one builds it *and proves it works by playing it*.
- **One-tool context economy.** A single `godot_run` MCP tool proxying 311 commands, instead of dozens of tool schemas (rivals ship ~40–160) weighing down the agent's context on every session — plus read-only `godot://` resources for pulling project/scene/engine state without spending a tool turn.
- **C# projects too.** `script.create` authors C# templates, `csharp.setup` scaffolds the csproj/sln, and `csharp.build` / `script.validate` compile with structured per-file diagnostics (requires a Godot .NET editor build and the dotnet SDK).
- **Introspection instead of wrappers.** The live `ClassDB` *is* the feature list (`engine.search`, generic `node.set`/`node.get`, `runtime.eval`), so new engine features are reachable the day you upgrade, with no new release of this tool.
- **Live editor integration** — commands run against the real SceneTree with UndoRedo (Ctrl+Z safe for the human) and open-scene conflict protection, not offline `.tscn` rewriting that clobbers unsaved work.
- **Crash-aware discovery** — per-project port discovery with `running`/`starting`/`crashed`/`closed` verdicts on every connection failure, so agents recover deliberately instead of relaunching blindly.
- **Safety guards** — `127.0.0.1`-only, audited code execution, an unsafe-editor-IO guard, and project-path jailing on every write sink.
- **A craft layer** — an agent skill plus 26 craft references (3D controllers, platformers, deckbuilders, interactive music, shaders, multiplayer, save systems…) that teach the agent to build *like a Godot developer*, not just call tools. No other server ships this.

Concretely, against the most popular editor-native server ([`hi-godot/godot-ai`](https://github.com/hi-godot/godot-ai)):

| | godot-ai | godot-mcp-go |
| --- | --- | --- |
| Editor integration | live | live |
| Running-game control | none (editor-time only) | full `runtime` + `input` groups |
| MCP tool schemas carried | ~43 | 1 (`godot_run`) + `godot://` resources |
| Surface | ~120 ops | 311 commands / 49 groups |
| Runtime deps | Python + `uv` | single Go binary |
| Craft layer | tool reference | 26 craft docs + skill |
| Distribution | Asset Library, multi-client auto-config, large community | CLI `install`/`create`/`configure`, self-hosted |

Honest trade: they win on distribution and community reach (Asset Library one-click, auto-config for 20+ clients). This wins on capability depth — the running game, context economy, introspection, and craft. Their tool surface mostly maps onto generic commands here, while the `spatial`, `pcg`, `wfc`, `scatter`, `skeleton`, and `authoring` groups have no counterpart anywhere else.

## How it works

```
godot-mcp (Go CLI / client)  ──WebSocket(JSON-RPC 2.0):9080──▶  Godot editor addon (server)
                                                                      │
                                            file IPC (user://) ◀──────┘──▶  running game
                                                              (MCPGameInspector / MCPGameInput autoloads)
```

- The **addon runs a WebSocket server inside the editor** (the long-lived process). The CLI is a short-lived client that dials in, runs one command, and exits.
- The CLI **auto-discovers the port** from `<project>/.godot/godot-mcp.json` (written by the addon) when run inside the project; otherwise pass `--port` (default `9080`).
- **`runtime`/`input` commands reach the *running* game** via file IPC brokered by two game-side autoloads — so you can inspect the live scene tree, read/set node state, capture frames, and simulate input.
- Every editor mutation goes through Godot's **UndoRedo** (Ctrl+Z safe).

## Requirements

- **Godot 4.7** (launch with `godot`).
- **Go 1.26+** to build the CLI.
- [Task](https://taskfile.dev) (optional but recommended) for the dev workflow.

> [!IMPORTANT]
> **Godot 4.7+ only.** This is built and tested exclusively against Godot 4.7 and newer. Earlier versions (4.6 and below, and the 3.x line) are **not supported** and are not expected to work — the addon targets 4.7 APIs. There are no plans to backport to older releases.

> [!NOTE]
> **C# / .NET?** This is **GDScript-first**: the addon and its introspection target the GDScript API, and there is **no C# support yet**. The introspection layer (`engine`/`runtime`) is language-agnostic in principle, so it isn't ruled out, but nothing works with C# today. Open a [Discussion](../../discussions) if it matters to you.

> **Windows note:** if the editor ever crashes with `ERROR: WASAPI: GetBufferSize`, another app has taken *exclusive* control of your audio device (Chrome on resume is a common culprit). Turn off exclusive mode in Windows Sound settings (Device properties → Advanced → uncheck "Allow applications to take exclusive control"). It's an OS/audio issue, not this addon. (`--audio-driver Dummy` also sidesteps it if needed.)

## Build

```sh
task build          # -> bin/godot-mcp(.exe)
# or:
go build -o bin/godot-mcp ./cmd/godot-mcp
```

## Install into a project

From an unpacked release bundle, install the addon (and the agent skill) into any Godot project in one step:

```sh
godot-mcp install --project /path/to/your/project --enable
```

Starting from nothing? Bootstrap a fresh Godot 4.7 project and wire the addon in one command:

```sh
godot-mcp create --path ./mygame --install --enable
```

Copies `addons/godot_mcp/` and `.claude/skills/godot-mcp/` in and enables the plugin in `project.godot`. See [INSTALL.md](INSTALL.md) for flags and the manual alternative.

## Quick start

1. Open the test project (or your own with the addon installed) in Godot 4.7:
   ```sh
   task editor          # godot --path project --editor
   ```
   Ensure the **Godot MCP** plugin is enabled (Project → Project Settings → Plugins). The addon prints `[MCP] Server listening on ws://127.0.0.1:9080`.
2. From inside the project directory, drive it:
   ```sh
   godot-mcp project info
   godot-mcp scene tree
   godot-mcp node add --type Sprite2D --name Player --parent-path .
   godot-mcp node set --node-path Player --property position --value "Vector2(100, 200)"
   ```

### Discover, then drive

Because the CLI talks to the *live* engine, you can ask it what 4.7 actually supports instead of guessing:

```sh
godot-mcp engine search --query offset_transform          # find members across all classes
godot-mcp engine class-info --class Control --filter transform
```

Even with no typed wrapper, `node.set`/`node.get` work on any property the live node exposes, and `editor.run_script` / `runtime.eval` run arbitrary GDScript — so the entire 4.7 API is reachable.

### Playtest loop

```sh
godot-mcp scene play --mode main
godot-mcp runtime tree
godot-mcp input action --action ui_accept --pressed true
godot-mcp runtime get --node-path Player --properties '["position"]'
godot-mcp runtime screenshot --save-path user://shot.png
godot-mcp scene stop
```

## Use as an MCP server

`godot-mcp serve` runs as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, so MCP clients (Claude Desktop, Claude Code, …) can drive Godot directly. It exposes one tool, `godot_run`, that takes `{ "method": "<group>.<command>", "params": {...} }` and proxies to the editor addon — the same surface as the CLI. The model discovers the live 4.7 API with `engine.search`/`engine.class_info` and then acts.

Example client config:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "godot-mcp",
      "args": ["serve", "--project", "/path/to/your/project"]
    }
  }
}
```

The Godot editor must be open with the plugin enabled (as for the CLI). `--project` sets where the server discovers the addon port.

## Live dashboard (opt-in)

`godot-mcp dashboard` starts a small web UI that shows live activity — tool calls, error rate, per-group breakdown, active connections, uptime, and a recent-activity feed — for **everything** flowing through the addon (CLI, `serve`/MCP, any client). The page (htmx + anime.js) and its assets are embedded in the binary; no Node/build step.

```sh
godot-mcp dashboard --port 8090     # then open http://127.0.0.1:8090
```

Run it from inside your project dir (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`. It holds a single persistent connection and polls the addon's `stats.snapshot`.

## Command groups

`project` `scene` `node` `script` `editor` `runtime` `engine` `input` `animation` `anim_tree` `tilemap` `theme` `shader` `particles` `scene3d` `physics` `navigation` `audio` `input_map` `resource` `analysis` `batch` `profiling` `export` `test` `android`

Invocation is `godot-mcp <group> <command> [--flag value ...]`. Names accept kebab- or snake-case; values that start with `[`/`{` are parsed as JSON. On error the CLI prints the JSON-RPC code, message, and any suggestions to stderr.

## Agent skill

`skills/godot-mcp/SKILL.md` is a Claude Code skill that teaches an agent to use the CLI well: the discover-then-drive loop, Godot's node/scene composition style, the command groups, core workflows, and pitfalls. Drop it into a project's `.claude/skills/` to give an AI agent full context.

## Layout

```
cmd/godot-mcp/                 Go CLI entry
internal/{protocol,client}/    JSON-RPC envelope + WebSocket client/discovery
project/                       Godot 4.7 test project (run with godot)
project/addons/godot_mcp/      the GDScript addon (commands/, services/, utils/)
skills/godot-mcp/SKILL.md      the agent skill
Taskfile.yml                   dev tasks (run `task` to list)
```

Command implementations live in `project/addons/godot_mcp/commands/` (each group a `*_commands.gd`), registered in `command_router.gd`; add a command by registering a handler there. The `services/` autoloads broker the running-game IPC.

## License

MIT — see [LICENSE](LICENSE).
