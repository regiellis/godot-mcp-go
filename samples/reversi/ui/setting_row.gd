@tool
class_name SettingRow
extends Control

## One line of the settings panel: a label on the left, a drawn control on the
## right, and an optional helper line beneath.
##
## Both control kinds live behind one `kind` enum rather than in two scenes,
## because the settings panel builds its rows from a data array and a second
## scene per kind would stop a new setting from being one dictionary entry.
##
## Nothing here is an HSlider or a CheckButton. Every piece of state is a float
## a tween can reach, which is what lets the toggle knob slide instead of snap.

enum Kind {
	SLIDER, ## A 0..1 float, shown as a percentage.
	TOGGLE, ## A bool.
}

## Carries a float for SLIDER and a bool for TOGGLE, so the panel can hand it
## straight to Settings.set_value without knowing which row fired.
signal value_changed(value: Variant)

## The control band, which is the row proper. A helper line sits under it.
const BAND_H := Design.ROW_H
const TRACK_W := 480.0
const TRACK_H := Design.SPACE_SM
const KNOB := Design.SPACE_MD

## Reserved right of the track for the reading. "100%" measures 93px at
## FS_SMALL, so SPACE_XXL clears it with room for the gap.
const VALUE_W := Design.SPACE_XXL

const TOGGLE_W := 112.0
const TOGGLE_H := 56.0
const TOGGLE_PAD := 6.0
const TOGGLE_KNOB := TOGGLE_H - TOGGLE_PAD * 2.0
const TOGGLE_OUTLINE := 4.0 ## Ink border around the toggle rail.
const KNOB_OUTLINE := 2.0 ## Ink border around the slider knob.
const T_KNOB := 0.16 ## TRANS_QUAD / EASE_OUT.
const STEP := 0.05 ## What ui_left and ui_right move a slider by.
const HELPER_GAP := Design.SPACE_XS
const HELPER_ALPHA := 0.6
const FOCUS_PAD := Design.SPACE_XS
const FOCUS_WIDTH := 6.0

## Slack each side of the control so a drag that starts a few pixels short of
## the rail still grabs it.
const GRAB_SLACK := Design.SPACE_SM

@export var label: String = "SETTING":
	set(value):
		label = value
		update_minimum_size()
		queue_redraw()

@export var kind: Kind = Kind.SLIDER:
	set(value):
		kind = value
		update_minimum_size()
		queue_redraw()

@export var accent: Color = Design.PINK:
	set(value):
		accent = value
		queue_redraw()

@export var helper: String = "":
	set(value):
		helper = value
		update_minimum_size()
		queue_redraw()

var _amount: float = 0.5:
	set(value):
		_amount = clampf(value, 0.0, 1.0)
		queue_redraw()

var _on: bool = false

## Where the toggle knob actually sits, 0 at the left stop and 1 at the right.
## Separate from `_on` so the slide can lag the state change.
var _knob: float = 0.0:
	set(value):
		_knob = value
		queue_redraw()

var _knob_tween: Tween
var _dragging := false


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


## Sets the row without firing `value_changed`, which is what reading the stored
## settings back on entry needs. A float lands on the slider, a bool on the
## toggle, and a mismatched type is ignored rather than coerced.
func set_value(value: Variant) -> void:
	if kind == Kind.SLIDER:
		if value is float or value is int:
			_amount = float(value)
		return
	if not (value is bool):
		return
	_on = bool(value)
	_settle_knob(false)


func get_value() -> Variant:
	return _amount if kind == Kind.SLIDER else _on


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_click(event as InputEventMouseButton)
		return
	if event is InputEventMouseMotion and _dragging:
		_set_from_point((event as InputEventMouseMotion).position.x)
		accept_event()
		return
	_handle_key(event)


func _handle_click(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		_dragging = false
		return
	if not _hit_rect().has_point(event.position):
		return
	grab_focus()
	accept_event()
	if kind == Kind.TOGGLE:
		_commit_toggle(not _on)
		return
	_dragging = true
	_set_from_point(event.position.x)
	_click_sound()


func _handle_key(event: InputEvent) -> void:
	if kind == Kind.TOGGLE:
		_handle_toggle_key(event)
		return
	var step := 0.0
	if event.is_action_pressed(&"ui_left", true):
		step = -STEP
	elif event.is_action_pressed(&"ui_right", true):
		step = STEP
	if is_zero_approx(step):
		return
	accept_event()
	_commit_amount(_amount + step)


func _handle_toggle_key(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_accept"):
		_commit_toggle(not _on)
		accept_event()
	elif event.is_action_pressed(&"ui_left") and _on:
		_commit_toggle(false)
		accept_event()
	elif event.is_action_pressed(&"ui_right") and not _on:
		_commit_toggle(true)
		accept_event()


func _set_from_point(x: float) -> void:
	_commit_amount((x - _track_left()) / TRACK_W)


func _commit_amount(wanted: float) -> void:
	var next := clampf(wanted, 0.0, 1.0)
	if is_equal_approx(next, _amount):
		return
	_amount = next
	value_changed.emit(_amount)


func _commit_toggle(wanted: bool) -> void:
	if wanted == _on:
		return
	_on = wanted
	_settle_knob(true)
	_click_sound()
	value_changed.emit(_on)


## `animate` is false when the row is being restored from storage: a knob that
## slid in on entry would read as the player having just changed something.
func _settle_knob(animate: bool) -> void:
	var target := 1.0 if _on else 0.0
	if not animate or not is_inside_tree() or Engine.is_editor_hint():
		_knob = target
		return
	if _knob_tween != null and _knob_tween.is_valid():
		_knob_tween.kill()
	_knob_tween = create_tween()
	_knob_tween.tween_property(self, ^"_knob", target, T_KNOB) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Resolved by path, never by bare name: this script carries a class_name and so
## can be compiled before the autoloads exist.
func _click_sound() -> void:
	var audio := get_node_or_null(^"/root/Audio")
	if audio != null:
		audio.play(&"click", -8.0)


## The row tells its panel how wide it has to be, label included. A panel sized
## under this ran "MASTER VOLUME" straight into the slider rail, which is the
## exact fault this pass exists to remove. Height stays on ROW_H unless a helper
## line is set, so a panel stacking on ROW_H is never clamped taller.
func _get_minimum_size() -> Vector2:
	var control_w := TOGGLE_W if kind == Kind.TOGGLE else TRACK_W + VALUE_W
	var use_font := Design.font()
	if use_font == null:
		return Vector2(control_w + Design.SPACE_LG, BAND_H)
	var height := BAND_H
	if not helper.is_empty():
		height += HELPER_GAP + use_font.get_height(Design.FS_SMALL)
	var label_w := use_font.get_string_size(
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_BODY
	).x
	return Vector2(label_w + Design.SPACE_LG + control_w, height)


func _track_left() -> float:
	return size.x - VALUE_W - TRACK_W


func _control_rect() -> Rect2:
	var mid := BAND_H * 0.5
	if kind == Kind.TOGGLE:
		return Rect2(size.x - TOGGLE_W, mid - TOGGLE_H * 0.5, TOGGLE_W, TOGGLE_H)
	return Rect2(_track_left(), mid - KNOB * 0.5, TRACK_W + VALUE_W, KNOB)


func _hit_rect() -> Rect2:
	return _control_rect().grow(GRAB_SLACK)


func _draw() -> void:
	var use_font := Design.font()
	if use_font == null or size.x <= 0.0:
		return

	var mid := BAND_H * 0.5
	var baseline := mid + (
		use_font.get_ascent(Design.FS_BODY) - use_font.get_descent(Design.FS_BODY)
	) * 0.5
	draw_string(
		use_font, Vector2(0.0, baseline), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_BODY, Design.CREAM
	)

	if kind == Kind.TOGGLE:
		_draw_toggle(mid)
	else:
		_draw_slider(use_font, mid)

	if has_focus():
		draw_rect(_control_rect().grow(FOCUS_PAD), Design.GOLD, false, FOCUS_WIDTH)

	if helper.is_empty():
		return
	var tint := Design.CREAM
	tint.a = HELPER_ALPHA
	draw_string(
		use_font,
		Vector2(0.0, BAND_H + HELPER_GAP + use_font.get_ascent(Design.FS_SMALL)),
		helper, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL, tint
	)


func _draw_slider(use_font: Font, mid: float) -> void:
	var left := _track_left()
	var rail := Rect2(left, mid - TRACK_H * 0.5, TRACK_W, TRACK_H)
	draw_rect(rail, Design.NIGHT_LO)
	if _amount > 0.0:
		draw_rect(Rect2(rail.position, Vector2(TRACK_W * _amount, TRACK_H)), accent)

	var knob_x := left + TRACK_W * _amount
	var knob := Rect2(knob_x - KNOB * 0.5, mid - KNOB * 0.5, KNOB, KNOB)
	draw_rect(knob.grow(KNOB_OUTLINE), Design.INK)
	draw_rect(knob, Design.CREAM)

	# A percentage rather than the raw float: a player reads 80, not 0.8.
	var text := "%d%%" % int(round(_amount * 100.0))
	var measured := use_font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL
	)
	var text_baseline := mid + (
		use_font.get_ascent(Design.FS_SMALL) - use_font.get_descent(Design.FS_SMALL)
	) * 0.5
	draw_string(
		use_font, Vector2(size.x - measured.x, text_baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL, Design.CREAM
	)


func _draw_toggle(mid: float) -> void:
	var rail := Rect2(size.x - TOGGLE_W, mid - TOGGLE_H * 0.5, TOGGLE_W, TOGGLE_H)
	draw_rect(rail.grow(TOGGLE_OUTLINE), Design.INK)
	draw_rect(rail, Design.NIGHT_LO.lerp(Design.MINT, _knob))
	var travel := TOGGLE_W - TOGGLE_PAD * 2.0 - TOGGLE_KNOB
	draw_rect(
		Rect2(
			rail.position + Vector2(TOGGLE_PAD + travel * _knob, TOGGLE_PAD),
			Vector2(TOGGLE_KNOB, TOGGLE_KNOB)
		),
		Design.CREAM
	)
