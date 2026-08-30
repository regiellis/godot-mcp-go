@tool
class_name JuiceTween
extends RefCounted

## Static tween helpers shared by every widget that wants an impact.
##
## Each helper records the node's resting value the first time it touches it and
## always returns there, so spamming a punch can never leave something parked at
## the wrong size. Each returns the [Tween] so a caller can chain or kill it, and
## returns null when the node is gone or [code]Juice[/code] has motion switched
## off, which callers must check before chaining.
##
## The split is always fast out, slow settle. An even in-and-out reads as a
## wobble rather than a hit.

const OVERSHOOT_LEG := 0.22 ## Fraction of the duration spent reaching the peak.
const SETTLE_LEG := 0.78 ## The remainder, spent easing elastically back to rest.

const META_REST_SCALE := &"_juice_rest_scale"
const META_REST_ROTATION := &"_juice_rest_rotation"
const META_REST_POSITION := &"_juice_rest_position"
const META_REST_MODULATE := &"_juice_rest_modulate"


static func punch_scale(
		node: CanvasItem, amount: float = 0.22, duration: float = 0.32
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: Vector2 = _rest(node, META_REST_SCALE, node.scale)
	_kill(node, &"scale")

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_scale", tween)
	tween.tween_property(node, ^"scale", rest * (1.0 + amount), duration * OVERSHOOT_LEG) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, ^"scale", rest, duration * SETTLE_LEG) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tween


## [param axis] picks which way the squash runs. Vector2.RIGHT widens and
## flattens, Vector2.UP does the opposite, anything between blends the two.
static func squash_stretch(
		node: CanvasItem,
		amount: float = 0.3,
		duration: float = 0.36,
		axis: Vector2 = Vector2.RIGHT
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: Vector2 = _rest(node, META_REST_SCALE, node.scale)
	_kill(node, &"scale")

	var along := absf(axis.normalized().x)
	var stretch := Vector2(
		lerpf(1.0 / (1.0 + amount), 1.0 + amount, along),
		lerpf(1.0 + amount, 1.0 / (1.0 + amount), along)
	)

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_scale", tween)
	tween.tween_property(node, ^"scale", rest * stretch, duration * OVERSHOOT_LEG) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, ^"scale", rest, duration * SETTLE_LEG) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tween


static func pop_in(
		node: CanvasItem, duration: float = Design.T_POP_IN, from: float = 0.0
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: Vector2 = _rest(node, META_REST_SCALE, node.scale)
	_kill(node, &"scale")

	node.scale = rest * from
	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_scale", tween)
	tween.tween_property(node, ^"scale", rest, duration) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween


## Runs even with motion switched off, because a caller passing
## [param free_when_done] is relying on the callback to clean the node up.
static func pop_out(
		node: CanvasItem, duration: float = Design.T_POP_OUT, free_when_done: bool = false
) -> Tween:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return null
	# Recorded even though nothing reads it here, so a later restore() knows
	# where this node was sitting before it shrank away.
	_rest(node, META_REST_SCALE, node.scale)
	_kill(node, &"scale")

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_scale", tween)
	tween.tween_property(node, ^"scale", Vector2.ZERO, duration) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	if free_when_done:
		tween.tween_callback(node.queue_free)
	return tween


static func rotate_punch(
		node: CanvasItem, angle_degrees: float = 8.0, duration: float = 0.4
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: float = _rest(node, META_REST_ROTATION, node.rotation)
	_kill(node, &"rotation")

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_rotation", tween)
	tween.tween_property(node, ^"rotation", rest + deg_to_rad(angle_degrees),
			duration * OVERSHOOT_LEG) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, ^"rotation", rest, duration * SETTLE_LEG) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tween


static func shake_position(
		node: CanvasItem, strength: float = 6.0, duration: float = 0.3
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: Vector2 = _rest(node, META_REST_POSITION, node.position)
	_kill(node, &"position")

	var step := func(t: float) -> void:
		if not is_instance_valid(node):
			return
		var falloff := 1.0 - t
		node.position = rest + Vector2(
			randf_range(-strength, strength),
			randf_range(-strength, strength)
		) * falloff

	var settle := func() -> void:
		if is_instance_valid(node):
			node.position = rest

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_position", tween)
	tween.tween_method(step, 0.0, 1.0, duration)
	tween.tween_callback(settle)
	return tween


static func flash_modulate(
		node: CanvasItem, colour: Color = Design.CREAM, duration: float = 0.12
) -> Tween:
	if not _can_juice(node):
		return null
	var rest: Color = _rest(node, META_REST_MODULATE, node.modulate)
	_kill(node, &"modulate")

	var tween := node.create_tween()
	node.set_meta(&"_juice_tween_modulate", tween)
	# In fast, out slow, so the flash lands on the frame it was asked for.
	tween.tween_property(node, ^"modulate", colour, duration * 0.3)
	tween.tween_property(node, ^"modulate", rest, duration * 0.7)
	return tween


## Kills everything this class started on [param node] and puts it back at rest.
static func restore(node: CanvasItem) -> void:
	if not is_instance_valid(node):
		return
	for key: StringName in [&"scale", &"rotation", &"position", &"modulate"]:
		_kill(node, key)
	if node.has_meta(META_REST_SCALE):
		node.scale = node.get_meta(META_REST_SCALE)
	if node.has_meta(META_REST_ROTATION):
		node.rotation = node.get_meta(META_REST_ROTATION)
	if node.has_meta(META_REST_POSITION):
		node.position = node.get_meta(META_REST_POSITION)
	if node.has_meta(META_REST_MODULATE):
		node.modulate = node.get_meta(META_REST_MODULATE)


static func centre_pivot(control: Control) -> void:
	if is_instance_valid(control):
		control.pivot_offset = control.size * 0.5


## Motion is allowed when the node is live and either Juice is absent or on.
## Looked up by path rather than by name: this script carries a class_name and
## can compile before the autoloads exist.
static func _can_juice(node: CanvasItem) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return false
	var juice := node.get_node_or_null(^"/root/Juice")
	if juice == null:
		return true
	return not ("enabled" in juice) or bool(juice.enabled)


static func _rest(node: CanvasItem, meta: StringName, fallback: Variant) -> Variant:
	if not node.has_meta(meta):
		node.set_meta(meta, fallback)
	return node.get_meta(meta)


static func _kill(node: CanvasItem, key: StringName) -> void:
	var meta := StringName("_juice_tween_" + key)
	if not node.has_meta(meta):
		return
	var previous: Tween = node.get_meta(meta)
	if is_instance_valid(previous) and previous.is_valid():
		previous.kill()
	node.remove_meta(meta)
