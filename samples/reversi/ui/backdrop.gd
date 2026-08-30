@tool
class_name Backdrop
extends Control

## The field of slow diagonal bands behind every full screen.
##
## It exists to stop a flat fill from reading as an empty buffer. The drift is
## deliberately slower than anything the player is doing, so it never competes
## with the board for attention.

## Lean across the full height. Four times a plate's lean, because a band spans
## the screen and the same angle would be invisible at that length.
const LEAN_SCALE := 4.0

## One band plus one gap, solved against the 2560 design box at eight periods
## across. Holding the first pass's proportion would have meant a 520 period,
## and a 300px band on a page this wide read as a slab cutting the screen rather
## than as texture. The field wants more bands here, not wider ones.
const PERIOD := 320.0
const BAND_WIDTH := 190.0

## Pixels per second, and the only rate on this page rather than a size. It grew
## with the page anyway: a band now has twice as far to travel, so holding 6
## would have halved the drift a player actually sees.
const DRIFT := 12.0

## Every Nth band takes the accent instead of the base tint. Solved by eye at
## 0.10 alpha: the first pass ran the accent at 0.25 and a saturated band read
## as a slab of colour cutting the screen in half rather than as texture.
const ACCENT_EVERY := 3

@export var accent: Color = Design.GOLD:
	set(value):
		accent = value
		queue_redraw()

@export var base_alpha := 0.35:
	set(value):
		base_alpha = value
		queue_redraw()

@export var accent_alpha := 0.10:
	set(value):
		accent_alpha = value
		queue_redraw()

var _offset := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	if not _motion_allowed():
		return
	_offset = fmod(_offset + DRIFT * delta, PERIOD)
	queue_redraw()


func _draw() -> void:
	var box := size
	if box.x <= 0.0 or box.y <= 0.0:
		return

	draw_rect(Rect2(Vector2.ZERO, box), Design.NIGHT)

	var lean := Design.PLATE_SKEW * LEAN_SCALE
	var base := Design.NIGHT_HI
	base.a = base_alpha
	var tint := accent
	tint.a = accent_alpha

	# Start a full period left of the viewport and run a period past its right
	# edge, so a band sliding in or out is never drawn half-formed.
	var first := -PERIOD - lean
	var span := box.x + lean + PERIOD * 2.0
	var count := int(ceil(span / PERIOD))

	for i in count:
		var x := first + float(i) * PERIOD + _offset
		var colour := tint if i % ACCENT_EVERY == 0 else base
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(x + lean, 0.0),
				Vector2(x + lean + BAND_WIDTH, 0.0),
				Vector2(x + BAND_WIDTH, box.y),
				Vector2(x, box.y),
			]),
			colour
		)


## Reduced motion holds the field still. It still draws: the texture is not the
## thing that causes trouble, the movement is.
func _motion_allowed() -> bool:
	if Engine.is_editor_hint():
		return false
	var juice := get_node_or_null(^"/root/Juice")
	if juice == null:
		return true
	return bool(juice.enabled)
