@tool
class_name Wipe
extends CanvasLayer

## The screen transition: a rake of skewed ink bands sweeping the viewport.
##
## Owned by the Stage autoload, which adds one instance and drives it. Cover and
## reveal are two forward gestures with mirrored band geometry rather than one
## tween played backwards, because a reversed sweep reads as a rewind.

signal covered()
signal revealed()

enum Gesture { COVER, REVEAL }

## Unchanged by the move to 1440p. The design box kept its 16:9 aspect, so a
## band is the same slice of the page it always was, at the same 12.5:1 ratio of
## width to height. Adding bands would be a redesign, not a rescale.
const BAND_COUNT := 7

## Normalised head start per band. The BAND_COUNT - 1 lags plus one band's own
## span fill the whole 0..1 progress, so every band lands as the sweep ends.
const BAND_LAG := 0.06

## Multiplies the plate lean up to something a full-width band can carry.
const LEAN_SCALE := 3.5

## Keeps a band's leading corner off screen at either end of its travel.
const EDGE_PAD := Design.SPACE_SM

var _canvas: Control = null
var _tween: Tween = null
var _gesture: int = Gesture.COVER
var _progress: float = 0.0:
	set(value):
		_progress = value
		if _canvas != null:
			_canvas.queue_redraw()


func _init() -> void:
	layer = 128
	# A transition has to keep running while the tree is paused, or opening the
	# pause menu would freeze the wipe halfway across the screen.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_canvas = Control.new()
	_canvas.name = "WipeCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_canvas_draw)
	add_child(_canvas)
	_fit_to_viewport()
	var viewport := get_viewport()
	if viewport != null:
		viewport.size_changed.connect(_fit_to_viewport)


func is_busy() -> bool:
	return _tween != null and _tween.is_valid()


## Sweeps from clear to fully covered over Design.T_WIPE. Await the returned
## signal to know the outgoing screen is hidden. A second call while the cover
## is already running joins the sweep in flight instead of stacking a tween.
func cover() -> Signal:
	if _gesture == Gesture.COVER:
		if is_busy():
			return covered
		if _progress >= 1.0:
			covered.emit.call_deferred()
			return covered
	_start(Gesture.COVER)
	return covered


## Sweeps from covered back to clear over Design.T_WIPE.
func reveal() -> Signal:
	if _gesture == Gesture.REVEAL:
		if is_busy():
			return revealed
		if _progress >= 1.0:
			revealed.emit.call_deferred()
			return revealed
	_start(Gesture.REVEAL)
	return revealed


func _start(gesture: int) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_gesture = gesture
	_progress = 0.0
	if _canvas != null:
		# Swallow clicks for the whole transition, so a stray press cannot land
		# on the outgoing screen behind the ink.
		_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_tween = create_tween()
	_tween.tween_property(self, ^"_progress", 1.0, Design.T_WIPE)
	_tween.tween_callback(_on_sweep_done)


func _on_sweep_done() -> void:
	if _gesture == Gesture.COVER:
		covered.emit()
		return
	if _canvas != null:
		_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	revealed.emit()


func _fit_to_viewport() -> void:
	var viewport := get_viewport()
	if viewport == null or _canvas == null:
		return
	_canvas.position = Vector2.ZERO
	_canvas.size = viewport.get_visible_rect().size
	_canvas.queue_redraw()


func _on_canvas_draw() -> void:
	var extent := _canvas.size
	if extent.x <= 0.0 or extent.y <= 0.0:
		return
	var band_height := extent.y / float(BAND_COUNT)
	var lean := Design.PLATE_SKEW * LEAN_SCALE
	for i in BAND_COUNT:
		var t := _band_progress(i)
		# A cover band before its cue has no ink on screen yet; a reveal band
		# past its cue has already carried its ink off. Everything between the
		# two, a reveal band still waiting included, is a polygon worth drawing.
		var offstage := (t <= 0.0) if _gesture == Gesture.COVER else (t >= 1.0)
		if offstage:
			continue
		var top := band_height * float(i)
		# One extra pixel of height, or the seam between two bands shows as a
		# hairline of the screen underneath.
		var bottom := top + band_height + 1.0
		var poly: PackedVector2Array
		if _gesture == Gesture.COVER:
			poly = _cover_band(top, bottom, extent.x, lean, 1.0 - pow(1.0 - t, 2.0))
		else:
			poly = _reveal_band(top, bottom, extent.x, lean, t * t)
		_canvas.draw_colored_polygon(poly, Design.INK)


## Where one band sits in its own 0..1 travel. The reveal rakes from the far
## band back, so the two gestures never share a leading edge.
func _band_progress(index: int) -> float:
	var order := index if _gesture == Gesture.COVER else BAND_COUNT - 1 - index
	var span := 1.0 - float(BAND_COUNT - 1) * BAND_LAG
	return clampf((_progress - float(order) * BAND_LAG) / span, 0.0, 1.0)


## Cover: the top edge leads, so the ink tips right as it crosses.
static func _cover_band(
		top: float, bottom: float, width: float, lean: float, t: float
) -> PackedVector2Array:
	var back := -lean - EDGE_PAD
	var edge := lerpf(back, width, t)
	return PackedVector2Array([
		Vector2(back, top),
		Vector2(edge + lean, top),
		Vector2(edge, bottom),
		Vector2(back, bottom),
	])


## Reveal: mirrored. The bottom edge clears first, so the diagonal tips the
## other way and the gesture reads as a second sweep, not a rewind.
static func _reveal_band(
		top: float, bottom: float, width: float, lean: float, t: float
) -> PackedVector2Array:
	var edge := lerpf(-lean - EDGE_PAD, width + EDGE_PAD, t)
	var front := width + lean + EDGE_PAD * 2.0
	return PackedVector2Array([
		Vector2(edge, top),
		Vector2(front, top),
		Vector2(front, bottom),
		Vector2(edge + lean, bottom),
	])
