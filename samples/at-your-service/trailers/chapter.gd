@tool
extends Control
## Preview an individual chapter's cards without running the whole film.

@export_range(1, 12, 1) var preview_step := 1:
	set(value):
		preview_step = value
		if Engine.is_editor_hint() and is_node_ready():
			_preview()


func _ready() -> void:
	if Engine.is_editor_hint() or get_parent() == get_tree().root:
		_preview()


func _preview() -> void:
	var cards := get_children()
	for index in cards.size():
		if cards[index] is CanvasItem:
			cards[index].visible = index == clampi(preview_step - 1, 0, cards.size() - 1)
