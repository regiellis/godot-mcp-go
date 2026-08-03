# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.7.1] — 2026-08-03

Forward-compatibility work: the addon is verified on Godot 4.8-dev, and
`engine search` picks up 4.8's new fuzzy matcher when it is there.

### Added

- **`engine search` falls back to fuzzy matching** when its substring sweep finds
  nothing and the running build exposes `FuzzySearch` (Godot 4.8+). An
  abbreviation an agent guessed now resolves: `linvel` reaches
  `RigidBody2D.linear_velocity`, `angvel` reaches `PhysicalBone3D.angular_velocity`,
  `glbpos` and `rotdeg` reach `Node3D`. `match_mode` in the result says which pass
  produced the matches. Substring stays the first pass, so a query that already
  worked keeps its previous speed and result, and on 4.7 the rescue is simply
  skipped.

### Verified

- **The addon runs unmodified on Godot 4.8-dev and on 4.7.2-rc**. 316 commands
  across 49 groups register on both, with no parse or compile errors. 4.8 adds a
  `unique_id` attribute to every node in saved scenes and drops `load_steps` from
  the header; `fs.move` is unaffected because it rewrites quoted path tokens
  across whole file text rather than parsing lines. 4.8's embedded Game View,
  on by default for new projects, does not affect the `runtime` channel: it
  reparents the game's window while the game stays a separate process.

### Documentation

- **A three-way comparison** in the README and on the landing page, against
  `godot-ai` and `Godot-MCP-Native` rather than one rival.
  Both are actively maintained and both run on Godot 4.5 and 4.6, which this
  project does not; Godot-MCP-Native reaches the running game through an in-game
  probe much as this project does, so that is no longer a dividing line. The
  differences that hold are structural, and each project gets its own paragraph
  of where it wins.
- **`discover-then-drive` documented the callable half**. The page claimed any
  feature surfaced as a property *or a callable* is reachable, then listed only
  the property commands; `node.call` and `runtime.call` are that missing half.

## [0.7.0] — 2026-08-03

Four commands (316 total, still 49 groups) and a craft reference, from reviewing
the public GDQuest and Brackeys repositories. Writing GDScript still needs no
tool beyond the editor.

### Added

- **`node call` and `runtime call`**, a generic method-invocation primitive for the
  edited scene and the running game. `node set`/`node get` already reached any
  property the running build exposes; calling a method meant `editor run-script`,
  which is arbitrary code execution to invoke one named call. Arguments coerce
  toward the method's declared signature, so `'["Vector3(1,0,1)"]'` arrives typed
  and a short `[5]` for a Vector3 is refused rather than silently zeroed; an
  unknown method errors with a did-you-mean. Both are audited. `node call` is
  **not** undoable and says so in its result, since UndoRedo cannot reverse
  arbitrary side effects. `lighting bake`, `csg bake`, and `navigation bake-mesh`
  are single-method wrappers that existed only because this was missing.
- **`script lint`, a native GDScript style linter** with no external dependency
  (`utils/gdscript_linter.gd`). All 17 rules from the official style guide: the 9
  naming rules at severity `error`, the rest as warnings. Findings carry `path`,
  `line`, `rule`, `severity`, and `message`; `--disable` takes rule names and
  rejects unknown ones with the full list; `# gdlint-ignore[-next-line] rule`
  suppresses in the source itself. The scan is comment- and string-aware, so
  `a == a` inside a string literal or a `#` inside quotes never trips a rule.
  Verified **identical** to GDQuest's `gdscript-formatter lint` across this
  addon's 61 files (22 findings, same file, line, and rule), using that tool as a
  test oracle; on a deliberately messy fixture it reports two more, both local
  `var` names the external tool misses and the style guide covers. This closes a real gap: agents wrote
  GDScript through `script create`/`script edit` with nothing ever judging the
  result, so `gdscript-style.md` was guidance rather than a check.
- **`script symbols`** reads one script's declared methods, properties, signals,
  and constants without pulling the file into context. It reaches scripts with no
  `class_name`, which `engine class-info` cannot — the ordinary case of a
  `player.gd` attached to a node. `--include-inherited` walks the base-script
  chain.
- **`ai-steering.md` craft reference**. Agent movement that reads as a creature
  rather than a cursor: accelerating toward a desired velocity instead of
  assigning it, arrive/flee/pursue/separation as summable forces, blending versus
  priority, facing, and 3D differences. Every recipe was driven against a live
  4.7 editor and verified numerically rather than by screenshot.
- **Input-action validation in `character-3d.md`**. A controller that reads an
  action nobody mapped does not error — `Input.is_action_pressed` on a missing
  action returns `false` forever, so the character silently never sprints and
  nothing says why. The guide now takes action names as `@export`s and checks
  them in `_ready`.

There is deliberately **no** `script format`. Reformatting safely needs a real
parser — a wrong linter prints a bad line, a wrong formatter corrupts source —
and the tree-sitter route would mean CGO, breaking the `CGO_ENABLED=0`
six-target cross-build. Linting was tractable without a parser; formatting is
not.

### Fixed

- **`script lint` reports which files do not compile**. Style rules read source,
  so they report on a file that does not parse — and zero findings there would
  read as clean, which is the opposite of the truth.
- **`no-else-return` reads the last statement, not the last line**. A
  `return success({` spanning eight lines ends on `})`, hiding the return; and a
  `break` nested inside a deeper `if` is not the branch's own last statement, so
  counting it flagged an `elif` that was required.
- **A `const` bound to `preload()`/`load()` accepts CONSTANT_CASE or
  PascalCase.** Both are idiomatic — a type when it holds a script, an asset when
  it holds a scene. Requiring CONSTANT_CASE flagged nine correct lines in this
  addon alone.
- **`engine class-info` and `script symbols` share one introspection helper**.
  `get_script_*_list()` walks the whole script chain, so a command group
  extending `base_command.gd` reported base_command's ~50 helpers as its own and
  listed overrides once per level.
- **`runtime eval`'s description said it returns a result**. The code runs inside
  a void function, so `return <value>` is a parse error; the description now says
  to call `emit(value)`.
- **`doctor`'s name column derives its width from the checks**, rather than a
  fixed pad a longer check name silently broke.

## [0.6.3] — 2026-08-01

Two addon fixes found by driving shader work against a live editor, plus
shipping guidance the install docs should always have carried.

### Fixed

- **`shader edit` and `shader create` hot-reload the material's cached shader
  in place.** The old path built a fresh `Shader` and took over the file's
  path, so every material kept referencing the stale copy: edits compiled but
  never rendered, and the next material save embedded the detached shader into
  the `.tres`, silently disconnecting the material from its file. Results now
  report `hot_reload` (`updated`, `blocked` when an open Shader Editor tab
  re-applies its own buffer, or `not_loaded`) and `compiled` from a uniform
  probe, so a broken edit is visible in the reply.
- **`editor screenshot` renders a fresh frame before capturing**. A minimized
  or unfocused editor stops redrawing, so the viewport texture could be hours
  old and every capture returned the same stale image while reporting success.

### Added

- **"Before you ship" guidance in README, INSTALL, and the docs site**.
  Disable the plugin before exporting (this removes the two injected
  autoloads) and exclude `addons/godot_mcp/*` in every export preset. The
  game-side autoloads poll IPC files each frame in release builds too, and
  `runtime eval` is an arbitrary-eval surface, so the addon must never ride
  into a shipped game. The shipping-export guide covers verifying a build by
  scanning the exported `.pck`.

## [0.6.2] — 2026-07-28

Another CLI-only patch, from the same corner as 0.6.1. The addon is unchanged.

### Fixed

- **`install` no longer copies the addon's dev context doc into your project**.
  It copied `addons/godot_mcp/` wholesale, so `addons/godot_mcp/CLAUDE.md` came
  along: repo-internal guidance with no business in a consumer project.
  `release.ps1` had always stripped it from packaged archives, so installing
  from a release was fine and installing from a source checkout was not. 0.6.1
  made checkout installs work without flags, which widened that path rather than
  narrowing it. The copy now applies the same rule the archive step does, at any
  depth and regardless of case, and names what it skipped rather than differing
  from its source in silence.

- `install` also warns when an **earlier** install left the file in your project.
  It only warns: the file is in your tree by then, possibly committed, and
  deleting things inside someone's project is not this command's call.

## [0.6.1] — 2026-07-28

A CLI-only patch. The addon is unchanged from 0.6.0; its version moves in step
with the bundle so Project Settings and the archive name agree.

### Fixed

- **`install` and `install-assets` no longer depend on the binary sitting in its
  bundle.** Both resolved their sources next to the executable and nowhere else.
  That is right for the release archive, where the binary sits beside `addons/`
  and `skills/`, and wrong for the flow `INSTALL.md` invited: it said to put the
  binary on your `PATH`, and copying it out of the bundle made the guide's own
  headline command fail with exit 1 and nothing installed. Candidate layouts are
  now walked against the executable's directory **and its parent**, so the
  archive behaves as before and a repo checkout resolves with no flags at all.
  The search stays anchored to the executable rather than the working directory
  on purpose: a cwd walk would resolve inside the *target* project and offer that
  project's own addon as the source, copying a directory onto itself.

- A binary separated from its bundle still cannot install an addon it
  does not carry, so that case still fails. It now lists every path it tried and
  names both remedies, instead of naming a single guess.

### Added

- **`install --skill-from DIR`**, the counterpart to `--from`. Only the addon had
  a source override, so from a repo checkout the agent skill could not be
  installed through the CLI at all.

### Changed

- `INSTALL.md` says which commands care where the binary lives (`install` and
  `install-assets`, which copy files shipped beside it) and which do not
  (everything else drives a running editor over a socket, so the binary works
  from anywhere once the addon is in the project).

## [0.6.0] — 2026-07-28

A bug-fix release, and every one of these came out of building a game with the
tool rather than reading its source. Four were found in a single session: an
initial `--properties` map that dropped values on the floor, sibling ordering
that had no CLI expression at all, commands that could answer from a different
project's editor, and a bad `runtime.eval` that wedged the game channel until
the game was restarted. The addon also stops rewriting the host's
`project.godot` twice a session, which is the change to read the upgrade note
for.

### Upgrading

**Projects that keep the plugin enabled must now commit the two autoloads.**
Autoload registration moved from the editor's tree hooks to plugin enable and
disable, so nothing re-adds `MCPGameInspector` / `MCPGameInput` at editor load
any more. Anyone who deliberately kept them out of version control, relying on
the old inject-on-launch behaviour, will find `runtime.*` and `input.*` inert
after upgrading. The failure is self-describing: `runtime.*` names the missing
autoload in about 0.3s instead of spending its whole timeout.

Three ways to restore them, in order of preference:

- Commit the two autoloads. That is what a project on this version should do.
- Add them from the CLI: `project add-autoload --name MCPGameInspector --path
  res://addons/godot_mcp/services/game_inspector.gd`, then the same for
  `MCPGameInput` with `services/game_input.gd`.
- Untick and re-tick the plugin in Project Settings > Plugins, which runs the
  enable hook and injects the pair.

**Do not attempt that last one through the CLI.** `project disable-plugin --name
godot_mcp` tears down the very WebSocket server the CLI is talking to: the
disable lands, the response never arrives, and nothing remains to re-enable
with. Use `project add-autoload` instead.

### Fixed

- **The addon no longer rewrites the host's `project.godot` on every editor launch
  and shutdown.** Autoload injection moved from `_enter_tree` / `_exit_tree` to
  `_enable_plugin` / `_disable_plugin`, which is what those virtuals are for: they
  fire when the user actually ticks or unticks the plugin. The tree hooks fire every
  time the editor starts and stops, so the addon dirtied the project file twice a
  session — a standing chore for anyone who does not want dev-only autoloads in their
  commits. Worse, the shutdown save persists whatever the in-memory settings hold
  *after every plugin has torn itself down*: observed 2026-07-27 in a consumer project,
  one quit dropped a DIFFERENT addon's seven committed autoloads, which would have
  shipped a game that could not boot. Export is unchanged — disabling the plugin still
  removes them. Projects that keep the plugin enabled should now COMMIT the two
  autoloads, since nothing re-adds them at load.

- **A missing game-side autoload is now diagnosed instantly instead of by
  timeout — or, worse, not at all.** Every editor→game entry point
  (`runtime.*`, `input.*`, `test.*`) now checks that `MCPGameInspector` /
  `MCPGameInput` are present in the **on-disk** `project.godot` before it
  writes an IPC request, reading the same file `get_game_user_dir()` already
  parses. The launched game loads that file itself, so an autoload the editor
  holds only in memory does not exist in the game; the on-disk copy can lose
  one after plugin-enable, most often in projects that deliberately keep these
  dev-only autoloads out of version control and then revert or check out
  `project.godot` mid-session. Every editor-side command keeps working in that
  state — `project.info` still lists both autoloads — so only the game hop
  breaks, which made it expensive to diagnose. Previously `runtime.*` spent its
  full timeout and then *guessed* at this cause in a suggestion string, while
  `input.*`, being one-way with no response to wait on, reported
  `{"sent": true}` for events nothing would ever read. The new error names the
  missing setting and how to restore it. An unreadable `project.godot` is
  treated as "proceed", so the check can never block a working call.

- **An initial `--properties` map no longer drops a value on the floor**.
  `node.add --properties '{"texture": "res://icon.png"}'` created the node, left
  `texture` null, and reported success. The map was coerced against
  `typeof(node.get(name))`, which reads the *current* value, and a null Resource
  property reads as nil — so the path was assigned as text and discarded. `node.set`
  had already been fixed to coerce against the declared type, which is why the same
  value worked there and made this look like a quirk rather than a bug. Nine commands
  now share one strict helper: a `res://` or `uid://` path is loaded into the real
  resource, a coercion that cannot be made is an error naming the literal the
  property wanted, and a name the type does not have comes back under
  `properties_ignored`. A malformed `--properties` value is an error too; it used to
  be iterated as a string and drop every key without a word. Affects `node.add`,
  `authoring.ensure`, `batch.add_nodes`, `csg.add`, `lighting.add`,
  `lighting.add_2d`, and `scene3d.add_mesh`.

- **A script error in `runtime.eval` no longer wedges the game channel**. Under a
  `--headless` editor a GDScript parse error broke into the remote debugger, which
  has no UI to resume, so the game froze and every later `runtime.*` command timed
  out with nothing surfaced anywhere. The channel simply went dead, and the usual
  trigger — `var x := <untyped expression>` — is easy to write by accident. That
  break only fires for a compile on the main thread, so the wrapped source is now
  compiled on a worker thread first. A bad eval returns the parse message with the
  line number in the caller's own code, and the next command still works.

- **Commands no longer answer from another project's editor**. Port discovery falls
  back to the default port when the project has no discovery file, so whichever
  godot-mcp editor happened to be running answered, and every write landed in *that*
  project with a success envelope each time. One session was spent chasing settings
  that would not persist; they persisted, in the other project. A port that did not
  come from this project's live discovery file is now checked against the answering
  editor's `project_path` before the call runs: a guessed port aborts, an explicit
  `--port` or `GODOT_MCP_PORT` warns. `godot-mcp status` reports `project_path` and
  `project_match`, and a mismatch now reads as no editor at all rather than
  "running", so the launch policy points at opening one. The healthy case costs
  nothing, since a live discovery file names its own editor and skips the check.

### Added

- **`node.move` reorders siblings, and `node.add` takes `--index`**. Sibling order is
  draw order in 2D, so seating a node behind existing content is routine work that
  had no CLI expression at all: `node.move` only reparented, and the fallback was
  `editor.run_script` with a hand-written `move_child`. `--new-parent-path` is now
  optional when `--index` (0-based, negative counts from the end) or
  `--before`/`--after` names a sibling to seat against, and the two combine to
  reparent and position in one undoable step. `node.add --index` skips the round trip
  entirely for a new node.

## [0.5.0] — 2026-07-27

The editor stops needing a middleman: it speaks MCP itself over streamable
HTTP, so an HTTP-capable client connects with no Go process in between. Also
the release where the new endpoint's `Origin` gate was added, then found
bypassable and hardened.

### Added

- **The editor is now an MCP server itself — streamable HTTP, zero external
  process.** The addon hosts `POST /mcp` on `127.0.0.1` (auto port 9100-9115;
  `GODOT_MCP_HTTP_PORT` or the `godot_mcp/network/http_port` setting pins one),
  so any MCP client that speaks streamable HTTP connects straight to the
  running editor. Tools mirror `serve`: the generic `godot_run` plus every
  documented command as a typed tool with a real schema, dispatched through
  the same command router — all guards apply unchanged. The
  `godot_mcp/network/http_typed` setting collapses the list to `godot_run`
  alone for tool-limited clients, `godot_mcp/network/mcp_http` turns the
  endpoint off, and the discovery file now carries `http_port`.

- **MCP prompts in `serve`**. The stdio MCP server now declares the prompts
  capability and ships four static prompts distilled from the agent skill —
  `discover-then-drive`, `spatial-placement` (optional `target` argument),
  `launch-recovery`, and `bug-hunt` — embedded in the binary and served via
  `prompts/list`/`prompts/get` even when the editor is down. The playbook now
  rides along as first-class MCP prompts, not just the `instructions` string.

- `scripts/test-http-mcp.ps1` (`task test:http`): a 37-check conformance sweep of
  the HTTP endpoint against a live editor — handshake and protocol negotiation,
  tool-surface legality, router dispatch and error mapping, HTTP framing
  (411/413/405/404, keep-alive, pipelining, `Connection: close`), and the Origin
  gate including lookalike hosts and the literal `null` origin. Exit 0 means all
  passed. Maintainer-only: `scripts/` does not ship in the public mirror.

### Fixed

- **Property writes no longer silently substitute a wrong value**. Three bugs in
  `property_parser.gd`, all found by driving the typed command groups to build a
  scene rather than scripting it:
  - A numeric input with too few components **zeroed the property and reported
    success**: `node set --property area_size --value 34.0` on an `AreaLight3D`
    (whose `area_size` is a `Vector2`) wrote `Vector2(0, 0)`. Write paths now
    coerce through `PropertyParser.parse_checked()`, which refuses and names the
    expected literal. Applies to Vector2/3/4, Rect2, Quaternion and Color.
  - **JSON arrays were stringified before parsing**, so `[28,28]` became
    `Vector2(0, 28)` — `_numbers()` stripped a `Vector2(` prefix but not `[`.
    Arrays and dictionaries are now read element-wise.
  - **Resource-typed properties silently dropped `res://` paths**.
    `resource create --type Sky --properties '{"sky_material":"res://…"}'`
    returned `properties_set:["sky_material"]` while saving `null`, because the
    value was coerced against `typeof(current)` (`TYPE_NIL` for an unset
    resource). Write paths now resolve the **declared** type from
    `get_property_list()` and load `res://` / `uid://` strings into real
    references, erroring on a missing file or a class mismatch. Consequence:
    `node set --property environment --value res://env.tres` and other
    resource-by-path assignments now work.
- `node.add_resource`, `resource.create` and `resource.edit` are **atomic** on
  failure (nothing written) and now report `properties_set` as what actually
  applied, plus `properties_ignored` for names the object does not have.

- **`scene open --force` switches to the scene it reloads** instead of leaving a
  different one active. `EditorInterface.reload_scene_from_path` reloads a tab
  without changing which tab is current, so forcing a scene that was open but not
  active returned `opened:true` while the editor stayed put — and every later
  command silently targeted the previously-active scene. The handler switches
  after reloading and reports `already_active` so a caller can tell the difference.

### Security

- **The `Origin` gate accepted attacker-registrable lookalike hosts**. The
  loopback test was `host.begins_with("127.")`, a prefix match on the host
  *string* rather than an address check, so an origin of
  `http://127.0.0.1.evil.example` or `https://127.evil.com` passed and had its
  origin echoed back in `Access-Control-Allow-Origin`. Anyone can register a
  domain in that shape and resolve it anywhere, so a page served from one could
  drive the editor through `editor.run_script` and read the replies, which is
  exactly what the gate was added to prevent. The host is now parsed as four
  numeric octets (`_is_loopback_ipv4`). Real loopback origins, `localhost`,
  `::1`, and header-less native clients are unaffected. The WebSocket transport
  is unchanged and was never gated. Conformance suite grew lookalike-host,
  `null`-origin, and non-`127.0.0.1` loopback cases (37 checks, was 34).
  **Exposure was limited to builds from `main`**: the HTTP endpoint itself
  landed after the `v0.4.0` tag, so no tagged release ever carried the
  endpoint, let alone the flawed gate. The pending Asset Library snapshot did
  carry it and has been refreshed.

- **The HTTP MCP endpoint now validates `Origin`**. Binding `127.0.0.1` does not
  keep a browser out: any web page you visited while the editor was open could
  POST to `http://127.0.0.1:9100/mcp` — the wildcard `Access-Control-Allow-Origin`
  even let it read the replies — and reach `editor.run_script`, i.e. arbitrary
  code execution. Requests with no `Origin` (native MCP clients, curl, the Go
  CLI) and loopback origins are served as before; any other origin now gets
  `403` with the connection closed, and `Access-Control-Allow-Origin` echoes the
  allowed origin instead of `*`. The WebSocket transport cannot be gated this way
  (Godot exposes no handshake headers server-side, and browser WebSockets are
  exempt from CORS) and that is an accepted limitation, not a pending fix — the
  ports are unauthenticated by design, so treat a running editor as reachable by
  anything local. The docs now carry a **Threat model** section spelling this out.

## [0.4.0] — 2026-07-22

The Unity CLI answer, shipped in two days: full nested help with per-command
param tables served live from the addon, per-project port pinning, project-local
command registration (`res://mcp_commands/`), a `doctor` preflight, `--format
tsv`, param docs for the complete 312-command catalog, a direct-to-player
channel that drives a standalone debug game with no editor (`--game`), and
typed MCP tool schemas in `serve` built live from those docs. Plus two real
fixes the work flushed out: plugin disable now removes the addon's autoloads,
and `navigation.add_link` applies `navigation_layers` to 2D links.

### Fixed

- **`navigation.add_link` now applies `--navigation-layers` to 2D links**. The
  handler set it only in the `NavigationLink3D` branch; a `NavigationLink2D`
  silently ignored the param even though the class has the property. Found by
  the param-docs authoring pass (docs are extracted from handler code, so the
  asymmetry stood out); verified live by reading `navigation_layers: 5` back
  off a freshly created 2D link.
- **Plugin disable now actually removes the addon's autoloads**. Removal used
  session-only provenance tracking, but injection saves `ProjectSettings` — so
  from the second session on the autoloads read as project-owned and disable
  left them behind (the one manual step in every ship-the-game flow). Removal
  now matches by ownership: an `autoload/MCPGame*` entry is removed iff its
  value points at the addon's own service script; unrelated autoloads a project
  declares itself are untouched.

### Added

- **Typed MCP tool schemas in `serve`**. The stdio MCP server now exposes every
  documented command as a first-class tool with a real JSON schema — name
  (`node_add`), description, per-param types and `required` — built **live**
  from the addon's `get_command_docs()` on the first `tools/list` and cached,
  so the tool surface can never drift from what's registered. `godot_run`
  stays as the generic escape hatch (and gains an optional `game` argument);
  `runtime_*`/`input_*` typed tools carry an optional `game` bool that routes
  the call to a standalone debug game's direct server — the MCP half of the
  player channel. Editor down at connect degrades to `godot_run` alone, and a
  later successful editor call upgrades the list via
  `notifications/tools/list_changed`. `serve --typed=false` opts tool-limited
  clients back to the single generic tool.
- **Direct-to-player channel** — drive a standalone running game with **no
  editor**. With the project setting `godot_mcp/runtime/direct_server` on, a
  **debug-build** game hosts its own `127.0.0.1` WebSocket server (ports
  9200-9215, `GODOT_MCP_GAME_PORT` pins) serving `runtime.*`/`input.*` with
  identical param shapes through the same game-side handlers the editor's file
  IPC uses (shared dispatch — nothing duplicated), plus a `user://`
  discovery file with the same stale-pid contract as the editor's. The CLI's
  `--game` flag routes there, resolving the game's user-data dir from
  `project.godot`. Hard-gated on `OS.is_debug_build()`, so a release export can
  never host it even if the setting ships enabled. Verified live: a standalone
  game driven (`tree`/`eval`/`get`/`input`) with zero editor processes, clean
  quit removes the discovery file, and the editor-brokered channel coexists
  unchanged.
- **Per-command param docs** (the Unity `[CliArg]` equivalent). A command group
  can expose `get_command_docs()` — per-command description plus param name /
  type / required / one-liner — and the router serves it live: `engine.commands
  --group G` attaches the group's docs (`--docs` for the full catalog), and the
  CLI renders them: `godot-mcp <group> <command> --help` prints a real param
  table, group listings gain one-line descriptions. Authored for the **entire
  catalog — all 49 groups, 312 commands** (plus the project-local example) —
  with every param extracted from
  handler code, not memory, and group gotchas folded into the descriptions;
  project-local `mcp_commands` files carry docs via the same hook (the shipped
  example demonstrates it). A group without docs (e.g. a third-party command
  file) degrades to the generic dynamic-params hint.
- **`godot-mcp doctor`** — environment preflight: godot binary + version,
  project resolution, addon installed/enabled, effective port source (env /
  per-project pin / auto, warns when env and pin disagree), editor liveness
  verdict, dotnet for C#. `--project DIR`, `--json`; exit 1 only when a check
  fails (warns don't fail — doctor may run before any editor is launched).
- **`--format tsv`** — global flag rendering a success result as tab-separated
  text for shell pipelines: array-of-objects → header + rows, object →
  key/value rows, nested values as compact JSON, tabs/newlines escaped.
  Default `json` (pretty) is unchanged.
- **Per-project MCP port setting**. A new project setting `godot_mcp/network/port`
  (Project → Project Settings, int, default `0` = auto) pins the WebSocket port
  per project, persisted in that project's `project.godot` — so two concurrent
  projects listen on distinct ports deterministically. Port precedence is now
  `GODOT_MCP_PORT` env > the project setting if > 0 > the auto range 9080-9095.
  The setting registers idempotently on plugin enable and survives disable/enable;
  `set_initial_value(0)` keeps the default out of `project.godot`, so enabling the
  plugin never dirties the file. The bind stays `127.0.0.1`-only (no host setting).
- **Project-local commands** — extend the MCP without forking the addon. On plugin
  enable the router scans `res://mcp_commands/*.gd` and registers each file's
  `get_commands()` alongside the built-ins, so custom commands appear in the CLI,
  `godot-mcp help <group>`, and `engine commands` automatically (no Go changes). A
  valid file instantiates to a Node exposing `get_commands() -> {"group.command":
  Callable}` (extend `base_command.gd` or a plain Node); a bad file is skipped with
  a warning and never breaks startup, and a name colliding with a built-in is
  skipped — built-ins win. Ships with a committed example, `custom.ping`/`custom.echo`.
- **Nested CLI help** (312 commands / 49 groups): `godot-mcp <group> --help`
  (also `-h`, `godot-mcp <group> help`, and `godot-mcp help <group> [<command>]`)
  lists a group's commands, and `godot-mcp help all` prints the entire catalog
  grouped by category; an unknown group or command lists what does exist.
  The catalog stays out of the Go binary: help is served live by the new
  `engine.commands [--group G]` introspection command — flat `methods` plus a
  `groups` map of group → command names, so automation built on the JSON gets
  the surface by category without splitting prefixes — with a fallback to the
  `available_methods` payload older addons return on `-32601`, so it needs a
  running editor and never goes stale.

- **`shipping-export.md` craft reference** — the release pipeline: dev-tooling
  exclusion (this addon must never ship), the headless export loop, PCK
  encryption with keyed custom templates (`SCRIPT_AES256_ENCRYPTION_KEY` at
  compile, `GODOT_SCRIPT_ENCRYPTION_KEY` at export — verified on 4.7),
  size-optimized template builds, and receipt-based verification (pck plaintext
  scans; a booting exe as the key-match proof). Distilled from a real 4.7
  desktop release.

- **C# project support** (311 commands / 49 groups): new `csharp` group —
  `csharp.info` (dotnet + .NET-editor detection), `csharp.setup` (scaffolds
  `<Name>.csproj`/`.sln` with Godot.NET.Sdk, sets the assembly name; SDK version
  defaults to the engine's `major.minor.patch[-status]`, `--sdk-version`
  overrides), `csharp.build` (non-blocking `dotnet build` with deduped
  structured diagnostics, line-level and project-level; a failed build is a
  `success:false` payload, not a transport error). `script.*` is now C#-aware:
  `create` writes a `public partial class` template for `.cs` paths, `validate
  --path X.cs` builds and filters diagnostics to that file, `list` sniffs the
  declared class/base. The Go CLI and `serve` floor timeouts to 5 minutes for
  build-backed methods. Requires a Godot .NET editor build plus the dotnet SDK;
  E2E-verified against a 4.7.2-rc mono editor (setup → create → build →
  validate → attach).

## [0.3.0] — 2026-07-17

AI-client integration (read-only `godot://` MCP resources, `configure`, Asset
Library readiness), running-game error capture and signal awaits, git-aware
batch script validation, project bootstrapping from nothing, blend-space
authoring for `anim_tree`, and eight new craft references. First public release.

### Added

- **`runtime.errors`**: poll runtime errors/warnings the running game captured
  via `OS.add_logger` (a `Logger` subclass registered by MCPGameInspector) —
  structured `{kind, message, code, backtrace[]}` with the game-script frame in
  `backtrace[0]`, `--since-seq` for incremental reads, `--clear` to drain.
  Pull-based (no doorbell) and runtime errors are unambiguously real. Live-
  verified capture of errors + warnings with backtraces; the game survives an
  error storm (bounded ring buffer, re-entrancy guard). Note: a *real* script
  error under a `--headless` editor trips the debugger break and freezes the
  game — push_error/warning/shader errors and windowed/standalone runs are fine.
- **`godot://` MCP resources** in `serve`: read-only introspection surfaced as
  MCP resources (`project/info`, `project/tree`, `scene/tree`,
  `engine/singletons`, `editor/errors`) via `resources/list`/`resources/read`,
  so a client pulls context without spending a tool turn.
- **`godot-mcp configure <client>`**: writes an MCP-server config pointing
  `claude`/`cursor`/`vscode`/`codex` at `godot-mcp serve`. Project-scoped by
  default (`--global` for user locations), merges without clobbering other
  servers, `--print` to emit the snippet.
- **Asset Library readiness**: `docs/ASSET_LIBRARY.md` submission checklist and
  a corrected `plugin.cfg` (submission is gated on a public repo mirror).
- README: head-to-head comparison table vs `hi-godot/godot-ai`, with the
  differentiation refocused on the running game, context economy, and craft.
- **`runtime.await_signal`**: block until a signal fires on a node in the
  running game, returning its serialized arguments (`fired:false` on timeout,
  as a success payload — agents can branch on it). Arity-matched one-shot
  connect; args captured up to 6 parameters. Live-verified: 0-arg fire,
  timeout, and 1-arg capture (`child_entered_tree`).
- **`script.validate --modified` / `--all`**: batch validation. `--modified`
  is git-aware (modified-vs-HEAD plus untracked `.gd`, deleted files skipped;
  handles the git repo sitting above the Godot project root), `--all` sweeps
  every project `.gd` outside `addons/`. Results list failures only.
- **`godot-mcp create`**: local subcommand that bootstraps a new Godot 4.7
  project from nothing (`project.godot`, placeholder `icon.svg`,
  `.gitignore`); `--install --enable` wires the addon and skill in the same
  step. Never overwrites an existing `project.godot`.
- README: "How is this different from other Godot MCPs?" positioning section
  (editor-native co-developer vs remote control).
- **Four craft docs** closing the 2026-07-16 surface-audit gaps, every API claim
  introspected live and flagship recipes behavior-verified in a running game:
  `audio-music.md` (buses, SFX variation, `AudioStreamInteractive` scores,
  sidechain ducking, spectrum), `menus-settings.md` (pause, the settings widget
  family, `ConfigFile` persistence, input remapping, dialogs, 9-slice, fonts,
  `GraphEdit`), `mobile-touch.md` (multitouch, gestures, `VirtualJoystick`,
  safe areas), plus locomotion blend spaces and an `HTTPRequest`
  leaderboard/telemetry pattern in `game-patterns.md` and particle trail
  meshes + `TextMesh` in `environment-art.md`.
- `audio.add_bus_effect`: compressor now accepts `sidechain`, and five new
  effect types — `pitchshift`, `hardlimiter`, `spectrum`, `record`, `capture`.
- **Blend-space authoring for `anim_tree`** (closes the last gap from the
  genre-doc pass): `anim_tree.create --root-type blend_space_1d|blend_space_2d`
  and `anim_tree.add_state --state-type blend_space_1d|blend_space_2d` build the
  node; new `anim_tree.set_blend_point` / `anim_tree.remove_blend_point` manage
  its clips; `get_structure` reads blend points back. What was a `run-script`
  workaround in `game-patterns.md` is now first-class — verified live, including
  a running-game drive of `parameters/blend_position`. (307 commands total.)
- **Four genre craft docs** closing the audit's genre axis: `character-3d.md`
  (FPS/third-person/platformer controllers — the movement core was built and
  driven live through the CLI itself: gravity, basis-relative heading, jump
  all verified numerically), `save-systems.md` (collector pattern, format
  tradeoffs, atomic autosave), `multiplayer-patterns.md` (authority, @rpc
  compile-probed, spawner/synchronizer wiring), `shaders-vfx.md` (the 2D VFX
  kit plus a programmatic .gdshader compile-verification loop).

## [0.2.0] — 2026-07-11

### Added

- **TileSet authoring** (`tilemap` group): `tilemap.create` (TileMapLayer with a
  fresh TileSet, `--tile-size`), `tilemap.add_atlas_source` (texture atlas with a
  tile auto-created per grid cell), `tilemap.add_scenes_source` (PackedScenes as
  paintable tiles — the scene-prefab blockout workflow; painted cells carry real
  collision), and `tilemap.set_terrain` (autotile painting/erasing via
  `set_cells_terrain_connect`). `get_info` now reports terrain sets and scene
  sources. Live-verified, including the engine gotcha that a terrain with no
  island tile (terrain assigned, zero peering bits) silently places nothing for
  isolated cells.
- **2D lighting extensions** (`lighting` group): `emissive_2d` (exempt a
  CanvasItem from darkness — unshaded/light-only, optional additive blending),
  `normal_map_2d` (wrap a sprite's texture in a `CanvasTexture` with
  diffuse/normal/specular so 2D lights shade it directionally), `glow_2d`
  (enables `rendering/viewport/hdr_2d` — restart required — and adds an
  additive-glow `WorldEnvironment`), plus `occluder_2d --sdf-collision` /
  `--occluder-light-mask`. Screenshot-verified against a live scene.
- **`scene2d.add_animated_sprite`**: AnimatedSprite2D + SpriteFrames authored
  from a spritesheet grid in one call — `--hframes/--vframes` slicing, named
  animations via `--animations` JSON (frames/fps/loop over row-major grid
  indices), `--autoplay [name]`, and the built-in empty "default" animation
  removed when unused.
- **2D cutout rigs** (`skeleton` group): `create_2d` (Skeleton2D + Bone2D
  hierarchy from a JSON bone list, rests baked, owners set so bones survive
  save), `set_rest_2d` (re-bake rests from current transforms), `skin_2d` (bind
  a Polygon2D with explicit or inverse-distance auto weights,
  `--falloff`/`--max-influences`); `list_bones` now handles Skeleton2D.
  Verified with a screenshot of a skinned polygon deforming through a bone
  rotation.
- **Nine craft references** mined from shipped/production games and verified
  against the live 4.7 engine: `platformer-2d.md` (component actor,
  physics-expression AnimationTree, codeless moving platforms), `topdown-2d.md`
  (TileMapLayer stacks, gameplay-as-terrain-painting, component library,
  day/night clock, Resource saves), `ui-polish-2d.md` (design tokens from
  comps, drawn controls, screen-builder traps), `rhythm-games.md` (corrected
  audio clock, beatmap-format reuse, windowed judging), `lighting-2d.md` (the
  full 2D lighting stack incl. SDF and glow), `event-deck-games.md`
  (Reigns-like decision-card architecture), `run-based-games.md` (reactive data
  blackboard, wave weight-budgets, seeded self-auditing worldgen) — plus major
  additions to `narrative-game-patterns.md` (the graph-dialogue family, the
  manifest-driven product shell), `environment-art.md` (paper-diorama staging,
  pixel-art project setup, GPU particle attractors/colliders, `AreaLight3D`),
  and `game-patterns.md` (combat-VFX shader grammar, entity-family discipline,
  the 4.7 `SkeletonModifier3D` motion stack, positional audio, offscreen
  lifecycle, turn-based loops with CPU personalities).
- **2D and 3D surface audits**: every instantiable `Node2D` (46) and `Node3D`
  (106) class on 4.7 enumerated from the live ClassDB and verified covered by a
  command or a craft doc (XR deliberately excluded).

- **`install-assets` subcommand**. Copies bundled **CC0 asset packs** into a
  project — `godot-mcp install-assets [--pack NAME] [--dest assets/vendor]
  [--list] [--force]`. Each pack is copied whole (its `License.txt`/source files
  kept, so attribution stays intact) into `<project>/assets/vendor/<pack>/` by
  default; `--dest` overrides (project-relative or absolute), `--pack` narrows to
  one, `--list` enumerates without a project. A local command — it does not dial
  the editor. Refuses to overwrite an existing pack without `--force`.
- **Bundled pack: `kenney_prototype_textures`** (Kenney Prototype Textures, CC0)
  — grid/checker greybox skins in per-colour `PNG/` folders, shipped in the addon
  zip.
- **Level-design craft reference** (`skills/godot-mcp/level-design.md`): blockout
  process/strategy and in-level spatial-communication tactics, each mapped to
  `godot-mcp` build recipes — Big→Medium→Small risk-ordered passes, a greybox
  colour language, 2.5D depth/value + grayscale test, designer-vs-stakeholder
  presentation stages, greybox lighting stages, and the prototype-texture workflow.
- **Game feel vs juice** section in `skills/godot-mcp/game-patterns.md`: the two
  as distinct layers (control-code vs signal-fired feedback) with verified 4.7
  recipes (coyote time/jump buffer/accel, squash-stretch/hit-stop/screen shake)
  and a reusable `Juice` autoload stack.
- **Environment art pass craft reference** (`skills/godot-mcp/environment-art.md`):
  the art pass after the greybox is proven — greybox→art handoff, PBR materials,
  real lighting (SDFGI/LightmapGI/VoxelGI), `WorldEnvironment` post, decals/
  particles/fog, set dressing + `MultiMesh`, occlusion/LOD, and the "don't lose
  the read" through-line. Tool boundary: meshes/textures authored externally.
- **`editor run_script --path`** — run an editor script from a file (`res://`,
  `user://`, or an absolute OS path) instead of only inline `--code`, so large
  scripts aren't shoved through the shell. `code` still works; `path` takes
  precedence when both are given.
- **`scene validate`** — scan the open scene for integrity problems that don't
  surface until play: AnimationPlayer tracks whose node path doesn't resolve
  ("track doesn't lead to a Node") and exported/stored NodePath references that
  point nowhere. Read-only; returns `{valid, issue_count, issues:[...]}`. Fills
  the gap where the only validation was `script.validate` (scripts) and
  `spatial.lint` (geometry), with `editor errors` as a noisy global fallback.

### Fixed

- **Packed-array properties parse and serialize correctly**. `property_parser`
  had no packed-array cases, so setting e.g. a `Polygon2D.polygon` from an array
  of `"Vector2(x,y)"` strings fell through untyped and Godot's implicit cast
  silently zeroed every element. All packed types now coerce per element in both
  directions.
- **`scene2d.add_animated_sprite` start animation is deterministic**. JSON
  params arrive orderless from the Go CLI, so "first animation in the dict" was
  nondeterministic; the start/autoplay animation is now chosen explicitly
  ("default", else alphabetical, else the `--autoplay` name).
- **`editor set_camera` accepts the `Vector3(x, y, z)` string form**. It only
  took a `{x, y, z}` dict; the `Vector3(...)` string every other spatial command
  uses hit a hard `Dictionary` cast and made the command a silent no-op (empty
  result). It now parses both forms via `PropertyParser`.
- **`editor run_script` no longer floods `editor errors` with its own source**.
  The exec audit logged the script body via `printerr`, which renders red as
  `ERROR:` and was then re-collected by `editor errors` as fake errors; it now
  logs via `print` (still visible in Output, not flagged as an error).
- **Object params validate via a shared `require_dict` helper**. `resource.edit`
  (`properties`), `scene3d` environment (`sky`), and `theme` container (`margins`)
  now return a clear error on a present-but-malformed value instead of a generic
  message or a silent skip, and tolerate a JSON object passed as a string. (None
  could crash like `set_camera` — each already guarded the cast — but a silently
  ignored param gives an agent no feedback.)
- **`animation create`/`remove` no longer emit a stray `animation_mixer.cpp`
  engine error.** Both called `get_animation_library("")` on a player that may
  have no default library, which returns null *and* logs an error; they now guard
  with `has_animation_library("")` first. (The commands worked; the log was noise
  that polluted a subsequent `scene validate` / `editor errors`.)
- **`node add --parent` now nests instead of silently landing at the scene root**.
  The flag is `--parent-path`; the generic CLI parser has no per-command schema, so
  a typo'd `--parent` was passed through and ignored, defaulting the node to root
  with no error. `node.add` now accepts `parent` as an alias for `parent_path`.
- **`node get` now reports the node's `script`**. `get_node_properties_dict`
  explicitly skipped the `script` property, so a node with a script attached
  looked script-less through `node get` (`scene tree` already showed it). It now
  reports `script` as the resource path (or `null` when none), matching the tree.
- **`node get --properties '[...]'` actually filters now**. The handler only
  honoured `--category` (a prefix filter); a `properties` name list was silently
  ignored and the full dump returned. It now fetches exactly the named properties
  (any property, not just the editor-visible set; `script` as its path) and
  reports unknown names under `missing` rather than dropping them silently.
- **`spatial lint --check-floating` no longer drowns in false positives**. It
  flagged every `VisualInstance3D` that wasn't resting on something directly below
  — so lights, decals, fog, GI probes, particles, sprites, MultiMesh scatter (no
  "rests on a surface" meaning) *and* all mounted/hanging/attached geometry got
  reported. Now it only considers solid geometry (`MeshInstance3D`/`CSGShape3D`)
  and treats a piece as supported if it touches/overlaps another solid (5 cm
  contact tolerance) or rests just above one. On a fully dressed scene this drops
  ~60 false positives to zero while still catching an isolated float.

## [0.1.0] — 2026-06-18

First release. A Go CLI plus a Godot 4.7 GDScript addon that drive a running
editor over WebSocket, with file-IPC into the running game.

### Added

- **Go CLI (`godot-mcp`)**. Connects to the editor addon over JSON-RPC 2.0 on a
  WebSocket; auto-discovers the port from `<project>/.godot/godot-mcp.json` (or
  `--port`). Maps `<group> <command> [--flags]` to dotted methods. Flag values
  accept strings (coerced engine-side), `true`/`false`, bare booleans, and JSON
  for `[...]`/`{...}`; command/flag names accept kebab- or snake-case. Prints
  JSON-RPC errors with code, message, and any `data` (suggestions, available
  methods) to stderr.
- **`install` subcommand**. Copies the addon into `<project>/addons/godot_mcp`
  and (by default) the agent skill into `<project>/.claude/skills/godot-mcp`;
  `--enable` adds the plugin to `project.godot`. Sources default to the
  release-bundle layout next to the binary.
- **Godot 4.7 addon (`godot_mcp`)**. WebSocket server hosted in the editor
  (the addon is the server; the CLI is a short-lived client). Self-installs its
  game-side autoloads on enable (idempotent). All editor mutations go through
  `EditorUndoRedoManager`.
- **175 commands across 26 groups**, every command verified against a live 4.7
  editor/game: `project`, `scene`, `node`, `script`, `editor`, `runtime` (20,
  including stateful capture/monitor/record/move/watch), `engine`, `input`,
  `animation`, `anim_tree`, `tilemap`, `theme`, `shader`, `particles`,
  `scene3d`, `physics`, `navigation`, `audio`, `input_map`, `resource`,
  `analysis`, `batch`, `profiling`, `export`, `test`, `android`.
- **`engine` introspection group** (`version`, `classes`, `class_info`,
  `search`, `singletons`) — query the live `ClassDB` so an agent can discover
  the real 4.7 API (e.g. `engine search --query offset_transform`) instead of
  relying on training knowledge.
- **Runtime/game bridge**. Two game-side autoloads (`MCPGameInspector`,
  `MCPGameInput`) broker inspection, input simulation, frame capture, property
  monitoring, recording/replay, and signal watching over `user://` file IPC.
  `runtime.screenshot` works even under a headless editor (the game is a
  separate windowed process).
- **Relative node paths** in `scene.tree`/`runtime.tree`/`node.get` output, so
  they feed straight back as `--node-path`.
- **Agent skill** (`skills/godot-mcp/SKILL.md`): teaches the discover-then-drive
  loop, Godot node/scene composition (build with composed scenes and component
  nodes, not monolithic scripts), command groups, workflows, and pitfalls.
- **Release packaging** (`scripts/release.ps1`, `task release`): CLI binaries
  for windows/amd64, linux/amd64, darwin/arm64, each bundled with the addon,
  skill, and docs; plus standalone addon and skill zips.
- Docs: `README.md`, `INSTALL.md`, `CLAUDE.md`; MIT `LICENSE`.

### Notes

- Targets the Godot **4.7** dev build (`godot-dev`); not validated against 4.6.
- `android.*` requires Android platform-tools/SDK and an export preset; without
  them it returns clean errors.
