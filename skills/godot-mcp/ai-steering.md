# Steering and agent movement — building with godot-mcp

How to move an AI character so it reads as a creature rather than a cursor. Read
`game-patterns.md` for scene composition and `gdscript-style.md` for language idioms.
**Verify signatures against the live engine** (`engine class-info --class CharacterBody2D`,
`engine class-info --class NavigationAgent2D`) — the patterns here are stable, the API is
what the running binary says it is.

## The one idea

Naive chase code assigns velocity:

```gdscript
velocity = global_position.direction_to(target) * speed   # snaps, orbits, jitters
```

Steering *accelerates toward* a desired velocity instead:

```gdscript
var steering := desired_velocity - velocity
velocity = (velocity + steering.limit_length(max_force) * delta).limit_length(max_speed)
```

Turn rate then falls out of `max_force`, and top speed out of `max_speed`. A heavy tank
gets a low force and a high speed; a wasp gets the reverse. That single substitution is
most of what separates convincing AI motion from the version that snaps to the player and
vibrates on arrival.

Two numbers per agent, both `@export`ed so they are tunable from the inspector:

- `max_speed` — how fast it may travel.
- `max_force` — how hard it may change direction. This is the feel dial.

## Steering vs NavigationAgent

They solve different problems and compose.

| Need | Use |
| --- | --- |
| Route around static level geometry | `NavigationAgent2D/3D` pathfinding |
| Smooth, weighty local motion | Hand-rolled steering (this doc) |
| Keep a crowd from stacking up | Separation (below), or agent avoidance |

The normal shape is both: ask the navigation agent for the next path point, then *steer*
toward it rather than assigning velocity straight at it. Pathfinding chooses the route,
steering decides how the body gets there.

## Build: a steering agent

Verified end to end on 4.7. Creates the scene, the body, and the script:

```
scene create --path res://ai/steer_demo.tscn --root-type Node2D --root-name SteerDemo
scene open --path res://ai/steer_demo.tscn
scene2d add-body --type CharacterBody2D --name Agent --shape circle --radius 12
scene2d add-body --type StaticBody2D --name Target --shape circle --radius 8 --position "Vector2(400, 200)"
script create --path res://ai/steering_agent.gd --extends CharacterBody2D
script attach --node-path Agent --script-path res://ai/steering_agent.gd
node set --node-path Agent --property target_path --value "../Target"
scene save
```

`--property target_path --value "../Target"` is not a typo. `get_node_or_null(target_path)`
resolves **relative to the node holding it**, so a sibling needs the `../`. Passing the bare
name silently yields null, `_physics_process` returns early, and the agent sits still with
no error anywhere — the exact failure this line exists to prevent.

The script (compiles clean, `script lint` reports zero findings):

```gdscript
class_name SteeringAgent2D
extends CharacterBody2D

@export var max_speed := 300.0
@export var max_force := 1200.0
@export var arrive_radius := 96.0
@export var target_path: NodePath

var _target: Node2D


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node2D


func _physics_process(delta: float) -> void:
	if _target == null:
		return
	var steering := arrive(_target.global_position).limit_length(max_force)
	velocity = (velocity + steering * delta).limit_length(max_speed)
	move_and_slide()
```

## The behaviours

Each returns a **steering force** (`desired - velocity`), never a velocity. That is what
lets them be summed.

### Arrive

Full speed toward the target, easing to a stop inside `arrive_radius`. Most chase,
escort, and patrol code ends up calling this one.

```gdscript
func arrive(target: Vector2) -> Vector2:
	var offset := target - global_position
	var distance := offset.length()
	if is_zero_approx(distance):
		return -velocity
	var speed := max_speed
	if distance < arrive_radius:
		speed = max_speed * distance / arrive_radius
	return offset / distance * speed - velocity
```

Seek is this without the taper. Seek overshoots the target, turns around, overshoots
again, and orbits forever — the classic "enemy vibrating on the player" bug. Reach for
arrive by default and only drop the taper when the agent should not slow down.

### Flee

```gdscript
func flee(threat: Vector2, panic_distance := 200.0) -> Vector2:
	var offset := global_position - threat
	var distance := offset.length()
	if is_zero_approx(distance) or distance > panic_distance:
		return Vector2.ZERO
	return offset / distance * max_speed - velocity
```

`panic_distance` is what stops every enemy on the map fleeing forever once the player
picks up the scary weapon.

### Pursue — lead the target

```gdscript
func pursue(target: Node2D, target_velocity: Vector2) -> Vector2:
	var lead := global_position.distance_to(target.global_position) / max_speed
	return arrive(target.global_position + target_velocity * lead)
```

Without the lead the chaser aims at where the target *was* and permanently tails anything
moving across its path. Scaling the lead by distance means a far-off interceptor predicts
further ahead, which is also what looks intelligent.

### Separation — keeps a crowd from stacking

```gdscript
func separation(radius := 80.0) -> Vector2:
	var push := Vector2.ZERO
	for other in get_tree().get_nodes_in_group("flock"):
		if other == self or not other is Node2D:
			continue
		var offset: Vector2 = global_position - other.global_position
		var distance := offset.length()
		if distance > radius or is_zero_approx(distance):
			continue
		push += offset / distance * (1.0 - distance / radius) * max_speed
	if push == Vector2.ZERO:
		return Vector2.ZERO
	return push - velocity
```

The `1.0 - distance / radius` term is the important part: a neighbour at arm's length
pushes gently, one that is overlapping pushes hard. A flat repulsion makes the crowd
twitch.

Build it (group membership is what the loop reads):

```
node set-groups --node-path F1 --groups '["flock"]'
```

## Blending

Sum the forces, weight them, clamp once at the end. Weights are the tuning surface:

```gdscript
func _physics_process(delta: float) -> void:
	var steering := seek(goal) + separation() * separation_weight
	velocity = (velocity + steering.limit_length(max_force) * delta).limit_length(max_speed)
	move_and_slide()
```

Clamp the **sum**, not each term, or the weights stop meaning anything. When two
behaviours conflict (flee-from-fire vs seek-objective) prefer priority — take
the first behaviour that returns a non-zero force — over blending, which averages the two
into walking straight into the fire.

## Facing

Movement direction and facing are separate. Turn toward travel rather than snapping:

```gdscript
if velocity.length_squared() > 1.0:
	rotation = lerp_angle(rotation, velocity.angle(), turn_speed * delta)
```

In 3D use `look_at` with an up vector, or `Basis.looking_at`, and interpolate with
`Quaternion.slerp` — assigning a basis every frame produces the same snap that assigning
velocity does.

## 3D

Identical maths on `Vector3` with `CharacterBody3D`. Two differences:

- Keep steering on the horizontal plane and let gravity own Y, or the agent will steer
  itself into the floor. Zero the Y component of the steering force before applying it.
- Seat spawns on real geometry with `spatial place-on` / `spatial raycast` rather than
  guessing heights, and read bounds back with `spatial bounds`.

## Crowd avoidance via NavigationAgent

Godot ships RVO avoidance on `NavigationAgent2D/3D`. The wiring:

```gdscript
@onready var _agent: NavigationAgent2D = $NavigationAgent2D


func _ready() -> void:
	_agent.velocity_computed.connect(_on_velocity_computed)


func _physics_process(_delta: float) -> void:
	_agent.set_velocity(global_position.direction_to(goal) * speed)


func _on_velocity_computed(safe_velocity: Vector2) -> void:
	velocity = safe_velocity
	move_and_slide()
```

`avoidance_enabled`, `radius`, `neighbor_distance`, `max_neighbors`, and the
`velocity_computed(safe_velocity)` signal all exist on 4.7 and the signal fires once per
physics frame. **Verify the returned `safe_velocity` numerically before building on it.**
In a two-agent head-on test here it came back `(0, 0)` on every frame in both headless and
windowed editors, with the agent registered on a valid map — so the wiring firing is not
evidence that avoidance is steering anything. Check with `runtime eval` and read the value:

```
runtime eval --code 'var a = get_tree().current_scene.get_node("A")
emit("safe=%s pos=%s" % [a.last_safe, a.global_position])'
```

Hand-rolled separation has no such dependency and is the dependable option when a crowd
just needs to not stack.

## Verify numerically, not by screenshot

A screenshot of a moving agent proves nothing. Play the scene and read the actual numbers:

```
scene play --mode res://ai/steer_demo.tscn
runtime get --node-path Agent --properties '["position","velocity"]'
```

What a correct arrive looks like, from a real run — agent starting at `(0, 0)`, target at
`(400, 200)`:

| Time | position | velocity |
| --- | --- | --- |
| ~2 s | `(124.4, 62.2)` | `(182.8, 91.4)` |
| ~6 s | `(420.0, 200.9)` | `(0.0, -18.2)` |

Two things to read off that. The heading is right — `124:62` is the same 2:1 ratio as
`400:200`. And it settles with velocity near zero instead of orbiting, which is the arrive
taper doing its job. The final `x` of 420 rather than 400 is the two collision radii
touching (12 + 8), not an error.

For separation, check pair distances rather than positions. Three agents all seeking
`(0, 0)` from overlapping starts settled at `56.0`, `57.0`, and `57.7` units apart — a
stable triangle, which is the equilibrium between seek pulling in and separation pushing
out. All three converging on one number is the signal that it works; a collapsing set
means `separation_weight` is too low.

## Pitfalls

- **A sibling `NodePath` needs `../`**. Silent null, no error, agent never moves.
- **Steer in `_physics_process`, not `_process`**. `move_and_slide` is physics-frame work.
- **Clamp the summed force, not each behaviour**, or blending weights do nothing.
- **`max_force` too high erases the effect** — it becomes velocity assignment again with
  extra steps. If motion looks snappy, lower it before adding more behaviours.
- **Separation over a whole-tree group scan is O(n²)**. Fine for a squad; for hundreds,
  bucket by grid cell or use an `Area2D` neighbour list.
- **`get_nodes_in_group` returns freed nodes' peers mid-frame**. Guard with
  `is_instance_valid(other)` when agents die during iteration.
