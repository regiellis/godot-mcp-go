<p align="center">
  <img src="https://raw.githubusercontent.com/regiellis/godot-mcp-go/main/website/public/brand/mark.svg" width="104" alt="Godot MCP CLI: a terminal prompt in a rounded tile with a live-connection dot">
</p>

# Godot MCP CLI

[![Godot 4.7+](https://img.shields.io/badge/Godot-4.7%2B-478CBF?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Go 1.26+](https://img.shields.io/badge/Go-1.26%2B-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Commands](https://img.shields.io/badge/commands-330-blue)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)

Drive a running **Godot 4.7+** editor from the command line and from AI agents: build scenes, write GDScript or C#, play and inspect the game, and introspect the engine's real API. A Go CLI talks to a GDScript editor addon over WebSocket. **330 commands across 50 groups**, every one verified against a live editor.

<p align="center">
  <a href="https://youtu.be/XnoW6EHXaBw">
    <img src="https://raw.githubusercontent.com/regiellis/godot-mcp-go/main/media/previews/demo-poster.png" width="860" alt="The Godot editor with the MCP dock open, a water demo running in its own window, and an agent writing GDScript in a terminal beside it">
  </a>
</p>

<p align="center">
  <a href="https://youtu.be/XnoW6EHXaBw"><b>Watch the three-minute demo</b></a>. A seascape built inside a live editor: water tuned while the game runs, boids for the fish and gulls, audio buses wired from a panel, and the dock counting every call as it lands.
</p>

> [!WARNING]
> **Built for big-context models.** The default MCP mode exposes every command as a typed tool, and that list measures **about 50,000 tokens** against a live editor. Frontier models with 200K to 1M windows and prompt caching carry it comfortably; a small local model will not, and this project does not aim to serve one. Context-tight? The escape hatch is one flag: `serve --typed=false` collapses the surface to a single generic tool (~470 tokens), and the CLI needs no schemas at all. Numbers, method, and reasoning: [What the tool surface costs](#what-the-tool-surface-costs).

> [!NOTE]
> **This repository is a one-way public mirror**, published as a squashed snapshot. It shares no commit history with the canonical development repo, so **pull requests can't be merged directly**. For bugs, feature requests, or changes, please open an [**Issue**](../../issues) or start a [**Discussion**](../../discussions). That's where development is tracked. The **`asset-library` branch** is a packaging artifact for the [Godot Asset Library](https://godotengine.org/asset-library) (an `addons/`-rooted snapshot of just the addon), and it is never merged into `main`.
>
> The snapshot also omits maintainer tooling, so `scripts/` is absent here. `Taskfile.yml` ships whole and a few of its tasks call into that folder (`task test:http`, `task release`, `task mirror:audit`); those are maintainer-only and will not run from a clone of this mirror. The build, editor, and play tasks cover the user-facing workflow. Where the CHANGELOG names a path under `scripts/`, it refers to the development repo.

## What the tool surface costs

Tool schemas are context: an MCP client carries its tool list into every request, so the size of that list is a real cost that deserves a measured number. Measured 2026-08-07 by capturing the actual `tools/list` payload `serve` produces against a live Godot 4.7.2 editor, with tokens estimated at four characters per token:

| Surface | Tools carried | Schema payload | Estimated tokens |
| --- | --- | --- | --- |
| The CLI (shell-driving agents) | none | none | **0** |
| `serve` default (typed tools) | 332 | ~205 KB JSON | **~52,000** |
| `serve --typed=false` | 1 (`godot_run`) | ~1.9 KB | **~470** |

The 332 is every registered command plus the generic `godot_run`. The measured list even picked up the test project's two project-local commands, because the schemas are built live from whatever the addon registers.

What the numbers mean in practice:

- **The default is sized for big-context models**. Against a 200K window the full list is a quarter of the budget; against the 1M windows current frontier models ship, it is 5%. With prompt caching the list sits in the cached prefix after the first request, and on Claude cached input bills at roughly a tenth of the base rate, so the recurring cost is a fraction of the headline number. The list only changes mid-session in one rare case: the editor was down at connect and came back up.
- **The escape hatches ship in the box**. `serve --typed=false` keeps the same 330 commands behind one ~470-token tool (the model discovers the API with `engine.search` instead of reading schemas); the `http_typed` project setting does the same for the editor's own HTTP endpoint; clients that load schemas on demand (Claude Code does) pay only for the tools they actually use; the read-only `godot://` resources pull project and scene state without any tool turn; and the CLI is a zero-schema surface any agent with a shell can drive.
- **The trade is deliberate**. A curated "core toolset" default is not planned: a model too small to carry the list is also too small to run the discover-then-drive and spatial-verification loops this tool is built around, and the escape hatches above already serve constrained clients. The full breakdown is on [What the tool surface costs](https://regiellis.github.io/godot-mcp-go/docs/context-cost) in the docs: which command groups carry the weight, the caching math, and the design reasoning.

## Isn't this just Godot's built-in CLI?

No. They do different jobs, and they compose. **Godot's own command line starts a Godot process; godot-mcp talks to the one that's already running.**

|  | Godot's CLI (`godot --headless`, `--export-release`, `--script`) | godot-mcp |
| --- | --- | --- |
| Process model | Launches a fresh engine process per invocation, cold start each time | Connects over WebSocket to the editor you already have open |
| Session state | None: no open scene, no selection, no undo history | The live session: edited scene, selection, unsaved work, UndoRedo (every mutation Ctrl+Z-safe) |
| Editing | Run a script once against project files | 330 commands against the open scene, with open-scene conflict protection |
| The running game | The launched process *is* the game; nothing reaches inside it | A live channel into it: read state, `eval`, inject input, await signals, screenshot |
| Introspection | `--doctool` dumps docs offline | `engine.*` reads the running build's ClassDB, live |
| Built for | CI work like exports, imports, and batch scripts | Interactive building and playtesting, by humans at a terminal and by AI agents |

Keep using Godot's CLI for exports and CI; godot-mcp itself shells out to it to launch the editor in the first place.

## How is this different from other Godot MCPs?

Plenty of Godot MCP servers exist, and the good ones are editor-native, so "runs in the editor" isn't the differentiator. The differences show up once an agent is building and testing a game rather than assembling a scene and stopping:

- **It's a CLI first, and an MCP server second:** every command runs from a shell (`godot-mcp node add --type Sprite2D …`), so a terminal-driven agent needs **zero** tool schemas and a human can drive the same surface by hand. The MCP modes are a second front door onto it, not the only one.
- **It drives the running game:** the `runtime` and `input` groups inspect and control it over a two-hop IPC, reading the scene tree, setting node state, `eval`, capturing frames, `await_signal`, polling `runtime.errors`, and injecting input for deterministic playtesting. A debug-build game can also host its own channel and be driven with **no editor open at all** (`--game`).
- **It debugs the running game:** the `debug` group arms real breakpoints (they show in the gutter and hit a game already running), reads the paused game's stack and per-frame variables, steps over/into/out, and hot-reloads edited scripts into the live process with state kept, so you fix a bug mid-playtest without restarting the run.
- **Schemas that can't go stale:** by default `serve` exposes every command as a typed MCP tool whose schema is built **live** from the addon's own param docs, so the tool surface tracks whatever the editor registers. `serve --typed=false` collapses to the single generic `godot_run` for tool-limited clients (rivals ship ~40 to 160 fixed schemas either way), plus read-only `godot://` resources for pulling project, scene, and engine state without spending a tool turn.
- **Two MCP transports, plus prompts:** stdio through the Go binary, or **editor-direct streamable HTTP**, where the addon itself hosts `POST /mcp` on `127.0.0.1` so an HTTP-capable MCP client drives the editor with **no external process at all**, same commands and same guards. The playbooks ship as first-class **MCP prompts** (`discover-then-drive`, `spatial-placement`, `launch-recovery`, `bug-hunt`), served even when the editor is down.
- **C# projects too:** `script.create` authors C# templates, `csharp.setup` scaffolds the csproj/sln, and `csharp.build` / `script.validate` compile with structured per-file diagnostics (requires a Godot .NET editor build and the dotnet SDK).
- **Introspection instead of wrappers:** the live `ClassDB` *is* the feature list: `engine.search` to find a name, `engine.docs`/`engine.doc_search` for what it means (the running build's own documentation prose, straight from the editor's doc cache), then generic `node.set`/`node.get` for properties and `node.call`/`runtime.call` for methods. New engine features are reachable the day you upgrade, with no new release of this tool. That is not a claim on paper: the addon runs unmodified on **4.8-dev**, whose 6 new classes and 4 removals needed no code change, and `engine.search` picks up 4.8's `FuzzySearch` automatically to resolve abbreviations like `linvel` → `linear_velocity`.
- **Live editor integration:** commands run against the real SceneTree with UndoRedo (Ctrl+Z safe for the human) and open-scene conflict protection, not offline `.tscn` rewriting that clobbers unsaved work.
- **Crash-aware discovery:** per-project port discovery with `running`/`starting`/`crashed`/`closed` verdicts on every connection failure, so agents recover deliberately instead of relaunching blindly.
- **Safety guards:** `127.0.0.1`-only, audited code execution, an unsafe-editor-IO guard, and project-path jailing on every write sink.
- **A craft layer:** an agent skill plus 28 craft references (3D controllers, platformers, deckbuilders, interactive music, shaders, multiplayer, save systems…) that teach Godot's idioms, so an agent composes nodes and scenes the way a Godot developer would instead of reaching for whichever command fits.
- **Style is checkable:** `script.lint` measures GDScript against the official style guide with 17 rules, each finding carrying line, rule, and severity, so the craft layer's advice becomes something an agent can verify against rather than merely read. It runs inside the addon, with no tool to install.

Concretely, here it is against the two most-used alternatives, [`godot-ai`](https://github.com/hi-godot/godot-ai) and [`Godot-MCP-Native`](https://github.com/yurineko73/Godot-MCP-Native). Both are good, both are actively maintained, and all three are MIT. Figures checked 2026-08-03; verify them yourself before relying on any of it.

| | godot-ai | Godot-MCP-Native | godot-mcp |
| --- | --- | --- | --- |
| Implementation | Python (FastMCP) + GDScript plugin | GDScript only | Go CLI + GDScript addon |
| Runtime deps | Python + `uv` | none | one Go binary, or none via the editor's own HTTP endpoint |
| Drives it from | an MCP client | an MCP client | **any agent that can run a shell command**, plus any MCP client |
| Shell-drivable CLI | no | no | yes, the primary surface |
| Surface | ~43 tools / ~120 ops | 155 tools | 330 commands / 50 groups |
| MCP tool schemas carried | ~43 fixed | 155 fixed | live-built per command, or as few as **1** (`godot_run`) |
| MCP transports | HTTP + WebSocket | HTTP, plus a headless editor mode | stdio, editor-direct HTTP, and the CLI |
| MCP prompts / resources | none | none | 4 prompts, 5 `godot://` resources |
| Running-game control | editor-time only | in-game probe autoload | two-hop IPC, plus a direct channel to an editor-less debug build |
| C# projects | not documented | symbol indexing, project inspection | `csharp` group: scaffold the csproj/sln, build, per-file diagnostics |
| Start a project from nothing | no | no | `godot-mcp create` writes `project.godot`, icon, `.gitignore` |
| Undo-safe mutations | no | no | `UndoRedo` across 29 command files, plus open-scene conflict refusal |
| Extending it | in review ([#820](https://github.com/hi-godot/godot-ai/pull/820)) | no | `res://mcp_commands/*.gd`, no fork needed |
| Godot versions | **4.5+** | **4.5+** | 4.7+, verified on 4.7.2 and 4.8-dev |
| Craft layer | tool reference | tool reference | 28 craft guides + agent skill |
| GDScript style linting | no | no | 17 rules, native |
| Install | Asset Library per its README; auto-configures 17+ clients | Asset Library (`Godot MCP Native`) | Asset Library (`Godot MCP/CLI`), or `godot-mcp install` / `create` / `configure` |
| Community | 1.4k stars | 590 stars | smaller |

**Where each one wins.** godot-ai has the reach: the biggest community by some margin, and the broadest client support, auto-configuring 17+ of them. Godot-MCP-Native has the leanest install of the three (GDScript only, nothing to download, nothing on PATH), and it reaches the running game through an in-game probe much as this project does, so that is no longer a dividing line. **Both support Godot 4.5 and 4.6; this project asks for 4.7.**

What this side adds starts with how you drive it: a **shell-drivable CLI** is the primary surface, so any agent that can run a shell command works, with no MCP support and no tool schemas at all. The MCP modes are a second front door, not the only way in. Past that: a tool surface **built live from the addon** rather than shipped as fixed schemas, collapsible to one tool for context-tight clients; MCP prompts and `godot://` resources; real C# project support; `create` to start a project from nothing; project-local commands without forking; the `spatial`, `pcg`, `wfc`, `scatter`, `skeleton`, and `authoring` groups; and the craft layer that teaches an agent Godot's idioms rather than only listing tools. Much of the other two's tool surface maps onto generic commands here (`node.set`/`node.get`/`node.call` against the live ClassDB), which is why a raw command count is not a like-for-like measure of capability.

> [!NOTE]
> Running godot-mcp and Godot-MCP-Native side by side: both default to port **9080**. Pin one of them (`GODOT_MCP_PORT`, or the `godot_mcp/network/port` project setting here) or the second to start will pick a different port and your client will connect to whichever answers.

## How it works

```
godot-mcp (Go CLI / client)  ──WebSocket(JSON-RPC 2.0):9080──▶  Godot editor addon (server)
MCP client (streamable HTTP) ──POST /mcp:9100────────────────▶        │
                                            file IPC (user://) ◀──────┘──▶  running game
                                                              (MCPGameInspector / MCPGameInput autoloads)
```

- The **addon runs a WebSocket server inside the editor** (the long-lived process). The CLI is a short-lived client that dials in, runs one command, and exits.
- The CLI **auto-discovers the port** from `<project>/.godot/godot-mcp.json` (written by the addon) when run inside the project; otherwise pass `--port` (default `9080`).
- **`runtime`/`input` commands reach the *running* game** via file IPC brokered by two game-side autoloads, or, for a standalone **debug build** with no editor open, over the game's own direct server (`godot-mcp --game …`, opt-in project setting). Either way you can inspect the live scene tree, read/set node state, capture frames, and simulate input.
- Every editor mutation goes through Godot's **UndoRedo** (Ctrl+Z safe).

## Requirements

- **Godot 4.7+** (launch with `godot`).
- **Go 1.26+** to build the CLI.
- [Task](https://taskfile.dev) (optional but recommended) for the dev workflow.

> [!IMPORTANT]
> **Godot 4.7+ only.** Earlier versions (4.6 and below, and the 3.x line) are **not supported** and are not expected to work, since the addon targets 4.7 APIs. There are no plans to backport.
>
> **Builds this release was run against:** `4.7.1-rc` (`d6096250e`), `4.7.2-rc` (`36a04fe52`), and a `4.8-dev` build from `master` (`eda2a482e`, after dev 2). On 4.8 the addon runs unmodified, with every command of that build registering and no parse or compile errors, and `engine.search` picks up 4.8's `FuzzySearch` automatically. 4.8 writes a `unique_id` attribute into saved scenes that 4.7 does not, so a project saved by 4.8 is not round-trip clean back to 4.7; that is an engine format change, not an addon one.

> [!NOTE]
> **C# / .NET?** Supported. The `csharp` group scaffolds and builds .NET projects (`csharp.info` / `csharp.setup` / `csharp.build`), and `script.*` is C#-aware: `script.create` writes a C# class template for `.cs` paths, `script.validate --path X.cs` compiles with per-file structured diagnostics, and `script.list` recognizes C# classes. *Running* C# scripts in-editor requires a Godot **.NET editor build** plus the dotnet SDK (`godot-mcp doctor` checks for it); `editor.run_script` / `runtime.eval` execute GDScript either way, and the introspection layer is language-agnostic.

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

> **Before you ship:** the addon is development tooling. Disable the plugin and add `addons/godot_mcp/*` to every export preset's exclude filter so it never rides into an exported game. [INSTALL.md](INSTALL.md#before-you-ship) has the two steps; the [Shipping and export guide](https://regiellis.github.io/godot-mcp-go/docs/guides/shipping-export) covers verifying a build.

## Quick start

1. Open the test project (or your own with the addon installed) in Godot 4.7+:
   ```sh
   task editor          # godot --path project --editor
   ```
   Ensure the **Godot MCP/CLI** plugin is enabled (Project → Project Settings → Plugins). The addon prints `[MCP] Server listening on ws://127.0.0.1:9080`.
2. From inside the project directory, drive it:
   ```sh
   godot-mcp project info
   godot-mcp scene tree
   godot-mcp node add --type Sprite2D --name Player --parent-path .
   godot-mcp node set --node-path Player --property position --value "Vector2(100, 200)"
   ```

### Discover, then drive

Because the CLI talks to the *live* engine, you can ask it what your engine build actually supports instead of guessing:

```sh
godot-mcp engine search --query offset_transform          # find members across all classes
godot-mcp engine class-info --class Control --filter transform
godot-mcp engine doc-search --query "wrap text"           # search the docs prose by concept
godot-mcp engine docs --class Label --member autowrap_mode  # read what it means
```

Even with no typed wrapper, `node.set`/`node.get` work on any property the live node exposes, and `editor.run_script` / `runtime.eval` run arbitrary GDScript, so any property or callable the running build exposes is reachable, whatever its version.

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

`godot-mcp serve` runs as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, so MCP clients (Claude Desktop, Claude Code, …) can drive Godot directly. By default every command is a **typed MCP tool** with a real schema built live from the addon's param docs; `godot_run` remains the generic escape hatch (`{ "method": "<group>.<command>", "params": {...} }`, the same surface as the CLI), and `serve --typed=false` keeps tool-limited clients on that single tool. `godot_run` and the typed `runtime_*`/`input_*` tools accept `game: true` to drive a standalone debug-build game with **no editor open**. The model discovers the running engine's API with `engine.search`/`engine.class_info` and then acts.

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

`serve` also ships **MCP prompts**: the durable playbooks (`discover-then-drive`, `spatial-placement`, `launch-recovery`, `bug-hunt`) as first-class prompts your client can pull with `prompts/get`, served even when the editor is down. Those sit alongside the read-only `godot://` resources and the `instructions` string every connect carries.

### Or connect straight to the editor (no binary)

The addon itself hosts a **streamable-HTTP MCP endpoint** inside the editor at `POST /mcp` on `127.0.0.1`, auto-port **9100-9115** (the actual port is in `<project>/.godot/godot-mcp.json` as `http_port`; pin one with the `godot_mcp/network/http_port` project setting or `GODOT_MCP_HTTP_PORT`). Any MCP client that speaks streamable HTTP connects with no external process:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://127.0.0.1:9100/mcp"
    }
  }
}
```

Same tool surface as `serve` (the generic `godot_run` plus typed per-command tools), same guards. Set `godot_mcp/network/http_typed` to `false` in Project Settings to list only `godot_run` for tool-limited clients, or `godot_mcp/network/mcp_http` to `false` to turn the endpoint off.

## Live dashboard (opt-in)

`godot-mcp dashboard` starts a small web UI that shows live activity across every client on the wire: the CLI, `serve`/MCP, the editor's HTTP endpoint, and anything else you have connected. It reports tool calls, error rate, per-group breakdown, active connections, uptime, and a recent-activity feed. The page (htmx + anime.js) and its assets are embedded in the binary; no Node/build step.

```sh
godot-mcp dashboard --port 8090     # then open http://127.0.0.1:8090
```

Run it from inside your project dir (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`. It holds a single persistent connection and polls the addon's `stats.snapshot`.

The same dashboard also lives **inside the editor**: the addon docks an **MCP panel** (right side, movable like any dock) with the same numbers: stat tiles, error banner, top groups, recent errors, and the live timeline with filters. It reads them in-process from the addon, so it needs no extra process and no port. The web UI stays for watching from outside the editor; the dock is there while you work.

## Build on it

The CLI is built to be scripted. The contract: piped results on stdout as JSON (`--format tsv|ndjson` for shell tools, `GODOT_MCP_FORMAT` to pin one per shell; a terminal gets color-coded tables instead, never a pipe), errors on stderr with JSON-RPC codes, exit codes `0`/`1`/`2`, port discovery from the project directory, and `doctor`/`status` as scriptable preflights. The catalog itself is queryable JSON, and `engine commands --docs` returns every command with typed params, so generators and UIs read the command list instead of hardcoding one. Underneath it all is a stable JSON-RPC-over-WebSocket wire that any language can speak: a Python script, a browser panel, a QA rig driving a standalone game via `--game`.

```bash
# hide every Label in the edited scene
godot-mcp batch find-nodes-by-type --type Label | jq -r '.matches[].path' \
  | while read -r p; do godot-mcp node set --node-path "$p" --property visible --value false; done
```

Worked examples (a CI smoke test, a Python client, a working browser panel): [Scripting and CI](https://regiellis.github.io/godot-mcp-go/docs/automation/) · [Your own tools and UIs](https://regiellis.github.io/godot-mcp-go/docs/building-on-top/).

## Command groups

`analysis` `android` `anim_tree` `animation` `audio` `authoring` `batch` `camera` `cleanup` `csg` `csharp` `doc` `editor` `engine` `export` `fs` `gridmap` `import` `input` `input_map` `lighting` `localization` `material` `mesh` `multiplayer` `navigation` `node` `particles` `path` `pcg` `physics` `profiling` `project` `resource` `runtime` `scatter` `scene` `scene2d` `scene3d` `script` `shader` `skeleton` `spatial` `test` `theme` `tilemap` `ui` `wfc`

Invocation is `godot-mcp <group> <command> [--flag value ...]`. Names accept kebab- or snake-case; values that start with `[`/`{` are parsed as JSON. On error the CLI prints the JSON-RPC code, message, and any suggestions to stderr. Explore the catalog from the CLI itself: `godot-mcp help all` lists every group's commands, `godot-mcp <group> --help` narrows to one group, and `godot-mcp <group> <command> --help` prints that command's param table.

## Agent skill

`skills/godot-mcp/SKILL.md` is a Claude Code skill that teaches an agent to use the CLI well: the discover-then-drive loop, Godot's node/scene composition style, the command groups, core workflows, and pitfalls. Drop it into a project's `.claude/skills/` so an agent starts with the loop, the groups, and the pitfalls already loaded.

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

MIT. See [LICENSE](LICENSE).
