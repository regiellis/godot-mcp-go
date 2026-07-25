@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## CSG authoring — the greybox workhorse. node.add can create CSG nodes and node.set
## can poke their props, but this group gives the operations those don't do ergonomically:
## boolean operation by name, wrapping a set of shapes in a CSGCombiner3D, and — the payoff —
## baking a proven CSG tree down to a static MeshInstance3D (+ collision), the graybox→mesh
## handoff. Bake uses the live 4.7 API: CSGShape3D.bake_static_mesh()/bake_collision_shape().

const _OPERATIONS := {"union": 0, "intersection": 1, "subtraction": 2}


func get_commands() -> Dictionary:
	return {
		"csg.add": _add,
		"csg.set_operation": _set_operation,
		"csg.combine": _combine,
		"csg.bake": _bake,
	}


func _vector3_param(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


func _is_csg(node: Node) -> bool:
	return node is CSGShape3D


# --- add --------------------------------------------------------------------

func _add(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	# Accept `parent` as an alias for `parent_path`, matching node.add.
	var parent_path := optional_string(params, "parent_path", optional_string(params, "parent", "."))
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var type := optional_string(params, "type", "CSGBox3D")
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "CSGShape3D"):
		return error_invalid_params("'%s' is not a CSG node type (must extend CSGShape3D, e.g. CSGBox3D/CSGSphere3D/CSGCylinder3D/CSGTorus3D/CSGPolygon3D/CSGMesh3D/CSGCombiner3D)" % type)
	if not ClassDB.can_instantiate(type):
		return error_invalid_params("'%s' cannot be instantiated" % type)

	var node: CSGShape3D = ClassDB.instantiate(type)
	node.name = optional_string(params, "name", type)

	if params.has("operation"):
		var op := str(params["operation"]).to_lower()
		if not _OPERATIONS.has(op):
			node.free()
			return error_invalid_params("Unknown operation '%s'. Use union, subtraction, or intersection" % op)
		node.operation = _OPERATIONS[op]
	node.use_collision = optional_bool(params, "use_collision", false)

	# Convenience dims + any extra props, version-agnostic via "prop in node".
	var props: Dictionary = params.get("properties", {})
	if params.has("size"): props["size"] = params["size"]
	if params.has("radius"): props["radius"] = params["radius"]
	if params.has("height"): props["height"] = params["height"]
	var ignored: Array = []
	for pname: String in props:
		if pname in node:
			node.set(pname, PropertyParser.parse_value(props[pname], typeof(node.get(pname))))
		else:
			ignored.append(pname)

	node.position = _vector3_param(params, "position", Vector3.ZERO)
	node.rotation_degrees = _vector3_param(params, "rotation", Vector3.ZERO)
	if params.has("scale"):
		node.scale = _vector3_param(params, "scale", Vector3.ONE)

	add_child_with_undo(parent, node, root, "MCP: Add %s" % type)
	return success({
		"node_path": str(root.get_path_to(node)),
		"name": String(node.name),
		"type": type,
		"operation": _OPERATIONS.find_key(node.operation),
		"is_root_shape": node.is_root_shape(),
		"ignored_properties": ignored,
	})


# --- set_operation ----------------------------------------------------------

func _set_operation(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not _is_csg(node):
		return error_invalid_params("Node '%s' is not a CSG node (is %s)" % [rn[0], node.get_class()])

	var ro := require_string(params, "operation")
	if ro[1] != null:
		return ro[1]
	var op := str(ro[0]).to_lower()
	if not _OPERATIONS.has(op):
		return error_invalid_params("Unknown operation '%s'. Use union, subtraction, or intersection" % op)

	var csg := node as CSGShape3D
	var old: int = csg.operation
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set CSG operation on %s" % csg.name)
	undo_redo.add_do_property(csg, "operation", _OPERATIONS[op])
	undo_redo.add_undo_property(csg, "operation", old)
	undo_redo.commit_action()
	return success({"node_path": rn[0], "operation": op})


# --- combine ----------------------------------------------------------------

## Wrap a set of CSG nodes under a new CSGCombiner3D so they form one CSG tree.
## Reparents each (preserving global transform), following node.move's undo pattern.
func _combine(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var nr := require_dict_array(params, "nodes")
	if nr[1] != null:
		return nr[1]
	var node_paths: Array = nr[0]
	if node_paths.size() < 1:
		return error_invalid_params("'nodes' must list at least one CSG node path")

	var nodes: Array[CSGShape3D] = []
	for np: Variant in node_paths:
		var n := find_node_by_path(str(np))
		if n == null:
			return error_not_found("Node at '%s'" % np)
		if not _is_csg(n):
			return error_invalid_params("Node '%s' is not a CSG node (is %s)" % [np, n.get_class()])
		nodes.append(n as CSGShape3D)

	# Default combiner parent = the first node's parent, so it slots in place.
	var parent := find_node_by_path(optional_string(params, "parent_path", str(root.get_path_to(nodes[0].get_parent()))))
	if parent == null:
		parent = nodes[0].get_parent()

	var combiner := CSGCombiner3D.new()
	combiner.name = optional_string(params, "name", "CSGCombiner3D")

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Combine %d CSG nodes" % nodes.size())
	undo_redo.add_do_method(parent, "add_child", combiner)
	undo_redo.add_do_method(combiner, "set_owner", root)
	undo_redo.add_do_reference(combiner)
	for n in nodes:
		var old_parent := n.get_parent()
		var gt := n.global_transform
		undo_redo.add_do_method(old_parent, "remove_child", n)
		undo_redo.add_do_method(combiner, "add_child", n)
		undo_redo.add_do_method(n, "set_owner", root)
		undo_redo.add_do_property(n, "global_transform", gt)
		undo_redo.add_undo_method(combiner, "remove_child", n)
		undo_redo.add_undo_method(old_parent, "add_child", n)
		undo_redo.add_undo_method(n, "set_owner", root)
		undo_redo.add_undo_property(n, "global_transform", gt)
	undo_redo.add_undo_method(parent, "remove_child", combiner)
	undo_redo.commit_action()

	return success({
		"node_path": str(root.get_path_to(combiner)),
		"name": String(combiner.name),
		"combined": nodes.size(),
	})


# --- bake -------------------------------------------------------------------

## Freeze a CSG tree to a static MeshInstance3D (+ optional collision body). The
## graybox→mesh handoff: the proven blockout becomes cheap static geometry.
func _bake(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not _is_csg(node):
		return error_invalid_params("Node '%s' is not a CSG node (is %s)" % [rn[0], node.get_class()])
	var csg := node as CSGShape3D

	var warnings: Array = []
	if not csg.is_root_shape():
		warnings.append("'%s' is not the root CSG shape; baking its subtree only. Bake the root for the whole boolean result." % rn[0])

	var mesh: ArrayMesh = csg.bake_static_mesh()
	if mesh == null or mesh.get_surface_count() == 0:
		return error(-32000, "CSG produced no mesh (empty result or not yet evaluated)")

	# Optionally persist the mesh as a shared resource; otherwise embed it.
	if params.has("mesh_path"):
		var mesh_path := str(params["mesh_path"])
		var guard := guard_project_path(mesh_path)
		if not guard.is_empty():
			return guard
		var dir := mesh_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
		var err := ResourceSaver.save(mesh, mesh_path)
		if err != OK:
			return error_internal("Failed to save mesh: %s" % error_string(err))
		EditorInterface.get_resource_filesystem().update_file(mesh_path)
		mesh.take_over_path(mesh_path)

	var mi := MeshInstance3D.new()
	mi.name = optional_string(params, "name", String(csg.name) + "_baked")
	mi.mesh = mesh
	mi.transform = csg.transform  # baked verts are in csg-local space → match its transform

	# Carry the CSG's own material onto the baked mesh override, if it has one.
	if "material" in csg and csg.get("material") is Material:
		mi.material_override = csg.get("material")

	var make_collision := optional_bool(params, "collision", csg.use_collision)
	var body: StaticBody3D = null
	if make_collision:
		var shape := csg.bake_collision_shape()
		if shape != null and shape.get_faces().size() > 0:
			body = StaticBody3D.new()
			body.name = "StaticBody3D"
			var cs := CollisionShape3D.new()
			cs.name = "CollisionShape3D"
			cs.shape = shape
			body.add_child(cs)
		else:
			warnings.append("collision requested but bake_collision_shape() was empty (does the CSG have use_collision/geometry?)")

	var parent := csg.get_parent()
	var replace := optional_bool(params, "replace", false)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Bake CSG %s to mesh" % csg.name)
	undo_redo.add_do_method(parent, "add_child", mi)
	undo_redo.add_do_method(mi, "set_owner", root)
	undo_redo.add_do_reference(mi)
	if body != null:
		undo_redo.add_do_method(mi, "add_child", body)
		undo_redo.add_do_method(body, "set_owner", root)
		undo_redo.add_do_method(body.get_child(0), "set_owner", root)
	if replace:
		undo_redo.add_do_method(parent, "remove_child", csg)
		undo_redo.add_undo_method(parent, "add_child", csg)
		undo_redo.add_undo_method(csg, "set_owner", root)
	undo_redo.add_undo_method(parent, "remove_child", mi)
	undo_redo.commit_action()

	var surfaces := mesh.get_surface_count()
	var verts := 0
	for s in surfaces:
		verts += mesh.surface_get_array_len(s)

	return success({
		"node_path": str(root.get_path_to(mi)),
		"name": String(mi.name),
		"surfaces": surfaces,
		"vertices": verts,
		"collision": body != null,
		"mesh_path": params.get("mesh_path", ""),
		"replaced_source": replace,
		"warnings": warnings,
	})


# --- helper -----------------------------------------------------------------

## Require an Array param (accepts a JSON array passed as a string), mirroring require_dict.
func require_dict_array(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return [[], error_invalid_params("Missing required parameter: %s" % key)]
	var v: Variant = params[key]
	if v is Array:
		return [v, null]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Array:
			return [parsed, null]
	return [[], error_invalid_params("Parameter '%s' must be a JSON array" % key)]


func get_command_docs() -> Dictionary:
	return {
		"csg.add": {
			"description": "Add a CSG node (CSGBox3D/Sphere/Cylinder/Torus/Polygon/Mesh/Combiner3D) under --parent-path. Convenience dims size/radius/height apply if valid for the type; extra --properties are set version-agnostically. 3D scene. Undoable.",
			"params": [
				doc_param("type", "String", false, "CSG node class (must extend CSGShape3D; default CSGBox3D)."),
				doc_param("parent_path", "NodePath", false, "Parent, relative to the scene root (default '.'; --parent is an alias)."),
				doc_param("name", "String", false, "Name for the new node (defaults to the type)."),
				doc_param("operation", "String", false, "Boolean op: union, subtraction, or intersection."),
				doc_param("use_collision", "bool", false, "Generate collision faces (default false)."),
				doc_param("size", "Vector3", false, "Box size convenience (if the type has 'size')."),
				doc_param("radius", "float", false, "Radius convenience (Sphere/Cylinder/Torus)."),
				doc_param("height", "float", false, "Height convenience (Cylinder)."),
				doc_param("properties", "Dictionary", false, "Extra {property: value}; unknown keys are reported as ignored."),
				doc_param("position", "Vector3", false, "Local position (default 0,0,0)."),
				doc_param("rotation", "Vector3", false, "Local rotation in degrees."),
				doc_param("scale", "Vector3", false, "Local scale."),
			],
		},
		"csg.set_operation": {
			"description": "Set a CSG node's boolean operation. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target CSG node."),
				doc_param("operation", "String", true, "union, subtraction, or intersection."),
			],
		},
		"csg.combine": {
			"description": "Wrap CSG nodes under a new CSGCombiner3D so they form one CSG tree, preserving each node's global transform. Undoable.",
			"params": [
				doc_param("nodes", "Array", true, "JSON array of CSG node paths to combine (>= 1)."),
				doc_param("parent_path", "NodePath", false, "Where to add the combiner (default the first node's parent)."),
				doc_param("name", "String", false, "Name for the combiner (default CSGCombiner3D)."),
			],
		},
		"csg.bake": {
			"description": "Freeze a CSG tree to a static MeshInstance3D (+ optional collision StaticBody3D), the greybox-to-mesh handoff. Bake the root shape for the whole boolean result. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "CSG node to bake (bake the root shape for the full result)."),
				doc_param("mesh_path", "String", false, "Persist the baked mesh to this .res/.tres/.mesh path; otherwise it's embedded."),
				doc_param("name", "String", false, "Name for the MeshInstance3D (default '<csg>_baked')."),
				doc_param("collision", "bool", false, "Also bake a collision body (default follows the CSG's use_collision)."),
				doc_param("replace", "bool", false, "Remove the source CSG node after baking (default false)."),
			],
		},
	}
