<p align="center">
  <img src="https://raw.githubusercontent.com/regiellis/godot-mcp-go/main/website/public/brand/swallowtail-butler.png" width="160" alt="Swallowtail butler mascot">
</p>

# Swallowtail

**Godot automation. Your game. Your workflow.**

Build, inspect, test, and debug Godot games from your terminal. Automate repetitive
work with scripts, or let an agent use the same commands. No agent, model, or AI
account is required. MCP is an optional interface.

> [!NOTE]
> This project shipped as `godot-mcp` through 0.12. That name described one
> connector, and the toolkit automates Godot from a terminal, a shell script, or
> a connected client, with MCP as one optional interface. The old name also
> matched many other Godot MCP projects. Swallowtail names the toolkit itself.
> The repository URL, the Go module path, and the `godot-mcp` executable are
> unchanged, with no scheduled removal date.

Use `swallowtail` for new commands and scripts. Release bundles also include the
deprecated `godot-mcp` executable with identical functionality. Preview an existing
project's addon migration with `swallowtail migrate --project DIR`.
See [Migrating to Swallowtail](https://regiellis.github.io/godot-mcp-go/docs/migration).
The project is MIT licensed.

[Terminal quickstart](https://regiellis.github.io/godot-mcp-go/docs/quickstart) ·
[Scripting and CI](https://regiellis.github.io/godot-mcp-go/docs/automation) ·
[Command reference](https://regiellis.github.io/godot-mcp-go/docs/commands) ·
[Releases](https://github.com/regiellis/godot-mcp-go/releases)

## Your game. Your workflow.

- **Run commands:** inspect a scene, change a property, validate it, and play the result.
- **Automate your workflow:** turn repeatable work into shell scripts, checks, and playtests.
  Use JSON output and exit codes to connect the steps.
- **Add your own commands:** drop a GDScript file into `res://mcp_commands/` and it
  shows up in the CLI, in help, and as an MCP tool.
  See [Add your own commands](https://regiellis.github.io/godot-mcp-go/docs/extending).
- **Connect your tools:** expose the same operations through the CLI or an MCP client.
  Choose the task and review what changes.

From a project with the addon enabled:

```sh
swallowtail scene tree
swallowtail scene validate --path res://hello.tscn
swallowtail scene play --mode res://hello.tscn
swallowtail runtime tree
swallowtail scene stop
```

The [quickstart](https://regiellis.github.io/godot-mcp-go/docs/quickstart) builds
that scene from an empty project. Godot 4.7.2 is the current development build.

## Working with Godot's built-in CLI

Godot already includes a command-line interface for launching the engine, running
scripts, importing assets, and exporting projects. Swallowtail uses your installed
Godot engine for those operations and adds commands that work with the live
editor session and running game.

| Job | How Swallowtail handles it |
| --- | --- |
| Import, check, test, export, run | Invokes Godot and reports results for shell workflows |
| Inspect and edit scenes | Connects to the editor addon and operates on the live session |
| Playtest | Reads runtime state, sends input, captures frames, and checks behavior |
| Discover APIs | Queries the running engine's ClassDB and command catalog |

Godot is installed separately. See [Godot's command-line reference](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)
and [How it works](https://regiellis.github.io/godot-mcp-go/docs/how-it-works).

## CLI first, MCP optional

Run commands from your terminal, reuse them in scripts, or add them to CI.
Read the results directly, or pipe JSON into your next step.

MCP connects clients that use that protocol to the same command handlers. It is
available through `serve` over stdio or the editor's HTTP endpoint. Neither is
required for ordinary CLI use.

For MCP clients, the default typed catalog can be large. `serve --typed=false`
exposes one generic tool when that suits the client better. See
[MCP setup](https://regiellis.github.io/godot-mcp-go/docs/mcp-setup) and
[tool context costs](https://regiellis.github.io/godot-mcp-go/docs/context-cost).

## How it compares

What each tool documents: how you start, what you set up, and what you can run
from a terminal, a script, or an MCP client. Sources and the comparison date
follow the table.

| What you need | Swallowtail | Godot AI | Godot MCP Native |
| --- | --- | --- | --- |
| Starting point | **Standalone automation CLI + editor addon** | MCP integration for the editor | MCP editor addon + companion CLI |
| Run from your terminal | Use `swallowtail` directly, without MCP | Documented setup uses `godot-ai attach` to connect an MCP client | Use `gdmcp` through its separate local CLI API |
| Use without an AI agent | **Yes.** The CLI and scripts need no agent, model, or account | Its requirements list an MCP client; every documented workflow runs through one | Yes, through its `gdmcp` CLI, which the docs present for agents with shell access |
| Set up the connection | Go binary + Godot addon for live commands | Python server via uv + Godot plugin + MCP client | Godot addon; prebuilt CLI for terminal use |
| Automate a workflow | Create projects, import, check, test, export, and operate the live editor | Edit scenes and scripts, run projects and test suites through MCP tools | Discover tools, run domain commands, and preview or apply command batches |
| Inspect a playtest | Runtime state, input, captures, breakpoints, stepping, and hot reload | Game state, input sequences, screenshots, and error logs | Runtime probe, breakpoints, stack and variable inspection, and execution control |
| Connect an MCP client | Optional stdio or editor-hosted HTTP interface | Documented primary workflow | MCP interface alongside the separate CLI API |

Compared against the published documentation on September 7, 2026:
[Godot AI](https://github.com/hi-godot/godot-ai),
[its tool reference](https://github.com/hi-godot/godot-ai/blob/main/docs/TOOLS.md),
[Godot MCP Native](https://github.com/yurineko73/Godot-MCP-Native), and
[its CLI reference](https://github.com/yurineko73/Godot-MCP-Native/tree/main/cli/gdmcp).
This summarizes documented workflows, not an exhaustive feature audit.

## Why I built Swallowtail

*A note from the maintainer.*

After twenty years as a programmer, I just wanted to build games. Games for my
son. Games for myself.

I don't have the budget to hire a team for every idea. I also don't want to spend
ten years on one uncertain project at the expense of my health or my family.
Swallowtail grew out of finding a way to make progress with the time and resources
I have.

What I wanted was a toolkit that lets me work the way I want on any given day, and
that includes using AI as one of the tools. Some days that is a terminal and a
script I can run again. Some days it is an agent driving the editor while I review
what it changed. Swallowtail gives both the same commands, so the choice stays
mine: what to try, what to keep, and when to stop and play it.

I understand the concerns about this technology. I'm not OpenAI, Anthropic, or
NVIDIA. I'm an individual programmer making games. You don't have to agree with
my choices, and I respect that. I'm here to build and share, not to fight.
Questions and criticism are welcome. Bullying and personal attacks aren't.

[The full note](https://regiellis.github.io/godot-mcp-go/docs/on-ai) covers the
project's purpose and what the toolkit requires.

## Samples

[Reversi](https://github.com/regiellis/godot-reversi) is a complete game built by
agents driving swallowtail: eleven screens, thirty GDScript files, every widget
drawn in code. [Play it in the browser](https://regiellis.github.io/godot-reversi/)
or clone the repository. Smaller demos live under [`samples/`](samples/), and the
[Samples page](https://regiellis.github.io/godot-mcp-go/docs/samples) lists them all.

## Contributing

This repository is a one-way public mirror with squashed history. Open an
[issue](https://github.com/regiellis/godot-mcp-go/issues) or
[discussion](https://github.com/regiellis/godot-mcp-go/discussions) for bugs,
questions, or proposed changes. Pull requests cannot be merged directly into the
canonical development history.

The `asset-library` branch is an addon packaging snapshot. Maintainer-only
`scripts/`, internal docs, and eval harnesses are omitted from the public mirror;
Taskfile tasks that depend on those files are maintainer-only.

## How it works

```
swallowtail (Go CLI / client)  ──WebSocket(JSON-RPC 2.0):9080──▶  Godot editor addon (server)
MCP client (streamable HTTP) ──POST /mcp:9100────────────────▶        │
                                            file IPC (user://) ◀──────┘──▶  running game
                                                              (MCPGameInspector / MCPGameInput autoloads)
```

- The **addon runs a WebSocket server inside the editor** (the long-lived process). The CLI is a short-lived client that dials in, runs one command, and exits.
- The CLI **auto-discovers the port** from `<project>/.godot/swallowtail.json` (written by the addon) when run inside the project; otherwise pass `--port` (default `9080`).
- **`runtime`/`input` commands reach the *running* game** via file IPC brokered by two game-side autoloads, or, for a standalone **debug build** with no editor open, over the game's own direct server (`swallowtail --game …`, opt-in project setting). Either way you can inspect the live scene tree, read/set node state, capture frames, and simulate input.
- Supported scene edits use Godot's **UndoRedo**. Review script and file changes in version control.

## Requirements

- **Godot 4.7** (launch with `godot`), the version this is developed and released against. **4.3 through 4.8** work in beta.
- **Go 1.26+** to build the CLI.
- [Task](https://taskfile.dev) (optional but recommended) for the dev workflow.

> [!IMPORTANT]
> **4.7 is the target; 4.3 is the floor, in beta.** The addon loads and serves on Godot 4.3 through 4.8. Registration is per group, so an engine that can't compile a group skips it and lists it under `unavailable_groups` in `engine.commands`, and the six APIs newer than 4.3 (`scene close`, unsaved-tab reporting, `csg bake`, the AGX tonemap, runtime error capture) refuse with the version they need. The 3.x line is out of scope: convert with Godot's own `--convert-3to4` first.
>
> **Builds this release was run against:** the official **4.3.0**, **4.4**, **4.5**, and **4.6** stables, a headless editor per version against its own copy of the project, each registering all 332 commands with `unavailable_groups` absent and the game IPC live; `4.7.1-rc` (`d6096250e`) and `4.7.2-rc` (`36a04fe52`); and a `4.8-dev` build from `master` (`eda2a482e`, after dev 2). On 4.8 the addon runs unmodified, with every command of that build registering and no parse or compile errors, and `engine.search` picks up 4.8's `FuzzySearch` automatically. 4.8 writes a `unique_id` attribute into saved scenes that 4.7 does not, so a project saved by 4.8 is not round-trip clean back to 4.7; that is an engine format change, not an addon one.
>
> Moving a project between versions: [Porting between Godot versions](https://regiellis.github.io/godot-mcp-go/docs/guides/porting-godot-versions) (beta).

> [!NOTE]
> **C# / .NET?** Supported. The `csharp` group scaffolds and builds .NET projects (`csharp.info` / `csharp.setup` / `csharp.build`), and `script.*` is C#-aware: `script.create` writes a C# class template for `.cs` paths, `script.validate --path X.cs` compiles with per-file structured diagnostics, and `script.list` recognizes C# classes. *Running* C# scripts in-editor requires a Godot **.NET editor build** plus the dotnet SDK (`swallowtail doctor` checks for it); `editor.run_script` / `runtime.eval` execute GDScript either way, and the introspection layer is language-agnostic.

> **Windows note:** if the editor ever crashes with `ERROR: WASAPI: GetBufferSize`, another app has taken *exclusive* control of your audio device (Chrome on resume is a common culprit). Turn off exclusive mode in Windows Sound settings (Device properties → Advanced → uncheck "Allow applications to take exclusive control"). It's an OS/audio issue, not this addon. (`--audio-driver Dummy` also sidesteps it if needed.)

## Build

```sh
task build          # -> bin/swallowtail(.exe)
# or:
go build -o bin/swallowtail ./cmd/swallowtail
```

## Install into a project

From an unpacked release bundle, install the addon (and the agent skill) into any Godot project in one step:

```sh
swallowtail install --project /path/to/your/project --enable
```

Starting from nothing? Bootstrap a fresh Godot 4.7 project and wire the addon in one command:

```sh
swallowtail create --path ./mygame --install --enable
```

Copies `addons/swallowtail/` and `.claude/skills/swallowtail/` in and enables the plugin in `project.godot`. See [INSTALL.md](INSTALL.md) for flags and the manual alternative.

> [!WARNING]
> **`install --enable` was broken in 0.6.0 through 0.8.2.** On those versions the installer enabled the plugin without writing the two game-side autoloads, so every `runtime.*` and `input.*` command failed on a fresh install while the editor-side commands worked. If a project was installed by an affected version, toggle the plugin off and back on in **Project Settings > Plugins**, which injects the pair; `swallowtail doctor` reports the missing entries and the repair command. Current builds write them at install time.

> [!CAUTION]
> **Before you ship:** the addon is development tooling. Disable the plugin and add `addons/swallowtail/*` to every export preset's exclude filter so it never rides into an exported game. [Before you ship](https://regiellis.github.io/godot-mcp-go/docs/before-you-ship) has the two steps and the scan that proves they worked; [INSTALL.md](INSTALL.md#before-you-ship) carries the same steps offline.

## Quick start

1. Open the test project (or your own with the addon installed) in Godot 4.7+:
   ```sh
   task editor          # godot --path project --editor
   ```
   From an installed CLI, `swallowtail launch` opens one editor for the project it is run in, refuses to stack a second on a running one, and logs the editor's output to `.godot/swallowtail-launch.log` rather than the terminal. Add `--headless` for a windowless session.
   Ensure the **Swallowtail** plugin is enabled (Project → Project Settings → Plugins). The addon prints `[MCP] Server listening on ws://127.0.0.1:9080`.
2. From inside the project directory, drive it:
   ```sh
   swallowtail project info
   swallowtail scene tree
   swallowtail node add --type Sprite2D --name Player --parent-path .
   swallowtail node set --node-path Player --property position --value "Vector2(100, 200)"
   ```

### Discover, then drive

Because the CLI talks to the *live* engine, you can ask it what your engine build actually supports instead of guessing:

```sh
swallowtail engine search --query offset_transform          # find members across all classes
swallowtail engine class-info --class Control --filter transform
swallowtail engine doc-search --query "wrap text"           # search the docs prose by concept
swallowtail engine docs --class Label --member autowrap_mode  # read what it means
```

Even with no typed wrapper, `node.set`/`node.get` work on any property the live node exposes, and `editor.run_script` / `runtime.eval` run arbitrary GDScript, so any property or callable the running build exposes is reachable, whatever its version.

### Playtest loop

```sh
swallowtail scene play --mode main
swallowtail runtime tree
swallowtail input action --action ui_accept --pressed true
swallowtail runtime get --node-path Player --properties '["position"]'
swallowtail runtime screenshot --save-path user://shot.png
swallowtail scene stop
```

## Use as an MCP server

`swallowtail serve` runs as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, so MCP clients (Claude Desktop, Claude Code, …) can drive Godot directly. By default every command is a **typed MCP tool** with a real schema built live from the addon's param docs; `godot_run` remains the generic escape hatch (`{ "method": "<group>.<command>", "params": {...} }`, the same surface as the CLI), and `serve --typed=false` keeps tool-limited clients on that single tool. `godot_run` and the typed `runtime_*`/`input_*` tools accept `game: true` to drive a standalone debug-build game with **no editor open**. The model discovers the running engine's API with `engine.search`/`engine.class_info` and then acts.

Example client config:

```json
{
  "mcpServers": {
    "swallowtail": {
      "command": "swallowtail",
      "args": ["serve", "--project", "/path/to/your/project"]
    }
  }
}
```

`--project` sets where the server discovers the addon port. If the editor is down when the client connects, `serve` starts with the generic `godot_run` tool alone and adds the typed tools once the editor answers. To drive an editor on another machine, forward its loopback port over SSH; [Reach an editor on another machine](https://regiellis.github.io/godot-mcp-go/docs/mcp-setup#reach-an-editor-on-another-machine) has the commands for Windows, Linux and macOS.

`serve` also ships **MCP prompts**: the durable playbooks (`discover-then-drive`, `spatial-placement`, `launch-recovery`, `bug-hunt`) as first-class prompts your client can pull with `prompts/get`, served even when the editor is down. Those sit alongside the read-only `godot://` resources and the `instructions` string every connect carries.

### Or connect straight to the editor (no binary)

The addon itself hosts a **streamable-HTTP MCP endpoint** inside the editor at `POST /mcp` on `127.0.0.1`, auto-port **9100-9115** (the actual port is in `<project>/.godot/swallowtail.json` as `http_port`; pin one with the `swallowtail/network/http_port` project setting or `SWALLOWTAIL_HTTP_PORT`). Any MCP client that speaks streamable HTTP connects with no external process:

```json
{
  "mcpServers": {
    "swallowtail": {
      "url": "http://127.0.0.1:9100/mcp"
    }
  }
}
```

Same tool surface as `serve` (the generic `godot_run` plus typed per-command tools), same guards. Set `swallowtail/network/http_typed` to `false` in Project Settings to list only `godot_run` for tool-limited clients, or `swallowtail/network/mcp_http` to `false` to turn the endpoint off.

## Live dashboard (opt-in)

`swallowtail dashboard` starts a small web UI that shows live activity across every client on the wire: the CLI, `serve`/MCP, the editor's HTTP endpoint, and anything else you have connected. It reports tool calls, error rate, per-group breakdown, active connections, uptime, and a recent-activity feed. The page (htmx + anime.js) and its assets are embedded in the binary; no Node/build step.

```sh
swallowtail dashboard --port 8090     # then open http://127.0.0.1:8090
```

Run it from inside your project dir (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`. It holds a single persistent connection and polls the addon's `stats.snapshot`.

The same dashboard also lives **inside the editor**: the addon docks a **Swallowtail panel** (right side, movable like any dock) with the same numbers: stat tiles, error banner, top groups, recent errors, and the live timeline with filters. It reads them in-process from the addon, so it needs no extra process and no port. The web UI stays for watching from outside the editor; the dock is there while you work.

## Build on it

The CLI is built to be scripted. The contract: piped results on stdout as JSON (`--format tsv|ndjson` for shell tools, `SWALLOWTAIL_FORMAT` to pin one per shell; a terminal gets color-coded tables instead, never a pipe), errors on stderr with JSON-RPC codes, exit codes `0`/`1`/`2`, port discovery from the project directory, and `doctor`/`status` as scriptable preflights. The editor-less subcommands are built for the same contract: `import`, `check`, `export`, and `run` exit with a code CI can branch on and return structured errors rather than a log to grep. The catalog itself is queryable JSON, and `engine commands --docs` returns every command with typed params, so generators and UIs read the command list instead of hardcoding one. Underneath it all is a stable JSON-RPC-over-WebSocket wire that any language can speak: a Python script, a browser panel, a QA rig driving a standalone game via `--game`.

```bash
# hide every Label in the edited scene
swallowtail batch find-nodes-by-type --type Label | jq -r '.matches[].path' \
  | while read -r p; do swallowtail node set --node-path "$p" --property visible --value false; done
```

Worked examples (a CI smoke test, a Python client, a working browser panel): [Scripting and CI](https://regiellis.github.io/godot-mcp-go/docs/automation/) · [Your own tools and UIs](https://regiellis.github.io/godot-mcp-go/docs/building-on-top/).

## Command groups

`analysis` `android` `anim_tree` `animation` `audio` `authoring` `batch` `camera` `cleanup` `csg` `csharp` `doc` `editor` `engine` `export` `fs` `gridmap` `import` `input` `input_map` `lighting` `localization` `material` `mesh` `multiplayer` `navigation` `node` `particles` `path` `pcg` `physics` `profiling` `project` `resource` `runtime` `scatter` `scene` `scene2d` `scene3d` `script` `shader` `skeleton` `spatial` `test` `theme` `tilemap` `ui` `wfc`

Invocation is `swallowtail <group> <command> [--flag value ...]`. Names accept kebab- or snake-case; values that start with `[`/`{` are parsed as JSON. On error the CLI prints the JSON-RPC code, message, and any suggestions to stderr. Explore the catalog from the CLI itself: `swallowtail help all` lists every group's commands, `swallowtail <group> --help` narrows to one group, and `swallowtail <group> <command> --help` prints that command's param table.

## Agent skill

`skills/swallowtail/SKILL.md` is a Claude Code skill that teaches an agent to use the CLI well: the discover-then-drive loop, Godot's node/scene composition style, the command groups, core workflows, and pitfalls. Drop it into a project's `.claude/skills/` so an agent starts with the loop, the groups, and the pitfalls already loaded.

## Layout

```
cmd/swallowtail/                 Go CLI entry
internal/{protocol,client}/    JSON-RPC envelope + WebSocket client/discovery
project/                       Godot 4.7 test project (run with godot)
project/addons/swallowtail/      the GDScript addon (commands/, services/, utils/)
skills/swallowtail/SKILL.md      the agent skill
Taskfile.yml                   dev tasks (run `task` to list)
```

Command implementations live in `project/addons/swallowtail/commands/` (each group a `*_commands.gd`), registered in `command_router.gd`; add a command by registering a handler there. The `services/` autoloads broker the running-game IPC.

## License

MIT. See [LICENSE](LICENSE).
