@tool
extends VBoxContainer

## In-editor MCP dashboard, docked on the right: the side-dock twin of the
## `godot-mcp dashboard` web UI (both surfaces stay; this one costs no process
## and no port).
##
## Data comes from command_router.stats_snapshot() IN-PROCESS — never a stats.*
## call over the wire, for the same reason the router excludes stats.* from its
## own counters: a dashboard that measures itself is measuring noise.
##
## Design language is ported from internal/dashboard/assets/app.css, translated
## to the editor's own palette: flat blocks, 1px hairlines, ZERO corner radius,
## no shadows, uppercase micro-labels, big mono numerals, Godot blue as the one
## constant accent. Everything else derives from the editor theme, so a light
## editor gets a light panel for free.
##
## Two standing hazards this file is written against:
## - A dock is narrow and tall. Nothing may derive a large minimum size from its
##   content, or the dock refuses to be dragged narrow; every variable label
##   clips with an ellipsis and every column width is a fixed constant.
## - The editor runs at 1x, 1.25x, 1.5x, 2x. EVERY dimension and font size goes
##   through _s(), or fonts scale while the boxes holding them do not (at 2x
##   that clipped "PLAYING" to "PLAYIN").

const REFRESH_SEC := 1.0
const FEED_MAX_ROWS := 100        # trimmed oldest-first; the router keeps 200
const GAP_MS := 5 * 60 * 1000     # quiet stretch that earns a separator row
const CADENCE_BUCKETS := 10       # one bar per minute, oldest → newest
const CADENCE_HOT := 8            # bars from this index on are the "now" accent
const SLOW_MS := 1000             # duration that earns the warn tint
const ERR_PARAM_CLIP := 140
const TOP_GROUPS := 6             # narrower than the web's 8: this is a dock
const RECENT_ERRORS := 3
const GROUP_CHIPS := 4
## Fit-content rows settle their height a frame late, so "parked at the bottom"
## has to tolerate a pixel or two of rounding or follow-mode detaches by itself.
const SCROLL_EPSILON := 2.0
## The WS server keeps its bound port private; the discovery file it writes is
## the published contract (and the single writer), so read that rather than
## reaching into another node's internals. Ports only move on bind/rebind.
const DISCOVERY_PATH := "res://.godot/godot-mcp.json"
const PORT_RECHECK_MS := 10000

## Godot blue, #2b7fff. The one colour that does NOT derive from the editor
## theme — it is the brand mark, the same accent the web dashboard uses. Spelled
## as floats so it stays a foldable constant expression.
const ACCENT := Color(0.169, 0.498, 1.0)

# Feed column widths, in logical px (run through _s at build time).
const COL_TIME := 52
const COL_CHIP := 56
const COL_DUR := 44

var _router: Node  # command_router.gd; set by plugin.gd via setup()

var _timer: Timer
var _built := false
var _scale := 1.0

# --- Header + banner
var _brand_square: ColorRect
var _play_dot: ColorRect
var _reset_button: Button
var _reset_dialog: ConfirmationDialog
var _banner: PanelContainer
var _banner_chip: Label
var _banner_text: Label

# --- Stat block
var _calls_value: Label
var _errors_value: Label
var _errors_sub: Label
var _conn_value: Label
var _conn_sub: Label
var _cmds_value: Label
var _uptime_value: Label

# --- Cadence
var _cadence: Control
var _cadence_pcts := PackedFloat32Array()
var _cadence_empty := true

# --- Sections
var _session_values: Array[Label] = []  # order matches _SESSION_ROWS
var _group_rows: Array[Dictionary] = []  # {row, name, bar, count}
var _group_fracs := PackedFloat32Array()
var _err_rows: Array[Dictionary] = []  # {row, time, method, params}
var _err_empty: Label
var _err_micro: Label

# --- Timeline
var _chip_all: Button
var _chip_err: Button
var _group_chips: Array[Button] = []
var _follow_button: Button
var _feed_scroll: ScrollContainer
var _feed_rows: VBoxContainer
var _feed_empty: Label
var _filter := "all"
var _stick := true  # follow the tail unless the user scrolled away from it

# High-water mark for the incremental append (newest row already rendered).
var _last_ts := 0
var _last_method := ""
var _prev_row_ts := 0
var _last_total := 0
var _last_uptime := 0

# --- Palette, re-derived on NOTIFICATION_THEME_CHANGED
var _mono_font: Font
var _bold_font: Font
var _col_panel := Color(0.16, 0.17, 0.19)
var _col_field := Color(0.13, 0.14, 0.15)
var _col_hair := Color(0.24, 0.25, 0.27)
var _col_ink := Color(0.87, 0.88, 0.89)
var _col_muted := Color(0.87, 0.88, 0.89, 0.55)
var _col_mid := Color(0.87, 0.88, 0.89, 0.32)
var _col_ok := Color(0.34, 0.73, 0.42)
var _col_err := Color(0.88, 0.33, 0.38)
var _col_warn := Color(0.88, 0.65, 0.33)
var _col_err_wash := Color(0.88, 0.33, 0.38, 0.10)
var _col_err_row := Color(0.88, 0.33, 0.38, 0.06)

# Shared styleboxes: mutating one repaints every control using it, which is what
# makes a theme swap cheap here (no rebuild, no per-row walk for backgrounds).
var _sb_lattice: StyleBoxFlat   # hairline field behind the stat cells
var _sb_panel: StyleBoxFlat     # a flat cell/section block
var _sb_banner: StyleBoxFlat    # error banner wash + bottom rule
var _sb_chip: StyleBoxFlat      # feed group chip
var _sb_errchip: StyleBoxFlat   # ERR chip, white on err
var _sb_row: StyleBoxFlat       # ok feed row: bottom hairline
var _sb_errrow: StyleBoxFlat    # err feed row: wash + 4px left rule
var _sb_gap: StyleBoxFlat       # gap strip: field tone, hairline top/bottom
var _sb_btn_idle: StyleBoxFlat  # chip button, released
var _sb_btn_on: StyleBoxFlat    # chip button, active (inverted)
var _sb_btn_err: StyleBoxFlat   # ERR chip button, released

var _ws_port := 0
var _http_port := 0
var _ports_checked_ms := -PORT_RECHECK_MS
var _tz_offset_sec := 0

const _SESSION_ROWS := [
	"Game", "Active conn", "Total conn", "Commands", "Uptime", "WS port", "HTTP port",
]


func _init() -> void:
	# The dock tab label IS the node name, so this has to be set before
	# plugin.gd calls add_control_to_dock.
	name = "MCP"


func _ready() -> void:
	_tz_offset_sec = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	_cadence_pcts.resize(CADENCE_BUCKETS)
	_group_fracs.resize(TOP_GROUPS)
	_resolve_theme()
	_build_ui()

	_timer = Timer.new()
	_timer.wait_time = REFRESH_SEC
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_built = true  # only now is every member the refresh and theme paths touch real

	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _notification(what: int) -> void:
	# Theme swaps are rare and cheap to absorb: re-derive the palette, mutate the
	# shared styleboxes in place, re-apply the tagged colours and fills.
	if what == NOTIFICATION_THEME_CHANGED and _built:
		_resolve_theme()
		_repaint(self)
		_cadence.queue_redraw()
		for entry: Dictionary in _group_rows:
			(entry["bar"] as Control).queue_redraw()


## Hand the panel its data source. Called by plugin.gd once the router exists.
func setup(router: Node) -> void:
	_router = router
	if is_visible_in_tree():
		_refresh()


## Every dimension and font size in this file goes through here. The editor
## scales its fonts by this factor; a raw constant beside a scaled font is the
## bug that clipped "PLAYING" to "PLAYIN" at 2x.
func _s(px: float) -> int:
	return int(round(px * _scale))


# --- Layout -----------------------------------------------------------------


func _build_ui() -> void:
	add_theme_constant_override("separation", _s(6))
	_build_header()
	_build_banner()
	_build_summary_and_feed()


func _build_header() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", _s(6))
	add_child(row)

	_brand_square = _make_square(row, _s(8), "accent")
	# The brand block is constant text, so it is deliberately NOT clipped: a
	# clipped label beside an expanding spacer would collapse to nothing.
	var brand := Label.new()
	brand.text = "godot-mcp"
	brand.add_theme_font_size_override("font_size", _s(12))
	if _bold_font != null:
		brand.add_theme_font_override("font", _bold_font)
	brand.set_meta("gm_bold", true)
	_tint(brand, "ink")
	row.add_child(brand)

	var tag := Label.new()
	tag.text = "editor"
	tag.add_theme_font_size_override("font_size", _s(9))
	_mono(tag)
	_tint(tag, "muted")
	row.add_child(tag)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	# Square dot, never round: zero radius is the signature of this language.
	_play_dot = _make_square(row, _s(8), "muted")
	_play_dot.mouse_filter = Control.MOUSE_FILTER_STOP  # it owns a tooltip
	_play_dot.tooltip_text = "Game: STOPPED"

	_reset_button = Button.new()
	_reset_button.text = "RESET"
	_reset_button.tooltip_text = "Clear the call counters and the recorded history."
	_reset_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_chip_button(_reset_button, false)
	_reset_button.pressed.connect(_on_reset_pressed)
	row.add_child(_reset_button)

	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.title = "Reset MCP stats"
	_reset_dialog.dialog_text = "Reset call counters and history?"
	_reset_dialog.confirmed.connect(_on_reset_confirmed)
	add_child(_reset_dialog)


func _build_banner() -> void:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", _sb_banner)
	_banner.visible = false
	add_child(_banner)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", _s(6))
	_banner.add_child(row)

	_banner_chip = Label.new()
	_banner_chip.text = "ERR"
	_banner_chip.add_theme_font_size_override("font_size", _s(9))
	_banner_chip.add_theme_stylebox_override("normal", _sb_errchip)
	_banner_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_chip.custom_minimum_size = Vector2(_s(34), 0)
	_banner_chip.clip_text = true
	_mono(_banner_chip)
	_tint(_banner_chip, "on_err")
	row.add_child(_banner_chip)

	_banner_text = Label.new()
	_banner_text.add_theme_font_size_override("font_size", _s(10))
	_banner_text.clip_text = true
	_banner_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_banner_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tint(_banner_text, "err")
	row.add_child(_banner_text)


## The summary sections share one scroll; the feed keeps its own and a generous
## minimum, so a short dock steals height from the summary, never from the feed.
func _build_summary_and_feed() -> void:
	var summary := ScrollContainer.new()
	summary.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	summary.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	summary.custom_minimum_size = Vector2(0, _s(110))
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	summary.size_flags_stretch_ratio = 1.0
	add_child(summary)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", _s(8))
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_child(stack)

	_build_stat_block(stack)
	_build_cadence_block(stack)
	_build_session_section(stack)
	_build_groups_section(stack)
	_build_errors_section(stack)

	var feed := VBoxContainer.new()
	feed.add_theme_constant_override("separation", _s(4))
	feed.custom_minimum_size = Vector2(0, _s(190))
	feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feed.size_flags_stretch_ratio = 1.6
	add_child(feed)
	_build_feed(feed)


## The stat lattice: a hairline-filled panel whose children sit 1px apart, so the
## gaps read as gridlines (the web's `gap:1px; background:var(--gridline)`).
func _build_stat_block(parent: VBoxContainer) -> void:
	var lattice := PanelContainer.new()
	lattice.add_theme_stylebox_override("panel", _sb_lattice)
	parent.add_child(lattice)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _s(1))
	lattice.add_child(col)

	# TOOL CALLS leads, full width and biggest numeral.
	var lead := _make_stat_cell(col, "TOOL CALLS", 34, "")
	_calls_value = lead["value"]

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", _s(1))
	grid.add_theme_constant_override("v_separation", _s(1))
	col.add_child(grid)

	var errors := _make_stat_cell(grid, "ERRORS", 22, "")
	_errors_value = errors["value"]
	_errors_sub = errors["sub"]
	var conn := _make_stat_cell(grid, "CONNECTIONS", 22, "")
	_conn_value = conn["value"]
	_conn_sub = conn["sub"]
	(conn["cell"] as Control).tooltip_text = "WebSocket peers attached right now. The in-editor HTTP MCP endpoint answers per request and holds no connection, so its clients never show up here."
	var cmds := _make_stat_cell(grid, "COMMANDS", 22, "across the addon")
	_cmds_value = cmds["value"]
	var uptime := _make_stat_cell(grid, "UPTIME", 22, "")
	_uptime_value = uptime["value"]
	(uptime["cell"] as Control).tooltip_text = "Time since the addon started, or since the last counter reset."


func _make_stat_cell(parent: Node, title: String, num_size: int, sub_text: String) -> Dictionary:
	var cell := PanelContainer.new()
	cell.add_theme_stylebox_override("panel", _sb_panel)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.custom_minimum_size = Vector2(_s(70), 0)
	parent.add_child(cell)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", _s(2))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(box)
	box.add_child(_make_micro(title))

	var value := Label.new()
	value.text = "—"
	value.add_theme_font_size_override("font_size", _s(num_size))
	value.clip_text = true
	value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_mono(value)
	_tint(value, "ink")
	box.add_child(value)

	var sub := Label.new()
	sub.text = sub_text
	sub.add_theme_font_size_override("font_size", _s(9))
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.visible = not sub_text.is_empty()  # no empty line under a bare numeral
	_mono(sub)
	_tint(sub, "muted")
	box.add_child(sub)

	return {"cell": cell, "value": value, "sub": sub}


func _build_cadence_block(parent: VBoxContainer) -> void:
	var block := PanelContainer.new()
	block.add_theme_stylebox_override("panel", _sb_panel)
	block.tooltip_text = "Calls per minute over the last 10 minutes, oldest bar on the left. Bar height is relative to the busiest minute, and the window is the newest 50 calls the router keeps."
	parent.add_child(block)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", _s(4))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block.add_child(box)
	box.add_child(_make_micro("CALLS / MIN"))

	_cadence = Control.new()
	_cadence.custom_minimum_size = Vector2(_s(60), _s(40))
	_cadence.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cadence.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cadence.draw.connect(_on_cadence_draw)
	_cadence.resized.connect(_cadence.queue_redraw)
	box.add_child(_cadence)


func _build_session_section(parent: VBoxContainer) -> void:
	var body := _make_section(parent, "SESSION", false)["body"] as VBoxContainer
	for i in _SESSION_ROWS.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", _s(6))
		body.add_child(row)

		var k := Label.new()
		k.text = String(_SESSION_ROWS[i])
		k.add_theme_font_size_override("font_size", _s(11))
		k.clip_text = true
		k.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tint(k, "muted")
		row.add_child(k)

		var v := Label.new()
		v.text = "—"
		v.add_theme_font_size_override("font_size", _s(11))
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.clip_text = true
		v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.custom_minimum_size = Vector2(_s(50), 0)
		_mono(v)
		_tint(v, "ink")
		row.add_child(v)
		_session_values.append(v)

		if i < _SESSION_ROWS.size() - 1:
			body.add_child(_make_rule(_s(1), "hair"))


func _build_groups_section(parent: VBoxContainer) -> void:
	var body := _make_section(parent, "TOP GROUPS", false)["body"] as VBoxContainer
	for i in TOP_GROUPS:
		var block := VBoxContainer.new()
		block.add_theme_constant_override("separation", _s(3))
		block.mouse_filter = Control.MOUSE_FILTER_STOP  # the block owns the tooltip
		block.visible = false
		body.add_child(block)

		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", _s(6))
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		block.add_child(head)

		var name_lbl := Label.new()
		name_lbl.add_theme_font_size_override("font_size", _s(11))
		name_lbl.clip_text = true
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mono(name_lbl)
		_tint(name_lbl, "ink")
		head.add_child(name_lbl)

		var count := Label.new()
		count.add_theme_font_size_override("font_size", _s(11))
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.custom_minimum_size = Vector2(_s(34), 0)
		count.clip_text = true
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mono(count)
		_tint(count, "muted")
		head.add_child(count)

		var bar := Control.new()
		bar.custom_minimum_size = Vector2(_s(24), _s(4))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.draw.connect(_on_group_bar_draw.bind(bar, i))
		bar.resized.connect(bar.queue_redraw)
		block.add_child(bar)

		_group_rows.append({"row": block, "name": name_lbl, "bar": bar, "count": count})


func _build_errors_section(parent: VBoxContainer) -> void:
	var section := _make_section(parent, "RECENT ERRORS", true)
	var body := section["body"] as VBoxContainer
	_err_micro = section["micro"] as Label
	for _i in RECENT_ERRORS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", _s(6))
		row.visible = false
		body.add_child(row)

		var time_lbl := Label.new()
		time_lbl.add_theme_font_size_override("font_size", _s(10))
		time_lbl.custom_minimum_size = Vector2(_s(COL_TIME), 0)
		time_lbl.clip_text = true
		_mono(time_lbl)
		_tint(time_lbl, "err")
		row.add_child(time_lbl)

		var body_box := VBoxContainer.new()
		body_box.add_theme_constant_override("separation", 0)
		body_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(body_box)

		var method_lbl := Label.new()
		method_lbl.add_theme_font_size_override("font_size", _s(11))
		method_lbl.clip_text = true
		method_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_mono(method_lbl)
		_tint(method_lbl, "ink")
		body_box.add_child(method_lbl)

		var params_lbl := Label.new()
		params_lbl.add_theme_font_size_override("font_size", _s(9))
		params_lbl.clip_text = true
		params_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_mono(params_lbl)
		_tint(params_lbl, "muted")
		body_box.add_child(params_lbl)

		_err_rows.append({"row": row, "time": time_lbl, "method": method_lbl, "params": params_lbl})

	_err_empty = _make_body_text("No errors in the recent window.")
	body.add_child(_err_empty)


func _build_feed(parent: VBoxContainer) -> void:
	_make_section(parent, "TIMELINE", false)

	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", _s(4))
	parent.add_child(chip_row)

	# Chips wrap: a dock is narrow and six of them will not sit on one line.
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", _s(4))
	flow.add_theme_constant_override("v_separation", _s(4))
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip_row.add_child(flow)

	var group := ButtonGroup.new()  # one active filter at a time, for free
	_chip_all = _make_chip(flow, group, "all")
	_chip_all.button_pressed = true
	_chip_err = _make_chip(flow, group, "err")
	_style_chip_button(_chip_err, true)
	for _i in GROUP_CHIPS:
		var chip := _make_chip(flow, group, "")
		chip.visible = false
		_group_chips.append(chip)

	_follow_button = Button.new()
	_follow_button.toggle_mode = true
	_follow_button.button_pressed = true
	_follow_button.text = "TAIL"
	_follow_button.tooltip_text = "Follow the newest call. Scrolling up releases it."
	_follow_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_chip_button(_follow_button, false)
	_apply_icon(_follow_button, "ArrowDown")
	_follow_button.toggled.connect(_on_follow_toggled)
	chip_row.add_child(_follow_button)

	# Column header stays OUTSIDE the scroll, so it never scrolls away (the web
	# needs position:sticky for the same effect).
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", _s(6))
	parent.add_child(head)
	head.add_child(_make_micro("TIME", _s(COL_TIME)))
	head.add_child(_make_micro("GROUP", _s(COL_CHIP)))
	var method_head := _make_micro("METHOD")
	method_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(method_head)
	var dur_head := _make_micro("DUR", _s(COL_DUR))
	dur_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(dur_head)
	parent.add_child(_make_rule(_s(2), "ink"))

	_feed_scroll = ScrollContainer.new()
	# Horizontal scrolling off: the method column ellipsizes instead, which is
	# what the web's narrow layout does too.
	_feed_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_feed_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_feed_scroll.custom_minimum_size = Vector2(0, _s(80))
	_feed_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_feed_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_feed_scroll)

	_feed_rows = VBoxContainer.new()
	_feed_rows.add_theme_constant_override("separation", 0)
	_feed_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feed_scroll.add_child(_feed_rows)

	var bar := _feed_scroll.get_v_scroll_bar()
	bar.value_changed.connect(_on_scroll_value_changed)
	bar.changed.connect(_on_scroll_range_changed)

	_feed_empty = _make_body_text("No activity yet. Drive the editor with a godot-mcp command.")
	parent.add_child(_feed_empty)

	_update_chips()  # seed the ALL/ERR counts before the first snapshot lands


## A section head in the web's `.panel-head` idiom: uppercase micro title over a
## 2px rule (err-coloured for the errors section), then the body.
func _make_section(parent: VBoxContainer, title: String, err: bool) -> Dictionary:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", _s(3))
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(section)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", _s(6))
	section.add_child(head)

	var title_lbl := _make_micro(title)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if err:
		_tint(title_lbl, "err")
	head.add_child(title_lbl)

	var micro := _make_micro("")  # unclipped: short constant text, sizes to itself
	micro.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(micro)

	section.add_child(_make_rule(_s(2), "err" if err else "ink"))

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", _s(4))
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(body)
	return {"section": section, "body": body, "micro": micro}


## Uppercase micro-label: the workhorse of this design language.
##
## Clipping is tied to min_width on purpose. A clipped label reports a minimum
## width of ~1px, so a NON-expanding one inside an HBox collapses to nothing —
## clip only the fixed-width columns, and let the short constant captions size
## to themselves.
func _make_micro(text: String, min_width: int = 0) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_size_override("font_size", _s(9))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if min_width > 0:
		lbl.custom_minimum_size = Vector2(min_width, 0)
		lbl.clip_text = true
		lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_tint(lbl, "muted")
	return lbl


func _make_body_text(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", _s(10))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(_s(40), 0)
	_tint(lbl, "muted")
	return lbl


## A flat 1px/2px rule. ColorRect, not a stylebox: it is the cheapest thing that
## can be re-coloured on a theme swap.
func _make_rule(thickness: int, kind: String) -> ColorRect:
	var rule := ColorRect.new()
	rule.custom_minimum_size = Vector2(0, thickness)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(rule, kind)
	return rule


func _make_square(parent: Node, size_px: int, kind: String) -> ColorRect:
	var sq := ColorRect.new()
	sq.custom_minimum_size = Vector2(size_px, size_px)
	sq.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sq.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(sq, kind)
	parent.add_child(sq)
	return sq


## A filter chip. NOT clip_text: an HFlowContainer lays children out at their
## minimum size, and a clipped Button reports a minimum that ignores its label,
## which would render every chip as an empty box.
func _make_chip(parent: Node, group: ButtonGroup, filter: String) -> Button:
	var chip := Button.new()
	chip.toggle_mode = true
	chip.button_group = group
	chip.add_theme_font_size_override("font_size", _s(10))
	chip.set_meta("filter", filter)
	chip.text = filter.to_upper()
	_style_chip_button(chip, false)
	chip.pressed.connect(_on_chip_pressed.bind(chip))
	parent.add_child(chip)
	return chip


## Flat square chip button: hairline border, transparent fill, inverted when
## active. Tagged so a theme swap can restyle it without a rebuild.
func _style_chip_button(button: Button, err: bool) -> void:
	button.set_meta("gm_chipbtn", err)
	var idle := _sb_btn_err if err else _sb_btn_idle
	button.add_theme_stylebox_override("normal", idle)
	button.add_theme_stylebox_override("hover", idle)
	button.add_theme_stylebox_override("focus", idle)
	button.add_theme_stylebox_override("disabled", idle)
	button.add_theme_stylebox_override("pressed", _sb_btn_on)
	button.add_theme_color_override("font_color", _col_err if err else _col_muted)
	button.add_theme_color_override("font_hover_color", _col_ink)
	button.add_theme_color_override("font_focus_color", _col_ink)
	button.add_theme_color_override("font_pressed_color", _col_panel)
	button.add_theme_color_override("font_hover_pressed_color", _col_panel)


# --- Refresh ----------------------------------------------------------------


## A hidden dock must cost nothing per frame, so the timer follows visibility
## rather than running for the session.
func _on_visibility_changed() -> void:
	if not _built:
		return
	if is_visible_in_tree():
		_refresh()
		_timer.start()
		return
	_timer.stop()


func _refresh() -> void:
	if _router == null or not is_instance_valid(_router):
		return
	if not _router.has_method("stats_snapshot"):
		return
	# by_group/by_method come back as live references to the router's own
	# dictionaries: read them, never write them.
	var snap: Dictionary = _router.stats_snapshot()
	_read_ports()
	_update_header(snap)
	_update_stats(snap)
	_update_session(snap)
	_update_groups(snap)
	_update_errors(snap)
	_update_feed(snap)


func _update_header(snap: Dictionary) -> void:
	var playing := bool(snap.get("playing", false))
	_fill(_play_dot, "ok" if playing else "muted")
	_play_dot.tooltip_text = "Game: PLAYING" if playing else "Game: STOPPED"

	# Banner: the newest failure in the recent window, or nothing.
	var recent: Array = snap.get("recent", [])  # newest-first
	for e: Dictionary in recent:
		if bool(e.get("ok", true)):
			continue
		_banner_text.text = "%s failed %s" % [String(e.get("method", "")), _clock(int(e.get("ts", 0)))]
		_banner.visible = true
		return
	_banner.visible = false


func _update_stats(snap: Dictionary) -> void:
	var total := int(snap.get("total_calls", 0))
	var errors := int(snap.get("errors", 0))
	_calls_value.text = str(total)
	_errors_value.text = str(errors)
	_tint(_errors_value, "err" if errors > 0 else "ink")
	_errors_sub.text = "%d%% of calls" % (errors * 100 / total if total > 0 else 0)
	_errors_sub.visible = true  # built hidden (empty at build time), filled here
	_conn_value.text = str(int(snap.get("active_connections", 0)))
	_conn_sub.text = "of %d total" % int(snap.get("total_connections", 0))
	_conn_sub.visible = true
	_cmds_value.text = str(int(snap.get("command_count", 0)))
	_uptime_value.text = _human_dur(int(snap.get("uptime_ms", 0)))

	_compute_cadence(snap.get("recent", []))
	_cadence.queue_redraw()


func _update_session(snap: Dictionary) -> void:
	var playing := bool(snap.get("playing", false))
	var values := [
		"PLAYING" if playing else "STOPPED",
		str(int(snap.get("active_connections", 0))),
		str(int(snap.get("total_connections", 0))),
		str(int(snap.get("command_count", 0))),
		_human_dur(int(snap.get("uptime_ms", 0))),
		str(_ws_port) if _ws_port > 0 else "—",
		str(_http_port) if _http_port > 0 else "off",
	]
	for i in mini(values.size(), _session_values.size()):
		_session_values[i].text = String(values[i])
	_tint(_session_values[0], "ok" if playing else "ink")


func _update_groups(snap: Dictionary) -> void:
	var by_group: Dictionary = snap.get("by_group", {})
	var by_method: Dictionary = snap.get("by_method", {})
	var sorted := _sorted_kv(by_group)
	var peak := 0 if sorted.is_empty() else int((sorted[0] as Array)[1])
	for i in _group_rows.size():
		var entry := _group_rows[i]
		var block: Control = entry["row"]
		if i >= sorted.size():
			block.visible = false
			continue
		var pair: Array = sorted[i]
		var key := String(pair[0])
		var count := int(pair[1])
		block.visible = true
		(entry["name"] as Label).text = key
		(entry["count"] as Label).text = str(count)
		_group_fracs[i] = (float(count) / float(peak)) if peak > 0 else 0.0
		(entry["bar"] as Control).queue_redraw()
		# The web UI never surfaced the per-method breakdown; in-editor it costs
		# a tooltip.
		block.tooltip_text = _group_tooltip(key, by_method)


func _group_tooltip(group: String, by_method: Dictionary) -> String:
	var scoped := {}
	var prefix := group + "."
	for method: String in by_method:
		if method.begins_with(prefix):
			scoped[method] = by_method[method]
	var lines: Array[String] = []
	for pair: Array in _sorted_kv(scoped):
		if lines.size() >= 8:
			break
		lines.append("%s  %d" % [pair[0], int(pair[1])])
	return "\n".join(lines)


func _update_errors(snap: Dictionary) -> void:
	var recent: Array = snap.get("recent", [])  # newest-first
	_err_micro.text = "LAST %d" % recent.size()
	var shown := 0
	for e: Dictionary in recent:
		if shown >= _err_rows.size():
			break
		if bool(e.get("ok", true)):
			continue
		var entry := _err_rows[shown]
		(entry["row"] as Control).visible = true
		(entry["time"] as Label).text = _clock(int(e.get("ts", 0)))
		(entry["method"] as Label).text = String(e.get("method", ""))
		var params := _clip(String(e.get("params", "")), ERR_PARAM_CLIP)
		var params_lbl: Label = entry["params"]
		params_lbl.text = params
		params_lbl.visible = not params.is_empty()
		shown += 1
	for i in range(shown, _err_rows.size()):
		(_err_rows[i]["row"] as Control).visible = false
	_err_empty.visible = shown == 0


func _update_feed(snap: Dictionary) -> void:
	var total := int(snap.get("total_calls", 0))
	var uptime := int(snap.get("uptime_ms", 0))
	# A counter that walked backwards means stats.reset (or a router restart):
	# the rendered tail no longer describes anything.
	if total < _last_total or uptime < _last_uptime:
		_clear_feed()
	_last_total = total
	_last_uptime = uptime

	var recent: Array = snap.get("recent", [])
	var ordered: Array = []
	for i in range(recent.size() - 1, -1, -1):  # snapshot is newest-first
		ordered.append(recent[i])

	var start := _feed_start_index(ordered)
	for i in range(start, ordered.size()):
		_append_feed_row(ordered[i])

	if start < ordered.size():
		_trim_feed()
		_update_chips()
		_apply_filter()
		if _stick:
			_snap_to_bottom()
	_feed_empty.visible = _feed_rows.get_child_count() == 0


## Index of the first entry newer than what is already rendered. The marker is
## ts+method because two calls can share a millisecond; when it has aged out of
## the router's 50-entry window, fall back to the timestamp.
func _feed_start_index(ordered: Array) -> int:
	if _last_ts <= 0:
		return 0
	for i in range(ordered.size() - 1, -1, -1):
		var e: Dictionary = ordered[i]
		if int(e.get("ts", 0)) == _last_ts and String(e.get("method", "")) == _last_method:
			return i + 1
	for i in ordered.size():
		if int((ordered[i] as Dictionary).get("ts", 0)) > _last_ts:
			return i
	return ordered.size()


func _append_feed_row(entry: Dictionary) -> void:
	var ts := int(entry.get("ts", 0))
	if _prev_row_ts > 0 and ts - _prev_row_ts > GAP_MS:
		_feed_rows.add_child(_make_gap_row((ts - _prev_row_ts) / 60000, ts))
	_feed_rows.add_child(_make_feed_row(entry))
	_prev_row_ts = ts
	_last_ts = ts
	_last_method = String(entry.get("method", ""))


## One feed row. Newest rows land at the BOTTOM: this is a live tail like the
## Output panel, which inverts the web dashboard's newest-first order. Params
## live in the row TOOLTIP — the dock has no width for a params column, and a
## tooltip carries the whole string, which the web layout cannot.
func _make_feed_row(entry: Dictionary) -> Control:
	var method := String(entry.get("method", ""))
	var group := method.get_slice(".", 0)
	var ok := bool(entry.get("ok", true))
	var ms := int(entry.get("ms", 0))
	var params := String(entry.get("params", ""))

	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _sb_row if ok else _sb_errrow)
	row.tooltip_text = params

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", _s(6))
	main.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var time_lbl := Label.new()
	time_lbl.text = _clock(int(entry.get("ts", 0)))
	time_lbl.add_theme_font_size_override("font_size", _s(10))
	time_lbl.custom_minimum_size = Vector2(_s(COL_TIME), 0)
	time_lbl.clip_text = true
	_mono(time_lbl)
	_tint(time_lbl, "err" if not ok else "muted")
	main.add_child(time_lbl)

	var chip := Label.new()
	chip.text = "ERR" if not ok else group.to_upper()
	chip.add_theme_font_size_override("font_size", _s(9))
	chip.add_theme_stylebox_override("normal", _sb_errchip if not ok else _sb_chip)
	chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chip.custom_minimum_size = Vector2(_s(COL_CHIP), 0)
	chip.clip_text = true
	chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_mono(chip)
	_tint(chip, "on_err" if not ok else "muted")
	main.add_child(chip)

	var method_lbl := Label.new()
	method_lbl.text = method
	method_lbl.add_theme_font_size_override("font_size", _s(11))
	method_lbl.clip_text = true
	method_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	method_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mono(method_lbl)
	_tint(method_lbl, "err" if not ok else "ink")
	main.add_child(method_lbl)

	var dur_lbl := Label.new()
	dur_lbl.text = _dur(ms)
	dur_lbl.add_theme_font_size_override("font_size", _s(10))
	dur_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	dur_lbl.custom_minimum_size = Vector2(_s(COL_DUR), 0)
	dur_lbl.clip_text = true
	_mono(dur_lbl)
	_tint(dur_lbl, "warn" if ms >= SLOW_MS else "muted")
	main.add_child(dur_lbl)

	if ok or params.is_empty():
		row.add_child(main)
	else:
		# Failures keep their params on a second line inside the washed block,
		# where there is room to read them.
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", _s(1))
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(main)
		var detail := Label.new()
		detail.text = _clip(params, ERR_PARAM_CLIP)
		detail.add_theme_font_size_override("font_size", _s(9))
		detail.clip_text = true
		detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_mono(detail)
		_tint(detail, "err")
		stack.add_child(detail)
		row.add_child(stack)

	row.set_meta("group", group)
	row.set_meta("ok", ok)
	row.set_meta("gap", false)
	return row


func _make_gap_row(minutes: int, ts: int) -> Control:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _sb_gap)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", _s(6))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)

	var lbl := _make_micro("GAP · %d MIN" % minutes)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(lbl)

	var clock := Label.new()
	clock.text = _clock(ts)  # fixed-width time; unclipped so it stays visible
	clock.add_theme_font_size_override("font_size", _s(9))
	_mono(clock)
	_tint(clock, "muted")
	box.add_child(clock)

	row.set_meta("gap", true)
	return row


func _clear_feed() -> void:
	for row in _feed_rows.get_children():
		_feed_rows.remove_child(row)
		row.queue_free()
	_last_ts = 0
	_last_method = ""
	_prev_row_ts = 0


func _trim_feed() -> void:
	while _feed_rows.get_child_count() > FEED_MAX_ROWS:
		var row := _feed_rows.get_child(0)
		_feed_rows.remove_child(row)
		row.queue_free()


## Chip counts describe the rows actually in the feed, not the router's window.
func _update_chips() -> void:
	var total := 0
	var errors := 0
	var counts := {}
	for row in _feed_rows.get_children():
		if bool(row.get_meta("gap", false)):
			continue
		total += 1
		if not bool(row.get_meta("ok", true)):
			errors += 1
		var group := String(row.get_meta("group", ""))
		counts[group] = int(counts.get(group, 0)) + 1

	_chip_all.text = "ALL %d" % total
	_chip_err.text = "ERR %d" % errors

	var sorted := _sorted_kv(counts)
	var live := {}
	for i in _group_chips.size():
		var chip := _group_chips[i]
		if i >= sorted.size():
			chip.visible = false
			chip.set_meta("filter", "")
			continue
		var pair: Array = sorted[i]
		var key := String(pair[0])
		chip.visible = true
		chip.text = "%s %d" % [key, int(pair[1])]
		chip.set_meta("filter", key)
		live[key] = true
	# The active group can drop out of the top four; fall back rather than
	# leaving every row hidden behind a filter nothing matches.
	if _filter != "all" and _filter != "err" and not live.has(_filter):
		_filter = "all"
		_chip_all.button_pressed = true


func _apply_filter() -> void:
	for row in _feed_rows.get_children():
		if bool(row.get_meta("gap", false)):
			row.visible = _filter == "all"  # a gap only reads right unfiltered
			continue
		var ok := bool(row.get_meta("ok", true))
		var group := String(row.get_meta("group", ""))
		row.visible = (
			_filter == "all"
			or (_filter == "err" and not ok)
			or group == _filter
		)


func _on_chip_pressed(chip: Button) -> void:
	var filter := String(chip.get_meta("filter", "all"))
	_filter = filter if not filter.is_empty() else "all"
	_apply_filter()
	if _stick:
		_snap_to_bottom()


# --- Scroll follow ----------------------------------------------------------


func _on_follow_toggled(pressed: bool) -> void:
	_stick = pressed
	if pressed:
		_snap_to_bottom()


func _on_scroll_value_changed(_value: float) -> void:
	var at_bottom := _scroll_at_bottom()
	if at_bottom == _stick:
		return
	_stick = at_bottom
	_follow_button.set_pressed_no_signal(_stick)  # reflect, don't re-trigger


## Rows settle their height one frame after they are added, which fires this.
## Re-snap synchronously (never await) and only while following.
func _on_scroll_range_changed() -> void:
	if _stick:
		_snap_to_bottom()


func _scroll_at_bottom() -> bool:
	var bar := _feed_scroll.get_v_scroll_bar()
	return bar.value >= bar.max_value - bar.page - SCROLL_EPSILON


func _snap_to_bottom() -> void:
	var bar := _feed_scroll.get_v_scroll_bar()
	_feed_scroll.scroll_vertical = int(bar.max_value - bar.page)


# --- Reset ------------------------------------------------------------------


func _on_reset_pressed() -> void:
	_reset_dialog.popup_centered()


func _on_reset_confirmed() -> void:
	if _router != null and is_instance_valid(_router) and _router.has_method("reset_stats"):
		_router.reset_stats()
	_clear_feed()
	_last_total = 0
	_last_uptime = 0
	_update_chips()
	_refresh()


# --- Drawing ----------------------------------------------------------------


## Bottom-aligned bars, fixed width with a fixed gap, right-anchored so the
## newest minute always sits at the right edge however wide the dock is.
func _on_cadence_draw() -> void:
	var w := _cadence.size.x
	var h := _cadence.size.y
	if w <= 0.0 or h <= 0.0:
		return
	var bar_w := float(_s(8))
	var gap := float(_s(3))
	var span := CADENCE_BUCKETS * bar_w + (CADENCE_BUCKETS - 1) * gap
	if span > w:  # a very narrow dock: shrink the bars rather than overflow
		bar_w = maxf(1.0, (w - (CADENCE_BUCKETS - 1) * gap) / float(CADENCE_BUCKETS))
		span = CADENCE_BUCKETS * bar_w + (CADENCE_BUCKETS - 1) * gap
	var x0 := w - span
	for i in CADENCE_BUCKETS:
		var frac := 0.0 if _cadence_empty else _cadence_pcts[i]
		var bar_h := maxf(float(_s(2)), h * frac)
		var col := _col_hair
		if not _cadence_empty:
			col = ACCENT if i >= CADENCE_HOT else _col_mid
		_cadence.draw_rect(Rect2(x0 + i * (bar_w + gap), h - bar_h, bar_w, bar_h), col)


func _on_group_bar_draw(bar: Control, idx: int) -> void:
	var w := bar.size.x
	var h := bar.size.y
	if w <= 0.0 or h <= 0.0:
		return
	bar.draw_rect(Rect2(0, 0, w, h), _col_hair)  # track
	var frac := clampf(_group_fracs[idx], 0.0, 1.0)
	if frac <= 0.0:
		return
	bar.draw_rect(Rect2(0, 0, w * frac, h), ACCENT if idx == 0 else _col_mid)


## Bin the recent window into one bar per minute over the last 10 minutes and
## normalize to the busiest bar, matching the web dashboard's cadence chart.
func _compute_cadence(recent: Array) -> void:
	var counts := PackedInt32Array()
	counts.resize(CADENCE_BUCKETS)
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	for e: Dictionary in recent:
		var age := maxi(0, now_ms - int(e.get("ts", 0)))
		var mins := age / 60000
		if mins > CADENCE_BUCKETS - 1:
			continue
		counts[CADENCE_BUCKETS - 1 - mins] += 1
	var peak := 0
	for v in counts:
		peak = maxi(peak, v)
	_cadence_empty = peak == 0
	for i in CADENCE_BUCKETS:
		_cadence_pcts[i] = 0.0 if peak == 0 else float(counts[i]) / float(peak)


# --- Palette ----------------------------------------------------------------


## Derive the whole palette from the editor theme, so a light editor gets a light
## panel with no second code path. Only ACCENT is constant: it is the brand.
func _resolve_theme() -> void:
	var t := EditorInterface.get_editor_theme()
	_scale = EditorInterface.get_editor_scale()
	_mono_font = t.get_font("source", "EditorFonts") if (t and t.has_font("source", "EditorFonts")) else null
	_bold_font = t.get_font("bold", "EditorFonts") if (t and t.has_font("bold", "EditorFonts")) else null

	var base := Color(0.16, 0.17, 0.19)
	if t and t.has_color("base_color", "Editor"):
		base = t.get_color("base_color", "Editor")
	_col_panel = base
	_col_field = base.darkened(0.20)
	_col_hair = base.lightened(0.10)

	_col_ink = Color(0.87, 0.88, 0.89)
	if t and t.has_color("font_color", "Label"):
		_col_ink = t.get_color("font_color", "Label")
	_col_muted = Color(_col_ink, 0.55)
	_col_mid = Color(_col_ink, 0.32)

	_col_ok = _theme_color(t, "success_color", Color(0.34, 0.73, 0.42))
	_col_err = _theme_color(t, "error_color", Color(0.88, 0.33, 0.38))
	_col_warn = _theme_color(t, "warning_color", Color(0.88, 0.65, 0.33))
	_col_err_wash = Color(_col_err, 0.10)
	_col_err_row = Color(_col_err, 0.06)

	_sb_lattice = _ensure_box(_sb_lattice, _s(1), _s(1))
	_sb_lattice.bg_color = _col_hair

	_sb_panel = _ensure_box(_sb_panel, _s(8), _s(6))
	_sb_panel.bg_color = _col_panel

	_sb_banner = _ensure_box(_sb_banner, _s(6), _s(5))
	_sb_banner.bg_color = _col_err_wash
	_sb_banner.border_width_bottom = _s(1)
	_sb_banner.border_color = _col_err

	_sb_chip = _ensure_box(_sb_chip, _s(3), _s(1))
	_sb_chip.bg_color = _col_hair

	_sb_errchip = _ensure_box(_sb_errchip, _s(3), _s(1))
	_sb_errchip.bg_color = _col_err

	_sb_row = _ensure_box(_sb_row, _s(4), _s(3))
	_sb_row.bg_color = Color(_col_panel, 0.0)  # rows sit on the dock's own ground
	_sb_row.border_width_bottom = _s(1)
	_sb_row.border_color = _col_hair

	# The 4px left rule is the error row's loudest signal in the web UI; keep it.
	_sb_errrow = _ensure_box(_sb_errrow, _s(4), _s(3))
	_sb_errrow.bg_color = _col_err_row
	_sb_errrow.border_width_left = _s(4)
	_sb_errrow.border_width_bottom = _s(1)
	_sb_errrow.border_color = _col_err

	_sb_gap = _ensure_box(_sb_gap, _s(4), _s(3))
	_sb_gap.bg_color = _col_field
	_sb_gap.border_width_top = _s(1)
	_sb_gap.border_width_bottom = _s(1)
	_sb_gap.border_color = _col_hair

	_sb_btn_idle = _ensure_box(_sb_btn_idle, _s(6), _s(3))
	_sb_btn_idle.bg_color = Color(_col_panel, 0.0)
	_sb_btn_idle.set_border_width_all(_s(1))
	_sb_btn_idle.border_color = _col_hair

	_sb_btn_on = _ensure_box(_sb_btn_on, _s(6), _s(3))
	_sb_btn_on.bg_color = _col_ink
	_sb_btn_on.set_border_width_all(_s(1))
	_sb_btn_on.border_color = _col_ink

	_sb_btn_err = _ensure_box(_sb_btn_err, _s(6), _s(3))
	_sb_btn_err.bg_color = _col_err_wash
	_sb_btn_err.set_border_width_all(_s(1))
	_sb_btn_err.border_color = _col_err


## A flat, ZERO-RADIUS box with the given horizontal/vertical content margins.
## Corner radius is never set anywhere in this file, by design.
func _ensure_box(box: StyleBoxFlat, margin_h: int, margin_v: int) -> StyleBoxFlat:
	var sb := box
	if sb == null:
		sb = StyleBoxFlat.new()
	sb.content_margin_left = margin_h
	sb.content_margin_right = margin_h
	sb.content_margin_top = margin_v
	sb.content_margin_bottom = margin_v
	return sb


func _theme_color(t: Theme, key: String, fallback: Color) -> Color:
	if t and t.has_color(key, "Editor"):
		return t.get_color(key, "Editor")
	return fallback


## Editor icon sets vary across builds: take the icon and drop the text when it
## exists (a dock has no width to spare), and keep the text when it does not.
func _apply_icon(button: Button, icon_name: String) -> void:
	button.set_meta("gm_icon", icon_name)
	var t := EditorInterface.get_editor_theme()
	if t and t.has_icon(icon_name, "EditorIcons"):
		button.icon = t.get_icon(icon_name, "EditorIcons")
		button.text = ""


## Tag a control with a semantic colour so a theme swap can re-apply it without
## rebuilding anything.
func _tint(ctrl: Control, kind: String) -> void:
	ctrl.set_meta("gm_tint", kind)
	ctrl.add_theme_color_override("font_color", _kind_color(kind))


## Same, for the ColorRect fills (rules, squares, dots).
func _fill(rect: ColorRect, kind: String) -> void:
	rect.set_meta("gm_fill", kind)
	rect.color = _kind_color(kind)


func _kind_color(kind: String) -> Color:
	match kind:
		"ink":
			return _col_ink
		"muted":
			return _col_muted
		"mid":
			return _col_mid
		"hair":
			return _col_hair
		"accent":
			return ACCENT
		"ok":
			return _col_ok
		"err":
			return _col_err
		"warn":
			return _col_warn
		"on_err":
			return Color(1, 1, 1)  # chip text sitting on the err fill
		_:
			return _col_muted


func _mono(label: Label) -> void:
	label.set_meta("gm_mono", true)
	if _mono_font != null:
		label.add_theme_font_override("font", _mono_font)


## Re-apply every tagged colour, fill, font and button style after a theme swap.
## Bounded by the tree size (~100 feed rows at worst) and never rebuilds.
func _repaint(node: Node) -> void:
	if node is Control:
		var ctrl := node as Control
		if ctrl.has_meta("gm_tint"):
			_tint(ctrl, String(ctrl.get_meta("gm_tint")))
		if ctrl.has_meta("gm_mono") and ctrl is Label:
			_mono(ctrl as Label)
		if ctrl.has_meta("gm_bold") and _bold_font != null:
			ctrl.add_theme_font_override("font", _bold_font)
		if ctrl.has_meta("gm_fill") and ctrl is ColorRect:
			_fill(ctrl as ColorRect, String(ctrl.get_meta("gm_fill")))
		if ctrl.has_meta("gm_chipbtn") and ctrl is Button:
			_style_chip_button(ctrl as Button, bool(ctrl.get_meta("gm_chipbtn")))
		if ctrl.has_meta("gm_icon") and ctrl is Button:
			_apply_icon(ctrl as Button, String(ctrl.get_meta("gm_icon")))
	for child in node.get_children():
		_repaint(child)


# --- Helpers ----------------------------------------------------------------


## The bound ports, read from the discovery file the WS server publishes. Cached:
## they only change on bind, and this runs once a second while visible.
func _read_ports() -> void:
	var now := Time.get_ticks_msec()
	if _ws_port > 0 and now - _ports_checked_ms < PORT_RECHECK_MS:
		return
	_ports_checked_ms = now
	if not FileAccess.file_exists(DISCOVERY_PATH):
		return
	var f := FileAccess.open(DISCOVERY_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		_ws_port = int((data as Dictionary).get("port", 0))
		_http_port = int((data as Dictionary).get("http_port", 0))


## key/count pairs sorted by count desc, then key asc (the dashboard's order).
func _sorted_kv(src: Dictionary) -> Array:
	var out: Array = []
	for k: String in src:
		out.append([k, int(src[k])])
	out.sort_custom(_kv_less)
	return out


func _kv_less(a: Array, b: Array) -> bool:
	if int(a[1]) != int(b[1]):
		return int(a[1]) > int(b[1])
	return String(a[0]) < String(b[0])


func _clip(s: String, n: int) -> String:
	if s.length() <= n:
		return s
	return s.substr(0, n - 1) + "…"


func _clock(ts_ms: int) -> String:
	return Time.get_time_string_from_unix_time(ts_ms / 1000 + _tz_offset_sec)


func _dur(ms: int) -> String:
	if ms < 1000:
		return "%dms" % ms
	return "%.1fs" % (float(ms) / 1000.0)


func _human_dur(ms: int) -> String:
	var secs := ms / 1000
	if secs < 60:
		return "%ds" % secs
	if secs < 3600:
		return "%dm %ds" % [secs / 60, secs % 60]
	return "%dh %dm" % [secs / 3600, (secs / 60) % 60]
