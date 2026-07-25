@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Camera authoring beyond scene3d.setup_camera (which sets fov/projection/transform). This adds
## the cinematic layer: CameraAttributesPractical (depth-of-field + exposure, a resource node.set
## can't build), making a camera current, and Camera2D limits/zoom. Grounded on the live
## CameraAttributesPractical property names.


func get_commands() -> Dictionary:
	return {
		"camera.set_attributes": _set_attributes,
		"camera.make_current": _make_current,
		"camera.set_2d": _set_2d,
	}


func _v2(params: Dictionary, key: String, default: Vector2) -> Vector2:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is String:
		return PropertyParser.parse_value(v, TYPE_VECTOR2)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return default


func _resolve(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	return [node, null]


# --- set_attributes (DOF + exposure) ----------------------------------------

func _set_attributes(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	if not node is Camera3D:
		return error_invalid_params("Node '%s' is not a Camera3D (is %s)" % [params["node_path"], node.get_class()])
	var cam := node as Camera3D

	# Reuse existing practical attributes, or make new.
	var attr: CameraAttributesPractical
	if cam.attributes is CameraAttributesPractical:
		attr = cam.attributes
	else:
		attr = CameraAttributesPractical.new()

	var applied := {}
	var map := {
		"dof_far": "dof_blur_far_enabled", "dof_far_distance": "dof_blur_far_distance", "dof_far_transition": "dof_blur_far_transition",
		"dof_near": "dof_blur_near_enabled", "dof_near_distance": "dof_blur_near_distance", "dof_near_transition": "dof_blur_near_transition",
		"dof_amount": "dof_blur_amount",
		"exposure_multiplier": "exposure_multiplier", "exposure_sensitivity": "exposure_sensitivity",
		"auto_exposure": "auto_exposure_enabled",
	}
	for param_key: String in map:
		if params.has(param_key):
			var prop: String = map[param_key]
			var cur: Variant = attr.get(prop)
			var val: Variant = optional_bool(params, param_key, false) if cur is bool else float(params[param_key])
			attr.set(prop, val)
			applied[prop] = val

	if applied.is_empty():
		return error_invalid_params("Provide at least one DOF/exposure param (dof_far, dof_far_distance, dof_amount, exposure_multiplier, …)")

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set camera attributes on %s" % cam.name)
	undo_redo.add_undo_property(cam, "attributes", cam.attributes)
	undo_redo.add_do_property(cam, "attributes", attr)
	undo_redo.add_do_reference(attr)
	undo_redo.commit_action()
	return success({"node_path": params["node_path"], "applied": applied})


# --- make_current -----------------------------------------------------------

func _make_current(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	if not (node is Camera3D or node is Camera2D):
		return error_invalid_params("Node '%s' is not a Camera3D/Camera2D" % params["node_path"])
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Make %s current" % node.name)
	undo_redo.add_undo_property(node, "current", node.get("current"))
	undo_redo.add_do_property(node, "current", true)
	undo_redo.commit_action()
	return success({"node_path": params["node_path"], "current": true, "type": node.get_class()})


# --- set_2d (Camera2D limits / zoom / smoothing) ----------------------------

func _set_2d(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	if not node is Camera2D:
		return error_invalid_params("Node '%s' is not a Camera2D" % params["node_path"])
	var cam := node as Camera2D

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Configure Camera2D %s" % cam.name)
	var applied := {}
	if params.has("zoom"):
		undo_redo.add_undo_property(cam, "zoom", cam.zoom)
		undo_redo.add_do_property(cam, "zoom", _v2(params, "zoom", Vector2.ONE))
		applied["zoom"] = str(_v2(params, "zoom", Vector2.ONE))
	for side in ["limit_left", "limit_right", "limit_top", "limit_bottom"]:
		if params.has(side):
			undo_redo.add_undo_property(cam, side, cam.get(side))
			undo_redo.add_do_property(cam, side, optional_int(params, side, 0))
			applied[side] = optional_int(params, side, 0)
	if params.has("smoothing_enabled"):
		undo_redo.add_undo_property(cam, "position_smoothing_enabled", cam.position_smoothing_enabled)
		undo_redo.add_do_property(cam, "position_smoothing_enabled", optional_bool(params, "smoothing_enabled", false))
		applied["position_smoothing_enabled"] = optional_bool(params, "smoothing_enabled", false)
	if params.has("smoothing_speed"):
		undo_redo.add_undo_property(cam, "position_smoothing_speed", cam.position_smoothing_speed)
		undo_redo.add_do_property(cam, "position_smoothing_speed", float(params["smoothing_speed"]))
		applied["position_smoothing_speed"] = float(params["smoothing_speed"])
	if applied.is_empty():
		undo_redo.commit_action()
		return error_invalid_params("Provide zoom / limit_* / smoothing_enabled / smoothing_speed")
	undo_redo.commit_action()
	return success({"node_path": params["node_path"], "applied": applied})


func get_command_docs() -> Dictionary:
	return {
		"camera.set_attributes": {
			"description": "Attach/update a CameraAttributesPractical on a Camera3D for depth-of-field + exposure. Pass at least one DOF/exposure param. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Camera3D."),
				doc_param("dof_far", "bool", false, "Enable far-field blur (dof_blur_far_enabled)."),
				doc_param("dof_far_distance", "float", false, "Distance where far blur begins."),
				doc_param("dof_far_transition", "float", false, "Far blur transition width."),
				doc_param("dof_near", "bool", false, "Enable near-field blur (dof_blur_near_enabled)."),
				doc_param("dof_near_distance", "float", false, "Distance where near blur ends."),
				doc_param("dof_near_transition", "float", false, "Near blur transition width."),
				doc_param("dof_amount", "float", false, "Blur amount (dof_blur_amount)."),
				doc_param("exposure_multiplier", "float", false, "Exposure multiplier."),
				doc_param("exposure_sensitivity", "float", false, "Exposure sensitivity (ISO)."),
				doc_param("auto_exposure", "bool", false, "Enable auto-exposure."),
			],
		},
		"camera.make_current": {
			"description": "Make a Camera3D or Camera2D the current/active camera (sets its 'current' property). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Camera3D or Camera2D."),
			],
		},
		"camera.set_2d": {
			"description": "Configure a Camera2D's zoom, scroll limits, and position smoothing. Pass at least one of the params below. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Camera2D."),
				doc_param("zoom", "Vector2", false, "Camera zoom, e.g. 'Vector2(2,2)'."),
				doc_param("limit_left", "int", false, "Left scroll limit (px)."),
				doc_param("limit_right", "int", false, "Right scroll limit (px)."),
				doc_param("limit_top", "int", false, "Top scroll limit (px)."),
				doc_param("limit_bottom", "int", false, "Bottom scroll limit (px)."),
				doc_param("smoothing_enabled", "bool", false, "Enable position smoothing (position_smoothing_enabled)."),
				doc_param("smoothing_speed", "float", false, "Position smoothing speed."),
			],
		},
	}
