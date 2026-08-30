extends Control

## One card, held for 1.6 seconds, then gone.
##
## Flat [constant Design.INK] and no [Backdrop]: splash and intro are the moment
## before the game rather than screens of it, so they carry none of its texture.
##
## Nothing on the card is placed by hand. [method layout] derives all three
## boxes from measured type, [method _draw] paints them, and the builder audits
## the same dictionary, so the drawing and the audit cannot disagree.

const NEXT_PATH := "res://screens/intro/intro.tscn"

const T_FADE_IN := 0.4
const T_HOLD := 0.8
const T_FADE_OUT := 0.4

## Input is dead this long after the screen appears. A key still held down from
## wherever the player came from would otherwise skip two cards on one press.
const SKIP_DEBOUNCE := 0.35

## Half the board's width. The 6px weight is a stroke and not a gap, which is
## why it is the one number here that does not come off the space ladder.
const RULE_SIZE := Vector2(Design.BOARD_PX * 0.5, 6.0)

## Off the type scale on purpose, between FS_H1 and FS_HERO: the logotype is
## lowercase, so it needs more size than a heading to carry the same weight.
const WORDMARK_SIZE := 144

const SUBTITLE_ALPHA := 0.75

const WORDMARK := "godot-mcp"
const SUBTITLE := "A GODOT EDITOR, DRIVEN BY AN AGENT"

var _alpha := 0.0:
	set(value):
		_alpha = value
		queue_redraw()

var _age := 0.0

## The one flag both the timed path and the skip path check, so a skip landing
## on the frame the fade ends cannot change scene twice.
var _advancing := false

## Cached because every box costs a text measurement, and the card is redrawn
## on every frame of both fades.
var _boxes: Dictionary = {}
var _boxes_for := Vector2.ZERO


## Every box the card draws, keyed by the name the audit reports it under.
## Static so the builder can audit the shipped layout rather than a copy of it.
static func layout(page: Vector2) -> Dictionary:
	var use_font := Design.font()
	if use_font == null or page.x <= 0.0 or page.y <= 0.0:
		return {}

	var wordmark_size := use_font.get_string_size(
			WORDMARK, HORIZONTAL_ALIGNMENT_LEFT, -1, WORDMARK_SIZE)
	var wordmark_h := Design.text_height(WORDMARK, page.x, WORDMARK_SIZE)
	var subtitle_w := tracked_width(use_font, SUBTITLE, Design.FS_SMALL, Design.TRACK_LABEL)
	var subtitle_h := Design.text_height(SUBTITLE, page.x, Design.FS_SMALL)

	var stack := RULE_SIZE.y + Design.SPACE_LG + wordmark_h + Design.SPACE_MD + subtitle_h
	var centre := page.x * 0.5
	var y := (page.y - stack) * 0.5

	var boxes := {}
	boxes["Rule"] = Rect2(centre - RULE_SIZE.x * 0.5, y, RULE_SIZE.x, RULE_SIZE.y)
	y += RULE_SIZE.y + Design.SPACE_LG
	boxes["Wordmark"] = Rect2(centre - wordmark_size.x * 0.5, y, wordmark_size.x, wordmark_h)
	y += wordmark_h + Design.SPACE_MD
	boxes["Subtitle"] = Rect2(centre - subtitle_w * 0.5, y, subtitle_w, subtitle_h)
	return boxes


## Width of a tracked run, which is wider than the string by one gap per join.
static func tracked_width(
		use_font: Font, text: String, font_size: int, tracking: float
) -> float:
	var width := use_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return width + tracking * maxf(float(text.length() - 1), 0.0)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_play()


func _process(delta: float) -> void:
	_age += delta


func _play() -> void:
	var tween := create_tween()
	tween.tween_property(self, ^"_alpha", 1.0, T_FADE_IN)
	tween.tween_interval(T_HOLD)
	tween.tween_property(self, ^"_alpha", 0.0, T_FADE_OUT)
	await tween.finished
	_advance()


func _advance() -> void:
	if _advancing:
		return
	_advancing = true
	set_process_unhandled_input(false)
	Stage.go(NEXT_PATH)


func _unhandled_input(event: InputEvent) -> void:
	if _advancing or _age < SKIP_DEBOUNCE or not _is_skip(event):
		return
	get_viewport().set_input_as_handled()
	_advance()


## Any key and any click, not only the two menu actions: a player reaching for
## the keyboard to get past a splash does not aim.
func _is_skip(event: InputEvent) -> bool:
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"ui_cancel"):
		return true
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	return false


func _current_boxes() -> Dictionary:
	if _boxes.is_empty() or _boxes_for != size:
		_boxes = layout(size)
		_boxes_for = size
	return _boxes


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Design.INK)
	var use_font := Design.font()
	if use_font == null or _alpha <= 0.001:
		return
	var boxes := _current_boxes()
	if boxes.is_empty():
		return

	var rule := Design.GOLD
	rule.a *= _alpha
	draw_rect(boxes["Rule"], rule)

	# No drop shadow on this screen: the shadow colour is the background colour,
	# so drawing one would cost a second pass and show nothing.
	var ink := Design.CREAM
	ink.a *= _alpha
	var wordmark: Rect2 = boxes["Wordmark"]
	draw_string(
		use_font,
		wordmark.position + Vector2(0.0, use_font.get_ascent(WORDMARK_SIZE)),
		WORDMARK, HORIZONTAL_ALIGNMENT_LEFT, -1, WORDMARK_SIZE, ink
	)

	var sub := Design.GOLD
	sub.a *= _alpha * SUBTITLE_ALPHA
	var subtitle: Rect2 = boxes["Subtitle"]
	_draw_tracked(
		use_font,
		subtitle.position + Vector2(0.0, use_font.get_ascent(Design.FS_SMALL)),
		SUBTITLE, Design.FS_SMALL, sub, Design.TRACK_LABEL
	)


## draw_string carries no letter-spacing argument and the shared cached Font is
## the wrong place to set one, so tracked text is advanced a glyph at a time.
func _draw_tracked(
		use_font: Font, origin: Vector2, text: String, font_size: int,
		colour: Color, tracking: float
) -> void:
	var pen := origin.x
	for i in text.length():
		var glyph := text[i]
		draw_string(
			use_font, Vector2(pen, origin.y), glyph,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour
		)
		pen += use_font.get_string_size(
				glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + tracking
