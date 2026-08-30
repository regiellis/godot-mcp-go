@tool
class_name JuiceMenu
extends VBoxContainer

## A column of [JuiceButton]s that deals itself in and out.
##
## Style is how a row enters (each button's own [member JuiceButton.intro_style]);
## order is which row goes first. They are separate settings because the same
## slide dealt centre-out feels nothing like the same slide dealt top down.
##
## Anything in the column that is not a [JuiceButton] is skipped rather than
## treated as an error, so a spacer or a rule can sit between two rows.

## Which button gets the shortest delay.
enum StaggerOrder {
	SEQUENTIAL, ## Top to bottom.
	REVERSE, ## Bottom to top.
	CENTRE_OUT, ## Middle first, edges last.
	TOGETHER, ## No stagger. Pause uses this, so Resume never arrives last.
}

signal dealt_in ## The last button has landed.
signal dealt_out ## The last button has left.
signal button_pressed(button: JuiceButton, index: int)

@export var stagger_order: StaggerOrder = StaggerOrder.SEQUENTIAL

@export var separation: int = int(Design.SPACE_MD):
	set(value):
		separation = value
		add_theme_constant_override(&"separation", separation)

## Whether ui_up and ui_down run off the ends back round to the other side.
@export var wrap: bool = true

var _index: int = 0


func _ready() -> void:
	add_theme_constant_override(&"separation", separation)
	refresh()


## Re-reads the child list. Call it after adding or removing a button at runtime.
func refresh() -> void:
	var rows := buttons()
	for i in rows.size():
		var button := rows[i]
		if not button.focus_entered.is_connected(_on_button_focused):
			button.focus_entered.connect(_on_button_focused.bind(button))
		if not button.pressed.is_connected(_on_button_pressed):
			button.pressed.connect(_on_button_pressed.bind(button))
	_wire_focus_ring(rows)
	_index = clampi(_index, 0, maxi(rows.size() - 1, 0))


func buttons() -> Array[JuiceButton]:
	var rows: Array[JuiceButton] = []
	for child in get_children():
		if child is JuiceButton:
			rows.append(child as JuiceButton)
	return rows


func deal_in() -> void:
	var rows := buttons()
	refresh()
	if rows.is_empty():
		dealt_in.emit()
		return

	var last := 0.0
	for i in rows.size():
		var delay := _delay_for(i, rows.size())
		last = maxf(last, delay)
		rows[i].play_intro(delay)

	var first := _first_enabled(rows)
	if first >= 0:
		_index = first
		rows[first].grab_focus()

	if not is_inside_tree():
		dealt_in.emit()
		return
	await get_tree().create_timer(last + JuiceButton.T_INTRO).timeout
	dealt_in.emit()


func deal_out() -> void:
	var rows := buttons()
	if rows.is_empty():
		dealt_out.emit()
		return

	var last := 0.0
	for i in rows.size():
		# Two thirds of the entry stagger. An exit that dawdles as long as the
		# entrance reads as hesitation rather than a decision.
		var delay := _delay_for(i, rows.size()) * 0.6
		last = maxf(last, delay)
		rows[i].play_outro(delay)

	if not is_inside_tree():
		dealt_out.emit()
		return
	await get_tree().create_timer(last + JuiceButton.T_OUTRO).timeout
	dealt_out.emit()


func focus_index(at: int) -> void:
	var rows := buttons()
	if rows.is_empty():
		return
	_index = clampi(at, 0, rows.size() - 1)
	rows[_index].grab_focus()


## Only reached when the focus ring did not consume the event, which means
## nothing in this menu holds focus. With focus, Godot's own navigation walks
## the neighbours wired in _wire_focus_ring.
func _unhandled_input(event: InputEvent) -> void:
	var rows := buttons()
	if rows.is_empty() or not is_visible_in_tree():
		return

	if event.is_action_pressed(&"ui_down"):
		_step(1, rows)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_up"):
		_step(-1, rows)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_accept"):
		var current := clampi(_index, 0, rows.size() - 1)
		rows[current].grab_focus()
		rows[current].press()
		get_viewport().set_input_as_handled()


func _step(direction: int, rows: Array[JuiceButton]) -> void:
	var count := rows.size()
	var next := _index
	for _attempt in count:
		next = wrapi(next + direction, 0, count) if wrap \
				else clampi(next + direction, 0, count - 1)
		if not rows[next].disabled:
			break
	_index = next
	rows[_index].grab_focus()


## Godot's geometric focus search stops at the ends of the column, so the ring
## is written out explicitly. Disabled rows are left out of it, which is what
## makes ui_down skip them instead of parking on a button that only refuses.
func _wire_focus_ring(rows: Array[JuiceButton]) -> void:
	var live: Array[JuiceButton] = []
	for button in rows:
		if not button.disabled:
			live.append(button)
	if live.size() < 2:
		return
	for i in live.size():
		var above := live[wrapi(i - 1, 0, live.size())]
		var below := live[wrapi(i + 1, 0, live.size())]
		if not wrap and i == 0:
			above = live[i]
		if not wrap and i == live.size() - 1:
			below = live[i]
		live[i].focus_neighbor_top = live[i].get_path_to(above)
		live[i].focus_neighbor_bottom = live[i].get_path_to(below)
		live[i].focus_previous = live[i].get_path_to(above)
		live[i].focus_next = live[i].get_path_to(below)


func _delay_for(at: int, count: int) -> float:
	if count <= 1 or stagger_order == StaggerOrder.TOGETHER:
		return 0.0
	var step := 0.0
	match stagger_order:
		StaggerOrder.SEQUENTIAL:
			step = float(at)
		StaggerOrder.REVERSE:
			step = float(count - 1 - at)
		StaggerOrder.CENTRE_OUT:
			step = absf(float(at) - float(count - 1) * 0.5)
	return Design.T_MENU_STAGGER * step


func _first_enabled(rows: Array[JuiceButton]) -> int:
	for i in rows.size():
		if not rows[i].disabled:
			return i
	return -1


func _on_button_focused(button: JuiceButton) -> void:
	var found := buttons().find(button)
	if found >= 0:
		_index = found


func _on_button_pressed(button: JuiceButton) -> void:
	button_pressed.emit(button, buttons().find(button))
