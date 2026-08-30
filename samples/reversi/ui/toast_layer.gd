@tool
class_name ToastLayer
extends CanvasLayer

## The notification stack, top right of the screen. Owned by Stage.
##
## When a toast retires the rest slide into the gap it left. A stack that pops a
## hole instead reads as broken, so the reflow is the point, not a flourish.

const MAX_VISIBLE := 5
const MARGIN := Vector2(Design.SPACE_LG, Design.SPACE_LG)

## A slot holds the plate plus its air. The plate is about 72px at FS_SMALL, so
## ROW_H leaves SPACE_MD-ish between two stacked toasts without a second token.
const SLOT_HEIGHT := Design.ROW_H
const REFLOW_TIME := 0.28 ## TRANS_CUBIC / EASE_OUT.

## Only used before the layer has a viewport to measure. Matches the design box
## so a toast pushed that early still lands on screen.
const FALLBACK_SIZE := Vector2(2560.0, 1440.0)

var _toasts: Array[JuiceToast] = []


func _init() -> void:
	layer = 120
	# Toasts have to keep animating while the tree is paused, since the pause
	# menu is one of the places that pushes them.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Adds a toast to the top-right stack and starts its life. Pushing past
## MAX_VISIBLE retires the oldest first.
func push(
		message: String,
		accent: Color = Design.GOLD,
		hold: float = Design.T_TOAST_HOLD
) -> JuiceToast:
	if _toasts.size() >= MAX_VISIBLE:
		_retire(_toasts[0])

	var toast := JuiceToast.new()
	toast.message = message
	toast.accent = accent
	toast.hold = hold
	# Plain top-left offsets. An anchored Control reads its position relative to
	# the anchor, which breaks the moment a toast is sized from its own text.
	toast.set_anchors_preset(Control.PRESET_TOP_LEFT)
	toast.size = Vector2(toast.measured_width(), SLOT_HEIGHT)
	toast.position = _slot_position(toast.size.x, _toasts.size())
	add_child(toast)

	_toasts.append(toast)
	toast.finished.connect(_retire.bind(toast))
	toast.play()
	return toast


## Drops every toast on the spot, for the juice-disabled path.
func clear() -> void:
	for toast in _toasts:
		if is_instance_valid(toast):
			toast.queue_free()
	_toasts.clear()


func _retire(toast: JuiceToast) -> void:
	if not is_instance_valid(toast):
		return
	_toasts.erase(toast)
	toast.queue_free()
	_reflow()


func _slot_position(width: float, index: int) -> Vector2:
	var screen := FALLBACK_SIZE
	var viewport := get_viewport()
	if viewport != null:
		screen = viewport.get_visible_rect().size
	return Vector2(screen.x - width - MARGIN.x, MARGIN.y + float(index) * SLOT_HEIGHT)


func _reflow() -> void:
	for i in _toasts.size():
		var toast := _toasts[i]
		if not is_instance_valid(toast):
			continue
		var target := _slot_position(toast.size.x, i)
		toast.position.x = target.x
		if absf(toast.position.y - target.y) < 0.5:
			continue
		var tween := toast.create_tween()
		tween.tween_property(toast, ^"position:y", target.y, REFLOW_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
