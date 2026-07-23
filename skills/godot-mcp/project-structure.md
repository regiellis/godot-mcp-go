# Project structure at scale (Godot 4)

How to lay out a real Godot project so it stays navigable past a few dozen scenes.
Distilled from a shipped commercial Godot 4 game (a deck-builder, ~900 scenes, ~2400
code files). The principles are engine-version-durable and language-agnostic — they hold
whether you write GDScript or C#. Map every action below to the CLI (`scene.create`,
`project.set_setting`, `project.add_autoload`, …).

## Separate code from assets; organize code by feature

Two top-level rules that scale:

1. **Code lives apart from assets.** Scripts in one tree (`src/` or `scripts/`); scenes,
   images, materials, shaders, themes, fonts, audio each in their own top-level folder.
   Don't scatter `.gd`/`.cs` next to every `.png`.
2. **Group code by *feature/domain*, not by *type*.** Prefer `combat/`, `cards/`,
   `map/`, `rewards/` over `controllers/`, `views/`, `models/`. A folder per game system,
   each holding everything that system needs. The shipped game has ~45 domain folders
   (`Combat`, `Cards`, `Commands`, `Map`, `Rewards`, `Saves`, …) — a contributor working
   on combat finds it all in one place.

A useful sub-split *within* a domain is **data vs. view**:
- a **`models/`** tree for pure data/logic (the card definitions, stats, run state), and
- a **`nodes/`** tree for the scripts attached to scenes (the visuals/behavior).

The shipped game keeps `Models/` (data, ~1600 files) entirely separate from `Nodes/`
(scene scripts, ~660 files). Data never imports the view; the view reads the data.

## Pair scenes with their scripts by a predictable path

Scenes and scripts live in separate trees, but **mirror the folder structure** so the
pairing is mechanical:

```
scenes/cards/card.tscn        ->  script: .../nodes/cards/card_view.gd
scenes/combat/combat_ui.tscn  ->  script: .../nodes/combat/combat_ui.gd
scenes/relics/relic.tscn      ->  script: .../nodes/relics/relic_view.gd
```

`scenes/<feature>/` ↔ `.../nodes/<feature>/`. You should be able to guess a scene's
script path (and vice-versa) without searching. The shipped game enforces this 1:1 and
prefixes node-script classes with `N` (`NCard`, `NRelic`) so a "scene script" is
instantly distinct from a data model in any file list.

## Naming

- **Scenes & resources** (`.tscn`, `.tres`) — `snake_case`: `card_grid.tscn`,
  `card_frame_red.tres`. (Godot's own convention.)
- **GDScript files** — `snake_case`: `health_component.gd`.
- **`class_name` / node names in the tree / enums** — `PascalCase`.
- **Asset folders** — `snake_case`, grouped by feature then variant:
  `materials/cards/frames/`, not a flat `materials/`.

Pick the convention once and hold it everywhere — mixed casing is the first thing that
rots in a large tree.

## Compose scenes; don't hand-build mega-trees

The defining habit of a scalable Godot project: **scenes are built by instancing other
scenes**, not by authoring one deep node tree. In the shipped game a combat-UI scene is
~5 instanced sub-scenes (energy counter, hand, end-turn button, pile container), each its
own `.tscn` with its own script:

```
[node name="CombatUi" type="Control"]            # one small script here
[node name="Hand" parent="." instance=...]       # a reusable sub-scene
[node name="EndTurnButton" parent="." instance=...]
[node name="StarCounter" parent="." instance=...]
```

Build this with `scene.instance` (compose) rather than `node.add` of 200 raw children.
A reusable visual (a card frame, a particle burst, a tooltip) becomes a sub-scene you
instance everywhere — fix it once, every use updates. See `game-patterns.md` for the
component pattern and SKILL.md "Build with composition, not monoliths".

### Node-setup conventions inside a scene

- **Script on the root only.** Children are pure visuals/structure; the root's one script
  owns the logic. Don't sprinkle scripts down the tree (a reusable child *is* a sub-scene
  with its own root script — that's different).
- **Expose children by unique name, not by path.** Mark a node "Access as Unique Name"
  and reach it as `%HealthBar` — survives reparenting. The shipped game uses `%`-access
  pervasively and almost never hard-codes `$A/B/C` chains. (GDScript: `@onready var bar :=
  %HealthBar`. The CLI sets unique-name access on a node via `node.set`.)
- **Pass child references as exported `NodePath`s** when the root must drive specific
  children (e.g. a VFX root controlling four particle emitters) — wired in the inspector,
  not looked up by string.
- **Keep visuals data-driven.** Colors, textures, offsets, materials belong on the nodes
  (set via `node.set`), so they stay inspector-editable; logic in script reads/updates
  them. Don't bake visual constants into code.

## Data as resources, in their own tree

Stats, item definitions, configs, tables → a `Resource` type with `@export`ed fields,
saved as `.tres`, grouped by feature (`data/cards/`, `data/relics/`). Code stays generic;
designers (and you, via `resource.create` + `node.set`) edit data without touching logic.
A central registry/loader that maps an id → resource keeps lookups in one place. (See
`gdscript-style.md` "Data as Resources".)

> Note: the shipped game expresses card *definitions* as code classes rather than `.tres`
> because each card has bespoke behavior (see `deckbuilder-patterns.md`). Use `.tres`
> resources for *data-shaped* content (stat blocks, drop tables); use code/script types
> when each entry carries unique behavior. Most games want both.

## Autoloads — for cross-cutting services only

Register singletons (`project.add_autoload`) for things that are genuinely
project-global and have no natural owner in the scene tree:

- asset/preload manager, audio manager, scene/transition manager, run/game state,
  save manager, a dev console.

The shipped game has ~7 autoloads — not dozens. Everything else is owned by the scene
that uses it. Reaching for an autoload to avoid passing a reference creates hidden
coupling; resist it. (See `gdscript-style.md` "class_name and autoloads — sparingly".)

## project.godot — drive it through the CLI

Never hand-edit `project.godot`; use `project.set_setting` / `project.add_autoload` /
`project.enable_plugin`. Settings worth establishing early on a new project:

- `application/run/main_scene`, window/viewport size and stretch mode,
- the **input map** (define every action *before* writing movement — see
  `game-patterns.md` build order),
- rendering driver, default clear color,
- autoloads and enabled plugins.

A real shipped `[application]` block also pins `config/features=PackedStringArray("4.5",
"C#", "Mobile")` and a custom user dir — confirm your engine/features with
`engine.version` and set them deliberately.

## `.uid` and `.import` files — commit, never edit

Every script/resource has a companion `.uid`; every imported asset a `.import`. These are
Godot-generated reference/metadata files. **Commit them** (they keep `uid://` references
stable across machines) but never author or edit them by hand.

## Transferable rules

1. Code in its own tree; assets each in their own top-level folder.
2. Organize code by **feature/domain**, not by layer/type.
3. Split **data** (resources/models) from **view** (scene scripts) within each domain.
4. Mirror `scenes/<feature>/` ↔ `scripts/<feature>/` so pairings are guessable.
5. `snake_case` scenes/resources/files; `PascalCase` types/nodes/enums; hold it everywhere.
6. Build scenes by **instancing sub-scenes**; one script on the root.
7. Access children by `%`-unique-name or exported `NodePath`, never `../../` chains.
8. Keep visuals on nodes (inspector-editable), logic in script.
9. Reserve autoloads for true cross-cutting services (a handful, not dozens).
10. Configure the project through `project.*` commands; commit `.uid`/`.import`, never edit them.
