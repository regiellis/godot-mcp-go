# Godot MCP/CLI

Drive the Godot editor you already have open, from an AI agent or from a terminal. The addon hosts
two local servers inside the running editor:

- a WebSocket server on `127.0.0.1`, first free port in 9080 to 9095, which the `godot-mcp` command
  line tool connects to;
- a streamable-HTTP MCP endpoint at `POST /mcp` on `127.0.0.1`, first free port in 9100 to 9115,
  which an HTTP-capable MCP client connects to directly with no extra process running.

Both dispatch the same 316 commands across 49 groups: scenes, nodes, GDScript and C#, spatial
placement, materials, tilemaps, animation, physics, procedural generation, and live inspection of
the running game. Every editor mutation goes through `UndoRedo`, so Ctrl+Z reverses it.

## Setup

1. Copy `addons/godot_mcp/` into your project.
2. Enable **Godot MCP/CLI** under Project, then Project Settings, then Plugins.
3. The Output panel prints the bound port, for example `[MCP] Server listening on ws://127.0.0.1:9080`.

Enabling the plugin also installs two autoloads, `MCPGameInspector` and `MCPGameInput`, which the
`runtime` and `input` command groups need to reach a running game. Disabling the plugin
removes them again.

The bound ports are written to `<project>/.godot/godot-mcp.json`, so a client can find the editor
without configuration. Pin them with the `godot_mcp/network/port` and `godot_mcp/network/http_port`
project settings, or the `GODOT_MCP_PORT` and `GODOT_MCP_HTTP_PORT` environment variables.

## Requirements

Godot 4.7 or newer, run against `4.7.1-rc`, `4.7.2-rc`, and a `4.8-dev` build from master. The addon alone is enough for an HTTP-capable MCP client. The command line tool
and the agent skill are separate downloads from the repository releases.

## Security

Both servers bind `127.0.0.1` only, never `0.0.0.0`. The HTTP endpoint also validates the `Origin`
header, so a page open in a browser cannot reach it. The ports carry no authentication by design,
which is what makes zero-configuration discovery work, so treat a running editor as reachable by
other processes on the same machine and quit it when you are not driving it.

## License

MIT. See the LICENSE file beside this one.
