@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"theme.create": _create,
		"theme.set_color": _set_color,
		"theme.set_constant": _set_constant,
		"theme.set_font_size": _set_font_size,
		"theme.set_stylebox": _set_stylebox,
		"theme.setup_control": _setup_control,
		"theme.get_info": _get_info,
	}


const _ANCHOR_PRESETS := {
	"top_left": Control.PRESET_TOP_LEFT,
	"top_right": Control.PRESET_TOP_RIGHT,
	"bottom_left": Control.PRESET_BOTTOM_LEFT,
	"bottom_right": Control.PRESET_BOTTOM_RIGHT,
	"center_left": Control.PRESET_CENTER_LEFT,
	"center_top": Control.PRESET_CENTER_TOP,
	"center_right": Control.PRESET_CENTER_RIGHT,
	"center_bottom": Control.PRESET_CENTER_BOTTOM,
	"center": Control.PRESET_CENTER,
	"left_wide": Control.PRESET_LEFT_WIDE,
	"top_wide": Control.PRESET_TOP_WIDE,
	"right_wide": Control.PRESET_RIGHT_WIDE,
	"bottom_wide": Control.PRESET_BOTTOM_WIDE,
	"vcenter_wide": Control.PRESET_VCENTER_WIDE,
	"hcenter_wide": Control.PRESET_HCENTER_WIDE,
	"full_rect": Control.PRESET_FULL_RECT,
}

const _SIZE_FLAGS := {
	"fill": Control.SIZE_FILL,
	"expand": Control.SIZE_EXPAND,
	"fill_expand": Control.SIZE_EXPAND_FILL,
	"shrink_center": Control.SIZE_SHRINK_CENTER,
	"shrink_end": Control.SIZE_SHRINK_END,
}

const _GROW_DIRECTIONS := {
	"begin": Control.GROW_DIRECTION_BEGIN,
	"end": Control.GROW_DIRECTION_END,
	"both": Control.GROW_DIRECTION_BOTH,
}


func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]

	var path_guard := guard_project_path(path)
	if not path_guard.is_empty():
		return path_guard

	var theme := Theme.new()
	var font_size := optional_int(params, "default_font_size", 0)
	if font_size > 0:
		theme.default_font_size = font_size

	var scene_guard := guard_offline_scene_save(path)
	if not scene_guard.is_empty():
		return scene_guard

	var err := ResourceSaver.save(theme, path)
	if err != OK:
		return error_internal("Failed to save theme: %s" % error_string(err))

	EditorInterface.get_resource_filesystem().scan()
	return success({"path": path, "created": true})


func _set_color(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var rc := require_string(params, "color")
	if rc[1] != null:
		return rc[1]

	var control: Control = ctx[0]
	var color_name: String = rn[0]
	var color_str: String = rc[0]
	var color := Color(color_str)

	var had_old := control.has_theme_color_override(color_name)
	var old_value: Variant = control.get("theme_override_colors/" + color_name) if had_old else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set theme color override")
	undo_redo.add_do_method(control, "add_theme_color_override", color_name, color)
	undo_redo.add_undo_method(self, "_restore_theme_override", control, "color", color_name, had_old, old_value)
	undo_redo.commit_action()

	return success({"node_path": str(get_edited_root().get_path_to(control)), "name": color_name, "color": color_str})


func _set_constant(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]

	var control: Control = ctx[0]
	var const_name: String = rn[0]
	var value := int(params.get("value", 0))

	var had_old := control.has_theme_constant_override(const_name)
	var old_value: Variant = control.get("theme_override_constants/" + const_name) if had_old else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set theme constant override")
	undo_redo.add_do_method(control, "add_theme_constant_override", const_name, value)
	undo_redo.add_undo_method(self, "_restore_theme_override", control, "constant", const_name, had_old, old_value)
	undo_redo.commit_action()

	return success({"node_path": str(get_edited_root().get_path_to(control)), "name": const_name, "value": value})


func _set_font_size(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]

	var control: Control = ctx[0]
	var font_name: String = rn[0]
	var size := int(params.get("size", 16))

	var had_old := control.has_theme_font_size_override(font_name)
	var old_value: Variant = control.get("theme_override_font_sizes/" + font_name) if had_old else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set theme font size override")
	undo_redo.add_do_method(control, "add_theme_font_size_override", font_name, size)
	undo_redo.add_undo_method(self, "_restore_theme_override", control, "font_size", font_name, had_old, old_value)
	undo_redo.commit_action()

	return success({"node_path": str(get_edited_root().get_path_to(control)), "name": font_name, "size": size})


func _set_stylebox(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]

	var control: Control = ctx[0]
	var style_name: String = rn[0]
	var stylebox := StyleBoxFlat.new()

	var bg_color := optional_string(params, "bg_color", "")
	if not bg_color.is_empty():
		stylebox.bg_color = Color(bg_color)

	var border_color := optional_string(params, "border_color", "")
	if not border_color.is_empty():
		stylebox.border_color = Color(border_color)

	var border_width := optional_int(params, "border_width", 0)
	if border_width > 0:
		stylebox.border_width_left = border_width
		stylebox.border_width_top = border_width
		stylebox.border_width_right = border_width
		stylebox.border_width_bottom = border_width

	var corner_radius := optional_int(params, "corner_radius", 0)
	if corner_radius > 0:
		stylebox.corner_radius_top_left = corner_radius
		stylebox.corner_radius_top_right = corner_radius
		stylebox.corner_radius_bottom_left = corner_radius
		stylebox.corner_radius_bottom_right = corner_radius

	var padding := optional_int(params, "padding", 0)
	if padding > 0:
		stylebox.content_margin_left = padding
		stylebox.content_margin_top = padding
		stylebox.content_margin_right = padding
		stylebox.content_margin_bottom = padding

	var had_old := control.has_theme_stylebox_override(style_name)
	var old_value: Variant = control.get("theme_override_styles/" + style_name) if had_old else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set theme stylebox override")
	undo_redo.add_do_method(control, "add_theme_stylebox_override", style_name, stylebox)
	undo_redo.add_do_reference(stylebox)
	undo_redo.add_undo_method(self, "_restore_theme_override", control, "stylebox", style_name, had_old, old_value)
	if old_value is Resource:
		undo_redo.add_undo_reference(old_value)
	undo_redo.commit_action()

	return success({"node_path": str(get_edited_root().get_path_to(control)), "name": style_name, "type": "StyleBoxFlat"})


func _setup_control(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var control: Control = ctx[0]

	var applied: Array = []
	var old_state := _capture_control_setup_state(control)
	var target := control.duplicate() as Control

	var anchor_preset := optional_string(params, "anchor_preset", "")
	if not anchor_preset.is_empty() and _ANCHOR_PRESETS.has(anchor_preset):
		target.set_anchors_and_offsets_preset(_ANCHOR_PRESETS[anchor_preset])
		applied.append("anchor_preset=%s" % anchor_preset)

	var min_size_str := optional_string(params, "min_size", "")
	if not min_size_str.is_empty():
		var expr := Expression.new()
		if expr.parse(min_size_str) == OK:
			var val: Variant = expr.execute()
			if val is Vector2:
				target.custom_minimum_size = val
				applied.append("min_size=%s" % min_size_str)

	var sf_h := optional_string(params, "size_flags_h", "")
	if not sf_h.is_empty() and _SIZE_FLAGS.has(sf_h):
		target.size_flags_horizontal = _SIZE_FLAGS[sf_h]
		applied.append("size_flags_h=%s" % sf_h)

	var sf_v := optional_string(params, "size_flags_v", "")
	if not sf_v.is_empty() and _SIZE_FLAGS.has(sf_v):
		target.size_flags_vertical = _SIZE_FLAGS[sf_v]
		applied.append("size_flags_v=%s" % sf_v)

	if params.has("margins"):
		var m_r := require_dict(params, "margins")
		if m_r[1] != null:
			return m_r[1]
		var margins: Dictionary = m_r[0]
		if target is MarginContainer:
			if margins.has("left"):
				target.add_theme_constant_override("margin_left", int(margins["left"]))
			if margins.has("top"):
				target.add_theme_constant_override("margin_top", int(margins["top"]))
			if margins.has("right"):
				target.add_theme_constant_override("margin_right", int(margins["right"]))
			if margins.has("bottom"):
				target.add_theme_constant_override("margin_bottom", int(margins["bottom"]))
			applied.append("margins=%s" % str(margins))

	if params.has("separation") and target is BoxContainer:
		var sep := int(params["separation"])
		target.add_theme_constant_override("separation", sep)
		applied.append("separation=%d" % sep)

	var grow_h := optional_string(params, "grow_h", "")
	if not grow_h.is_empty() and _GROW_DIRECTIONS.has(grow_h):
		target.grow_horizontal = _GROW_DIRECTIONS[grow_h]
		applied.append("grow_h=%s" % grow_h)

	var grow_v := optional_string(params, "grow_v", "")
	if not grow_v.is_empty() and _GROW_DIRECTIONS.has(grow_v):
		target.grow_vertical = _GROW_DIRECTIONS[grow_v]
		applied.append("grow_v=%s" % grow_v)

	if not applied.is_empty():
		var new_state := _capture_control_setup_state(target)
		_register_control_setup_undo(control, old_state, new_state)
	target.free()
	return success({"node_path": str(get_edited_root().get_path_to(control)), "applied": applied, "count": applied.size()})


func _get_info(params: Dictionary) -> Dictionary:
	var ctx := _resolve_control(params)
	if ctx[1] != null:
		return ctx[1]
	var control: Control = ctx[0]

	var info := {"node_path": str(get_edited_root().get_path_to(control)), "class": control.get_class()}

	var theme := control.theme
	if theme:
		info["theme_path"] = theme.resource_path
		info["type_list"] = Array(theme.get_type_list())

	var overrides := {"colors": {}, "constants": {}, "font_sizes": {}, "styleboxes": {}}
	for prop in control.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("theme_override_colors/"):
			overrides["colors"][pname.substr(22)] = "#" + (control.get(pname) as Color).to_html()
		elif pname.begins_with("theme_override_constants/"):
			overrides["constants"][pname.substr(25)] = control.get(pname)
		elif pname.begins_with("theme_override_font_sizes/"):
			overrides["font_sizes"][pname.substr(26)] = control.get(pname)
		elif pname.begins_with("theme_override_styles/"):
			var style: Variant = control.get(pname)
			overrides["styleboxes"][pname.substr(22)] = style.get_class() if style else null

	info["overrides"] = overrides
	return success(info)


# --- Shared resolution + undo helpers ---------------------------------------

## Resolve params.node_path to a Control. Returns [control, null] or [null, error].
func _resolve_control(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null or not (node is Control):
		return [null, error_not_found("Control node at '%s'" % r[0])]
	return [node as Control, null]


func _restore_theme_override(control: Control, kind: String, override_name: String, had_old: bool, old_value: Variant) -> void:
	match kind:
		"color":
			if had_old:
				control.add_theme_color_override(override_name, old_value)
			else:
				control.remove_theme_color_override(override_name)
		"constant":
			if had_old:
				control.add_theme_constant_override(override_name, old_value)
			else:
				control.remove_theme_constant_override(override_name)
		"font_size":
			if had_old:
				control.add_theme_font_size_override(override_name, old_value)
			else:
				control.remove_theme_font_size_override(override_name)
		"stylebox":
			if had_old:
				control.add_theme_stylebox_override(override_name, old_value)
			else:
				control.remove_theme_stylebox_override(override_name)


func _capture_control_setup_state(control: Control) -> Dictionary:
	var state := {"properties": {}, "theme_constants": {}}
	for property: String in [
		"anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
		"offset_left", "offset_top", "offset_right", "offset_bottom",
		"custom_minimum_size", "size_flags_horizontal", "size_flags_vertical",
		"grow_horizontal", "grow_vertical",
	]:
		state["properties"][property] = control.get(property)
	for constant_name: String in ["margin_left", "margin_top", "margin_right", "margin_bottom", "separation"]:
		var had_override := control.has_theme_constant_override(constant_name)
		state["theme_constants"][constant_name] = {
			"had": had_override,
			"value": control.get("theme_override_constants/" + constant_name) if had_override else null,
		}
	return state


func _register_control_setup_undo(control: Control, old_state: Dictionary, new_state: Dictionary) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Setup Control")
	for property: String in new_state["properties"]:
		undo_redo.add_do_property(control, property, new_state["properties"][property])
		undo_redo.add_undo_property(control, property, old_state["properties"][property])
	for constant_name: String in new_state["theme_constants"]:
		var new_constant: Dictionary = new_state["theme_constants"][constant_name]
		var old_constant: Dictionary = old_state["theme_constants"][constant_name]
		undo_redo.add_do_method(self, "_restore_theme_override", control, "constant", constant_name, new_constant["had"], new_constant["value"])
		undo_redo.add_undo_method(self, "_restore_theme_override", control, "constant", constant_name, old_constant["had"], old_constant["value"])
	undo_redo.commit_action()


func get_command_docs() -> Dictionary:
	return {
		"theme.create": {
			"description": "Create and save an empty Theme .tres resource.",
			"params": [
				doc_param("path", "String", true, "Save path for the theme (inside the project)."),
				doc_param("default_font_size", "int", false, "Theme default font size (0 = leave unset)."),
			],
		},
		"theme.set_color": {
			"description": "Add a theme color override on a Control node (not a .tres edit). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("name", "String", true, "Theme color item name (e.g. 'font_color')."),
				doc_param("color", "Color", true, "Color value (name, #hex, or Color(...))."),
			],
		},
		"theme.set_constant": {
			"description": "Add a theme constant override on a Control node. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("name", "String", true, "Theme constant item name (e.g. 'outline_size')."),
				doc_param("value", "int", false, "Constant value (default 0)."),
			],
		},
		"theme.set_font_size": {
			"description": "Add a theme font-size override on a Control node. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("name", "String", true, "Theme font-size item name (e.g. 'font_size')."),
				doc_param("size", "int", false, "Font size in pixels (default 16)."),
			],
		},
		"theme.set_stylebox": {
			"description": "Add a StyleBoxFlat theme override on a Control node, built from the given fill/border/corner/padding params. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("name", "String", true, "Theme stylebox item name (e.g. 'panel', 'normal')."),
				doc_param("bg_color", "Color", false, "Fill color."),
				doc_param("border_color", "Color", false, "Border color."),
				doc_param("border_width", "int", false, "Uniform border width in px (0 = none)."),
				doc_param("corner_radius", "int", false, "Uniform corner radius in px (0 = square)."),
				doc_param("padding", "int", false, "Uniform content margin in px (0 = none)."),
			],
		},
		"theme.setup_control": {
			"description": "Apply layout/sizing to a Control in one call (anchors, min size, size flags, grow, and container margins/separation). Only the params you pass are applied. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("anchor_preset", "String", false, "Anchor+offset preset (top_left, center, full_rect, ...)."),
				doc_param("min_size", "Vector2", false, "custom_minimum_size as a 'Vector2(x, y)' expression."),
				doc_param("size_flags_h", "String", false, "Horizontal size flags: fill, expand, fill_expand, shrink_center, shrink_end."),
				doc_param("size_flags_v", "String", false, "Vertical size flags (same options as --size-flags-h)."),
				doc_param("margins", "Dictionary", false, "MarginContainer margins {left, top, right, bottom} (as theme constant overrides)."),
				doc_param("separation", "int", false, "BoxContainer separation constant."),
				doc_param("grow_h", "String", false, "Horizontal grow direction: begin, end, both."),
				doc_param("grow_v", "String", false, "Vertical grow direction: begin, end, both."),
			],
		},
		"theme.get_info": {
			"description": "Report a Control's assigned theme (path, type list) and all its per-item theme overrides (colors, constants, font sizes, styleboxes).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
			],
		},
	}
