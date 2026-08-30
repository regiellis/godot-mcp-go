extends Node

## Screen shake, hitstop, and the small reusable tweens every widget reaches for.
##
## Autoload `Juice`. Runs on PROCESS_MODE_ALWAYS so a paused game still gets its
## overlay animations and so a hitstop can undo itself.

signal enabled_changed(is_enabled: bool)

## Trauma units shed per second. A 0.30 place-a-disc shake is gone in an eighth
## of a second, which is what keeps a fast game from rattling continuously.
const TRAUMA_DECAY := 2.4

## Resample rate for the shake offset. Sampling every frame reads as noise; 42 Hz
## keeps a visible step at any refresh rate.
const SHAKE_HZ := 42.0

const MAX_OFFSET := Vector2(18.0, 12.0)
const FLASH_LAYER := 130

## squash() carries no duration in its signature, so it pins one here.
const SQUASH_TIME := 0.6

var _enabled := true
var _cameras: Array[Camera2D] = []
var _trauma := 0.0
var _sample_clock := 0.0
var _offset := Vector2.ZERO
var _hitstop_token := 0
var _flash_layer: CanvasLayer = null
var _flash_rect: ColorRect = null
var _rng := RandomNumberGenerator.new()

## False when Settings game/juice is off, or a11y/reduced_motion is on. Turning
## it off silences what is already running, it does not only block new calls.
var enabled: bool:
	set(value):
		if value == _enabled:
			return
		_enabled = value
		if not _enabled:
			_silence()
		enabled_changed.emit(_enabled)
	get:
		return _enabled


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_build_flash()
	var settings := get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	_sync_from_settings(settings)
	settings.changed.connect(_on_settings_changed)


func _process(delta: float) -> void:
	if _trauma <= 0.0:
		return
	_trauma = maxf(_trauma - TRAUMA_DECAY * delta, 0.0)
	_sample_clock += delta
	var step := 1.0 / SHAKE_HZ
	while _sample_clock >= step:
		_sample_clock -= step
		# Squared trauma keeps a small shake subtle while a big one stays sharp.
		var amount := pow(_trauma, 2.0)
		_offset = Vector2(
			_rng.randf_range(-1.0, 1.0) * MAX_OFFSET.x,
			_rng.randf_range(-1.0, 1.0) * MAX_OFFSET.y
		) * amount
	if _trauma <= 0.0:
		_offset = Vector2.ZERO
	_push_offset()


## 0.15 for a UI beat, 0.30 for placing a disc, 0.55 for a big flip cascade.
func shake(amount: float = 0.3) -> void:
	if not _enabled:
		return
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## 0.03 light, 0.07 heavy. Past 0.20 it stops reading as impact and reads as a
## frozen game.
func hitstop(duration: float = 0.05) -> void:
	if not _enabled or duration <= 0.0:
		return
	_hitstop_token += 1
	var token := _hitstop_token
	Engine.time_scale = 0.0
	# ignore_time_scale, not just process_always: a SceneTreeTimer counts down in
	# scaled time, so at time_scale 0 an ordinary timer never fires and the game
	# never comes back.
	var timer := get_tree().create_timer(duration, true, false, true)
	await timer.timeout
	if token != _hitstop_token:
		return
	Engine.time_scale = 1.0


func punch(node: CanvasItem, amount: float = 0.22, duration: float = 0.32) -> void:
	if not _can_tween(node):
		return
	_prepare_pivot(node)
	var tween := node.create_tween()
	# Fast out, slow settle. An even in-and-out reads as a wobble, not an impact.
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", Vector2.ONE * (1.0 + amount), duration * 0.22)
	tween.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", Vector2.ONE, duration * 0.78)


func squash(node: CanvasItem, amount: float = 0.3, axis: Vector2 = Vector2.RIGHT) -> void:
	if not _can_tween(node):
		return
	_prepare_pivot(node)
	# Volume is conserved by eye: what the axis loses, the perpendicular gains.
	var along := axis.normalized().abs()
	var across := Vector2(along.y, along.x)
	var target := Vector2.ONE - along * amount + across * amount
	# Same 0.2 / 0.8 split as punch, over the 0.6s a squash reads best across.
	var tween := node.create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", target, SQUASH_TIME * 0.2)
	tween.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", Vector2.ONE, SQUASH_TIME * 0.8)


func pop_in(node: CanvasItem, duration: float = Design.T_POP_IN) -> void:
	if not _can_tween(node):
		return
	_prepare_pivot(node)
	_set_scale(node, Vector2.ONE * 0.01)
	node.modulate.a = 0.0
	var tween := node.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", Vector2.ONE, duration)
	tween.tween_property(node, "modulate:a", 1.0, duration * 0.5)


func pop_out(
		node: CanvasItem, duration: float = Design.T_POP_OUT, free_when_done: bool = false
) -> void:
	if not is_instance_valid(node):
		return
	if not _can_tween(node):
		# Still honour the free, or a disabled Juice leaks the node.
		if free_when_done:
			node.queue_free()
		return
	_prepare_pivot(node)
	var tween := node.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_property(node, "scale", Vector2.ONE * 0.01, duration)
	tween.tween_property(node, "modulate:a", 0.0, duration)
	if free_when_done:
		tween.finished.connect(node.queue_free)


## Forwarded to Stage, which owns the single ToastLayer. Looked up at call time
## because Stage is registered after Juice.
##
## Deliberately NOT gated on `enabled`. A toast carries game information, such as
## a turn passing for want of a legal move, and reduced motion is an accessibility
## setting: it may take away animation, never content. The toast layer reads
## `enabled` itself and plays a plain fade instead of the pop when it is off.
func toast(message: String, colour: Color = Design.GOLD, hold: float = Design.T_TOAST_HOLD) -> void:
	var stage := get_node_or_null(^"/root/Stage")
	if stage == null:
		return
	stage.toast(message, colour, hold)


func flash(colour: Color, duration: float = 0.12) -> void:
	if not _enabled or _flash_rect == null:
		return
	_flash_rect.color = colour
	_flash_rect.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(_flash_rect, "modulate:a", 0.0, maxf(duration, 0.01))


func register_camera(camera: Camera2D) -> void:
	if camera == null or _cameras.has(camera):
		return
	_cameras.append(camera)


func unregister_camera(camera: Camera2D) -> void:
	_cameras.erase(camera)
	if is_instance_valid(camera):
		camera.offset = Vector2.ZERO


func _build_flash() -> void:
	_flash_layer = CanvasLayer.new()
	_flash_layer.name = "FlashLayer"
	_flash_layer.layer = FLASH_LAYER
	add_child(_flash_layer)
	_flash_rect = ColorRect.new()
	_flash_rect.name = "Flash"
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_flash_rect.modulate.a = 0.0
	_flash_layer.add_child(_flash_rect)


func _push_offset() -> void:
	var live: Array[Camera2D] = []
	for camera in _cameras:
		if not is_instance_valid(camera):
			continue
		camera.offset = _offset
		live.append(camera)
	if live.size() != _cameras.size():
		_cameras = live


## Cuts everything already in flight. Blocking new calls is not enough: a shake
## mid-decay or a hitstop mid-await would outlive the setting change.
func _silence() -> void:
	_hitstop_token += 1
	Engine.time_scale = 1.0
	_trauma = 0.0
	_sample_clock = 0.0
	_offset = Vector2.ZERO
	for camera in _cameras:
		if is_instance_valid(camera):
			camera.offset = Vector2.ZERO
	if _flash_rect != null:
		_flash_rect.modulate.a = 0.0
	var stage := get_node_or_null(^"/root/Stage")
	if stage != null:
		stage.clear_toasts()


func _sync_from_settings(settings: Node) -> void:
	enabled = (
		bool(settings.get_value("game/juice", true))
		and not bool(settings.get_value("a11y/reduced_motion", false))
	)


func _on_settings_changed(key: String, _value: Variant) -> void:
	if key != "game/juice" and key != "a11y/reduced_motion":
		return
	var settings := get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	_sync_from_settings(settings)


func _can_tween(node: CanvasItem) -> bool:
	if not _enabled or not is_instance_valid(node):
		return false
	# CanvasItem itself has no scale. Node2D and Control do, and those are the
	# only two things this game animates.
	return node is Node2D or node is Control


func _set_scale(node: CanvasItem, value: Vector2) -> void:
	if node is Node2D:
		(node as Node2D).scale = value
	elif node is Control:
		(node as Control).scale = value


## Scaling a Control about its top-left corner reads as a slide, not a pop, so a
## widget that has not set its own pivot gets a centred one.
func _prepare_pivot(node: CanvasItem) -> void:
	if not (node is Control):
		return
	var control := node as Control
	if control.pivot_offset == Vector2.ZERO:
		control.pivot_offset = control.size * 0.5
