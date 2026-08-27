# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

## [0.9.1] - 2026-08-27

### Added

- **Two sample projects**, `samples/ghibli-meadow` and
  `samples/lighthouse-demo`, each a standalone Godot 4.7 project an agent
  built by driving the tool. The meadow scatters 250,000 grass blades as a
  MultiMesh over a 70 m field, built at load from a seed rather than stored,
  so the scene file stays small. Its panel retunes the grass and the wind and
  rebuilds the field at a new density without a reload. The lighthouse demo is
  a stylized water surface whose control panel is generated from the shader's
  own uniform list, so it shows whatever the material exposes. Both run with
  `godot --path .`.
- **An agent eval harness** as the scripted release gate, under `evals/`: five
  scenarios carrying 37 deterministic checks, a worker preamble, a review
  rubric, and the run ledgers. A blind worker agent builds against a sandbox in
  the maintainer's dogfood project, then `scripts/eval-check.ps1` grades the
  result against the live editor, so what the worker says it did never counts
  toward the score. The `/eval` skill orchestrates a run. Methodology is
  published on the docs site under Agent evals. Maintainer-only: `evals/` does
  not ship in the public mirror.
- **`configure --config-dir`** writes the client config somewhere other than
  the project it points at. The two are the same directory in an ordinary
  project, and different in a repo whose Godot project sits in a
  subdirectory, where the client reads `.mcp.json` at the repo root while the
  server has to target the subdirectory. It is rejected alongside `--global`
  and for codex, both of which write fixed paths, and the directory has to
  exist already.
- **A "What's not supported" page** on the docs site, under Reference. It
  records features that were considered and deliberately not built, with the
  reasoning and what to use instead: declarative VisualShader graph
  authoring, per-domain tool subsets, and driving an editor on another
  machine. Each entry argues from the engine rather than from preference. The
  first notes that 4.7 ships 110 `VisualShaderNode` subclasses whose port
  metadata is not bound to GDScript, so wiring ports by index means a
  hand-written table nothing can validate, and that `connect_nodes` accepts a
  type-mismatched edge and returns success, so a stale index yields a shader
  that compiles, renders wrong, and reports no error.
- **`scripts/mirror.sh` and `scripts/lib/snapshot_guard.py`**, a POSIX port of
  the mirror snapshot ritual, so a release can be mirrored from macOS or Linux
  and not from Windows alone. The guard is Python rather than shell because
  the policy patterns use `\b` and character classes, which POSIX ERE lacks
  and macOS `grep` cannot match with `-P`. A shell port would quietly
  under-match and pass a leaking tree. Verified by rebuilding the published
  0.9.0 snapshot and diffing trees: 421 files, byte-identical. `task mirror`
  dispatches to whichever script fits the platform. Maintainer-only:
  `scripts/` does not ship in the public mirror.

### Changed

- **`task build` writes `bin/godot-mcp` on every platform except Windows**,
  which still gets `bin/godot-mcp.exe`. The `BIN` variable had the `.exe` name
  hard-coded, so building from source on macOS or Linux produced a working
  binary under a misleading name.

### Fixed

- **A screenshot step ignored `half_resolution` when it saved a file**. A
  `test run-scenario` step carrying both `save_path` and `half_resolution`
  wrote a full-resolution PNG and reported the full dimensions, so the flag
  read as accepted and did nothing; the capture was byte-identical to one
  taken without it. Only the discard branch, which returns the frame instead
  of saving it, had ever honoured the flag. The step now forwards it and the
  game downscales with the same call `capture_frames` uses, and the result
  reports the dimensions actually written. Saving defaults to full resolution,
  unlike `capture_frames`, because a saved PNG is evidence someone looks at;
  both help strings now name the default. `runtime screenshot` accepts
  `--half-resolution` for the same reason.
- **`node get` accepts `--property`**, the singular spelling `node set`
  requires, as shorthand for a single-name `--properties`. Agents that had
  just used `node set` carried the spelling over and got a refusal for a
  mistake most callers make.
- **Two help strings described less than their commands return**.
  `editor errors` reports a `suppressed_noise` count its help never named, so
  a result reading `count: 0` beside a non-zero suppressed count invited the
  reading that something was being hidden. `spatial bounds` said it reads
  `VisualInstance3D` geometry and offered `Marker3D` as the example of a node
  with none, which left lights looking like points. A light reports its
  influence volume, so `spatial relate` says it overlaps whatever it lights,
  and a light's placement has to be read from its pivot. Both now say so, and
  the skill's `doc-search` example no longer claims a query that does not
  return what it says it does.
- **A param a command does not declare now refuses the call** instead of being
  noted in the result. The router compared sent param names against the
  command's docs and annotated the payload with `unknown_params` plus a
  did-you-mean hint, which meant a flag borrowed from a sibling command, or one
  spelled for a different command, returned a plausible answer to a question the
  caller had not asked. Three independent agents hit it in one session:
  `scene validate --path res://...` answered `valid: true` about whichever scene
  was open, `node get --property x` returned every property where `node set`
  requires that same singular spelling, and `--format json` placed after the
  command reached the addon rather than the CLI's formatter. Each is now
  `-32602` with the unknown names, the hint, and the command's declared params,
  and **the check runs before the handler**, so a refused call cannot have
  already changed the project. Commands that deliberately accept an
  unadvertised param keep working: the router's alias table now carries all 26
  of them, including `parent` as an alias for `parent_path` across the 19
  add-style commands that take it, which the old annotation had been flagging as
  unknown on calls that worked. `task check` gained `task audit:params`, which
  walks every handler for the param keys it actually reads and fails on one the
  docs do not declare, because refusing an undeclared param is only correct
  while the docs are a complete map of what each handler accepts.
- **A typed `Array[X]` property took an untyped array and dropped it on save**.
  `Object.set()` with an untyped `Array` on an `Array[X]` export is either
  refused by the engine or stores a value the serializer discards, and neither
  outcome reached the caller: a gate build watched `resource.create` report
  `planets` under `properties_set` while the saved file held `[]`. Writes now
  build a properly typed copy first. Elements coerce toward the array's element
  type, so an Object passes a class or script check, a `res://` or `uid://`
  string is loaded, a Dictionary instantiates the element class and applies its
  keys strictly, and a nested typed array recurses. An element that cannot be
  carried refuses the whole array and names its index instead of quietly
  shortening it. Both write paths read the size back afterwards, because a
  container can refuse an assignment without raising anything the caller sees,
  and a refusal must not hide inside a success.
- **`release.ps1` would have shipped an addon zip with no `.gdignore`** if it
  were ever run on macOS or Linux. `Compress-Archive` treats a leading dot as
  hidden on PowerShell for Unix and skips those entries without a word, so
  `assets/.gdignore` vanished and a consumer project would have imported the
  whole bundled texture pack. It now refuses to run outside Windows and names
  `release.sh`, the POSIX port, which `task release` already selects there.
  Published archives were never affected: they were built on Windows, where a
  leading dot carries no hidden attribute.
- **Release archives carried files from the maintainer's working directory**.
  The packaging step copied `project/addons` and `skills/godot-mcp` off disk
  rather than out of the commit, so anything sitting in the checkout rode
  along. The 0.9.0 archives ship 94 gitignored `.import` files because of it:
  stale ones, since `assets/.gdignore` means Godot never imports that folder,
  and each names a desktop S3TC path under `res://.godot/imported/` that no
  consumer project has. Being untracked, they never passed the policy scan
  that gates every public artifact, because that scan reads a commit. The same
  copy baked in Windows line endings, giving 65 of 244 text files in the addon
  zip CRLF where a POSIX checkout gives LF. Packaging now stages through
  `git archive` from the commit being released, so the artifacts hold exactly
  the  tracked files and the line endings those files carry as committed.
  `core.autocrlf` is forced off for that step: `git archive` converts line
  endings on the way out exactly as a checkout does, so on a Windows clone it
  re-baked CRLF into every text file it staged, which left the artifact
  depending on the building machine again. Verified by rebuilding 0.9.0 on
  Windows from the released commit and diffing against the published assets:
  94 `.import` files gone, nothing added anywhere, every file in the addon zip
  byte-identical to its blob, and CRLF down to the one bundled license file
  whose blob holds it. The GitHub mirror and the Asset Library branch were
  never affected: both already built from the commit.
- **`configure` accepted a directory that was not a Godot project**. The config
  it wrote looked correct, but `serve` could not resolve a project root from
  that directory, so it fell back to port 9080 and also skipped the check that
  the answering editor belongs to this project. Pointed at a repo root whose
  Godot project sits one level down, it silently drove whichever editor held
  the default port. `--project` now resolves through the same upward walk
  `install` uses, a directory in no project is refused outright, and the
  refusal names any `project.godot` one level below it.
- **The two mirror scripts built different snapshots from the same commit**.
  `mirror.ps1` piped its filtered `.gitignore` into `git hash-object --stdin`,
  and PowerShell terminates what it writes to a native command with the
  platform newline, so that blob picked up a trailing CRLF `mirror.sh` never
  produced. Alternating between the two machines flipped the line back and
  forth in the published snapshot. It now writes the text to a file and hashes
  it with `--no-filters`, and both scripts land on the same blob for the same
  input. The two exclusion lists had also drifted apart in the POSIX port:
  `mirror.sh` carried no `evals` entry, and `mirror.ps1` lacked the any-depth
  globs that catch a context doc arriving in a folder the exact-path list does
  not name. Maintainer-only.
- **`mirror.sh` refuses to run on Windows**. Under Git Bash the guard writes its
  filtered `.gitignore` in the locale codepage and in text mode, which drops the
  bytes of every non-ASCII character and puts the carriage returns back, so the
  snapshot would differ from the one `mirror.ps1` builds from the same commit.
  It now exits and names `mirror.ps1`, while `--help` still works. `task mirror`
  already routes by platform, so this catches a direct invocation. `release.ps1`
  carries the same kind of refusal in the other direction. Maintainer-only.

## [0.9.0] - 2026-08-13

### Added

- **The addon runs on Godot 4.3 through 4.8** (beta). Development still targets
  4.7. Registration is per group now, so an engine that cannot compile a group
  skips it and `engine.commands` names the file under `unavailable_groups`
  instead of one unsupported group taking the whole plugin down. Verified
  against the official 4.3, 4.4, 4.5, and 4.6 stable builds plus 4.7.2, one
  headless editor per version against its own copy of the project: all **330
  commands** registered on every one of the five, `unavailable_groups` absent
  throughout, and the game IPC answering on each. Six APIs newer than the floor
  refuse cleanly and name the version they need. `scene close` needs 4.5, and
  below 4.7 every close needs `--discard`, because the editor cannot report
  which tabs hold unsaved work and unknown is not clean. `csg bake` and the AGX
  tonemap need 4.4. Runtime error capture needs 4.5, below which
  `runtime errors` answers `capture: "unavailable"` naming the version rather
  than an empty list that reads as no errors. The floor is beta: the evidence
  behind it is five engine builds and one real port, with no shipped projects
  on it yet.
- **A craft reference on porting a project between 4.x versions** (beta),
  `porting-godot-versions.md`, published as
  [Porting between Godot versions](https://regiellis.github.io/godot-mcp-go/docs/guides/porting-godot-versions).
  It runs the upgrade with evidence on both sides of the move: record how the
  game behaves before the new editor ever opens it, as a replayable
  `test run-scenario` step list plus screenshots and the numbers `runtime get`
  returns, then replay the identical list afterwards. The comparison threshold
  comes from measurement: run the baseline twice on the same build, and the
  spread between those two runs is what a post-port difference is read against.
  On the port it was validated against, a 4.6 FPS starter moved to 4.7, two
  runs of the *same* build differed by 0.083 units in `_process`-driven
  position and 8.35 percent between screenshots, while the cross-version pair
  differed by 1.85 percent, so the after-port run sat inside the noise. The
  guide also carries the per-minor break list, the rollback point that has to
  exist before the first launch, the reimport and resave passes, and the
  `config/features` string the upgrade never rewrites. Scope is 4.x to 4.x; a
  Godot 3 project goes through the engine's own converter first. It is marked
  beta on the strength of that single port.
- **`node.set_editable_instance` and `project.remove_setting`**. The first flips
  Godot's editable-children flag from the CLI, which the instanced-scene write
  guard (under Fixed) names as its remedy; the second removes a project setting,
  which until now required `--allow-unsafe-editor-io` code execution. The
  catalog is **332 commands** across the same 50 groups.
- **The `test.run_scenario` screenshot step saves evidence**: `save_path`
  routes the capture through the game-side screenshot handler and the step
  result names the file; without it the step reports `saved: false` instead of
  a bare `captured: true` that wrote nothing anywhere.
- **Four craft guides gained the breadth their titles promised**. `level-design`
  restructures around space families: the shared spine stays, the combat-interior
  material is named as one family, and exterior/open space (landmarks, terrain
  as pacing, walk-second travel budgets), 2D level design as its own discipline
  (screen vs scroll, the camera window as the sightline, room graphs), and
  pacing without combat are new. `shipping-export` gains the Android, web,
  macOS, and iOS legs with honest statements of what a Windows host cannot
  finish. `in-game-docs` gains the 2D equivalent of the gym/zoo/museum/notes
  patterns. `tile-constraint` names its GridMap 3D scope and bridges the 2D
  case to terrain painting.
- **Encryption's honest edges**. `save-systems` separates encrypting a save
  (`FileAccess.open_encrypted` and variants; the key ships in the binary) from
  validating one (`Crypto.hmac_digest`, live-confirmed); `multiplayer-patterns`
  states that ENet is plaintext UDP and names the DTLS setup calls; the
  shipping guide connects the APK-is-a-zip receipt back to `encrypt_pck`; the
  site's gotchas page corrects the two expectations readers bring.
- **The trailer guide became a matrix of cuts and formats**: duration profiles
  from a 15-second hook to a 2-3 minute feature, delivery profiles from 16:9 to
  9:16 composed per viewport rather than cropped, shot lists carrying
  per-profile framing, and a render manifest.

### Changed

- **Every em dash is gone from every shipped surface**. Roughly 1,700 of them
  across the craft guides, the site pages, the README, this changelog, the
  CLI's help and error text, and the addon's messages and source comments,
  each removed by rewriting its sentence rather than swapping punctuation.
  Code behavior is unchanged: only string literals and comments moved, and
  the full test suite plus a scratch-copy editor compile prove it.

### Fixed

- **`node.connect` never persisted a connection**. It connected without
  `CONNECT_PERSIST`, so the wire worked all session, `editor.signals` reported
  it, and the scene file never carried a `[connection]` line: everything built
  on it was dead on reload. Connections now persist (`persisted: true` in the
  result), and re-connecting an old non-persistent wire upgrades it in one undo
  step. `node.connect` also now refuses a target method that does not exist,
  with a nearest-name hint; `--allow-missing-method` overrides for a script
  that gains the method later.
- **Writes into an instanced scene's children were dropped on save, with a
  success envelope**. Godot's packer discards overrides on a non-editable
  instance, so `node.set` reported old and new values while the scene file
  never changed. Write paths across the node group now refuse (`-32009`)
  naming the instance and the remedy, `node set-editable-instance`.
- **Adjacent scenario input steps destroyed each other**. The editor-to-game
  input channel is a single file slot, and writing truncates it, so a press
  adjacent to another input step vanished while both reported `sent: true`; a
  payload arriving mid-`input.sequence` likewise discarded the sequence's
  remainder. Editor-side writers now wait for the game to consume the slot
  (bounded, naming a debugger break when the wait expires) and the game-side
  queue appends instead of replacing.
- **`test.report` scored every wait, input, and screenshot step as a failure**,
  so a green session read as 13 passed, 81 failed. It scores assertions only
  now and reports the other steps as `steps_recorded`.
- **`project.set_setting` silently created phantom settings on typos**: a
  mistyped key wrote a brand-new section into `project.godot` and reported
  success while the intended setting stayed unset. The result now carries
  `existed`, plus a nearest-key hint when a created key looks like a typo of a
  real one.
- **Packed-array properties truncated silently when handed one string
  literal**: a three-point polygon written as a single `"[Vector2(...),...]"`
  string became one point. The strict write path now parses the whole literal
  or refuses, naming the documented JSON-array-of-literals form.
- **`script.edit --insert-at-line` past the end of the file clamped silently**;
  the result now reports `inserted_at`, `clamped`, and the requested line.
- **`status --all` exited 1 when a successful scan found nothing running.** A
  scan that finds nothing has still answered; it exits 0 with the empty payload.
- **`script validate --path` false-failed on files under `addons/`**. The
  throwaway compile the command runs has no `resource_path`, so the
  `debug/gdscript/warnings/exclude_addons` exclusion (default on) never applied
  to it and any warning the project escalates to an error failed a file the
  editor itself compiles clean. The throwaway now carries a path under the real
  file's own `addons/` location, so the parser applies the exclusion the same
  way the editor does. A real parse error still fails, and a project running
  with the exclusion off keeps its addon warnings.
- **`install --enable` left out the two autoloads `runtime` and `input` need**,
  so a project installed that way answered every `runtime.*` and `input.*` call
  with a missing-singleton failure while the addon reported as installed and
  enabled. Godot runs a plugin's `_enable_plugin` hook only when someone ticks
  the checkbox in the editor, and that hook is what injects `MCPGameInspector`
  and `MCPGameInput`; writing the enabled line into `project.godot` never fires
  it. The installer now writes the pair itself. Running it again is a no-op,
  and a same-named autoload pointing at another script is reported rather than
  overwritten. **Affects 0.6.0 through 0.8.2**: on those versions, toggle the
  plugin checkbox off and back on in the editor, which runs the hook. `doctor`
  gained a **game autoloads** check that names the missing entries and prints
  the command that repairs them.
- **A scenario assert comparing a vector property against a string crashed the
  running game into the debugger**. GDScript treats `==` across those types as
  a hard error rather than a false result, so a typo in a `test run-scenario`
  step list stopped the game mid-run with nothing naming the step. An assert
  now coerces the expected value toward the type of the live one and returns
  `passed: false` with a `reason` naming both types.
- **A scenario input step silently turned a held action into a one-frame tap**.
  A pressed action is released again in the same batch unless the step sets
  `auto_release` false, which is the right default (an action never released
  stays down for every later step) and is also why a hold-then-wait moved a
  player 0.08 units instead of 7. The release is unchanged, the step result now
  carries `auto_released: true` when it happens, and the command's own docs
  state the default and the flag.
- **A stranded game reply could be delivered as the next command's answer**. A
  `runtime.*` call that gave up waiting, most often because the game had
  stopped at a debugger break, left its reply on disk for the following command
  to read and return as its own. Game IPC requests now carry a correlation id
  the game echoes back, and the editor discards a response that does not match.
  The old recovery that pressed the debugger's Continue button to free a stuck
  reply is gone: a break is reported and left where it is.
- **`script validate` wrote a phantom parse error into the editor's error log**
  for every script carrying a `class_name`. The throwaway copy it compiles
  registered as a second declaration of the same global class, so the editor
  logged "Class X hides a global script class" against a file that was fine and
  `editor errors` reported it afterwards. The declaration is stripped from the
  copy before the compile, with line numbers preserved so every diagnostic
  still points at the real line.
- **`status` read a live editor as absent on Windows**. The answering editor's
  project path and the caller's were compared as text, so an 8.3 short path
  (`D:\PROJEC~1\game`) and its long spelling read as two different projects
  and the verdict came back as if nothing had answered. Both sides now resolve
  to a real path before the comparison. A genuine project mismatch also
  reported a verdict that disagreed with its own advice, saying to wait while
  the action said to launch; it now reports `closed` or `crashed`, which is
  what the launch policy reads.
- **A malformed JSON flag value went nowhere and still returned success**. A
  value opening with `[` or `{` that did not parse was passed on as a plain
  string, and the addon's typed parameters discard a string they cannot read
  and fall back to a default, so a mis-escaped `--properties` returned every
  property inside a success envelope with nothing saying the flag had been
  dropped. Such a value is now an error naming the flag. A string meant to
  begin with a bracket or brace is sent verbatim behind a leading backslash
  (`--text '\[literal]'`).
- **`project tree --filter` returned every empty directory**. A directory whose
  files all failed the filter was still listed, so a narrow filter came back as
  the project's whole folder structure with a few files in it. Directories with
  no surviving descendant are pruned.
- **`godot-mcp --version` and `godot-mcp version` print the CLI version**. Both
  spellings failed before, the flag on an unknown-flag parse error and the bare
  word by being read as a command group.
- **`doc note --action add --at` now refuses a 2D scene** like its four
  scaffold siblings, instead of silently parenting a `Marker3D` under a
  `Node2D`. The release-gate verification build found it. The billboard
  labels the `doc` group creates are also named (`DocLabel`) so they are
  addressable, where they previously landed as unstable auto-generated names.
- **The 2D jump-arc measurement recipe in `level-design` works as written
  now**: it read positions from `runtime capture-frames`, which returns PNG
  frames; the corrected loop holds directional input and samples
  `runtime monitor`, and its numbers were verified against analytic jump
  physics. Every other claim in the two new-guide verification sessions
  passed against the live editor with results read back.

## [0.8.2] - 2026-08-12

The keeper's-light release: twelve defects found by driving a complete game
build through the CLI, each fixed at the root, plus the new `scene close` that
build showed was missing. It also carries the CLI's presentation pass (results,
help, and the banner now render for a human at a terminal while piped output
stays exact JSON) and the docs site's Godot MCP CLI identity and type pass.
A sustained project build now gates every release; the how and why is on the
site's new [How it's tested](https://regiellis.github.io/godot-mcp-go/docs/testing) page.

### Added

- **`scene close`**. Closes a scene tab, either `--path` or the active scene
  when no path is given, and reports the remaining `open_scenes` and the resulting
  `active_scene`. It closes the gap the rest of the surface assumed was covered:
  `scene delete`, `fs delete`, and `fs move` all refuse a scene that is open and
  told the caller to close the tab, which no command could do, so a throwaway
  scene could not be cleaned up without a person at the editor or a restart.
  Those three refusals now name `scene close` and the exact path to pass.
  Closing discards unsaved changes without prompting, so a scene with unsaved
  changes is refused with `-32009` unless `--discard true`; and closing a
  background tab restores the scene that was current, because Godot otherwise
  selects the closed tab's neighbour and every later `node` command would
  quietly target it.
- **`editor errors --clear` and `--internal=false`**. `--clear` drains the
  Output panel after reading, the same pull-then-drain contract
  `runtime errors --clear` already had. `--internal=false` drops the entries
  whose source file is the engine's own C++ rather than a project script.
  Every editor error line already carries its `<file>:<line>`, and a filesystem
  rescan after `editor reload` fills the buffer with dozens of
  `progress_dialog.cpp` and `class_db.cpp` lines that bury the parse error you
  were looking for. The default is unchanged, and a line whose source cannot be
  read is never treated as internal. Note that the engine attributes
  `push_error` and `push_warning` to `variant_utility.cpp`, so the filter drops
  those too.
- **`script read --start-line/--end-line`**. Returns a 1-based inclusive slice
  instead of the whole file, using the line addressing `script edit` already
  takes, so reading around a reported error line no longer costs the file.
  `line_count` still reports the file's real total. Both were previously
  accepted and ignored.
- **`project settings --filter`**. A case-insensitive substring match anywhere
  in the key, for when you know the word (`msaa`, `shadow`) but not which
  section owns it. `--section` remains the prefix match and the two combine.
  Also previously accepted and ignored.
- **`scene instance --path`** is accepted as an alias for `--scene-path`. Every
  other `scene` command names the file `--path`, so reaching for it here is the
  obvious mistake, and it used to fail on a missing `scene_path` while the flag
  was annotated as unknown.
- **Readable terminal output**. On a terminal, a result renders for a human: an
  object becomes a titled key/value box, an array of objects becomes a table,
  values are color-coded by JSON type, and a nested value too large for one
  line prints as an indented JSON block under its key. Help listings, `doctor`,
  and error/diagnosis output carry the same color scheme (traffic-light badges,
  cyan command names, red errors), and the top-level help is restructured into
  aligned Usage / Subcommands / Examples / Flags sections. Piped or redirected output stays exact
  pretty-printed JSON with no escape codes, so scripts and agents are
  unaffected; `--format pretty|json|tsv` pins a format explicitly and
  `NO_COLOR` drops the color while keeping the layout. The styling lives in a
  new zero-dependency `internal/ui` package that also enables VT processing on
  legacy Windows consoles.
- **Subcommand help is uniform**. Every local subcommand renders the same
  styled shape as the top-level help (heading, usage, notes, an aligned
  `--flag` table) instead of the raw single-dash `flag` dump, and three routes
  reach it, all exiting 0: `<sub> --help`, `<sub> help`, and `help <sub>`.
  Previously `create help` tried to run and failed on the missing `--path`.
  Section headings carry the accent, usage-line placeholders (`<group>`,
  `DIR`, `NAME`) tint magenta so the fixed words read apart from the
  fill-ins, and the banner carries the docs-site URL.
- **`status --all`**. Scans the editor auto range (9080-9095, plus any env- or
  discovery-pinned port) and the game range (9200-9215) concurrently and lists
  every live instance with its port, project name and path, Godot version, pid,
  and whether it serves the current project. A terminal gets the table render,
  piped output gets JSON (`editors` + `games` arrays); exit 0 when at least
  one editor is live. Game servers report presence only, because that channel
  carries no project identity to ask for.
- **The accent color is a burnt yellow**. Headings, command names, and the
  banner wordmark render in 256-color amber instead of cyan, keeping the
  traffic-light ok/warn/fail tokens as they were.
- **Docs site type and surface pass**. Code, commands, and terminal frames
  render in Source Code Pro; display headings (docs h1/h2, the landing hero
  and section heads) in Manrope; body text stays Inter. Callouts trade the
  accent side bar for a tinted full hairline on the same wash, and blockquotes
  get the matching quiet full-border surface.
- **The display name is Godot MCP CLI**. The docs site and README now present
  the product under the same identity as the Asset Library listing and the
  banner (which stylizes it GODOT MCPCLI). The command you type is still
  `godot-mcp` everywhere.
- **A front-door banner**. Running `godot-mcp` with no arguments at all now
  prints the brand mark as a block-glyph tile beside the wordmark (reading
  GODOT MCPCLI), the version, and where to go next, exiting 0. A bare
  invocation is a person exploring, not a script. Run inside a project it also
  reports that project's editor on one line (running with port and pid,
  starting, crashed, or none), from the same diagnosis `status` uses; outside
  a project it stays silent rather than probe a port that might belong to
  someone else's editor. Usage errors, `--help`, and
  `help` still print the structured help; there is no banner anywhere else, so
  no suppression flag is needed.
- **`--format ndjson` and `GODOT_MCP_FORMAT`**. NDJSON emits one compact JSON
  value per line for a top-level array result and the whole result on one line
  otherwise, keeping nesting intact where TSV flattens it. The environment
  variable pins a format for a whole shell or CI job when the flag is absent;
  the flag wins, and an unrecognized value warns and falls back to the
  default.

### Fixed

- **`scene create` now opens the scene it creates**. It wrote the file and left
  the editor where it was, so every following `node add` silently built into the
  previous scene, or, with nothing open, failed with a suggestion to "use
  scene.open or scene.create first" immediately after `scene create` had been
  used. The result reports `active_scene`, `--open=false` keeps the old
  behaviour for a batch that writes many files, and the no-scene error no longer
  names the command the caller just ran as the remedy.
- **`runtime screenshot` right after `scene play` returned an all-black frame**
  with no error. The capture read a viewport texture nothing had drawn into yet;
  the game now waits for a real `frame_post_draw` before reading it, and reports
  `black_frame` when the result is uniformly black anyway. A scene that is
  black by design looks the same, so this is a flag rather than an error.
- **Game commands failed intermittently with "Could not read game response
  file"**, where an immediate retry always worked. The game wrote its reply
  straight to the path the editor polls, and `FileAccess.open` creates that file
  empty, so a poll landing between the open and the close read a half-written
  file. The game now writes to a scratch name and renames it into place, and the
  editor's read retries briefly rather than treating one failed open as fatal.
- **A game paused at a debugger break timed out with the wrong explanation**.
  Every `runtime.*` call spent its timeout and then suggested checking the
  `MCPGameInspector` autoload, which the same call had already verified on disk.
  The editor now asks the debugger bridge and says what is actually true: the
  game is stopped at a break, with the reason, `debugger_breaked: true`, and
  `debug.state` / `debug.resume` as the way out.
- **`editor run_script` refused a space-indented body**. The submitted code was
  wrapped in a tab-indented function, so anything indented with spaces became a
  tab-and-space mix that GDScript rejects, for reasons the caller never saw. The
  body's common leading indent is stripped and what remains is re-expressed in
  tabs before wrapping, so space-indented, tab-indented, and already-nested
  snippets all compile.
- **`editor set_camera` posed the 3D camera without bringing the 3D screen with
  it**. It succeeded and returned a 3D pose while the editor's main screen sat
  on 2D, and the following `editor screenshot` captured the canvas: the right
  call, the wrong picture, no error anywhere. `set_camera` now switches the main
  screen to 3D (`--switch-main-screen=false` opts out), and both `screenshot`
  and `get_camera` report the active `main_screen`. A screenshot never forces a
  switch: capturing the 2D editor is a legitimate thing to want.
- **`input_map get_actions` could not see the project's own actions**. It read
  the InputMap of the *editor* process, which holds the editor's bindings
  (`ui_*`, `spatial_editor/*`) and not the game's, so a project's `jump` was
  invisible while `set_action` persisted it correctly. It now reads
  ProjectSettings `input/*`, which is where project.godot keeps them and where
  the running game reads them, and reports which source answered.
- **`spatial` refused every node without visual geometry**. A `Marker3D` or a
  bare `Node3D` anchor answered "has no 3D visual geometry", which made
  marker-to-marker questions unanswerable through the group that exists to
  answer them. Those nodes now read as a zero-size box at their origin, flagged
  `point_only` (per side, in `spatial relate`, which also returns `distance`
  now). Only a node with no transform at all is still refused.
- **`editor clear_output` did not clear anything**. It printed fifty blank lines
  to scroll the panel, leaving every old line in the buffer `editor errors`
  reads, so a "cleared" panel still answered with the errors it had just
  reported. It presses the Output panel's own Clear button, and falls back to
  the blank lines only when that button cannot be located, saying so.

## [0.8.1] - 2026-08-09

Documentation, media, and the skill archive. No command, addon, or CLI behaviour
changed, and the binaries and the addon are functionally identical to 0.8.0, so
this release exists to ship a new craft guide and the pages that came with it.

### Added

- **A craft reference on filming a game**, `game-trailers.md`, published as
  [Videos and trailers](https://regiellis.github.io/godot-mcp-go/docs/guides/game-trailers).
  It covers the shot list as the source of record, a dev-only director scene and
  the five rules that keep an unattended render honest, cutting between shots
  through a cover while the world runs backstage under `Engine.time_scale`,
  Godot's movie writer and its three output formats, the ffmpeg encode, and the
  `scene play` plus `runtime screenshot` loop that proves a shot before a render
  is spent on it. Two of its facts were measured rather than assumed: the
  recorded resolution comes from `display/window/size/viewport_width` and
  `viewport_height` rather than the window, since a 2560×1440 project filmed in
  a window forced to 1280×720 (with `--resolution 1280x720` passed as well)
  still wrote a 2560×1440 film; and under `--fixed-fps` tweens and timers
  measure film seconds while `Time.get_ticks_msec()` measures wall clock, which
  ran about four times longer than the footage it was writing.
- **A worked example for project-local commands**, answering what the
  `res://mcp_commands/` hook is actually for rather than only proving it works.
  `custom.broken_refs` sweeps the project's text files for `res://` paths and
  `uid://` ids that no longer resolve, with the file and line each sits on;
  `custom.replace_ref` repoints every reference from one resource to another and
  repairs the `ext_resource` uid beside each rewritten path, because the loader
  prefers a uid that resolves and a path-only rewrite still loads the old file.
  Between them they show both halves such a command may need: a read-only sweep,
  and a write path that guards its inputs, refuses a scene open in the editor,
  and plans every file before writing any of them.
  [Add your own commands](https://regiellis.github.io/godot-mcp-go/docs/extending)
  carries a compact version of the sweep.
- **A three-minute demo video** on the README, linked from a still: a seascape
  built inside a live editor, with water tuned while the game runs, boids for the
  fish and gulls, and audio buses wired from a panel.

### Verified

- **Godot 4.8-dev3** (`51105ccbe`), with no code change needed. The plugin
  compiled and bound both transports, all 329 commands registered, the HTTP MCP
  conformance suite passed 37/37, and a sweep over `project`, `scene`, `node`,
  `script`, `engine`, `runtime`, `input` and `debug` behaved as it does on 4.7.2,
  including the two-hop runtime IPC end to end.

### Fixed

- **The commands badge and one line under the context-cost table still read
  316**. The count has been 329 since the debug group landed in 0.8.0.
- **The Asset Library record named a download commit a release behind**. The
  `asset-library` branch was refreshed for 0.8.0 on 2026-08-07, but the record
  still pointed at the 0.7.x snapshot. A listing is pinned to whatever commit it
  was submitted with, so a stale note is how an old download keeps being served.

## [0.8.0] - 2026-08-07

The editor-side release: an interactive debugger the agent can drive, the
engine documentation's prose to go with its structure, and the dashboard
docked into the editor itself. 329 commands across 50 groups, every new
command driven live before landing.

### Added

- **The dashboard, docked in the editor**. The addon now ships an **MCP dock**
  (right side by default, movable like any dock) with the web dashboard's full
  feature set: stat tiles, error banner, top groups with per-method tooltips,
  recent errors, and the live timeline with filter chips. It adds what only an
  in-editor surface can, with stats read in-process (no extra process, no port,
  and no polling at all while the dock is closed), full call parameters on
  each row's tooltip, and a Reset button. The design language is the web UI's
  instrument-cockpit look (flat blocks, hairlines, zero radius, mono numerals,
  the Godot-blue accent) translated onto colors derived from the editor theme,
  and every dimension scales with the editor's display scale.
  `godot-mcp dashboard` (the web UI) is unchanged; both read the same
  counters.
- **The `debug` group: an interactive debugger for the editor-launched game**
  (329 commands, 50 groups). `set_breakpoint` arms a line through the editor's
  own script gutter, so it is visible in the gutter and the Breakpoints list,
  live for a game already running, and kept for the next run. It refuses lines
  that can never be hit (blanks, comments, declarations) with the first executable line
  suggested instead; arming a per-frame callback like `_process` earns a
  warning, since every resume would re-break immediately. `state` and `frame`
  read the paused game's stack and variables, `step`/`resume`/`pause` drive
  execution through the debugger's own controls, and `reload_scripts`
  hot-reloads edited `.gd` files into the live process with state kept.
  `scene.play` now launches every run with the editor's script-sync options
  armed so a reload always applies. Verified end to end against a live 4.7.2
  game: break at a line, step, read a variable change, resume, pause into
  `_process`, and a hot-swapped function returning its new value without a
  restart.
- **`engine.docs` and `engine.doc_search`: the engine's documentation prose,
  live from the editor's doc cache.** `engine.class_info` answers what exists;
  these answer what it means, with the running build's own Help-panel text.
  `docs --class C [--member m]` walks the inheritance chain, finds annotations
  with or without the `@`, and covers pages ClassDB has never held
  (`@GlobalScope`, `@GDScript`, the Variant types, with an enum name like `Key`
  returning its values). `doc_search --query "wrap text"` searches names and
  prose by concept and ranks name hits above prose hits, so the half-known
  term surfaces first. Unknown names come back with closest-first suggestions.
- **`editor.activity`: poll what happened in the editor since a cursor**.
  Selection changes, scene switches, scene and resource saves, and undo/redo
  history bumps are buffered in a 200-entry ring (`services/activity_log.gd`) and
  read with the same `--since-seq`/`--clear` cursor contract as
  `runtime.errors`. An agent sharing the editor with a person can now see what
  the person just did between commands: click a node, save a scene, hit
  undo. `edit` events include actions the MCP's own
  commands commit, and the command's result says so. Verified live: commit,
  undo (via an injected Ctrl+Z), selection, and save each produce exactly one
  event.

## [0.7.2] - 2026-08-03

Documentation only. No command, addon, or CLI behaviour changed. The agent skill
and the craft guides did change, so the skill archive is worth updating even
though the addon is unchanged apart from a one-word fix in its README.

### Added

- **A changelog page on the docs site**, at `/docs/changelog`. It renders this
  file rather than a copy, so the published history and the file maintainers
  actually edit cannot disagree. Every release anchors, so deep links work, and
  the search index covers it: looking up a feature in the docs now also finds the
  release it shipped in.

### Documentation

- **Every prose surface went through the writing linter, reading the matched
  spans rather than the summary counts.** That covers the README, INSTALL, both
  addon READMEs, all 18 docs pages, this changelog, and the 28 craft guides,
  which had never been linted at all despite being published as guide pages.
  Most of the volume was bullet labels shaped `- **Sentence.** Body`, where the
  period sits inside the bold; the rest were empty intensifiers and vague words
  swapped for the concrete thing meant, such as gapless looping in the audio
  guide and "things they can't use must look unusable" in the level-design one.
  Every surface now reports only findings that were reviewed and deliberately
  kept, each with a recorded reason.
- **The Godot builds behind the 4.7+ claim are named** in the README, the
  installation page, INSTALL, and the addon README: `4.7.1-rc`, `4.7.2-rc`, and
  a `4.8-dev` build from `master`. That last one is a master build rather than
  the published dev 2 snapshot, and is described that way. The note carries the
  consequence worth knowing before opening a 4.7 project in 4.8: 4.8 writes a
  `unique_id` attribute into saved scenes that 4.7 does not, so the round trip is
  not clean.
- **The comparison names projects rather than org paths**, `godot-ai` and
  `Godot-MCP-Native`.

## [0.7.1] - 2026-08-03

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

## [0.7.0] - 2026-08-03

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
  `class_name`, which `engine class-info` cannot, and that is the ordinary case
  of a `player.gd` attached to a node. `--include-inherited` walks the base-script
  chain.
- **`ai-steering.md` craft reference**. Agent movement that reads as a creature
  rather than a cursor: accelerating toward a desired velocity instead of
  assigning it, arrive/flee/pursue/separation as summable forces, blending versus
  priority, facing, and 3D differences. Every recipe was driven against a live
  4.7 editor and verified numerically rather than by screenshot.
- **Input-action validation in `character-3d.md`**. A controller that reads an
  action nobody mapped does not error. `Input.is_action_pressed` on a missing
  action returns `false` forever, so the character silently never sprints and
  nothing says why. The guide now takes action names as `@export`s and checks
  them in `_ready`.

There is deliberately **no** `script format`. Reformatting safely needs a real
parser, because a wrong linter prints a bad line while a wrong formatter
corrupts source, and the tree-sitter route would mean CGO, breaking the `CGO_ENABLED=0`
six-target cross-build. Linting was tractable without a parser; formatting is
not.

### Fixed

- **`script lint` reports which files do not compile**. Style rules read source,
  so they report on a file that does not parse, and zero findings there would
  read as clean, which is the opposite of the truth.
- **`no-else-return` reads the last statement, not the last line**. A
  `return success({` spanning eight lines ends on `})`, hiding the return; and a
  `break` nested inside a deeper `if` is not the branch's own last statement, so
  counting it flagged an `elif` that was required.
- **A `const` bound to `preload()`/`load()` accepts CONSTANT_CASE or
  PascalCase.** Both are idiomatic: a type when it holds a script, an asset when
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

## [0.6.3] - 2026-08-01

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

## [0.6.2] - 2026-07-28

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

## [0.6.1] - 2026-07-28

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

## [0.6.0] - 2026-07-28

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
  session, a standing chore for anyone who does not want dev-only autoloads in their
  commits. Worse, the shutdown save persists whatever the in-memory settings hold
  *after every plugin has torn itself down*: observed 2026-07-27 in a consumer project,
  one quit dropped a DIFFERENT addon's seven committed autoloads, which would have
  shipped a game that could not boot. Export is unchanged, since disabling the plugin still
  removes them. Projects that keep the plugin enabled should now COMMIT the two
  autoloads, since nothing re-adds them at load.

- **A missing game-side autoload is now diagnosed instantly, where it used to
  take a timeout or go unreported entirely.** Every editor→game entry point
  (`runtime.*`, `input.*`, `test.*`) now checks that `MCPGameInspector` /
  `MCPGameInput` are present in the **on-disk** `project.godot` before it
  writes an IPC request, reading the same file `get_game_user_dir()` already
  parses. The launched game loads that file itself, so an autoload the editor
  holds only in memory does not exist in the game; the on-disk copy can lose
  one after plugin-enable, most often in projects that deliberately keep these
  dev-only autoloads out of version control and then revert or check out
  `project.godot` mid-session. Every editor-side command keeps working in that
  state (`project.info` still lists both autoloads), so only the game hop
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
  property reads as nil, so the path was assigned as text and discarded. `node.set`
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
  trigger, `var x := <untyped expression>`, is easy to write by accident. That
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

## [0.5.0] - 2026-07-27

The editor stops needing a middleman: it speaks MCP itself over streamable
HTTP, so an HTTP-capable client connects with no Go process in between. Also
the release where the new endpoint's `Origin` gate was added, then found
bypassable and hardened.

### Added

- **The editor is now an MCP server itself, over streamable HTTP with zero
  external process.** The addon hosts `POST /mcp` on `127.0.0.1` (auto port 9100-9115;
  `GODOT_MCP_HTTP_PORT` or the `godot_mcp/network/http_port` setting pins one),
  so any MCP client that speaks streamable HTTP connects straight to the
  running editor. Tools mirror `serve`: the generic `godot_run` plus every
  documented command as a typed tool with a real schema, dispatched through
  the same command router, with all guards applying unchanged. The
  `godot_mcp/network/http_typed` setting collapses the list to `godot_run`
  alone for tool-limited clients, `godot_mcp/network/mcp_http` turns the
  endpoint off, and the discovery file now carries `http_port`.

- **MCP prompts in `serve`**. The stdio MCP server now declares the prompts
  capability and ships four static prompts distilled from the agent skill
  (`discover-then-drive`, `spatial-placement` with an optional `target`
  argument, `launch-recovery`, and `bug-hunt`), embedded in the binary and served via
  `prompts/list`/`prompts/get` even when the editor is down. The playbook now
  rides along as first-class MCP prompts, not just the `instructions` string.

- `scripts/test-http-mcp.ps1` (`task test:http`): a 37-check conformance sweep of
  the HTTP endpoint against a live editor, covering handshake and protocol
  negotiation, tool-surface legality, router dispatch and error mapping, HTTP framing
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
    `Vector2(0, 28)`, because `_numbers()` stripped a `Vector2(` prefix but not `[`.
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
  active returned `opened:true` while the editor stayed put, and every later
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
  POST to `http://127.0.0.1:9100/mcp` and reach `editor.run_script`, i.e.
  arbitrary code execution, and the wildcard `Access-Control-Allow-Origin`
  even let it read the replies. Requests with no `Origin` (native MCP clients, curl, the Go
  CLI) and loopback origins are served as before; any other origin now gets
  `403` with the connection closed, and `Access-Control-Allow-Origin` echoes the
  allowed origin instead of `*`. The WebSocket transport cannot be gated this way
  (Godot exposes no handshake headers server-side, and browser WebSockets are
  exempt from CORS) and that is an accepted limitation, not a pending fix. The
  ports are unauthenticated by design, so treat a running editor as reachable by
  anything local. The docs now carry a **Threat model** section spelling this out.

## [0.4.0] - 2026-07-22

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
  session-only provenance tracking, but injection saves `ProjectSettings`, so
  from the second session on the autoloads read as project-owned and disable
  left them behind (the one manual step in every ship-the-game flow). Removal
  now matches by ownership: an `autoload/MCPGame*` entry is removed iff its
  value points at the addon's own service script; unrelated autoloads a project
  declares itself are untouched.

### Added

- **Typed MCP tool schemas in `serve`**. The stdio MCP server now exposes every
  documented command as a first-class tool with a real JSON schema, carrying the
  name (`node_add`), a description, and per-param types and `required`, built **live**
  from the addon's `get_command_docs()` on the first `tools/list` and cached,
  so the tool surface can never drift from what's registered. `godot_run`
  stays as the generic escape hatch (and gains an optional `game` argument);
  `runtime_*`/`input_*` typed tools carry an optional `game` bool that routes
  the call to a standalone debug game's direct server, the MCP half of the
  player channel. Editor down at connect degrades to `godot_run` alone, and a
  later successful editor call upgrades the list via
  `notifications/tools/list_changed`. `serve --typed=false` opts tool-limited
  clients back to the single generic tool.
- **Direct-to-player channel**, driving a standalone running game with **no
  editor**. With the project setting `godot_mcp/runtime/direct_server` on, a
  **debug-build** game hosts its own `127.0.0.1` WebSocket server (ports
  9200-9215, `GODOT_MCP_GAME_PORT` pins) serving `runtime.*`/`input.*` with
  identical param shapes through the same game-side handlers the editor's file
  IPC uses (shared dispatch, nothing duplicated), plus a `user://`
  discovery file with the same stale-pid contract as the editor's. The CLI's
  `--game` flag routes there, resolving the game's user-data dir from
  `project.godot`. Hard-gated on `OS.is_debug_build()`, so a release export can
  never host it even if the setting ships enabled. Verified live: a standalone
  game driven (`tree`/`eval`/`get`/`input`) with zero editor processes, clean
  quit removes the discovery file, and the editor-brokered channel coexists
  unchanged.
- **Per-command param docs** (the Unity `[CliArg]` equivalent). A command group
  can expose `get_command_docs()`, a per-command description plus param name /
  type / required / one-liner, and the router serves it live: `engine.commands
  --group G` attaches the group's docs (`--docs` for the full catalog), and the
  CLI renders them: `godot-mcp <group> <command> --help` prints a real param
  table, group listings gain one-line descriptions. Authored for the **entire
  catalog, all 49 groups and 312 commands** (plus the project-local example),
  with every param extracted from
  handler code, not memory, and group gotchas folded into the descriptions;
  project-local `mcp_commands` files carry docs via the same hook (the shipped
  example demonstrates it). A group without docs (e.g. a third-party command
  file) degrades to the generic dynamic-params hint.
- **`godot-mcp doctor`**, an environment preflight: godot binary + version,
  project resolution, addon installed/enabled, effective port source (env /
  per-project pin / auto, warns when env and pin disagree), editor liveness
  verdict, dotnet for C#. `--project DIR`, `--json`; exit 1 only when a check
  fails (warns don't fail, since doctor may run before any editor is launched).
- **`--format tsv`**, a global flag rendering a success result as tab-separated
  text for shell pipelines: array-of-objects → header + rows, object →
  key/value rows, nested values as compact JSON, tabs/newlines escaped.
  Default `json` (pretty) is unchanged.
- **Per-project MCP port setting**. A new project setting `godot_mcp/network/port`
  (Project → Project Settings, int, default `0` = auto) pins the WebSocket port
  per project, persisted in that project's `project.godot`, so two concurrent
  projects listen on distinct ports deterministically. Port precedence is now
  `GODOT_MCP_PORT` env > the project setting if > 0 > the auto range 9080-9095.
  The setting registers idempotently on plugin enable and survives disable/enable;
  `set_initial_value(0)` keeps the default out of `project.godot`, so enabling the
  plugin never dirties the file. The bind stays `127.0.0.1`-only (no host setting).
- **Project-local commands**, extending the MCP without forking the addon. On plugin
  enable the router scans `res://mcp_commands/*.gd` and registers each file's
  `get_commands()` alongside the built-ins, so custom commands appear in the CLI,
  `godot-mcp help <group>`, and `engine commands` automatically (no Go changes). A
  valid file instantiates to a Node exposing `get_commands() -> {"group.command":
  Callable}` (extend `base_command.gd` or a plain Node); a bad file is skipped with
  a warning and never breaks startup, and a name colliding with a built-in is
  skipped, since built-ins win. Ships with a committed example, `custom.ping`/`custom.echo`.
- **Nested CLI help** (312 commands / 49 groups): `godot-mcp <group> --help`
  (also `-h`, `godot-mcp <group> help`, and `godot-mcp help <group> [<command>]`)
  lists a group's commands, and `godot-mcp help all` prints the entire catalog
  grouped by category; an unknown group or command lists what does exist.
  The catalog stays out of the Go binary: help is served live by the new
  `engine.commands [--group G]` introspection command, which returns flat
  `methods` plus a `groups` map of group → command names, so automation built on
  the JSON gets the surface by category without splitting prefixes. It falls back
  to the `available_methods` payload older addons return on `-32601`, so it needs
  a running editor and never goes stale.

- **`shipping-export.md` craft reference**, covering the release pipeline: dev-tooling
  exclusion (this addon must never ship), the headless export loop, PCK
  encryption with keyed custom templates (`SCRIPT_AES256_ENCRYPTION_KEY` at
  compile, `GODOT_SCRIPT_ENCRYPTION_KEY` at export, both verified on 4.7),
  size-optimized template builds, and receipt-based verification (pck plaintext
  scans; a booting exe as the key-match proof). Distilled from a real 4.7
  desktop release.

- **C# project support** (311 commands / 49 groups): a new `csharp` group with
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

## [0.3.0] - 2026-07-17

AI-client integration (read-only `godot://` MCP resources, `configure`, Asset
Library readiness), running-game error capture and signal awaits, git-aware
batch script validation, project bootstrapping from nothing, blend-space
authoring for `anim_tree`, and eight new craft references. First public release.

### Added

- **`runtime.errors`**: poll runtime errors/warnings the running game captured
  via `OS.add_logger` (a `Logger` subclass registered by MCPGameInspector).
  Entries are structured `{kind, message, code, backtrace[]}` with the game-script frame in
  `backtrace[0]`, `--since-seq` for incremental reads, `--clear` to drain.
  Pull-based (no doorbell) and runtime errors are unambiguously real. Live-
  verified capture of errors + warnings with backtraces; the game survives an
  error storm (bounded ring buffer, re-entrancy guard). Note: a *real* script
  error under a `--headless` editor trips the debugger break and freezes the
  game, while push_error/warning/shader errors and windowed/standalone runs are fine.
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
  as a success payload agents can branch on). Arity-matched one-shot
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
  effect types: `pitchshift`, `hardlimiter`, `spectrum`, `record`, `capture`.
- **Blend-space authoring for `anim_tree`** (closes the last gap from the
  genre-doc pass): `anim_tree.create --root-type blend_space_1d|blend_space_2d`
  and `anim_tree.add_state --state-type blend_space_1d|blend_space_2d` build the
  node; new `anim_tree.set_blend_point` / `anim_tree.remove_blend_point` manage
  its clips; `get_structure` reads blend points back. What was a `run-script`
  workaround in `game-patterns.md` is now first-class, verified live, including
  a running-game drive of `parameters/blend_position`. (307 commands total.)
- **Four genre craft docs** closing the audit's genre axis: `character-3d.md`
  (FPS/third-person/platformer controllers, whose movement core was built and
  driven live through the CLI itself: gravity, basis-relative heading, jump
  all verified numerically), `save-systems.md` (collector pattern, format
  tradeoffs, atomic autosave), `multiplayer-patterns.md` (authority, @rpc
  compile-probed, spawner/synchronizer wiring), `shaders-vfx.md` (the 2D VFX
  kit plus a programmatic .gdshader compile-verification loop).

## [0.2.0] - 2026-07-11

### Added

- **TileSet authoring** (`tilemap` group): `tilemap.create` (TileMapLayer with a
  fresh TileSet, `--tile-size`), `tilemap.add_atlas_source` (texture atlas with a
  tile auto-created per grid cell), `tilemap.add_scenes_source` (PackedScenes as
  paintable tiles, the scene-prefab blockout workflow; painted cells carry real
  collision), and `tilemap.set_terrain` (autotile painting/erasing via
  `set_cells_terrain_connect`). `get_info` now reports terrain sets and scene
  sources. Live-verified, including the engine gotcha that a terrain with no
  island tile (terrain assigned, zero peering bits) silently places nothing for
  isolated cells.
- **2D lighting extensions** (`lighting` group): `emissive_2d` (exempt a
  CanvasItem from darkness, unshaded/light-only, with optional additive blending),
  `normal_map_2d` (wrap a sprite's texture in a `CanvasTexture` with
  diffuse/normal/specular so 2D lights shade it directionally), `glow_2d`
  (enables `rendering/viewport/hdr_2d`, which requires a restart, and adds an
  additive-glow `WorldEnvironment`), plus `occluder_2d --sdf-collision` /
  `--occluder-light-mask`. Screenshot-verified against a live scene.
- **`scene2d.add_animated_sprite`**: AnimatedSprite2D + SpriteFrames authored
  from a spritesheet grid in one call: `--hframes/--vframes` slicing, named
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
  blackboard, wave weight-budgets, seeded self-auditing worldgen), plus major
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
  project: `godot-mcp install-assets [--pack NAME] [--dest assets/vendor]
  [--list] [--force]`. Each pack is copied whole (its `License.txt`/source files
  kept, so attribution stays intact) into `<project>/assets/vendor/<pack>/` by
  default; `--dest` overrides (project-relative or absolute), `--pack` narrows to
  one, `--list` enumerates without a project. It is a local command and does not
  dial the editor. Refuses to overwrite an existing pack without `--force`.
- **Bundled pack: `kenney_prototype_textures`** (Kenney Prototype Textures,
  CC0), grid/checker greybox skins in per-colour `PNG/` folders, shipped in the
  addon zip.
- **Level-design craft reference** (`skills/godot-mcp/level-design.md`): blockout
  process/strategy and in-level spatial-communication tactics, each mapped to
  `godot-mcp` build recipes: Big→Medium→Small risk-ordered passes, a greybox
  colour language, 2.5D depth/value + grayscale test, designer-vs-stakeholder
  presentation stages, greybox lighting stages, and the prototype-texture workflow.
- **Game feel vs juice** section in `skills/godot-mcp/game-patterns.md`: the two
  as distinct layers (control-code vs signal-fired feedback) with verified 4.7
  recipes (coyote time/jump buffer/accel, squash-stretch/hit-stop/screen shake)
  and a reusable `Juice` autoload stack.
- **Environment art pass craft reference** (`skills/godot-mcp/environment-art.md`):
  the art pass after the greybox is proven, covering greybox→art handoff, PBR materials,
  real lighting (SDFGI/LightmapGI/VoxelGI), `WorldEnvironment` post, decals/
  particles/fog, set dressing + `MultiMesh`, occlusion/LOD, and the "don't lose
  the read" through-line. Tool boundary: meshes/textures authored externally.
- **`editor run_script --path`** runs an editor script from a file (`res://`,
  `user://`, or an absolute OS path) instead of only inline `--code`, so large
  scripts aren't shoved through the shell. `code` still works; `path` takes
  precedence when both are given.
- **`scene validate`** scans the open scene for integrity problems that don't
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
  could crash like `set_camera`, since each already guarded the cast, but a
  silently ignored param gives an agent no feedback.)
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
  flagged every `VisualInstance3D` that wasn't resting on something directly
  below, so lights, decals, fog, GI probes, particles, sprites, MultiMesh scatter (no
  "rests on a surface" meaning) *and* all mounted/hanging/attached geometry got
  reported. Now it only considers solid geometry (`MeshInstance3D`/`CSGShape3D`)
  and treats a piece as supported if it touches/overlaps another solid (5 cm
  contact tolerance) or rests just above one. On a fully dressed scene this drops
  ~60 false positives to zero while still catching an isolated float.

## [0.1.0] - 2026-06-18

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
  `search`, `singletons`) queries the live `ClassDB` so an agent can discover
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
