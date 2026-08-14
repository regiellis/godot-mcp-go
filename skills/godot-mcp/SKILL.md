---
name: godot-mcp
description: Use the complete Godot development loop from the godot-mcp CLI: discover the live engine API, build and edit in the open editor, run and play the game, observe state, debug failures, fix them in place, and verify the result. Use when the task involves creating or modifying a Godot project, testing game behavior, diagnosing a running game, or answering "does Godot/this node support X" against the actual engine.
---

# Godot MCP (godot-mcp)

`godot-mcp` carries one workflow across the **running Godot editor**, the game process, and the debugger over a WebSocket the editor's MCP addon hosts. Discover the live API, create scenes, add nodes, write scripts, play the game, simulate input, inspect state, diagnose failures, apply fixes, and verify the result without leaving the interface. Every editor mutation goes through Godot's UndoRedo, so the user can Ctrl+Z anything.

## Prerequisites (check first)

1. **The Godot editor must be open** with the `godot_mcp` addon enabled. When a command fails because the editor isn't reachable, **run `godot-mcp status`** (preflight) rather than guessing. It returns a `verdict`:
   - `running` means reachable. **Never launch another editor** (a second instance stacks and breaks discovery).
   - `starting` means the process is alive but still booting. **Wait a few seconds and retry; do not launch.**
   - `crashed` means a stale discovery file remains but the process is gone. Tell the user it crashed; you may **relaunch exactly one** editor.
   - `closed` means no discovery file, so the editor closed cleanly or never started. You may **launch exactly one** editor if the task needs it.
   - Launch with `godot --path <project> --editor`. **Relaunch at most once**; if it's still unreachable after one attempt, stop and report rather than looping launches. After a successful launch, `status` will read `running`/`starting`, which is your guard against opening a second.
   - **Check `project_match` too**. `status` reports which project the answering editor serves. When another project's editor holds the port, the verdict reads `closed`/`crashed` (nothing is serving *this* project) with `project_match: false` and the answering `project_path`, so follow the verdict and open one for this project. Commands refuse to run in that state rather than editing the other project, which is what the check exists to prevent.
2. **The CLI binary.** In this repo: `task build` → `bin/godot-mcp.exe`. Invoke as `bin/godot-mcp.exe <group> <command> [--flags]` (or `task run -- <group> <command> [--flags]`). Elsewhere, use the installed `godot-mcp`.
3. **Connection is automatic.** The CLI finds the port from `<project>/.godot/godot-mcp.json` (written by the addon) when run from inside the project dir; otherwise pass `--port` (default 9080).

## The golden rule: discover, then drive

Your training may predate the engine you are driving. **Do not guess** whether a class, property, or method exists. Ask the live engine:

```
godot-mcp engine search --query offset_transform      # find members across all classes
godot-mcp engine class-info --class Control --filter transform   # a class's own members + signatures
godot-mcp engine classes --inherits Node2D            # what subclasses exist
godot-mcp engine defaults --class OmniLight3D          # a class's default property values (no instantiation)
godot-mcp engine version                              # confirm the running version
godot-mcp engine commands [--group node]              # the MCP's own tool surface, with param docs per command
godot-mcp node set --help                             # a command's param table (name/type/required/desc)
godot-mcp engine doc-search --query "wrap text"       # search the docs PROSE by concept (finds autowrap_mode)
godot-mcp engine docs --class Label --member autowrap_mode   # what a member MEANS, from this build's own docs
```

`engine docs`/`engine doc-search` serve the running build's documentation prose (the editor's own
Help text): structure from `class-info`, meaning from `docs`. Member lookup walks the inheritance
chain, finds annotations with or without the `@`, and covers pages ClassDB lacks (`@GlobalScope`,
`@GDScript`, Variant types); an enum name like `Key` returns its values.

`engine search` matches by substring first. On **Godot 4.8+** a query that matches nothing is
retried fuzzily, so a half-remembered abbreviation still lands: `linvel` reaches
`RigidBody2D.linear_velocity`, `glbpos` reaches `Node3D.global_position`. The result's
`match_mode` says which pass answered (`substring` or `fuzzy`). On 4.7 there is no fuzzy pass, so
an abbreviation returns nothing. Widen to a real substring (`velocity`, not `linvel`) and filter
from there.

`class-info` defaults to a class's **own** members, exactly where version-new API (like `offset_transform_*`) lives; add `--inherited` for the full set. Lead with these whenever you're unsure, then act.

**These docs record what was verified against a live engine, not a version the guidance expires past.** When any statement here and the running engine disagree, **the live engine wins**: `engine version` and `engine class-info` are the ground truth.

**Universal fallback:** even if no typed command wraps a feature, you can always reach it:
- `node.set` / `node.get` work on **any** property name the live node exposes, and `node.call` invokes **any method** it exposes (`runtime.call` does the same in the running game). Between them, a feature is reachable whether the engine surfaces it as a property or a method. Reach for `editor.run_script` / `runtime.eval` only when you need several statements.
- `editor.run_script --code '...'` runs arbitrary `@tool` GDScript in the editor; `runtime.eval --code '...'` runs it in the game. Use `emit(value)` to return data. So any API GDScript can call in the running engine is reachable with no per-feature wrapper.

## The spatial rule: anchor, read back, verify (don't place blind)

The same discipline as "discover, then drive," applied to **space**. You cannot reliably perceive 3D from one perspective screenshot, and you are bad at absolute-coordinate 3D math, so **never position dependent objects with parallel absolute coordinates**. Computing every part from the same constants (`board_x`, `rim_x = board_x - 1.2`, …) leaves nothing anchored to what actually landed; a small error makes a part float or misalign (a rim off its backboard, a prop sunk into the floor) and one camera angle hides it.

**The `spatial` group does the math for you** (3D, meters, global space; positions come back as `"Vector3(…)"` strings that feed straight into `node set --property global_position`):

```
spatial bounds   --node-path Board                       # real world AABB: center/size/min/max/pivot
spatial relate   --node-path Rim --other Board           # center_delta, centered{x,y,z}, gap, overlaps
spatial place_on --node-path Crate --surface-from Floor   # seat its bottom on the surface below
spatial align    --node-path Rim --to Board --axes xz [--on-top]   # center A on B / stack on top
spatial distribute --nodes '["P1","P2","P3"]' --axis x --span 12   # even spacing
spatial look_at  --node-path Turret --target Player       # face a node or --point (engine math, no Euler)
spatial raycast  --from "Vector3(0,20,0)" --to "Vector3(0,-20,0)"  # edit-time ray (hits CSG use_collision)
spatial find_in_region --min "Vector3(-5,-5,-5)" --max "Vector3(5,5,5)"
spatial lint     --check-floating                        # coincident dupes + unsupported/floating nodes
```

The discipline they encode:

1. **Anchor to realized geometry.** Place a piece, `spatial bounds` it, derive the next from *those numbers*. Chain it: floor → `bounds` → wall → `bounds` → fixture. (Under the hood this is a node's `VisualInstance3D.get_aabb()` × `global_transform`; reach it directly with `editor run-script` if you need a shape `spatial` doesn't cover.)
2. **Mind local vs global.** `node.set --property position` is **local to the parent**. To anchor across the tree, write **`global_position`**, which is exactly what `spatial align`/`place_on`/`distribute` do.
3. **Raycast / `place_on` to seat on surfaces** instead of computing heights. `spatial raycast` **works at edit time against CSG `use_collision`** (greybox geometry registers collision in the editor, verified) and any real collider; `spatial place_on` uses mesh-AABB math so it works even without colliders. In the **running game**, raycast via `runtime eval` (`get_tree().root.world_3d.direct_space_state`).
4. **Face with `spatial look_at`**, never hand-computed Euler. Hand-rolled angles are reliably ~20° off.
5. **Verify by reading back, not by one screenshot.** `spatial relate` after a placement, `spatial lint` after a set ("center_delta.x = 0; gap.y = 0 → touching, not sunk"). When layout needs eyes, **teleport the camera** (`editor set-camera`) or player (`runtime set global_position`) to several vantages and screenshot each, because one frame hides a 5 cm / 60 cm error.

Godot conventions to reason in: **+Y up, −Z forward, right-handed, meters** (1 unit ≈ 1 m); 2D is **+Y down, pixels**, bounds via `Control.get_global_rect()`.

## CLI conventions

- `godot-mcp [--port N] [--timeout 30s] <group> <command> [--key value ...]`. Global flags go **before** the group.
- Command and flag names accept kebab- or snake-case: `node set-anchor` → `node.set_anchor`, `--node-path` → `node_path`.
- Values: `--key value` or `--key=value` (string; the addon coerces toward the target type), `--key=true|false` (bool), bare `--flag` (bool true), and JSON when the value starts with `[`/`{` (e.g. `--properties '["text","visible"]'`).
- Output is the result JSON. On error the CLI prints `error [code]: message` plus any `data` (suggestions, available methods) to stderr and exits non-zero.
- **Node paths are relative to the scene root** (`.`, `UI/Score`). Output paths feed straight back as `--node-path`. Start from `scene.tree`.

## Property value formats

`"Vector2(100, 200)"` · `"Vector3(1, 2, 3)"` · `"Color(1, 0, 0, 1)"` or `"#ff0000"` · `"true"`/`"false"` · `"42"`, `"3.14"` · enums as integers (`0` = first value). Arrays/objects as JSON: `--groups '["enemy","hittable"]'`.

## Command groups

Run `godot-mcp <group>` patterns; discover exact names per group by reading the addon or just trying `--help`-style exploration. Groups: `project` `scene` `node` `spatial` `authoring` `script` `editor` `debug` `runtime` `engine` `input` `animation` `anim_tree` `tilemap` `theme` `shader` `particles` `scene3d` `scene2d` `material` `mesh` `csg` `gridmap` `scatter` `lighting` `path` `pcg` `wfc` `camera` `ui` `doc` `skeleton` `physics` `navigation` `audio` `input_map` `multiplayer` `resource` `fs` `import` `localization` `analysis` `batch` `profiling` `export` `test` `android`.

Most-used:
- `project info|tree|search|grep|settings|set_setting`: project metadata, files, settings (never edit `project.godot` directly, go through `project set-setting`).
- `scene tree|create|open|close|save|play|stop|instance`: `tree` is your map of the open scene. `create` opens what it writes, and `close` is how you release a tab again: `delete` refuses a scene while it is open, so cleaning up a throwaway is `scene close --path X` then `scene delete --path X`. Closing discards unsaved changes without asking, so it refuses one that has them unless you pass `--discard true`.
- `node add|set|get|call|rename|move|delete|set_anchor|connect|set_meta|get_meta`: building blocks (`set`/`get` are property ops; `set` takes singular `--property/--value` **or** a batch `--properties '{...}'`). `call --method M [--args '[…]']` runs a method and returns its result. Reach for `node call --node-path Fx --method restart` rather than a `run_script` when one call is all you need; args coerce to the method's declared types, so `'["Vector3(1,0,1)"]'` arrives typed. It is **not** undoable. `set_meta|get_meta` read/write arbitrary node metadata, the general-purpose store that `set` (properties only) can't reach. **In 2D, sibling order is draw order**, so reach for `node move --before|--after|--index` to seat a node behind or in front of its siblings, and `node add --index` to place a new one; `move` reparents and reorders in one undoable step. A `--properties` value that can't be coerced is an error naming what the property wanted, so a failed create tells you why instead of leaving the property null.
- `spatial bounds|relate|place_on|align|distribute|look_at|raycast|find_in_region|lint`: 3D placement done right (anchor → read back → seat → verify). See "The spatial rule" above.
- `authoring resolve|ensure|checkpoint` gives re-runnable scripted-build helpers: `resolve` (fuzzy name → ranked node/scene/resource paths, flags ambiguity), `ensure` (idempotent get-or-create a node by name, so re-runs converge with no `Node2`/`Node3`), `checkpoint` (capture/diff/restore a JSON snapshot of node transforms, answering "what did my edits move?").
- `resource find|info|read|edit|create|preview` does asset discovery + graph: `find --type PackedScene [--path res://… --name foo]` (type-filtered, matches subclasses), `info --path res://x` (its dependencies **and** referencers, the "what breaks if I delete this" question).
- `fs mkdir|move|copy|delete`: asset/file management with **dependency fixup**, the one thing `node.*` can't reach. `move --from --to` renames/relocates a file or dir and rewrites every `res://` path reference to it (uid refs survive the move automatically); `copy` regenerates the copy's uid so it doesn't collide; `delete` refuses a referenced file (or a dir holding an open scene) unless `--force`, and reports what breaks. The safe way to reorganize a project without breaking scenes.
- `script create|read|edit|attach|validate|symbols|lint`: GDScript authoring. `symbols` reads one script's declared methods/properties/signals/constants without spending context on the file (and reaches scripts with no `class_name`, which `engine class-info` can't). `lint` checks the official style guide.
- `editor run_script|errors|log|screenshot|reload|signals`: editor control + diagnostics.
- `debug set_breakpoint|state|frame|step|resume|pause|reload_scripts`: the interactive debugger for an editor-launched game. Breakpoints arm through the script gutter and hit a game **already running**; a paused game answers `state` (reason, stack, variables) and `frame --index N`; `step --mode over|into|out` then `resume`. `reload_scripts` hot-swaps edited `.gd` into the live process, state kept (runs started by `scene play` always accept it), so you fix, reload, and keep playing instead of restarting. It refuses unhittable lines (suggesting the first executable one) and warns on `_process`-family breakpoints, which re-break every resume: trust those refusals.
- `runtime tree|get|set|call|eval|screenshot|...`: the **running** game (needs `scene play` first). `call` invokes a method on a live node (script methods included) and returns its result, which beats `eval` when you only need one call. A standalone debug-build game (no editor) is reachable too when the project enables `godot_mcp/runtime/direct_server`: add `--game` to route directly to it.
- `input key|tap|click|move|action|sequence`: simulate input into the running game.

3D content pipeline (build → dress → light a level, the Godot way):
- `material create|set|apply|info`: reusable `StandardMaterial3D`/`ORMMaterial3D` `.tres`; the **only** way to set a texture-map path or **triplanar** (`node.set` can't). `apply` auto-picks the slot (CSG→`material`, others→`material_override`).
- `csg add|set_operation|combine|bake`: boolean greybox blockouts; `bake` freezes a proven CSG tree to a static `MeshInstance3D` (+collision), the graybox→mesh handoff.
- `gridmap meshlibrary_from_scene|set_cell|fill|list_items` does modular-kit level building (the 3D `tilemap`): turn a kit scene into a MeshLibrary, then paint cells.
- **Procedural generation comes in two families. Pick by the problem:**
  - **Point-scatter** (`pcg`, `scatter`): "put N things over a surface." `pcg sample|scatter` is one pipeline: domain (`--on`/`--region`/`--along`) → distribution (`--poisson`/`--grid`/`--count`) → filters (`--max_slope`/`--noise_threshold`/…) → emitter (`--emit multimesh|scene`), **seeded**. `sample` previews (returns cull stats); `scatter` emits. `pcg relax` Laplacian-smooths a point graph. `scatter populate` is the simpler raycast-seated MultiMesh.
  - **Constraint tile-assembly** (`wfc`, `gridmap`): "assemble handmade modules so neighbours fit" (Townscaper/Bad North). Author a small kit → MeshLibrary, then: `wfc case_table` (the 6 dual-grid tiles) + `set_corner` + `solve_dual` paint a per-corner type field and pick each cell's module+rotation; **or** `wfc rules_from_example` + `collapse` run Wave Function Collapse over a region (constraint propagation, seeded, respects fixed/painted cells); `wfc match_pattern` swaps multi-cell special pieces; `gridmap set_cell_variant` de-repeats; `wfc stalberg_grid` makes an organic all-quad grid.
- `mesh info|deform_lattice` covers geometry ops `node.set` can't reach: `deform_lattice` free-form-warps a mesh from 8 corner handles (conform a square module to an irregular cell).
- `lighting add|bake|set_gi|set_sdfgi`: 3D GI nodes; `bake` works for **VoxelGI** (the only script-bakeable GI type). `lighting add_2d|occluder_2d|canvas_modulate` handles **2D lighting**: a PointLight2D renders nothing without a texture, so `add_2d` generates a radial one for you; `occluder_2d` builds the OccluderPolygon2D shadows need; `canvas_modulate` sets the scene-wide ambient darkness the lights lift. `path create|sample|add_follow` builds splines (sampling feeds `pcg`). `camera set_attributes|make_current` covers DOF/exposure + activation.
- `scene2d add_sprite|add_camera|add_body`: 2D scene assembly (the canvas counterpart to `scene3d`). `add_body` wires a physics body + `CollisionShape2D` + shape (rectangle/circle/capsule) in **one** call. Its 3D twin is `scene3d add_body` (box/sphere/capsule primitives, or a trimesh/convex collider built from a MeshInstance3D via `--from-mesh`, which covers the "make this imported geometry collidable" need).
- `ui add_container|add_control|set_sizing` (layout + size_flags) · `skeleton`, `multiplayer`, `localization`, `import` for rigging / networking / i18n / asset-import config.
- `doc note|metric|gym|zoo|museum` is **in-game documentation** (Gyms/Zoos/Museums): `gym` scaffolds a colour-graded character-metrics test level; `zoo` lays out a folder of assets in a labeled grid with scale refs + lighting ("Generate Zoo"); `museum` builds labeled exhibit pads with API-doc links; `note --action add|list|resolve` leaves spatial notes (metadata-bearing markers) in the level. Document the game *in* the game. For a solo dev that is a single source of truth your future self won't lose. See `in-game-docs.md`.
- `cleanup strip_junk|unreal_env|unreal_lights|fix_imports` is **import hygiene** for a scene exported from Unreal (UnrealToGodot etc.): strip editor-only meshes (camera bodies, sky domes), fix the washed-out default WorldEnvironment (AgX + sane intensity + drop auto-exposure), normalize the garbage physical-light values (`lumens`/`lux` are one aliased store!), and repair `.import` `source_file` paths broken by dropping the export into a subfolder. Order: env → lights → junk → imports, wrapped in `authoring.checkpoint`. See `unreal-import-cleanup.md`.

These are typed conveniences over the same engine; the discover-then-drive and **spatial** rules still apply. For instance, `pcg`/`scatter` seat on colliders via the edit-time raycast, and you still verify placements by reading bounds back, not by one screenshot. For the full constraint-tile workflow as buildable command sequences, read `tile-constraint.md`.

## Build with composition, not monoliths

Godot is built around **node and scene composition**, so lean into it. Do **not** build one giant scene driven by one giant script. That fights the engine and produces code that can't be reused, tested, or debugged.

- **One scene per "thing."** Give each entity or UI piece its own small, self-contained scene (`player.tscn`, `enemy.tscn`, `coin.tscn`, `health_bar.tscn`), then **instance** them into levels with `scene.instance`. A level is a *composition of instances*, not a hand-built mega-tree.
- **Compose capabilities from child nodes; don't hand-code them**. Need collision? add a `CollisionShape2D`. A trigger? `Area2D`. Timing? `Timer`. Animation? `AnimationPlayer`. Reach for a node before writing code, and use `engine search`/`engine class-info` to find the right node type for a capability.
- **Small, focused scripts at the node that owns the behavior**. Split responsibilities (movement, health, AI) across nodes instead of one 1000-line script on the root. A recurring behavior becomes a reusable **component scene** (e.g. a `HealthComponent`, a `Hurtbox`) you instance wherever it's needed: fix it once, every user updates.
- **Decouple with signals**. Wire interactions with `node.connect` (e.g. `Area2D.body_entered` → a handler) so pieces stay independent and reusable. For references, prefer `@export` (set via `node.set`) wired in the inspector over brittle `get_node("../../X")` chains.
- **Prefer inspector data over hard-coded values** so designers (and you) can tweak without editing code.

How this maps to the tools: `scene.create` per entity → `node.add` the capability nodes → `script.create`/`script.attach` a focused script → `scene.instance` to compose into a level → `node.connect` for signals → `node.set` to wire `@export`ed references and set inspector values. When you catch yourself adding a fifth responsibility to one script or one scene, split it into a child node or a separate scene instead.

## Write like a Godot developer (read these)

Knowing the tools isn't enough. Build the *Godot way*. Reference files sit next to this skill; read the relevant one before writing code or structuring a game:

- **`gdscript-style.md`** covers GDScript idioms: static typing, naming, `@export`/`@onready`, signals over polling, `_physics_process` for movement, Resources for data, `class_name`/autoloads, plus the `script lint` rules that enforce most of it mechanically.
- **`ai-steering.md`** is about agent movement that reads as a creature rather than a cursor: accelerate toward a desired velocity instead of assigning it (`max_force` is the feel dial), arrive/flee/pursue/separation as summable forces, blending vs priority, facing, when to reach for `NavigationAgent` instead, and how to verify motion numerically rather than by screenshot. Read before writing any chase, patrol, or crowd behavior.
- **`game-patterns.md`** collects buildable patterns mapped to CLI command sequences: movement, **game feel vs juice** (control-code vs signal-fired feedback), components, state machines, projectiles, Area2D triggers, signal-bound HUD, groups, timers, animation, scene management, plus build order and common mistakes.
- **`platformer-2d.md`** is 2D platformer *construction*: the component actor (Node2D root; body/controllers/graphics/interaction as sibling components), the intent-API + predicate contract, physics-expression-driven `AnimationTree` transitions (no glue code), codeless `AnimatableBody2D` moving platforms, level-owned cameras with trip-line limits, a collision-layer contract, and scene-tile blockouts via `tilemap.*`. Read before building a 2D platformer.
- **`topdown-2d.md`** covers top-down 2D / sim *construction*: the layered `TileMapLayer` stack + Y-sort chain rule, gameplay-as-terrain-painting (`tilemap.set_terrain`, cursor components), the one-job Area2D component library with tool-gated hits, behavior state machines as child nodes, NPC wander via navigation, the one-clock day/night pattern (gradient-sampled `CanvasModulate`), and component + polymorphic-Resource saves. Read before building a farming sim, RPG, or any top-down game.
- **`ui-polish-2d.md`** is comp-faithful 2D UI: a `Design` token class transcribed from comps (solved constants, semantic colors, BLEED overscan, the `LabelSettings`-vs-theme and shared-resource traps, optical label centering), the drawn-control kit (face + hard drop shadow, the `sink` feel float, `offset_transform_*` layout-safe lift/tilt), a juice grammar scaled to the beat, and programmatic screen builders with their silent-failure traps (`CACHE_MODE_REPLACE_DEEP`, `owner`, minimum-size caching). Read before polishing any 2D UI or building screens from comps.
- **`character-3d.md`** covers 3D character controllers (FPS / third-person / platformer): one camera-basis-relative movement core, the floor contract (`floor_snap_length`, honest no-built-in-stairs), moving platforms via `AnimatableBody3D`, FPS mouse-look rig, third-person pivot + `SpringArm3D` rig with facing lerp, jump feel cross-linked to the 2D timers, and the exact verify-by-driving sequence. Read before building anything first- or third-person in 3D.
- **`menus-settings.md`** handles the meta-game screens: container-driven menu skeletons, pause done right (the `process_mode` ladder), the settings widget family (`OptionButton`/`HSlider`/`CheckButton`/`SpinBox` with the signal each binds), `ConfigFile` persistence + apply-on-boot autoload, runtime input remapping, `DisplayServer` window/vsync modes, dialogs & popups, gamepad focus navigation, 9-slice skinning (`NinePatchRect` vs `StyleBoxTexture` margins differ), the font pipeline, `GraphEdit`, `VideoStreamPlayer`. Read before building title/pause/settings screens.
- **`mobile-touch.md`** is touch input: index-keyed multitouch (`InputEventScreenTouch`/`Drag`), the mouse↔touch emulation settings, on-screen controls (`VirtualJoystick`/`TouchScreenButton`), pinch/pan gestures, safe-area HUD insets, `InputEventAction` synthesis. Read before targeting phones/tablets or adding touch controls.
- **`lighting-2d.md`** walks the complete 2D lighting stack: the CanvasModulate/PointLight2D/LightOccluder2D triad (multiplicative-darkness math, CanvasLayer escape hatch, texture-required lights, cull-mask legibility discipline, occluder perf + the TileSet seam gotcha), emissive exemptions (`lighting.emissive_2d` unshaded/additive/light-only), normal-mapped sprites via CanvasTexture (`lighting.normal_map_2d`), real 2D glow (`lighting.glow_2d`, the hdr_2d restart gotcha), and the occluder SDF layer for `texture_sdf` shader effects. Read before lighting any 2D scene.
- **`level-design.md`** is about building playable greybox levels with the CLI: the **Big→Medium→Small** risk order, graybox-first workflow, the greybox colour/value language + grayscale test, spatial-communication tactics (goals, sightlines, valves, pinch points, safety nets, …), interior combat spaces with greybox AI, exterior/open space (landmarks, terrain as pacing, walk-second travel budgets), 2D level design as its own discipline (screen vs scroll, the camera window as the sightline, room graphs), and pacing without combat. Read before laying out a level.
- **`environment-art.md`** is the art pass *after* the greybox is proven, driven from the editor: handoff without breaking layout, PBR materials, real lighting (SDFGI/LightmapGI/VoxelGI), `WorldEnvironment` post (restraint), decals/particles/fog, set dressing + `MultiMesh`, occlusion/LOD, and "don't lose the read." Includes the **paper-diorama** technique (2D art on 3D quads shot with a real camera, SubViewport crossfades). The CLI assembles/materials/lights, while meshes & textures come from Blender/Substance.
- **`tile-constraint.md`** covers the *constraint tile-assembly* PCG family (Townscaper/Bad North): the dual-grid fix (type corners not cells → 6 tiles), Wave Function Collapse from a learned example, variant buckets, multi-cell special pieces, and the organic all-quad `stalberg_grid` + `mesh deform_lattice`. Read before procedurally assembling modular kits (vs `pcg`/`scatter` for point-scatter).
- **`rhythm-games.md`** is rhythm / music minigame architecture: the corrected audio clock (`get_playback_position` + `time_to_next_mix` + `output_latency`, minus a user calibration offset) pushed down the tree as one timestamp, `.osu`/`.lrc` as beatmap/lyric data, notes as pure functions of time with per-lane FIFO input, windowed judging with a typed result, and the embed/autoplay/metronome structure. Read before building anything timing-based.
- **`audio-music.md`** covers the mixer and music systems: bus architecture (dB vs linear, the slider trap), `AudioStreamRandomizer`/`Polyphonic` SFX variation, interactive music (`AudioStreamInteractive` clip transitions, `Synchronized` stems, `Playlist`), compressor-sidechain ducking, spectrum-driven visuals, format & loop-point guidance (WAV/Ogg/MP3, bpm metadata for bar-quantized transitions). Read before wiring any game audio. (Beat-*locked* gameplay is `rhythm-games.md`.)
- **`in-game-docs.md`** is *Gyms, Zoos, and Museums*: document the game in-game so it never goes stale. Buildable `doc.*` recipes for a character-metrics gym, an asset zoo, a system museum, and spatial notes. Read when setting up a project's living documentation (especially solo/small-team).
- **`unreal-import-cleanup.md`** is about fixing a scene exported from Unreal (UnrealToGodot etc.): the env→lights→junk→imports order, why it's washed out (blown WorldEnvironment + auto-exposure), the `lumens`/`lux` one-aliased-store light trap, stripping editor-only meshes, and repairing `.import` `source_file` paths. Buildable `cleanup.*` recipes wrapped in `authoring.checkpoint`. Read when importing UE content.
- **`porting-godot-versions.md`** is upgrading an existing **4.x** project to 4.7: what actually breaks per minor (4.3 `TileMap` to `TileMapLayer`, 4.4 `.uid` sidecars and `@export_file` returning `uid://`, 4.5 Android .NET 9), the pre-flight that has to happen before an editor opens (feature tag, addon audit, rollback point), recording the old behavior as a replayable `test run-scenario` drive plus fixed-camera screenshots, harvesting `editor errors` as a to-do list after the reimport, triaging by category with `script validate --modified`, the scripted `TileMap` extraction, the resave-for-UIDs sweep, and verifying with the same drive plus `editor compare-screenshots`. Read before opening an older project in a newer editor. (Godot 3 projects go through `--convert-3to4` first; this starts after that.)
- **`project-structure.md`** shows how a shipped project is laid out to scale: code/asset separation, feature-slice folders, data/view split, scene↔script pairing, composition, autoloads. Read before scaffolding a project or subsystem.
- **`save-systems.md`** is the unifying persistence reference: authoritative-vs-derived state, the persist-group collector (with the respawned-node identity problem), the five-format tradeoff table (JSON type loss, `var_to_str` fidelity, the untrusted-`Resource` security caveat), versioning ladders, slots + metadata, threaded saves, temp-then-rename atomic autosave. Read before writing any save code; it routes to the four genre docs that own their slices.
- **`multiplayer-patterns.md`** covers high-level networking: the scene-tree replication mental model, ENet connection + the five `MultiplayerAPI` signals, authority gates, `@rpc` arguments (compile-probed), `MultiplayerSpawner`/`Synchronizer` wiring via the `multiplayer` group, the canonical co-op skeleton, intent-RPCs vs synchronized state. Two-peer behavior must be proven with two real instances, since the CLI drives one game. Read before adding any networking.
- **`shaders-vfx.md`** is gdshader authoring and wiring: shader types/render modes, the CLI wiring path (uniforms are *material* properties, so `shader set-param`, not `node set`), instance/global uniforms, the 2D VFX kit (hit-flash, dissolve, outline, scroll, palette), fresnel/wind, screen-space via `hint_screen_texture`, and the programmatic `.gdshader` compile-verification loop (`get_shader_uniform_list` canary + `editor errors`). Read before writing any shader; the combat-VFX *grammar* stays in `game-patterns.md`.
- **`gdscript-architecture.md`** is large-scale GDScript *runtime* architecture (autoload tiering; the Service-locator / node-Index / path-addressed-Store spine; key-addressed scene routing; a Scene base-class contract; two-tier save with JSON-diff checkpoints; components-vs-modules; a controller focus stack). Read before architecting a big GDScript game.
- **`event-deck-games.md`** covers narrative decision games (Reigns-like): the monolith-to-peers decomposition (dependencies as call arguments, consequences as intent signals), immutable `.tres` cards + a mutable overlay that *is* the save, cumulative-weight selection with forced/never-random weights, chains and postponed chains, AND/OR condition and coin-flip outcome DSLs, prefix-namespaced variables, the lose-at-both-ends pillar design, and the swipe verb. Read when building a decision/event-card game.
- **`run-based-games.md`** is run-based / roguelite architecture: the reactive `Data` blackboard (dot-path store, `of/apply/listen`, balance as leveled YAML arrays so upgrades/modifiers/mods are data writes), loadout registries, wave assembly from authored snippets under a weight budget (tolerance relaxation + fallback, monster-memory variety, anti-stall punishers, pity randomness), and seeded staged world generation from archetype resources with a self-auditing report and a standalone-runnable generator scene. Read before building a wave-survival or run-based game.
- **`deckbuilder-patterns.md`** holds card-game / deck-builder *logic-layer* architecture (action queue, hook pipeline for powers/relics, data-driven cards, seeded RNG, event-sourced history, model/entity/view split). Language-agnostic with GDScript mappings. Read when building a turn-based card game.
- **`narrative-game-patterns.md`** covers narrative / visual-novel architecture, both families: branching script via Ink (auto-bound external functions, `$ command` bus, line-format parsing, story event bus, keyed chapter flow, data-driven in-world apps) **and** graph dialogue (versioned JSON node graph + `match` interpreter, safe `Expression` evaluator, action registry, VN skip/auto/backlog/resume layer, box-vs-bubble Message contract with 2D/3D world-anchored bubbles), plus the manifest-driven **product shell** (boot/splash flow, versioned saves wrapping an opaque story snapshot with backup fallback, settings as a registration table with an accessibility tab, TOML-driven chapter select and extras). Read when building a story-driven game.
- **`csharp-godot.md`** is C#-in-Godot idioms (`partial`, `[Signal]` vs `event`, `[Export]`, tween/`await`, GDScript-proxy interop). A reference for editing a **C# Godot project**. The CLI supports C# directly: `csharp.setup` scaffolds the csproj/sln, `script.create` on a `.cs` path writes the C# template, and `csharp.build` / `script.validate --path X.cs` compile with structured diagnostics (needs a Godot .NET editor build plus the dotnet SDK; `editor.run_script`/`runtime.eval` still execute GDScript).
- **`shipping-export.md`** walks the release pipeline across targets: keeping dev tooling (this addon included, so disable the plugin and it removes its autoloads) out of player builds via export filters, per-platform legs (Android keystores and the `android` device loop, web's isolation-header contract, macOS/iOS signing boundaries and what a Windows machine cannot finish), the headless export loop, **PCK encryption** with keyed custom templates (compile-time `SCRIPT_AES256_ENCRYPTION_KEY` bake, export-time `GODOT_SCRIPT_ENCRYPTION_KEY` env key, key hygiene), size-optimized template builds (the scons knob menu with caveats), and receipt-based verification (pck string scans, the boot-is-the-key-match-proof rule, restore-then-regression). Read before cutting a build for players.

- **`game-trailers.md`** teaches filming the game with the engine itself, as a matrix of cuts and formats: duration profiles from a 15-second hook to a 2 to 3 minute feature, delivery profiles from 16:9 to 9:16 (compose per viewport, never crop; the shot list carries per-profile framing), the shot list as source of record, the dev-only director scene (real handlers, rigged determinism, in-memory fixtures, ceilinged waits), what rides film time versus the wall clock under `--fixed-fps`, cutting through a cover with the world running backstage at `Engine.time_scale`, `--write-movie` and the three writers, **the film's resolution coming from the viewport project setting rather than the window**, the render manifest and ffmpeg encode, and the `scene play` + `runtime screenshot` loop that proves a shot before a render is spent on it. Read before making a trailer or any captured video.

Two rules thread through all of them: **decouple with signals, not polling or `get_node("../../")` chains**, and **never write a remembered API signature without confirming it against the running engine** with `engine class-info`/`engine search` first.

## Core workflows

### Explore before changing
```
godot-mcp project info
godot-mcp scene tree
godot-mcp node get --node-path <path>        # inspect a node's properties
```

### Build a 2D scene
```
godot-mcp scene create --path res://scenes/player.tscn --root-type CharacterBody2D   # opens it; --open=false to just write the file
godot-mcp node add --type Sprite2D --name Sprite --parent-path .
godot-mcp node add --type CollisionShape2D --name Col --parent-path .   # root is already the body; just add the shape
godot-mcp node add-resource --node-path Col --property shape --resource-type RectangleShape2D
godot-mcp script create --path res://scenes/player.gd --extends CharacterBody2D
godot-mcp script attach --node-path . --script-path res://scenes/player.gd
godot-mcp scene save

# Dropping a *separate* body into a level (platform, wall, trigger)? One call does body+shape:
godot-mcp scene2d add-body --type StaticBody2D --shape rectangle --size "Vector2(256,32)" --name Platform --position "Vector2(0,400)"
```

### Scripts
`script create` (template or `--content`), `script edit` (modes: `--content` full; `--replacements '[{"search":"a","replace":"b"}]'`; `--start-line/--end-line --content`; `--insert-at-line N --text "..."`), then `script validate` (single `--path`, or batch: `--modified` compiles every git-modified/untracked `.gd`, `--all` sweeps the project, with results listing failures only). After creating/major edits, `editor reload` so Godot picks up changes.

Before reading a script you did not write, try `script symbols --path res://x.gd`. It returns the declared methods, properties, signals, and constants without pulling the whole file into context, and unlike `engine class-info` it works on scripts with no `class_name`. Add `--include-inherited` to walk the base-script chain.

`script lint --path res://x.gd` checks style against the official guide and returns structured findings (`line`, `rule`, `severity`, `message`). 17 rules: the 9 naming rules are `error`, the rest are warnings. Run it after writing or editing a script, because it is the check that makes `gdscript-style.md` enforceable rather than advisory. Suppress a line inline with `# gdlint-ignore[-next-line] rule`, or a whole run with `--disable rule,rule`. `max-line-length` is the noisy one (default 100; `0` turns it off).

A clean lint is **not** a passing compile: style rules read source, so they still report on a file that doesn't parse, and zero findings there would read as fine. A single-file run reports `syntax_valid`; a directory run is style-only, and `script validate --all` is the tree-wide compile check.

There is no `script format`. Reformatting safely needs a real parser, and it isn't worth making you install a binary for. Write to the style guide as you go and let `script lint` catch the rest.

### Playtest loop (the payoff)
```
godot-mcp scene play --mode main
godot-mcp runtime tree                                  # live scene tree
godot-mcp input action --action ui_accept --pressed true
godot-mcp runtime get --node-path Player --properties '["position","velocity"]'
godot-mcp runtime screenshot --save-path user://shot.png
godot-mcp runtime capture-frames --count 5 --frame-interval 6   # observe motion
godot-mcp scene stop
```
Input is **fire-and-forget** (`sent:true` ≠ applied), so confirm effects by reading state back with `runtime get`/`runtime eval`. `runtime.screenshot` works even with a headless editor (the game is a separate window). Stateful runtime commands (`capture_frames`, `monitor`, `watch_signals`, `move_to`, `replay`, `await_signal`) take time. Let them finish. For event-driven checks, `runtime await-signal --node-path Enemy --signal died --timeout 5` blocks until the signal fires and returns its args (`fired:false` on timeout, not an error), which is sharper than polling with `runtime get`. Arm the trigger *before* awaiting (the await connects when the command arrives; an emission during the CLI round-trip is missed). `runtime errors [--clear]` polls errors/warnings the running game logged (`push_error`, script/shader errors) as structured entries with a game-script backtrace. Treat it as an **on-demand** health check when something looks wrong, not a reflex after every action; runtime errors are unambiguously real. (A script error in the *game's own code* under a `--headless` editor freezes the game on the debugger break; recover with `scene stop`/`scene play`. Bad `runtime eval` code doesn't do this: it comes back as a compile error naming the line in your snippet.)

## Pitfalls

- **Prefer inspector properties over code**. Set visual props (color, position, transform) via `node.set`, not GDScript, so they stay editable in the inspector.
- **Never edit `project.godot` directly**. Use `project set-setting`.
- **`editor reload` after `script create`/major `script edit`**.
- **`runtime.eval`/`editor.run_script`:** no nested `func`s; `emit(v)` to return; use `.get("prop")` for dynamic access. Indent however you like, since the body is re-indented with tabs before it is wrapped.
- **A game stopped at a debugger break serves nothing**: every `runtime.*` call spends its timeout and comes back with `debugger_breaked` and the break reason. Read the stop with `debug state`, then `debug resume`.
- **Input timing:** prefer `input action` over raw `input key` when InputMap actions exist; UI buttons fire on release (`input click` auto press+releases).
- **Save:** `scene save` after significant edits.
- Mutations are undoable; reads are safe. Errors return JSON-RPC codes (`-32000` no scene/not playing, `-32001` not found, `-32602` bad params, `-32009` conflict, e.g. a scene/file open in the editor).

## Verifying a command works (for testing/QA)

To confirm a command behaves (not just returns `sent`/`ok`):
1. Set up the minimal state it needs (`scene create`/`open`; add a node of the right type; `scene play` for `runtime`/`input`).
2. Run the command.
3. **Read the result back**: `node.get`/`runtime.get` the affected property, `scene.tree` for structure, `engine.class_info` to confirm a property exists, a screenshot for visuals. Don't trust the success envelope alone.
4. On failure, read `editor errors` / `editor log`, fix, retry. Clean up test artifacts with `scene close --path X` then `scene delete --path X`, since a scene cannot be deleted while its tab is open; don't leave throwaways in the project.

`editor errors --internal=false` keeps the project's own script errors and drops the engine-internal C++ ones a filesystem rescan floods the buffer with; `--clear` drains the panel, so the next read shows only what happened since. Both make "did my change introduce an error?" answerable in one call.
