# Swallowtail

Give an AI agent the complete Godot development loop from a terminal or MCP client: discover the
live engine, build in the open editor, run and play the game, observe state, debug failures, fix
them, and verify the result. The addon hosts two local servers inside the running editor:

- a WebSocket server on `127.0.0.1`, first free port in 9080 to 9095, which the `swallowtail` command
  line tool connects to;
- a streamable-HTTP MCP endpoint at `POST /mcp` on `127.0.0.1`, first free port in 9100 to 9115,
  which an HTTP-capable MCP client connects to directly with no extra process running.

Both enter the same workflow. Structured commands cover scenes, nodes, GDScript and C#, spatial
placement, materials, tilemaps, animation, physics, procedural generation, live game control, and
debugging. Generic ClassDB discovery and node access keep the workflow open to engine features
without a dedicated command. Every editor mutation goes through `UndoRedo`, so Ctrl+Z reverses it.

## Setup

1. Copy `addons/swallowtail/` into your project.
2. Enable **Swallowtail** under Project, then Project Settings, then Plugins.
3. The Output panel prints the bound port, for example `[MCP] Server listening on ws://127.0.0.1:9080`.

Enabling the plugin also installs two autoloads, `MCPGameInspector` and `MCPGameInput`, which the
`runtime` and `input` command groups need to reach a running game. Disabling the plugin
removes them again.

The bound ports are written to `<project>/.godot/swallowtail.json`, so a client can find the editor
without configuration. Pin them with the `swallowtail/network/port` and `swallowtail/network/http_port`
project settings, or the `SWALLOWTAIL_PORT` and `SWALLOWTAIL_HTTP_PORT` environment variables. Older
tooling still works: the addon also writes `.godot/godot-mcp.json` and reads the `godot_mcp/` settings
and `GODOT_MCP_` variables.

## Requirements

Godot 4.7 is the target and 4.3 is the floor, in beta: run against the 4.3.0, 4.4, 4.5 and 4.6
stables, `4.7.1-rc`, `4.7.2-rc`, and a `4.8-dev` build from master. A group needing a newer API is
skipped and listed under `unavailable_groups` in `engine.commands`. The addon alone is enough for an
HTTP-capable MCP client. The command line tool and the agent skill are separate downloads from the
repository releases.

## Security

Both servers bind `127.0.0.1` only, never `0.0.0.0`. The HTTP endpoint also validates the `Origin`
header, so a page open in a browser cannot reach it. The ports carry no authentication by design,
which is what makes zero-configuration discovery work, so treat a running editor as reachable by
other processes on the same machine and quit it when you are not driving it.

## License

MIT. See the LICENSE file beside this one.
