# Security

## What this tool is, before anything else

godot-mcp exists to let a local client drive a running Godot editor, and the command surface
includes `editor.run_script` and `runtime.eval`. **Enabling the plugin grants any process that
can reach the loopback listener code execution inside the editor.** That is the feature, not a
flaw in it.

So the honest summary: while the editor is open with the plugin enabled, treat it as reachable
by anything running on that machine. The design assumes a workstation you control. If that
assumption does not hold for your setup, quit the editor when you are not driving it. Disabling
the plugin stops both transports.

The full reasoning is in the [threat model](https://regiellis.github.io/godot-mcp-go/docs/how-it-works/#threat-model).

## Supported versions

The latest release only. This is a solo project; there are no maintained release branches, and
fixes land on `main` and ship in the next tag.

| Version | Supported |
| --- | --- |
| latest release | yes |
| anything older | no |

## What is worth reporting

Anything that widens the blast radius beyond "a local process can drive the editor":

- A way for a **remote host** to reach either server. Both bind `127.0.0.1` and never `0.0.0.0`;
  a path that changes that is a bug.
- A way for a **web page** to reach the HTTP MCP endpoint. Every request is gated on `Origin`,
  and only an absent header or a genuine loopback origin passes. A bypass of that gate is a real
  vulnerability, and one has already been found and fixed (0.5.0: the loopback host was matched
  by string prefix, so an attacker-registrable domain like `127.evil.com` passed).
- A **path escape**: any command that writes outside `res://` or `user://`, or that resolves a
  `..` traversal past the project root, despite the `guard_project_path` check.
- A **code-execution path that skips the audit or the editor guard**. `editor.run_script` and
  `runtime.eval` are logged before they run, and the editor-side path additionally refuses
  direct write APIs without an explicit opt-in flag.
- A way for the **release or install path** to place files outside the target project, or to
  execute anything during install.

## What is already known, and is not a bug report

These are documented design decisions. A report that restates one will be closed with a link
here.

- **The WebSocket transport is unauthenticated and cannot check `Origin`.** Godot exposes no
  handshake headers to a GDScript server, and browser WebSockets are exempt from CORS, so a page
  can open a socket to the editor while it is running. This is an accepted limitation. Closing it
  needs a rotating secret threaded through the CLI, the MCP server, and every hand-written
  client, and that cost is not currently judged worth the exposure on a private workstation. A
  concrete environment where the assumption fails is what would reopen it, and
  [the discussion](https://github.com/regiellis/godot-mcp-go/discussions/1) is the place for that.
- **The ports are fixed and published.** The ranges are 9080 to 9095, 9100 to 9115 and 9200 to
  9215, and the editor writes the bound port into a discovery file inside the project. Nothing
  relies on a port being hard to guess, and it should not.
- **`runtime.eval` does not carry the editor's write guard.** It runs in the launched game's own
  process over IPC, not in the editor, so the editor guard does not apply by design.
- **A local process can read the discovery file.** It is a plain JSON file in the project's
  `.godot/` directory. Anything that can read it could have connected anyway.

## Reporting

Use GitHub's private vulnerability reporting on this repository: **Security → Report a
vulnerability**. That opens a private advisory that only the maintainer can see.

Please do not open a public issue for something that is exploitable and not already listed above.

Include what you would want to receive: the version or commit, the transport (WebSocket or HTTP),
the exact request or origin, and what you observed. A one-line reproduction is worth more than a
long description.

## What to expect

One maintainer, best effort, no service level agreement. Realistically: a reply within a week,
and a fix in the next release if it is confirmed. Credit in the changelog unless you would rather
not be named.

This repository is a **one-way public mirror**, so pull requests cannot be merged. A patch is
still welcome as a diff in the advisory thread; it will be applied upstream with attribution.
