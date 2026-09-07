---
title: Live dashboard
description: Watch activity, inspect failures, and export diagnostics from the Swallowtail dock or web dashboard.
---

`swallowtail dashboard` starts a small web UI that shows live activity for **everything** flowing through the addon: the CLI, the `serve` / MCP path, and any other client. It reports tool calls, error rate, a per-group breakdown, active connections, uptime, and a recent-activity feed.

```bash
swallowtail dashboard --port 8090     # then open http://127.0.0.1:8090
```

The page and its assets are embedded in the binary. No Node, no build step. Run it from inside your project directory (it discovers the addon port like the CLI), or pass `--project DIR` / `--addon-port N`.

It holds a single persistent connection and polls the addon's `stats.snapshot`, so it observes activity without competing with the agent for the editor's main thread.

## The in-editor panel

The **Swallowtail** dock sits on the right by default and moves like any editor dock. Its butler illustrations, speech bubbles, and mulberry accent follow your editor's light or dark theme. It shows call counts, recent errors, command groups, and a timeline with group and error filters. It reads activity directly inside the editor and pauses refreshes while hidden.

**Setup** shows this project's connection endpoints and CLI setup guidance. Zero connected peers is normal between CLI calls: each command opens its own connection. Optional HTTP MCP clients do not count as persistent WebSocket peers.

Choose **Details** on the warning bubble or **View** beside a recent error to inspect the error code, message, and available diagnostic data. **Copy details** copies that record. **Copy plan** copies a single-step JSON plan for [`swallowtail automate`](/docs/automation#run-a-command-plan), using the recorded parameters. Review and correct the plan before running it; copying does not execute anything.

You can also click a failed timeline row, or focus it and press Enter, to open its details. In a narrow dock, the timeline gives space to method names and durations; timestamps and group information remain in the row tooltip.

Requests that were truncated or had common credential fields redacted cannot be copied as runnable plans. Retained request and error details are bounded to 16 KiB each. Error data may include a truncation marker. Redaction covers common credential field names, not arbitrary secrets embedded in scripts or strings; review reports before sharing them.

**Export activity** saves a JSON report wherever you choose. It contains the capture time, project path, engine version, session counters, and up to 50 recent calls. **Reset** clears the session's counters and recorded activity after confirmation.

Use whichever fits the moment: the dock while you work in the editor, the web page when you watch a session from outside it. Both read the same counters, so they always agree.
