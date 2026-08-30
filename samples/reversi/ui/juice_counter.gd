@tool
class_name JuiceCounter
extends Control

## A number that rolls to its new reading instead of snapping, punches its scale
## on arrival, and flashes green or red on the way.
##
## Both the roll time and the flash scale with how big the change was, so
## catching one disc and catching eleven do not look the same.

const GAP := Design.SPACE_SM ## Between the label's block and the number's.
const PUNCH := 0.22 ## Peak overshoot on the number's scale.
const T_PUNCH := 0.40
const T_FLASH := 0.30 ## Shorter than the punch on purpose, see _react.
const ROLL_MIN := 0.12
const ROLL_MAX := 1.10
const SHADOW_SCALE := 0.5 ## Of Design.SHADOW_OFF. The full 12px is a smear.

signal reached(value: int)

# Backing field. value's setter routes to set_value(), so set_value() must never
# assign to value or it recurses until the stack goes.
var _value: int = 0

@export var value: int = 0:
	set(new_value):
		set_value(new_value)
	get:
		return _value

@export var label: String = "":
	set(new_label):
		label = new_label
		update_minimum_size()
		queue_redraw()

@export var colour: Color = Design.CREAM:
	set(new_colour):
		colour = new_colour
		queue_redraw()

@export var value_font_size: int = Design.FS_H1:
	set(new_size):
		value_font_size = maxi(new_size, 1)
		update_minimum_size()
		queue_redraw()

@export var label_font_size: int = Design.FS_SMALL:
	set(new_size):
		label_font_size = maxi(new_size, 1)
		update_minimum_size()
		queue_redraw()

@export var prefix: String = "":
	set(new_prefix):
		prefix = new_prefix
		update_minimum_size()
		queue_redraw()

@export var suffix: String = "":
	set(new_suffix):
		suffix = new_suffix
		update_minimum_size()
		queue_redraw()

@export_group("Colours")
@export var gain_colour: Color = Design.MINT
@export var loss_colour: Color = Design.RED
@export var label_colour: Color = Design.CREAM

var _displayed: float = 0.0:
	set(new_value):
		_displayed = new_value
		queue_redraw()

var _scale: float = 1.0:
	set(new_value):
		_scale = new_value
		queue_redraw()

## 0 at rest, 1 at the peak of a flash. Kept as a weight rather than a colour so
## a live change to `colour` is never stranded behind a stale tint.
var _flash: float = 0.0:
	set(new_value):
		_flash = new_value
		queue_redraw()

var _flash_colour: Color = Design.MINT
var _roll_tween: Tween
var _punch_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_displayed = float(_value)


## Rolls to [param v]. The duration scales with how far it has to travel
## relative to where it was, so a small correction stays snappy.
func set_value(v: int) -> void:
	var previous := _value
	_value = v

	if not is_inside_tree():
		_displayed = float(v)
		return
	if previous == v:
		return

	if _roll_tween != null and _roll_tween.is_valid():
		_roll_tween.kill()

	var magnitude := absf(float(v - previous))
	var reference := maxf(absf(float(previous)), 1.0)
	var duration := clampf(
		Design.T_COUNTER_ROLL * clampf(magnitude / reference, 0.15, 2.0),
		ROLL_MIN, ROLL_MAX
	)

	_roll_tween = create_tween()
	_roll_tween.tween_property(self, ^"_displayed", float(v), duration) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_roll_tween.tween_callback(func() -> void: reached.emit(v))

	_react(v > previous)


## Jumps straight to [param v] with no animation. What a board reset calls.
func snap_value(v: int) -> void:
	if _roll_tween != null and _roll_tween.is_valid():
		_roll_tween.kill()
	if _punch_tween != null and _punch_tween.is_valid():
		_punch_tween.kill()
	_value = v
	_displayed = float(v)
	_scale = 1.0
	_flash = 0.0


func formatted() -> String:
	return prefix + str(int(round(_displayed))) + suffix


func _react(is_gain: bool) -> void:
	if _punch_tween != null and _punch_tween.is_valid():
		_punch_tween.kill()

	_scale = 1.0 + PUNCH
	_flash = 1.0
	_flash_colour = gain_colour if is_gain else loss_colour

	_punch_tween = create_tween().set_parallel(true)
	_punch_tween.tween_property(self, ^"_scale", 1.0, T_PUNCH) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	# Colour comes back faster than the scale so the flash punctuates instead of
	# leaving the number sitting there tinted.
	_punch_tween.tween_property(self, ^"_flash", 0.0, T_FLASH) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _get_minimum_size() -> Vector2:
	var use_font := Design.font()
	if use_font == null:
		return Vector2(Design.SPACE_XXL, float(label_font_size + value_font_size) + GAP)

	var value_size := use_font.get_string_size(
		formatted(), HORIZONTAL_ALIGNMENT_LEFT, -1, value_font_size)
	var width := value_size.x
	var height := use_font.get_ascent(value_font_size) + use_font.get_descent(value_font_size)

	if not label.is_empty():
		var label_size := use_font.get_string_size(
			label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size)
		width = maxf(width, label_size.x)
		height += use_font.get_ascent(label_font_size) \
				+ use_font.get_descent(label_font_size) + GAP

	return Vector2(width, height)


func _draw() -> void:
	var use_font := Design.font()
	if use_font == null:
		return

	var top := 0.0
	if not label.is_empty():
		var label_ink := label_colour
		label_ink.a *= 0.7
		var baseline := use_font.get_ascent(label_font_size)
		draw_string(
			use_font, Vector2(0.0, baseline), label.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, label_ink
		)
		top = baseline + use_font.get_descent(label_font_size) + GAP

	var text := formatted()
	var measured := use_font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, value_font_size)
	var ascent := use_font.get_ascent(value_font_size)
	var origin := Vector2(0.0, top + ascent)

	# Punches about the number's own middle, not the widget's, so a two-digit
	# reading and a one-digit reading swell from the same place.
	var pivot := Vector2(measured.x * 0.5, top + ascent * 0.5)
	draw_set_transform_matrix(
		Transform2D(0.0, Vector2(_scale, _scale), 0.0, pivot - pivot * _scale))

	draw_string(
		use_font, origin + Design.SHADOW_OFF * SHADOW_SCALE, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, value_font_size, Design.INK
	)
	draw_string(
		use_font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		value_font_size, colour.lerp(_flash_colour, clampf(_flash, 0.0, 1.0))
	)
	draw_set_transform_matrix(Transform2D.IDENTITY)
