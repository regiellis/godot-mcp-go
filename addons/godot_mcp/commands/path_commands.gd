@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Path3D / Curve3D authoring — splines for patrol routes, rails, camera dollies, and as a
## sampler domain for pcg. Editing a Curve3D's points/handles through node.set is impractical
## (no property surface for per-point in/out tangents), so this group does it directly, plus
## even-by-length sampling (the placement primitive) and PathFollow3D setup. 3D-only, like spatial.


func get_commands() -> Dictionary:
	return {
		"path.create": _create,
		"path.add_point": _add_point,
		"path.get_points": _get_points,
		"path.sample": _sample,
		"path.add_follow": _add_follow,
	}


func _to_v3(v: Variant) -> Vector3:
	if v is String:
		return PropertyParser.parse_value(v, TYPE_VECTOR3)
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Dictionary:
		return Vector3(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("z", 0)))
	return Vector3.ZERO


func _v3param(params: Dictionary, key: String, default: Vector3) -> Vector3:
	if params.has(key):
		return _to_v3(params[key])
	return default


func _points_array(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return []
	var v: Variant = params[key]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Array:
			return parsed
	if v is Array:
		return v
	return []


func _resolve_path3d(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	if not node is Path3D:
		return [null, error_invalid_params("Node '%s' is not a Path3D (is %s)" % [rn[0], node.get_class()])]
	var p := node as Path3D
	if p.curve == null:
		p.curve = Curve3D.new()
	return [p, null]


# --- create -----------------------------------------------------------------

func _create(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("path needs a 3D scene")
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var path := Path3D.new()
	path.name = optional_string(params, "name", "Path3D")
	var curve := Curve3D.new()
	var pts := _points_array(params, "points")
	for p in pts:
		curve.add_point(_to_v3(p))
	path.curve = curve
	path.position = _v3param(params, "position", Vector3.ZERO)

	add_child_with_undo(parent, path, root, "MCP: Add Path3D")
	return success({
		"node_path": str(root.get_path_to(path)),
		"name": String(path.name),
		"point_count": curve.get_point_count(),
		"length": curve.get_baked_length(),
	})


# --- add_point --------------------------------------------------------------

func _add_point(params: Dictionary) -> Dictionary:
	var ctx := _resolve_path3d(params)
	if ctx[1] != null:
		return ctx[1]
	var path: Path3D = ctx[0]
	var curve := path.curve

	if not params.has("position"):
		return error_invalid_params("position (Vector3) is required")
	var pos := _v3param(params, "position", Vector3.ZERO)
	var pin := _v3param(params, "in", Vector3.ZERO)    # in handle (relative)
	var pout := _v3param(params, "out", Vector3.ZERO)  # out handle (relative)
	var index := optional_int(params, "index", -1)

	var before := curve.get_point_count()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add curve point to %s" % path.name)
	undo_redo.add_do_method(curve, "add_point", pos, pin, pout, index)
	# Undo: remove the point that was added (at index, or the appended last one).
	undo_redo.add_undo_method(curve, "remove_point", index if index >= 0 else before)
	undo_redo.commit_action()
	return success({"node_path": params["node_path"], "point_count": curve.get_point_count(), "length": curve.get_baked_length()})


# --- get_points -------------------------------------------------------------

func _get_points(params: Dictionary) -> Dictionary:
	var ctx := _resolve_path3d(params)
	if ctx[1] != null:
		return ctx[1]
	var path: Path3D = ctx[0]
	var curve := path.curve
	var pts: Array = []
	for i in curve.get_point_count():
		pts.append({
			"index": i,
			"position": str(curve.get_point_position(i)),
			"in": str(curve.get_point_in(i)),
			"out": str(curve.get_point_out(i)),
		})
	return success({"node_path": params["node_path"], "point_count": pts.size(), "length": curve.get_baked_length(), "points": pts})


# --- sample -----------------------------------------------------------------

## Even-by-length samples along the baked curve — the placement primitive (feeds pcg / manual
## set-dressing along a road or rail). Returns world-or-local positions, optionally full
## transforms (with path-aligned rotation) for orienting instances.
func _sample(params: Dictionary) -> Dictionary:
	var ctx := _resolve_path3d(params)
	if ctx[1] != null:
		return ctx[1]
	var path: Path3D = ctx[0]
	var curve := path.curve
	if curve.get_point_count() < 2:
		return error(-32000, "Curve needs at least 2 points to sample")

	var length := curve.get_baked_length()
	var cubic := optional_bool(params, "cubic", true)
	var with_transform := optional_bool(params, "with_transform", false)
	var global := optional_bool(params, "global", false)
	var path_gt := path.global_transform

	# Count, or spacing (distance between samples).
	var count := optional_int(params, "count", 0)
	if count <= 0 and params.has("spacing"):
		var spacing := float(params["spacing"])
		count = maxi(2, int(length / maxf(spacing, 0.0001)) + 1)
	if count < 2:
		count = 10

	var out: Array = []
	for i in count:
		var offset := length * float(i) / float(count - 1)
		var entry := {}
		if with_transform:
			var t := curve.sample_baked_with_rotation(offset, cubic, true)
			if global:
				t = path_gt * t
			entry["transform_origin"] = str(t.origin)
			entry["basis_y"] = str(t.basis.y)  # path-up
			entry["basis_z"] = str(t.basis.z)  # path-forward
		else:
			var p := curve.sample_baked(offset, cubic)
			if global:
				p = path_gt * p
			entry["position"] = str(p)
		entry["offset"] = offset
		out.append(entry)
	return success({"node_path": params["node_path"], "length": length, "count": out.size(), "global": global, "samples": out})


# --- add_follow -------------------------------------------------------------

const _ROTATION_MODES := {"none": 0, "y": 1, "xy": 2, "xyz": 3, "oriented": 4}


func _add_follow(params: Dictionary) -> Dictionary:
	var ctx := _resolve_path3d(params)
	if ctx[1] != null:
		return ctx[1]
	var path: Path3D = ctx[0]
	var root := get_edited_root()

	var follow := PathFollow3D.new()
	follow.name = optional_string(params, "name", "PathFollow3D")
	if params.has("progress_ratio"):
		follow.progress_ratio = clampf(float(params["progress_ratio"]), 0.0, 1.0)
	elif params.has("progress"):
		follow.progress = float(params["progress"])
	follow.loop = optional_bool(params, "loop", true)
	if params.has("rotation_mode"):
		var rm := str(params["rotation_mode"]).to_lower()
		if not _ROTATION_MODES.has(rm):
			follow.free()
			return error_invalid_params("rotation_mode must be one of %s" % [_ROTATION_MODES.keys()])
		follow.rotation_mode = _ROTATION_MODES[rm]

	add_child_with_undo(path, follow, root, "MCP: Add PathFollow3D")

	# Optionally reparent an existing node under the follow so it rides the path.
	var moved := ""
	if params.has("move"):
		var target := find_node_by_path(str(params["move"]))
		if target != null and target != root and target is Node:
			var old_parent := target.get_parent()
			var undo_redo := get_undo_redo()
			undo_redo.create_action("MCP: Attach %s to path" % target.name)
			undo_redo.add_do_method(old_parent, "remove_child", target)
			undo_redo.add_do_method(follow, "add_child", target)
			undo_redo.add_do_method(target, "set_owner", root)
			undo_redo.add_undo_method(follow, "remove_child", target)
			undo_redo.add_undo_method(old_parent, "add_child", target)
			undo_redo.add_undo_method(target, "set_owner", root)
			undo_redo.commit_action()
			moved = str(params["move"])

	return success({
		"node_path": str(root.get_path_to(follow)),
		"name": String(follow.name),
		"moved": moved,
	})


func get_command_docs() -> Dictionary:
	return {
		"path.create": {
			"description": "Create a Path3D (with a Curve3D) under --parent-path, optionally seeded with --points. 3D scene only. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add the path under (default '.'). --parent is an alias."),
				doc_param("name", "String", false, "Node name (default 'Path3D')."),
				doc_param("points", "Array", false, "Initial curve points: JSON array of Vector3 (string/array/{x,y,z}) positions."),
				doc_param("position", "Vector3", false, "Local position of the Path3D node (default origin)."),
			],
		},
		"path.add_point": {
			"description": "Append or insert a point into a Path3D's Curve3D, with optional relative in/out bezier handles. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Path3D (a Curve3D is created if absent)."),
				doc_param("position", "Vector3", true, "Point position (curve-local)."),
				doc_param("in", "Vector3", false, "In-handle offset, relative to the point (default zero)."),
				doc_param("out", "Vector3", false, "Out-handle offset, relative to the point (default zero)."),
				doc_param("index", "int", false, "Insert index; -1 (default) appends."),
			],
		},
		"path.get_points": {
			"description": "List a Path3D's curve points with positions and in/out handles, plus the baked length.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Path3D."),
			],
		},
		"path.sample": {
			"description": "Even-by-length samples along a Path3D's baked curve (the placement primitive for seating instances along a road/rail). Needs >=2 points.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Path3D."),
				doc_param("count", "int", false, "Number of samples. Use this OR --spacing; defaults to 10 if neither is set."),
				doc_param("spacing", "float", false, "Distance between samples (derives count from the curve length). Ignored if --count > 0."),
				doc_param("cubic", "bool", false, "Cubic interpolation of the baked curve (default true)."),
				doc_param("with_transform", "bool", false, "Return full path-aligned transforms (origin + basis) instead of positions (default false)."),
				doc_param("global", "bool", false, "Return positions/transforms in global space instead of path-local (default false)."),
			],
		},
		"path.add_follow": {
			"description": "Add a PathFollow3D child to a Path3D and optionally reparent an existing node under it so it rides the path. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Path3D."),
				doc_param("name", "String", false, "PathFollow3D node name (default 'PathFollow3D')."),
				doc_param("progress_ratio", "float", false, "Start position as 0..1 along the path. Use this OR --progress."),
				doc_param("progress", "float", false, "Start position as an absolute distance along the path. Use this OR --progress-ratio."),
				doc_param("loop", "bool", false, "Wrap progress at the ends (default true)."),
				doc_param("rotation_mode", "String", false, "'none', 'y', 'xy', 'xyz', or 'oriented'."),
				doc_param("move", "NodePath", false, "Existing node to reparent under the PathFollow3D so it follows the path."),
			],
		},
	}
