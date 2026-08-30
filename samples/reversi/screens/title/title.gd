extends Control

## The front door: type and the menu on the left, a game playing itself on the
## right.
##
## The attract board is the argument for keeping the rules and the opponent free
## of node dependencies. Nothing here knows how Reversi works: it hands a
## [ReversiBoard] to a [BoardView] and asks [ReversiAI] what to do next.
##
## Geometry is derived, not authored. [method layout] returns every box on the
## screen, [method _draw] paints the type from it, [method _apply_layout] moves
## the menu and the board onto it, and the builder audits the same dictionary.

const SETUP_PATH := "res://screens/setup/setup.tscn"
const HOW_TO_PLAY_PATH := "res://screens/how_to_play/how_to_play.tscn"
const SETTINGS_PATH := "res://screens/settings/settings.tscn"
const CREDITS_PATH := "res://screens/credits/credits.tscn"

const WORDMARK := "REVERSI"
const SUBTITLE := "A GODOT-MCP DEMO"

## The corner mark: the author on the first line, the repository on the second.
const FOOTER_LINES: PackedStringArray = [
	"Built with godot-mcp by Regi Ellis",
	"github.com/regiellis/godot-mcp-go",
]

## Quit is meaningless in a browser: SceneTree.quit() there kills the game and
## leaves a dead canvas with no way back. The button is removed on web rather
## than disabled, since a control that cannot work is worse than no control.
const MENU_ROWS_NATIVE := 5
const MENU_ROWS_WEB := 4

## The wordmark lifts by one SPACE_XS and settles, 2.2s each way. It rises
## rather than sinks because the subtitle is what sits below it, and the audit
## reads rest boxes here the same way it does for a button that grows on hover.
const WORDMARK_LIFT := Design.SPACE_XS
const T_BREATHE := 2.2

## 960px of board drawn at 595px, which is as large as the right column takes
## without crowding the page margin.
const ATTRACT_SCALE := 0.62

## The attract match runs EASY on both sides. A stronger level trades the board
## down early and the title would spend most of its time on a quiet position.
const ATTRACT_MOVE_INTERVAL := 1.1
const ATTRACT_RESET_HOLD := 2.0

@onready var _menu: JuiceMenu = %Menu
@onready var _play_button: JuiceButton = %PlayButton
@onready var _how_to_play_button: JuiceButton = %HowToPlayButton
@onready var _settings_button: JuiceButton = %SettingsButton
@onready var _credits_button: JuiceButton = %CreditsButton
@onready var _quit_button: JuiceButton = %QuitButton
@onready var _attract_view: BoardView = %AttractBoard
@onready var _attract_timer: Timer = %AttractTimer

var _lift := 0.0:
	set(value):
		_lift = value
		queue_redraw()

var _attract_board: ReversiBoard = null
var _attract_player := ReversiBoard.BLACK
var _attract_over := false
var _rng := RandomNumberGenerator.new()

var _boxes: Dictionary = {}
var _boxes_for := Vector2.ZERO


## Every box on the screen, keyed by the name the audit reports it under.
static func layout(page: Vector2) -> Dictionary:
	var use_font := Design.font()
	if use_font == null or page.x <= 0.0 or page.y <= 0.0:
		return {}

	# The footer takes the bottom-left corner first, because it is anchored to
	# two page margins and has nothing to give. Whatever column is left above it
	# is what the type block gets to work in.
	var line_h := Design.text_height(FOOTER_LINES[0], page.x, Design.FS_SMALL)
	var footer_w := 0.0
	for line: String in FOOTER_LINES:
		footer_w = maxf(footer_w, use_font.get_string_size(
				line, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL).x)
	var rows := float(FOOTER_LINES.size())
	# One box for two lines: a footer is one element, and its lines sit on the
	# font's own leading rather than on the space ladder.
	var footer_h := line_h * rows + Design.SPACE_XS * (rows - 1.0)
	var footer_top := page.y - Design.MARGIN_PAGE - footer_h

	var wordmark_w := use_font.get_string_size(
			WORDMARK, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_HERO).x
	var wordmark_h := Design.text_height(WORDMARK, page.x, Design.FS_HERO)
	var subtitle_w := tracked_width(use_font, SUBTITLE, Design.FS_SMALL, Design.TRACK_LABEL)
	var subtitle_h := Design.text_height(SUBTITLE, page.x, Design.FS_SMALL)
	var menu_rows := MENU_ROWS_WEB if OS.has_feature("web") else MENU_ROWS_NATIVE
	var menu_h := Design.BUTTON_H * float(menu_rows) \
			+ Design.SPACE_MD * float(menu_rows - 1)

	var region_top := Design.MARGIN_PAGE
	var region_h := footer_top - Design.SPACE_XL - region_top
	var fixed := wordmark_h + Design.SPACE_SM + subtitle_h + menu_h
	var gap := _subtitle_gap(region_h - fixed)

	# Centred in that column as one group, so the three pieces stand or fall
	# together instead of each carrying an offset of its own.
	var y := region_top + (region_h - fixed - gap) * 0.5
	var column_x := Design.MARGIN_PAGE * 2.0

	var boxes := {}
	boxes["Wordmark"] = Rect2(column_x, y, wordmark_w, wordmark_h)
	y += wordmark_h + Design.SPACE_SM
	boxes["Subtitle"] = Rect2(column_x, y, subtitle_w, subtitle_h)
	y += subtitle_h + gap
	boxes["Menu"] = Rect2(column_x, y, Design.BUTTON_W, menu_h)
	# Aligned to the content column, not the page margin. The wordmark, the menu
	# and the footer reading off three different left edges is what makes a screen
	# look assembled rather than designed.
	boxes["Footer"] = Rect2(column_x, footer_top, footer_w, footer_h)

	# The board's own right edge lands two page margins in, balancing the 320px
	# the board geometry already carries on its left. The box is the framed
	# extent, which is what a reader sees, so the frame goes on both sides.
	var board := Design.BOARD_PX * ATTRACT_SCALE
	var frame := Design.FRAME_WIDTH * ATTRACT_SCALE
	boxes["AttractBoard"] = Rect2(
		page.x - Design.MARGIN_PAGE * 2.0 - board - frame,
		(page.y - board) * 0.5 - frame,
		board + frame * 2.0, board + frame * 2.0
	)
	return boxes


## Where the BoardView node goes. It draws the board at Design.BOARD_ORIGIN in
## its own space, so the scaled origin has to come back off the position or the
## board lands 198px right and 149px below the box it was given.
static func attract_origin(page: Vector2) -> Vector2:
	var boxes := layout(page)
	if boxes.is_empty():
		return Vector2.ZERO
	var frame: Rect2 = boxes["AttractBoard"]
	var inset := Vector2.ONE * Design.FRAME_WIDTH * ATTRACT_SCALE
	return frame.position + inset - Design.BOARD_ORIGIN * ATTRACT_SCALE


## The widest ladder step that still fits between the subtitle and the menu.
## The spec asks for SPACE_XXL and a 1440p column cannot pay it: the block's
## fixed parts take 947 of the 1008px the footer leaves, so the ladder is walked
## down until a step fits rather than a number being invented to suit.
static func _subtitle_gap(room: float) -> float:
	var ladder: Array[float] = [
		Design.SPACE_XXL, Design.SPACE_XL, Design.SPACE_LG, Design.SPACE_MD,
	]
	for step: float in ladder:
		if step <= room:
			return step
	return Design.SPACE_SM


## Width of a tracked run, which is wider than the string by one gap per join.
static func tracked_width(
		use_font: Font, text: String, font_size: int, tracking: float
) -> float:
	var width := use_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return width + tracking * maxf(float(text.length() - 1), 0.0)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_play_button.pressed.connect(_on_play_pressed)
	_how_to_play_button.pressed.connect(_on_how_to_play_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_credits_button.pressed.connect(_on_credits_pressed)
	if OS.has_feature("web"):
		# Removed rather than hidden: JuiceMenu deals in its JuiceButton children
		# and runs a focus ring over them, and a hidden child would still take a
		# turn in both.
		_quit_button.queue_free()
	else:
		_quit_button.pressed.connect(_on_quit_pressed)

	resized.connect(_apply_layout)
	_apply_layout()

	_rng.randomize()
	_attract_view.interactive = false
	_reset_attract()
	_attract_timer.one_shot = true
	_attract_timer.timeout.connect(_on_attract_tick)
	_attract_timer.start(ATTRACT_MOVE_INTERVAL)

	_menu.deal_in()
	_start_breathing()


## The timer is a child and dies with the screen, but stopping it here means a
## tick already queued for this frame cannot fire into a half-freed board.
func _exit_tree() -> void:
	if is_instance_valid(_attract_timer):
		_attract_timer.stop()


## The scene file carries these same numbers, written by the builder out of this
## same function. Re-applying them here is what moves the menu and the board
## when the window is another shape, instead of leaving them where 2560 by 1440
## put them.
func _apply_layout() -> void:
	_boxes = {}
	var boxes := _current_boxes()
	if boxes.is_empty():
		return
	var menu: Rect2 = boxes["Menu"]
	_menu.position = menu.position
	_menu.size = menu.size
	_attract_view.scale = Vector2.ONE * ATTRACT_SCALE
	_attract_view.position = attract_origin(size)
	queue_redraw()


func _current_boxes() -> Dictionary:
	if _boxes.is_empty() or _boxes_for != size:
		_boxes = layout(size)
		_boxes_for = size
	return _boxes


func _start_breathing() -> void:
	if not bool(Juice.enabled):
		return
	var tween := create_tween().set_loops()
	tween.tween_property(self, ^"_lift", WORDMARK_LIFT, T_BREATHE) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, ^"_lift", 0.0, T_BREATHE) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _reset_attract() -> void:
	# The attract game runs real moves through play_move, so without this the
	# title clicks and flips about once a second for as long as it is open.
	_attract_view.muted = true
	_attract_board = ReversiBoard.new()
	_attract_player = ReversiBoard.BLACK
	_attract_over = false
	# Cleared before the swap: snap() inside set_board rebuilds the discs but
	# leaves last_move alone, so the previous game's red ring would survive.
	_attract_view.last_move = BoardView.NO_CELL
	_attract_view.set_board(_attract_board)


## One tick is one move, one pass, or the pause after the game ends. Keeping the
## three on the same clock is what stops a finished game from restarting on the
## same frame it ended.
func _on_attract_tick() -> void:
	if _attract_over:
		_reset_attract()
		_attract_timer.start(ATTRACT_MOVE_INTERVAL)
		return

	if _attract_board.is_over():
		_attract_over = true
		_attract_timer.start(ATTRACT_RESET_HOLD)
		return

	if not _attract_board.has_move(_attract_player):
		_attract_player = ReversiBoard.opponent(_attract_player)
		_attract_timer.start(ATTRACT_MOVE_INTERVAL)
		return

	var cell := ReversiAI.choose(
			_attract_board, _attract_player, ReversiAI.Level.EASY, _rng)
	if cell != ReversiAI.NO_MOVE:
		var flipped := _attract_board.apply_move(cell, _attract_player)
		_attract_view.play_move(cell, _attract_player, flipped)
		_attract_player = ReversiBoard.opponent(_attract_player)
	_attract_timer.start(ATTRACT_MOVE_INTERVAL)


func _on_play_pressed() -> void:
	Stage.go(SETUP_PATH)


func _on_how_to_play_pressed() -> void:
	Stage.go(HOW_TO_PLAY_PATH)


func _on_settings_pressed() -> void:
	Stage.go(SETTINGS_PATH)


func _on_credits_pressed() -> void:
	Stage.go(CREDITS_PATH)


func _on_quit_pressed() -> void:
	get_tree().quit()


## The type is drawn by the screen root rather than carried on Label children,
## which is why the Backdrop child sets show_behind_parent: a parent draws
## before its children, so without it the bands would cover the wordmark.
func _draw() -> void:
	var use_font := Design.font()
	if use_font == null:
		return
	var boxes := _current_boxes()
	if boxes.is_empty():
		return

	var wordmark: Rect2 = boxes["Wordmark"]
	var pen := wordmark.position \
			+ Vector2(0.0, use_font.get_ascent(Design.FS_HERO) - _lift)
	var shadow := Vector2.ONE * float(Design.shadow_for(Design.FS_HERO))
	draw_string(
		use_font, pen + shadow, WORDMARK,
		HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_HERO, Design.INK
	)
	draw_string(
		use_font, pen, WORDMARK,
		HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_HERO, Design.CREAM
	)

	var subtitle: Rect2 = boxes["Subtitle"]
	_draw_tracked(
		use_font,
		subtitle.position + Vector2(0.0, use_font.get_ascent(Design.FS_SMALL)),
		SUBTITLE, Design.FS_SMALL, Design.GOLD, Design.TRACK_LABEL
	)

	_draw_footer(use_font, boxes["Footer"])


## The repository line takes the CYAN of a link at the alpha of the line above
## it, so the two read as one mark rather than as a note and a link.
func _draw_footer(use_font: Font, footer: Rect2) -> void:
	var line_h := Design.text_height(FOOTER_LINES[0], size.x, Design.FS_SMALL)
	var link := Design.CYAN
	link.a = Design.CREAM_FAINT.a
	for i in FOOTER_LINES.size():
		var origin := footer.position + Vector2(
			0.0,
			float(i) * (line_h + Design.SPACE_XS) + use_font.get_ascent(Design.FS_SMALL)
		)
		draw_string(
			use_font, origin, FOOTER_LINES[i], HORIZONTAL_ALIGNMENT_LEFT, -1,
			Design.FS_SMALL, Design.CREAM_FAINT if i == 0 else link
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
