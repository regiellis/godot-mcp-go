# Porting a Godot 4.x project to 4.7 with godot-mcp

Moving a project from an older 4.x release to 4.7 is a reimport plus a short list of real breaks.
What decides whether the port succeeded happens on either side of that: a recorded picture of how
the game behaved before, and the same drive replayed after. `godot-mcp` runs the game, drives it,
and reads state back, so the comparison is frames and numbers instead of memory.

Scope is **4.3 and up to 4.7**, the range the addon runs in. Godot 3 projects are out of scope.

Confirm anything below against the running build (`engine version`, `engine class-info --class
TileMap`) rather than against this page. The shapes are stable and the signatures move.

## The `upgrade` pipeline

`godot-mcp upgrade <phase>` runs the six phases below as commands. Each phase is a gate: it does
its work, writes a report under `<project>/.godot/upgrade/`, and stops. Nothing runs the next
phase for you, because every phase ends with something a person should read. The phases are the
spec for the commands, and each phase's **Build** block names the command that runs it.

| Phase | Command | Needs | Writes |
| --- | --- | --- | --- |
| 1 pre-flight | `upgrade preflight [--old-godot PATH] [--godot PATH]` | a clean tree, no editor | `preflight.json`, one commit forcing warnings on |
| 2 baseline | `upgrade baseline --old-godot PATH [--scenario FILE]` | the old binary (4.3+) | `baseline/` frames, numbers, errors |
| 3 open | `upgrade open --godot PATH` | the new binary | a tag, a branch, `open.json` with the bucketed to-do list |
| 4 and 5 fix | `upgrade fix --category NAME [--dry-run]` | the new editor running | one proved edit per category, one commit each |
| 6 verify | `upgrade verify --godot PATH [--scenario FILE]` | the new binary | `verify.json`, the delta table |

**What every phase reads, because the Output panel is not the whole story.** An editor's error
panel shows the last few dozen lines, the analyzer results of scripts that happen to be open, and
nothing that printed before the panel existed. Two of the costliest breaks print nothing at all: a
property the new version dropped on resave, and a deprecation whose warning is off by default.
So the harvest reads seven sources, and a report names which source each finding came from:

1. The launch log. `launch --headless` captures the editor's whole stdout and stderr to
   `.godot/godot-mcp-launch.log`, unbounded, so boot-time failures (autoloads, `@tool` scripts)
   and the full reimport flood are there when the panel has already scrolled past them.
2. Warnings forced on. `preflight` sets every `debug/gdscript/warnings/*` level to at least `warn`
   in its own commit before the first open (a key the engine defaults to `error` keeps the error,
   since lowering it during a port is the opposite of the point), and `verify` puts them back at
   the end. The parser reads these through a cached path, so a change made while the editor runs is
   invisible to it; it has to be in `project.godot` before launch. **Reverting that commit is not
   enough on its own**: the editor prunes any setting equal to its default on the next save, so most
   of the block is already gone by then and git's three-way merge reads the whole hunk as reverted.
   `verify` runs the revert and then repairs whatever it left, key by key, through
   `project set-setting` and `project remove-setting`.
3. `script validate --all`, the tree-wide compile.
4. Every scene, opened and validated. `scene validate` flags a `MissingNode` or `MissingResource`
   placeholder and an `ext_resource` whose path no longer exists; `preflight` runs the same check
   offline over the `.tscn` and `.tres` text before anything is rewritten.
5. The resave diff. The first open rewrites scenes, resources, and `project.godot`. `open` diffs
   every file the editor touched and reports each property or setting that went missing, as
   `scene, node, property`. This is the only place a silent drop shows up.
6. The static rename sweep. The rename table matched against every `.gd` as text. A renamed
   method called on an untyped variable compiles clean and fails at runtime, so the compiler cannot
   find it; the text can.
7. The drive. `baseline` and `verify` play the scenario and poll `runtime errors`; a fault breaks
   into the debugger and the report carries `debug state`'s stack. Coverage is whatever the drive
   exercised, and the report says so.

**`fix` applies, then proves it, then keeps or restores.** Report-only is what the editor already
gives you. Each category runs as one loop: capture (`authoring checkpoint --action capture`, a git
tag, and the category's count from `open.json`), apply through the tool's own commands
(`script edit` for text rewrites, `scene open` plus one `editor run-script` extraction plus
`node delete` and `scene save` for the TileMap conversion, `project set-setting` for the feature
tag), then prove it: `editor reload`, `script validate --all`, `editor errors --internal=false`,
the drive. The category's count must reach zero and neither the compile's failure count nor the
error panel's may get worse. If either fails, `fix` restores the checkpoint, checks the files back
out, and reports why with `debug state`'s stack attached. `--dry-run` prints the diff and touches
nothing. The categories `fix` can apply are the mechanical ones: the rename table, `@export_file`
to `@export_file_path`, the typed `Dictionary` cast, the TileMap to TileMapLayer rewrite, the
feature tag, and `.uid` sidecars. A GDExtension addon with no build for the target is the one
finding that stays a report, and `preflight` refuses to continue past it.

**The rollback unit is the checkpoint plus git, not one undo.** Every addon command commits its own
`EditorUndoRedoManager` action and the wire has no way to group several calls into one, so a
category taking more than one command cannot be a single Ctrl+Z. The checkpoint holds the scene's
node identities and transforms, git holds everything else, and a failed proof restores both. Two
further limits worth knowing before reading a report: **the error panel is a running buffer**, so
both proof snapshots drain it and rescan rather than comparing raw counts, and **the rename table
ships report-only**, because every symbol the supported range changed either drops an argument or
has no replacement at all.

Scope is 4.3 and up on both sides, because the addon's floor is 4.3 and `baseline` needs it in
the old editor. Two binaries have to be on disk; the commands take both explicitly and guess
neither. The headless editor `open` launches stays up afterwards, because `fix` and `verify` drive
it; close it yourself once the port is done (`status` names its pid).

**Verification.** The pipeline was driven end to end on 2026-08-30 against a copy of the
`starter-kit-basic-scene` project carrying six planted breakages: a `TileMap` with two layers and
six painted cells, two scripts using `@export_file` beside a `res://` prefix test, a
`: Dictionary = JSON.parse_string` line, a `.tscn` with an `ext_resource` path that does not exist,
a `get_layers_count()` call site, and a feature tag naming 4.6. `preflight` found all six and
committed 50 warning settings; `baseline` recorded six numbers and two frames with no runtime
errors; `open` tagged, branched, settled the reimport in three reloads, and bucketed the findings
across eight categories; `fix` applied `export_file`, `typed_dictionary`, `tilemap` and `settings`
to zero and committed each, refused `renames` as report-only, and found `uid` already resolved by
the first open; `verify` replayed the drive to identical numbers and 0.00 percent changed pixels on
both frames, and restored all eight surviving warning settings. A deliberately broken rewrite was
run through `fix` as well: `script validate` went from 0 failures to 1, the category was restored,
nothing was committed, and the file came back byte for byte.

**Two cross-version runs ground the numbers.** A genuine 4.4 editor (`4.4.2.rc`, built from the
engine's `4.4` branch) drove `--old-godot` against two beds, each imported and resaved by 4.4
first. On the small planted-breakage bed the two versions render identically and every frame pair
compared at 0.00 percent. On `starter-kit-3d-platformer`, a real lit 3D scene, `preflight` flagged
four scripts failing the cold parse on both binaries equally (the project's `Audio` autoload,
which the parse-only check cannot resolve; identical on both sides means it is not an upgrade
break), the resave diff caught 4.7 silently dropping `glow_levels/5` from the environment
resource, and `verify` measured the honest cross-version render noise: mean 7.76 percent and peak
12.09 percent of pixels changed per frame at the default threshold of 10. Read the delta table
against that floor: on a real 3D scene, single-digit percentages are version noise, and what
matters is a frame pair that jumps far above its neighbours. That platformer run is also what
caught the comparison lying: every pair reported 0.00 while six-figure pixel counts sat beside it,
because the percentage was decoded from a field the addon does not send. Numbers a phase prints
deserve the same suspicion as numbers the engine prints.

**The 2D floor is different in kind.** A third bed, an animated 2D scene authored through the
addon (eight sprites, a dark `CanvasModulate`, three moving shadow-casting `PointLight2D`s, two
occluders), measured 4.4 to 4.7 at mean 0.00 and peak 0.01 percent changed pixels across 300
frames. So read the table per dimension: the 2D canvas pipeline replays near bit-identically
across these versions and any visible percentage on a 2D scene deserves attention, while a 3D
scene carries a several-percent floor before anything is wrong. Glow, custom shaders, and
particles are unmeasured on both floors.

## What breaks between 4.x minors

Most minor-to-minor change is additive or widens a type (`String` to `StringName` is the recurring
one), so a GDScript project usually opens and runs. C# breaks more often, because binary
compatibility is not held across minors. The changes that cost hand work:

| Release | Change | What it costs |
| --- | --- | --- |
| 4.3 | `TileMap` deprecated in favour of `TileMapLayer`, one node per layer | scene surgery plus a script port off the layer-indexed API |
| 4.3 | GDExtension dropped `close_library` / `initialize_library` / `open_library` | a GDExtension addon needs a rebuild by its author, which nothing local can do |
| 4.4 | `.uid` sidecar files appear beside scripts and shaders | commit them, and move them with their file |
| 4.4 | `@export_file` began returning `uid://` paths | code that string-matched `res://` stops matching (4.5 added `@export_file_path` to force the old shape) |
| 4.4 | typed `Dictionary` | an untyped `JSON.parse_string` result no longer assigns into one |
| 4.5 | Android C# export requires .NET 9 | other platforms stay on .NET 8 |
| 4.7 | nothing breaking listed for GDScript | a 4.6 project opens, compiles, and runs as it is; one live port compiled 7 of 7 scripts with no edit, leaving reimport and resave as the whole job |

The project config version does not change inside 4.x (`config_version=5`), so 4.7 shows no
conversion dialog. It reimports the whole project and regenerates `.godot/`, which takes minutes on
a large project and floods the error panel with warnings that mostly clear on the second pass. A
project older than 4.2 gets one extra dialog about mesh compression: **Restart & Upgrade** writes
the change permanently, **Upgrade Only** keeps it in memory for the session.

## Phase 1: pre-flight, before an editor opens

Nothing here needs an editor, and `godot-mcp install` does not dial one either. Launching the editor
is the step that starts rewriting the project, so it comes after all of this.

**Build:**
```
godot-mcp install --project . --enable   # this dirties the tree, so it lands on its own
git commit -am "chore: install godot-mcp addon"
godot-mcp upgrade preflight --old-godot <old binary> --godot <new binary>
```

`upgrade preflight` is the phase. It reads `config/features` and the config version, parses every
`.gdextension` and refuses outright when one has no build for this machine, finds `TileMap` nodes
still in scenes, sweeps every `.gd` for the patterns below, lists scripts and shaders with no `.uid`
sidecar, and reports each `ext_resource` path that is not on disk. With both binaries named it also
runs the cold parse sweep under each, so a script that fails only under the new one is a real port
finding rather than one that was already broken. It requires a clean tree, writes
`.godot/upgrade/preflight.json`, and ends with the warnings commit described above.

Run by hand, the same reading is:
```
grep config/features project.godot     # PackedStringArray("4.2", "Forward Plus")
ls addons/                             # every entry is its own compatibility question
git status --porcelain                 # must come back empty before anything else runs
godot-mcp check .                      # cold parse, no editor
```

Order matters. The clean check comes first, then the addon install as its own commit. Installing
before the check turns "must come back empty" into a judgement call, and installing without
committing mixes the addon's own files into a port diff that later has to be read as one migration.
The rollback branch and tag are `upgrade open`'s first act, before it launches anything.

Each third-party addon needs its own 4.7 answer before the editor opens, because the first launch
enables what is already enabled and runs its code. A **GDExtension** addon (a `.gdextension` file
beside platform binaries) is the one that can hard-block the port: those binaries are compiled
against a specific engine ABI, and only the addon's author can rebuild them. Note each addon's
version and its stated Godot support, and disable any that has no 4.7 build before the first open.

The rollback point has to exist **before** the first launch. Opening in 4.7 rewrites `project.godot`
(its own settings, and the section order they are written in) and resaves scenes as it touches them.
It does **not** rewrite `config/features`: that string keeps naming whichever version last saved the
project, so a fully ported project still reports 4.2 to everything that reads the file, this doc's
own first command included. Phase 5 sets it.

## Phase 2: record the baseline

A screenshot proves one frame. What catches a regression is a **drive**, written once and replayed
identically on both sides of the port. `test run-scenario` takes that drive as a JSON step list, so
keep the list in a file and reuse it verbatim later.

**Build:**
```
godot-mcp upgrade baseline --old-godot <old binary> --scenario drive.json
```

`upgrade baseline` runs the game standalone under the old binary and replays `drive.json` over the
game's own direct channel, which needs the `godot_mcp/runtime/direct_server` project setting and a
debug build. It records every value the drive read, the screenshots, and `runtime errors` into
`.godot/upgrade/baseline/`, and `upgrade verify` replays the identical file later. Without
`--scenario` it records `--frames` frames with `--write-movie` at a fixed 60 fps and quits, which
gives a frame sequence to compare and the run log's own error lines.

**One difference from the hand-run path is worth knowing.** The command reads an `assert` step as a
measurement: it records what the property held and does not judge it. Whether a value satisfied an
operator on the old build says nothing about the port, and the recorded number is what the delta
table diffs. Run `test run-scenario` in the editor when you want the assertions themselves.

Run by hand (in the old editor, addon installed and enabled):
```
scene play --mode main
test run-scenario --steps '[
  {"type":"wait","seconds":1.0},
  {"type":"input","action":"move_right","pressed":true,"auto_release":false},
  {"type":"wait","seconds":1.5},
  {"type":"input","action":"move_right","pressed":false},
  {"type":"assert","node_path":"Player","property":"global_position","expected":"Vector2(0, 0)","operator":"neq"},
  {"type":"screenshot"}
]'
runtime get --node-path Player --properties '["global_position","velocity"]'
runtime screenshot --save-path user://baseline_level_01.png
scene stop
```

Two details in that step list are silent when they are wrong:

- **A press is released again in the same batch unless the step sets `"auto_release": false`**. A
  hold-then-wait written without it runs as a one-frame tap, and the step still reports `sent: true`.
  The tell is `auto_released: true` in the step's own result. Without the flag the drive above moves
  the player a few pixels instead of 600, and the `neq` assert passes anyway.
- **`expected` is a Godot literal string** (`"Vector2(0, 0)"`, `"#ff0000"`, `"true"`, a number),
  coerced to the live property's type before the comparison. A pair that cannot be coerced comes back
  `passed: false` with a `reason` naming both types, which is a typo in the step list rather than a
  regression in the game.

Record the numbers `runtime get` returns alongside the images. A position that lands 40 px short
after the port is a physics or input change no screenshot comparison will flag.

**Run the whole baseline twice and keep both sets.** The second pass costs a minute and is what
makes the after numbers readable, because nothing in a real game replays bit-identically. Measured
on one port: `_process`-driven positions differed by 0.083 units between two runs of the **same**
build, and two screenshots of the same build differed by 8.35 percent while the cross-version pair
differed by 1.85. The spread between the two baseline runs is the comparison threshold. A post-port
difference inside it is noise however large it looks, and a fixed threshold picked by intuition
points the wrong way as often as the right one.

For scenes that are looked at rather than played, shoot from a **fixed** camera so the after shot
frames the same thing:
```
scene open --path res://levels/level_02.tscn
editor set-camera --position "Vector3(0,18,40)" --look-at "Vector3(0,2,0)"
editor screenshot --save-path user://baseline_level_02.png
```
Write down the camera arguments with the image. Reproducing the pose is the whole value of the shot.

This needs the addon installed and enabled in the old editor, so check that it binds before
planning around it: install it, enable the plugin, and run `godot-mcp status` until the verdict
reads `running`. If it never does, capture the baseline as the first thing after the 4.7 open,
before any fix lands. That baseline is weaker, because the reimport already happened, and it still
beats porting blind.

## Phase 3: open in 4.7 and harvest the error list

**One editor.** Check the verdict before launching, and never stack a second instance.

**Build:**
```
godot-mcp upgrade open --godot <new binary>
```

`upgrade open` refuses on a dirty tree, tags the tree as it stands (`pre-<version>-upgrade`),
branches (`upgrade/godot-<version>`), launches exactly one headless editor, and waits for the
reimport to settle: successive `editor reload`s until the error count comes back the same twice.
Then it reads the sources above and buckets what they found by category, opens and validates and
resaves every scene, diffs the result, writes `.godot/upgrade/open.json`, and prints the to-do
table. The resave lands as its own commit, so a later `fix` has a well-defined state to restore to.

Run by hand:
```
godot-mcp status                  # closed or crashed -> launch one; running -> do not; starting -> wait
godot --path <project> --editor   # exactly one, at most one relaunch
godot-mcp status                  # wait for running
project info                      # confirm which project answered, and its Godot version
engine version
```

The first open reimports everything. Let the scan finish before reading errors, because a scan in
progress reports failures that resolve themselves.

```
editor errors --internal=false --clear    # drain the import noise
editor reload                             # rescan
editor errors --internal=false            # what survives is the to-do list
script validate --all                     # tree-wide compile check, failures only
```

`--internal=false` keeps the project's own script errors and drops the engine C++ entries a rescan
floods the buffer with. `script validate --all` answers "does every script still compile", which
the error panel cannot, since it only shows what the editor happened to load.

## Phase 4: triage by category, not file by file

A migration error list is repetitive. One renamed method appears in thirty scripts, and thirty
individual fixes is thirty chances to typo one. Find the whole set, fix it in one pass, recompile
that set, and watch the count fall.

**Build:**
```
godot-mcp upgrade fix --category renames --dry-run
godot-mcp upgrade fix --category renames --godot <new binary>
```

`upgrade fix` reads `open.json` for what the category started at, captures an
`authoring checkpoint` and a git tag, applies the category through the tool's own commands, and
then proves it: `editor reload`, `script validate --all`, `editor errors`, and the drive when
`--godot` names a binary to run it under. The count has to reach zero and neither tree-wide number
may get worse. If either fails, the checkpoint is restored, the files are checked back out, and the
report says why with the debugger's stack attached. A category that passes lands as one commit.
`--dry-run` prints the diff for the categories that rewrite text and the command list for the ones
that do not.

The mechanical categories are `renames`, `export_file`, `typed_dictionary`, `tilemap`, `settings`,
and `uid`. Everything else `open` found is a report a person acts on, and `fix` says so rather than
guessing. The rename table itself ships report-only, because every symbol the 4.3-to-4.7 range
changed either drops an argument or has no replacement, and neither is a text substitution.

Run by hand, once per category:
```
project grep --query "get_used_cells" --file-type gd    # every caller of the changed API
analysis script-references --query TileMap              # every reference, .tscn and .tres included
script read --path res://world/chunk.gd --start-line 40 --end-line 80
script edit --path res://world/chunk.gd \
  --replacements '[{"search":"tilemap.set_cell(0, ","replace":"ground_layer.set_cell("}]'
script validate --modified                              # compiles exactly what git says changed
editor reload
editor errors --internal=false                          # shorter than last pass, or the diagnosis was wrong
```

`analysis script-references` reaches into `.tscn` and `.tres` as well as scripts, which is how a
deprecated node type gets found in scenes nobody opened. `project grep` is the narrower tool when
the target is code.

Ground every replacement in the live engine instead of in a memory of the old signature:
```
engine search --query set_cell
engine class-info --class TileMapLayer --filter cell
engine docs --class TileMapLayer --member set_cell
```

**Treat a surprise as a bug in this tool surface before blaming the engine.** A property that reads
back wrong, a count that disagrees with the scene, an error naming a file that does not exist: stop
and root-cause it. A port is the exact situation where a wrong answer is easiest to write off as
"the old version was weird".

## Phase 5: structural conversions

### TileMap to TileMapLayer

The editor ships an extractor for the hand-driven path: select the `TileMap` node, open the bottom
panel, and use the toolbox icon at its top right, **Extract TileMap layers as individual
TileMapLayer nodes**. It is not scriptable, so a CLI port reads the old node and paints new layers.

**Build:**
```
godot-mcp upgrade fix --category tilemap --godot <new binary>
```

That runs the extraction below for every `TileMap` in every scene, one scene at a time: open,
extract each layer into its own `TileMapLayer`, delete the old node, save. Each addon command
commits its own undo action and the wire cannot group several into one, so the rollback unit is the
checkpoint plus git rather than a single Ctrl+Z, and `fix` restores both when the proof fails.

Run by hand:
```
node get --node-path Ground                                  # confirm the class is still TileMap
node call --node-path Ground --method get_layers_count
node call --node-path Ground --method get_used_cells --args '[0]'
```
Then extract every layer in one pass. `TileMap` accessors take a layer index that `TileMapLayer`
drops (`get_cell_source_id(layer, coords)` becomes `get_cell_source_id(coords)`):
```
editor run-script --code '
var root = EditorInterface.get_edited_scene_root()
var old = root.get_node("Ground")
var made = []
for i in old.get_layers_count():
    var layer = TileMapLayer.new()
    layer.name = "%s_%d" % [old.name, i]
    layer.tile_set = old.tile_set
    layer.z_index = old.get_layer_z_index(i)
    layer.modulate = old.get_layer_modulate(i)
    layer.y_sort_origin = old.get_layer_y_sort_origin(i)
    for c in old.get_used_cells(i):
        layer.set_cell(c, old.get_cell_source_id(i, c), old.get_cell_atlas_coords(i, c), old.get_cell_alternative_tile(i, c))
    root.add_child(layer)
    layer.owner = root
    made.append([layer.name, old.get_used_cells(i).size()])
emit(made)'
```
`layer.owner = root` is required. A node added without an owner vanishes when the scene is saved,
and the loss shows up as an empty level rather than as an error. The per-layer flags live behind
`get_layer_*` / `is_layer_*` on the old node (`engine class-info --class TileMap --filter layer`
lists the set); on the new node they are plain `Node2D` properties.

Verify the cell counts moved, then remove the old node:
```
tilemap get-info --node-path Ground_0      # used_cells should match the emitted count
node delete --node-path Ground
scene save
```

The script side is a separate pass: `$TileMap.set_cell(0, c, ...)` becomes
`$Ground_0.set_cell(c, ...)`, and one script that drove several layers usually splits into several
`@export var` references. Find them with `project grep --query "get_cell_" --file-type gd`.

### Resave every scene and resource once

Do it as one deliberate pass rather than letting the rewrites trickle into unrelated commits for the
next month. What the pass is actually adopting depends on where the project came from:

- **4.3 or older**: `.uid` sidecars do not exist yet, so the resave writes them. That is UID
  adoption, and the new files beside every script and scene are the deliverable.
- **4.4 or newer**: the sidecars are already there and already committed. The resave is text-format
  adoption instead, which in 4.7 means the `unique_id` attribute on every node and the dropped
  `load_steps` header.

**Build:**
```
godot-mcp upgrade fix --category uid --godot <new binary>
```

By the time `fix` runs there is usually nothing left to do: the first open already rescanned the
filesystem and wrote the sidecars, `open` committed them with the resave, and the category reports
zero. What `fix` adds is the rescan for a file that arrived while the editor was down, and the
count that proves every script and shader now has one. The engine says so too, with a
`Missing .uid file for path` line in the launch log that the harvest picks up.

Run by hand:
```
project tree --filter "*.tscn"      # filtered, so directories holding no scene are omitted
scene open --path res://levels/level_01.tscn
scene save
scene close --path res://levels/level_01.tscn
```
Loop that over the list, then spot-check that a reference resolves both ways:
```
project path-to-uid --path res://entities/player.tscn
project uid-to-path --uid uid://bx8n2v1qk3m4p
```
Commit the `.uid` files. Later relocations go through `fs move --from --to`, which updates the UID
cache and rewrites literal `res://` references. A move made in the OS file manager leaves the
sidecar behind and breaks the reference.

### Renamed or relocated settings

**Build:**
```
godot-mcp upgrade fix --category settings --godot <new binary>
```

The `settings` category is the feature tag. `open` reports it when `config/features` still names an
older release than the one being ported to, and `fix` writes the target version plus whatever
renderer strings the project already used, through `project set-setting` in the open editor.

Run by hand, plus any setting that moved:
```
project settings --filter anti_alias        # find where a setting moved to
project set-setting --key rendering/anti_aliasing/quality/msaa_3d --value 2
project set-setting --key application/config/features --value '["4.7", "Forward Plus"]'
```
Never hand-edit `project.godot`. The 4.7 editor rewrites the file on open and on any settings
write, and a hand edit made alongside that rewrite is easy to lose without noticing.

**The feature tag survives every rewrite that is not a settings write.** Opening the project and
resaving its scenes leaves `config/features` naming whichever version last saved it, so a fully
ported project still reports 4.6 to everything that reads the file. One settings write from the
editor does regenerate it, which is why `fix --category settings` is a single
`project set-setting`; keep the renderer string the project already used (`Forward Plus`, `Mobile`,
or `GL Compatibility` beside the version). Every port needs this line.

### C# projects

**Build:**
```
csharp info                          # dotnet SDK, .NET editor build, csproj state
script edit --path Game.csproj --replacements '[{"search":"Godot.NET.Sdk/4.2.0","replace":"Godot.NET.Sdk/4.7.0"}]'
csharp build --timeout 300
script validate --path res://Player.cs
```
The `Godot.NET.Sdk` version in the `.csproj` has to match the engine, and a full rebuild is
required rather than optional, since binary compatibility is not held across minors. Android
exports from 4.5 onward need .NET 9 while the other platforms stay on .NET 8. Running C# at all
needs a Godot .NET editor build plus the dotnet SDK.

## Phase 6: verify against the baseline

**Build:**
```
godot-mcp upgrade verify --godot <new binary>
```

`upgrade verify` replays the drive `baseline` recorded, under the new binary, compares every
recorded number and every captured frame against the baseline, runs the harvest again so the result
reads as a delta against `open.json`, and writes `.godot/upgrade/verify.json`. Its last step puts
the warning settings back the way `preflight` found them: it reverts that commit, and repairs
whatever the revert could not, because the editor prunes any setting equal to its default on the
next save and git then reads the hunk as already reverted.

Run by hand:
```
scene play --mode main
test run-scenario --steps '<the identical JSON from phase 2>'
runtime get --node-path Player --properties '["global_position","velocity"]'
runtime screenshot --save-path user://after_level_01.png
runtime errors
scene stop
editor compare-screenshots --image-a user://baseline_level_01.png \
  --image-b user://after_level_01.png --threshold 12
```
`compare_screenshots` requires matching image sizes, so leave the viewport and window settings alone
between the two captures. Read the changed-pixel percentage against the two baseline runs from phase
2, never against a number picked in advance: on one port the same build compared with itself came
back 8.35 percent while the cross-version pair came back 1.85. A difference larger than the baseline
spread is worth opening the frame pair for. Anything inside it is timing.

Editor captures compare the same way, once the camera is back where the baseline shot it:
```
scene open --path res://levels/level_02.tscn
editor set-camera --position "Vector3(0,18,40)" --look-at "Vector3(0,2,0)"
editor screenshot --save-path user://after_level_02.png
editor compare-screenshots --image-a user://baseline_level_02.png --image-b user://after_level_02.png
```

Then the checks that need no baseline at all:
```
scene validate              # per open scene: dead AnimationPlayer track paths, stored NodePaths pointing nowhere
script validate --all
editor errors --internal=false
analysis circular-dependencies
```
`scene validate` catches the break a reimport produces most quietly. An AnimationPlayer track whose
node path stopped resolving plays nothing, reports nothing, and looks identical in a still frame.

## Land it as one commit

The 4.7 editor resaves a `.tscn` or `.tres` whenever it touches one, so the diff grows on its own
while the port runs. Two consequences worth planning for:

- **The scene text format itself changed**. 4.7.2 writes a `unique_id` attribute on every node and
  drops `load_steps` from the `[gd_scene]` header, so a scene the editor merely opened comes back
  changed. Expect the resave noise and read it as format, not as damage.
- **Keep feature work out of the port branch**. Land the whole migration as one labeled commit
  naming the source and target versions. A bisect over a mixed commit cannot separate "the port
  broke this" from "the feature broke this".

## Checklist

Each phase command already enforces the items above it, and its report names what it read. This is
the list for a port run by hand, and the list to read a report against.

- Rollback branch or tag exists **before** the first 4.7 launch, and the addon install is its own
  commit on top of a tree that was already clean.
- `config/features` version read; every `addons/` entry checked for 4.7 support, GDExtension ones first.
- Baseline recorded as a replayable `test run-scenario` step list, plus per-scene screenshots with
  their camera arguments and the `runtime get` numbers.
- Baseline run **twice**, both sets kept, and the spread between them used as the comparison threshold.
- Every held input in the step list carries `"auto_release": false`, or it is a tap by design.
- Exactly one editor launched, `godot-mcp status` consulted first.
- Reimport allowed to finish before `editor errors` was read as a to-do list.
- Errors triaged by category, each category recompiled with `script validate --modified`.
- Every replacement signature confirmed against the live engine with `engine class-info` / `engine docs`.
- `TileMap` nodes extracted to `TileMapLayer` (owner set, cell counts verified) and scripts ported
  off the layer-indexed API.
- Every scene and resource resaved once so `.uid` files land in one pass, and committed.
- Settings changed through `project set-setting`, never by hand, `application/config/features` set
  to 4.7 plus the project's renderer among them.
- Baseline scenario replayed, screenshots compared, `runtime errors` clean, `scene validate` clean.
- One labeled migration commit, no feature work inside it.
