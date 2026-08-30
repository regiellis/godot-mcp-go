extends Control

## The settings screen.
##
## Reached two ways: from the title as a full screen through Stage.go, and from
## the pause menu as an instanced overlay child of a paused game. Neither route
## configures anything: the screen works out which one it is on entry, draws the
## Backdrop or the scrim to match, and routes BACK to whichever exit exists.
##
## Every row is one entry in ROWS. Adding a setting is a dictionary, never a
## node, which is why the rows are built here rather than authored in the scene.
##
## `layout()` derives every box from the space ladder and from helper lines
## measured at the width they wrap to. The builder audits the same numbers, so a
## row that would run into the one below it, or into BACK, fails the build.

## Emitted by BACK. A pause menu connects this, frees the overlay, and never
## sees a scene change. With nothing connected the screen falls back to Stage.
signal closed()

const TITLE_SCENE := "res://screens/title/title.tscn"

## Set by a caller that already knows it is opening an overlay. Left false, the
## screen still works it out from the scene tree, so a caller may ignore it.
@export var overlay: bool = false

## The design box. `canvas_items` stretch fits it to the player's window.
const PAGE := Vector2(2560.0, 1440.0)

const SCRIM_ALPHA := 0.72
const TITLE := "SETTINGS"

## Rows run in two columns, four then three. One column of seven does not fit
## the page: seven rows at ROW_H, three of them carrying a helper line, plus the
## title block and BACK comes to more than the 1184px the page margins leave,
## whatever is done with the gap above BACK. Splitting also lands the three
## helped rows together, which reads as a group rather than as a ragged tail.
const COLUMN_SPLIT := 4

## Every setting the screen exposes, in the order it is drawn. `key` is the
## Settings key, so a row never has to know what its value means.
const ROWS: Array[Dictionary] = [
	{
		"key": "audio/master",
		"label": "MASTER VOLUME",
		"kind": SettingRow.Kind.SLIDER,
		"helper": "",
	},
	{
		"key": "audio/music",
		"label": "MUSIC VOLUME",
		"kind": SettingRow.Kind.SLIDER,
		"helper": "",
	},
	{
		"key": "audio/sfx",
		"label": "EFFECTS VOLUME",
		"kind": SettingRow.Kind.SLIDER,
		"helper": "",
	},
	{
		"key": "video/fullscreen",
		"label": "FULLSCREEN",
		"kind": SettingRow.Kind.TOGGLE,
		"helper": "",
	},
	{
		"key": "game/juice",
		"label": "SCREEN SHAKE",
		"kind": SettingRow.Kind.TOGGLE,
		"helper": "Turns off shake, hit stop, and the flip cascade.",
	},
	{
		"key": "a11y/reduced_motion",
		"label": "REDUCED MOTION",
		"kind": SettingRow.Kind.TOGGLE,
		"helper": "Holds every animation to a single fade.",
	},
	{
		"key": "game/show_hints",
		"label": "SHOW LEGAL MOVES",
		"kind": SettingRow.Kind.TOGGLE,
		"helper": "Marks the cells where a move is legal.",
	},
]

@onready var _backdrop: Backdrop = %Backdrop
@onready var _scrim: ColorRect = %Scrim
@onready var _panel: JuicePanel = %Panel
@onready var _back: JuiceButton = %BackButton

var _overlay_mode := false
var _rows: Array[SettingRow] = []
## True while a row is being refreshed from storage, so the write-back that
## refresh would otherwise trigger cannot loop.
var _syncing := false


## Every box on the screen, derived rather than authored. Static and free of the
## scene tree so the builder script can audit the numbers the screen draws.
##
## Returns `panel` and `back` as Rect2 and `rows` as one rect per entry in ROWS,
## each sized to what its SettingRow actually paints: the control band, plus the
## helper line where the row carries one.
static func layout() -> Dictionary:
	# Both columns take the width of the widest row anywhere on the screen, so
	# every helper line has the same measure to wrap into and the two columns
	# read as one grid. SettingRow refuses to be narrower than its own label
	# plus its control, so the width is asked for rather than assumed.
	var widths: Array[float] = []
	var mins: Array[Vector2] = []
	var column_w := 0.0
	for spec: Dictionary in ROWS:
		var probe := SettingRow.new()
		probe.label = String(spec["label"])
		probe.kind = int(spec["kind"]) as SettingRow.Kind
		probe.helper = String(spec["helper"])
		probe.update_minimum_size()
		var wanted := probe.get_combined_minimum_size()
		probe.free()
		mins.append(wanted)
		widths.append(wanted.x)
		column_w = maxf(column_w, wanted.x)

	# JuicePanel paints its title and rule from its own top edge, so the first
	# row starts below that block. PAD_PANEL alone would put it on the rule.
	var card := JuicePanel.new()
	card.title = TITLE
	var header := card.content_top()
	card.free()

	var offsets: Array[Vector2] = []
	var heights: Array[float] = []
	var cursor: Array[float] = [0.0, 0.0]
	var block := 0.0
	for i in ROWS.size():
		var spec: Dictionary = ROWS[i]
		var helper := String(spec["helper"])
		var height: float = mins[i].y
		if not helper.is_empty():
			# Measured at the width it will wrap to, not assumed to be one line.
			height = maxf(height, SettingRow.BAND_H + SettingRow.HELPER_GAP
				+ Design.text_height(helper, column_w, Design.FS_SMALL))
		var column := 0 if i < COLUMN_SPLIT else 1
		var y: float = cursor[column]
		offsets.append(Vector2((column_w + Design.SPACE_XL) * float(column), y))
		heights.append(height)
		block = maxf(block, y + height)
		cursor[column] = y + height + Design.SPACE_MD

	var panel_w := column_w * 2.0 + Design.SPACE_XL + Design.PAD_PANEL * 2.0
	var panel_h := (
		header + block + Design.SPACE_XL + Design.BUTTON_H + Design.PAD_PANEL
	)
	var panel := Rect2(
		(PAGE - Vector2(panel_w, panel_h)) * 0.5, Vector2(panel_w, panel_h)
	)
	var origin := panel.position + Vector2(Design.PAD_PANEL, header)

	var rows: Array[Rect2] = []
	for i in offsets.size():
		rows.append(Rect2(origin + offsets[i], Vector2(column_w, heights[i])))

	return {
		"panel": panel,
		"rows": rows,
		"back": Rect2(
			origin.x,
			origin.y + block + Design.SPACE_XL,
			Design.BUTTON_W,
			Design.BUTTON_H
		),
	}


func _ready() -> void:
	# The overlay route runs over a paused tree, and the standalone route does
	# not care, so ALWAYS is correct either way.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_mode = _resolve_overlay()
	var plan := layout()

	_backdrop.accent = Design.PINK
	_backdrop.visible = not _overlay_mode
	# A parent CanvasItem paints before its children, so index 0 alone would
	# still put the bands over anything drawn above them.
	_backdrop.show_behind_parent = true

	var shade := Design.INK
	shade.a = SCRIM_ALPHA
	_scrim.color = shade
	_scrim.visible = _overlay_mode
	_scrim.mouse_filter = (
		Control.MOUSE_FILTER_STOP if _overlay_mode else Control.MOUSE_FILTER_IGNORE
	)

	var panel_rect: Rect2 = plan["panel"]
	_panel.position = panel_rect.position
	_panel.size = panel_rect.size
	_panel.accent = Design.PINK
	_panel.title = TITLE

	var back_rect: Rect2 = plan["back"]
	_back.position = back_rect.position
	_back.size = back_rect.size
	_back.text = "BACK"
	_back.accent = Design.PINK
	_back.intro_style = JuiceButton.IntroStyle.RISE
	_back.pressed.connect(_on_back_pressed)

	_build_rows(plan["rows"])
	_wire_focus()
	Settings.changed.connect(_on_settings_changed)

	_panel.pop_in()
	_back.play_intro(0.18)
	if not _rows.is_empty():
		_rows[0].call_deferred(&"grab_focus")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_on_back_pressed()


## Overlay when a caller said so, or when this screen is not the scene the tree
## is currently running. Stage.go assigns current_scene before the node enters
## the tree, so the second test is settled by the time _ready runs.
func _resolve_overlay() -> bool:
	if overlay:
		return true
	return get_tree().current_scene != self


func _build_rows(rects: Array) -> void:
	for i in ROWS.size():
		var spec: Dictionary = ROWS[i]
		var rect: Rect2 = rects[i]
		var row := SettingRow.new()
		row.name = "Row_" + String(spec["key"]).replace("/", "_")
		row.label = String(spec["label"])
		row.kind = int(spec["kind"]) as SettingRow.Kind
		row.helper = String(spec["helper"])
		row.accent = Design.PINK
		row.position = rect.position
		row.size = rect.size
		row.set_meta(&"key", spec["key"])
		add_child(row)
		row.set_value(Settings.get_value(String(spec["key"]), _fallback(spec)))
		row.value_changed.connect(_on_row_changed.bind(row))
		_rows.append(row)


## The row's own resting value, used only when Settings has never heard of the
## key. Settings owns the real defaults; this keeps a typo from writing a float
## into a bool key.
func _fallback(spec: Dictionary) -> Variant:
	return 0.5 if int(spec["kind"]) == SettingRow.Kind.SLIDER else false


## Godot's geometric focus search gives up at the ends of a column, so the ring
## is written out: seven rows and then BACK, wrapping at both ends. It stays one
## ring across both columns, since a slider row spends ui_left and ui_right on
## its own value and cannot also use them to change column.
func _wire_focus() -> void:
	var chain: Array[Control] = []
	for row in _rows:
		chain.append(row)
	chain.append(_back)
	for i in chain.size():
		var previous := chain[(i - 1 + chain.size()) % chain.size()]
		var next := chain[(i + 1) % chain.size()]
		chain[i].focus_neighbor_top = previous.get_path()
		chain[i].focus_previous = previous.get_path()
		chain[i].focus_neighbor_bottom = next.get_path()
		chain[i].focus_next = next.get_path()


## Settings applies audio, fullscreen and juice itself, so writing the value is
## the whole of "applies live" for those. game/show_hints is read by the game
## screen on its next redraw.
func _on_row_changed(value: Variant, row: SettingRow) -> void:
	if _syncing:
		return
	Settings.set_value(String(row.get_meta(&"key")), value)


## Two rows move together: turning reduced motion on also silences juice, and a
## screen showing a stale toggle would be lying about what it just did.
func _on_settings_changed(key: String, value: Variant) -> void:
	_syncing = true
	for row in _rows:
		if String(row.get_meta(&"key")) == key:
			row.set_value(value)
	_syncing = false


func _on_back_pressed() -> void:
	# Emitted before the fallback so the two routes cannot both fire: a pause
	# menu that connected `closed` owns the exit, and Stage never hears about it.
	var listening := not closed.get_connections().is_empty()
	closed.emit()
	if not listening:
		Stage.go(TITLE_SCENE)
