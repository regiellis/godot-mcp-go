class_name BoardView
extends Node2D

## Draws a [ReversiBoard] and reports clicks on it.
##
## It owns no rules. Every legality question goes back to the board it was
## handed, and the screen above decides what a click means. What lives here is
## purely presentation: where a cell sits in pixels, and how a disc looks while
## it is turning over.
##
## Per-disc render state is a Dictionary keyed by cell index rather than a node
## per square, because 64 nodes with 64 tweens is a lot of machinery for what is
## one [method _draw] and a handful of floats.

signal cell_clicked(cell: Vector2i)
signal animation_finished

const NO_CELL := Vector2i(-1, -1)

const GRID_WIDTH := 2.0
const STAR_RADIUS := Design.SPACE_XS

## Star points sit on the grid intersections two cells in from each corner, the
## same four an Othello board is printed with.
const STAR_POINTS: Array[Vector2i] = [
	Vector2i(2, 2), Vector2i(2, 6), Vector2i(6, 2), Vector2i(6, 6),
]

const DISC_EDGE_WIDTH := 4.0
const HIGHLIGHT_WIDTH := 2.0
const HIGHLIGHT_SCALE := 0.66 ## Of the disc radius. Inside the edge, not on it.

## Solved against the cell rather than doubled blind. The ring's outer edge sits
## at DISC_RADIUS + LAST_RING_PAD + LAST_RING_WIDTH * 0.5 = 59, inside the 60px
## half-cell. Doubling the first pass's 5 would have bled into the next square.
const LAST_RING_PAD := Design.SPACE_XS
const LAST_RING_WIDTH := 6.0

const HOVER_WIDTH := 4.0
const HOVER_ALPHA := 0.22
const HOVER_LEGAL_ALPHA := 0.55

## At the 1440p radii a 40-segment circle showed its chords, which reads as a
## defect rather than as a style.
const RING_SEGMENTS := 64

## A flip squashed all the way to nothing blinks out for a frame in the middle
## of the turn, so the pinch stops just short of flat.
const MIN_SCALE_X := 0.02

## The cascade waits until the placed disc has most of its size, so the flips
## read as a consequence of the placement rather than as part of it.
const FLIP_LEAD := Design.T_DISC_DROP * 0.6

## Pitch across one cascade. Rising rather than random, so a long chain reads as
## a run of notes instead of a rattle.
const FLIP_PITCH_LOW := 0.94
const FLIP_PITCH_HIGH := 1.12

## Flips at or above this earn the heavy shake and the hitstop. Five is where a
## capture stops being routine on an eight by eight board.
const BIG_CASCADE := 5

const HINT_FLASH_TIME := 1.2
const HINT_FLASH_PULSES := 3.0
## Bounded by the cell, not by the first pass's proportion. At SPACE_SM the
## flash ring reached 67px out and lapped the neighbouring square; SPACE_XS puts
## its outer edge at 59, inside the 60px half-cell, the same stop the last-move
## ring takes.
const HINT_RING_PAD := Design.SPACE_XS
const HINT_RING_WIDTH := 6.0

## The legal-move marker's outer ring: how far clear of the fill it sits, and
## how heavily it draws.
const LEGAL_RING_GAP := 6.0
const LEGAL_RING_WIDTH := 4.0

var board: ReversiBoard = null

## Silences the sounds and the impact this view asks for. The title screen runs
## an attract game through [method play_move] on a loop, and a board that is
## scenery must not click and shake behind a menu.
@export var muted: bool = false

## Cells to mark as legal. The screen decides whether to fill this, since the
## setting that hides hints is not the board's business.
var hints: Array[Vector2i] = []

var last_move: Vector2i = NO_CELL:
	set(value):
		last_move = value
		queue_redraw()

## False for the whole of an animation, and while the other side is thinking.
var interactive: bool = true:
	set(value):
		interactive = value
		if not value:
			_hover = NO_CELL
		queue_redraw()

# index -> {scale_x: float, player: int, drop: float}
var _discs: Dictionary = {}
var _hover: Vector2i = NO_CELL
var _tween: Tween = null
var _hint_cell: Vector2i = NO_CELL

var _hint_pulse: float = 0.0:
	set(value):
		_hint_pulse = value
		queue_redraw()


func _ready() -> void:
	set_process_unhandled_input(true)


## Adopts [param new_board] and redraws it at rest. Named `new_board` rather
## than `board` so the parameter does not shadow the member it assigns.
func set_board(new_board: ReversiBoard) -> void:
	board = new_board
	snap()


## Drops every scrap of animation state and redraws the board as it stands.
func snap() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_discs.clear()
	_hint_cell = NO_CELL
	_hint_pulse = 0.0
	if board != null:
		for index in ReversiBoard.CELL_COUNT:
			var value := int(board.cells[index])
			if value != ReversiBoard.EMPTY:
				_discs[index] = {"scale_x": 1.0, "player": value, "drop": 1.0}
	queue_redraw()


func is_animating() -> bool:
	return _tween != null and _tween.is_valid()


## Plays the placement and the cascade it caused. The board is expected to have
## been mutated already: this renders what happened, it does not decide it.
func play_move(cell: Vector2i, player: int, flipped: Array[Vector2i]) -> void:
	interactive = false
	last_move = cell
	hints = []
	_hint_cell = NO_CELL

	if _tween != null and _tween.is_valid():
		_tween.kill()

	var key := _key(cell)
	_discs[key] = {"scale_x": 1.0, "player": player, "drop": 0.0}
	queue_redraw()

	_play(&"confirm", -3.0)

	# Sorted outward so the pitch rises with the distance travelled, which is
	# what makes a long chain sound like one gesture.
	var order := flipped.duplicate()
	order.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return _distance(cell, a) < _distance(cell, b)
	)

	_tween = create_tween().set_parallel(true)
	_tween.tween_method(
		_drop_setter(key), 0.0, 1.0, Design.T_DISC_DROP
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	var big := order.size() >= BIG_CASCADE
	_tween.tween_callback(_impact.bind(big)).set_delay(Design.T_DISC_DROP * 0.5)

	var span := maxf(float(order.size() - 1), 1.0)
	for i in order.size():
		var target: Vector2i = order[i]
		var delay := FLIP_LEAD + Design.T_FLIP_STAGGER * float(_distance(cell, target))
		var pitch := lerpf(FLIP_PITCH_LOW, FLIP_PITCH_HIGH, float(i) / span)
		_queue_flip(_key(target), player, delay, pitch)

	_tween.finished.connect(_on_move_finished, CONNECT_ONE_SHOT)


## Pulses a ring on [param cell] without touching the board. What the HINT
## button shows: where the move is, not the move itself.
func flash_hint(cell: Vector2i) -> void:
	if not Design.in_bounds(cell):
		return
	_hint_cell = cell
	_hint_pulse = 0.0
	if not is_inside_tree():
		return
	var pulse := create_tween()
	pulse.tween_property(self, ^"_hint_pulse", 1.0, HINT_FLASH_TIME)
	pulse.tween_callback(_clear_hint)


func _clear_hint() -> void:
	_hint_cell = NO_CELL
	_hint_pulse = 0.0


func _key(cell: Vector2i) -> int:
	return cell.y * Design.SIZE + cell.x


## Chebyshev distance: a ring of cells one step out from the placement all flip
## together, which is what makes the cascade read as spreading.
func _distance(from: Vector2i, to: Vector2i) -> int:
	return maxi(absi(to.x - from.x), absi(to.y - from.y))


func _drop_setter(key: int) -> Callable:
	return func(value: float) -> void:
		if _discs.has(key):
			_discs[key]["drop"] = value
			queue_redraw()


func _scale_setter(key: int) -> Callable:
	return func(value: float) -> void:
		if _discs.has(key):
			_discs[key]["scale_x"] = value
			queue_redraw()


## Three tweeners per disc: squash flat, switch colour at the pinch, open out.
## The colour change has to land exactly where the disc has no width, or the
## turn reads as a colour swap rather than as a rotation.
func _queue_flip(key: int, player: int, delay: float, pitch: float) -> void:
	var setter := _scale_setter(key)
	_tween.tween_method(setter, 1.0, MIN_SCALE_X, Design.T_FLIP_HALF) \
			.set_delay(delay).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_turn_disc.bind(key, player, pitch)) \
			.set_delay(delay + Design.T_FLIP_HALF)
	_tween.tween_method(setter, MIN_SCALE_X, 1.0, Design.T_FLIP_HALF) \
			.set_delay(delay + Design.T_FLIP_HALF) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _turn_disc(key: int, player: int, pitch: float) -> void:
	if _discs.has(key):
		_discs[key]["player"] = player
		queue_redraw()
	_play_pitched(&"flip", pitch)


func _impact(big: bool) -> void:
	if muted:
		return
	var juice := get_node_or_null(^"/root/Juice")
	if juice == null:
		return
	juice.shake(0.55 if big else 0.30)
	if big:
		juice.hitstop(0.07)


func _on_move_finished() -> void:
	_tween = null
	animation_finished.emit()


func _play(bank: StringName, volume_offset_db: float) -> void:
	if muted:
		return
	var audio := get_node_or_null(^"/root/Audio")
	if audio != null:
		audio.play(bank, volume_offset_db)


func _play_pitched(bank: StringName, pitch: float) -> void:
	if muted:
		return
	var audio := get_node_or_null(^"/root/Audio")
	if audio != null:
		audio.play_pitched(bank, pitch)


## A Node2D has no _gui_input, so clicks come in here. The event position goes
## through this node's own transform, which is what lets the title screen scale
## an attract board down without doing any of the maths itself.
func _unhandled_input(event: InputEvent) -> void:
	if not interactive or not is_visible_in_tree():
		return
	if event is InputEventMouseMotion:
		var moved := Design.cell_at(_to_board((event as InputEventMouseMotion).position))
		if moved != _hover:
			_hover = moved
			queue_redraw()
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	var cell := Design.cell_at(_to_board(button.position))
	if cell == NO_CELL:
		return
	get_viewport().set_input_as_handled()
	cell_clicked.emit(cell)


func _to_board(point: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * point


func _draw() -> void:
	_draw_frame()
	_draw_grid()
	_draw_hints()
	_draw_last_ring()
	_draw_discs()
	_draw_hover()
	_draw_hint_flash()


func _draw_frame() -> void:
	var outer := Rect2(
		Design.BOARD_ORIGIN - Vector2.ONE * Design.FRAME_WIDTH,
		Vector2.ONE * (Design.BOARD_PX + Design.FRAME_WIDTH * 2.0)
	)
	draw_rect(Rect2(outer.position + Design.SHADOW_OFF, outer.size), Design.INK)
	draw_rect(outer, Design.FELT_EDGE)
	draw_rect(Rect2(Design.BOARD_ORIGIN, Vector2.ONE * Design.BOARD_PX), Design.FELT)


func _draw_grid() -> void:
	var origin := Design.BOARD_ORIGIN
	for i in Design.SIZE + 1:
		var step := float(i) * Design.CELL
		draw_line(
			origin + Vector2(step, 0.0),
			origin + Vector2(step, Design.BOARD_PX),
			Design.FELT_LINE, GRID_WIDTH
		)
		draw_line(
			origin + Vector2(0.0, step),
			origin + Vector2(Design.BOARD_PX, step),
			Design.FELT_LINE, GRID_WIDTH
		)
	for point: Vector2i in STAR_POINTS:
		draw_circle(
			origin + Vector2(point) * Design.CELL, STAR_RADIUS,
			Design.FELT_LINE, true, -1.0, true
		)


## The fill alone sank into the felt: semi-transparent yellow blended toward
## green lands on olive whatever its alpha. The ring carries the same hue at a
## higher alpha so the marker reads as an invitation rather than a smudge.
func _draw_hints() -> void:
	var ring := Design.HINT
	ring.a = minf(Design.HINT.a * 1.8, 1.0)
	for cell: Vector2i in hints:
		if not Design.in_bounds(cell):
			continue
		var centre := Design.cell_centre(cell)
		draw_circle(centre, Design.HINT_RADIUS, Design.HINT, true, -1.0, true)
		draw_arc(
			centre, Design.HINT_RADIUS + LEGAL_RING_GAP, 0.0, TAU, RING_SEGMENTS,
			ring, LEGAL_RING_WIDTH, true
		)


func _draw_last_ring() -> void:
	if last_move == NO_CELL or not Design.in_bounds(last_move):
		return
	draw_arc(
		Design.cell_centre(last_move), Design.DISC_RADIUS + LAST_RING_PAD,
		0.0, TAU, RING_SEGMENTS, Design.RED, LAST_RING_WIDTH, true
	)


func _draw_discs() -> void:
	for index in ReversiBoard.CELL_COUNT:
		if not _discs.has(index):
			continue
		var state: Dictionary = _discs[index]
		var drop := float(state["drop"])
		if drop <= 0.001:
			continue
		var cell := Vector2i(index % Design.SIZE, index / Design.SIZE)
		_draw_disc(
			Design.cell_centre(cell), int(state["player"]),
			float(state["scale_x"]), drop
		)


## Scaling on X alone is the whole flip: a circle squeezed to nothing and let
## back out reads as a disc turning over, with none of the cost of a real
## rotation. The squeeze is floored above zero so the edge never vanishes.
func _draw_disc(centre: Vector2, player: int, scale_x: float, drop: float) -> void:
	var radius := Design.DISC_RADIUS * maxf(drop, 0.0)
	if radius <= 0.5:
		return
	var squeeze := maxf(absf(scale_x), MIN_SCALE_X)
	draw_set_transform(centre, 0.0, Vector2(squeeze, 1.0))
	draw_circle(Vector2.ZERO, radius, Design.disc_colour(player), true, -1.0, true)
	draw_circle(
		Vector2.ZERO, radius - DISC_EDGE_WIDTH * 0.5, Design.DISC_EDGE,
		false, DISC_EDGE_WIDTH, true
	)
	if player == ReversiBoard.WHITE:
		# Without this the white disc is a flat hole in the felt. One arc across
		# the upper left is enough to give it a face.
		var sheen := Color(1.0, 1.0, 1.0, 0.55)
		draw_arc(
			Vector2.ZERO, radius * HIGHLIGHT_SCALE, PI, TAU * 0.875,
			RING_SEGMENTS, sheen, HIGHLIGHT_WIDTH, true
		)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_hover() -> void:
	if not interactive or _hover == NO_CELL:
		return
	var tint := Design.GOLD
	tint.a = HOVER_LEGAL_ALPHA if hints.has(_hover) else HOVER_ALPHA
	draw_rect(Design.cell_rect(_hover), tint, false, HOVER_WIDTH)


func _draw_hint_flash() -> void:
	if _hint_cell == NO_CELL or _hint_pulse <= 0.0 or _hint_pulse >= 1.0:
		return
	# Three pulses across the run, taken off a sine so the ring breathes rather
	# than blinking on and off.
	var wave := absf(sin(_hint_pulse * PI * HINT_FLASH_PULSES))
	var tint := Design.CYAN
	tint.a = wave
	draw_arc(
		Design.cell_centre(_hint_cell), Design.DISC_RADIUS + HINT_RING_PAD,
		0.0, TAU, RING_SEGMENTS, tint, HINT_RING_WIDTH, true
	)
