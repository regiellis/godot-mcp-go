extends Control

## The first scene the game runs, and the only one whose job is the next one.
##
## Nothing here is decoration. It paints [constant Design.INK] so the cut to
## splash is invisible, then spends its frames pulling every screen scene and
## every font size into memory one item per frame, so the first real transition
## does not stall on a load the player can see.

## Every screen, listed rather than discovered: a directory scan finds these in
## the editor and finds nothing in an exported build. A path not on disk yet is
## skipped, so boot works while the rest of the game is still being written and
## gets faster as each screen lands.
const PRELOAD_PATHS: PackedStringArray = [
	"res://screens/splash/splash.tscn",
	"res://screens/intro/intro.tscn",
	"res://screens/title/title.tscn",
	"res://screens/setup/setup.tscn",
	"res://screens/game/game.tscn",
	"res://screens/pause/pause.tscn",
	"res://screens/result/result.tscn",
	"res://screens/how_to_play/how_to_play.tscn",
	"res://screens/settings/settings.tscn",
	"res://screens/credits/credits.tscn",
]

const SPLASH_PATH := "res://screens/splash/splash.tscn"
const TITLE_PATH := "res://screens/title/title.tscn"

## Kept in step with `WORDMARK_SIZE` in splash.gd, which owns it. A const there
## cannot be read from here, so the one number lives in two places and this is
## the copy that only warms an atlas.
const SPLASH_WORDMARK_SIZE := 144

## Caps, lowercase, digits and the punctuation the score readouts and the
## credits URLs need. Drawn once per size to force the atlas to build here
## rather than on the frame that first shows real text.
const WARM_GLYPHS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:/-"

## A bar that flashes for three frames is worse than no bar at all, so it waits
## until there is genuinely something to report and then stays readable.
const BAR_DELAY := 0.45
const BAR_MIN_HOLD := 0.7

## As wide as the board and as thick as a SPACE_MD gap, centred on the page.
const BAR_SIZE := Vector2(Design.BOARD_PX, Design.SPACE_MD)

## Scenes that were found on disk, in preload order.
var _paths: PackedStringArray = []

## The type scale, filled in _ready: a const initialiser may not reach into
## another script, so these cannot be a const here.
var _warm_sizes: PackedInt32Array = []

## Godot's resource cache holds weak references, so a loaded scene stays cached
## only while something still points at it. These are handed to Stage on the way
## out, because dropping them when boot frees would undo the entire warm-up.
var _held: Array[Resource] = []

var _step := 0
var _elapsed := 0.0

## Wall time the bar appeared, or negative while it is still hidden.
var _bar_shown_at := -1.0

## Size to rasterise on this frame, or 0 on a frame that loads a scene instead.
var _warm_size := 0

var _routed := false


## The one box this screen draws. Static so the builder audits the shipped
## layout rather than a second copy of the same arithmetic.
static func layout(page: Vector2) -> Dictionary:
	if page.x <= 0.0 or page.y <= 0.0:
		return {}
	return {
		"ProgressBar": Rect2((page - BAR_SIZE) * 0.5, BAR_SIZE),
	}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for path in PRELOAD_PATHS:
		if ResourceLoader.exists(path):
			_paths.append(path)
	# The type scale, plus the splash logotype's own size. That one is off the
	# scale and it is the first text the player sees, so leaving it out would
	# put the stall on exactly the frame this screen exists to protect.
	_warm_sizes = PackedInt32Array([
		Design.FS_HERO, Design.FS_H1, Design.FS_H2, Design.FS_BODY, Design.FS_SMALL,
		SPLASH_WORDMARK_SIZE,
	])


func _process(delta: float) -> void:
	if _routed:
		return
	_elapsed += delta

	if _step < _total_steps():
		_advance_one()
		if _bar_shown_at < 0.0 and _elapsed >= BAR_DELAY:
			_bar_shown_at = _elapsed
		queue_redraw()
		return

	# Work is done. A bar that has already been seen owes the player its minimum
	# hold; one that never appeared routes on the same frame.
	if _bar_shown_at >= 0.0 and _elapsed - _bar_shown_at < BAR_MIN_HOLD:
		queue_redraw()
		return
	_route()


func _total_steps() -> int:
	return _paths.size() + _warm_sizes.size()


## One item per frame, on the main thread. Threaded loading would finish sooner
## and then pay the whole cost back on the frame that instantiates.
func _advance_one() -> void:
	if _step < _paths.size():
		var loaded: Resource = ResourceLoader.load(_paths[_step])
		if loaded != null:
			_held.append(loaded)
		_warm_size = 0
	else:
		_warm_size = _warm_sizes[_step - _paths.size()]
	_step += 1


func _route() -> void:
	_routed = true
	set_process(false)
	# Parked on the autoload that outlives every screen. Boot is about to be
	# freed and it is the only thing holding these open.
	Stage.set_meta(&"boot_warm_scenes", _held)
	var seen := bool(Settings.get_value("game/seen_intro", false))
	var target := TITLE_PATH if seen else SPLASH_PATH
	if not ResourceLoader.exists(target):
		target = TITLE_PATH
	Stage.go_immediate(target)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Design.INK)
	if _warm_size > 0:
		_warm_glyphs()
	if _bar_shown_at >= 0.0:
		_draw_bar()


## Drawn at zero alpha and in the corner: shaping and rasterising still run and
## the atlas still fills, only the blit comes out to nothing.
func _warm_glyphs() -> void:
	var use_font := Design.font()
	if use_font == null:
		return
	draw_string(
		use_font, Vector2(8.0, 8.0), WARM_GLYPHS,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _warm_size, Color(1.0, 1.0, 1.0, 0.0)
	)


func _draw_bar() -> void:
	var boxes := layout(size)
	if boxes.is_empty():
		return
	var bar: Rect2 = boxes["ProgressBar"]
	var total := _total_steps()
	var ratio := 1.0 if total <= 0 else clampf(float(_step) / float(total), 0.0, 1.0)
	draw_rect(bar, Design.NIGHT_LO)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), Design.GOLD)
