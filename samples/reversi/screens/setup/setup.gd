extends Control

## The pre-match card: pick an opponent, pick a colour, start.
##
## Selection is a screen-local int rather than a button group. The four opponent
## plates stay ordinary JuiceButtons and "chosen" is said by retuning that one
## button's own colours, which is what the widget's Colours group is there for.

const GAME_SCENE := "res://screens/game/game.tscn"
const TITLE_SCENE := "res://screens/title/title.tscn"

## Index into the opponent row, in reading order. The first three match
## ReversiAI.Level by value; TWO_PLAYERS sits one past the end of that enum, so a
## single int carries the whole choice. ReversiAI plays NORMAL for any level it
## does not recognise, which is what keeps the out-of-range value harmless.
const TWO_PLAYERS := 3

const DIFFICULTY_KEY := "game/difficulty"

## Entrance stagger. Shorter than a menu's Design.T_MENU_STAGGER because eight
## plates dealt at 0.06 would still be arriving after a second.
const ROW_STAGGER := 0.04

@onready var _card := %Card as JuicePanel
@onready var _easy := %OpponentEasy as JuiceButton
@onready var _normal := %OpponentNormal as JuiceButton
@onready var _hard := %OpponentHard as JuiceButton
@onready var _two := %OpponentTwo as JuiceButton
@onready var _black := %ColourBlack as JuiceButton
@onready var _white := %ColourWhite as JuiceButton
@onready var _start := %StartButton as JuiceButton
@onready var _back := %BackButton as JuiceButton

var _opponent: int = 1
var _colour: int = 0
var _opponents: Array[JuiceButton] = []
var _colours: Array[JuiceButton] = []


func _ready() -> void:
	_opponents = [_easy, _normal, _hard, _two]
	_colours = [_black, _white]

	_opponent = clampi(int(Settings.get_value(DIFFICULTY_KEY, 1)), 0, TWO_PLAYERS)
	# The colour comes back off Session rather than off a settings key: it is
	# already the last thing configure() was told, and it needs no second store.
	_colour = 1 if Session.human_player == Session.WHITE else 0

	for i in _opponents.size():
		_opponents[i].pressed.connect(_on_opponent_pressed.bind(i))
	for i in _colours.size():
		_colours[i].pressed.connect(_on_colour_pressed.bind(i))
	_start.pressed.connect(_on_start_pressed)
	_back.pressed.connect(_on_back_pressed)

	_refresh()
	_deal_in()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back_pressed()


func _deal_in() -> void:
	_card.pop_in()
	var order := _all_buttons()
	for i in order.size():
		order[i].play_intro(float(i) * ROW_STAGGER)
	# Focus lands on START rather than on the current choice: the choice is
	# already readable from the plate colours, and START is what the screen is for.
	_start.grab_focus()


func _all_buttons() -> Array[JuiceButton]:
	var rows: Array[JuiceButton] = []
	rows.append_array(_opponents)
	rows.append_array(_colours)
	rows.append(_start)
	rows.append(_back)
	return rows


## Pushes the whole selection state out to the widgets in one pass, so there is
## one place where "what is chosen" turns into "what is drawn".
func _refresh() -> void:
	for i in _opponents.size():
		_style_choice(_opponents[i], i == _opponent)
	for i in _colours.size():
		_style_choice(_colours[i], i == _colour)

	var hotseat := _opponent == TWO_PLAYERS
	for button in _colours:
		button.disabled = hotseat
		button.queue_redraw()
	if hotseat and (_black.has_focus() or _white.has_focus()):
		_start.grab_focus()

	_wire_focus()


## JuiceButton's accent is the colour it reaches when hovered or focused, so a
## chosen plate needs fill_idle set as well: with accent alone the selection
## would only be visible while the pointer was sitting on it.
func _style_choice(button: JuiceButton, chosen: bool) -> void:
	button.accent = Design.GOLD if chosen else Design.NIGHT_LO
	button.fill_idle = Design.GOLD if chosen else Design.NIGHT_LO
	# Ink on gold, cream on the well. text_selected matches text_idle so the
	# hover lerp cannot drag the label toward a colour its plate cannot carry.
	button.text_idle = Design.INK if chosen else Design.CREAM
	button.text_selected = Design.INK if chosen else Design.CREAM
	button.queue_redraw()


## Godot's geometric focus search will happily park on a disabled plate and it
## stops dead at the edges of a grid, so the ring is written out by hand over the
## rows that are live. Left and right wrap inside a row, up and down between rows.
func _wire_focus() -> void:
	var rows: Array[Array] = [[_easy, _normal], [_hard, _two]]
	if _opponent != TWO_PLAYERS:
		rows.append([_black, _white])
	rows.append([_start, _back])

	var flat: Array[JuiceButton] = []
	for row: Array in rows:
		for entry: Variant in row:
			flat.append(entry as JuiceButton)

	for i in rows.size():
		var row: Array = rows[i]
		var above: Array = rows[wrapi(i - 1, 0, rows.size())]
		var below: Array = rows[wrapi(i + 1, 0, rows.size())]
		for j in row.size():
			var button := row[j] as JuiceButton
			var left := row[wrapi(j - 1, 0, row.size())] as JuiceButton
			var right := row[wrapi(j + 1, 0, row.size())] as JuiceButton
			var up := above[mini(j, above.size() - 1)] as JuiceButton
			var down := below[mini(j, below.size() - 1)] as JuiceButton
			button.focus_neighbor_left = button.get_path_to(left)
			button.focus_neighbor_right = button.get_path_to(right)
			button.focus_neighbor_top = button.get_path_to(up)
			button.focus_neighbor_bottom = button.get_path_to(down)

	for i in flat.size():
		var button := flat[i]
		button.focus_previous = button.get_path_to(flat[wrapi(i - 1, 0, flat.size())])
		button.focus_next = button.get_path_to(flat[wrapi(i + 1, 0, flat.size())])


func _on_opponent_pressed(index: int) -> void:
	if index == _opponent:
		return
	_opponent = index
	_refresh()


func _on_colour_pressed(index: int) -> void:
	if index == _colour:
		return
	_colour = index
	_refresh()


func _on_start_pressed() -> void:
	Settings.set_value(DIFFICULTY_KEY, _opponent)
	var mode := Session.Mode.HOTSEAT if _opponent == TWO_PLAYERS else Session.Mode.CPU
	var human := Session.WHITE if _colour == 1 else Session.BLACK
	Session.configure(mode, _opponent, human)
	Audio.play(&"start")
	Stage.go(GAME_SCENE)


func _on_back_pressed() -> void:
	Stage.go(TITLE_SCENE)
