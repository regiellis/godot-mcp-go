# Porting a Godot 4.x project to 4.7 with godot-mcp

Moving a project from an older 4.x release to 4.7 is a reimport plus a short list of real breaks.
What decides whether the port succeeded happens on either side of that: a recorded picture of how
the game behaved before, and the same drive replayed after. `godot-mcp` runs the game, drives it,
and reads state back, so the comparison is frames and numbers instead of memory.

Scope is **4.x to 4.x**. A Godot 3 project goes through the engine's own `--convert-3to4` pass
first, and this doc starts once that conversion has landed and the project opens in some 4.x editor.

Confirm anything below against the running build (`engine version`, `engine class-info --class
TileMap`) rather than against this page. The shapes are stable and the signatures move.

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
# the version the project was last saved by
grep config/features project.godot     # PackedStringArray("4.2", "Forward Plus")
ls addons/                             # every entry is its own compatibility question
git status --porcelain                 # must come back empty before anything else runs
git switch -c port/godot-4.7
git tag pre-4.7-port
godot-mcp install --project . --enable # this dirties the tree, so it lands on its own
git commit -am "chore: install godot-mcp addon"
```

Run those in that order. The clean check comes first, then the branch and tag, then the addon
install as its own commit. Installing before the check turns "must come back empty" into a
judgement call, and installing without committing mixes the addon's own files into a port diff that
later has to be read as one migration.

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

**Build** (in the old editor, addon installed and enabled):
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

**Build**, once per category:
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
project settings --filter anti_alias        # find where a setting moved to
project set-setting --key rendering/anti_aliasing/quality/msaa_3d --value 2
project set-setting --key application/config/features --value '["4.7", "Forward Plus"]'
```
Never hand-edit `project.godot`. The 4.7 editor rewrites the file on open and on any settings
write, and a hand edit made alongside that rewrite is easy to lose without noticing.

**The feature tag is the one thing the editor will not fix for the project.** Every other rewrite
happens on its own; `config/features` keeps naming the version that last saved the file, so set it
explicitly and keep the renderer string the project already used (`Forward Plus`, `Mobile`, or
`GL Compatibility` beside the version). Every port needs this line.

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
