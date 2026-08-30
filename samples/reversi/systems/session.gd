extends Node

## Match configuration on the way in, match result on the way out.
##
## Autoload `Session`. Plain state with no knowledge of scenes: setup writes it,
## game reads it, result reads what game wrote. It resets every launch, so
## nothing here is persisted.

enum Mode { CPU, HOTSEAT }

## Mirrors ReversiBoard's cell values without importing the rules, which keeps
## this file free of any dependency on the board.
const EMPTY := 0
const BLACK := 1
const WHITE := 2

var mode: int = Mode.CPU
var difficulty: int = 1 ## A ReversiAI.Level value.
var human_player: int = BLACK
var seed_value: int = 0

## {winner: int, black: int, white: int, moves: int, biggest_flip: int}.
var result: Dictionary = {}


func _ready() -> void:
	reset()


func configure(new_mode: int, new_difficulty: int, new_human_player: int) -> void:
	mode = new_mode
	difficulty = new_difficulty
	human_player = new_human_player
	# A fresh seed per match, kept so a match can be replayed from it later.
	seed_value = randi()
	result = {}


func record_result(outcome: Dictionary) -> void:
	result = outcome.duplicate(true)
	# Hotseat is two people at one keyboard, so the win/loss ledger would mean
	# nothing. Only matches against the CPU move the stats.
	if mode != Mode.CPU:
		return
	var settings := get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	var winner := int(result.get("winner", EMPTY))
	if winner == EMPTY:
		settings.bump_stat("stats/draws")
	elif winner == human_player:
		settings.bump_stat("stats/wins")
	else:
		settings.bump_stat("stats/losses")


## One line for the result screen, phrased from the board rather than from the
## player, so it reads the same in hotseat as against the CPU.
func summary_line() -> String:
	if result.is_empty():
		return "No match played yet."
	var black := int(result.get("black", 0))
	var white := int(result.get("white", 0))
	var winner := int(result.get("winner", EMPTY))
	if winner == EMPTY:
		return "Drawn at %d discs each." % black
	var name_of := "Black" if winner == BLACK else "White"
	var high := maxi(black, white)
	var low := mini(black, white)
	return "%s wins %d to %d." % [name_of, high, low]


func reset() -> void:
	mode = Mode.CPU
	human_player = BLACK
	seed_value = 0
	result = {}
	var settings := get_node_or_null(^"/root/Settings")
	difficulty = 1 if settings == null else int(settings.get_value("game/difficulty", 1))
