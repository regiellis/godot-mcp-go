# 3D character controllers (Godot 4.7+) — FPS, third-person, platformer

How to build a `CharacterBody3D` controller the Godot way, driven from godot-mcp: one
movement core shared by all three genres, then the rig and feel that make each distinct.
Verified live against 4.7.1. Jump-*feel* timers (coyote, buffer, double, cutoff) are the 2D
ones from `game-patterns.md`/`platformer-2d.md` with the vertical sign flipped — this doc
reuses them, it does not re-derive them. Read `spatial` discipline in `SKILL.md` before
placing anything: seat the body with a raycast, verify numerically, don't eyeball one frame.

## Input actions first (never raw keys)

Define the move/jump/interact actions before any movement code, so remapping and gamepads
work and playtesting can drive `input action` (SKILL's rule: actions, not raw keys). One call
per action (`move_back`/`_left`/`_right`, `jump`→`KEY_SPACE`, `interact`→`KEY_E` likewise):
```
input_map set-action --action move_forward --events '[{"type":"key","keycode":"KEY_W"}]'
```
`Input.get_vector("move_left","move_right","move_forward","move_back")` returns the normalized
planar intent; `move_back` maps to `+y`, which becomes `+Z` (backward) below. `input_map`
writes `project.godot` — revert throwaway actions after tests.

## The body: CharacterBody3D + a capsule

The scene root *is* the body; add the collider under it (a `CharacterBody3D` root plus a child
`CollisionShape3D` — not a nested second body):
```
scene create --path res://actors/player.tscn --root-type CharacterBody3D --root-name Player
scene open --path res://actors/player.tscn
node add --type CollisionShape3D --name Col --parent-path .
node add-resource --node-path Col --property shape --resource-type CapsuleShape3D
```
The default `CapsuleShape3D` is `radius 0.5`, `height 2.0` — humanoid; resize by editing the
shape resource. `scene3d add-body --type CharacterBody3D --shape capsule --radius 0.4 --height
1.8` is the one-call form for dropping a *standalone* body into a level (it nests body + sized
shape under a parent), not for a root that is already the body.

**Why a capsule, not a box.** The rounded bottom slides over small ledges, floor seams, and step
edges that a box catches on, and its single curved side never snags on a wall corner mid-slide —
the standard collider for anything that walks. `height` is the *full* height including both caps;
the shape centers on the body origin, so raising `Col.position` to `y = height/2` puts the body
origin at the feet, convenient for `spatial place_on`.

**Two properties set the body's contract** (both verified on `CharacterBody3D`):
- `motion_mode` — `MOTION_MODE_GROUNDED` (`0`, default) gives you `is_on_floor()`, slopes,
  snapping, and stairs behavior: for anything that walks. `MOTION_MODE_FLOATING` (`1`) drops
  all floor logic — for swimmers, flyers, zero-g.
- `up_direction` — `Vector3.UP` by default; the axis `is_on_floor()`/floor angle measure
  against. Change it only for wall-walking or planet gravity.

## The movement core (shared by all three genres)

The canonical `_physics_process`. Read gravity from project settings (never hard-code `9.8`),
build a **camera-relative** direction, accelerate with `move_toward`, then `move_and_slide()`:
```gdscript
extends CharacterBody3D
@export var speed := 5.0
@export var accel := 60.0
@export var friction := 40.0
@export var jump_velocity := 5.0
@onready var _cam_yaw: Node3D = $CameraPivot          # FPS: use the body itself instead
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

func _physics_process(delta: float) -> void:
    if not is_on_floor():
        velocity.y -= _gravity * delta                 # +Y is up in 3D: gravity is negative
    if Input.is_action_just_pressed("jump") and is_on_floor():
        velocity.y = jump_velocity                      # positive = up
    var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var dir := _cam_yaw.global_transform.basis * Vector3(input.x, 0.0, input.y)
    dir.y = 0.0
    dir = dir.normalized()
    var target := dir * speed
    var rate := accel if dir != Vector3.ZERO else friction
    velocity.x = move_toward(velocity.x, target.x, rate * delta)
    velocity.z = move_toward(velocity.z, target.z, rate * delta)
    move_and_slide()
```
**The classic bug: forward is world `-Z`, not where the camera looks.** Feeding
`Vector3(input.x, 0, input.y)` straight into `velocity` makes "forward" always drive world `-Z`
no matter which way the player faces. Multiply the input by a **basis** to make it relative:
- **FPS** — the body yaws with the mouse, so use the body's own basis: `global_transform.basis
  * Vector3(input.x, 0, input.y)`. `dir.y = 0` before normalizing so looking up/down never
  changes ground speed.
- **Third-person** — the body does *not* yaw with the camera, so use the **camera pivot's**
  basis (`_cam_yaw` above). Movement follows the camera; the body turns to face it separately.

Keep `speed`/`accel`/`friction` as `@export`s (inspector data over hard-coded values). Instant
`velocity.x = dir.x * speed` feels robotic; `move_toward` gives weight — lower `accel` and higher
`friction` reads heavier.

## Floor behavior: slopes, snapping, stairs

Four `CharacterBody3D` properties (all verified) shape how the body meets the ground; set them
in `_ready()` or the inspector via `node set`:
- `floor_max_angle` (radians, default `deg_to_rad(45)`) — steeper than this counts as a wall,
  not walkable floor. `node set --node-path . --property floor_max_angle --value 0.8`.
- `floor_snap_length` (default `0.1`) — how far below the feet `move_and_slide` looks for floor
  to stick to. **Raise it (e.g. `0.5`) to walk *down* slopes and stairs without launching off
  the crest**; too small and the body ski-jumps every downhill. Snapping is skipped the frame
  you jump.
- `floor_stop_on_slope` (default `true`) — hold position on a slope with no input; off for ice.
- `floor_constant_speed` (default `false`) — keep ground speed constant up/down slopes (the slope
  otherwise steals horizontal speed); on for a snappy platformer.

**Stairs, honestly.** Vanilla `move_and_slide()` does **not** step up stairs. The capsule rolls
over lips smaller than its radius and a generous `floor_snap_length` keeps you glued going down,
but a real step taller than the capsule's curve stops the body dead. Two vanilla-only fixes:
model stairs as a ramp `StaticBody3D` under the visual steps (cheapest, most reliable), or add a
step-up pass — a shin-height forward `RayCast3D` that, on a hit with walkable floor just above,
nudges `global_position.y` up by the step height before `move_and_slide`. Don't claim built-in
stair-stepping the engine doesn't have.

## Moving platforms: velocity inheritance for free

`AnimatableBody3D` (the 3D twin of `platformer-2d.md`'s `AnimatableBody2D`: a kinematic body
driven by animation, `sync_to_physics = true`) carries riders correctly — `move_and_slide()`
reads the platform's motion and adds it to the body automatically, no code on the character. Two
`CharacterBody3D` knobs govern the hand-off:
- `platform_on_leave` — what happens to inherited velocity when you step off: `ADD_VELOCITY`
  (default; a moving floor flings you naturally), `ADD_UPWARD_VELOCITY`, or `DO_NOTHING`.
- `platform_floor_layers` — which collision layers count as velocity-inheriting floor.

**Build:** author the platform as its own scene, animate its `position` on an `AnimationPlayer`
(or a `PathFollow3D` + `RemoteTransform3D`, mirroring the 2D recipe), and instance it into the
level. Reading `velocity` off the Player while it rides confirms the inheritance is live.

## FPS rig: head, camera, mouse-look, interaction ray

Tree: a `Head` `Node3D` at eye height owns pitch; the `Camera3D` and interaction `RayCast3D`
hang under it. The **body** yaws (whole capsule turns), the **head** pitches — never pitch the
body (see Common mistakes).
```
node add --type Node3D    --name Head --parent-path .
node set  --node-path Head --property position --value "Vector3(0,1.6,0)"
node add --type Camera3D  --name Camera3D --parent-path Head
node add --type RayCast3D --name InteractRay --parent-path Head/Camera3D
node set  --node-path Head/Camera3D/InteractRay --properties '{"target_position":"Vector3(0,0,-3)","enabled":true}'
```
```gdscript
@export var sensitivity := 0.003                    # exported: a settings menu writes it
@onready var _head: Node3D = $Head
@onready var _ray: RayCast3D = $Head/Camera3D/InteractRay

func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED    # hide + lock the cursor to the window

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        var mm := event as InputEventMouseMotion
        rotate_y(-mm.relative.x * sensitivity)                     # yaw the body
        _head.rotate_x(-mm.relative.y * sensitivity)              # pitch the head
        _head.rotation.x = clampf(_head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))
    if event.is_action_pressed("ui_cancel"):
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE               # release for menus

func interact() -> void:                            # called on the "interact" action
    if _ray.is_colliding():
        var hit := _ray.get_collider()
        if hit and hit.has_method(&"use"):
            hit.call(&"use")
```
`InputEventMouseMotion.relative` is the per-frame delta. Clamp pitch to just under ±90° so the
view never flips. Expose `sensitivity` and an invert-Y toggle as `@export`s bound from a settings
screen (`menus-settings.md`). The `RayCast3D` casts along its local `-Z` toward `target_position`;
`get_collider()` returns the hit node — a duck-typed `use()` keeps the door/lever/pickup
decoupled from the player.

## Third-person rig: pivot, SpringArm3D, face-the-movement

Tree: a `CameraPivot` `Node3D` at the shoulder (this is the `_cam_yaw` the movement core reads),
a `SpringArm3D` under it, the `Camera3D` under the arm, and a separate `Skin` `Node3D` for the
visible mesh so the body collider never rotates with the model.
```
node add --type Node3D     --name CameraPivot --parent-path .
node set  --node-path CameraPivot --property position --value "Vector3(0,1.5,0)"
node add --type SpringArm3D --name SpringArm --parent-path CameraPivot
node add --type Camera3D    --name Camera3D  --parent-path CameraPivot/SpringArm
node add --type Node3D      --name Skin      --parent-path .
```
`game-patterns.md` owns the **SpringArm3D** mechanics — it raycasts back from the pivot and
shortens when geometry intrudes so the camera never clips walls; set `spring_length` (rest
distance), `margin` (pad the hit), and `add_excluded_object` (a collider **RID**) so the arm
ignores the player. Don't re-teach it; wire it:
```
node set --node-path CameraPivot/SpringArm --properties '{"spring_length":4.0,"margin":0.2}'
```
Exclude the player in `_ready()` with `_spring.add_excluded_object(get_rid())` — the body's own
physics RID, from `CollisionObject3D.get_rid()` (or drop the player's layer from
`SpringArm3D.collision_mask`).

**Mouse orbits the pivot; the character turns to face where it moves** (not where the camera
looks). Movement is camera-relative via the pivot basis (movement core, third-person branch);
the skin lerps its yaw toward the velocity heading:
```gdscript
@onready var _pivot: Node3D = $CameraPivot
@onready var _skin: Node3D = $Skin
@export var turn_speed := 12.0

func _unhandled_input(event: InputEvent) -> void:                 # orbit the pivot
    if event is InputEventMouseMotion:
        _pivot.rotate_y(-(event as InputEventMouseMotion).relative.x * 0.005)

func _physics_process(delta: float) -> void:
    # ... movement core using _pivot.global_transform.basis, then move_and_slide() ...
    var planar := Vector3(velocity.x, 0.0, velocity.z)
    if planar.length() > 0.1:
        var target_yaw := atan2(-planar.x, -planar.z)             # -Z is the model's forward
        _skin.rotation.y = lerp_angle(_skin.rotation.y, target_yaw, turn_speed * delta)
```
The `atan2(-x, -z)` maps a velocity heading to the yaw that points the model's `-Z` down it;
`lerp_angle` eases the turn and wraps correctly across ±π. Alternative:
`_skin.basis = _skin.basis.slerp(Basis.looking_at(planar, Vector3.UP), turn_speed * delta)` (both
verified to compile).

## 3D platformer feel

The forgiving-jump timers are identical to the 2D versions in `game-patterns.md` (coyote time,
jump buffer) and its double-jump / variable-height blocks — **only the sign flips**: 3D up is
`+Y`, so the jump sets `velocity.y = +jump_velocity` and the cutoff fires while `velocity.y >
0.0` (rising), the mirror of 2D's negative-Y up. One `_physics_process`, all four layers:
```gdscript
@export var jump_velocity := 5.0
@export var coyote_time := 0.1
@export var jump_buffer := 0.1
@export var max_air_jumps := 1
var _coyote := 0.0
var _buffered := 0.0
var _air_jumps := 0

func _physics_process(delta: float) -> void:
    if not is_on_floor():
        velocity.y -= _gravity * delta
    _coyote = coyote_time if is_on_floor() else _coyote - delta   # grace after leaving a ledge
    _buffered -= delta
    if Input.is_action_just_pressed("jump"):
        _buffered = jump_buffer                                    # queue a slightly-early press
    if is_on_floor():
        _air_jumps = max_air_jumps                                 # refill on landing
    if _buffered > 0.0 and _coyote > 0.0:
        velocity.y = jump_velocity
        _buffered = 0.0; _coyote = 0.0
    elif Input.is_action_just_pressed("jump") and _air_jumps > 0:
        velocity.y = jump_velocity * 0.85                          # double jump: a touch weaker
        _air_jumps -= 1
    if Input.is_action_just_released("jump") and velocity.y > 0.0:
        velocity.y *= 0.4                                          # variable height: cut the rise
    # ... horizontal move + move_and_slide() ...
```
Layering reads the same as 2D: cutoff shapes the arc, the midair jump rescues it, coyote makes
the first jump reliable, the buffer keeps land→jump chains consistent. Fire a **landing squash**
on the touchdown edge (`was_airborne and is_on_floor()`) — a `pop(1.2, 0.8)` tween on the `Skin`,
per the juice grammar in `game-patterns.md` / `ui-polish-2d.md`. That is juice, not control —
keep it out of the physics.

## Verify by driving (the payoff)

Prove the controller works by reading state back, not by one screenshot (SKILL's playtest
loop). Arm any signal *before* awaiting it:
```
scene play --mode main
runtime tree                                                        # confirm the rig is live
runtime get --node-path Player --properties '["position","velocity"]'   # baseline
input action --action move_forward --pressed true
runtime capture-frames --count 10 --frame-interval 2                # let it move
runtime get --node-path Player --properties '["position","velocity"]'   # position advanced, velocity.z < 0?
input action --action move_forward --pressed false
input action --action jump --pressed true
runtime await-signal --node-path Player --signal landed --timeout 3    # if you emit one on touchdown
runtime get --node-path Player --properties '["velocity"]'          # velocity.y crossed +→−?
runtime eval --code 'emit(get_tree().current_scene.get_node("Player").is_on_floor())'
runtime screenshot --save-path user://char3d.png                    # visual sanity (works headless)
scene stop
```
Input is fire-and-forget (`sent:true` ≠ applied) — every claim ("it moved", "it jumped", "it's
grounded") is confirmed by a `runtime get`/`eval` read, never by the input's own success.
Camera-relative movement is only proven by yawing the camera, then checking `move_forward`
changes the world-space heading of `velocity`.

## Common mistakes

- **World-basis forward.** Raw input into `velocity` ignores facing — multiply by the body basis
  (FPS) or camera-pivot basis (third-person). The most common 3D-controller bug.
- **Pitching the whole body.** Pitch the *head* `Node3D`, yaw the body — never `rotate_x` the
  `CharacterBody3D`, which tilts the collider and gimbals the character.
- **Gravity in `_process`.** All movement goes in `_physics_process` with `delta`; `_process` is
  frame-rate-dependent and desyncs from collision.
- **Mouse not captured.** Without `MOUSE_MODE_CAPTURED` the cursor leaves the window and
  mouse-look dies at the edge; restore `MOUSE_MODE_VISIBLE` for menus.
- **SpringArm colliding with the player.** The arm raycasts into the player's own capsule and
  slams the camera to the face — `add_excluded_object(get_rid())` (the body's RID) or drop its layer.
- **`floor_snap_length` too small.** The body launches off every downhill and stair crest; raise
  it until walking down is glued.
- **Hard-coded `9.8`** instead of reading `physics/3d/default_gravity`.
- **Remembered signatures.** Confirm properties/methods against the running engine (`engine class-info`/`search`)
  before writing — CharacterBody3D's floor API evolved across 4.x.
