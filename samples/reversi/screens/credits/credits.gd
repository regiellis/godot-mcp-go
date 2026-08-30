extends Control

## Who and what the sample is built out of, plus a column of discs turning over
## beside it.
##
## Reached from the title only, so unlike `settings` and `how_to_play` there is
## no overlay route and no scrim: BACK always goes back through Stage.
##
## Nothing on this screen is placed by hand. `layout()` derives every box from
## the space ladder and from text measured at the width it will actually wrap
## to, and the builder script audits those same boxes before it saves.

const TITLE_SCENE := "res://screens/title/title.tscn"

## The design box. `canvas_items` stretch fits it to the player's window, so
## every coordinate below is in these units.
const PAGE := Vector2(2560.0, 1440.0)

const HEADING := "CREDITS"

## Discs in the ornament column on the right.
const DISC_COUNT := 8

## The left column takes the first two sections and the right column the other
## four. The split is forced by BACK: the left column has to stop clear of it
## while the right one runs on to the bottom margin, and the two longest bodies
## are the first two in reading order.
const COLUMN_SPLIT := 2

## Verbatim from the copy deck. A body is one string rather than the deck's own
## lines, because the deck breaks for reading the deck and this column is a
## different width. A link line carries a label only where the deck gives one.
const SECTIONS: Array[Dictionary] = [
	{
		"label": "THE GAME",
		"body": "Reversi, built end to end by an agent driving the Godot editor"
			+ " through godot-mcp. The board, every widget, and every transition"
			+ " are drawn in code. There are no sprites.",
		"links": [],
	},
	{
		"label": "THE TOOL",
		"body": "godot-mcp is a Go CLI and MCP server that drives the Godot"
			+ " editor over a local WebSocket, plus the editor addon it talks to."
			+ " Released under the MIT licence.",
		"links": [
			{"label": "REPOSITORY", "url": "github.com/regiellis/godot-mcp-go"},
			{"label": "DOCS", "url": "regiellis.github.io/godot-mcp-go/docs"},
		],
	},
	{
		"label": "AUTHOR",
		"body": "godot-mcp is built and maintained by Regi Ellis.",
		"links": [{"label": "", "url": "github.com/regiellis"}],
	},
	{
		"label": "SOUND",
		"body": "Sound effects by Kenney, released under CC0.",
		"links": [{"label": "", "url": "kenney.nl"}],
	},
	{
		"label": "TYPE",
		"body": "Bungee by David Jonathan Ross, used under the SIL Open Font"
			+ " License 1.1.",
		"links": [{"label": "", "url": "github.com/djrrb/Bungee"}],
	},
	{
		"label": "ENGINE",
		"body": "Godot Engine 4.7",
		"links": [{"label": "", "url": "godotengine.org"}],
	},
]

@onready var _backdrop: Backdrop = %Backdrop
@onready var _back: JuiceButton = %BackButton

var _ink: Ink = null
var _discs: DiscColumn = null


## Every box on the screen, derived rather than authored. Static and free of the
## scene tree so the builder script can audit the same numbers the screen draws.
##
## Returns `heading`, `back` and `ornament` as Rect2, and `sections` as one
## entry per section carrying its own rect and the y its body and links start at.
static func layout() -> Dictionary:
	var face := Design.font()
	var small_h := face.get_height(Design.FS_SMALL)
	var heading_h := face.get_height(Design.FS_H1)
	var heading_w := face.get_string_size(
		HEADING, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1
	).x

	var ornament_w := Design.DISC_RADIUS * 2.0
	var ornament_x := PAGE.x - Design.MARGIN_PAGE - ornament_w
	# The text stops a full SPACE_XXL short of the ornament, which is what keeps
	# the two apart in the audit however long a body wraps.
	var text_w := ornament_x - Design.SPACE_XXL - Design.MARGIN_PAGE
	var column_w := (text_w - Design.SPACE_LG) / 2.0

	var top := Design.MARGIN_PAGE + heading_h + Design.SPACE_XL
	var cursor: Array[float] = [top, top]
	var sections: Array[Dictionary] = []
	for i in SECTIONS.size():
		var spec: Dictionary = SECTIONS[i]
		var column := 0 if i < COLUMN_SPLIT else 1
		var x := Design.MARGIN_PAGE + (column_w + Design.SPACE_LG) * float(column)
		var y: float = cursor[column]
		var body := String(spec["body"])
		var links: Array = spec["links"]
		var body_top := y + small_h + Design.SPACE_XS
		var body_h := Design.text_height(body, column_w, Design.FS_BODY)
		var links_top := body_top + body_h + Design.SPACE_XS
		var height := small_h + Design.SPACE_XS + body_h
		if not links.is_empty():
			height += Design.SPACE_XS + small_h * float(links.size())
		sections.append({
			"label": String(spec["label"]),
			"body": body,
			"links": links,
			"rect": Rect2(x, y, column_w, height),
			"body_top": body_top,
			"links_top": links_top,
		})
		cursor[column] = y + height + Design.SPACE_LG

	var pitch := ornament_w + Design.SPACE_MD
	var ornament_h := pitch * float(DISC_COUNT - 1) + ornament_w
	var ornament_y := Design.MARGIN_PAGE + (
		PAGE.y - Design.MARGIN_PAGE * 2.0 - ornament_h
	) * 0.5

	return {
		"heading": Rect2(
			Design.MARGIN_PAGE, Design.MARGIN_PAGE, heading_w, heading_h
		),
		"sections": sections,
		"ornament": Rect2(ornament_x, ornament_y, ornament_w, ornament_h),
		"back": Rect2(
			Design.MARGIN_PAGE,
			PAGE.y - Design.MARGIN_PAGE - Design.BUTTON_H,
			Design.BUTTON_W,
			Design.BUTTON_H
		),
	}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var plan := layout()

	_backdrop.accent = Design.GOLD
	# A parent CanvasItem paints before its children, so index 0 alone would
	# still put the bands over anything drawn above them.
	_backdrop.show_behind_parent = true

	var back_rect: Rect2 = plan["back"]
	_back.position = back_rect.position
	_back.size = back_rect.size
	_back.text = "BACK"
	_back.accent = Design.GOLD
	_back.intro_style = JuiceButton.IntroStyle.RISE
	_back.pressed.connect(_on_back_pressed)

	_discs = DiscColumn.new()
	_discs.name = "Discs"
	_discs.field = plan["ornament"]
	_discs.count = DISC_COUNT
	add_child(_discs)

	_ink = Ink.new()
	_ink.name = "Ink"
	_ink.heading = HEADING
	_ink.heading_rect = plan["heading"]
	_ink.sections = plan["sections"]
	_ink.accent = Design.GOLD
	add_child(_ink)

	move_child(_back, get_child_count() - 1)
	_back.play_intro(0.2)
	_back.call_deferred(&"grab_focus")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_on_back_pressed()


func _on_back_pressed() -> void:
	Stage.go(TITLE_SCENE)


## The heading and the six sections. A child rather than the screen root's own
## _draw, because the root paints before the Backdrop it contains.
class Ink extends Control:
	var heading: String = ""
	var heading_rect := Rect2()
	var sections: Array = []
	var accent: Color = Design.GOLD

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		var face := Design.font()
		if face == null:
			return
		var baseline := heading_rect.position + Vector2(
			0.0, face.get_ascent(Design.FS_H1)
		)
		draw_string(
			face, baseline + Vector2.ONE * Design.SPACE_XS, heading,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1, Design.INK
		)
		draw_string(
			face, baseline, heading,
			HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_H1, Design.CREAM
		)
		for section: Dictionary in sections:
			_draw_section(face, section)

	func _draw_section(face: Font, section: Dictionary) -> void:
		var rect: Rect2 = section["rect"]
		_draw_tracked(
			face,
			Vector2(rect.position.x, rect.position.y + face.get_ascent(Design.FS_SMALL)),
			String(section["label"]), Design.FS_SMALL, accent
		)
		draw_multiline_string(
			face,
			Vector2(
				rect.position.x,
				float(section["body_top"]) + face.get_ascent(Design.FS_BODY)
			),
			String(section["body"]), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x,
			Design.FS_BODY, -1, Design.CREAM
		)
		_draw_links(face, section)

	## Link lines sit on one label column so the two URLs under THE TOOL start at
	## the same x. The column is measured from this section's own labels, so a
	## section whose links carry no label loses the indent entirely.
	func _draw_links(face: Font, section: Dictionary) -> void:
		var links: Array = section["links"]
		if links.is_empty():
			return
		var rect: Rect2 = section["rect"]
		var line_h := face.get_height(Design.FS_SMALL)
		var indent := 0.0
		for link: Dictionary in links:
			var text := String(link["label"])
			if text.is_empty():
				continue
			indent = maxf(indent, face.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL
			).x + Design.SPACE_MD)
		for i in links.size():
			var link: Dictionary = links[i]
			var baseline := Vector2(
				rect.position.x,
				float(section["links_top"]) + line_h * float(i)
					+ face.get_ascent(Design.FS_SMALL)
			)
			var text := String(link["label"])
			if not text.is_empty():
				draw_string(
					face, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
					Design.FS_SMALL, Design.CREAM_FAINT
				)
			draw_string(
				face, baseline + Vector2(indent, 0.0), String(link["url"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, Design.FS_SMALL, Design.CYAN
			)

	## Section labels are tracked wide, which draw_string cannot do, so the pen
	## is advanced by hand a glyph at a time.
	func _draw_tracked(
			face: Font, origin: Vector2, text: String, font_size: int, ink: Color
	) -> void:
		var pen := origin
		for i in text.length():
			draw_char(face, pen, text[i], font_size, ink)
			pen.x += face.get_char_size(text.unicode_at(i), font_size).x + Design.TRACK_LABEL


## Eight discs turning over on a slow offset sine: the board's flip animation
## held at rest and used as ornament. It is decoration, so reduced motion parks
## it rather than hiding it, and the phase offset still reads as a wave.
class DiscColumn extends Control:
	## One full turn every 4 seconds, each disc a sixth of a turn behind the one
	## above it, so the column reads as a wave rather than eight discs in step.
	const PERIOD := 4.0
	const PHASE_STEP := TAU / 12.0

	## Below this the disc is edge on and the ellipse is a line, so the outline
	## is dropped rather than drawn as a stray dark bar. The floor also keeps
	## the draw transform out of a zero determinant.
	const EDGE_ON := 0.04
	const MIN_SQUEEZE := 0.02
	const OUTLINE := 4.0

	var field := Rect2()
	var count := 8

	var _time := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _process(delta: float) -> void:
		if not _motion_allowed():
			return
		_time = fmod(_time + delta, PERIOD)
		queue_redraw()

	func _draw() -> void:
		if count <= 0 or field.size.x <= 0.0:
			return
		var radius := field.size.x * 0.5
		var pitch := radius * 2.0 + Design.SPACE_MD
		for i in count:
			var phase := TAU * (_time / PERIOD) + float(i) * PHASE_STEP
			var squeeze := cos(phase)
			var centre := field.position + Vector2(radius, radius + pitch * float(i))
			# Odd indices start on the other colour, and the disc swaps colour
			# as it passes edge on, which is what makes it read as a flip.
			var face := ReversiBoard.BLACK if (i % 2 == 0) == (squeeze >= 0.0) \
					else ReversiBoard.WHITE
			draw_set_transform(centre, 0.0, Vector2(maxf(absf(squeeze), MIN_SQUEEZE), 1.0))
			draw_circle(Vector2.ZERO, radius, Design.disc_colour(face))
			if absf(squeeze) > EDGE_ON:
				draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Design.DISC_EDGE, OUTLINE)
			draw_set_transform_matrix(Transform2D.IDENTITY)

	## Looked up by path rather than by name, and treated as on when absent, so
	## the column still turns in a scene opened on its own.
	func _motion_allowed() -> bool:
		if Engine.is_editor_hint():
			return false
		var juice := get_node_or_null(^"/root/Juice")
		if juice == null:
			return true
		return bool(juice.enabled)
