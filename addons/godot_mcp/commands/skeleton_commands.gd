@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Skeleton3D — bones, poses, and bone attachments. Bone indices/poses (Quaternion rotations,
## per-component pose setters) aren't reachable through node.set, so this exposes them directly.
## Pose edits are undoable; structural ops (add_bone — Skeleton3D has no remove_bone) are direct.
## IK in 4.7 is SkeletonModifier3D-based: add those via node.add and configure with node.set.
##
## 2D (cutout) rigs: Skeleton2D bones are Bone2D *nodes*, so posing is plain node.set on
## position/rotation — the 2D commands here cover what node.set can't: building the hierarchy
## with rests (create_2d), re-baking rests from the current pose (set_rest_2d), and binding a
## Polygon2D with per-vertex weights (skin_2d). list_bones handles both skeleton types.


func get_commands() -> Dictionary:
	return {
		"skeleton.list_bones": _list_bones,
		"skeleton.add_bone": _add_bone,
		"skeleton.set_pose": _set_pose,
		"skeleton.get_pose": _get_pose,
		"skeleton.reset_pose": _reset_pose,
		"skeleton.add_attachment": _add_attachment,
		"skeleton.create_2d": _create_2d,
		"skeleton.set_rest_2d": _set_rest_2d,
		"skeleton.skin_2d": _skin_2d,
	}


func _v3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


func _resolve_skeleton(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	if not node is Skeleton3D:
		return [null, error_invalid_params("Node '%s' is not a Skeleton3D (is %s)" % [rn[0], node.get_class()])]
	return [node as Skeleton3D, null]


## Resolve a bone by name or numeric index. Returns idx or -1.
func _bone_idx(skel: Skeleton3D, bone: Variant) -> int:
	if bone is int or (bone is String and (bone as String).is_valid_int()):
		var i := int(bone)
		return i if i >= 0 and i < skel.get_bone_count() else -1
	return skel.find_bone(str(bone))


# --- 2D (cutout) rigs --------------------------------------------------------

func _resolve_skeleton_2d(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	if not node is Skeleton2D:
		return [null, error_invalid_params("Node '%s' is not a Skeleton2D (is %s)" % [rn[0], node.get_class()])]
	return [node as Skeleton2D, null]


## Build a Skeleton2D with a Bone2D hierarchy in one call. --bones is a JSON array,
## each entry {"name": ..., "position": [x,y] (local, relative to parent), "parent":
## <earlier bone name, omit for a root bone>}. Rests are baked from the given positions.
func _create_2d(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", "."))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))
	var rb := require_array(params, "bones")
	if rb[1] != null:
		return rb[1]
	var specs: Array = rb[0]
	if specs.is_empty():
		return error_invalid_params("bones must contain at least one bone")

	var skel := Skeleton2D.new()
	skel.name = optional_string(params, "name", "Skeleton2D")
	skel.position = vec2_param(params, "position", Vector2.ZERO)

	var by_name: Dictionary = {}
	for spec: Dictionary in specs:
		var bone_name := str(spec.get("name", ""))
		if bone_name.is_empty():
			skel.free()
			return error_invalid_params("every bone needs a name")
		if by_name.has(bone_name):
			skel.free()
			return error_invalid_params("duplicate bone name '%s'" % bone_name)
		var bone := Bone2D.new()
		bone.name = bone_name
		var pos: Variant = spec.get("position", [0, 0])
		bone.position = PropertyParser.parse_value(pos, TYPE_VECTOR2) if not pos is Array \
			else Vector2(float(pos[0]), float(pos[1]))
		var parent_name := str(spec.get("parent", ""))
		if parent_name.is_empty():
			skel.add_child(bone)
		elif by_name.has(parent_name):
			(by_name[parent_name] as Bone2D).add_child(bone)
		else:
			skel.free()
			return error_invalid_params("bone '%s' names parent '%s', which must appear earlier in the list" % [bone_name, parent_name])
		by_name[bone_name] = bone
		# Rest = the authored setup pose. Autocalculated length/angle points each
		# bone at its first child, matching the editor's behavior.
		bone.rest = bone.transform

	add_child_with_undo(parent, skel, root, "MCP: Create Skeleton2D")
	# Owner must be set for every descendant or the bones vanish on save.
	for bone_name in by_name:
		(by_name[bone_name] as Node).owner = root

	return success({
		"node_path": str(root.get_path_to(skel)),
		"name": String(skel.name),
		"bone_count": by_name.size(),
	})


## Re-bake every Bone2D's rest from its CURRENT transform — the "pose it, then
## make that the rest" workflow after adjusting bones via node.set.
func _set_rest_2d(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton_2d(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton2D = ctx[0]
	var count := 0
	for node: Node in find_descendants_of_type(skel, "Bone2D"):
		var bone := node as Bone2D
		bone.rest = bone.transform
		count += 1
	return success({"node_path": params["node_path"], "rests_baked": count})


## Bind a Polygon2D to a Skeleton2D with per-vertex weights. Explicit weights via
## --weights '{"boneName": [w per vertex...]}'; otherwise auto-weights by inverse
## distance from each polygon vertex to each bone segment (bone -> first child, or
## its length along its angle), normalized, keeping the strongest --max-influences.
func _skin_2d(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton_2d(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton2D = ctx[0]
	var rp := require_string(params, "polygon_path")
	if rp[1] != null:
		return rp[1]
	var poly_node := find_node_by_path(rp[0])
	if poly_node == null or not poly_node is Polygon2D:
		return error_not_found("Polygon2D at '%s'" % rp[0])
	var poly := poly_node as Polygon2D
	var verts: PackedVector2Array = poly.polygon
	if verts.is_empty():
		return error_invalid_params("Polygon2D has no vertices; set its polygon first")

	var bones: Array = []
	for node: Node in find_descendants_of_type(skel, "Bone2D"):
		bones.append(node)
	if bones.is_empty():
		return error_invalid_params("Skeleton2D has no Bone2D children")

	poly.skeleton = poly.get_path_to(skel)
	poly.clear_bones()

	var explicit: Dictionary = params.get("weights", {})
	var falloff := float(params.get("falloff", 2.0))
	var max_influences := optional_int(params, "max_influences", 2)
	var bound: Array = []

	if not explicit.is_empty():
		for bone_name: String in explicit:
			var bone: Bone2D = null
			for b: Bone2D in bones:
				if String(b.name) == bone_name:
					bone = b
					break
			if bone == null:
				return error_not_found("Bone '%s' in weights" % bone_name)
			var wr := require_array(explicit, bone_name)
			if wr[1] != null or (wr[0] as Array).size() != verts.size():
				return error_invalid_params("weights for '%s' must be an array of %d floats (one per vertex)" % [bone_name, verts.size()])
			var weights := PackedFloat32Array()
			for w in wr[0]:
				weights.append(clampf(float(w), 0.0, 1.0))
			poly.add_bone(skel.get_path_to(bone), weights)
			bound.append({"bone": bone_name, "weighted_vertices": weights.size()})
	else:
		# Auto: score each vertex against each bone segment, keep top N, normalize.
		var poly_xform := poly.global_transform
		var raw: Array = []          # per bone: PackedFloat32Array of scores
		for b: Bone2D in bones:
			var a: Vector2 = b.global_position
			var tip: Vector2 = a + Vector2.from_angle(b.get_bone_angle() + b.global_rotation) * b.get_length() * b.global_scale.x
			if b.get_child_count() > 0 and b.get_child(0) is Bone2D:
				tip = (b.get_child(0) as Bone2D).global_position
			var scores := PackedFloat32Array()
			for v in verts:
				var world: Vector2 = poly_xform * v
				var closest := Geometry2D.get_closest_point_to_segment(world, a, tip)
				scores.append(1.0 / pow(maxf(world.distance_to(closest), 1.0), falloff))
			raw.append(scores)
		for vi in verts.size():
			# Keep only the strongest max_influences bones for this vertex.
			var order: Array = range(bones.size())
			order.sort_custom(func(x, y): return raw[x][vi] > raw[y][vi])
			for rank in range(max_influences, order.size()):
				raw[order[rank]][vi] = 0.0
			var total := 0.0
			for bi in bones.size():
				total += raw[bi][vi]
			if total > 0.0:
				for bi in bones.size():
					raw[bi][vi] = raw[bi][vi] / total
		for bi in bones.size():
			poly.add_bone(skel.get_path_to(bones[bi]), raw[bi])
			var influenced := 0
			for w in raw[bi]:
				if w > 0.0:
					influenced += 1
			bound.append({"bone": String((bones[bi] as Node).name), "weighted_vertices": influenced})

	return success({
		"polygon_path": rp[0],
		"skeleton": str(poly.skeleton),
		"vertices": verts.size(),
		"mode": "explicit" if not explicit.is_empty() else "auto",
		"bones": bound,
	})


# --- list_bones -------------------------------------------------------------

func _list_bones(params: Dictionary) -> Dictionary:
	# Skeleton2D: bones are Bone2D nodes, so report the node tree view.
	if get_edited_root() != null:
		var probe := find_node_by_path(optional_string(params, "node_path", ""))
		if probe is Skeleton2D:
			var bones_2d: Array = []
			for node: Node in find_descendants_of_type(probe, "Bone2D"):
				var b := node as Bone2D
				bones_2d.append({
					"index": b.get_index_in_skeleton(),
					"name": String(b.name),
					"path": str((probe as Node).get_path_to(b)),
					"parent": String(b.get_parent().name) if b.get_parent() is Bone2D else "",
					"position": PropertyParser.serialize_value(b.position),
					"rotation_degrees": b.rotation_degrees,
					"length": b.get_length(),
				})
			return success({"node_path": params.get("node_path"), "type": "Skeleton2D", "bone_count": bones_2d.size(), "bones": bones_2d})

	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	var bones: Array = []
	for i in skel.get_bone_count():
		var parent := skel.get_bone_parent(i)
		bones.append({
			"index": i,
			"name": skel.get_bone_name(i),
			"parent": parent,
			"parent_name": skel.get_bone_name(parent) if parent >= 0 else "",
		})
	return success({"node_path": params["node_path"], "bone_count": bones.size(), "bones": bones})


# --- add_bone ---------------------------------------------------------------

func _add_bone(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var bone_name: String = rn[0]
	if skel.find_bone(bone_name) != -1:
		return error_conflict("Bone '%s' already exists" % bone_name)

	skel.add_bone(bone_name)
	var idx := skel.find_bone(bone_name)

	if params.has("parent"):
		var pidx := _bone_idx(skel, params["parent"])
		if pidx == -1:
			return error_not_found("Parent bone '%s'" % params["parent"])
		skel.set_bone_parent(idx, pidx)

	if params.has("rest_position") or params.has("rest"):
		var rest := Transform3D(Basis(), _v3(params, "rest_position", Vector3.ZERO))
		if params.has("rest"):
			rest = PropertyParser.parse_value(params["rest"], TYPE_TRANSFORM3D)
		skel.set_bone_rest(idx, rest)
		# Rest != pose in Godot: snap the pose to the rest so the bone actually sits there
		# (otherwise the pose stays at origin and global_pose ignores the rest).
		skel.reset_bone_pose(idx)

	return success({"node_path": params["node_path"], "index": idx, "name": bone_name, "parent": skel.get_bone_parent(idx), "bone_count": skel.get_bone_count()})


# --- set_pose ---------------------------------------------------------------

func _set_pose(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	if not params.has("bone"):
		return error_invalid_params("'bone' (name or index) is required")
	var idx := _bone_idx(skel, params["bone"])
	if idx == -1:
		return error_not_found("Bone '%s'" % params["bone"])

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set bone pose %s" % skel.get_bone_name(idx))
	var applied := {}
	if params.has("position"):
		undo_redo.add_undo_method(skel, "set_bone_pose_position", idx, skel.get_bone_pose_position(idx))
		undo_redo.add_do_method(skel, "set_bone_pose_position", idx, _v3(params, "position", Vector3.ZERO))
		applied["position"] = str(_v3(params, "position", Vector3.ZERO))
	if params.has("rotation"):
		var q := Quaternion.from_euler(_v3(params, "rotation", Vector3.ZERO) * (PI / 180.0))
		undo_redo.add_undo_method(skel, "set_bone_pose_rotation", idx, skel.get_bone_pose_rotation(idx))
		undo_redo.add_do_method(skel, "set_bone_pose_rotation", idx, q)
		applied["rotation_deg"] = str(_v3(params, "rotation", Vector3.ZERO))
	if params.has("scale"):
		undo_redo.add_undo_method(skel, "set_bone_pose_scale", idx, skel.get_bone_pose_scale(idx))
		undo_redo.add_do_method(skel, "set_bone_pose_scale", idx, _v3(params, "scale", Vector3.ONE))
		applied["scale"] = str(_v3(params, "scale", Vector3.ONE))
	if applied.is_empty():
		return error_invalid_params("Provide at least one of position/rotation/scale")
	undo_redo.commit_action()
	return success({"node_path": params["node_path"], "bone": skel.get_bone_name(idx), "index": idx, "applied": applied})


# --- get_pose ---------------------------------------------------------------

func _get_pose(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	if not params.has("bone"):
		return error_invalid_params("'bone' (name or index) is required")
	var idx := _bone_idx(skel, params["bone"])
	if idx == -1:
		return error_not_found("Bone '%s'" % params["bone"])
	return success({
		"node_path": params["node_path"],
		"bone": skel.get_bone_name(idx),
		"index": idx,
		"pose_position": str(skel.get_bone_pose_position(idx)),
		"pose_rotation": str(skel.get_bone_pose_rotation(idx)),
		"pose_scale": str(skel.get_bone_pose_scale(idx)),
		"global_pose_origin": str(skel.get_bone_global_pose(idx).origin),
	})


# --- reset_pose -------------------------------------------------------------

func _reset_pose(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	if params.has("bone"):
		var idx := _bone_idx(skel, params["bone"])
		if idx == -1:
			return error_not_found("Bone '%s'" % params["bone"])
		skel.reset_bone_pose(idx)
		return success({"node_path": params["node_path"], "reset_bone": skel.get_bone_name(idx)})
	skel.reset_bone_poses()
	return success({"node_path": params["node_path"], "reset_all": skel.get_bone_count()})


# --- add_attachment ---------------------------------------------------------

func _add_attachment(params: Dictionary) -> Dictionary:
	var ctx := _resolve_skeleton(params)
	if ctx[1] != null:
		return ctx[1]
	var skel: Skeleton3D = ctx[0]
	var root := get_edited_root()
	if not params.has("bone"):
		return error_invalid_params("'bone' (name or index) is required")
	var idx := _bone_idx(skel, params["bone"])
	if idx == -1:
		return error_not_found("Bone '%s'" % params["bone"])

	var att := BoneAttachment3D.new()
	att.name = optional_string(params, "name", "BoneAttachment3D")
	add_child_with_undo(skel, att, root, "MCP: Add BoneAttachment3D")
	# Bind after it's in the tree (the node needs its Skeleton3D parent to resolve the bone).
	att.bone_name = skel.get_bone_name(idx)
	att.bone_idx = idx
	return success({"node_path": str(root.get_path_to(att)), "bone": skel.get_bone_name(idx), "bone_idx": idx})


func get_command_docs() -> Dictionary:
	return {
		"skeleton.list_bones": {
			"description": "List a skeleton's bones. Works on Skeleton3D (index/name/parent) and Skeleton2D (Bone2D node tree with position/rotation/length).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D or Skeleton2D."),
			],
		},
		"skeleton.add_bone": {
			"description": "Add a bone to a Skeleton3D, optionally parented and given a rest. Setting a rest snaps the pose to it (rest != pose in Godot). Structural, not undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D."),
				doc_param("name", "String", true, "New bone name (must be unique)."),
				doc_param("parent", "String", false, "Parent bone by name or numeric index."),
				doc_param("rest_position", "Vector3", false, "Rest translation (identity basis). Use this OR --rest."),
				doc_param("rest", "String", false, "Full rest as a Transform3D literal. Use instead of --rest-position."),
			],
		},
		"skeleton.set_pose": {
			"description": "Set a Skeleton3D bone's pose. Provide at least one of position/rotation/scale. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D."),
				doc_param("bone", "String", true, "Bone name or numeric index."),
				doc_param("position", "Vector3", false, "Pose position."),
				doc_param("rotation", "Vector3", false, "Pose rotation as Euler degrees (x,y,z)."),
				doc_param("scale", "Vector3", false, "Pose scale."),
			],
		},
		"skeleton.get_pose": {
			"description": "Read a Skeleton3D bone's pose (position/rotation/scale) and its global-pose origin.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D."),
				doc_param("bone", "String", true, "Bone name or numeric index."),
			],
		},
		"skeleton.reset_pose": {
			"description": "Reset bone pose(s) to rest. With --bone resets that one; without, resets every bone.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D."),
				doc_param("bone", "String", false, "Bone name or index to reset; omit to reset all bones."),
			],
		},
		"skeleton.add_attachment": {
			"description": "Add a BoneAttachment3D bound to a Skeleton3D bone (parent nodes to it so they follow the bone). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton3D."),
				doc_param("bone", "String", true, "Bone name or numeric index to attach to."),
				doc_param("name", "String", false, "Attachment node name (default 'BoneAttachment3D')."),
			],
		},
		"skeleton.create_2d": {
			"description": "Build a Skeleton2D with a Bone2D hierarchy in one call; rests are baked from the authored positions. Every bone gets its owner set so it survives save. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add the Skeleton2D under (default '.')."),
				doc_param("bones", "Array", true, "JSON array of bones: {name, position: [x,y] local-to-parent, parent: earlier bone name (omit for a root)}."),
				doc_param("name", "String", false, "Skeleton2D node name (default 'Skeleton2D')."),
				doc_param("position", "Vector2", false, "Local position of the Skeleton2D node."),
			],
		},
		"skeleton.set_rest_2d": {
			"description": "Re-bake every Bone2D's rest from its current transform (the 'pose it, then make that the rest' workflow after posing via node.set).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton2D."),
			],
		},
		"skeleton.skin_2d": {
			"description": "Bind a Polygon2D to a Skeleton2D with per-vertex bone weights: explicit --weights, or auto inverse-distance weights kept to --max-influences per vertex.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Skeleton2D."),
				doc_param("polygon_path", "NodePath", true, "Polygon2D to skin (must already have vertices)."),
				doc_param("weights", "Dictionary", false, "Explicit weights {boneName: [weight per vertex]} (one float per polygon vertex). Omit for auto-weights."),
				doc_param("falloff", "float", false, "Auto-weight distance falloff exponent (default 2.0)."),
				doc_param("max_influences", "int", false, "Auto-weights: max bones influencing each vertex (default 2)."),
			],
		},
	}
