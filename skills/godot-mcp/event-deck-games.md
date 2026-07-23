# Event-deck / swipe-decision games (Reigns-like) — data, selection, outcomes

The architecture of a narrative decision game: a deck of authored event cards, a handful of
pillar stats, binary decisions with consequences, chains, and characters. Mined from a
production Godot rewrite of a shipped commercial title (a 2,400-line Unity monolith decomposed
into signal-connected nodes); the selection/condition core validated headless against the live engine.
`deckbuilder-patterns.md` covers combat card games; this is its narrative sibling.

## Decompose the rules into a pipeline of peers

The monolith splits into sibling nodes under one orchestrator, each with one job:

```
MainGame (orchestrator: turn loop, wiring, save)
├── VariableStore       (all numeric state + change signals)
├── BearerManager       (characters: presence, votes, text templating)
├── CardSelector        (filter + weighted pick)
├── OutcomeApplicator   (apply decision consequences)
├── EffectManager / ObjectiveManager / ...
```

Two composition rules make it clean. **Dependencies are call arguments**: `select(...)` and
`apply(...)` receive the `VariableStore`/`BearerManager` they need — no global lookups, so each
node is testable alone and the evaluator can even be a stateless `static` class. **Consequences
are intent signals**: the applicator never touches cards or characters; it emits
`chain_requested`, `bearer_add_requested`, `card_destroy_requested`, and the orchestrator wires
those to whoever owns the action. Porting note: this *is* the Unity→Godot playbook — one god
class becomes a scene of peers, method calls inward, signals outward.

## Immutable data + a mutable overlay

Cards are `.tres` Resources converted from the authoring format (CSV → a `csv_to_tres` editor
tool) and **never mutated at runtime**. Everything the game does *to* a card lives in a
`card_states: Dictionary` overlay keyed by card id: `destroyed`, `is_locked`,
`next_turn` (re-eligible after a cooldown; a huge lock = "once per reign"). Saves persist the
overlay + the variable store, never the resources. This is the general shape for any
data-driven game: author-owned immutable resources, runtime-owned overlay, save = overlay.

## Selection: filter, then cumulative weights

Each turn: filter the deck (overlay state, cooldowns, owner-character present, not the same
character twice in a row, conditions pass), then pick by **cumulative weight** (append running
sums, roll once, first bucket that exceeds the roll). Two escape hatches that make authoring
expressive: **weight < 0 means "forced — play me now"** (checked during the scan, before any
roll), and **weight 0 means "never random"** — reachable only by name via a *chain*. A chain is
an outcome that names the next card (prefix routes to a hidden deck); a **postponed chain**
schedules it N turns out — the delayed-consequence tool ("the emissary returns three years
later...").

## Conditions and outcomes: tiny DSLs, not code

A condition row is `(variable | character, op, value)` with ops above/below/equal/not/modulo
("every 3rd year"). AND is the default; **OR is a flag on a row** that short-circuits: "if true
so far, done; else reset and keep evaluating." The same flag on *outcomes* means a **coin flip
between alternatives** — authored randomness with no code. Variables are one store with two
namespaces: enum pillars, and string customs where **prefixes are behavior**: `nb_` clamps ≥ 0
(counters), `inc_` self-increments each turn (timers), `*_keep` survives the reign-reset.
Character text templating (`treat_text`) substitutes names/titles at display time.

## The four-pillar death design

Pillar stats (church/army/people/treasury) run 0–100 and **you lose at either end** — too
little money is bankruptcy, too much breeds a coup. That one rule turns every decision into a
balancing act rather than a maximization. The gauges preview which pillars a decision touches
(dots sized by magnitude on hover/drag preview — but never the direction; that's the gamble).
On death, the *cause* card chains into an epitaph, and a new reign starts: age reset, pillars
equalized, customs wiped except `*_keep` — persistent world, disposable monarch.

## The swipe verb

One controller emits the whole interaction: `decision_previewed(±1)` while dragging past a
fraction of the threshold (drives the answer captions + gauge preview dots),
`decision_made(±1)` on release past it, `decision_cancelled` (spring snap-back) otherwise.
Card rotation is `clamp(offset/threshold) * factor` — tilt proportional to commitment. Cards
can constrain to `only_yes`/`only_no` (the drag mirrors to the allowed side). Keyboard/gamepad
map to the same signals, so every input device speaks "swipe." Decisions are `+1/-1`
throughout the whole pipeline — the sign *is* the API.

## Production-standards nuggets worth stealing

From the port's own standards doc: resources immutable / saves forward-compatible (new fields
default, unknown fields ignored, corrupt saves fall back — never crash); autoloads as thin
service locators; every player-facing string through `TranslationServer` from day one (`.po`
generated from the authoring CSVs); input works on keyboard + mouse + touch + gamepad via the
input map, never device checks; no per-frame allocation in the hot loop (selection/evaluation).

## Build order

1. Resources + enums first (`script.create` the `Resource` subclasses; a converter tool for
   the authoring data).
2. The store/evaluator/selector/applicator as plain nodes — headless-testable before any UI.
3. Orchestrator + card display + swipe controller (`scene2d`, `node.connect` the intent signals).
4. Gauges with preview; chains; death/reign cycle; saves last (it's just the overlay + store).
