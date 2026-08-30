@tool
class_name JuiceButton
extends BaseButton

## A button that draws itself: a skewed plate, a hard offset shadow, and a label
## painted straight onto the face.
##
## Built on [BaseButton] rather than [Button] so nothing themed leaks in, and
## drawn entirely in [method _draw] so every piece of its state is a float a
## tween can reach. Four animation channels run on their own tweens so they can
## overlap without fighting: select (hover or focus), press, intro (entrance),
## and shake (what a press on a disabled button gets).

## Where the button travels in from. The label rides the plate either way.
enum IntroStyle {
	SLIDE, ## In from the side, the menu default.
	RISE, ## Up from below.
	POP, ## Scaled up from nothing.
	FADE, ## Opacity only, with a 12px settle.
}

const PAD_X := Design.SPACE_LG ## Breathing room each side of the label.

## Vertical air in the minimum size only. Deliberately the smallest ladder step:
## the minimum has to stay clear of Design.BUTTON_H, or a screen sizing a button
## to that token would be silently clamped taller and push its neighbour off.
const PAD_Y := Design.SPACE_XS

const SELECT_SLIDE := Design.SPACE_MD ## How far a hovered plate leans right.
const SELECT_GROW := 0.07
const PRESS_SQUASH := 0.10
const SHADOW_PRESS_SHRINK := 0.75 ## Press takes the shadow offset down to 25%.
const INTRO_TRAVEL := 1040.0
const VERTICAL_TRAVEL := 480.0
const FADE_SETTLE := 24.0 ## The short drop a FADE entrance settles through.

## Two detuned amplitudes, so the refuse wobble never reads as a clean sine.
const REFUSE_AMP_FAST := 18.0
const REFUSE_AMP_SLOW := 8.0

const T_INTRO := 0.45
const T_OUTRO := 0.30
const T_REFUSE := 0.45
const FOCUS_RING_OFFSET := Design.SPACE_XS
const FOCUS_RING_WIDTH := 6.0

@export var text: String = "BUTTON":
	set(value):
		text = value
		update_minimum_size()
		queue_redraw()

## Fill the plate reaches when hovered or focused.
@export var accent: Color = Design.GOLD:
	set(value):
		accent = value
		queue_redraw()

@export var intro_style: IntroStyle = IntroStyle.SLIDE

## Whether a press also asks Juice for a shake and a touch of hitstop.
@export var juicy_press: bool = true

@export var font_size: int = Design.FS_BODY:
	set(value):
		font_size = maxi(value, 1)
		update_minimum_size()
		queue_redraw()

@export_group("Colours")
@export var fill_idle: Color = Design.NIGHT_HI
@export var fill_disabled: Color = Design.NIGHT_LO
@export var text_idle: Color = Design.CREAM
@export var text_selected: Color = Design.INK

# Animated state. _draw reads only these floats, never the tweens driving them,
# so a redraw during a scene reload can never touch a freed Tween.

var _select: float = 0.0:
	set(value):
		_select = value
		queue_redraw()

var _press: float = 0.0:
	set(value):
		_press = value
		queue_redraw()

var _intro: float = 1.0:
	set(value):
		_intro = value
		queue_redraw()

var _alpha: float = 1.0:
	set(value):
		_alpha = value
		queue_redraw()

var _shake: float = 0.0:
	set(value):
		_shake = value
		# absf, because the elastic settle undershoots past zero and a signed
		# test would stop the clock mid-wobble and freeze the phase.
		set_process(absf(value) > 0.001)
		queue_redraw()

var _select_tween: Tween
var _press_tween: Tween
var _intro_tween: Tween
var _shake_tween: Tween
var _hovering: bool = false
var _selected: bool = false
var _shake_time: float = 0.0


func _ready() -> void:
	set_process(false)
	mouse_entered.connect(_on_hover_changed.bind(true))
	mouse_exited.connect(_on_hover_changed.bind(false))
	focus_entered.connect(_refresh_select)
	focus_exited.connect(_refresh_select)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	pressed.connect(_on_pressed)


func _process(delta: float) -> void:
	# The refuse wobble is sampled off wall time rather than tweened per axis,
	# so it needs a frame tick for as long as it is decaying.
	_shake_time += delta
	queue_redraw()


func _get_minimum_size() -> Vector2:
	var use_font := Design.font()
	if use_font == null:
		return Vector2(Design.BUTTON_W * 0.5, float(font_size) * 1.6)
	var measured := use_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	# Measured glyph box rather than a multiple of the point size: Bungee's own
	# ascent and descent are what has to fit, and a flat multiplier overshot them
	# far enough at FS_H2 to clamp a BUTTON_H row.
	var glyphs := use_font.get_ascent(font_size) + use_font.get_descent(font_size)
	return Vector2(measured.x + PAD_X * 2.0 + Design.PLATE_SKEW, glyphs + PAD_Y * 2.0)


## Entrance. [param delay] is what a menu uses to stagger a column of these.
func play_intro(delay: float = 0.0) -> void:
	_intro = 0.0
	_alpha = 0.0
	if not is_inside_tree():
		return
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	_intro_tween = create_tween().set_parallel(true)
	_intro_tween.tween_property(self, ^"_intro", 1.0, T_INTRO).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Opacity runs its own shorter leg because the BACK ease overshoots past 1,
	# and an alpha driven off that would clip flat before the plate lands.
	_intro_tween.tween_property(self, ^"_alpha", 1.0, T_INTRO * 0.5).set_delay(delay) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Exit. Returns nothing; the caller times the gap with its own stagger maths.
func play_outro(delay: float = 0.0) -> void:
	if not is_inside_tree():
		_intro = 0.0
		_alpha = 0.0
		return
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	_intro_tween = create_tween().set_parallel(true)
	_intro_tween.tween_property(self, ^"_intro", 0.0, T_OUTRO).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_intro_tween.tween_property(self, ^"_alpha", 0.0, T_OUTRO).set_delay(delay) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


## The answer to a press this button cannot accept: a decaying elastic wobble
## and the error sound. Two frequencies so it does not read as a clean sine.
func refuse() -> void:
	_shake_time = 0.0
	_shake = 1.0
	if is_inside_tree():
		if _shake_tween != null and _shake_tween.is_valid():
			_shake_tween.kill()
		_shake_tween = create_tween()
		_shake_tween.tween_property(self, ^"_shake", 0.0, T_REFUSE) \
				.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_play_sound(&"error", -6.0)


## Fires the button as though it had been clicked, so a menu can drive it from
## the keyboard without synthesising an input event. A disabled one refuses.
func press() -> void:
	if disabled:
		refuse()
		return
	if is_inside_tree():
		if _press_tween != null and _press_tween.is_valid():
			_press_tween.kill()
		_press_tween = create_tween()
		_press_tween.tween_property(self, ^"_press", 1.0, Design.T_PRESS_IN)
		_press_tween.tween_property(self, ^"_press", 0.0, Design.T_PRESS_OUT) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pressed.emit()


func _gui_input(event: InputEvent) -> void:
	# BaseButton's own handler swallows input while disabled, so the refuse
	# gesture has to be caught here, ahead of it.
	if not disabled:
		return
	var refused := false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		refused = button.button_index == MOUSE_BUTTON_LEFT and button.pressed
	elif event.is_action_pressed(&"ui_accept"):
		refused = true
	if refused:
		refuse()
		accept_event()


## Hovering is tracked rather than read back from is_hovered(): Control emits
## mouse_exited before BaseButton clears its own flag, so the flag still reads
## true inside the handler.
func _on_hover_changed(hovering: bool) -> void:
	_hovering = hovering
	_refresh_select()


func _refresh_select() -> void:
	var wanted := _hovering or has_focus()
	if wanted == _selected:
		return
	_selected = wanted
	if wanted and _intro > 0.5 and not disabled:
		_play_sound(&"click", -10.0)
	if not is_inside_tree():
		_select = 1.0 if wanted else 0.0
		return
	if _select_tween != null and _select_tween.is_valid():
		_select_tween.kill()
	_select_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_select_tween.tween_property(self, ^"_select", 1.0 if wanted else 0.0, Design.T_HOVER)


func _on_button_down() -> void:
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = create_tween()
	_press_tween.tween_property(self, ^"_press", 1.0, Design.T_PRESS_IN)


func _on_button_up() -> void:
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	# The settle has to wait out the hit: a second tween on the same property
	# cancels the first, so overlapping them would eat the squash entirely.
	_press_tween = create_tween()
	_press_tween.tween_property(self, ^"_press", 0.0, Design.T_PRESS_OUT) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_pressed() -> void:
	_play_sound(&"confirm", -4.0)
	if not juicy_press:
		return
	var juice := get_node_or_null(^"/root/Juice")
	if juice == null:
		return
	juice.shake(0.15)
	juice.hitstop(0.03)


func _play_sound(bank: StringName, volume_offset_db: float) -> void:
	var audio := get_node_or_null(^"/root/Audio")
	if audio != null:
		audio.play(bank, volume_offset_db)


func _draw() -> void:
	var use_font := Design.font()
	if use_font == null or _alpha <= 0.001:
		return

	var box := size
	var centre := box * 0.5
	var grow := 1.0 + _select * SELECT_GROW - _press * PRESS_SQUASH
	var slide := _select * SELECT_SLIDE
	if absf(_shake) > 0.001:
		slide += sin(_shake_time * 74.0) * _shake * REFUSE_AMP_FAST
		slide += sin(_shake_time * 131.0) * _shake * REFUSE_AMP_SLOW

	var travel := _entry_offset() + Vector2(slide, 0.0)
	var stretch := _entry_scale() * grow
	var alpha := clampf(_alpha, 0.0, 1.0)

	var face := Design.plate(box)
	for i in face.size():
		face[i] = centre + (face[i] - centre) * stretch + travel

	var shadow := PackedVector2Array(face)
	var shadow_step := Design.SHADOW_OFF * (1.0 - _press * SHADOW_PRESS_SHRINK)
	for i in shadow.size():
		shadow[i] += shadow_step

	var shade := Design.INK
	shade.a *= alpha * 0.9
	draw_colored_polygon(shadow, shade)

	var fill := fill_disabled if disabled else fill_idle.lerp(accent, _select)
	fill.a *= alpha
	draw_colored_polygon(face, fill)

	if has_focus():
		_draw_focus_ring(face, alpha)

	var ink := text_idle if disabled else text_idle.lerp(text_selected, _select)
	ink.a *= alpha * (0.45 if disabled else 1.0)
	var measured := use_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline := centre.y \
			+ (use_font.get_ascent(font_size) - use_font.get_descent(font_size)) * 0.5

	# The label goes through the same transform as the plate rather than a child
	# Label, so it slides, grows and shakes with the face instead of lagging it.
	draw_set_transform_matrix(
		Transform2D(0.0, stretch, 0.0, centre - centre * stretch + travel))
	draw_string(
		use_font, Vector2(centre.x - measured.x * 0.5, baseline),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ink
	)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_focus_ring(face: PackedVector2Array, alpha: float) -> void:
	var ring := face
	var expanded := Geometry2D.offset_polygon(face, FOCUS_RING_OFFSET)
	if not expanded.is_empty():
		ring = expanded[0]
	var closed := PackedVector2Array(ring)
	if not closed.is_empty():
		closed.append(closed[0])
	var gold := Design.GOLD
	gold.a *= alpha
	draw_polyline(closed, gold, FOCUS_RING_WIDTH)


## Scale is floored at zero: _intro dips below 0 under the BACK ease, and a
## negative scale would mirror the plate on its way out.
func _entry_scale() -> Vector2:
	if intro_style == IntroStyle.POP:
		return Vector2.ONE * maxf(_intro, 0.0)
	return Vector2.ONE


func _entry_offset() -> Vector2:
	var away := 1.0 - _intro
	match intro_style:
		IntroStyle.SLIDE:
			# Always in from the left, so a dealt column reads as one gesture.
			return Vector2(-away * INTRO_TRAVEL, 0.0)
		IntroStyle.RISE:
			return Vector2(0.0, away * VERTICAL_TRAVEL)
		IntroStyle.FADE:
			return Vector2(0.0, away * FADE_SETTLE)
		_:
			return Vector2.ZERO
