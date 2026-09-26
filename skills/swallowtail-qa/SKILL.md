---
name: swallowtail-qa
description: "Playtest Godot games and exported builds, capture frame spikes, compare QA baselines, and produce Swallowtail branded reports. Use for release QA and reusable game-specific test scenarios, not routine implementation-only unit tests."
---

# Swallowtail Game QA

Use the local `swallowtail qa` commands. Read [the command and extension contract](references/workflow.md) before creating a scenario. The CLI embeds the runner, mascot, fonts and PDF template. Python 3.10+ is required; PDF generation additionally needs ReportLab 4 (`SWALLOWTAIL_PYTHON` selects the interpreter). Do not install dependencies globally without considering the project's environment.

Establish the release target, build provenance, intended platforms, representative gameplay, and explicit acceptance criteria from the request and repository. Progress with available evidence; ask only for material missing information. Export locally when authorized. Publishing or store uploads are separate actions.

Run against isolated test saves. The worker isolates Windows APPDATA/LOCALAPPDATA and Linux XDG directories. Check games using custom paths, macOS saves or cloud synchronization before assuming isolation. Retain original saves and fixtures.

Keep source and packaged evidence distinct. `qa run` source mode injects a SceneTree runner and calls the game's GDScript `run(qa)` scenario. Package mode launches the exact executable without script injection. Hardened exports can ignore `--script` or refuse `--path`; an exit-zero launch is not proof an injected test ran. Missing scenario receipts fail source runs. Never put QA addons into a player build solely to get a green test.

Choose checks that cover the game's actual release risks: normal boot, repeated transitions, representative gameplay and restart, input/focus, pause/settings, save/reload, clean exit. Extend a small game-owned GDScript scenario with `qa.check`, `qa.phase`, `qa.wait`, and `qa.screenshot`; reuse the project's existing fixtures and custom-command logic where appropriate. Editor-only `mcp_commands/*.gd` remain editor extensions, not packaged tests.

For timing, separate cold boot, first entry, repeated entries, steady gameplay, and teardown. Keep capture resolution, renderer, vsync, power state and hardware recorded. PresentMon is optional Windows capture; process-frame timing is a different measurement. Name screenshot phases separately because reading back pixels can stall a frame. Keep raw CSVs, including spikes. Do not infer CPU/GPU causes from frame duration alone; use source profiler attribution as a separate experiment.

Treat the full process log as evidence, including diagnostics printed after a PASS receipt and during shutdown. A timeout, engine error, missing receipt or missing requested capture is a failure. Pending manual checks mean incomplete coverage. Use `qa attest` only with an actual observed or user-reported result, named check and substantive evidence. Never fabricate visual, audio, controller, accessibility or hardware coverage.

Before an operator-driven capture, establish that the operator can see and interact with the exact game window. A Ready response before launch, a live PID, a boot log or presentation events do not prove visibility. If the window is unavailable, retain process data with that limitation and leave manual checks pending; do not label the trace gameplay. A later operator correction supersedes an earlier form response and must be recorded in the run and regenerated report.

Compare only compatible runs with `qa compare`; environment or scenario changes make a baseline incompatible. Explain differences rather than relaxing matching to force a result. Use explicit game-specific budgets; a single machine does not establish minimum hardware support. Retain the approved baseline as an immutable run directory and compare new runs to it.

Generate the branded PDF with `qa report`, inspect rendered pages, and verify that screenshots, labels, hashes, findings and limits match the raw evidence. Append follow-up results to an existing launch report when requested; preserve historical failures as resolved history rather than deleting them. Summarize actionable findings with reproduction, severity, evidence, owning repo/file, fix and retest status.

For every test or clearly named test group, conclude what the result establishes, whether a fix is verified, what remains, and the evidence needed to close it. Include a prominent ship-readiness assessment with rationale, required work, follow-up, owners and closure criteria. Distinguish demonstrated stop-ship defects from coverage gaps and proposed acceptance budgets. Use `qa report --assessment` for specific editorial conclusions; green test receipts alone do not mean ready to ship.

Finish with the tested package location/hash, checks and frame results, unresolved coverage, report location, and any upstream changes. Report which files and commands implement a new test baseline so the next game can extend it without copying game-specific assumptions into Swallowtail.
