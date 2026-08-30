@tool
class_name JuiceToast
extends Control

## One notification plate. Pops in, rattles itself still, holds, slides out.
##
## It measures its own plate rather than living in a container, because the plate
## is skewed and a container would lay out the bounding box instead of the shape.

signal finished()

const PADDING := Vector2(Design.SPACE_MD, Design.SPACE_SM) ## Around the message.
const SPINE := Design.SPACE_XS ## Accent bar riding the plate's leaning left edge.
const SLIDE := 180.0 ## How far right of its slot the plate starts.

## Two detuned amplitudes for the arrival rattle, as the buttons carry.
const SHAKE_AMP_FAST := 12.0
const SHAKE_AMP_SLOW := 6.0
const REST_SCALE := 0.86 ## Plate scale at rest, growing to 1.0 on arrival.
const SHAKE_TIME := 0.5 ## The rattle decays over this, in parallel with the pop.

@export var message: String = "":
	set(value):
		message = value
		queue_redraw()

@export var accent: Color = Design.GOLD:
	set(value):
		accent = value
		queue_redraw()

@export var hold: float = Design.T_TOAST_HOLD

var _amount: float = 0.0:
	set(value):
		_amount = value
		queue_redraw()

var _shake: float = 0.0:
	set(value):
		_shake = value
		queue_redraw()

var _time: float = 0.0
var _tween: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if _shake <= 0.001:
		return
	_time += delta
	queue_redraw()


## The plate width this toast needs, measured from its own text.
func measured_width() -> float:
	return _plate_size(Design.font()).x


## The plate is the widget: the layer sizes the Control from measured_width(),
## and _draw() lays the same box out, so the two can never drift apart.
func _plate_size(face: Font) -> Vector2:
	var text_size := Vector2.ZERO
	if face != null:
		text_size = face.get_string_size(
			message, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL
		)
	# The spine eats width on the left, the lean eats it on the right.
	return text_size + PADDING * 2.0 + Vector2(SPINE + Design.PLATE_SKEW, 0.0)


## Runs the whole life in one chain: in, rattle, hold, out, then `finished`.
##
## Under reduced motion the plate still appears and still holds for its full
## time. A toast carries game information, so the setting takes away the pop
## and the rattle, never the message.
func play() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var quiet := not _motion_allowed()
	_amount = 0.0
	_shake = 0.0 if quiet else 1.0
	_time = 0.0
	_tween = create_tween()
	if quiet:
		_tween.tween_property(self, ^"_amount", 1.0, Design.T_TOAST_IN)
	else:
		var step_in := _tween.tween_property(self, ^"_amount", 1.0, Design.T_TOAST_IN)
		step_in.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_tween.parallel().tween_property(self, ^"_shake", 0.0, SHAKE_TIME)
	_tween.tween_interval(hold)
	if quiet:
		_tween.tween_property(self, ^"_amount", 0.0, Design.T_TOAST_OUT)
	else:
		var step_out := _tween.tween_property(self, ^"_amount", 0.0, Design.T_TOAST_OUT)
		step_out.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_on_life_done)


## Juice is looked up by path, never by a bare identifier: this script carries a
## class_name and so can be compiled before the autoloads exist.
func _motion_allowed() -> bool:
	var juice := get_node_or_null(^"/root/Juice")
	if juice == null:
		return true
	return bool(juice.enabled)


func _on_life_done() -> void:
	finished.emit()


func _draw() -> void:
	var face := Design.font()
	if face == null or _amount <= 0.001 or message.is_empty():
		return

	var box := _plate_size(face)

	var centre := Vector2(box.x * 0.5 + (1.0 - _amount) * SLIDE, size.y * 0.5)
	if _shake > 0.001:
		# Two detuned sines, so the rattle never settles into one clean wave.
		centre.x += sin(_time * 74.0) * _shake * SHAKE_AMP_FAST
		centre.x += sin(_time * 131.0) * _shake * SHAKE_AMP_SLOW
	var grow := REST_SCALE + (1.0 - REST_SCALE) * _amount

	var shape := Design.plate(box)
	for i in shape.size():
		shape[i] = centre + (shape[i] - box * 0.5) * grow

	var shadow := PackedVector2Array(shape)
	for i in shadow.size():
		shadow[i] += Design.SHADOW_OFF
	var shade := Design.INK
	shade.a *= _amount * 0.85
	draw_colored_polygon(shadow, shade)

	var plate_colour := Design.NIGHT_HI
	plate_colour.a *= _amount
	draw_colored_polygon(shape, plate_colour)

	# The spine tracks the plate's leaning left edge, corners 0 and 3.
	var spine_step := Vector2(SPINE * grow, 0.0)
	var spine_colour := accent
	spine_colour.a *= _amount
	draw_colored_polygon(PackedVector2Array([
		shape[0],
		shape[0] + spine_step,
		shape[3] + spine_step,
		shape[3],
	]), spine_colour)

	var ink := Design.CREAM
	ink.a *= _amount
	# Half the skew clears the leaning edge at the message's own baseline.
	var left := centre.x - box.x * 0.5 * grow + PADDING.x + SPINE + Design.PLATE_SKEW * 0.5
	var lift := face.get_ascent(Design.FS_SMALL) - face.get_descent(Design.FS_SMALL)
	draw_string(
		face, Vector2(left, centre.y + lift * 0.5), message,
		HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL, ink
	)
