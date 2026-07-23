# 2D platformer construction — the component-actor way

How to assemble a 2D platformer character, its animation, and its level the Godot way:
composition over inheritance, physics as the single source of truth, and almost no glue code.
Distilled from a studied production demo and verified live. Jump *feel* (coyote
time, buffering, midair jump) lives in `game-patterns.md`; this file is the architecture.

## The actor is a composition, not a class hierarchy

Don't subclass `CharacterBody2D` into a god-object player. The actor root is a plain `Node2D`
whose children each own one job; the physics body is just one component among peers:

```
Actor2D (Node2D — tiny script, wiring only)
├── KeyboardController (Node — input → intent calls on the body)
├── JoyController (Node — same intents from a different device)
├── MovingCharacter2D (CharacterBody2D — physics, intent API, predicates)
│   ├── CollisionShape2D
│   ├── GraphicsRemoteTransform2D   → ../Graphics
│   └── CameraRemoteTransform2D     → the level's camera (rotation/scale updates OFF)
├── Graphics (Node2D — sprites; follows the body, never leads it)
├── AnimationPlayer + AnimationTree (reads the body's predicates)
└── InteractionArea2D (Area2D beacon; follows via its own RemoteTransform2D)
```

Why: controllers swap without touching physics (keyboard/gamepad/AI/replay are siblings, not
subclasses); graphics can lag, squash, or flip without moving colliders; the body scene is a
reusable system you instance into any actor. **Physics leads, everything else follows** — the
one-way `RemoteTransform2D` links make that structural, not a convention someone must remember.

## The body: intent API + query predicates

The body script exposes *intents* (what a controller may ask) and *predicates* (what observers
may read). Controllers never write velocity; animation never reads input:

```gdscript
class_name MovingCharacter2D
extends CharacterBody2D
signal look_direction_changed(new_vector: Vector2)
@export var speed := 500.0
@export var gravity := 2000.0
@export var jump_strength := 800.0
var look_direction := 0:
    set(value):
        look_direction = value
        if look_direction != 0:
            look_direction_changed.emit(Vector2(look_direction, 1.0))

func _physics_process(delta: float) -> void:
    velocity.y += gravity * delta
    velocity.x = look_direction * speed      # snappy; blend via move_toward for weight
    move_and_slide()

func jump() -> void:
    if is_on_floor(): velocity.y = -jump_strength
func cancel_jump() -> void:                  # jump cutoff, as an intent
    if is_jumping(): velocity.y *= 0.4
func is_falling() -> bool: return velocity.y > 0.0 and not is_on_floor()
func is_jumping() -> bool: return velocity.y < 0.0 and not is_on_floor()
func is_running() -> bool: return look_direction != 0
```

Tune the body scene itself: `node set --node-path Player --properties
'{"floor_constant_speed":true,"floor_snap_length":16.0}'` (constant speed on slopes; snap keeps
`is_on_floor()` true over slope crests and platform seams). Flip facing with a signal, not code:
`node connect --node-path Player --signal look_direction_changed --target-path Graphics --method set_scale`
— emitting `Vector2(-1, 1)` mirrors the whole rig.

## Physics drives the AnimationTree — no glue code

The payoff of the predicate API: state-machine transitions advance **themselves** by evaluating
expressions against the body every frame. No `travel()` calls, no animation code anywhere.

**Build** (verified live; states `idle`/`fall` over an existing `Anims` AnimationPlayer):
```
anim-tree create --node-path . --anim-player Anims --name Tree
anim-tree add-state --node-path Tree --state-name idle --animation idle
anim-tree add-state --node-path Tree --state-name fall --animation fall
anim-tree add-transition --node-path Tree --from-state Start --to-state idle --advance-mode auto
anim-tree add-transition --node-path Tree --from-state idle --to-state fall \
    --advance-mode auto --advance-expression 'not get_node("Player").is_on_floor()' --xfade-time 0.1
anim-tree add-transition --node-path Tree --from-state fall --to-state idle \
    --advance-mode auto --advance-expression 'get_node("Player").is_on_floor()' --xfade-time 0.1
node set --node-path Tree --properties '{"advance_expression_base_node":"..","active":true}'
```
`advance_expression_base_node` is where `get_node()` resolves from — point it at the actor root.
Full graph for a platformer: idle ⇄ run (`is_running()`), any-ground → jump (`is_jumping()`,
switch-mode `at_end` off looping states), jump → fall (`is_falling()`), fall → idle/run on
`is_on_floor()`. Verify in-game, numerically:
`runtime eval --code 'emit(get_tree().current_scene.get_node("Tree").get("parameters/playback").get_current_node())'`.

## Moving platforms with zero code

`AnimatableBody2D` (not Rigid, not Static) carries riders correctly. Drive it by animating a
`PathFollow2D`'s `progress_ratio` and mirroring through `RemoteTransform2D`:

```
Path2D (the route, any Curve2D shape)
├── PathFollowPlatform2D (rotates=false)
│   └── RemoteTransform2D            → ../MovingPlatform2D
├── MovingPlatform2D (AnimatableBody2D, layer 2)
│   ├── CollisionPolygon2D (one_way_collision = true)
│   └── Polygon2D (visual)
└── AnimationPlayer (keys progress_ratio 0→1; loop ping-pong, or linear for circuits)
```

**Build:** `node add --type Path2D` + `path2d`-style curve via `node set --properties
'{"curve": ...}'` or reuse a saved platform scene; `animation create --node-path AP --name idle
--length 2` then `animation add-track` / `set_keyframe` on `PathFollowPlatform2D:progress_ratio`
(`0.0` at t=0, `1.0` at t=2), `--autoplay`. Desync duplicates with one embedded line:
`speed_scale = randf_range(0.5, 1.0)` in a tiny `extends AnimationPlayer` script. The platform
never knows it's moving; the rider never knows it's on a platform.

## The camera belongs to the level

The level owns `Camera2D` (limits are level knowledge); the actor only *feeds* it, via a
`RemoteTransform2D` on the body with `update_rotation=false, update_scale=false`. Inject the
camera as an exported NodePath on the actor. Use built-in smoothing
(`position_smoothing_enabled`, `limit_smoothed`) — never hand-lerp.

Per-region framing: invisible Area2D **trip lines** (a `SegmentShape2D` across a doorway) that
rewrite `camera.limit_left/right/top/bottom` on `area_entered`, with `-1` meaning "leave as is".
Room-based cameras fall out of level layout, no camera manager.

## Collision layers are a contract — write it down

| layer | who | notes |
|---|---|---|
| 1 | world (tiles, slopes) | static geometry |
| 2 | platforms | one-way, moving |
| 4 | hazards/enemies | |
| 8 | player presence | body **and** its interaction beacon |

Player body: `layer 8, mask 1|2|4`. The interaction pair is deliberately asymmetric: the actor
carries a dumb **beacon** (`Area2D`, layer 8, `monitoring=false`), the world carries **sensors**
(`Area2D`, layer 0, mask 8, `monitorable=false`) that own the response. A sensor enables its
input handling only while overlapped (`set_process_unhandled_input` on enter/exit) — no global
"can I interact?" state. Set with `physics set-layers` or `node set` on `collision_layer`/`collision_mask`.

## Blockout the level as scene tiles

Registering *prefab scenes* as tiles gives painted cells real collision, visuals, and behavior —
the fastest greybox that still plays. **Build** (verified live):
```
tilemap create --parent-path . --name Ground --tile-size 'Vector2(128,128)'
tilemap add-scenes-source --node-path Ground --scenes '["res://tiles/floor.tscn","res://tiles/slope.tscn"]'
tilemap fill-rect --node-path Ground --x1 0 --y1 5 --x2 24 --y2 6 --source-id 0 --alternative 1
```
Each prefab is a 1-cell scene (visual polygon + `StaticBody2D` collision) centered on the origin.
For texture tiles instead: `tilemap add-atlas-source --node-path Ground --texture <png>
--tile-size 'Vector2(256,256)'` (tiles auto-created for the whole grid) and paint with
`--atlas-x/--atlas-y`. Check what a layer holds with `tilemap get-info`.

## Teach in the world, not in menus

Tutorial prompts are level objects: an `Area2D` sensor + `RichTextLabel` that pops when entered.
Two details worth stealing: the label text holds an `{input}` placeholder replaced at runtime
with a keyboard or gamepad glyph depending on `Input.get_connected_joypads()` (store both glyph
paths as node metadata via `node set-meta`); and the dismiss animation is the pop animation
*played backwards* (`play_mode` backward on a second state), so one clip serves both. Even this
UI runs on expression-driven transitions (`get_overlapping_areas().size() > 0`) — the same
pattern as the character, applied to presentation. See `in-game-docs.md` for the 3D equivalents.

## Checklist

- Actor root is a `Node2D`; body, controllers, graphics, interaction are sibling components.
- Controllers call intents; animation reads predicates; nobody else touches `velocity`.
- AnimationTree transitions are `--advance-mode auto` + expressions; `advance_expression_base_node` set.
- Graphics/camera/interaction follow the body via `RemoteTransform2D`, never the reverse.
- Platforms are `AnimatableBody2D` on an animated `PathFollow2D`; one-way collision on.
- Camera lives in the level; limits change via trip-line areas.
- Collision layers documented as a table in the project; beacons don't monitor, sensors aren't monitorable.
- Blockout painted as scene tiles; `scene save` after; verify state live with `runtime eval`.
