extends Control

## The post-match screen: who won, by how much, and what to do next.
##
## It reads Session.result and nothing else about the match. The result may be
## empty, because this screen has to stand up when it is opened on its own, so
## every reading goes through normalise_result() and lands on a zeroed match.
##
## The three text builders are static and take the mode and the human's colour as
## arguments rather than reaching for Session. That keeps them callable with no
## autoloads present, which is the only way to check all six outcome branches.

enum Outcome { WIN, LOSS, DRAW }

const GAME_SCENE := "res://screens/game/game.tscn"
const SETUP_SCENE := "res://screens/setup/setup.tscn"
const TITLE_SCENE := "res://screens/title/title.tscn"

## Mirrors ReversiBoard's cell values and Session.Mode.CPU. Copied rather than
## read so the static builders below carry no dependency at all.
const EMPTY := 0
const BLACK := 1
const WHITE := 2
const MODE_CPU := 0

const SCORE_JOIN := " to "

## Rolls the two score counters into a two-beat reading rather than one lump.
const COUNTER_STAGGER := 0.12

## The heading is held back a beat so the wipe has finished uncovering before it
## pops, and the card and buttons follow it in.
const HEADING_DELAY := 0.15
const CARD_DELAY := 0.30
const BUTTON_DELAY := 0.55
const SUBLINE_FADE := 0.25
const FLASH_ALPHA := 0.10

@onready var _backdrop := %Backdrop as Backdrop
@onready var _heading := %Heading as Label
@onready var _subline := %Subline as Label
@onready var _card := %Card as JuicePanel
@onready var _score_row := %ScoreRow as Control
@onready var _black_counter := %BlackScore as JuiceCounter
@onready var _white_counter := %WhiteScore as JuiceCounter
@onready var _moves_value := %MovesValue as Label
@onready var _flip_value := %FlipValue as Label
@onready var _record_value := %RecordValue as Label
@onready var _play_again := %PlayAgain as JuiceButton
@onready var _change_game := %ChangeGame as JuiceButton
@onready var _back_title := %BackToTitle as JuiceButton

var _result: Dictionary = {}
var _outcome: int = Outcome.DRAW


## Fills in every key the screen reads, so an empty or half-written result from
## a screen opened directly renders a zeroed match instead of throwing.
static func normalise_result(raw: Dictionary) -> Dictionary:
	return {
		"winner": int(raw.get("winner", EMPTY)),
		"black": int(raw.get("black", 0)),
		"white": int(raw.get("white", 0)),
		"moves": int(raw.get("moves", 0)),
		"biggest_flip": int(raw.get("biggest_flip", 0)),
	}


## The heading is always the winner's, never the player's.
static func heading_for(winner: int) -> String:
	match winner:
		BLACK:
			return "BLACK WINS"
		WHITE:
			return "WHITE WINS"
	return "A DRAW"


## The subline is where the outcome lands, which is why it differs by mode: with
## a computer on the other side there is a you, and with two players there is not.
static func subline_for(winner: int, mode: int, human_player: int) -> String:
	if winner == EMPTY:
		return "Nobody wins."
	if mode == MODE_CPU:
		return "You win." if winner == human_player else "The computer wins."
	return "Black takes it." if winner == BLACK else "White takes it."


static func outcome_for(winner: int, mode: int, human_player: int) -> int:
	if winner == EMPTY:
		return Outcome.DRAW
	if mode != MODE_CPU:
		# Two people at one keyboard. Somebody won and nobody lost to a machine,
		# so the screen celebrates rather than commiserating.
		return Outcome.WIN
	return Outcome.WIN if winner == human_player else Outcome.LOSS


static func accent_for(outcome: int) -> Color:
	match outcome:
		Outcome.WIN:
			return Design.MINT
		Outcome.LOSS:
			return Design.RED
	return Design.CYAN


func _ready() -> void:
	_result = normalise_result(Session.result)
	var winner := int(_result["winner"])
	_outcome = outcome_for(winner, Session.mode, Session.human_player)

	var accent := accent_for(_outcome)
	_backdrop.accent = accent
	_card.accent = accent

	_heading.text = heading_for(winner)
	_subline.text = subline_for(winner, Session.mode, Session.human_player)
	_moves_value.text = str(int(_result["moves"]))
	_flip_value.text = str(int(_result["biggest_flip"]))
	_record_value.text = _record_text()
	_layout_score()

	_play_again.pressed.connect(_on_play_again_pressed)
	_change_game.pressed.connect(_on_change_game_pressed)
	_back_title.pressed.connect(_on_back_title_pressed)
	_wire_focus()
	_deal_in()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back_title_pressed()


func _record_text() -> String:
	return "%dW / %dL / %dD" % [
		int(Settings.get_value("stats/wins", 0)),
		int(Settings.get_value("stats/losses", 0)),
		int(Settings.get_value("stats/draws", 0)),
	]


## The score reads as one right-aligned phrase, so both counters are placed from
## the width of their finished text. The join rides on the black counter's suffix
## rather than a Label of its own, which keeps all three parts on one baseline.
##
## Everything is measured inside ScoreRow, the slot the builder sized and placed,
## so the score lands on the same right edge as the three values below it however
## many digits the match produced.
func _layout_score() -> void:
	var use_font := Design.font()
	_black_counter.suffix = SCORE_JOIN
	var left := str(int(_result["black"])) + SCORE_JOIN
	var right := str(int(_result["white"]))
	var left_width := use_font.get_string_size(
		left, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_BODY).x
	var right_width := use_font.get_string_size(
		right, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_BODY).x
	var slot := _score_row.size
	_black_counter.position = Vector2(slot.x - left_width - right_width, 0.0)
	_black_counter.size = Vector2(left_width, slot.y)
	_white_counter.position = Vector2(slot.x - right_width, 0.0)
	_white_counter.size = Vector2(right_width, slot.y)


func _buttons() -> Array[JuiceButton]:
	return [_play_again, _change_game, _back_title]


## A row, so left and right walk it and wrap. Written out because Godot's own
## focus search has nothing to find past either end.
func _wire_focus() -> void:
	var row := _buttons()
	for i in row.size():
		var button := row[i]
		var left := row[wrapi(i - 1, 0, row.size())]
		var right := row[wrapi(i + 1, 0, row.size())]
		button.focus_neighbor_left = button.get_path_to(left)
		button.focus_neighbor_right = button.get_path_to(right)
		button.focus_previous = button.get_path_to(left)
		button.focus_next = button.get_path_to(right)


func _deal_in() -> void:
	_heading.modulate.a = 0.0
	_subline.modulate.a = 0.0
	_card.pop_in(CARD_DELAY)
	var row := _buttons()
	for i in row.size():
		row[i].play_intro(BUTTON_DELAY + float(i) * Design.T_MENU_STAGGER)
	_play_again.grab_focus()

	await get_tree().create_timer(HEADING_DELAY).timeout
	if not is_inside_tree():
		return
	JuiceTween.centre_pivot(_heading)
	_heading.modulate.a = 1.0
	if JuiceTween.pop_in(_heading) == null:
		# Motion is off, so the pop never ran and the heading has to be put where
		# the tween would have left it.
		_heading.scale = Vector2.ONE

	await get_tree().create_timer(Design.T_POP_IN).timeout
	if not is_inside_tree():
		return
	_land()

	await get_tree().create_timer(COUNTER_STAGGER).timeout
	if not is_inside_tree():
		return
	_white_counter.set_value(int(_result["white"]))


## The beat the heading arrives on: the punch, the outcome's noise, and the first
## of the two score counters.
func _land() -> void:
	JuiceTween.punch_scale(_heading)
	create_tween().tween_property(_subline, ^"modulate:a", 1.0, SUBLINE_FADE)
	_black_counter.set_value(int(_result["black"]))

	match _outcome:
		Outcome.WIN:
			var tint := Design.GOLD
			tint.a = FLASH_ALPHA
			Juice.shake(0.3)
			Juice.flash(tint)
			Audio.play(&"win")
		Outcome.LOSS:
			# No shake on a loss. A screen that punches the player for losing
			# reads as mockery.
			Audio.play(&"lose")


func _on_play_again_pressed() -> void:
	# Same opponent, same colour, fresh seed. configure() re-rolls seed_value, so
	# a second run is a new match rather than a replay of the one just finished.
	Session.configure(Session.mode, Session.difficulty, Session.human_player)
	Stage.go(GAME_SCENE)


func _on_change_game_pressed() -> void:
	Stage.go(SETUP_SCENE)


func _on_back_title_pressed() -> void:
	Stage.go(TITLE_SCENE)
