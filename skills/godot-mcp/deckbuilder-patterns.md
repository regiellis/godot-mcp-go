# Deck-builder / card-game architecture (Godot 4)

The engine architecture a turn-based deck-builder needs (Slay-the-Spire-like: a deck, a
combat where cards queue effects, stackable powers/relics that modify those effects,
seeded runs). Reverse-engineered from a shipped commercial Godot 4 deck-builder's compiled
code, so the *patterns* are verified against real shipping software. They're
**language-agnostic** — the game ships in C#, but each pattern maps cleanly to GDScript
(mappings inline). Build the visuals/scenes with `scene.*`/`node.*` as usual; this file is
about the *logic layer* underneath.

The one idea to internalize: **gameplay effects are data-driven and resolved through a
queue, not executed inline.** A card doesn't "deal damage" directly — it *enqueues a
damage action*, which passes through every power/relic that wants to modify it. That
indirection is what makes "Strength +3", "Vulnerable ×1.5", and "double your next attack"
compose without if-spaghetti.

## 1. The action queue (the heart)

All gameplay effects are **actions** processed one at a time by a central executor. An
action can enqueue more actions; the executor drains the queue in order. This is what lets
effects cascade deterministically (play card → triggers a power → applies a buff → deals
damage → triggers an on-damage relic …).

In the shipped game each action is a small state machine (`WaitingForExecution → Executing
→ Finished`, with a `GatheringPlayerChoice` pause state) and the executor `await`s each
action frame-by-frame so animations play out before the next resolves:

```
abstract class GameAction { async Task ExecuteAction(); /* overridden per effect */ }
// ActionExecutor: while ((a = queue.GetReadyAction()) != null) { await a.Execute(); }
```

**GDScript mapping.** A `GameAction` base `class_name` with `func execute() -> void` that
can `await`; an `ActionQueue` autoload holding an `Array[GameAction]`, draining it in
`_process` or a coroutine, `await`ing each so tweens/animations finish before the next:

```gdscript
class_name GameAction extends RefCounted
func execute(ctx: CombatContext) -> void: pass   # override; may await

# ActionQueue (autoload)
var _queue: Array[GameAction] = []
func push(a: GameAction) -> void: _queue.append(a)
func _resolve() -> void:
    while not _queue.is_empty():
        await _queue.pop_front().execute(_ctx)    # one at a time, in order
```

Actions enqueue follow-ups by pushing onto the same queue. **Pattern: everything that
changes combat state is an action; actions are ordered and resolve serially.**

## 2. Commands vs. actions (two layers)

Don't conflate the queue with the mutation helpers. The shipped game separates:

- **Actions** (`GameAction`, queued) — *orchestration*: the ordered, awaitable steps
  ("play this card", "end turn", "begin enemy turn").
- **Commands** (`CreatureCmd.Damage(...)`, `CardPileCmd.Add(...)`) — *the actual mutation +
  hook dispatch*. A command directly changes state (HP, block, pile contents), fires the
  before/after hooks around that change, and triggers VFX. Commands are **called from
  inside an action's `execute()`**; they are not themselves queued.

So: `PlayCardAction.execute()` → calls `card.on_play()` → which calls
`CreatureCmd.damage(target, n)` → which runs the damage **hook pipeline** (next section),
applies the result, and emits events. Keep "what order things happen" (actions) separate
from "how one mutation is applied" (commands).

## 3. Powers / relics / status effects = a hook pipeline

Stackable modifiers (Strength, Vulnerable, Poison, relics, enchantments) are **not**
special-cased in the damage code. Instead every such modifier is a "hook listener", and
the damage calculation **walks all listeners in layers**:

```
ModifyDamage(base):
  additive layer:        foreach listener: base += listener.ModifyDamageAdditive(...)
  multiplicative layer:  foreach listener: base *= listener.ModifyDamageMultiplicative(...)
  cap layer:             foreach listener: base = min(base, listener.ModifyDamageCap(...))
  return max(0, base)
```

Each power overrides only the layer it cares about and returns the identity otherwise:

```
StrengthPower   : ModifyDamageAdditive       -> returns +Amount  (only if owner is the dealer)
VulnerablePower : ModifyDamageMultiplicative -> returns 1.5      (only if owner is the target)
```

`CombatState` exposes `IterateHookListeners()` that gathers **every** active modifier in
one pass — powers on all creatures, the player's relics, equipped potions, channeled orbs,
and even per-card afflictions/enchantments — so a hook fires across all of them uniformly.
There are many hook points beyond damage: `BeforeDamageReceived`, `AfterCardPlayed`,
`AfterTurnEnd`, `ModifyShuffleOrder`, `AfterCreatureAdded`, etc. A power decrements its own
duration in `AfterTurnEnd`.

**GDScript mapping.** A `Power`/`Modifier` base with virtual hook methods returning the
identity by default; combat code calls them in order over a gathered listener list:

```gdscript
class_name Modifier extends RefCounted
func modify_damage_additive(_c: DamageContext) -> int: return 0
func modify_damage_multiplicative(_c: DamageContext) -> float: return 1.0
func after_turn_end(_ctx) -> void: pass

# damage resolution
func compute_damage(base: int, ctx: DamageContext) -> int:
    var dmg := base
    for m in ctx.combat.all_modifiers(): dmg += m.modify_damage_additive(ctx)
    for m in ctx.combat.all_modifiers(): dmg = int(dmg * m.modify_damage_multiplicative(ctx))
    return maxi(0, dmg)
```

**Pattern: open/closed via hooks.** Adding a new relic/power means adding a listener that
overrides a hook — never editing the damage/turn code. This is the single highest-leverage
pattern in the genre; get it right first.

## 4. Cards are data + one behavior method

A card is a definition (energy cost, type, rarity, target type, keywords, and a set of
named "dynamic vars" like base-damage/block) **plus** a single overridable `on_play`
method that enqueues the card's effect via commands. Effects are *not* a data-encoded
mini-language; they're a few lines of imperative code that read the card's vars:

```
class AshenStrike : CardModel {            // declarative vars
  CanonicalVars => [ Damage(6), ExtraDamage(3), ... ]
  async OnPlay(ctx, play) =>
      await DamageCmd.Attack(DynamicVars.CalculatedDamage)
                     .FromCard(this).Targeting(play.Target)
                     .WithHitFx("vfx/slash","blunt_attack.mp3").Execute(ctx);
  OnUpgrade() => DynamicVars.ExtraDamage.UpgradeValueBy(1);   // upgrade tweaks vars
}
```

Note the **fluent command builder** (`DamageCmd.Attack(n).FromCard(c).Targeting(t)
.WithHitFx(...).Execute()`) — readable, and it threads source/target/VFX through to the
hook pipeline so modifiers know who dealt what.

**GDScript mapping.** A `Card` base `class_name` with exported stat vars and a
`func on_play(ctx, target)` override per card; upgrades adjust the vars. For *data-shaped*
cards you can drive everything from a `.tres` resource; for cards with bespoke logic, a
small script per card (extending `Card`) is cleaner than a data interpreter.

```gdscript
class_name Card extends Resource
@export var cost: int
@export var damage: int
func on_play(ctx: CombatContext, target: Creature) -> void: pass   # override

# strike.gd
extends Card
func on_play(ctx, target) -> void:
    ctx.deal_damage(self, target, damage)   # goes through the hook pipeline
```

**Pattern: declarative stats + one imperative effect hook.** Avoid inventing a card-effect
DSL early; per-card code that calls shared commands scales further than it looks.

## 5. Piles and the deck

Cards move between **piles** — Draw, Hand, Discard, Exhaust, Play, plus the persistent
Deck. A pile is a thin ordered list wrapper that emits `card_added`/`card_removed`/
`contents_changed` and integrates with hooks (shuffling fires `ModifyShuffleOrder`; adding
to a combat pile subscribes the card to the combat state tracker). Hand is capped (10).
Moving a card = remove from its current pile, add to the target pile (top/bottom), fire the
`AfterCardChangedPiles` hook.

**GDScript mapping.** A `CardPile` holding `Array[Card]` with `signal contents_changed`,
`add(card, position)`, `remove(card)`, and a `shuffle(rng)` that uses the **seeded** RNG
(next section). Draw = pop from Draw into Hand; reshuffle Discard into Draw when empty.

## 6. Seeded RNG and determinism

A roguelike must be reproducible — same seed → same run (for daily challenges, leaderboard
fairness, multiplayer lockstep, and bug repro). The shipped game wraps a PRNG with an
explicit **call counter** and seeds **multiple independent streams**:

```
class Rng {
  Rng(uint seed); int NextInt(max); void Shuffle<T>(IList<T>); int Counter;  // counts every draw
  Rng(uint seed, string name) : this(seed + Hash(name)) { }  // derive a named sub-stream
}
```

- The `Counter` lets you snapshot/replay RNG state exactly.
- **Separate streams per decision domain** (card rewards, map layout, monster moves, shuffle)
  so consuming a random number in one system can't shift another system's results. Streams
  are derived from the run's root seed by name/coordinate.

**GDScript mapping.** Use `RandomNumberGenerator` (it has `seed` and `state` you can
save/restore), one instance per stream, all derived from the run seed:

```gdscript
var rng := RandomNumberGenerator.new()
rng.seed = run_seed + hash("card_rewards")     # named sub-stream
# save/restore determinism: store rng.state with the run; reassign to resume
```

**Pattern: never call the global RNG for gameplay.** Own your seeded streams; persist their
state with the save.

## 7. Combat state, history, and saves (event sourcing)

`CombatState` is the mutable snapshot of a fight — ally/enemy creature lists, round number,
whose turn, encounter, modifiers — mutated in place, emitting events on change. A
`Creature` holds HP/block/powers and emits `BlockChanged`/`HpChanged`/`PowerApplied` so the
view updates reactively (the node never polls).

Above combat, the **run** records *history entries* (cards drawn/played, damage received,
powers applied, choices made) rather than only snapshotting state. This **event-sourcing**
gives you: deterministic replay, undo (rewind one entry), multiplayer verification
(checksum the action stream), and analytics — for free, because every change already went
through the action queue.

**GDScript mapping.** A `CombatState` object with creature arrays + `signal` per stat; a
`RunHistory` that appends a small record per resolved action. Save the seed + history (or
periodic state snapshots) to `user://`. Reactive UI: nodes `connect` to creature/state
signals; **never** read combat numbers every frame.

## 8. Model / entity / view separation

Three distinct layers — keep them apart:

- **Definition** (`CardModel`, `MonsterModel`, …) — static template, looked up by id from a
  central registry/db.
- **Runtime entity** (`Creature`, the live `Card` in a pile) — mutable per-run state
  (current HP, applied powers, pile location), emits change events.
- **View node** (the `.tscn` + its script) — listens to the entity's events and renders;
  holds no game rules.

Data flows id → registry → entity (created/mutated by actions) → view (reacts to events).
The view can be regenerated or restyled without touching rules; rules can be unit-tested
without a scene tree.

## Cheat-sheet — the 10 patterns to replicate

1. **Action queue.** Every effect is a queued action; the executor drains serially, awaiting each.
2. **Two layers.** Actions orchestrate order; commands apply one mutation + fire hooks.
3. **Hook pipeline.** Powers/relics override damage/turn hooks in additive→multiplicative→cap layers — never edit core math to add a modifier.
4. **One listener gather.** Combat state yields *all* active modifiers (powers, relics, potions, orbs, card afflictions) in one pass.
5. **Cards = data + `on_play`.** Declarative stat vars plus one imperative effect method calling shared commands; upgrades tweak vars.
6. **Fluent command builders.** `damage(n).from(card).at(target).with_fx(...)` threads source/target/VFX into the pipeline.
7. **Piles as signaling lists.** Draw/Hand/Discard/Exhaust/Play/Deck; move = remove+add+hook; hand capped.
8. **Seeded multi-stream RNG.** One seeded stream per decision domain, derived from the run seed; persist state.
9. **Event-sourced history.** Record actions, not just snapshots → replay, undo, verify, analytics.
10. **Model/entity/view split.** Definition (registry) → runtime entity (events) → view node (reacts), data flowing one way.

Build order: hook pipeline + action queue first (1–4), then cards (5–6), then piles/RNG
(7–8), then history/save and the reactive view (9–10). The view is last — it should be a
thin reaction to entity events, addable once the logic layer resolves a fight headlessly.
