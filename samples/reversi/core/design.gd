@tool
class_name Design
extends RefCounted

## Every colour, metric, space and duration the game draws with.
##
## Nothing here holds instance state. Widgets read the constants directly rather
## than carrying their own copies, so a retune lands everywhere at once.
##
## The design box is 2560 by 1440. Screens lay out against that, and
## `canvas_items` stretch fits it to whatever window the player has.

# --- Chrome -----------------------------------------------------------------

const INK := Color("0b0f14") ## Outlines and the hard offset drop shadows.
const NIGHT := Color("1b2430") ## Page background.
const NIGHT_HI := Color("243040") ## Raised panel face.
const NIGHT_LO := Color("121a24") ## Sunken well.
const CREAM := Color("f2efe6") ## Primary text.
const GOLD := Color("f5c242") ## Primary accent and focus ring.
const CYAN := Color("4fd6ff") ## Informational accent.
const PINK := Color("ff4f8b") ## Tertiary accent.
const MINT := Color("6ee7a0") ## Positive delta.
const RED := Color("e5484d") ## Negative delta and the last-move ring.

## Body text that should sit back from a heading without becoming unreadable.
const CREAM_MUTED := Color(0.949, 0.937, 0.902, 0.72)
const CREAM_FAINT := Color(0.949, 0.937, 0.902, 0.5)

# --- Board ------------------------------------------------------------------

const FELT := Color("1b5337") ## The board surface.
const FELT_LINE := Color("0e3221") ## Grid lines, one step darker than the felt.
const FELT_EDGE := Color("0a2418") ## Frame around the playable area.
const DISC_BLACK := Color("14181d")
const DISC_WHITE := Color("f2efe6")
const DISC_EDGE := Color("05080b") ## Outline carried by both discs.
const HINT := Color(1.0, 0.82, 0.25, 0.45) ## Legal-move marker.
# Alpha solved against the felt, not in the abstract: at 0.28 the marker sank
# into FELT and read as a smudge rather than an invitation.

# --- The space scale --------------------------------------------------------
#
# Every gap in the game comes from this ladder. Hand-picked spacing is what
# produced the first pass's overlaps: a number chosen for one screen has nothing
# holding it in agreement with the screen beside it.

const SPACE_XS := 8.0
const SPACE_SM := 16.0
const SPACE_MD := 32.0
const SPACE_LG := 56.0
const SPACE_XL := 88.0
const SPACE_XXL := 136.0

## Distance from a screen edge to any content. Nothing sits outside this.
const MARGIN_PAGE := 128.0

## Distance from a panel's own edge to its contents.
const PAD_PANEL := 48.0

# --- Metrics ----------------------------------------------------------------
#
# The board geometry is load-bearing. Playtests click cell centres by pixel, so
# BOARD_ORIGIN and CELL are fixed points of the design rather than free choices.
# They scale with the design box: at 1440p the board is 960px across a 2560px
# page, the same 37.5% of the width it held at 720p.

const SIZE := 8
const BOARD_ORIGIN := Vector2(320.0, 240.0)
const CELL := 120.0
const BOARD_PX := 960.0 ## CELL * SIZE.
const DISC_RADIUS := 48.0 ## 0.40 * CELL, which leaves a 12px gutter each side.
const HINT_RADIUS := 20.0
const FRAME_WIDTH := 20.0
const PLATE_SKEW := 28.0 ## Lean on a plate's top edge. The shape signature.
const SHADOW_OFF := Vector2(12.0, 12.0)

## Right of the board, separated by SPACE_XL. Height matches the board's.
const PANEL_RECT := Rect2(1368.0, 240.0, 1064.0, 960.0)

## Standard control sizes, so two screens cannot disagree about how tall a
## button is.
const BUTTON_H := 108.0
const BUTTON_W := 680.0
const BUTTON_W_WIDE := 840.0
const ROW_H := 112.0

# --- Timing -----------------------------------------------------------------

const T_HOVER := 0.22 ## TRANS_BACK / EASE_OUT.
const T_PRESS_IN := 0.06 ## Linear. A press must register before it can settle.
const T_PRESS_OUT := 0.22 ## TRANS_BACK / EASE_OUT.
const T_POP_IN := 0.40 ## TRANS_BACK / EASE_OUT.
const T_POP_OUT := 0.25 ## TRANS_BACK / EASE_IN.
const T_MENU_STAGGER := 0.06
const T_WIPE := 0.42
const T_DISC_DROP := 0.26
const T_FLIP_HALF := 0.11 ## scale.x 1 to 0 then 0 to 1, so one flip runs 0.22s.
const T_FLIP_STAGGER := 0.045 ## Per ring of distance out from the placed cell.
const T_COUNTER_ROLL := 0.55 ## Scaled by magnitude, clamped to [0.12, 1.1].
const T_TOAST_IN := 0.24
const T_TOAST_HOLD := 1.40
const T_TOAST_OUT := 0.26

# --- Type -------------------------------------------------------------------
#
# Bungee throughout, no secondary face. Sizes are the 720p scale doubled, so the
# type holds the same proportion of the page it always did.

const FS_HERO := 168
const FS_H1 := 96
const FS_H2 := 64
const FS_BODY := 40
const FS_SMALL := 30

## Offset of the hard ink drop shadow, in pixels, for a given font size.
##
## A flat offset does not work across a scale this wide. Solved by eye at 1440p:
## 8px sits right under a 96px heading and reads as a second copy of the text
## under a 30px label, which is exactly what a flat 8 produced on the pause hint.
## One twelfth holds the same visual weight from FS_SMALL up to FS_HERO.
static func shadow_for(font_size: int) -> int:
	return maxi(2, roundi(float(font_size) / 12.0))


## Extra pixels between glyphs for a tracked-out label. Bungee is a display face
## and a small size reads better opened up.
const TRACK_LABEL := 6.0

const FONT_PATH := "res://assets/fonts/Bungee-Regular.ttf"

## Cached because a font load per redraw would show up in the frame time.
## Held in a static var, which outlives a scene reload in the editor, so
## clear_cache() exists for teardown to call.
static var _font: Font = null


static func font() -> Font:
	if _font != null:
		return _font
	if ResourceLoader.exists(FONT_PATH):
		var loaded: Resource = load(FONT_PATH)
		if loaded is Font:
			_font = loaded
			return _font
	_font = ThemeDB.fallback_font
	return _font


static func clear_cache() -> void:
	_font = null


static func disc_colour(player: int) -> Color:
	return DISC_BLACK if player == 1 else DISC_WHITE


static func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < SIZE and cell.y >= 0 and cell.y < SIZE


static func cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(BOARD_ORIGIN + Vector2(cell) * CELL, Vector2(CELL, CELL))


static func cell_centre(cell: Vector2i) -> Vector2:
	return BOARD_ORIGIN + Vector2(cell) * CELL + Vector2(CELL, CELL) * 0.5


## Returns (-1, -1) for a point outside the board, which callers treat as a miss.
static func cell_at(point: Vector2) -> Vector2i:
	var local := point - BOARD_ORIGIN
	if local.x < 0.0 or local.y < 0.0:
		return Vector2i(-1, -1)
	var cell := Vector2i(int(local.x / CELL), int(local.y / CELL))
	return cell if in_bounds(cell) else Vector2i(-1, -1)


## A plate is a rectangle whose top edge leans right by `skew`. Drawn as a
## polygon rather than a StyleBox so every corner stays a tweenable float.
static func plate(size: Vector2, skew: float = PLATE_SKEW) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(skew, 0.0),
		Vector2(size.x, 0.0),
		Vector2(size.x - skew, size.y),
		Vector2(0.0, size.y),
	])


## Same polygon, translated by `offset`, for the shadow pass.
static func plate_offset(
		size: Vector2, offset: Vector2, skew: float = PLATE_SKEW
) -> PackedVector2Array:
	var shape := plate(size, skew)
	for i in shape.size():
		shape[i] += offset
	return shape


## Height a block of text occupies once wrapped to `width`. Screens stack
## sections on measured heights rather than a guessed pitch, which is what stops
## a long line from running under whatever sits below it.
static func text_height(body: String, width: float, font_size: int) -> float:
	var face := font()
	if face == null or body.is_empty():
		return 0.0
	return face.get_multiline_string_size(
		body, HORIZONTAL_ALIGNMENT_LEFT, width, font_size
	).y
