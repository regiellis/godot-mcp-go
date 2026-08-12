---
title: Live dashboard
description: An opt-in web UI showing live activity across every client talking to the addon.
---

`godot-mcp dashboard` starts a small web UI that shows live activity for **everything** flowing through the addon: the CLI, the `serve` / MCP path, and any other client. It reports tool calls, error rate, a per-group breakdown, active connections, uptime, and a recent-activity feed.

```bash
godot-mcp dashboard --port 8090     # then open http://127.0.0.1:8090
```

The page and its assets are embedded in the binary. No Node, no build step. Run it from inside your project directory (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`.

It holds a single persistent connection and polls the addon's `stats.snapshot`, so it observes activity without competing with the agent for the editor's main thread.

## The in-editor panel

The same dashboard is built into the addon as an editor dock named **MCP**, on the right side by default and movable like any dock. It shows the same numbers: the stat tiles, an error banner when a recent call failed, the top command groups, recent errors, and the live timeline with filter chips. Living inside the editor also buys it things the web page cannot have. It reads the stats in-process (no extra process, no port, no polling cost while the dock is closed), full call parameters ride on each row's tooltip, and a Reset button clears the counters. The panel follows your editor theme; the one constant is the blue.

Use whichever fits the moment: the dock while you work in the editor, the web page when you watch a session from outside it. Both read the same counters, so they always agree.
