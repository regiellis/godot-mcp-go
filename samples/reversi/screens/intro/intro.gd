extends Control

## Three cards, then the title.
##
## Same flat [constant Design.INK] as splash, so the two read as one held breath
## rather than as two screens. The last card writes `game/seen_intro`, which is
## what sends a returning player straight past both.

const NEXT_PATH := "res://screens/title/title.tscn"

const CARD_ONE := "This is a demo for godot-mcp."

const CARD_TWO := """An agent built it by driving the Godot editor over a local WebSocket:
the scenes, the scripts, the interface, and the rules underneath."""

const CARD_THREE := """Reversi, on eight by eight.
Outflank a line to flip it."""

const CARDS: PackedStringArray = [CARD_ONE, CARD_TWO, CARD_THREE]

const HINT := "Press any key to skip"

const T_FADE := 0.6
const T_HOLD := 2.6

## Input is dead this long after the screen appears, so a key still held from
## the splash cannot skip the intro before its first card is readable.
const SKIP_DEBOUNCE := 0.35

const HINT_DELAY := 1.2
const HINT_FADE := 0.5

## Card two is the long one and it drops a step down the type scale rather than
## running wider than the column.
const LONG_CARD := 1

var _index := 0
var _age := 0.0

var _card_alpha := 0.0:
	set(value):
		_card_alpha = value
		queue_redraw()

var _hint_alpha := 0.0:
	set(value):
		_hint_alpha = value
		queue_redraw()

## The one flag the card sequence and the skip both check. Without it a skip
## landing as a card ends would change scene twice.
var _advancing := false

var _boxes: Dictionary = {}
var _boxes_for := Vector2.ZERO


## The wrap width for a card. Card two's first line measures 1682px at FS_BODY,
## so a narrower column drops "WebSocket:" onto a line of its own and breaks the
## two lines the copy was written with.
static func column_width(page: Vector2) -> float:
	return page.x - Design.MARGIN_PAGE * 2.0 - Design.SPACE_XXL * 2.0


static func card_font_size(index: int) -> int:
	return Design.FS_BODY if index == LONG_CARD else Design.FS_H2


## The box a card occupies once wrapped: as wide as its widest line, as tall as
## the lines it actually took, centred on the page.
static func card_box(page: Vector2, index: int) -> Rect2:
	var use_font := Design.font()
	if use_font == null or index < 0 or index >= CARDS.size():
		return Rect2()
	var font_size := card_font_size(index)
	var block := use_font.get_multiline_string_size(
			CARDS[index], HORIZONTAL_ALIGNMENT_CENTER, column_width(page), font_size)
	return Rect2(
		(page.x - block.x) * 0.5, (page.y - block.y) * 0.5, block.x, block.y
	)


## One box for the card region and one for the hint. The three cards share an
## axis and only ever one is on screen, so they are audited as the one region
## they reserve: the widest card by the tallest card, centred.
static func layout(page: Vector2) -> Dictionary:
	var use_font := Design.font()
	if use_font == null or page.x <= 0.0 or page.y <= 0.0:
		return {}

	var widest := 0.0
	var tallest := 0.0
	for i in CARDS.size():
		var box := card_box(page, i)
		widest = maxf(widest, box.size.x)
		tallest = maxf(tallest, box.size.y)

	var hint_w := use_font.get_string_size(
			HINT, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL).x
	var hint_h := Design.text_height(HINT, page.x, Design.FS_SMALL)

	var boxes := {}
	boxes["Card"] = Rect2(
		(page.x - widest) * 0.5, (page.y - tallest) * 0.5, widest, tallest
	)
	boxes["SkipHint"] = Rect2(
		(page.x - hint_w) * 0.5, page.y - Design.MARGIN_PAGE - hint_h, hint_w, hint_h
	)
	return boxes


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_tween := create_tween()
	hint_tween.tween_property(self, ^"_hint_alpha", 1.0, HINT_FADE).set_delay(HINT_DELAY)
	_play()


func _process(delta: float) -> void:
	_age += delta


func _play() -> void:
	for i in CARDS.size():
		if _advancing:
			return
		_index = i
		_card_alpha = 0.0
		var tween := create_tween()
		tween.tween_property(self, ^"_card_alpha", 1.0, T_FADE)
		tween.tween_interval(T_HOLD)
		tween.tween_property(self, ^"_card_alpha", 0.0, T_FADE)
		await tween.finished
	_advance()


func _advance() -> void:
	if _advancing:
		return
	_advancing = true
	set_process_unhandled_input(false)
	# Written whether the player watched the cards or skipped them: either way
	# they have been offered, and offering them twice is the annoyance.
	Settings.set_value("game/seen_intro", true)
	Stage.go(NEXT_PATH)


func _unhandled_input(event: InputEvent) -> void:
	if _advancing or _age < SKIP_DEBOUNCE or not _is_skip(event):
		return
	get_viewport().set_input_as_handled()
	_advance()


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
	if use_font == null:
		return
	_draw_card(use_font)
	_draw_hint(use_font)


func _draw_card(use_font: Font) -> void:
	if _card_alpha <= 0.001 or _index < 0 or _index >= CARDS.size():
		return
	var box := card_box(size, _index)
	if box.size.y <= 0.0:
		return
	var font_size := card_font_size(_index)
	var ink := Design.CREAM
	ink.a *= _card_alpha
	# The card is drawn into the full column so the engine centres each line the
	# same way it measured them; the box only says where that column sits.
	var column := column_width(size)
	draw_multiline_string(
		use_font,
		Vector2((size.x - column) * 0.5, box.position.y + use_font.get_ascent(font_size)),
		CARDS[_index], HORIZONTAL_ALIGNMENT_CENTER, column, font_size, -1, ink
	)


func _draw_hint(use_font: Font) -> void:
	if _hint_alpha <= 0.001:
		return
	var boxes := _current_boxes()
	if boxes.is_empty():
		return
	var colour := Design.CREAM_FAINT
	colour.a *= _hint_alpha
	var hint: Rect2 = boxes["SkipHint"]
	draw_string(
		use_font, hint.position + Vector2(0.0, use_font.get_ascent(Design.FS_SMALL)),
		HINT, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL, colour
	)
