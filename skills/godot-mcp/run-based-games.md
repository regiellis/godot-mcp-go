# Run-based games & roguelites: the data blackboard, waves, and world gen

The architecture of a run-based game (dig-and-defend, roguelite, wave survival): runs composed
from a loadout, balance as data, difficulty as a budget, worlds from seeds. Pattern-mined from
a shipped commercial Godot title's extracted source (patterns only); the blackboard/wave core
validated headless against the live engine. Complements `deckbuilder-patterns.md` (turn-based runs) and
`event-deck-games.md` (narrative runs); this is the real-time flavor.

## One reactive blackboard runs the whole game

A `Data` autoload holds **every tunable and every piece of run state** in one dot-path
key-value store: `dome.health`, `walker.weight`, `monsters.allowedtypes`. Three verbs:

- `Data.of("key")` / `ofOr(key, default)` reads. An unknown key logs an error instead of crashing.
- `Data.apply("key", value)` writes, and every registered listener gets
  `propertyChanged(key, old, new)` (stale listener refs are swept on the way).
- `Data.listen(self, "key")` subscribes, so systems react to state instead of polling each other.
  The wave director listens to `dome.health` (damage tracking), `inventory.iron` (start the run
  on first pickup), and `map.tilesdestroyed` (run really began), holding zero direct references.

Why one store instead of members scattered across systems: **upgrades, difficulty modifiers,
game modes, and mods all become data writes.** Gamedata ships as YAML: each property is an
*array of leveled values*, and an upgrade is a `PropertyChange` list that says "set `drill.speed`
to index 2 of its array." The tech tree is a UI over those lists. Run modifiers are pre-run
`apply()` batches. Mod support falls out for free: a mod is a data overlay. Save/load is
`serialize()` of the store. For multi-instance co-op, a *class → instances* mapping fans a
class-level write (`keeper.speed`) out to per-instance keys (`keeper1.speed`).

(This is the reactive, gamedata-backed cousin of the path-addressed Store in
`gdscript-architecture.md`. That one diffs for saves; this one broadcasts for gameplay.)

## Loadout = registries × choices

Selectable content self-registers into registries (`registerDome/Keeper/Gadget/GameMode/
RunModifier/Pet`), and a run is a *loadout*: one pick per registry, applied as data before the
run starts. Preloaded scene registries keyed by string id (drops, caves, tutorials) keep
`content/` addressable from data, so a YAML value can name a cave type and the game can
instance it.

## Difficulty is a weight budget, waves are authored phrases

Don't generate encounters monster-by-monster; **author small snippets** (a combat "phrase":
two or three spawn entries plus a beat of delay, with left/right variants) and let a generator
assemble them under a budget:

- Goal weight = run-progression base × mode modifier. Each monster carries data:
  `weight`, `minRunWeight` (don't appear too early), `maxRelativeWeightInWave` (cap one type's
  share), `repeatable`/`single` flags.
- Filter snippets by those gates plus a **monster-memory ring** holding the last 2 waves' species,
  so a non-repeatable monster can't appear twice running and waves stay varied.
- Assemble: shuffle candidates, add any snippet that stays under budget, until the total lands
  inside ±10% of goal; if a bounded number of attempts fails, **relax tolerance to ±20% and
  retry, then fall back** to a guaranteed-valid single-monster wave. Never loop forever, never
  ship an empty wave.
- Cap wave *count* separately, with a formula over difficulty, log of budget, and player count.
  Budget controls threat, count controls chaos.

Two companion mechanisms: **anti-stall** (track battle intensity; if the fight stalls past a
threshold, spawn "punisher" pressure) and **pity randomness**, where `stabilizedRandom*` tracks
each random stream's cumulative deviation in a data property and steers the next roll back toward
the mean once it crosses a threshold. Streaks stay possible; droughts don't.

## The other flavor: a declarative wave timeline

The budget assembler above generates encounters. The alternative authors them: **one schedule per
map and level**, a list of typed events on a clock. Each event names its type, when it starts, how
often it repeats, how long it lives, and how many times it may fire.

```gdscript
schedule.add({
	"type": "spawn", "interval": 1.0,
	"data": {"spawns": [{"id": "grunt", "size": 2, "max_alive": 12, "kill_rate_factor": 1.0}]},
})
schedule.add({
	"type": "spawn_wave", "start": 4.0, "interval": 0.5,
	"data": {"spawns": [{"id": "brute", "size": 8, "batch": 2}]},
})
schedule.add({
	"type": "stat_increment", "start": 2.0, "interval": 2.0, "ticks": 3,
	"data": {"id": "grunt", "field": "size", "amount": 1},
})
```

Every clock field takes seconds or `"mm:ss"`, so a schedule reads in the units a designer talks in
(`"start": "15:00"` for the boss). The three event types cover most of a survival map:

- **`spawn`** emits `size` of each entry per tick, clamped by `max_alive` counted from the scene
  group. This is the ambient population.
- **`spawn_wave`** drains a fixed authored pool `batch` at a time, moving to the next pool when one
  empties and ending the event when the last does. This is the scripted set piece.
- **`stat_increment`** rewrites a field on other events' spawn entries, which is how the schedule
  ramps itself without a second difficulty system. `ticks: 3` bounds it, so the ramp stops at an
  authored ceiling instead of climbing for the whole run.

**One systemic dial rides on top: a kill-rate factor.** Sample kills over a short window, keep a
few samples, average them, and let a spawn entry opt in with `kill_rate_factor`. A player clearing
fast gets `size + round(factor * kill_rate)` extra bodies; a struggling player gets the authored
number. One reactive knob inside an authored curve covers most of what the budget assembler is
for, at a fraction of its machinery.

### Which one to reach for

Prefer the schedule when the pacing is the design: minute three should feel a specific way, the
boss arrives at 15:00, and a playtest note translates into editing one number. It is readable end
to end, diffable, and trivially per-level, at the cost of being blind to what the player is doing.

Prefer the blackboard and budget when the *system* is the design: the run is composed from a
loadout, upgrades and modifiers are data writes, and the encounter should answer whatever the
player built. It stays interesting for longer and it is far harder to say what minute three feels
like.

The two combine cleanly, because they meet at the spawn entry. Author the schedule for pacing and
let a budget assembler fill one `spawn_wave` pool, or let the blackboard write the schedule's
`size` fields at run start. Do not run both as independent spawners; they will fight over
`max_alive` and neither reading will be true.

### Build: the schedule runner, verified live

`EventSchedule` is a `Node` under the level root that owns a `Timers` child, one `Timer` per event
clock. `Timer` and not `SceneTree.create_timer()`, because a `timeout` event has to be able to
cancel a repeating interval. Its shape:

```gdscript
static func to_seconds(value: Variant) -> float:   # "01:30" -> 90.0, 4.0 -> 4.0
func add(event: Dictionary) -> void                # before start(); events is the table
func start() -> void                               # arms start/interval/timeout per event
func report_kill() -> void                         # the game reports; the schedule averages
```

`_fire()` bumps the event's tick count, dispatches on `type`, emits `event_fired`, and stops the
event once `ticks` is reached. `_spawn()` reads live population with
`get_tree().get_nodes_in_group(id).size()` so `max_alive` is a fact rather than a tally that can
drift.

```sh
godot-mcp script create --path res://waves/event_schedule.gd --content "..."
godot-mcp scene open --path res://arena.tscn
godot-mcp node add --type Node --name Schedule --parent-path .
godot-mcp script attach --node-path Schedule --script-path res://waves/event_schedule.gd
godot-mcp script attach --node-path . --script-path res://waves/arena.gd   # builds the table
godot-mcp scene save && godot-mcp editor reload
godot-mcp script validate --all
godot-mcp scene play --mode main
```

Read the counts back, never a screenshot. Two ticks of the `spawn` event by 1.5 s:

```sh
godot-mcp test run-scenario --steps '[
  {"type":"wait","seconds":1.5},
  {"type":"assert","node_path":"Schedule","property":"spawned","operator":"gte","expected":2}
]'
# "actual": 4.0, "passed": true
```

After seven seconds the whole table has run: the grunt cap holds and the authored wave has drained
exactly its pool.

```sh
godot-mcp runtime eval --code 'emit({"grunts": get_tree().get_nodes_in_group("grunt").size(),
  "brutes": get_tree().get_nodes_in_group("brute").size()})'
# { "grunts": 12, "brutes": 8 }
```

`stat_increment` is visible in the table itself. After its three ticks the authored grunt size has
stepped from 2 to 5, and one tick then emits exactly five:

```sh
godot-mcp runtime eval --code 'var s = get_tree().current_scene.get_node("Schedule")
for n in get_tree().get_nodes_in_group("grunt"):
	n.queue_free()
emit({"authored_size": s.events[0]["data"]["spawns"][0]["size"]})'
# { "authored_size": 5 }
# one second later: grunts == 5
```

And the kill-rate dial, driven by reporting kills and waiting out a sample window:

```sh
godot-mcp runtime eval --code 'var s = get_tree().current_scene.get_node("Schedule")
for i in 20:
	s.report_kill()
emit("reported")'
godot-mcp test run-scenario --steps '[{"type":"wait","seconds":2.2}]'
godot-mcp runtime get --node-path Schedule --properties '["kill_rate"]'
# "kill_rate": 3.33
```

With `kill_rate_factor: 1.0` the next tick asks for `5 + round(3.33)` and the `max_alive` clamp
takes it to the cap, which is the clamp doing its job. Assert on `spawned` and on group counts
together: `spawned` alone cannot tell a clamped tick from a small one.

## Seeded world generation with a self-audit

The mining map generates from a **`MapArchetype` resource** (width/depth/target tile count,
feature toggles, and three `FastNoiseLite` resources covering large and small shape "viability"
plus material hardness), so a new world size/shape is a `.tres`, not a code branch. The pipeline:

1. **Staged, ordered, and timed**: base shape → biomes → hardness → border prepass →
   resources → border → entrance. Each stage runs under a named timer and appends to a
   **generation report**; any stage error marks the report and aborts cleanly. A failed
   generation is a first-class outcome the caller handles by re-rolling the seed, not a crash.
2. **Resources seed in dependency order**, each relative to what's already placed: baseline
   dirt → iron clusters → chambers/relics → *adjust* ore amounts to targets → *expand* clusters
   → water and cobalt placed **relative to the iron cluster centers** (guaranteeing the early
   game finds what it needs) → holes last. Distribution rules, not per-cell chance.
3. Seed discipline: one run seed; each noise gets `seed + n`; every shuffle uses the seeded RNG.
4. **The generator scene is its own test harness**: `_ready()` detects it was run standalone
   (`get_parent() == get_tree().root`), self-inits with a random seed, generates, prints the
   report, and adds a zoomed camera. F6 on the file = visual inspection loop.

## Production notes worth copying

- `stages/` gives *failure* first-class screens: dedicated `error`, `saveerror`, and
  platform-issue stages instead of dialogs bolted onto the title screen.
- `systems/` vs `content/` vs `stages/` is the scale layout: cross-cutting services /
  domain-organized game content / top-level flow. Tutorials are a registry of small scenes
  keyed by id and triggered contextually, rather than one tutorial level.
- A `backwardcompatibility` seam wraps deserialization helpers so old saves parse through one
  choke point you can version.

## Build order

1. The `Data` blackboard + YAML/JSON gamedata loader first, because every later system reads it.
2. Registries + loadout screen; content registers itself.
3. World gen as archetype resources + staged pipeline with the report; make the generator
   scene runnable standalone from day one.
4. Wave snippets as data + the budget assembler; tune with the anti-stall and pity layers last.
