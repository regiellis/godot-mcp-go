# Boss patterns: phase tables and behaviour containers

Multi-phase boss AI as three separable pieces: a **declarative phase table**, a small
**PhaseController** that watches for triggers and dispatches to named handlers, and a
**behaviour container** that holds the boss's moves as named objects in ordered groups so a
phase can add, retune, remove, or lock them. Every recipe below was driven against a live
4.7.2-rc editor and a running game.

Read `game-patterns.md` for the state machine this replaces at scale, `ai-steering.md` for the
movement a behaviour drives, and `run-based-games.md` for the wave timeline that spawns the boss.

## Why a table instead of a state machine

A boss written as a state machine grows one transition per pair of states, so the fifth phase
costs more than the second, and the fight is spread across `match` arms nobody can read as a
whole. Three properties are worth designing for instead:

- **The fight is readable in one place**. A designer reads the table and knows what 40% health
  does. Rebalancing means editing one number.
- **Phases add, they do not replace**. Phase 2 keeps phase 1's moves and layers on. Handlers
  stay short because each one only says what changed.
- **A phase advances on health or on a clock**. Health alone means a passive player never sees
  the last phase; a clock alone ignores how the fight is going. Support both and take whichever
  fires first.

## The phase table

One array of dictionaries. `health` is a fraction of max, compared with `<=`. `timeout` is
seconds from the moment the phase was entered. Either may be absent, and both may be present.

```gdscript
var phases: Array[Dictionary] = [
	{"health": 1.0, "handler": "_on_phase_0"},
	{"health": 0.6, "handler": "_on_phase_1"},
	{"health": 0.25, "handler": "_on_phase_2", "timeout": 3.0},
	{"health": 0.05, "handler": "_on_phase_3"},
]
```

Phase 0 carries `health: 1.0` so it fires the moment the controller starts. A boss with per-level
tables keys them by level and picks at `_ready`, falling back to the highest authored level, which
keeps one boss scene serving an endless mode.

### PhaseController

It needs two things from the boss: the host answers `call(handler)`, and a `Stats` child emits
`health_changed`. Any boss meeting those two conditions can reuse the same controller.

```gdscript
class_name PhaseController extends Node

## Reads a declarative phase table and calls one named handler on the host per
## phase. A phase advances when health falls to its fraction of max, or when
## its timeout elapses, whichever comes first.
signal phase_entered(index: int, handler: StringName)

var host: Node
var stats: Stats
var phases: Array[Dictionary] = []
var phase_index := 0
var stale_timeouts := 0

var _generation := 0


func start(new_host: Node, new_phases: Array[Dictionary]) -> void:
	host = new_host
	stats = new_host.get_node("Stats")
	phases = new_phases
	if phases.is_empty():
		return
	stats.health_changed.connect(_on_health_changed)
	_enter_next()


func _on_health_changed(current: float, maximum: float) -> void:
	if phase_index >= phases.size():
		stats.health_changed.disconnect(_on_health_changed)
		return
	var phase: Dictionary = phases[phase_index]
	if not phase.has("health"):
		return
	if current / maximum <= float(phase["health"]):
		_enter_next()


func _enter_next() -> void:
	if phase_index >= phases.size():
		return
	var phase: Dictionary = phases[phase_index]
	var handler := StringName(phase["handler"])
	phase_index += 1

	## A timeout armed for the phase being left must not fire into the one
	## being entered. SceneTreeTimer cannot be cancelled, so stamp it.
	_generation += 1
	var generation := _generation

	host.call(handler)
	phase_entered.emit(phase_index - 1, handler)

	if phase.has("timeout"):
		var timer := get_tree().create_timer(float(phase["timeout"]))
		timer.timeout.connect(_on_phase_timeout.bind(generation))


func _on_phase_timeout(generation: int) -> void:
	if generation != _generation:
		stale_timeouts += 1
		return
	_enter_next()
```

**The generation stamp exists because `SceneTreeTimer` has no cancel.** A 3 second timeout armed
for phase 2 still fires after health has already carried the fight into phase 3, and without the
stamp that late call advances a phase nobody asked for. `stale_timeouts` counts the discards so
the guard is observable from `runtime get`.

`stale_timeouts` and `phase_index` are the two numbers to read back after driving the fight. A
screenshot cannot show either one.

## Behaviours: named, grouped, ticked in order

A boss's moves are the part that changes per phase, so they cannot live in the boss script. Give
each move its own object with an `id`, a `group_id`, and a `tick(delta)`, and let a container own
them.

Groups are the reason this beats a plain array. Five groups in a fixed process order
(`buff`, `move`, `attack`, `debuff`, `default`) mean a speed buff applies before the chase reads
`move_speed` in the same frame, and a freeze debuff lands after the attack that provoked it. Node
order cannot give that once phases add and remove behaviours at runtime, so the container sorts
by group and drives `tick()` itself.

```gdscript
class_name Behaviour extends Node

## One named unit of enemy behaviour. The container owns it, ticks it, and
## enables or disables it by group. Never define _process here: the container
## decides the order behaviours run in.
signal disabled_changed(is_disabled: bool)

var group_id: StringName = &"default"
var id: StringName
var host: Node
var container: Node  # BehaviourContainer; typing it as such would cycle

var _disable_count := 0


## Disable requests nest. Two systems may each hold this behaviour down, and it
## stays down until both let go.
func push_disable() -> void:
	_disable_count += 1
	if _disable_count == 1:
		disabled_changed.emit(true)


func pop_disable() -> void:
	if _disable_count == 0:
		return
	_disable_count -= 1
	if _disable_count == 0:
		disabled_changed.emit(false)


func is_disabled() -> bool:
	return _disable_count > 0


func tick(_delta: float) -> void:
	pass


func lock_others_in_group() -> void:
	container.disable_group(group_id, [id])


func unlock_others_in_group() -> void:
	container.enable_group(group_id, [id])
```

**Two counters do the bookkeeping.** A **reference count** per behaviour lets two phases both
want `melee` without either owning it: the second `add` bumps the count and retunes the data, and
a `remove` from one phase leaves the other's registration standing. A **nested disable count** per
behaviour lets a dash and a freeze both hold `melee` down, with `melee` waking only when both let
go. A plain boolean in either slot produces a boss that stops attacking forever after two systems
overlap once.

```gdscript
class_name BehaviourContainer extends Node

const GROUP_ORDER: Array[StringName] = [&"buff", &"move", &"attack", &"debuff", &"default"]

var host: Node

var _behaviours: Dictionary = {}
var _refs: Dictionary = {}
var _group_locked: Dictionary = {}
var _order: Array[StringName] = []
var _order_dirty := false


func _ready() -> void:
	host = get_parent()


func _process(delta: float) -> void:
	if _order_dirty:
		_rebuild_order()
	for behaviour_id in _order:
		var behaviour: Behaviour = _behaviours[behaviour_id]
		if not behaviour.is_disabled():
			behaviour.tick(delta)


## Register, or bump the reference count of an already-registered behaviour and
## retune it. Two phases can both want "melee" without either owning it.
func add(behaviour_id: StringName, script_path: String, data: Dictionary = {}) -> Behaviour:
	if _behaviours.has(behaviour_id):
		_refs[behaviour_id] += 1
		_apply(behaviour_id, data)
		return _behaviours[behaviour_id]
	var behaviour: Behaviour = load(script_path).new()
	behaviour.id = behaviour_id
	behaviour.name = String(behaviour_id)
	behaviour.host = host
	behaviour.container = self
	_behaviours[behaviour_id] = behaviour
	_refs[behaviour_id] = 1
	add_child(behaviour)
	_apply(behaviour_id, data)
	if _group_locked.get(behaviour.group_id, false):
		behaviour.push_disable()
	_order_dirty = true
	return behaviour


func remove(behaviour_id: StringName) -> void:
	if not _behaviours.has(behaviour_id):
		return
	_refs[behaviour_id] -= 1
	if _refs[behaviour_id] > 0:
		return
	var behaviour: Behaviour = _behaviours[behaviour_id]
	_behaviours.erase(behaviour_id)
	_refs.erase(behaviour_id)
	behaviour.queue_free()
	_order_dirty = true


## Lock a whole group. A behaviour added while the group is locked comes up
## disabled, so a phase cannot hand a dash a live attack behaviour mid-dash.
func disable_group(group_id: StringName, except: Array = []) -> void:
	if except.is_empty():
		_group_locked[group_id] = true
	for behaviour_id in _behaviours:
		var behaviour: Behaviour = _behaviours[behaviour_id]
		if behaviour.group_id == group_id and not except.has(behaviour_id):
			behaviour.push_disable()


func enable_group(group_id: StringName, except: Array = []) -> void:
	if except.is_empty():
		_group_locked[group_id] = false
	for behaviour_id in _behaviours:
		var behaviour: Behaviour = _behaviours[behaviour_id]
		if behaviour.group_id == group_id and not except.has(behaviour_id):
			behaviour.pop_disable()


## The read-back surface. Rebuild first: _order is refreshed in _process, so a
## report taken in the same frame a phase registered would come back empty.
func report() -> Dictionary:
	if _order_dirty:
		_rebuild_order()
	var out := {}
	for behaviour_id in _order:
		var behaviour: Behaviour = _behaviours[behaviour_id]
		out[String(behaviour_id)] = {
			"group": String(behaviour.group_id),
			"disabled": behaviour.is_disabled(),
			"refs": _refs[behaviour_id],
		}
	return out


func _apply(behaviour_id: StringName, data: Dictionary) -> void:
	var behaviour: Behaviour = _behaviours[behaviour_id]
	for key in data:
		if not (key in behaviour):
			push_error("behaviour %s has no field %s" % [behaviour_id, key])
			continue
		behaviour.set(key, data[key])


func _rebuild_order() -> void:
	_order.clear()
	for group in GROUP_ORDER:
		for behaviour_id in _behaviours:
			if _behaviours[behaviour_id].group_id == group:
				_order.append(behaviour_id)
	_order_dirty = false
```

`get_behaviour(id)`, `ref_count(id)` and `group_locked(id)` round out the reads; each is a one
line dictionary lookup.

### Group locking: a dash that stands the rest down

A dash, a channel, or a leap needs exclusive control for its duration. The behaviour asks for it
so the boss script never has to list which moves conflict with it:

```gdscript
extends Behaviour

signal finished

var duration := 0.4
var speed := 400.0
var dashes := 0
var executing := false

var _elapsed := 0.0


func _init() -> void:
	group_id = &"move"


## Lock everything that could fight this dash: the rest of the move group, and
## the attack group whole. Release both when it ends, never on a branch that
## can return early.
func execute() -> void:
	if executing:
		return
	executing = true
	dashes += 1
	_elapsed = 0.0
	lock_others_in_group()
	container.disable_group(&"attack")


func tick(delta: float) -> void:
	if not executing:
		return
	_elapsed += delta
	host.position += Vector2.UP * speed * delta
	if _elapsed < duration:
		return
	executing = false
	unlock_others_in_group()
	container.enable_group(&"attack")
	finished.emit()
```

The release has to sit on the single path that ends the dash. A lock taken in `execute()` and
released inside a branch that an early `return` can skip leaves the boss permanently passive, and
because the disable count nests, that leak shows up only on the run where two locks overlapped.

### Phase handlers say only what changed

```gdscript
const BEHAVIOURS := "res://boss/behaviours/"

func _on_phase_0() -> void:
	behaviours.add(&"chase", BEHAVIOURS + "chase.gd")
	behaviours.add(&"melee", BEHAVIOURS + "melee.gd", {"cooldown": 0.25})


func _on_phase_1() -> void:
	behaviours.add(&"dash", BEHAVIOURS + "dash.gd", {"duration": 0.4})
	behaviours.add(&"melee", BEHAVIOURS + "melee.gd", {"cooldown": 0.15})


func _on_phase_2() -> void:
	behaviours.remove(&"chase")
	behaviours.get_behaviour(&"dash").execute()


func _on_phase_3() -> void:
	behaviours.remove(&"melee")
```

Phase 1's second `add(&"melee", ...)` is the reference-count case: `melee` goes to two references
and its cooldown drops from 0.25 to 0.15. Phase 3's `remove` takes it back to one, so it keeps
swinging. The transcript below shows both counts.

## Build: a four-phase boss, driven and read back

Bootstrap a bed, then build the scene. `Stats` is the one script not shown above: it emits
`health_changed(current, maximum)` and exposes `damage(amount)`. `chase` and `melee` follow
`dash`'s pattern with no locking.

```sh
godot-mcp create --path ./boss-bed --name BossBed --install --enable
cd boss-bed && godot-mcp launch

godot-mcp script create --path res://boss/stats.gd            --content "..."
godot-mcp script create --path res://boss/behaviour.gd        --content "..."
godot-mcp script create --path res://boss/behaviour_container.gd --content "..."
godot-mcp script create --path res://boss/phase_controller.gd --content "..."
godot-mcp script create --path res://boss/boss.gd             --content "..."
godot-mcp script create --path res://boss/behaviours/chase.gd --content "..."
godot-mcp script create --path res://boss/behaviours/melee.gd --content "..."
godot-mcp script create --path res://boss/behaviours/dash.gd  --content "..."

godot-mcp scene create --path res://boss/boss.tscn --root-type Node2D --root-name Boss
godot-mcp node add --type Node --name Stats --parent-path .
godot-mcp node add --type Node --name Behaviours --parent-path .
godot-mcp node add --type Node --name PhaseController --parent-path .
godot-mcp script attach --node-path Stats --script-path res://boss/stats.gd
godot-mcp script attach --node-path Behaviours --script-path res://boss/behaviour_container.gd
godot-mcp script attach --node-path PhaseController --script-path res://boss/phase_controller.gd
godot-mcp script attach --node-path . --script-path res://boss/boss.gd
godot-mcp scene save

godot-mcp editor reload            # class_name files need the rescan before validate
godot-mcp script validate --all    # "failed": 0, "passed": 8
```

Then play and drive the fight by damaging the boss directly. `Stats.damage()` is a plain method,
so `runtime call` reaches it without a script:

```sh
godot-mcp scene play --mode main
godot-mcp runtime call --node-path Boss/Behaviours --method report
godot-mcp runtime call --node-path Boss/Stats --method damage --args '[45]'
godot-mcp runtime get  --node-path Boss/PhaseController --properties '["phase_index"]'
```

The verified sequence, trimmed to the fields that matter. Phase 0 on start:

```
"chase": { "group": "move",   "disabled": false, "refs": 1 }
"melee": { "group": "attack", "disabled": false, "refs": 1 }
```

`damage 45` takes health to 55%, crossing phase 1's `0.6`. `dash` joins the move group, `melee`
goes to two references:

```
"chase": { "group": "move",   "disabled": false, "refs": 1 }
"dash":  { "group": "move",   "disabled": false, "refs": 1 }
"melee": { "group": "attack", "disabled": false, "refs": 2 }
```

`damage 35` takes health to 20%, crossing `0.25`. Phase 2 removes `chase` and calls
`dash.execute()`. Read the report inside the dash's 0.4 s window and the lock is visible: `chase`
is gone, `dash` runs, `melee` is held down by the attack-group lock while keeping both references:

```
"dash":  { "group": "move",   "disabled": false, "refs": 1 }
"melee": { "group": "attack", "disabled": true,  "refs": 2 }
```

`damage 16` takes health to 4%, crossing phase 3's `0.05` before phase 2's 3 s timeout elapses.
Assert on the discarded timer instead of waiting and eyeballing it:

```sh
godot-mcp test run-scenario --steps '[
  {"type":"wait","seconds":4},
  {"type":"assert","node_path":"Boss/PhaseController","property":"phase_index","operator":"eq","expected":4},
  {"type":"assert","node_path":"Boss/PhaseController","property":"stale_timeouts","operator":"eq","expected":1}
]'
```

Both pass: `phase_index` 4 with four phases authored, and exactly one timeout discarded. A final
report shows the dash released everything it took, `melee` back to one reference after phase 3:

```
"dash":  { "group": "move",   "disabled": false, "refs": 1 }
"melee": { "group": "attack", "disabled": false, "refs": 1 }
```

## Gotchas verified on 4.7.2-rc

- **Two `class_name` scripts cannot reference each other's type**. Typing
  `Behaviour.container` as `BehaviourContainer` while the container's `add()` assigns `self` into
  it fails to compile: `Value of type "gdscript://..." cannot be assigned to a variable of type
  "BehaviourContainer"`. Type the back-reference as `Node` and keep the strong type on the
  forward direction only.
- **`editor reload` before `script validate` on any new `class_name` file**. Until the editor
  rescans, the validator compiles the source as an anonymous script and the file fails on its own
  type name.
- **A `report()` taken in the same frame a phase registered comes back empty** unless it rebuilds
  the order itself, because the sort runs in `_process`. Any read-back helper over a lazily sorted
  list needs that guard, or the first read after each phase change reports the previous state.
- **Commands issued from separate shells are seconds apart**. Phase 2's 3 s timeout fired between
  two hand-run CLI calls and carried the fight into phase 3 on its own, making the health trigger
  a no-op. Drive timing-sensitive sequences from one `test run-scenario` call, or accept that the
  clock beat the input.
- **`script lint` reads `x.group_id == group_id` as a self-comparison** when the loop variable
  shares the property's name. Rename the loop variable; the finding is worth taking even though
  the code was correct.

## Build order

1. `Stats` with `health_changed` and `damage()`. Everything else listens to it.
2. `Behaviour` and `BehaviourContainer`, with `report()` written at the same time. Every check
   in this doc reads through it.
3. One behaviour per group (`chase` in move, `melee` in attack) and a boss with a single-entry
   phase table. Play it, `report`, confirm the tick order.
4. `PhaseController` and the real table. Drive each trigger with `runtime call ... damage` and
   assert `phase_index`.
5. The exclusive move (dash, channel, leap) last, because group locking is the piece that breaks
   quietly. Read the report inside the lock window; after it releases, everything looks fine.
