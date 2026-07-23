# Godot game patterns (4.7) — building with godot-mcp

How to build games the Godot way, mapped to the CLI. Read `gdscript-style.md` for
language idioms. **Verify exact APIs against the live engine** (`engine class-info
--class CharacterBody2D`, `engine search --query <thing>`) — patterns below are stable,
signatures evolve.

## Principles

- **Compose, don't centralize.** One small scene per entity/UI piece, instanced into
  levels (`scene.instance`). Build capability from child nodes, behavior from focused
  scripts. (See SKILL.md "Build with composition, not monoliths".)
- **Components.** Recurring behavior → its own small scene + script (`HealthComponent`,
  `HurtboxComponent`), instanced wherever needed. Components expose signals; the owner wires them.
- **Data-driven.** Stats/items/config as `Resource` types (`.tres`), not hard-coded.
- **Decouple with signals.** Emitter announces; listeners react. No per-frame polling
  of other nodes, no reaching across the tree with `get_node` chains.
- **Separate** data (Resources) / logic (scripts on the owning node) / presentation
  (Sprite, AnimationPlayer, UI). Don't put all three in one script.

## Recommended build order for a new game

1. `project info`; set viewport/window via `project set-setting`.
2. **Input map first** — `input_map set-action` for every action (`move_left`, `jump`, …).
3. **Player scene** — its own `.tscn`, movement script, collision.
4. **One level scene** — instance the player, build the world (TileMapLayer / 3D meshes).
5. **Core loop** — enemies, pickups, win/lose, via component scenes.
6. **UI/HUD** — Control nodes bound to gameplay by signals.
7. **Playtest** — `scene play` → `input.*` → `runtime.get`/`screenshot` → fix → repeat.
8. **Polish** — animation, particles, audio, juice (tweens).

## Top-down movement (CharacterBody2D)

```gdscript
extends CharacterBody2D
@export var speed: float = 300.0

func _physics_process(_delta: float) -> void:
    var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    velocity = dir * speed
    move_and_slide()
```
Build it:
```
scene create --path res://entities/player.tscn --root-type CharacterBody2D --root-name Player
scene open --path res://entities/player.tscn
node add --type Sprite2D --name Sprite --parent-path .
node add --type CollisionShape2D --name Col --parent-path .
node add-resource --node-path Col --property shape --resource-type CircleShape2D
script create --path res://entities/player.gd --extends CharacterBody2D
script attach --node-path . --script-path res://entities/player.gd
scene save
```
(Define `move_left/right/up/down` via `input_map set-action` first; `Input.get_vector`
returns a normalized direction.)

## Platformer movement

```gdscript
extends CharacterBody2D
@export var speed := 250.0
@export var jump_velocity := -400.0
var gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity")

func _physics_process(delta: float) -> void:
    if not is_on_floor():
        velocity.y += gravity * delta
    if Input.is_action_just_pressed("jump") and is_on_floor():
        velocity.y = jump_velocity
    velocity.x = Input.get_axis("move_left", "move_right") * speed
    move_and_slide()
```

For how the platformer *actor and level* are assembled — component actor, physics-driven
`AnimationTree`, moving platforms, cameras, collision layers, scene-tile blockouts — read
`platformer-2d.md`; this file owns the movement code and its feel.

## Game feel vs juice — two different layers

**They are not the same thing, and they live in different code.** Conflating them is the common
mistake.

- **Game feel** is the quality of *control* — the input→avatar loop: responsiveness, weight,
  momentum, camera. It lives in the **movement/simulation code**. Strip every visual effect and
  it's still there (or still missing); you tune it with physics constants and input handling.
- **Juice** is the *feedback* layer — the avatar→audiovisual reaction fired on events to make an
  action satisfying and legible. It lives in the **presentation layer** (tweens, particles,
  signals→effects). Remove all of it and the mechanics are unchanged.

One feels good in the **hands**, the other reads well to the **eyes/ears**. Build **game feel
first** (it's core mechanics — belongs in the designer greybox); add **juice second** (cheap,
works on grey cubes — for a stakeholder prototype). See `level-design.md` "Presentation stages".

**Tier it Big → Medium → Small** (risk order): **Big feel** = movement, jump, camera, combat — get
these right first; if they feel bad nothing else matters. **Medium feel** = landing effects, hit
reactions, camera shake, recoil. **Small feel** = dust, sparks, shell casings, UI flourishes. Big
feel is mostly *game feel* (control); Medium/Small are mostly *juice*. (See `level-design.md`
"Big → Medium → Small".)

### Game feel — make the control feel good (movement code)

Augment the platformer above; all verified against 4.7.

**Weight via acceleration** (instant velocity feels robotic):
```gdscript
const ACCEL := 1800.0
const FRICTION := 2200.0
func _physics_process(delta: float) -> void:
    var dir := Input.get_axis("move_left", "move_right")
    var rate := ACCEL if dir != 0.0 else FRICTION
    velocity.x = move_toward(velocity.x, dir * speed, rate * delta)
    # ... gravity + move_and_slide()
```

**Coyote time + jump buffer + variable height** (forgiving, responsive jumps):
```gdscript
@export var coyote_time := 0.1
@export var jump_buffer := 0.1
var _coyote := 0.0
var _buffered := 0.0

func _physics_process(delta: float) -> void:
    _coyote = coyote_time if is_on_floor() else _coyote - delta
    _buffered -= delta
    if Input.is_action_just_pressed("jump"):
        _buffered = jump_buffer
    if _buffered > 0.0 and _coyote > 0.0:           # buffered press + recently grounded
        velocity.y = jump_velocity
        _buffered = 0.0
        _coyote = 0.0
    if Input.is_action_just_released("jump") and velocity.y < 0.0:
        velocity.y *= 0.4                            # variable height: cut the rise short
```

**Midair (double) jump** (aerial correction — consumes a charge, refilled on landing):
```gdscript
@export var max_air_jumps := 1
@export var air_jump_velocity := -340.0   # weaker than the ground jump keeps commitment
var _air_jumps := 0

# inside _physics_process, after the coyote/buffer ground jump:
    if is_on_floor():
        _air_jumps = max_air_jumps
    elif Input.is_action_just_pressed("jump") and _air_jumps > 0:
        velocity.y = air_jump_velocity
        _air_jumps -= 1
```
Layering: **cutoff shapes** the arc (micro), the **midair jump rescues** it (macro), coyote time
makes the *first* jump reliable so the second stays a deliberate tool, and the buffer keeps fast
land→jump→air-jump chains consistent. To preserve high-stakes jumps, constrain it: lower
`air_jump_velocity`, one charge, or gate it as a progression unlock (flip `max_air_jumps` from a
pickup). Level design: midair jump enables **commit-vs-correct** patterns — gaps the first jump
almost clears, layered vertical routes, rescue ledges under hazards.

**Air control** (steering after takeoff — a second jump is only fair if you can aim it):
```gdscript
@export var air_accel := 1100.0           # < ground ACCEL: drifty but steerable
var rate := (ACCEL if is_on_floor() else air_accel) if dir != 0.0 else FRICTION
```

**Asymmetric gravity** (snappier arc — float up, fall fast):
```gdscript
velocity.y += (fall_gravity if velocity.y > 0.0 else rise_gravity) * delta
```

**Camera that follows with weight** — built-in smoothing (don't hand-roll a lerp):
```
node add --type Camera2D --name Cam --parent-path .
node set --node-path Cam --properties '{"position_smoothing_enabled":true,"position_smoothing_speed":8.0}'
```
(`position_smoothing_speed` confirmed on `Camera2D`; for lookahead, offset the camera toward the
`velocity.x` direction.) Also game feel, not juice: read input every frame, snappy turnarounds,
sub-pixel movement, low latency. The 3D third-person equivalent is **`SpringArm3D`**: parent the
`Camera3D` to it and set `length` — the arm raycasts back from the pivot and shortens when
geometry intrudes, so the camera never clips walls (`margin` pads the hit;
`add_excluded_object` ignores the player's own collider).

### Juice — make the action satisfying (presentation, fired on events)

None of these need final art — they work on cubes/spheres. Fire them from gameplay **signals**.

**Squash & stretch** (the workhorse — jump, land, hit, collect):
```gdscript
func pop(sx: float, sy: float, t := 0.12) -> void:
    var tw := create_tween()
    tw.tween_property(sprite, "scale", Vector2(sx, sy), t * 0.4)
    tw.tween_property(sprite, "scale", Vector2.ONE, t * 0.6).set_trans(Tween.TRANS_BACK)
# jump: pop(0.7, 1.3)    land: pop(1.3, 0.7)
```

**Combat-VFX shader grammar** (from a shipped commercial deck-builder's 2D VFX library — the
system behind every impact/burst/ring effect, built on `GPUParticles2D` + `canvas_item` shaders):
- **Lifetime drives everything.** In the shader, `INSTANCE_CUSTOM.y / INSTANCE_CUSTOM.w` is the
  particle's 0→1 age; sample **authored 1D curve textures** at that value (`CurveTexture` for
  erosion threshold, flipbook frame, hue shift) instead of hardcoding math — artists tune curves,
  not code.
- **Grayscale + LUT.** Particle textures are grayscale masks; color comes from
  `texture(lut, mask.rr)` — one texture serves every palette, recolored per effect.
- **Erosion dissolve**: `smoothstep(threshold, threshold + softness, noise.r)` with the threshold
  read from the lifetime curve — the standard burn-away for smoke/impact sprites.
- **Flipbook UVs in-shader** (grid size + frame from lifetime, per-instance offset via
  `INSTANCE_CUSTOM.z` so instances desync).
- **Polar UV remap** (`radius, angle` from center, optional twist) turns any linear gradient into
  rings and radial shockwaves.
- **Screen distortion**: offset `hint_screen_texture` UVs along the direction to the sprite's
  center, masked by the particle texture, with intensity riding the particle's **color alpha** —
  the particle system animates the shader parameter for free. When a shader must read what was
  drawn *below it* mid-frame (refraction over a specific region, frosted panels), place a
  `BackBufferCopy` node above it in draw order — it snapshots the backbuffer (`copy_mode`
  rect or viewport) so `hint_screen_texture` reads are defined at that point.
- **CanvasGroup** renders its children as one image first: fade a whole multi-sprite character
  with a single `self_modulate` alpha (no per-part overlap artifacts), or run one outline/
  silhouette shader over the merged shape (pad `fit_margin` so the outline isn't clipped).

**Hit-stop** (freeze a few frames on impact — huge for perceived weight):
```gdscript
func hit_stop(seconds := 0.08) -> void:
    Engine.time_scale = 0.0
    # 4th arg ignore_time_scale=true so the timer still ticks while frozen (verified signature):
    await get_tree().create_timer(seconds, true, false, true).timeout
    Engine.time_scale = 1.0
```

**Screen shake** (on a `Camera2D`, decaying):
```gdscript
var _shake := 0.0
func add_shake(amount := 6.0) -> void: _shake = maxf(_shake, amount)
func _process(delta: float) -> void:
    offset = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))
    _shake = move_toward(_shake, 0.0, 40.0 * delta)
```

Others, same spirit: **particle burst** — a `GPUParticles2D` with `one_shot=true`, `emitting=true`
at the event, freed on finish. **Hit flash** — a shader that mixes albedo→white by a uniform you
tween 1→0 (plain `modulate` *multiplies*, so it can't turn a textured sprite uniformly white). **Screen flash** — a full-rect `ColorRect`
on a top `CanvasLayer`, alpha tweened down. **Floating text** — a `Label` that tweens up and fades.
**Sound on every action** — even a placeholder beep sells the feedback.

### A reusable stack (build once)

A `Juice` **autoload** exposing `hit_stop()`, `add_shake()`, `flash()`, `spawn_text()` so any scene
calls `Juice.hit_stop()` with no wiring; drive it from signals (`HealthComponent.died` → shake +
flash; `Coin.collected` → pop + particles + sound). Keep **game-feel constants as `@export`s** on
the entity so they tune in the inspector. See `gdscript-architecture.md` for the autoload-service
pattern and `level-design.md` for which layer to add when.

## Component pattern (health example)

A reusable `HealthComponent` scene (root `Node`, a script), instanced under any entity:

```gdscript
class_name HealthComponent
extends Node
signal health_changed(current: int, max_health: int)
signal died
@export var max_health: int = 10
var health: int

func _ready() -> void:
    health = max_health

func take_damage(amount: int) -> void:
    health = clampi(health - amount, 0, max_health)
    health_changed.emit(health, max_health)
    if health == 0:
        died.emit()
```
Instance it under the player/enemy (`scene.instance` or `node.add --type HealthComponent`
once it has a `class_name`), then wire `died` to a handler with `node.connect`. The HUD
connects to `health_changed`. Same idea for `HurtboxComponent` (an `Area2D` that detects a
`Hitbox` and calls `take_damage`).

## State machine

Simple AI/player states: enum + `match` in `_physics_process`.
```gdscript
enum State { IDLE, CHASE, ATTACK }
var state: State = State.IDLE

func _physics_process(delta: float) -> void:
    match state:
        State.IDLE:   _do_idle(delta)
        State.CHASE:  _do_chase(delta)
        State.ATTACK: _do_attack(delta)
```
Three enemy/encounter shapes worth keeping (from shipped-shooter devlogs): **onboarding aggro**
— intro enemies idle until provoked (proximity *or* first shot), giving new players a
low-pressure window; **boss phases gated by counts and thresholds, not timers** — "after the
turret fires 3 times, unlock the blast; below half HP, swap to ramming + homing" reads as
telegraphed escalation and survives pause/lag where timelines drift; **the charge ultimate** — hold N seconds to
charge, massive payoff (screen-wipe) at a real resource cost (1 HP), with one authored risk
knob: either damage interrupts the charge *or* charging grants invulnerability — never both.
Every number here is an `@export`.

For complex behavior, go node-based: a `StateMachine` node with a child `Node` per state;
the machine calls `enter()/update()/exit()` and switches `current` — full pattern with the
`transition` signal contract in `topdown-2d.md`. (Godot 4.7 also has `AnimationTree` state
machines for *animation* — use `anim_tree.*`; expression-driven recipe in `platformer-2d.md`.)

### Turn-based match loop + CPU personalities

For alternating-turn games (dice/card duels), the loop is a handful of flags, not a framework:
`_turn` ("player"/"cpu"), per-side `_done` flags recomputed from board state each pass
(`played >= cap or hand empty`), one `_busy` input lock, and a single `_advance_turn()` that
resolves when both sides are done. Give the CPU a **personality drawn per match** — an enum of
*picking strategies* over a shared `gain(piece)` function (greedy = max, balanced = median,
adaptive = smallest that retakes the lead else shed the lowest, gambler = random). Personality
decides *which* piece; the rolls stay pure luck — the CPU never rigs. Rank by **gain, not raw
value** (a strike is worth `min(strike, their_total)` — never fire a -6 at an empty board), and
estimate conservatively so the CPU holds its bombs. Gate narration on information: name the
leader only when the mode doesn't conceal totals. Full worked example in `ui-polish-2d.md`'s
source study; UI feel in that doc's juice grammar.

## Entity families: standardize the root, share the hurtbox

A war story that repeats across devlogs: enemies prototyped ad hoc end up with mixed roots
(`CharacterBody2D` here, `Area2D` there, `StaticBody2D` somewhere else) and suddenly damage is
inconsistent — some never register hits, some take double. Two rules prevent it:
- **One root type per family.** Everything that shares behavior ("takes damage") shares a root
  type and child layout, decided the moment the *second* variant exists. Prefer `Area2D` roots
  for enemies that don't need physics resolution — cheaper than `CharacterBody2D`.
- **One generic hurtbox scene** (an `Area2D` child) that only detects and forwards to the
  root's `take_damage()`; the root owns health. One shared script, not N per-enemy copies —
  the same hit/hurt/damage component split as `topdown-2d.md`.
Prototype fast and messy to find the fun, then run the consistency refactor once patterns
emerge — but *do* run it.

## Spawning & projectiles

A `Bullet` is its own scene; the shooter instances it at runtime and gives it velocity.
Don't pool prematurely: pooling pays off only at hundreds of concurrent projectiles — pool the
player's rapid-fire stream, not the boss's occasional volley. **Hitscan vs projectile is a feel
choice**: an instant raycast reads as "a real gun" (miniguns, rifles); a travelling node reads
as energy/arcing shots.

**Offscreen lifecycle** (APIs verified on 4.7): give every projectile/pickup a
`VisibleOnScreenNotifier2D` child and `queue_free()` on its `screen_exited` signal — the
standard leak-proof despawn, no manual bounds math. For persistent world objects that should
*sleep* offscreen (patrolling enemies, animated props), `VisibleOnScreenEnabler2D` pauses the
target's processing automatically (`enable_node_path`, mode inherit/always/when-paused) —
free culling, no code. The same pair exists as `VisibleOnScreenNotifier3D`/`Enabler3D`.

**Specialty 3D physics** (teach-level; all reachable via `node.add` + `node.set`, verified):
`VehicleBody3D` + one `VehicleWheel3D` per wheel is a complete arcade car — per wheel set
`use_as_traction`/`use_as_steering`, `wheel_radius`, suspension (`suspension_travel`,
`wheel_friction_slip`); drive by writing `engine_force`/`steering`/`brake` on the body each
frame. `SoftBody3D` turns a mesh into cloth/jelly — pin anchor vertices with
`set_point_pinned(i, true)`, raise `simulation_precision` before blaming the solver.
```gdscript
@export var bullet: PackedScene   # set in inspector to res://entities/bullet.tscn

func shoot(dir: Vector2) -> void:
    var b := bullet.instantiate()
    b.global_position = global_position
    b.velocity = dir * 600.0
    get_tree().current_scene.add_child(b)
```
The bullet `queue_free()`s on lifetime/collision. For many bullets, **pool** them (keep a
free-list, hide+reuse instead of instance/free each shot).

## Pickups & triggers (Area2D)

```gdscript
extends Area2D
signal collected
func _ready() -> void:
    body_entered.connect(_on_body_entered)
func _on_body_entered(body: Node) -> void:
    if body.is_in_group("player"):
        collected.emit()
        queue_free()
```
Build: `node add --type Area2D`, add a `CollisionShape2D` child with a shape. **Make the
shape generous** — tiny radii are nearly impossible to hit with simulated input.

## Input setup

Define actions once, drive by action (not raw keys) so remapping/controllers work:
```
input_map set-action --action jump --events '[{"type":"key","keycode":"KEY_SPACE"}]'
input_map set-action --action move_left --events '[{"type":"key","keycode":"KEY_A"}]'
```
Then in playtesting prefer `input action --action jump` over `input key`.

Mobile: `TouchScreenButton` (a 2D node, not a Control) fires an input-map `action` from a
screen region and can multi-press alongside other touches — set
`visibility_mode = TOUCHSCREEN_ONLY` so on-screen controls vanish on desktop. Because it maps
to actions, the same gameplay code serves both inputs.

## UI / HUD — signal-bound, never polling

`CanvasLayer` → `Control` nodes. The HUD listens to gameplay signals and updates; it does
not read player state every frame.
```gdscript
extends Control
@onready var bar: ProgressBar = %HealthBar
func bind(hp: HealthComponent) -> void:
    hp.health_changed.connect(func(cur, mx): bar.value = float(cur) / mx * 100.0)
```
Lay out with anchors (`node set-anchor --preset ...`), style with `theme.*`. For UI motion
that containers would otherwise stomp, Godot 4.7 has `offset_transform_*` on `Control`
(confirm with `engine class-info --class Control --filter offset_transform`).

## Groups for broadcast

```gdscript
add_to_group("enemies")            # in _ready
get_tree().call_group("enemies", "pause")
for e in get_tree().get_nodes_in_group("enemies"): ...
```
Manage via `node.set_groups` / `node.find_in_group`.

## Timers & cooldowns

- One-shot delay: `await get_tree().create_timer(0.5).timeout`.
- Repeating/inspectorable: a `Timer` node with `timeout` connected.
- Cooldown gate: `var _can_fire := true` flipped by a timer.

## Animation

- 2D frames / property tracks: `AnimationPlayer` (`animation.*`). Spritesheet characters:
  `scene2d add-animated-sprite --texture sheet.png --hframes 4 --vframes 4 --autoplay walk
  --animations '{"walk":{"frames":[0,1,2,3],"fps":8}}'` — one call builds the `SpriteFrames`
  (frame indices are row-major over the grid).
- Blending/state (idle↔run↔jump): `AnimationTree` + state machine (`anim_tree.*`).
- **Locomotion blend spaces** are the other `AnimationTree` tool. A **BlendSpace1D**
  interpolates poses along one axis — speed-based idle→walk→run; a **BlendSpace2D** blends
  across a plane — 8-way top-down locomotion, `blend_position` is the movement `Vector2`.
  Neighbouring clips cross-fade on their own; there are no per-clip transitions to author.
  - **Build a 2D 8-way blend as the tree root** — the `anim_tree` group authors blend spaces
    directly (`--root-type blend_space_2d` on `create`, then one `set-blend-point` per clip;
    every call verified live, `walk_*` clips already on an `AnimationPlayer`):
    ```
    anim-tree create --node-path . --anim-player AnimationPlayer --name Tree \
      --root-type blend_space_2d --sync true --min-space "Vector2(-1,-1)" --max-space "Vector2(1,1)"
    anim-tree set-blend-point --node-path Tree --animation idle       --pos-x 0  --pos-y 0
    anim-tree set-blend-point --node-path Tree --animation walk_right  --pos-x 1  --pos-y 0
    anim-tree set-blend-point --node-path Tree --animation walk_up     --pos-x 0  --pos-y -1
    # ...left / down / four diagonals; anim-tree get-structure --node-path Tree reads them back
    scene save
    ```
    `set-blend-point` wraps the named clip in an `AnimationNodeAnimation` at the blend-space
    position (2D: `--pos-x`/`--pos-y` or `--position "Vector2(x,y)"`; 1D: `--pos <float>`).
    `--sync true` sets the `AnimationNodeSync` flag both blend spaces carry — it locks the
    blended clips to one shared playback ratio so a slow walk and a fast run don't foot-slide;
    2D `--auto-triangles` (on by default) triangulates the points for you. The **1D** form is
    the same with `--root-type blend_space_1d` and float `--min-space`/`--max-space` (`0`→top
    speed). `remove-blend-point --index N` drops one. To nest the blend space inside a state
    machine instead of as the root, `add-state --state-type blend_space_2d --state-name
    Locomotion`, then target it with `set-blend-point --blend-space-state Locomotion`.
  - **Drive `blend_position` from velocity** in `_physics_process` — the one axis a blend space
    exposes as a runtime parameter:
    ```gdscript
    @onready var _tree: AnimationTree = $Tree
    func _physics_process(_delta: float) -> void:
        var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
        velocity = dir * speed
        move_and_slide()
        if dir != Vector2.ZERO:                            # hold last heading when stopped
            _tree.set("parameters/blend_position", dir)    # 2D: Vector2
        # 1D speed variant: _tree.set("parameters/blend_position", velocity.length())
    ```
    The path is `parameters/blend_position` when the blend space is the **tree root**. Nest it
    instead as a state named `Locomotion` in the state machine (so `jump`/`attack` still
    transition around it) and it becomes `parameters/Locomotion/blend_position`. Preview a pose
    at edit time with `anim-tree set-parameter --node-path Tree --parameter blend_position
    --value "Vector2(1,0)"`; confirm in-game with `runtime eval --code
    'emit(get_node("Tree").get("parameters/blend_position"))'`.
- **3D character motion stack** (4.7's `SkeletonModifier3D` family — children of the
  `Skeleton3D`, run after animation each frame; all `node.add` + `node.set`, APIs verified):
  `LookAtModifier3D` turns a bone toward a `target_node` (heads/eyes — set `bone_name` +
  `forward_axis`); `TwoBoneIK3D` plants limbs (indexed settings: `setting_count = 1`, then
  `set_target_node(0, …)` + `set_pole_node(0, …)` for the elbow/knee direction — one modifier
  can drive several limbs); `FABRIK3D`/`CCDIK3D`/`SplineIK3D` solve longer chains
  (tentacles, spines). **Secondary motion**: `SpringBoneSimulator3D` makes tails/hair/cloth
  bones lag and jiggle (`set_root_bone_name(0, …)`/`set_end_bone_name(0, …)` per chain), with
  `SpringBoneCollisionSphere3D/Capsule/Plane` children keeping them out of the body.
  **Ragdolls**: `PhysicalBoneSimulator3D` +  a `PhysicalBone3D` per major bone (generate via
  the editor's Skeleton3D toolbar, then tune shapes); flip live with
  `physical_bones_start_simulation()` / `stop` — death = animation off, simulation on.
  Modifier order matters: they apply top-to-bottom, so IK before spring bones.
- Cutout / skeletal 2D (verified live): `skeleton create-2d --bones '[{"name":"shoulder","position":[0,0]},{"name":"elbow","parent":"shoulder","position":[96,0]}]'` builds the `Bone2D` chain with rests; `skeleton skin-2d --node-path Rig --polygon-path Arm` auto-weights a `Polygon2D` by inverse distance (`--max-influences`, `--falloff`; explicit `--weights` per bone also accepted). Pose bones with plain `node.set` on `rotation_degrees`, bake a new bind pose with `set_rest_2d`, animate bone rotations with `animation.*` tracks. Chain-tip bones without children warn about length auto-calc — expected; set `length` if it matters.
- Juice (squash/stretch, punches, shake, hit-stop): built with tweens — see **Game feel vs
  juice** above. Distinct from game feel (the control itself).

## Positional audio (2D & 3D)

`AudioStreamPlayer` is flat (music, UI); **`AudioStreamPlayer2D` pans and attenuates by
distance to the listener** (the current `Camera2D`, or an `AudioListener2D`). The knobs that
matter (verified on 4.7): `max_distance` (beyond it, silent — default 2000px is small for
zoomed-out games), `attenuation` (falloff exponent), `panning_strength`, `bus` (route world
SFX to their own bus for the pause-menu duck — `audio.*` commands manage buses), and
`max_polyphony` (one player can voice N overlapping shots — no per-shot player nodes).
Positional audio is spatial *information*: an offscreen enemy you can hear approaching is
gameplay, not polish.

**3D** (`AudioStreamPlayer3D`) swaps the model: `attenuation_model` (inverse / inverse-square /
logarithmic / disabled) with `unit_size` scaling how fast falloff bites, `max_distance` as a
hard cutoff (0 = audible forever — set it, it's also a perf cull), and optional
`doppler_tracking` for fast movers. Same bus/polyphony discipline as 2D.

## Scene management

A `SceneManager` autoload that wraps `get_tree().change_scene_to_file("res://...")` (with
a fade) centralizes transitions. Register it with `project add-autoload`.

## Save / load

Small saves: a `Resource` or JSON written to `user://`. Resource approach: a `SaveData`
`class_name extends Resource`, `ResourceSaver.save(data, "user://save.tres")`.

## Networking — HTTP (leaderboards, telemetry)

`HTTPRequest` is a **node**, not a blocking call: add one, fire `request()`, react to the
`request_completed` signal. Signature (verified): `request_completed(result: int,
response_code: int, headers: PackedStringArray, body: PackedByteArray)`, and
`request(url, custom_headers, method, body)` returns an error you **must** check — a
malformed URL never reaches the socket, so the signal never fires. Wrap it in a thin autoload
with a **serial queue** (one request in flight); leaderboard posts and telemetry pings don't
need concurrency, and a queue makes ordering and retries trivial:

```gdscript
extends Node   # autoload "Net"
signal completed(tag: String, ok: bool, data: Variant)

var _http: HTTPRequest
var _queue: Array[Dictionary] = []
var _busy := false

func _ready() -> void:
    _http = HTTPRequest.new()
    _http.use_threads = true            # desktop: run the transfer off the main thread
    _http.timeout = 10.0                # give up after 10s instead of hanging forever
    add_child(_http)
    _http.request_completed.connect(_on_completed)

func post_json(url: String, payload: Dictionary, tag := "") -> void:
    _queue.push_back({"url": url, "body": JSON.stringify(payload), "tag": tag})
    _pump()

func _pump() -> void:
    if _busy or _queue.is_empty():
        return
    _busy = true
    var job: Dictionary = _queue.front()
    var headers := PackedStringArray(["Content-Type: application/json"])
    var err := _http.request(job["url"], headers, HTTPClient.METHOD_POST, job["body"])
    if err != OK:
        _finish(false, null)            # never left the socket — drain and move on

func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
    var data: Variant = null
    if ok:
        data = JSON.parse_string(body.get_string_from_utf8())   # null on malformed JSON — check it
    _finish(ok, data)

func _finish(ok: bool, data: Variant) -> void:
    var job: Dictionary = _queue.pop_front()
    _busy = false
    completed.emit(String(job.get("tag", "")), ok, data)
    _pump()                             # next in line
```

Build: `project add-autoload --name Net --path res://systems/net.gd`, then call
`Net.post_json("https://api.example.com/score", {"name": n, "score": s}, "leaderboard")`
and listen on `Net.completed`. **HTTPS just works on desktop** — Godot ships Mozilla's CA
bundle, so `https://` validates against system certs with no setup (`set_tls_options` is only
for certificate pinning or a private CA). `use_threads` keeps the transfer off the main
thread on desktop; on other platforms confirm threading before enabling it.

## Measuring performance (frame-delta, not a single readout)

A single FPS / frame-time sample is noisy and misleading. Measure over a **window** — count
frames advanced across a known interval and report an average *and* a worst frame — and be
explicit about **which world** you're sampling: the running game and the editor viewport behave
differently, and only the game's number matters for "does it run well."

**Build (sample the running game over a window):**
```
scene play --mode main
# capture_frames already advances N frames at a fixed interval — use it as the window:
runtime capture-frames --count 60 --frame-interval 1
# read engine timing from inside the game over that window:
runtime eval --code '
var fps = Engine.get_frames_per_second()
var draw = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_DRAW_CALLS_IN_FRAME)
var prims = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
emit({"fps": fps, "draw_calls": draw, "primitives": prims})'
scene stop
```
Sample several times and keep the **worst** frame, not just the mean — a stutter is what players
feel. The `profiling` group exposes deeper monitors; confirm exact names with `engine class-info
--class Performance` / `engine search --query RENDERING_INFO` against the live build before relying
on them (the constants evolve between 4.x releases). Don't trust the editor viewport's frame rate
as the game's.

## Common mistakes to avoid

- One giant scene + one 1000-line script. Split into entity scenes + components.
- Movement/physics in `_process` instead of `_physics_process`.
- Polling another node's state every frame instead of connecting a signal.
- `get_node("../../Thing")` chains — use `@export`/`%unique`/groups.
- Hard-coding values in `_ready()` that should be `@export`s.
- Untyped GDScript.
- Forgetting `delta` (frame-rate-dependent movement).
- Confusing **game feel** (the control) with **juice** (the feedback) — or shipping a prototype
  with neither. Game feel goes in the movement code; juice is fired on signals.
- Trusting remembered API signatures — confirm 4.7 with `engine class-info`/`search`.
