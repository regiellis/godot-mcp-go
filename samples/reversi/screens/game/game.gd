extends Control

## The match screen: the turn loop, the panel that reports it, and the overlay
## it hands control to.
##
## The loop is deliberately a handful of flags rather than a state machine. A
## turn is `_turn` plus the move set recomputed from the board each pass, and
## `_busy` is the one input lock. Everything a state machine would formalise
## here already lives in [ReversiBoard], which is the only place the rules are.

const RESULT_SCENE := "res://screens/result/result.tscn"
const TITLE_SCENE := "res://screens/title/title.tscn"
const PAUSE_SCENE := "res://screens/pause/pause.tscn"
const SETTINGS_SCENE := "res://screens/settings/settings.tscn"
const HOW_TO_SCENE := "res://screens/how_to_play/how_to_play.tscn"

const TURN_BLACK := "BLACK TO MOVE"
const TURN_WHITE := "WHITE TO MOVE"
const TURN_THINKING := "COMPUTER THINKING"
const PASS_BLACK := "No legal move. Black passes."
const PASS_WHITE := "No legal move. White passes."
const CORNER_TOAST := "Corner taken."
const CENTRE_PASS := "PASS"
const NO_MOVE_TEXT := "-"

## Long enough for the readout to be read before the board moves again. HARD
## already spends about 56 ms of its own, so this is the whole of the pause.
const T_THINK_BEAT := 0.45

## One step of the thinking ellipsis.
const T_DOT := 0.35
const DOT_STEPS := 4

const T_CENTRE_HOLD := 1.2

## A flip toast on every move would push sixty of them through a five-slot
## layer. Reusing the cascade threshold keeps the toast for the moves that
## already earn a shake.
const TOAST_FLIP_FROM := 5

const CORNERS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(7, 7),
]


@onready var _board_view: BoardView = %Board
@onready var _camera: Camera2D = %Camera
@onready var _black_counter: JuiceCounter = %BlackCounter
@onready var _white_counter: JuiceCounter = %WhiteCounter
@onready var _turn_label: Label = %TurnLabel
@onready var _turn_glyph: Polygon2D = %TurnGlyph
@onready var _last_label: Label = %LastMoveLabel
@onready var _flip_label: Label = %FlipLabel
@onready var _strip: Control = %Strip
@onready var _hint_button: JuiceButton = %HintButton
@onready var _pause_button: JuiceButton = %PauseButton
@onready var _centre: Label = %CentreMessage

var _board := ReversiBoard.new()
var _turn: int = ReversiBoard.BLACK

## Vector2i -> Array[Vector2i], recomputed once per turn and reused for the
## hints, the click test and the AI.
var _moves: Dictionary = {}

var _busy := true
var _over := false
var _mode: int = Session.Mode.HOTSEAT
var _difficulty: int = ReversiAI.Level.NORMAL
var _human: int = ReversiBoard.BLACK
var _show_hints := true
var _pause: Node = null
var _sub_overlay: Node = null
var _last_cell: Vector2i = BoardView.NO_CELL
var _last_flips := 0
var _played: Array[int] = []
var _thinking := false
var _think_clock := 0.0
var _think_phase := -1

## The match rng is seeded from the session so a game replays. The hint button
## gets its own, or asking for a hint would shift every AI choice after it.
var _rng := RandomNumberGenerator.new()
var _hint_rng := RandomNumberGenerator.new()


func _ready() -> void:
	# The root would otherwise swallow every click before the board sees it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

	_read_session()
	_style_labels()
	_centre.pivot_offset = _centre.size * 0.5
	_centre.visible = false

	Juice.register_camera(_camera)
	Settings.changed.connect(_on_setting_changed)

	_board_view.cell_clicked.connect(_on_cell_clicked)
	_hint_button.pressed.connect(_on_hint_pressed)
	_pause_button.pressed.connect(_open_pause)

	_board_view.set_board(_board)
	_black_counter.snap_value(_board.score(ReversiBoard.BLACK))
	_white_counter.snap_value(_board.score(ReversiBoard.WHITE))
	Audio.play(&"start", -4.0)
	_begin_turn()


func _exit_tree() -> void:
	Juice.unregister_camera(_camera)
	# A screen that leaves while its own overlay is up would strand the tree
	# paused with nothing left to unpause it.
	if _pause != null:
		get_tree().paused = false


func _process(delta: float) -> void:
	if not _thinking:
		return
	_think_clock += delta
	var phase := int(_think_clock / T_DOT) % DOT_STEPS
	if phase == _think_phase:
		return
	_think_phase = phase
	_turn_label.text = TURN_THINKING + ".".repeat(phase)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_open_pause()
		get_viewport().set_input_as_handled()


# --- Setup ------------------------------------------------------------------


## An unconfigured session means two players. `seed_value` is the tell: only
## Session.configure() sets it, so a zero means nothing visited setup and this
## screen was opened on its own.
func _read_session() -> void:
	if Session.seed_value == 0:
		_mode = Session.Mode.HOTSEAT
		_human = ReversiBoard.BLACK
		_difficulty = ReversiAI.Level.NORMAL
		_rng.randomize()
	else:
		_mode = Session.mode
		_human = Session.human_player
		_difficulty = Session.difficulty
		_rng.seed = Session.seed_value
	_hint_rng.randomize()
	_show_hints = bool(Settings.get_value("game/show_hints", true))


func _style_labels() -> void:
	_style(_turn_label, Design.FS_H2, Design.CREAM)
	_style(_last_label, Design.FS_H2, Design.CREAM)
	_style(_flip_label, Design.FS_SMALL, Design.CREAM_MUTED)
	_style(_centre, Design.FS_HERO, Design.GOLD)


## Labels carry the same drawn look the widgets do: Bungee, cream, and the hard
## offset ink shadow, set here rather than in a Theme resource so the whole
## screen still reads from Design.
func _style(node: Label, font_size: int, tint: Color) -> void:
	node.add_theme_font_override(&"font", Design.font())
	node.add_theme_font_size_override(&"font_size", font_size)
	node.add_theme_color_override(&"font_color", tint)
	node.add_theme_color_override(&"font_shadow_color", Design.INK)
	node.add_theme_constant_override(&"shadow_offset_x", Design.shadow_for(font_size))
	node.add_theme_constant_override(&"shadow_offset_y", Design.shadow_for(font_size))
	node.add_theme_constant_override(&"shadow_outline_size", 0)


# --- The turn loop ----------------------------------------------------------


func _begin_turn() -> void:
	if _over:
		return
	_moves = _board.valid_moves(_turn)
	_refresh_panel()

	if _moves.is_empty():
		if _board.has_move(ReversiBoard.opponent(_turn)):
			_pass_turn()
		else:
			_finish()
		return

	if _is_cpu_turn():
		await _take_cpu_turn()
		return

	_busy = false
	_board_view.hints = _hint_cells()
	_board_view.interactive = true
	_board_view.queue_redraw()


func _take_cpu_turn() -> void:
	_busy = true
	_board_view.interactive = false
	_board_view.hints = []
	_start_thinking()
	# The readout has to be legible before the board moves, and the search
	# itself is too fast to supply that pause on its own.
	await get_tree().create_timer(T_THINK_BEAT).timeout
	if not is_inside_tree() or _over:
		return
	var cell := ReversiAI.choose(_board, _turn, _difficulty, _rng)
	_stop_thinking()
	if cell == ReversiAI.NO_MOVE:
		_pass_turn()
		return
	_apply(cell)


func _apply(cell: Vector2i) -> void:
	_busy = true
	_board_view.interactive = false
	_board_view.hints = []

	var player := _turn
	var flipped := _board.apply_move(cell, player)
	if flipped.is_empty():
		# Unreachable through the click test, but a no-op beats a stuck screen.
		_busy = false
		return

	_last_cell = cell
	_last_flips = flipped.size()
	_push_strip(player)
	_board_view.play_move(cell, player, flipped)
	_refresh_panel()

	if CORNERS.has(cell):
		Juice.toast(CORNER_TOAST, Design.GOLD)
	if flipped.size() >= TOAST_FLIP_FROM:
		Juice.toast("Flipped %d." % flipped.size(), Design.CYAN)

	await _board_view.animation_finished
	if not is_inside_tree() or _over:
		return
	_advance_turn()


func _advance_turn() -> void:
	if _board.is_over():
		_finish()
		return
	_turn = ReversiBoard.opponent(_turn)
	_begin_turn()


func _pass_turn() -> void:
	_busy = true
	_board_view.interactive = false
	_board_view.hints = []
	_stop_thinking()
	Juice.toast(PASS_BLACK if _turn == ReversiBoard.BLACK else PASS_WHITE, Design.CYAN)
	Audio.play(&"pass")
	await _show_centre(CENTRE_PASS)
	if not is_inside_tree() or _over:
		return
	_turn = ReversiBoard.opponent(_turn)
	_begin_turn()


func _finish() -> void:
	if _over:
		return
	_over = true
	_busy = true
	_thinking = false
	set_process(false)
	_board_view.interactive = false
	_board_view.hints = []

	var black := _board.score(ReversiBoard.BLACK)
	var white := _board.score(ReversiBoard.WHITE)
	var winner := ReversiBoard.EMPTY
	if black > white:
		winner = ReversiBoard.BLACK
	elif white > black:
		winner = ReversiBoard.WHITE

	Session.record_result({
		"winner": winner,
		"black": black,
		"white": white,
		"moves": _board.move_count(),
		"biggest_flip": _board.biggest_flip(),
	})

	if winner != ReversiBoard.EMPTY:
		var lost := _mode == Session.Mode.CPU and winner != _human
		Audio.play(&"lose" if lost else &"win")

	Stage.go(RESULT_SCENE)


func _restart() -> void:
	_over = false
	_busy = true
	_stop_thinking()
	_board.reset()
	_board_view.set_board(_board)
	_board_view.last_move = BoardView.NO_CELL
	_board_view.hints = []
	_black_counter.snap_value(_board.score(ReversiBoard.BLACK))
	_white_counter.snap_value(_board.score(ReversiBoard.WHITE))
	_last_cell = BoardView.NO_CELL
	_last_flips = 0
	_played.clear()
	_turn = ReversiBoard.BLACK
	_refresh_panel()
	Audio.play(&"start", -4.0)
	_begin_turn()


func _is_cpu_turn() -> bool:
	return _mode == Session.Mode.CPU and _turn != _human


func _hint_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not _show_hints:
		return cells
	for cell: Vector2i in _moves:
		cells.append(cell)
	return cells


func _start_thinking() -> void:
	_thinking = true
	_think_clock = 0.0
	_think_phase = -1
	_turn_label.text = TURN_THINKING
	set_process(true)


func _stop_thinking() -> void:
	_thinking = false
	set_process(false)


# --- Input ------------------------------------------------------------------


func _on_cell_clicked(cell: Vector2i) -> void:
	if _busy or _over or _pause != null:
		return
	if _is_cpu_turn():
		return
	if not _moves.has(cell):
		Audio.play(&"error", -4.0)
		return
	_apply(cell)


## Shows where the best move is. It never plays it: a hint that moves for you
## is the computer taking a turn on your behalf.
func _on_hint_pressed() -> void:
	if _busy or _over or _moves.is_empty():
		return
	var best := ReversiAI.choose(_board, _turn, ReversiAI.Level.NORMAL, _hint_rng)
	if best == ReversiAI.NO_MOVE:
		return
	_board_view.flash_hint(best)


func _on_setting_changed(key: String, value: Variant) -> void:
	if key != "game/show_hints":
		return
	_show_hints = bool(value)
	if not _busy and not _over:
		_board_view.hints = _hint_cells()
		_board_view.queue_redraw()


# --- Panel ------------------------------------------------------------------


func _refresh_panel() -> void:
	_black_counter.set_value(_board.score(ReversiBoard.BLACK))
	_white_counter.set_value(_board.score(ReversiBoard.WHITE))

	if not _thinking:
		_turn_label.text = TURN_BLACK if _turn == ReversiBoard.BLACK else TURN_WHITE
	_turn_glyph.color = Design.disc_colour(_turn)

	if _last_cell == BoardView.NO_CELL:
		_last_label.text = NO_MOVE_TEXT
		_flip_label.text = ""
	else:
		_last_label.text = _algebraic(_last_cell)
		_flip_label.text = "Flipped %d." % _last_flips

	_hint_button.disabled = _over or _is_cpu_turn()


## File a to h left to right, rank 1 to 8 top to bottom, so the notation reads
## the same way the board is drawn.
func _algebraic(cell: Vector2i) -> String:
	return "%s%d" % [String.chr(97 + cell.x), cell.y + 1]


## The strip holds the last sixteen movers, so the tail of the game is what is
## on screen rather than an unreadable sixty-square ribbon.
func _push_strip(player: int) -> void:
	_played.append(player)
	var slots := _strip.get_children()
	while _played.size() > slots.size():
		_played.remove_at(0)
	for i in slots.size():
		var slot := slots[i] as ColorRect
		if slot == null:
			continue
		slot.visible = i < _played.size()
		if slot.visible:
			slot.color = Design.disc_colour(_played[i])


func _show_centre(text: String) -> void:
	_centre.text = text
	_centre.visible = true
	_centre.modulate.a = 1.0
	JuiceTween.pop_in(_centre)
	await get_tree().create_timer(T_CENTRE_HOLD).timeout
	if not is_inside_tree():
		return
	JuiceTween.pop_out(_centre)
	await get_tree().create_timer(Design.T_POP_OUT).timeout
	if not is_inside_tree():
		return
	_centre.visible = false
	_centre.scale = Vector2.ONE


# --- Overlays ---------------------------------------------------------------


## Refused while the board is mid-cascade: pausing there would freeze a tween
## halfway and leave a disc stuck on its edge.
func _open_pause() -> void:
	if _pause != null or _over or _board_view.is_animating():
		return
	if Stage.is_transitioning():
		return
	if not ResourceLoader.exists(PAUSE_SCENE):
		push_error("game: %s is missing." % PAUSE_SCENE)
		return
	var packed: PackedScene = load(PAUSE_SCENE)
	_pause = packed.instantiate()
	add_child(_pause)
	_pause.resumed.connect(_close_pause)
	_pause.restart_requested.connect(_on_restart_requested)
	_pause.quit_requested.connect(_on_quit_requested)
	_pause.settings_requested.connect(_open_sub.bind(SETTINGS_SCENE))
	_pause.how_to_requested.connect(_open_sub.bind(HOW_TO_SCENE))
	get_tree().paused = true


func _close_pause() -> void:
	if _pause == null:
		return
	if _sub_overlay != null:
		_sub_overlay.queue_free()
		_sub_overlay = null
	get_tree().paused = false
	_pause.queue_free()
	_pause = null
	if not _busy and not _over:
		_board_view.interactive = true


func _on_restart_requested() -> void:
	_close_pause()
	_restart()


func _on_quit_requested() -> void:
	_close_pause()
	Stage.go(TITLE_SCENE)


## Settings and how-to-play run as further overlays on top of pause, so their
## own BACK ("closed") walks the player back the way they came instead of
## dropping them on the title screen.
##
## Parented to the screen rather than to pause: suspending pause hides it, and a
## child of a hidden node is hidden with it.
func _open_sub(path: String) -> void:
	if _sub_overlay != null or _pause == null:
		return
	if not ResourceLoader.exists(path):
		push_error("game: %s is missing." % path)
		return
	var packed: PackedScene = load(path)
	_sub_overlay = packed.instantiate()
	if not _sub_overlay.has_signal("closed"):
		push_error("game: %s has no `closed` signal to return from." % path)
		_sub_overlay.free()
		_sub_overlay = null
		return
	_sub_overlay.closed.connect(_close_sub)
	_sub_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	# Appended, so it lands after pause in the child order and draws over it.
	add_child(_sub_overlay)
	_pause.suspend(true)


func _close_sub() -> void:
	if _sub_overlay != null:
		_sub_overlay.queue_free()
		_sub_overlay = null
	if _pause != null:
		_pause.suspend(false)
	_show_hints = bool(Settings.get_value("game/show_hints", true))
