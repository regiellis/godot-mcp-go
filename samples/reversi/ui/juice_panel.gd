@tool
class_name JuicePanel
extends Control

## The glass card everything else sits on: a translucent [Design.NIGHT_HI] face,
## an accent spine down the leading edge, and the same hard offset shadow the
## buttons carry.
##
## Drawn in [method _draw] rather than assembled from a StyleBox so the whole
## card is one tweenable pair of floats, and so the spine can follow the plate's
## lean instead of sitting square against a skewed face.

const FACE_ALPHA := 0.86
const SPINE_WIDTH := Design.SPACE_XS
const TITLE_INSET := Design.SPACE_MD
const TITLE_TRACKING := Design.TRACK_LABEL ## Bungee needs the air when small.
const TITLE_RULE_GAP := Design.SPACE_SM
const RULE_WIDTH := 2.0
const RULE_ALPHA := 0.35

@export var accent: Color = Design.GOLD:
	set(value):
		accent = value
		queue_redraw()

@export var title: String = "":
	set(value):
		title = value
		queue_redraw()

@export var show_spine: bool = true:
	set(value):
		show_spine = value
		queue_redraw()

var _pop: float = 1.0:
	set(value):
		_pop = value
		queue_redraw()

var _alpha: float = 1.0:
	set(value):
		_alpha = value
		queue_redraw()

var _pop_tween: Tween


func _ready() -> void:
	# A card is scenery. Letting it swallow clicks would break every widget
	# parented to it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Scales up from nothing and fades in. [param delay] staggers a row of cards.
func pop_in(delay: float = 0.0) -> void:
	_pop = 0.0
	_alpha = 0.0
	if not is_inside_tree():
		return
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = create_tween().set_parallel(true)
	_pop_tween.tween_property(self, ^"_pop", 1.0, Design.T_POP_IN).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_property(self, ^"_alpha", 1.0, Design.T_POP_IN * 0.5).set_delay(delay) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func pop_out(delay: float = 0.0) -> void:
	if not is_inside_tree():
		_pop = 0.0
		_alpha = 0.0
		return
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = create_tween().set_parallel(true)
	_pop_tween.tween_property(self, ^"_pop", 0.0, Design.T_POP_OUT).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_pop_tween.tween_property(self, ^"_alpha", 0.0, Design.T_POP_OUT).set_delay(delay) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


## The first y inside the card a screen can put its own contents on without
## running into the title block. A card with no title gives back PAD_PANEL, so a
## caller can ask unconditionally.
func content_top() -> float:
	if title.is_empty():
		return Design.PAD_PANEL
	var use_font := Design.font()
	if use_font == null:
		return Design.PAD_PANEL
	var rule_y := TITLE_INSET + use_font.get_ascent(Design.FS_SMALL)
	rule_y += use_font.get_descent(Design.FS_SMALL) + TITLE_RULE_GAP
	return rule_y + Design.SPACE_MD


func _draw() -> void:
	var alpha := clampf(_alpha, 0.0, 1.0)
	if alpha <= 0.001 or size.x <= 0.0 or size.y <= 0.0:
		return

	var centre := size * 0.5
	# Floored at zero because the BACK ease dips below it, and a negative scale
	# would mirror the card.
	var stretch := Vector2.ONE * maxf(_pop, 0.0)

	var face := Design.plate(size)
	for i in face.size():
		face[i] = centre + (face[i] - centre) * stretch

	var shadow := PackedVector2Array(face)
	for i in shadow.size():
		shadow[i] += Design.SHADOW_OFF

	var shade := Design.INK
	shade.a *= alpha * 0.9
	draw_colored_polygon(shadow, shade)

	var fill := Design.NIGHT_HI
	fill.a = FACE_ALPHA * alpha
	draw_colored_polygon(face, fill)

	if show_spine:
		_draw_spine(face, alpha)

	if not title.is_empty():
		_draw_title(centre, stretch, alpha)


## A parallelogram hugging the leading edge rather than a stroked line, so the
## whole 8px sits inside the face however far the plate leans.
func _draw_spine(face: PackedVector2Array, alpha: float) -> void:
	var top := face[0]
	var bottom := face[3]
	var spine := PackedVector2Array([
		top,
		top + Vector2(SPINE_WIDTH, 0.0),
		bottom + Vector2(SPINE_WIDTH, 0.0),
		bottom,
	])
	var edge := accent
	edge.a *= alpha
	draw_colored_polygon(spine, edge)


func _draw_title(centre: Vector2, stretch: Vector2, alpha: float) -> void:
	var use_font := Design.font()
	if use_font == null:
		return

	var ink := accent
	ink.a *= alpha
	var origin := Vector2(
		TITLE_INSET + Design.PLATE_SKEW,
		TITLE_INSET + use_font.get_ascent(Design.FS_SMALL)
	)

	draw_set_transform_matrix(
		Transform2D(0.0, stretch, 0.0, centre - centre * stretch))

	var caps := title.to_upper()
	var pen := origin
	for i in caps.length():
		var glyph := caps[i]
		draw_char(use_font, pen, glyph, Design.FS_SMALL, ink)
		pen.x += use_font.get_char_size(caps.unicode_at(i), Design.FS_SMALL).x + TITLE_TRACKING

	var rule_y := origin.y + use_font.get_descent(Design.FS_SMALL) + TITLE_RULE_GAP
	var rule := accent
	rule.a *= alpha * RULE_ALPHA
	draw_line(
		Vector2(origin.x, rule_y),
		Vector2(size.x - TITLE_INSET, rule_y),
		rule, RULE_WIDTH
	)

	draw_set_transform_matrix(Transform2D.IDENTITY)
