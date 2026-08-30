class_name ReversiBoard
extends RefCounted

## The complete rules of Reversi, and the only place they live.
##
## Pure data. Nothing here touches the engine beyond Vector2i and
## PackedByteArray, so a headless check script can drive a whole match with no
## scene tree and the AI can clone positions cheaply while it searches.

enum { EMPTY = 0, BLACK = 1, WHITE = 2 }

const SIZE := 8
const CELL_COUNT := SIZE * SIZE

## The eight rays a bracket can run along, listed once so that flips_for stays
## the only function in the project that walks them.
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

## 64 entries, one byte per cell, index = y * SIZE + x. A packed array rather
## than a nested Array so clone() is a single memcpy during the AI search.
var cells: PackedByteArray

## Match statistics, maintained by apply_move. Public because clone() has to
## carry them across, and reached through move_count() / biggest_flip() at the
## call sites so the reading side never looks like it may write them.
var moves_played := 0
var largest_flip := 0


func _init() -> void:
	reset()


## The standard opening: white on the a1-h8 diagonal, black on the other.
func reset() -> void:
	cells = PackedByteArray()
	cells.resize(CELL_COUNT)
	cells.fill(EMPTY)
	cells[3 * SIZE + 3] = WHITE
	cells[4 * SIZE + 4] = WHITE
	cells[4 * SIZE + 3] = BLACK
	cells[3 * SIZE + 4] = BLACK
	moves_played = 0
	largest_flip = 0


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < SIZE and cell.y >= 0 and cell.y < SIZE


## An off-board cell reads as EMPTY. Rays stop on it either way, and callers
## that probe a neighbour without checking bounds first get a harmless answer.
func get_cell(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return EMPTY
	return cells[cell.y * SIZE + cell.x]


func set_cell(cell: Vector2i, value: int) -> void:
	if not in_bounds(cell):
		return
	cells[cell.y * SIZE + cell.x] = value


static func opponent(player: int) -> int:
	return WHITE if player == BLACK else BLACK


## The rule, in full. Walks each direction collecting a contiguous run of
## opponent discs and keeps that run only when it terminates on one of
## `player`'s own discs. A run that reaches the board edge, or an empty cell,
## brackets nothing. An empty return means the move is illegal, and every
## legality question in the game routes back through here.
func flips_for(cell: Vector2i, player: int) -> Array[Vector2i]:
	var flipped: Array[Vector2i] = []
	if player != BLACK and player != WHITE:
		return flipped
	if not in_bounds(cell) or cells[cell.y * SIZE + cell.x] != EMPTY:
		return flipped
	var foe := opponent(player)
	for dir: Vector2i in DIRECTIONS:
		var run: Array[Vector2i] = []
		var probe := cell + dir
		while in_bounds(probe) and cells[probe.y * SIZE + probe.x] == foe:
			run.append(probe)
			probe += dir
		if run.is_empty():
			continue
		if in_bounds(probe) and cells[probe.y * SIZE + probe.x] == player:
			flipped.append_array(run)
	return flipped


## Vector2i -> Array[Vector2i]. Callers compute this once per turn and reuse it
## for the hints, the click test and the AI, rather than asking cell by cell.
func valid_moves(player: int) -> Dictionary:
	var moves := {}
	for y in SIZE:
		for x in SIZE:
			if cells[y * SIZE + x] != EMPTY:
				continue
			var cell := Vector2i(x, y)
			var flipped := flips_for(cell, player)
			if not flipped.is_empty():
				moves[cell] = flipped
	return moves


## Cheaper than valid_moves when only the yes or no matters, because it stops
## at the first legal cell instead of collecting every flip set.
func has_move(player: int) -> bool:
	for y in SIZE:
		for x in SIZE:
			if cells[y * SIZE + x] != EMPTY:
				continue
			if not flips_for(Vector2i(x, y), player).is_empty():
				return true
	return false


## Defensive rather than assertive: an illegal cell returns an empty array and
## leaves the board untouched, so a stray click during an animation is a no-op
## instead of a crash.
func apply_move(cell: Vector2i, player: int) -> Array[Vector2i]:
	var flipped := flips_for(cell, player)
	if flipped.is_empty():
		return flipped
	cells[cell.y * SIZE + cell.x] = player
	for target: Vector2i in flipped:
		cells[target.y * SIZE + target.x] = player
	moves_played += 1
	if flipped.size() > largest_flip:
		largest_flip = flipped.size()
	return flipped


func score(player: int) -> int:
	var total := 0
	for index in CELL_COUNT:
		if cells[index] == player:
			total += 1
	return total


func empty_count() -> int:
	var total := 0
	for index in CELL_COUNT:
		if cells[index] == EMPTY:
			total += 1
	return total


## Over when neither side can move, which is not the same as a full board: a
## position can lock up with squares left over.
func is_over() -> bool:
	return not has_move(BLACK) and not has_move(WHITE)


func move_count() -> int:
	return moves_played


## The largest single-move flip count seen on this board. The result screen
## reports it, so it has to survive across the whole match rather than being
## recomputed from a final position that no longer shows it.
func biggest_flip() -> int:
	return largest_flip


## An independent copy. The AI mutates clones by the thousand while searching,
## so nothing here may be shared with the original.
func clone() -> ReversiBoard:
	var copy := ReversiBoard.new()
	copy.cells = cells.duplicate()
	copy.moves_played = moves_played
	copy.largest_flip = largest_flip
	return copy
