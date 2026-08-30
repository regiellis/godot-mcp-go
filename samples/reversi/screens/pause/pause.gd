extends Control

## The pause card, instanced as a child of the match screen rather than swapped
## in as a scene.
##
## It owns no pause state. `get_tree().paused` belongs to the screen that opened
## this, and everything here reports out as a signal so the decision to resume,
## restart or leave is made in one place.

signal resumed
signal restart_requested
signal quit_requested
signal settings_requested
signal how_to_requested

const HINT_TEXT := "Press Escape to resume."
const CONFIRM_TEXT := "Quit to the title screen? The current game is lost."

const T_SCRIM := 0.18

## One beat behind the card, and every row lands on it together rather than
## staggered, so RESUME is never the button that arrives last.
const T_MENU_DELAY := 0.05

const SCRIM_ALPHA := 0.72
const CONFIRM_SCRIM_ALPHA := 0.55

@onready var _scrim: ColorRect = %Scrim
@onready var _panel: JuicePanel = %Panel
@onready var _menu: JuiceMenu = %Menu
@onready var _hint: Label = %HintLabel
@onready var _confirm: Control = %Confirm
@onready var _confirm_label: Label = %ConfirmLabel
@onready var _confirm_quit: JuiceButton = %ConfirmQuit
@onready var _confirm_cancel: JuiceButton = %ConfirmCancel
@onready var _resume_button: JuiceButton = %ResumeButton
@onready var _restart_button: JuiceButton = %RestartButton
@onready var _how_to_button: JuiceButton = %HowToButton
@onready var _settings_button: JuiceButton = %SettingsButton
@onready var _quit_button: JuiceButton = %QuitButton

## True while a further overlay sits on top of this card. It keeps Escape from
## resuming the game out from under a settings screen that is still open.
var _suspended := false


func _ready() -> void:
	# Its own buttons and tweens have to keep running while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_style(_hint, Design.FS_SMALL, Design.CREAM_MUTED)
	_style(_confirm_label, Design.FS_BODY, Design.CREAM)
	_hint.text = HINT_TEXT
	_confirm_label.text = CONFIRM_TEXT
	_confirm.visible = false

	_resume_button.pressed.connect(_on_resume)
	_restart_button.pressed.connect(restart_requested.emit)
	_how_to_button.pressed.connect(how_to_requested.emit)
	_settings_button.pressed.connect(settings_requested.emit)
	_quit_button.pressed.connect(_show_confirm)
	_confirm_quit.pressed.connect(quit_requested.emit)
	_confirm_cancel.pressed.connect(_hide_confirm)

	_scrim.color = Color(Design.INK, SCRIM_ALPHA)
	_scrim.modulate.a = 0.0
	var fade := create_tween()
	fade.tween_property(_scrim, ^"modulate:a", 1.0, T_SCRIM)

	_panel.pop_in()
	# ignore_time_scale, because a hitstop running when the player paused would
	# otherwise strand the menu off screen.
	await get_tree().create_timer(T_MENU_DELAY, true, false, true).timeout
	if not is_inside_tree():
		return
	_menu.deal_in()


## Hides this card while another overlay is on top of it, and takes its input
## handling with it. Called by the screen that owns both.
func suspend(on: bool) -> void:
	_suspended = on
	visible = not on
	_menu.set_process_unhandled_input(not on)


func _unhandled_input(event: InputEvent) -> void:
	if _suspended or not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	if _confirm.visible:
		_hide_confirm()
		return
	_on_resume()


func _on_resume() -> void:
	resumed.emit()


func _show_confirm() -> void:
	_confirm.visible = true
	# The menu keeps its focus ring otherwise, and ui_accept would fire the
	# button behind the card instead of the one on it.
	_menu.set_process_unhandled_input(false)
	_confirm_cancel.grab_focus()


func _hide_confirm() -> void:
	_confirm.visible = false
	_menu.set_process_unhandled_input(true)
	_resume_button.grab_focus()


func _style(node: Label, font_size: int, tint: Color) -> void:
	node.add_theme_font_override(&"font", Design.font())
	node.add_theme_font_size_override(&"font_size", font_size)
	node.add_theme_color_override(&"font_color", tint)
	node.add_theme_color_override(&"font_shadow_color", Design.INK)
	node.add_theme_constant_override(&"shadow_offset_x", Design.shadow_for(font_size))
	node.add_theme_constant_override(&"shadow_offset_y", Design.shadow_for(font_size))
	node.add_theme_constant_override(&"shadow_outline_size", 0)
