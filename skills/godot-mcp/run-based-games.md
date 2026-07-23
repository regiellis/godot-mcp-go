# Run-based games & roguelites — the data blackboard, waves, and world gen

The architecture of a run-based game (dig-and-defend, roguelite, wave survival): runs composed
from a loadout, balance as data, difficulty as a budget, worlds from seeds. Pattern-mined from
a shipped commercial Godot title's extracted source (patterns only); the blackboard/wave core
validated headless against the live engine. Complements `deckbuilder-patterns.md` (turn-based runs) and
`event-deck-games.md` (narrative runs); this is the real-time flavor.

## One reactive blackboard runs the whole game

A `Data` autoload holds **every tunable and every piece of run state** in one dot-path
key-value store: `dome.health`, `walker.weight`, `monsters.allowedtypes`. Three verbs:

- `Data.of("key")` / `ofOr(key, default)` — read (unknown key = logged error, not a crash).
- `Data.apply("key", value)` — write; every registered listener gets
  `propertyChanged(key, old, new)` (stale listener refs are swept on the way).
- `Data.listen(self, "key")` — subscribe; systems react to state instead of polling each other.
  The wave director listens to `dome.health` (damage tracking), `inventory.iron` (start the run
  on first pickup), `map.tilesdestroyed` (run really began) — zero direct references.

Why one store instead of members scattered across systems: **upgrades, difficulty modifiers,
game modes, and mods all become data writes.** Gamedata ships as YAML: each property is an
*array of leveled values*, and an upgrade is a `PropertyChange` list — "set `drill.speed` to
index 2 of its array." The tech tree is a UI over those lists. Run modifiers are pre-run
`apply()` batches. Mod support falls out for free: a mod is a data overlay. Save/load is
`serialize()` of the store. For multi-instance co-op, a *class → instances* mapping fans a
class-level write (`keeper.speed`) out to per-instance keys (`keeper1.speed`).

(This is the reactive, gamedata-backed cousin of the path-addressed Store in
`gdscript-architecture.md` — that one diffs for saves; this one broadcasts for gameplay.)

## Loadout = registries × choices

Selectable content self-registers into registries (`registerDome/Keeper/Gadget/GameMode/
RunModifier/Pet`), and a run is a *loadout*: one pick per registry, applied as data before the
run starts. Preloaded scene registries keyed by string id (drops, caves, tutorials) keep
`content/` addressable from data — a YAML value can name a cave type and the game can instance it.

## Difficulty is a weight budget, waves are authored phrases

Don't generate encounters monster-by-monster; **author small snippets** (a combat "phrase":
2–3 spawn entries plus a beat of delay, with left/right variants) and let a generator assemble
them under a budget:

- Goal weight = run-progression base × mode modifier. Each monster carries data:
  `weight`, `minRunWeight` (don't appear too early), `maxRelativeWeightInWave` (cap one type's
  share), `repeatable`/`single` flags.
- Filter snippets by those gates plus a **monster-memory ring** (last 2 waves' species; a
  non-repeatable monster can't appear twice running) — variety is enforced, not hoped for.
- Assemble: shuffle candidates, add any snippet that stays under budget, until the total lands
  inside ±10% of goal; if a bounded number of attempts fails, **relax tolerance to ±20% and
  retry, then fall back** to a guaranteed-valid single-monster wave. Never loop forever, never
  ship an empty wave.
- Cap wave *count* separately (a formula over difficulty, log of budget, and player count) —
  budget controls threat, count controls chaos.

Two companion mechanisms: **anti-stall** (track battle intensity; if the fight stalls past a
threshold, spawn "punisher" pressure) and **pity randomness** — `stabilizedRandom*` tracks each
random stream's cumulative deviation in a data property and steers the next roll back toward
the mean once it crosses a threshold. Streaks stay possible; droughts don't.

## Seeded world generation with a self-audit

The mining map generates from a **`MapArchetype` resource** (width/depth/target tile count,
three `FastNoiseLite` resources — large + small shape "viability", material hardness — and
feature toggles), so a new world size/shape is a `.tres`, not a code branch. The pipeline:

1. **Staged, ordered, and timed**: base shape → biomes → hardness → border prepass →
   resources → border → entrance. Each stage runs under a named timer and appends to a
   **generation report**; any stage error marks the report and aborts cleanly — a failed
   generation is a first-class outcome the caller handles (re-roll the seed), not a crash.
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
  keyed by id, triggered contextually — not one tutorial level.
- A `backwardcompatibility` seam wraps deserialization helpers so old saves parse through one
  choke point you can version.

## Build order

1. The `Data` blackboard + YAML/JSON gamedata loader first — every later system reads it.
2. Registries + loadout screen; content registers itself.
3. World gen as archetype resources + staged pipeline with the report; make the generator
   scene runnable standalone from day one.
4. Wave snippets as data + the budget assembler; tune with the anti-stall and pity layers last.
