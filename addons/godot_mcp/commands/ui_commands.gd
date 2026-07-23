@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## UI layout — the gap node.set_anchor (anchors) and theme (styling) leave open: responsive
## CONTAINERS that auto-arrange children, and the size_flags that govern how a child fills/expands
## inside one. size_flags are bitmask enums that node.set handles clumsily, so this names them.
## (For anchors use node.set_anchor; for colors/fonts/styleboxes use the theme group.)

const _SIZE_FLAGS := {
	"shrink_begin": 0,    # SIZE_SHRINK_BEGIN
	"fill": 1,            # SIZE_FILL
	"expand": 2,          # SIZE_EXPAND
	"expand_fill": 3,     # SIZE_EXPAND | SIZE_FILL
	"shrink_center": 4,   # SIZE_SHRINK_CENTER
	"shrink_end": 8,      # SIZE_SHRINK_END
}


func get_commands() -> Dictionary:
	return {
		"ui.add_container": _add_container,
		"ui.add_control": _add_control,
		"ui.set_sizing": _set_sizing,
	}


func _resolve_parent(params: Dictionary) -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return [null, error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))]
	return [parent, null]


func _v2(params: Dictionary, key: String, default: Vector2) -> Vector2:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is String:
		return PropertyParser.parse_value(v, TYPE_VECTOR2)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return default


# --- add_container ----------------------------------------------------------

func _add_container(params: Dictionary) -> Dictionary:
	var ctx := _resolve_parent(params)
	if ctx[1] != null:
		return ctx[1]
	var parent: Node = ctx[0]
	var root := get_edited_root()

	var type := optional_string(params, "type", "VBoxContainer")
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Container"):
		return error_invalid_params("type must be a Container (VBoxContainer/HBoxContainer/GridContainer/MarginContainer/PanelContainer/CenterContainer/ScrollContainer/TabContainer/FlowContainer)")

	var c: Container = ClassDB.instantiate(type)
	c.name = optional_string(params, "name", type)

	if type == "GridContainer" and params.has("columns"):
		c.columns = optional_int(params, "columns", 1)
	if params.has("separation"):
		var sep := optional_int(params, "separation", 4)
		# Box/Flow use "separation"; Grid uses h/v separation — set all, harmless extras.
		c.add_theme_constant_override("separation", sep)
		c.add_theme_constant_override("h_separation", sep)
		c.add_theme_constant_override("v_separation", sep)
	if type == "MarginContainer" and params.has("margin"):
		var m := optional_int(params, "margin", 8)
		for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
			c.add_theme_constant_override(side, m)

	add_child_with_undo(parent, c, root, "MCP: Add %s" % type)
	return success({"node_path": str(root.get_path_to(c)), "name": String(c.name), "type": type})


# --- add_control ------------------------------------------------------------

func _add_control(params: Dictionary) -> Dictionary:
	var ctx := _resolve_parent(params)
	if ctx[1] != null:
		return ctx[1]
	var parent: Node = ctx[0]
	var root := get_edited_root()

	var rt := require_string(params, "type")
	if rt[1] != null:
		return rt[1]
	var type: String = rt[0]
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Control") or not ClassDB.can_instantiate(type):
		return error_invalid_params("type must be an instantiable Control (Label/Button/LineEdit/TextureRect/Panel/…)")

	var ctrl: Control = ClassDB.instantiate(type)
	ctrl.name = optional_string(params, "name", type)
	if params.has("text") and "text" in ctrl:
		ctrl.set("text", str(params["text"]))
	if params.has("custom_min_size"):
		ctrl.custom_minimum_size = _v2(params, "custom_min_size", Vector2.ZERO)

	add_child_with_undo(parent, ctrl, root, "MCP: Add %s" % type)
	return success({"node_path": str(root.get_path_to(ctrl)), "name": String(ctrl.name), "type": type})


# --- set_sizing -------------------------------------------------------------

## Set how a Control behaves inside its container: size_flags (named) + stretch ratio + min size.
func _set_sizing(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not node is Control:
		return error_invalid_params("Node '%s' is not a Control (is %s)" % [rn[0], node.get_class()])
	var ctrl := node as Control

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set sizing on %s" % ctrl.name)
	var applied := {}

	for axis in [["h", "size_flags_horizontal"], ["v", "size_flags_vertical"]]:
		if params.has(axis[0]):
			var name := str(params[axis[0]]).to_lower()
			if not _SIZE_FLAGS.has(name):
				return error_invalid_params("%s must be one of %s" % [axis[0], _SIZE_FLAGS.keys()])
			undo_redo.add_undo_property(ctrl, axis[1], ctrl.get(axis[1]))
			undo_redo.add_do_property(ctrl, axis[1], _SIZE_FLAGS[name])
			applied[axis[1]] = name

	if params.has("stretch_ratio"):
		undo_redo.add_undo_property(ctrl, "size_flags_stretch_ratio", ctrl.size_flags_stretch_ratio)
		undo_redo.add_do_property(ctrl, "size_flags_stretch_ratio", float(params["stretch_ratio"]))
		applied["stretch_ratio"] = float(params["stretch_ratio"])
	if params.has("custom_min_size"):
		undo_redo.add_undo_property(ctrl, "custom_minimum_size", ctrl.custom_minimum_size)
		undo_redo.add_do_property(ctrl, "custom_minimum_size", _v2(params, "custom_min_size", Vector2.ZERO))
		applied["custom_min_size"] = str(_v2(params, "custom_min_size", Vector2.ZERO))

	if applied.is_empty():
		return error_invalid_params("Provide at least one of h/v/stretch_ratio/custom_min_size")
	undo_redo.commit_action()
	return success({"node_path": rn[0], "applied": applied})


func get_command_docs() -> Dictionary:
	return {
		"ui.add_container": {
			"description": "Add a responsive Container that auto-arranges children (Box/Grid/Margin/Panel/...) under --parent-path. Undoable. For anchors use node.set_anchor; for styling use the theme group.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.'). --parent is an alias."),
				doc_param("type", "String", false, "A Container class (default VBoxContainer; HBoxContainer/GridContainer/MarginContainer/PanelContainer/CenterContainer/ScrollContainer/TabContainer/FlowContainer)."),
				doc_param("name", "String", false, "Node name (defaults to the type)."),
				doc_param("columns", "int", false, "GridContainer column count."),
				doc_param("separation", "int", false, "Child separation (sets separation + h/v_separation constants)."),
				doc_param("margin", "int", false, "MarginContainer uniform margin (all four sides)."),
			],
		},
		"ui.add_control": {
			"description": "Add an instantiable Control (Label/Button/LineEdit/...) under --parent-path, optionally with text and a min size. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.'). --parent is an alias."),
				doc_param("type", "String", true, "An instantiable Control class (Label, Button, LineEdit, TextureRect, Panel, ...)."),
				doc_param("name", "String", false, "Node name (defaults to the type)."),
				doc_param("text", "String", false, "Text to set (only if the control has a `text` property)."),
				doc_param("custom_min_size", "Vector2", false, "custom_minimum_size for the control."),
			],
		},
		"ui.set_sizing": {
			"description": "Set how a Control fills/expands inside its container (named size flags + stretch ratio + min size). Provide at least one of --h/--v/--stretch-ratio/--custom-min-size. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("h", "String", false, "Horizontal size flags: shrink_begin, fill, expand, expand_fill, shrink_center, shrink_end."),
				doc_param("v", "String", false, "Vertical size flags (same options as --h)."),
				doc_param("stretch_ratio", "float", false, "size_flags_stretch_ratio (relative expand weight)."),
				doc_param("custom_min_size", "Vector2", false, "custom_minimum_size for the control."),
			],
		},
	}
