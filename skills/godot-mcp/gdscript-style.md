# GDScript style for games

How to write GDScript a competent Godot dev would ship. Patterns here are durable;
for any exact API/signature, confirm against the live engine with
`engine class-info --class <X>` / `engine search` rather than trusting memory.

## Check the style, don't eyeball it

Most of this page is machine-checkable. After writing or editing a script, run:

```
script lint --path res://path/to/file.gd
```

`script lint` returns structured findings (`path`, `line`, `rule`, `severity`, `message`)
against the official GDScript style guide, covering 17 rules — the 9 naming rules below at
severity `error`, the rest as warnings. It needs no external tool.

There is no auto-formatter. Write to the guide as you go and let the linter catch the
rest; the rules below are the whole contract.

Two things to know before trusting a clean result:

- **A clean lint is not a passing compile**. Style rules read source, so they still report
  on a file that doesn't parse — and zero findings there would read as fine. A single-file
  run reports `syntax_valid`; a directory run is style-only. `script validate` is the
  compile check.
- **`max-line-length` (default 100) is the noisy rule**. Silence it with
  `--disable max-line-length`, raise it with `--max-line-length`, or pass `0` to turn it
  off when a project deliberately runs long lines.

Suppress a single line in the source itself, which survives outside the tool:

```gdscript
# gdlint-ignore-next-line variable-name
var LegacyName := 1

var OtherName := 2  # gdlint-ignore variable-name
```

Indentation is **tabs**, per the official guide. The examples below use spaces for
readability in Markdown, so indent the real file with tabs rather than copying the spacing.

## Type everything

Static typing catches errors at parse time, runs faster, and gives the editor real
autocomplete. Untyped GDScript is a smell.

```gdscript
var speed: float = 300.0
var _targets: Array[Node] = []
@onready var sprite: Sprite2D = $Sprite2D

func take_damage(amount: int) -> void:
    health -= amount
```

- Annotate every `var`, parameter, and return type. Use `:=` for inferred locals
  (`var dir := Input.get_vector(...)` — already typed).
- Type your arrays: `Array[Vector2]`, `Array[Enemy]`.
- `-> void` on functions that return nothing.

## Naming

- `snake_case` — variables, functions, files (`player_controller.gd`), signals.
- `PascalCase` — `class_name`, node names in the tree, enum types.
- `CONSTANT_CASE` — `const MAX_SPEED := 600.0`, and enum *members*.
- `_leading_underscore` — private members and helpers (`_velocity`, `_update_ui()`).

Every one of these is enforced by `script lint`, as the rules `variable-name`,
`function-name`, `function-argument-name`, `loop-variable-name`, `signal-name`,
`class-name`, `enum-name`, `enum-member-name`, and `constant-name` — all severity
`error`, and `variable-name` covers locals, not just members. The remaining rules catch
real defects rather than naming: `duplicated-load`, `standalone-expression`,
`unnecessary-pass`, `unused-argument`, `comparison-with-itself`, `private-access`,
`no-else-return`, and `max-line-length`. Passing an unknown name to `--disable` returns
an error listing all seventeen.

One exception worth knowing: a `const` bound to `preload()`/`load()` accepts either case,
because both are idiomatic — PascalCase when it holds a script used as a type
(`const NodeUtils := preload(...)`, called as `NodeUtils.foo()`), CONSTANT_CASE when it
holds an asset (`const PLAYER_SCENE := preload(...)`).

## Node references — never `get_node("../../X")`

Brittle path chains break the moment the tree changes. In order of preference:

1. **Child of self:** `@onready var hp: HealthComponent = $HealthComponent`.
2. **Scene-unique name** (`%`): mark a node "Access as Unique Name" in the editor,
   then `@onready var bar: ProgressBar = %HealthBar` — survives reparenting.
3. **`@export` a reference:** `@export var target: Node2D` — wired in the inspector
   (and settable via `node.set --property target --value <NodePath>`). Best for
   cross-branch references.

## Expose data with `@export`

Anything a designer (or you, via `node.set`) should tweak belongs in the inspector,
not hard-coded in `_ready()`.

```gdscript
@export var speed: float = 300.0
@export_range(0.0, 1.0) var friction: float = 0.1
@export var projectile: PackedScene
@export_enum("Idle", "Patrol", "Chase") var start_state: int
```

This is why the tools prefer `node.set` over writing values in code — it keeps them
visible and editable.

## Lifecycle: pick the right callback

- `_ready()` — one-time setup after children exist.
- `_process(delta)` — per-frame visuals, non-physics input polling, UI.
- `_physics_process(delta)` — movement, physics, anything needing a fixed timestep.
  **Do movement here, not in `_process`.**
- `_unhandled_input(event)` — gameplay input that UI didn't consume.

Always scale motion by `delta` so it's frame-rate independent: `position += velocity * delta`
(or use `move_and_slide()`, which handles it).

## Signals over polling

When something *happens*, emit a signal; don't make other nodes check state every frame.
This decouples — the emitter doesn't know or care who listens.

```gdscript
signal health_changed(current: int, max: int)
signal died

func take_damage(amount: int) -> void:
    health = max(0, health - amount)
    health_changed.emit(health, max_health)
    if health == 0:
        died.emit()
```

The HUD connects to `health_changed`; the spawner connects to `died`. Wire connections
with `node.connect`. Prefer typed signal args.

## Data as Resources

For stats, items, configs — define a custom `Resource`, not a Dictionary or constants
buried in code. Designers edit `.tres` files; code stays generic.

```gdscript
class_name EnemyStats
extends Resource

@export var max_health: int = 10
@export var speed: float = 80.0
@export var damage: int = 1
```

Create instances with `resource.create --type EnemyStats`, assign with
`node.add_resource` / `node.set`.

## `class_name` and autoloads — sparingly

- Add `class_name Foo` when a type is reused across scenes or referenced by name
  (it registers globally — and makes the type discoverable via `engine.script_classes`).
- Autoloads (singletons) are for *true* globals: a `GameState`, an `AudioManager`, a
  `SceneLoader`. Don't reach for them to avoid passing references — that creates hidden
  coupling. Most state belongs in the scene that owns it.

## Control flow & misc

- Prefer `match` over long `if/elif` ladders (states, enums).
- `queue_free()` to remove a node, not `free()` (defers to end of frame, safe).
- Wait a frame/time with `await get_tree().process_frame` or
  `await get_tree().create_timer(0.5).timeout` — no busy loops.
- Guard external lookups: `if is_instance_valid(target):` before using a node that may
  have been freed.
- Don't allocate per-frame in hot paths (no `Array`/`Dictionary` churn in `_physics_process`).
