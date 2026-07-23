# Top-down 2D & sim construction (Godot 4.7+) — components, terrains, and clocks

How top-down games (farming sims, RPGs, life sims) are assembled the Godot way: a component
library glued by signals, gameplay that *paints terrain*, and systems that run off one game
clock. Distilled from a studied complete farming game and verified live against 4.7.
`platformer-2d.md` covers side-view actors; this file is the top-down counterpart.

## Layer the world as a TileMapLayer stack

One `TileMapLayer` per meaning, in draw order, under a Y-sorted root:

```
Level (Node2D, y_sort_enabled)
└── GameTilemap (Node2D, y_sort_enabled)
    ├── Water / Grass / TilledSoil    (flat ground — no Y-sort)
    ├── Undergrowth                   (under actors)
    ├── Overgrowth (y_sort_enabled)   (sorts against actors — trees, posts)
    └── Objects (y_sort_enabled)
```

Y-sort only works when **every** node in the chain from the common ancestor down has
`y_sort_enabled` (root, actor, and the layers that must interleave). Flat ground layers stay
unsorted. Gameplay layers are separate on purpose: `TilledSoil` is its own layer so tilling,
saving, and crop placement each talk to exactly one node.

## Gameplay paints terrain — `tilemap.set_terrain`

Actions that change the ground (tilling, paths, corruption) are *terrain painting*: the engine's
autotiler picks tiles whose peering bits connect with neighbors, so one command yields
seamless patches. **Build** (verified live):
```
tilemap get-info --node-path TilledSoil            # discover terrain_sets: [{id, terrains:[{id,name}]}]
tilemap set-terrain --node-path TilledSoil --cells '[[4,2],[5,2],[5,3]]' --terrain-set 0 --terrain 0
tilemap set-terrain --node-path TilledSoil --cells '[[5,2]]' --terrain-set 0 --terrain -1   # erase
```
**Gotcha (live-verified):** a terrain must include an *island* tile — terrain assigned, **no**
peering bits — or painting isolated cells places *nothing, silently*. Author terrains in the
TileSet editor (peering bits are visual work); paint them from code/CLI.

The in-game version is a **cursor component**: mouse → cell via
`layer.local_to_map(layer.get_local_mouse_position())`, gate by
`player.global_position.distance_to(layer.map_to_local(cell))` (reach), then
`set_cells_terrain_connect([cell], set, terrain, true)`. Same shape for planting: instantiate
a crop scene at `map_to_local(cell)` under a `CropFields` container — position on the grid,
node off it.

## The component library (one Area2D, one job, one signal)

Build these once as saved scenes; every entity composes them (`scene.instance` + `node.connect`):

| component | base | contract |
|---|---|---|
| HitComponent | Area2D | carries `current_tool` + `hit_damage`; lives on the *player* |
| HurtComponent | Area2D | `@export var tool`; emits `hurt(damage)` only when the overlapping HitComponent's tool matches |
| DamageComponent | Node | accumulates; emits `max_damage_reached` |
| CollectableComponent | Area2D | on player touch: `InventoryManager.add_collectable(name)`, free parent |
| InteractableComponent | Area2D | emits `interactable_activated/deactivated` on body enter/exit |
| GrowthCycleComponent | Node | day-tick driven; emits `crop_maturity`, `crop_harvesting` |

The **tool-gating** trick makes one hit system serve axe/hoe/watering-can: HurtComponent
compares its expected tool against the hitter's current tool — no `if` forest in the player. An
entity is then pure wiring: a tree connects `hurt → damage.apply_damage`,
`max_damage_reached → drop log scene + queue_free`. A crop connects day-ticks to sprite frames
(`sprite.frame = growth_state` — growth stages as spritesheet frames, no animation needed).
Swinging a tool = enabling the HitComponent's collision shape during the swing state.

## The state machine as child nodes

When states own *behavior* (not just animation), make the machine a node with one child per
state — the inspector becomes your state editor:

```gdscript
class_name NodeStateMachine extends Node          # machine: collects NodeState children,
@export var initial_node_state: NodeState         # connects their `transition` signal,
# _physics_process: current._on_physics_process(delta); current._on_next_transitions()

class_name NodeState extends Node                 # state: signal transition
# virtuals: _on_enter/_on_exit/_on_process/_on_physics_process/_on_next_transitions
```

Each state `@export`s the nodes it drives (player, sprite, a collision shape) and stays
self-contained: `Walk` reads input and moves the body; `Tilling` plays the swing and returns to
`Idle` when `!sprite.is_playing()`. Transition rule: states decide *when to leave*
(`transition.emit("Walk")` inside `_on_next_transitions`), the machine decides *how*. Use this
when actions have logic; use the AnimationTree expression machine (`platformer-2d.md`) when
states differ only in animation. NPCs reuse the same machine with different states: `Idle`
(Timer wait) ⇄ `Walk` (pick a wander target via
`NavigationServer2D.map_get_random_point(agent.get_navigation_map(), agent.navigation_layers, false)`,
steer with `NavigationAgent2D`; with avoidance on, set `agent.velocity` and move in
`velocity_computed` — the safe-velocity handshake).

## One clock, many consumers (day/night)

A `DayAndNightCycleManager` autoload owns time as **radians** (`TAU / minutes_per_day` per game
minute, so one day = one full circle) and emits three granularities: `game_time(float)` every
frame, `time_tick(day,hour,min)` per game-minute, `time_tick_day(day)` per day. Consumers pick
their granularity:

- **Lighting**: a `CanvasModulate` component samples a `GradientTexture2D` —
  `color = gradient.sample(0.5 * (sin(time - PI/2) + 1.0))`. The gradient *is* the whole
  lighting design (night blue → dawn gold → noon white → dusk); tune colors, not code.
- **Crops**: `GrowthCycleComponent` advances one growth state per `time_tick_day` (only if
  watered), emits `crop_harvesting` after `days_until_harvest`.
- **HUD clock**: renders on `time_tick`.

Build: `project add-autoload`, then `node add --type CanvasModulate` + attach the component.

## Save = components + polymorphic Resources

Each saveable node carries a `SaveDataComponent` (in group `save_data_component`) holding a
typed Resource; a per-level `SaveLevelDataComponent` sweeps the group, calls `_save_data(node)`
on each, and `ResourceSaver.save()`s the collected array to `user://game_data/save_<level>.tres`.
Polymorphism does the heavy lifting — subclasses of a `NodeDataResource` base
(`_save_data(node)` / `_load_data(root)`) each know their own shape:

- `SceneDataResource` — stores `scene_file_path` + position; load re-instantiates and re-parents.
- `TilemapDataLayerResource` — stores a layer's `get_used_cells()`; load **repaints** them with
  `set_cells_terrain_connect`, so the autotiler rebuilds seams instead of restoring raw cells.

Adding a saveable thing = new Resource subclass + drop the component on it. No central save
switch statement. (For the diff-based alternative, see `gdscript-architecture.md` two-tier save.)

## Small patterns worth stealing

- **Doors**: open/close = `collision_layer` swap (1 ↔ 2) + animation. The wall stays; the player's
  mask simply stops matching. No node juggling.
- **Ability gating via dialogue/managers**: tools start disabled; the guide NPC's dialogue emits
  `give_crop_seeds` → `ToolManager.enable_tool_button(...)`. Progression is a signal, not a flag check.
- **Manager autoloads stay thin**: `ToolManager` = selected enum + two signals; `InventoryManager` =
  a Dictionary + `inventory_updated`. State + signals, no game logic (see `gdscript-architecture.md`
  autoload tiering).
- **Reward juice**: chest feeding tweens each item from inventory to the chest (`position`, then
  `scale`, then `queue_free` callback) with staggered `create_timer` delays — consumption reads
  physically.
- **Shader feedback**: chopping sets `material.set_shader_parameter("shake_intensity", 0.5)` for a
  second — hit feedback without touching the transform.

## Checklist

- Ground layers flat; only layers that interleave with actors get `y_sort_enabled` — and the whole
  ancestor chain has it.
- Ground-changing gameplay is terrain painting; the terrain has an island tile.
- Entities are component compositions wired by signals; tools gate hits by enum match.
- Behavior states are child nodes emitting `transition`; animation-only states use the AnimationTree.
- One time authority emits frame/minute/day signals; consumers subscribe at their granularity.
- Saveables carry components + typed Resources; tilemap state saves as cells, loads as a repaint.
- `scene save` after edits; verify live state with `runtime eval`.
