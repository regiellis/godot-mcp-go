class_name ReversiAI
extends RefCounted

## The opponent. Three levels over one shared search, with no state of its own:
## everything it needs comes in through choose(), so the same board and the same
## seeded RandomNumberGenerator always produce the same move and a match replays
## exactly from its seed.

enum Level { EASY, NORMAL, HARD }

const NO_MOVE := Vector2i(-1, -1)

## Longest HARD may think before it has to answer with whatever it has. A turn
## runs inside a frame, so anything past this is a visible hitch rather than a
## stronger opponent.
const BUDGET_MS := 60

const DEPTH := 4

## Late in the game the branching factor collapses, so the same budget buys two
## more plies. Twelve empties is where a full search starts to fit.
const DEPTH_ENDGAME := 6
const ENDGAME_EMPTY := 12

## Board coordinates of the four corners. Literal 7 rather than SIZE - 1 because
## a const initialiser may not reach into another script.
const CORNERS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(7, 7),
]

## Positional weights, index = y * 8 + x, derived from how permanent a square is
## rather than from how it looks.
##
## 120 for a corner: it can never be flipped, because a bracket has to close on
## a square beyond it and there is none.
## -40 for the X square diagonally inside a corner, and -20 for the two C
## squares beside it: occupying one is what lets the opponent reach the corner,
## and losing a corner costs far more than the square gains.
## 20 for the rest of the edge and 15 for the inner box corners, both hard to
## flip because a bracket needs squares on two sides.
## 3 to 5 in the middle: everything there changes hands repeatedly and is worth
## very little until the board stops moving.
const WEIGHTS: Array[int] = [
	120, -20, 20, 5, 5, 20, -20, 120,
	-20, -40, -5, -5, -5, -5, -40, -20,
	20, -5, 15, 3, 3, 15, -5, 20,
	5, -5, 3, 3, 3, 3, -5, 5,
	5, -5, 3, 3, 3, 3, -5, 5,
	20, -5, 15, 3, 3, 15, -5, 20,
	-20, -40, -5, -5, -5, -5, -40, -20,
	120, -20, 20, 5, 5, 20, -20, 120,
]

# Evaluation weights. The scale is anchored on the corner term: one net corner
# is worth 25, and every other term is priced against that.
const W_CORNER := 25.0
const W_ADJACENT := 12.0
const W_MOBILITY := 30.0
const W_FRONTIER := 15.0
const W_PARITY_EARLY := 2.0
const W_PARITY_LATE := 60.0

## A finished game is scored well past anything the heuristic can reach, so a
## win is never traded away for position.
const SCORE_WIN := 10000.0


## Returns NO_MOVE when the side to move has nothing legal, which is the
## caller's cue to pass rather than an error.
static func choose(
		board: ReversiBoard, player: int, level: int, rng: RandomNumberGenerator
) -> Vector2i:
	var moves := board.valid_moves(player)
	if moves.is_empty():
		return NO_MOVE
	match level:
		Level.EASY:
			return _choose_easy(moves, rng)
		Level.HARD:
			return _choose_hard(board, player, moves)
	# Anything unrecognised plays NORMAL, so a bad difficulty setting still
	# produces a game instead of a crash.
	return _choose_normal(moves, rng)


## Uniform random, except that it always takes a corner. Losing to EASY should
## feel like carelessness, and a level that hands back free corners never
## teaches a new player that corners matter.
static func _choose_easy(moves: Dictionary, rng: RandomNumberGenerator) -> Vector2i:
	var cells := moves.keys()
	for cell: Vector2i in cells:
		if _is_corner(cell):
			return cell
	var picked: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
	return picked


## One ply: the weight table decides the shape, the flip count breaks near-ties
## toward the move that also gains material. Two points a disc keeps a big
## capture from outranking a corner, since eight flips is worth 16 against 120.
static func _choose_normal(moves: Dictionary, rng: RandomNumberGenerator) -> Vector2i:
	var best: Array[Vector2i] = []
	var best_score := -INF
	for cell: Vector2i in moves:
		var flipped: Array = moves[cell]
		var value := float(WEIGHTS[cell.y * ReversiBoard.SIZE + cell.x] + flipped.size() * 2)
		if value > best_score:
			best_score = value
			best.clear()
			best.append(cell)
		elif is_equal_approx(value, best_score):
			best.append(cell)
	# Ties go to the rng rather than to dictionary order, so NORMAL does not
	# open with the same move every single game.
	return best[rng.randi_range(0, best.size() - 1)]


static func _choose_hard(board: ReversiBoard, player: int, moves: Dictionary) -> Vector2i:
	var deadline := Time.get_ticks_msec() + BUDGET_MS
	var max_depth := DEPTH_ENDGAME if board.empty_count() <= ENDGAME_EMPTY else DEPTH
	var ordered := _ordered_moves(moves)
	var best := ordered[0]
	# Iterative deepening. Each pass costs a fraction of the one after it, so
	# the repeated work is cheap, and it is what makes the budget safe to
	# enforce: whenever the clock runs out there is already a finished answer
	# from the depth below to return.
	for depth in range(1, max_depth + 1):
		best = _search_root(board, player, ordered, depth, deadline)
		if Time.get_ticks_msec() >= deadline:
			break
	return best


static func _search_root(
		board: ReversiBoard,
		player: int,
		ordered: Array[Vector2i],
		depth: int,
		deadline: int
) -> Vector2i:
	var best := ordered[0]
	var alpha := -INF
	var scored := false
	for cell: Vector2i in ordered:
		var child := board.clone()
		child.apply_move(cell, player)
		var value := -_negamax(
				child, ReversiBoard.opponent(player), depth - 1, -INF, -alpha, deadline
		)
		if not scored or value > alpha:
			alpha = value
			best = cell
			scored = true
		# Breaking here keeps the best of the moves already searched. The move
		# ordering is what makes that partial answer worth having.
		if Time.get_ticks_msec() >= deadline:
			break
	return best


## Negamax with alpha-beta: the score is always read from `side`'s point of
## view, so one branch covers both players instead of a mirrored pair.
static func _negamax(
		board: ReversiBoard,
		side: int,
		depth: int,
		alpha: float,
		beta: float,
		deadline: int
) -> float:
	if depth <= 0 or Time.get_ticks_msec() >= deadline:
		return _evaluate(board, side)
	var moves := board.valid_moves(side)
	if moves.is_empty():
		var foe := ReversiBoard.opponent(side)
		if not board.has_move(foe):
			return _terminal(board, side)
		# A pass costs no depth, because the position did not change. It cannot
		# loop: the side being passed to has a move by the test above.
		return -_negamax(board, foe, depth, -beta, -alpha, deadline)
	var ordered := _ordered_moves(moves)
	var value := -INF
	var a := alpha
	for cell: Vector2i in ordered:
		var child := board.clone()
		child.apply_move(cell, side)
		value = maxf(value, -_negamax(
				child, ReversiBoard.opponent(side), depth - 1, -beta, -a, deadline
		))
		a = maxf(a, value)
		if a >= beta:
			break
		if Time.get_ticks_msec() >= deadline:
			break
	return value


## Corners first, then by flip count. Multiplying the table by 4 puts it out of
## reach of the flip count, which tops out around 19, so the ordering is
## table-led with flips separating squares the table rates the same.
static func _ordered_moves(moves: Dictionary) -> Array[Vector2i]:
	var ordered: Array[Vector2i] = []
	var rank := {}
	for cell: Vector2i in moves:
		ordered.append(cell)
		var flipped: Array = moves[cell]
		rank[cell] = WEIGHTS[cell.y * ReversiBoard.SIZE + cell.x] * 4 + flipped.size()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return rank[a] > rank[b])
	return ordered


## Static evaluation from `side`'s point of view, five terms on one scale.
static func _evaluate(board: ReversiBoard, side: int) -> float:
	var foe := ReversiBoard.opponent(side)

	# Corner ownership. A corner can never be flipped, so it is the only thing
	# on the board that is permanently true, and it anchors the whole edge.
	var corners := float(_corner_count(board, side) - _corner_count(board, foe)) * W_CORNER

	# Corner adjacency, counted only while the corner itself is still empty:
	# sitting on an X or C square is what gives the opponent the corner. Once
	# the corner is settled those squares are ordinary again.
	var adjacency := float(_corner_risk(board, foe) - _corner_risk(board, side)) * W_ADJACENT

	# Mobility. Reversi is usually won by starving the other side of choices
	# rather than by capturing, so the count of legal replies matters more than
	# the count of discs for most of the game.
	var my_moves := float(board.valid_moves(side).size())
	var their_moves := float(board.valid_moves(foe).size())
	var mobility := 0.0
	if my_moves + their_moves > 0.0:
		mobility = W_MOBILITY * (my_moves - their_moves) / (my_moves + their_moves)

	# Frontier discs: discs touching an empty square, which are exactly the ones
	# the opponent can play against. Fewer of them is a quieter position, and it
	# is the mechanism behind mobility rather than a restatement of it.
	var my_front := float(_frontier(board, side))
	var their_front := float(_frontier(board, foe))
	var frontier := 0.0
	if my_front + their_front > 0.0:
		frontier = W_FRONTIER * (their_front - my_front) / (my_front + their_front)

	# Disc parity, weighted toward the endgame. Early on a disc lead is
	# actively misleading, because a wide position is a wide target, so the
	# weight is squared into relevance and only bites once the board fills.
	var lateness := clampf(1.0 - float(board.empty_count()) / 60.0, 0.0, 1.0)
	var parity_weight := W_PARITY_EARLY + (W_PARITY_LATE - W_PARITY_EARLY) * lateness * lateness
	var mine := float(board.score(side))
	var theirs := float(board.score(foe))
	var parity := 0.0
	if mine + theirs > 0.0:
		parity = parity_weight * (mine - theirs) / (mine + theirs)

	return corners + adjacency + mobility + frontier + parity


static func _terminal(board: ReversiBoard, side: int) -> float:
	var diff := board.score(side) - board.score(ReversiBoard.opponent(side))
	if diff > 0:
		return SCORE_WIN + float(diff)
	if diff < 0:
		return -SCORE_WIN + float(diff)
	return 0.0


static func _is_corner(cell: Vector2i) -> bool:
	var edge := ReversiBoard.SIZE - 1
	return (cell.x == 0 or cell.x == edge) and (cell.y == 0 or cell.y == edge)


static func _corner_count(board: ReversiBoard, player: int) -> int:
	var owned := 0
	for corner: Vector2i in CORNERS:
		if board.get_cell(corner) == player:
			owned += 1
	return owned


## Discs on a square that gives away a corner that is still up for grabs: the
## two C squares along the edges and the X square on the diagonal.
static func _corner_risk(board: ReversiBoard, player: int) -> int:
	var risk := 0
	for corner: Vector2i in CORNERS:
		if board.get_cell(corner) != ReversiBoard.EMPTY:
			continue
		var inward := Vector2i(1 if corner.x == 0 else -1, 1 if corner.y == 0 else -1)
		var guards: Array[Vector2i] = [
			corner + Vector2i(inward.x, 0),
			corner + Vector2i(0, inward.y),
			corner + inward,
		]
		for guard: Vector2i in guards:
			if board.get_cell(guard) == player:
				risk += 1
	return risk


static func _frontier(board: ReversiBoard, player: int) -> int:
	var count := 0
	for y in ReversiBoard.SIZE:
		for x in ReversiBoard.SIZE:
			if board.cells[y * ReversiBoard.SIZE + x] != player:
				continue
			for dir: Vector2i in ReversiBoard.DIRECTIONS:
				# in_bounds first: get_cell reads an off-board square as EMPTY,
				# which would count every edge disc as a frontier disc.
				var probe := Vector2i(x, y) + dir
				if board.in_bounds(probe) and board.get_cell(probe) == ReversiBoard.EMPTY:
					count += 1
					break
	return count
