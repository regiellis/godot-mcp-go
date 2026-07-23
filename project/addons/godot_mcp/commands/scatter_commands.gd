@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## MultiMesh scatter — cheap set dressing (grass, rocks, debris) as one draw call. Populate a
## MultiMeshInstance3D with N instances seated by an edit-time down-ray onto real colliders
## (CSG use_collision / StaticBody), with optional normal-alignment, yaw and scale jitter, all
## seeded for reproducibility. This is the MultiMesh *emitter* the pcg group composes; the
## sampling/filtering layer lives there.

const _PRIMITIVES := ["BoxMesh", "SphereMesh", "CylinderMesh", "CapsuleMesh", "PlaneMesh", "PrismMesh", "TorusMesh", "QuadMesh"]


func get_commands() -> Dictionary:
	return {
		"scatter.populate": _populate,
		"scatter.clear": _clear,
		"scatter.info": _info,
	}


func _v3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


## Resolve the instanced mesh from mesh_path / mesh_type / mesh_from (copy a node's mesh).
func _resolve_mesh(params: Dictionary) -> Array:
	if params.has("mesh_path"):
		var p := str(params["mesh_path"])
		if not ResourceLoader.exists(p):
			return [null, error_not_found("Mesh '%s'" % p)]
		var res: Resource = load(p)
		if not res is Mesh:
			return [null, error_invalid_params("'%s' is not a Mesh" % p)]
		return [res as Mesh, null]
	if params.has("mesh_from"):
		var n := find_node_by_path(str(params["mesh_from"]))
		if n == null or not n is MeshInstance3D or (n as MeshInstance3D).mesh == null:
			return [null, error_invalid_params("mesh_from '%s' is not a MeshInstance3D with a mesh" % params["mesh_from"])]
		return [(n as MeshInstance3D).mesh, null]
	var mtype := optional_string(params, "mesh_type", "BoxMesh")
	if mtype not in _PRIMITIVES:
		return [null, error_invalid_params("Unknown mesh_type '%s'. Available: %s, or use mesh_path/mesh_from" % [mtype, _PRIMITIVES])]
	return [ClassDB.instantiate(mtype) as Mesh, null]


func _populate(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("scatter needs a 3D scene (root is not a Node3D)")

	var mr := _resolve_mesh(params)
	if mr[1] != null:
		return mr[1]
	var mesh: Mesh = mr[0]

	# Region: explicit min/max, or the AABB footprint of an `on` surface node.
	var rmin: Vector3
	var rmax: Vector3
	if params.has("on"):
		var surf := find_node_by_path(str(params["on"]))
		if surf == null or not surf is VisualInstance3D:
			return error_invalid_params("'on' must be a VisualInstance3D node path")
		var wa: AABB = world_aabb(surf)["aabb"]  # unions surf + visual descendants, world-space
		rmin = wa.position
		rmax = wa.end
	elif params.has("min") and params.has("max"):
		rmin = _v3(params, "min", Vector3.ZERO)
		rmax = _v3(params, "max", Vector3.ONE)
	else:
		return error_invalid_params("Provide a region: either --on <surface node> or --min/--max (world Vector3 box)")

	var count := optional_int(params, "count", 50)
	if count < 1 or count > 100000:
		return error_invalid_params("count must be 1..100000")
	var use_ray := optional_bool(params, "raycast", true)
	var align := optional_bool(params, "align_to_normal", false)
	var yaw_random := optional_bool(params, "yaw_random", true)
	var scale_min := float(params.get("scale_min", 1.0))
	var scale_max := float(params.get("scale_max", 1.0))
	var base_y := float(params.get("base_y", rmin.y))
	var skip_misses := optional_bool(params, "skip_misses", true)

	var rng := RandomNumberGenerator.new()
	rng.seed = optional_int(params, "seed", 0)

	var space: PhysicsDirectSpaceState3D = (root as Node3D).get_world_3d().direct_space_state
	var top_y := rmax.y + float(params.get("margin", 1.0))
	var bottom_y := rmin.y - float(params.get("max_drop", 1000.0))

	var transforms: Array[Transform3D] = []
	var misses := 0
	for i in count:
		var x := rng.randf_range(rmin.x, rmax.x)
		var z := rng.randf_range(rmin.z, rmax.z)
		var pos := Vector3(x, base_y, z)
		var normal := Vector3.UP
		if use_ray:
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, top_y, z), Vector3(x, bottom_y, z))
			q.collide_with_areas = false
			q.collide_with_bodies = true
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				misses += 1
				if skip_misses:
					continue
			else:
				pos = hit.position
				normal = hit.normal

		var basis := Basis()
		if align:
			basis = _basis_from_up(normal)
		if yaw_random:
			basis = basis * Basis(Vector3.UP, rng.randf() * TAU)
		var s := rng.randf_range(scale_min, scale_max)
		basis = basis.scaled(Vector3.ONE * s)
		transforms.append(Transform3D(basis, pos))

	if transforms.is_empty():
		return error(-32000, "No instances placed (all %d rays missed the region)" % count,
			{"suggestion": "Lower the region, add colliders (CSG use_collision/StaticBody), or set --raycast false"} as Dictionary)

	# Build the MultiMesh (instance transforms are in the MMI3D's local space; we keep it at origin).
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])

	# Reuse an existing MultiMeshInstance3D, or create one.
	var undo_redo := get_undo_redo()
	if params.has("node_path"):
		var node := find_node_by_path(str(params["node_path"]))
		if node == null or not node is MultiMeshInstance3D:
			return error_invalid_params("node_path '%s' is not a MultiMeshInstance3D" % params["node_path"])
		var mmi := node as MultiMeshInstance3D
		var old: Variant = mmi.multimesh
		undo_redo.create_action("MCP: Scatter into %s" % mmi.name)
		undo_redo.add_do_property(mmi, "multimesh", mm)
		undo_redo.add_do_reference(mm)
		undo_redo.add_undo_property(mmi, "multimesh", old)
		undo_redo.commit_action()
		return _result(str(params["node_path"]), transforms.size(), misses, count)

	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = optional_string(params, "name", "Scatter")
	mmi.multimesh = mm
	add_child_with_undo(parent, mmi, root, "MCP: Scatter %d instances" % transforms.size())
	return _result(str(root.get_path_to(mmi)), transforms.size(), misses, count)


func _basis_from_up(up: Vector3) -> Basis:
	up = up.normalized()
	var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := arbitrary.cross(up).normalized()
	var z := up.cross(x).normalized()
	return Basis(x, up, z)


func _result(node_path: String, placed: int, misses: int, requested: int) -> Dictionary:
	return success({
		"node_path": node_path,
		"placed": placed,
		"misses": misses,
		"requested": requested,
	})


func _clear(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null or not node is MultiMeshInstance3D:
		return error_invalid_params("node_path '%s' is not a MultiMeshInstance3D" % rn[0])
	var mmi := node as MultiMeshInstance3D
	if mmi.multimesh == null:
		return success({"node_path": rn[0], "cleared": 0})
	var n := mmi.multimesh.instance_count
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Clear scatter %s" % mmi.name)
	undo_redo.add_do_property(mmi.multimesh, "instance_count", 0)
	undo_redo.add_undo_property(mmi.multimesh, "instance_count", n)
	undo_redo.commit_action()
	return success({"node_path": rn[0], "cleared": n})


func _info(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null or not node is MultiMeshInstance3D:
		return error_invalid_params("node_path '%s' is not a MultiMeshInstance3D" % rn[0])
	var mmi := node as MultiMeshInstance3D
	if mmi.multimesh == null:
		return success({"node_path": rn[0], "instance_count": 0, "mesh": ""})
	return success({
		"node_path": rn[0],
		"instance_count": mmi.multimesh.instance_count,
		"mesh": mmi.multimesh.mesh.get_class() if mmi.multimesh.mesh != null else "",
	})


func get_command_docs() -> Dictionary:
	return {
		"scatter.populate": {
			"description": "Fill a MultiMeshInstance3D with N instances seated by an edit-time down-ray onto colliders (CSG use_collision/StaticBody), with optional normal-align, yaw and scale jitter. Seeded. Reuses --node-path if given, else creates one under --parent-path. Undoable. 3D scene only. Provide one mesh (--mesh-type/--mesh-path/--mesh-from) and one region (--on or --min/--max).",
			"params": [
				doc_param("mesh_type", "String", false, "Primitive mesh class (BoxMesh, SphereMesh, ...; default BoxMesh)."),
				doc_param("mesh_path", "String", false, "Path to a Mesh resource to instance (overrides --mesh-type)."),
				doc_param("mesh_from", "NodePath", false, "Borrow the mesh from this MeshInstance3D."),
				doc_param("on", "NodePath", false, "Region: a VisualInstance3D whose world AABB footprint bounds the scatter. Use this OR --min/--max."),
				doc_param("min", "Vector3", false, "Region min corner (pair with --max). Use instead of --on."),
				doc_param("max", "Vector3", false, "Region max corner (pair with --min)."),
				doc_param("count", "int", false, "Instances to attempt, 1..100000 (default 50)."),
				doc_param("raycast", "bool", false, "Down-ray each point onto colliders to seat it (default true)."),
				doc_param("skip_misses", "bool", false, "Drop points whose ray missed instead of placing at base_y (default true)."),
				doc_param("base_y", "float", false, "Y used when a ray misses / --raycast is false (default region min Y)."),
				doc_param("margin", "float", false, "Height above the region top the seating ray starts (default 1.0)."),
				doc_param("max_drop", "float", false, "How far below the region bottom the ray reaches (default 1000)."),
				doc_param("align_to_normal", "bool", false, "Orient instances to the surface normal (default false)."),
				doc_param("yaw_random", "bool", false, "Apply a random yaw per instance (default true)."),
				doc_param("scale_min", "float", false, "Minimum uniform scale jitter (default 1.0)."),
				doc_param("scale_max", "float", false, "Maximum uniform scale jitter (default 1.0)."),
				doc_param("seed", "int", false, "RNG seed for reproducibility (default 0)."),
				doc_param("node_path", "NodePath", false, "Existing MultiMeshInstance3D to fill (replaces its multimesh). Omit to create a new one."),
				doc_param("parent_path", "NodePath", false, "Parent for a newly-created MultiMeshInstance3D (default '.'). --parent is an alias."),
				doc_param("name", "String", false, "Name for a newly-created node (default 'Scatter')."),
			],
		},
		"scatter.clear": {
			"description": "Zero a MultiMeshInstance3D's instance_count (empties the scatter without deleting the node). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MultiMeshInstance3D."),
			],
		},
		"scatter.info": {
			"description": "Report a MultiMeshInstance3D's instance_count and mesh class.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MultiMeshInstance3D."),
			],
		},
	}
