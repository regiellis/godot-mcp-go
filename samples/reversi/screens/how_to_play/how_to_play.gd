extends Control

## The rules, five cards, each beside the position its paragraph describes.
##
## Reached two ways, exactly as `settings` is: from the title as a full screen
## through Stage.go, and from the pause menu as an instanced overlay child of a
## paused game. The screen works out which on entry and needs nothing from the
## caller either way.
##
## Every box comes out of `layout()`, which measures each paragraph at the width
## it will wrap to and sizes its card from that. The builder audits the same
## numbers before it saves, so text past a card edge is a build failure.

## Emitted by BACK. A pause menu connects this and frees the overlay. With
## nothing connected the screen falls back to Stage.
signal closed()

const TITLE_SCENE := "res://screens/title/title.tscn"

## Set by a caller that already knows it is opening an overlay. Left false, the
## screen still works it out from the scene tree.
@export var overlay: bool = false

## The design box. `canvas_items` stretch fits it to the player's window.
const PAGE := Vector2(2560.0, 1440.0)

const SCRIM_ALPHA := 0.72
const HEADING := "HOW TO PLAY"

## The mini board beside a paragraph: four files by four ranks at 60px a cell.
const DIAGRAM_SIZE := 4
const DIAGRAM_CELL := 60.0

## Card copy runs at FS_SMALL, not the FS_BODY the rest of the game uses for
## body text. At FS_BODY the second paragraph wraps to 318px in a 732px text
## column, which makes its card taller than the diagram and pushes the pair of
## left-hand cards through the BACK button. Measured, not guessed.
const CARD_FS := Design.FS_SMALL

## Cards one and two fill the left column and the rest the right. BACK sits
## bottom-left, so only the left column has to stop short of it.
const COLUMN_SPLIT := 2

const BLANK: Array[int] = []

## The board positions each paragraph is about. Card one comes from
## ReversiBoard, because "the opening, and where black may play" is a question
## the rules already answer. The rest are contrived positions no real opening
## reaches, so they are written out.
##
## Cell values match ReversiBoard: 0 empty, 1 black, 2 white. Index is y * 4 + x.
const LAYOUT_OUTFLANK: Array[int] = [
	0, 0, 0, 0,
	1, 2, 2, 0,
	0, 0, 0, 2,
	0, 0, 0, 1,
]
const HINTS_OUTFLANK: Array[int] = [7]

## The same position after black plays the hinted cell: three discs turned over,
## in two directions from the one move.
const LAYOUT_FLIPPED: Array[int] = [
	0, 0, 0, 0,
	1, 1, 1, 1,
	0, 0, 0, 1,
	0, 0, 0, 1,
]

## A finished board. Nothing is empty, so neither side has a move and the count
## decides it: eleven to five.
const LAYOUT_FINISHED: Array[int] = [
	1, 1, 1, 2,
	1, 1, 2, 2,
	1, 1, 1, 2,
	1, 1, 1, 2,
]

## Copy is verbatim from the deck, one entry per card. The deck wraps a
## paragraph across two lines for reading; here each is one string and the
## renderer wraps it to the card, so the only difference is the newline.
const CARD_TEXT: Array[String] = [
	"Black moves first. A move must outflank at least one white disc.",
	"Outflanking means placing a disc so that a straight line of the opponent's discs, "
	+ "with no gaps, ends on a disc of your own. It works in all eight directions.",
	"Every disc you outflank flips to your colour. A move that flips nothing is not legal.",
	"With no legal move, a player passes and the turn goes back. When neither player can "
	+ "move, the game ends and the larger count wins.",
	"Corners cannot be flipped once taken, which is why they are worth more than the "
	+ "count on the board says.",
]

@onready var _backdrop: Backdrop = %Backdrop
@onready var _scrim: ColorRect = %Scrim
@onready var _back: JuiceButton = %BackButton

var _overlay_mode := false
var _ink: Ink = null
var _cards: Array[JuicePanel] = []


## Every box on the screen, derived rather than authored. Static and free of the
## scene tree so the builder script can audit the numbers the screen draws.
##
## Returns `heading` and `back` as Rect2, and `cards` as one entry per card
## carrying the card rect, the diagram rect (zero-sized when the card has none)
## and the text rect the paragraph occupies once wrapped.
static func layout() -> Dictionary:
	var face := Design.font()
	var heading_h := face.get_height(Design.FS_H1)
	var heading_w := face.get_string_size(
		HEADING, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1
	).x

	var column_w := (PAGE.x - Design.MARGIN_PAGE * 2.0 - Design.SPACE_LG) / 2.0
	var diagram := DIAGRAM_CELL * float(DIAGRAM_SIZE)
	var top := Design.MARGIN_PAGE + heading_h + Design.SPACE_XL
	var cursor: Array[float] = [top, top]
	var cards: Array[Dictionary] = []

	for i in CARD_TEXT.size():
		var has_diagram := i < CARD_TEXT.size() - 1
		var column := 0 if i < COLUMN_SPLIT else 1
		var x := Design.MARGIN_PAGE + (column_w + Design.SPACE_LG) * float(column)
		var y: float = cursor[column]
		var text_x := Design.PAD_PANEL
		if has_diagram:
			text_x += diagram + Design.SPACE_LG
		var text_w := column_w - text_x - Design.PAD_PANEL
		var body := CARD_TEXT[i]
		var text_h := Design.text_height(body, text_w, CARD_FS)
		# The card is as tall as whichever of its two contents is taller, plus
		# the panel padding. Forcing a fixed height is what ran text past the
		# card edge on the first pass.
		var content_h := maxf(text_h, diagram if has_diagram else 0.0)
		var card := Rect2(x, y, column_w, content_h + Design.PAD_PANEL * 2.0)
		var board := Rect2()
		if has_diagram:
			board = Rect2(
				x + Design.PAD_PANEL,
				y + Design.PAD_PANEL + (content_h - diagram) * 0.5,
				diagram, diagram
			)
		cards.append({
			"text": body,
			"rect": card,
			"board": board,
			"text_rect": Rect2(
				x + text_x,
				y + Design.PAD_PANEL + (content_h - text_h) * 0.5,
				text_w, text_h
			),
		})
		cursor[column] = card.end.y + Design.SPACE_LG

	return {
		"heading": Rect2(
			Design.MARGIN_PAGE, Design.MARGIN_PAGE, heading_w, heading_h
		),
		"cards": cards,
		"back": Rect2(
			Design.MARGIN_PAGE,
			PAGE.y - Design.MARGIN_PAGE - Design.BUTTON_H,
			Design.BUTTON_W,
			Design.BUTTON_H
		),
	}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_mode = _resolve_overlay()
	var plan := layout()

	_backdrop.accent = Design.CYAN
	_backdrop.visible = not _overlay_mode
	# A parent CanvasItem paints before its children, so index 0 alone would
	# still put the bands over anything drawn above them.
	_backdrop.show_behind_parent = true

	var shade := Design.INK
	shade.a = SCRIM_ALPHA
	_scrim.color = shade
	_scrim.visible = _overlay_mode
	_scrim.mouse_filter = (
		Control.MOUSE_FILTER_STOP if _overlay_mode else Control.MOUSE_FILTER_IGNORE
	)

	var back_rect: Rect2 = plan["back"]
	_back.position = back_rect.position
	_back.size = back_rect.size
	_back.text = "BACK"
	_back.accent = Design.CYAN
	_back.intro_style = JuiceButton.IntroStyle.RISE
	_back.pressed.connect(_on_back_pressed)

	_build_cards(plan)
	# Ink paints over the cards, and BACK over everything, so the three go into
	# the tree in that order. A CanvasItem paints itself before its children,
	# which is why the card text cannot live on the card.
	move_child(_ink, get_child_count() - 1)
	move_child(_back, get_child_count() - 1)

	_back.play_intro(0.24)
	_back.call_deferred(&"grab_focus")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_on_back_pressed()


## Overlay when a caller said so, or when this screen is not the scene the tree
## is currently running. Stage.go assigns current_scene before the node enters
## the tree, so the second test is settled by the time _ready runs.
func _resolve_overlay() -> bool:
	if overlay:
		return true
	return get_tree().current_scene != self


func _build_cards(plan: Dictionary) -> void:
	var boards := _diagrams()
	var painted: Array = []
	var cards: Array = plan["cards"]
	for i in cards.size():
		var spec: Dictionary = cards[i]
		var rect: Rect2 = spec["rect"]
		var card := JuicePanel.new()
		card.name = "Card%d" % (i + 1)
		card.position = rect.position
		card.size = rect.size
		card.accent = Design.CYAN
		add_child(card)
		card.pop_in(float(i) * Design.T_MENU_STAGGER)
		_cards.append(card)

		var diagram: Dictionary = boards[i]
		painted.append({
			"text": spec["text"],
			"text_rect": spec["text_rect"],
			"board": spec["board"],
			"layout": diagram["layout"],
			"hints": diagram["hints"],
		})

	_ink = Ink.new()
	_ink.name = "Ink"
	_ink.heading = HEADING
	_ink.heading_rect = plan["heading"]
	_ink.font_size = CARD_FS
	_ink.grid = DIAGRAM_SIZE
	_ink.cards = painted
	add_child(_ink)


func _diagrams() -> Array[Dictionary]:
	var opening := _opening_window()
	return [
		{"layout": opening["layout"], "hints": opening["hints"]},
		{"layout": LAYOUT_OUTFLANK, "hints": HINTS_OUTFLANK},
		{"layout": LAYOUT_FLIPPED, "hints": BLANK},
		{"layout": LAYOUT_FINISHED, "hints": BLANK},
		{"layout": BLANK, "hints": BLANK},
	]


## The middle four files and ranks of a real opening board, with black's legal
## moves marked. Read out of ReversiBoard rather than typed, so the diagram
## cannot drift from the rules the game actually plays by.
func _opening_window() -> Dictionary:
	const OFFSET := Vector2i(2, 2)
	var board := ReversiBoard.new()
	var layout: Array[int] = []
	layout.resize(DIAGRAM_SIZE * DIAGRAM_SIZE)
	for y in DIAGRAM_SIZE:
		for x in DIAGRAM_SIZE:
			layout[y * DIAGRAM_SIZE + x] = board.get_cell(Vector2i(x, y) + OFFSET)
	var hints: Array[int] = []
	for cell: Vector2i in board.valid_moves(ReversiBoard.BLACK):
		var local := cell - OFFSET
		if local.x < 0 or local.x >= DIAGRAM_SIZE:
			continue
		if local.y < 0 or local.y >= DIAGRAM_SIZE:
			continue
		hints.append(local.y * DIAGRAM_SIZE + local.x)
	return {"layout": layout, "hints": hints}


func _on_back_pressed() -> void:
	# Emitted before the fallback so the two routes cannot both fire: a pause
	# menu that connected `closed` owns the exit, and Stage never hears about it.
	var listening := not closed.get_connections().is_empty()
	closed.emit()
	if not listening:
		Stage.go(TITLE_SCENE)


## The flat layer: the heading, the four board diagrams, and the five
## paragraphs. Everything a card shows is painted here rather than on the card,
## because a CanvasItem paints itself before its children.
class Ink extends Control:
	const DISC_RATIO := 0.40 ## The board's own disc-to-cell ratio.
	const HINT_RATIO := 0.17
	const DIAGRAM_FRAME := 6.0
	const DISC_OUTLINE := 3.0
	const GRID_WIDTH := 2.0

	var heading: String = ""
	var heading_rect := Rect2()
	var cards: Array = []

	## Handed down from the screen rather than restated, so the size the text is
	## measured at and the size it is drawn at cannot drift apart.
	var font_size: int = Design.FS_SMALL
	var grid: int = 4

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		var face := Design.font()
		if face == null:
			return
		var baseline := heading_rect.position + Vector2(
			0.0, face.get_ascent(Design.FS_H1)
		)
		draw_string(
			face, baseline + Vector2.ONE * Design.SPACE_XS, heading,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1, Design.INK
		)
		draw_string(
			face, baseline, heading,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1, Design.CREAM
		)
		for card: Dictionary in cards:
			_draw_card(face, card)

	func _draw_card(face: Font, card: Dictionary) -> void:
		var board: Rect2 = card["board"]
		if board.size.x > 0.0:
			_draw_diagram(board, card["layout"], card["hints"])
		var text_rect: Rect2 = card["text_rect"]
		draw_multiline_string(
			face,
			text_rect.position + Vector2(0.0, face.get_ascent(font_size)),
			String(card["text"]), HORIZONTAL_ALIGNMENT_LEFT, text_rect.size.x,
			font_size, -1, Design.CREAM
		)

	## A 4 by 4 window on a board, in the felt and disc colours the real board
	## uses, so a diagram and the game read as the same object.
	func _draw_diagram(field: Rect2, layout: Array, hints: Array) -> void:
		var cell := field.size.x / float(grid)
		draw_rect(field.grow(DIAGRAM_FRAME), Design.FELT_EDGE)
		draw_rect(field, Design.FELT)
		for i in range(1, grid):
			var step := float(i) * cell
			draw_line(
				field.position + Vector2(step, 0.0),
				field.position + Vector2(step, field.size.y),
				Design.FELT_LINE, GRID_WIDTH
			)
			draw_line(
				field.position + Vector2(0.0, step),
				field.position + Vector2(field.size.x, step),
				Design.FELT_LINE, GRID_WIDTH
			)

		for index in layout.size():
			var player: int = layout[index]
			if player == 0:
				continue
			var centre := _cell_centre(field, cell, index)
			draw_circle(centre, cell * DISC_RATIO, Design.disc_colour(player))
			draw_arc(
				centre, cell * DISC_RATIO, 0.0, TAU, 32,
				Design.DISC_EDGE, DISC_OUTLINE
			)

		for index: int in hints:
			draw_circle(_cell_centre(field, cell, index), cell * HINT_RATIO, Design.HINT)

	func _cell_centre(field: Rect2, cell: float, index: int) -> Vector2:
		return field.position + Vector2(
			(float(index % grid) + 0.5) * cell,
			(float(floori(float(index) / float(grid))) + 0.5) * cell
		)
