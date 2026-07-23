---
title: Live dashboard
description: An opt-in web UI showing live activity across every client talking to the addon.
---

`godot-mcp dashboard` starts a small web UI that shows live activity for **everything** flowing through the addon: the CLI, the `serve` / MCP path, and any other client. It reports tool calls, error rate, a per-group breakdown, active connections, uptime, and a recent-activity feed.

```bash
godot-mcp dashboard --port 8090     # then open http://127.0.0.1:8090
```

The page and its assets are embedded in the binary, so there is no Node or build step. Run it from inside your project directory (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`.

It holds a single persistent connection and polls the addon's `stats.snapshot`, so it observes activity without competing with the agent for the editor's main thread.
