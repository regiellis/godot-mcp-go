# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

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

- **`navigation.add_link` now applies `--navigation-layers` to 2D links.** The
  handler set it only in the `NavigationLink3D` branch; a `NavigationLink2D`
  silently ignored the param even though the class has the property. Found by
  the param-docs authoring pass (docs are extracted from handler code, so the
  asymmetry stood out); verified live by reading `navigation_layers: 5` back
  off a freshly created 2D link.
- **Plugin disable now actually removes the addon's autoloads.** Removal used
  session-only provenance tracking, but injection saves `ProjectSettings` — so
  from the second session on the autoloads read as project-owned and disable
  left them behind (the one manual step in every ship-the-game flow). Removal
  now matches by ownership: an `autoload/MCPGame*` entry is removed iff its
  value points at the addon's own service script; unrelated autoloads a project
  declares itself are untouched.

### Added

- **Typed MCP tool schemas in `serve`.** The stdio MCP server now exposes every
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
- **Per-project MCP port setting.** A new project setting `godot_mcp/network/port`
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

- **`install-assets` subcommand.** Copies bundled **CC0 asset packs** into a
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

- **Packed-array properties parse and serialize correctly.** `property_parser`
  had no packed-array cases, so setting e.g. a `Polygon2D.polygon` from an array
  of `"Vector2(x,y)"` strings fell through untyped and Godot's implicit cast
  silently zeroed every element. All packed types now coerce per element in both
  directions.
- **`scene2d.add_animated_sprite` start animation is deterministic.** JSON
  params arrive orderless from the Go CLI, so "first animation in the dict" was
  nondeterministic; the start/autoplay animation is now chosen explicitly
  ("default", else alphabetical, else the `--autoplay` name).
- **`editor set_camera` accepts the `Vector3(x, y, z)` string form.** It only
  took a `{x, y, z}` dict; the `Vector3(...)` string every other spatial command
  uses hit a hard `Dictionary` cast and made the command a silent no-op (empty
  result). It now parses both forms via `PropertyParser`.
- **`editor run_script` no longer floods `editor errors` with its own source.**
  The exec audit logged the script body via `printerr`, which renders red as
  `ERROR:` and was then re-collected by `editor errors` as fake errors; it now
  logs via `print` (still visible in Output, not flagged as an error).
- **Object params validate via a shared `require_dict` helper.** `resource.edit`
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
- **`node add --parent` now nests instead of silently landing at the scene root.**
  The flag is `--parent-path`; the generic CLI parser has no per-command schema, so
  a typo'd `--parent` was passed through and ignored, defaulting the node to root
  with no error. `node.add` now accepts `parent` as an alias for `parent_path`.
- **`node get` now reports the node's `script`.** `get_node_properties_dict`
  explicitly skipped the `script` property, so a node with a script attached
  looked script-less through `node get` (`scene tree` already showed it). It now
  reports `script` as the resource path (or `null` when none), matching the tree.
- **`node get --properties '[...]'` actually filters now.** The handler only
  honoured `--category` (a prefix filter); a `properties` name list was silently
  ignored and the full dump returned. It now fetches exactly the named properties
  (any property, not just the editor-visible set; `script` as its path) and
  reports unknown names under `missing` rather than dropping them silently.
- **`spatial lint --check-floating` no longer drowns in false positives.** It
  flagged every `VisualInstance3D` that wasn't resting on something directly below
  — so lights, decals, fog, GI probes, particles, sprites, MultiMesh scatter (no
  "rests on a surface" meaning) *and* all mounted/hanging/attached geometry got
  reported. Now it only considers solid geometry (`MeshInstance3D`/`CSGShape3D`)
  and treats a piece as supported if it touches/overlaps another solid (5 cm
  contact tolerance) or rests just above one. On a fully dressed scene this drops
  ~60 false positives to zero while still catching a genuinely isolated float.

## [0.1.0] — 2026-06-18

First release. A Go CLI plus a Godot 4.7 GDScript addon that drive a running
editor over WebSocket, with file-IPC into the running game.

### Added

- **Go CLI (`godot-mcp`).** Connects to the editor addon over JSON-RPC 2.0 on a
  WebSocket; auto-discovers the port from `<project>/.godot/godot-mcp.json` (or
  `--port`). Maps `<group> <command> [--flags]` to dotted methods. Flag values
  accept strings (coerced engine-side), `true`/`false`, bare booleans, and JSON
  for `[...]`/`{...}`; command/flag names accept kebab- or snake-case. Prints
  JSON-RPC errors with code, message, and any `data` (suggestions, available
  methods) to stderr.
- **`install` subcommand.** Copies the addon into `<project>/addons/godot_mcp`
  and (by default) the agent skill into `<project>/.claude/skills/godot-mcp`;
  `--enable` adds the plugin to `project.godot`. Sources default to the
  release-bundle layout next to the binary.
- **Godot 4.7 addon (`godot_mcp`).** WebSocket server hosted in the editor
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
- **Runtime/game bridge.** Two game-side autoloads (`MCPGameInspector`,
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
