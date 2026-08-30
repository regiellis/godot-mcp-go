extends Node

## The only thing in the game that changes scenes.
##
## Autoload `Stage`. It owns the transition wipe and the single toast layer, so
## both survive the scene swap they are drawn over. No screen calls
## `get_tree().change_scene_to_file()` directly.
##
## Overlays are not scene changes. Pause, settings and how-to-play are added as
## children of the screen that opens them and never come through here.

signal scene_changed(path: String)

var _wipe: Wipe = null
var _toasts: ToastLayer = null
var _transitioning := false


func _ready() -> void:
	# Both set their own CanvasLayer index in _init: Wipe at 128 above ToastLayer
	# at 120, so a transition covers the notifications rather than the reverse.
	_wipe = Wipe.new()
	_wipe.name = "Wipe"
	add_child(_wipe)
	_toasts = ToastLayer.new()
	_toasts.name = "Toasts"
	add_child(_toasts)


## Wipe out, swap, wipe back in. A second call while a transition is running is
## dropped, not queued: queueing it would land the player two screens along from
## one impatient double-click.
func go(path: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	await _wipe.cover()
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("Stage.go could not load %s (error %d)." % [path, err])
	# change_scene_to_file swaps at the end of the frame, so the reveal has to
	# wait a frame or it uncovers the outgoing scene.
	await get_tree().process_frame
	await _wipe.reveal()
	_transitioning = false
	scene_changed.emit(path)


## Hard cut with no wipe. Boot uses it, because there is nothing on screen yet
## to transition away from.
func go_immediate(path: String) -> void:
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("Stage.go_immediate could not load %s (error %d)." % [path, err])
		return
	scene_changed.emit(path)


func is_transitioning() -> bool:
	return _transitioning


func toast(message: String, accent: Color = Design.GOLD, hold: float = Design.T_TOAST_HOLD) -> void:
	if _toasts == null:
		return
	_toasts.push(message, accent, hold)


func clear_toasts() -> void:
	if _toasts == null:
		return
	_toasts.clear()
