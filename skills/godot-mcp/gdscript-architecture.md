# Large-scale GDScript architecture

How to structure the *runtime* of a big GDScript game so it stays decoupled and
navigable — the layer above `project-structure.md`'s folder layout. Distilled from a
shipped commercial Godot narrative game (real GDScript source: ~800 scripts, ~1000
scenes, 22 autoloads, 8 locales, console releases). Patterns are durable and map straight
to the CLI (`project.add_autoload`, `script.create`, `node.add`). For any exact API,
confirm against the live engine with `engine class-info`/`engine search`.

The throughline: **decouple by indirection, not by reaching across the tree.** Global
*services* found by name, *state* addressed by path, *nodes* found by a query index, and
*commands* dispatched through a handler chain — so no system hard-references another's tree
position.

## Tier your autoloads; keep logic out of them

22 autoloads sounds like a lot, but it scales because they're *tiered by role*, not a
junk drawer of managers:

- **Core spine** — `Constants` (enums/paths/regexes), `Game` (orchestrator), `Utils`,
  `Service` (locator), `Index` (node query), `Store` (state).
- **Data/state** — the state store, the narrative/story engine, input config.
- **Engine wrappers** — one autoload each fronting a subsystem: camera, audio (FMOD),
  environment/render toggles, controller-icon mapping. These insulate game code from
  version-specific engine APIs in one place.
- **Persistent UI overlays** — pause screen, debug console, perf monitor, loaded as
  `.tscn` autoloads so they carry a full node tree.

Rule: an autoload holds **cross-cutting state or an adapter**, never gameplay logic.
Gameplay lives in scenes and components. Register with `project.add_autoload`.

## The three spine patterns

These three small autoloads remove almost all need for `get_node("../../")` and fragile
singletons. Reproduce them on any large project.

### 1. Service locator by naming convention (`Service`)

An autoload watches the whole tree (`get_tree().node_added/removed/renamed`); any node
**named with a `$` prefix** auto-registers under that name. Retrieve the live instance with
`Service.of("Name")` — null-safe if absent.

```gdscript
# A node named "$SceneManager" anywhere in the tree becomes:
@onready var scene_manager = Service.of("SceneManager")
@onready var dialogue = Service.of("DialogueHandler")
```

No manual registration, no singleton bloat: each service is just a node living in the
scene that owns it, discoverable in the editor (you can *see* `$ScreenNavigator`). The
shipped game routes ~10 services (ScreenNavigator, NotificationHandler, DialogueHandler,
Fader…) this way. **Pattern: convention-registered service locator** — decouples callers
from where a service lives.

### 2. Node query index (`Index`)

An autoload that indexes nodes of chosen custom classes by a key field, kept current via
tree signals. Look a node up by *what it is and a key*, not by path:

```gdscript
# Index registers SkitContainer by "id", SpeechBubblePivot by "alias", etc.
var pivot = Index.get_with("SpeechBubblePivot", "Player")
var skit  = Index.get_with("SkitContainer", "WakeUp")
```

Two index kinds — unique (one node per key) and multiple (many per key, with an optional
predicate filter). **Pattern: spatial/semantic node registry** — lets logic find "the
player's speech anchor" without knowing the scene structure.

### 3. Path-addressed state store (`Store`)

State lives in JSON "databases" loaded at boot, addressed by a `db://a/b/c` path parsed
with a regex. Read/write anywhere without threading references:

```gdscript
Store.get_value("state://chapter1/met_alice")   # read
Store.set_value("fb://posts/%s/liked" % id, true) # write (mutates the live dict)
```

`$`-prefixed keys hold transient per-DB config (UI state, high scores) kept separate from
narrative content. **Pattern: central state addressed by path** — code references *data*,
not objects, and the store owns persistence (next section).

## Two-tier save: a Resource header + JSON-diff checkpoints

Don't serialize one giant blob. The shipped game saves in two complementary tiers:

1. **A `Savegame` Resource** (`ResourceSaver.save` to `user://savegame.res`) for the small,
   always-present header: current scene key, playthrough, unlocked scenes, NG+ flags. It
   carries its own **md5 checksum** (recompute on load → detect corruption), writes a
   **`.bak`** before overwriting, and has a **`version` field with a migration `match`** so
   old saves upgrade in place.

   ```gdscript
   # on load: backup, checksum-verify, migrate
   if save.md5 != save.compute_md5(): corrupted_flag = true   # fall back to .bak
   match save.version: 1: save.migrate()                       # upgrade old saves
   ```

2. **Per-scene JSON diffs** for the large mutable state. On leaving a scene the store
   diffs each database against its loaded defaults and writes only the delta to
   `user://store/<scene_id>/`. On entering, it finds the **nearest prior checkpoint** and
   patches forward.

   Why diffs, for a narrative game: the databases (social feeds, emails, web pages) are
   hundreds of KB but only a few values change per scene — a 500 KB DB becomes a ~2 KB diff.
   It also makes saves **scene-addressable** (rewind to any visited scene) for free.

**Pattern: small verified Resource header + diff-per-checkpoint for bulk state.** Reach for
it whenever bulk state dwarfs what actually changes between save points.

## The Game orchestrator + a scene directory

A single `Game` autoload owns the run: savegame/config, pause, time, platform, and **all
scene transitions**. Scenes are addressed by **string keys** (`"1.1a"`, `"1.2"`) resolved
through a `SceneDirectory` built from a JSON file — never by hard-coded paths:

```gdscript
Game.to_scene_key("1.1a")     # load by key (looks up path, shows loading screen)
Game.to_next_scene()          # follow the chapter chain to the next key
```

`change_scene_to_*` is wrapped (`Game.change_scene`) to pass params, emit
`will_change_scene`, and clear per-scene caches. **Pattern: key-addressed scene graph** —
content authors reference `"3.2b"`, not a `res://` path; the directory owns chapter order,
NG+ variants, hidden/unlocked state.

## A `Scene` base class with a lifecycle contract

Every story scene `extends Scene` (a `class_name`), not `Node3D`. The base provides a
uniform contract the orchestrator relies on:

```gdscript
class_name Scene extends Node
@export var pausable := true
@export var auto_fade_in := true
@onready var key: String = Game.get_scene_param("scene_key", "")
func exit_scene(): if auto_fade_out: await _fade_out()   # awaited by Game before swap
```

So `Game` can do `await last_scene.exit_scene()` and read `last_scene.key` on *any* scene.
Fade in/out, shader pre-caching, and audio cleanup are handled once in the base; a
`CutScene extends Scene` adds skip UI and disables pause. **Pattern: a scene base class is
the contract between your scene-router and your content** — give every routed scene the
same `key` + `enter/exit` shape.

## Components vs. modules

Two reuse tiers, kept distinct:

- **Components** (`components/`) — single-responsibility, scene-bound building blocks
  (`Focus`, `CameraEffects`, `AudioEventEmitter`). `class_name`, heavy `@export`
  (with `@export_group`), communicate by **signals**, instanced into scenes. A component
  may create child components.
- **Modules** (`modules/`) — feature-complete subsystems that own their domain
  (a rhythm minigame, the record-replay harness), often a deep folder of tightly-coupled
  files with their own internal state machines. Modules *use* components; components never
  depend on modules.

Litmus test: a thing you'd drop onto many different nodes is a component; a self-contained
*feature* with its own scenes/state is a module.

## Controller focus: a focus stack (console-grade UI)

Gamepad-driven UI needs deliberate focus routing (Godot's default focus assumes
mouse+keyboard). The shipped game uses a global **focus stack**:

- A `FocusManager` autoload holds a stack of named focus scopes and emits `focus_changed`;
  there's always a base scope that's never popped.
- A small `Focus` **component** (with an `@export focus_name`) sits on each input region,
  listens to `focus_changed`, and flips its own `active` flag — input handlers consume
  input only while active.

Opening dialogue pushes a `"dialogue"` scope (interactive areas go inert); closing it pops
back. **Pattern: push/pop focus scopes + per-region focus components** — narrative code can
even script focus transitions. Essential for console certification.

## Determinism & a record-replay harness

For QA and reproducibility the game seeds RNG (`seed(...)` at boot) and ships a
**record-replay module**: an overlay that records timestamped input events (and continuous
mouse position) to a `Resource`, then replays them frame-synced, exiting with **CI exit
codes** (pass/timeout/fail). State systems explicitly *skip* saving while replay is active
to eliminate nondeterminism. **Pattern: record/replay input for automated playtests** —
worth it once a game is too large to test by hand.

## Transferable rules

1. Tier autoloads by role (spine / state / engine-wrapper / overlay); keep gameplay out of them.
2. Find services by name via a **convention-registered locator** (`Service.of("X")`), not tree paths.
3. Find nodes by class+key via a **query index**, not `get_node("../../")`.
4. Address state by **path** in a central store; reference data, not objects.
5. Save a **small checksummed, versioned Resource header** + **diff-per-checkpoint** for bulk state.
6. Route scenes by **string key** through a JSON scene directory; wrap `change_scene`.
7. Give every routed scene a **base class** with a uniform `key` + `enter/exit` contract.
8. Split **components** (scene-bound, exported, signal-driven) from **modules** (self-contained features).
9. For gamepad UI, manage a **push/pop focus stack** with per-region focus components.
10. Wrap each engine subsystem (audio/camera/render) behind **one adapter autoload**; seed RNG and add **record-replay** for deterministic QA.
