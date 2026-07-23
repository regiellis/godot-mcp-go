@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Mesh-geometry ops the rest of the surface can't reach (node.set tweaks resources, never
## vertices). Phase D of the tile-assembly roadmap: free-form lattice deformation, so a square
## module can be warped to fit an irregular cell — the video's exact recipe (store each vertex
## as a percentage of the bounds, rebuild from displaced corner handles via trilinear interp).
##
## Handle order — 8 corners of the local AABB, indexed by bit (x=i&1, y=(i>>1)&1, z=(i>>2)&1):
##   0:(-x-y-z) 1:(+x-y-z) 2:(-x+y-z) 3:(+x+y-z) 4:(-x-y+z) 5:(+x-y+z) 6:(-x+y+z) 7:(+x+y+z)
##   bottom face (min Y) = 0,1,4,5 ; top face (max Y) = 2,3,6,7


func get_commands() -> Dictionary:
	return {
		"mesh.info": _info,
		"mesh.deform_lattice": _deform_lattice,
	}


func _resolve_mesh_instance(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	if not node is MeshInstance3D:
		return [null, error_invalid_params("Node '%s' is not a MeshInstance3D (is %s)" % [rn[0], node.get_class()])]
	if (node as MeshInstance3D).mesh == null:
		return [null, error(-32000, "MeshInstance3D '%s' has no mesh" % rn[0])]
	return [node as MeshInstance3D, null]


## Normalize any Mesh to an ArrayMesh (PrimitiveMesh like BoxMesh lacks the ArrayMesh-only
## surface introspection / MeshDataTool needs). Primitives are always triangle surfaces.
func _to_array_mesh(src: Mesh) -> ArrayMesh:
	if src is ArrayMesh:
		return src as ArrayMesh
	var am := ArrayMesh.new()
	for s in src.get_surface_count():
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(s))
		var mat := src.surface_get_material(s)
		if mat != null:
			am.surface_set_material(am.get_surface_count() - 1, mat)
	return am


func _parse_v3(v: Variant) -> Vector3:
	if v is String:
		var pv: Variant = PropertyParser.parse_value(v, TYPE_VECTOR3)
		if pv is Vector3:
			return pv
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Dictionary:
		return Vector3(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("z", 0)))
	return Vector3.ZERO


# --- mesh.info --------------------------------------------------------------

func _info(params: Dictionary) -> Dictionary:
	var ctx := _resolve_mesh_instance(params)
	if ctx[1] != null:
		return ctx[1]
	var mi: MeshInstance3D = ctx[0]
	var mesh := _to_array_mesh(mi.mesh)
	var aabb := mesh.get_aabb()
	var surfaces: Array = []
	var total_v := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var vc := 0
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			vc = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		total_v += vc
		surfaces.append({
			"surface": s,
			"primitive": mesh.surface_get_primitive_type(s),
			"vertices": vc,
			"material": mesh.surface_get_material(s).resource_path if mesh.surface_get_material(s) != null else "",
		})
	return success({
		"node_path": params["node_path"],
		"mesh_class": mesh.get_class(),
		"surface_count": mesh.get_surface_count(),
		"total_vertices": total_v,
		"aabb_position": str(aabb.position),
		"aabb_size": str(aabb.size),
		"surfaces": surfaces,
	})


# --- mesh.deform_lattice ----------------------------------------------------

## Trilinear interpolation of the 8 displaced corner handles, by each vertex's normalized
## position within the source AABB.
func _trilinear(handles: Array, u: float, v: float, w: float) -> Vector3:
	var c00: Vector3 = handles[0].lerp(handles[1], u)
	var c10: Vector3 = handles[2].lerp(handles[3], u)
	var c01: Vector3 = handles[4].lerp(handles[5], u)
	var c11: Vector3 = handles[6].lerp(handles[7], u)
	var c0: Vector3 = c00.lerp(c10, v)
	var c1: Vector3 = c01.lerp(c11, v)
	return c0.lerp(c1, w)


func _deform_lattice(params: Dictionary) -> Dictionary:
	var ctx := _resolve_mesh_instance(params)
	if ctx[1] != null:
		return ctx[1]
	var mi: MeshInstance3D = ctx[0]
	var src_mesh := _to_array_mesh(mi.mesh)

	if not params.has("handles"):
		return error_invalid_params("Missing --handles (JSON array of 8 Vector3 corner positions, local space)")
	var raw: Variant = params["handles"]
	if raw is String:
		raw = JSON.parse_string(raw)
	if not raw is Array or (raw as Array).size() != 8:
		return error_invalid_params("--handles must be a JSON array of exactly 8 Vector3 corner positions")
	var handles: Array = []
	for e in raw:
		handles.append(_parse_v3(e))

	var aabb := src_mesh.get_aabb()
	var sz := aabb.size
	# guard zero-thickness axes (a flat mesh) so the % is well-defined
	var inv := Vector3(
		1.0 / sz.x if sz.x > 0.00001 else 0.0,
		1.0 / sz.y if sz.y > 0.00001 else 0.0,
		1.0 / sz.z if sz.z > 0.00001 else 0.0,
	)

	var out_mesh := ArrayMesh.new()
	var deformed_surfaces := 0
	var skipped: Array = []
	var total_v := 0
	for s in src_mesh.get_surface_count():
		if src_mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			skipped.append({"surface": s, "reason": "not triangles"})
			continue
		# Wrap the surface in a standalone ArrayMesh so MeshDataTool can edit it.
		var tmp := ArrayMesh.new()
		tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, src_mesh.surface_get_arrays(s))
		var mdt := MeshDataTool.new()
		if mdt.create_from_surface(tmp, 0) != OK:
			skipped.append({"surface": s, "reason": "MeshDataTool failed (needs an indexed triangle surface)"})
			continue
		var vc := mdt.get_vertex_count()
		for i in vc:
			var p := mdt.get_vertex(i)
			var u := (p.x - aabb.position.x) * inv.x
			var vv := (p.y - aabb.position.y) * inv.y
			var ww := (p.z - aabb.position.z) * inv.z
			mdt.set_vertex(i, _trilinear(handles, u, vv, ww))
		# recompute vertex normals from the deformed faces
		var accum := PackedVector3Array()
		accum.resize(vc)
		for f in mdt.get_face_count():
			var n := mdt.get_face_normal(f)
			for k in 3:
				var vi := mdt.get_face_vertex(f, k)
				accum[vi] = accum[vi] + n
		for i in vc:
			var nrm := accum[i]
			mdt.set_vertex_normal(i, nrm.normalized() if nrm.length() > 0.0 else Vector3.UP)
		mdt.commit_to_surface(out_mesh)
		out_mesh.surface_set_material(out_mesh.get_surface_count() - 1, src_mesh.surface_get_material(s))
		deformed_surfaces += 1
		total_v += vc

	if deformed_surfaces == 0:
		return error(-32000, "No deformable triangle surfaces", {"skipped": skipped})

	# Optionally persist; otherwise just assign the in-memory mesh to the node.
	var saved_path := ""
	if params.has("mesh_path"):
		var mp := String(params["mesh_path"])
		var guard := guard_project_path(mp)
		if not guard.is_empty():
			return guard
		if not (mp.ends_with(".mesh") or mp.ends_with(".res") or mp.ends_with(".tres")):
			return error_invalid_params("mesh_path must end in .mesh, .res or .tres")
		var err := ResourceSaver.save(out_mesh, mp)
		if err != OK:
			return error_internal("Failed to save mesh: %s" % error_string(err))
		EditorInterface.get_resource_filesystem().update_file(mp)
		saved_path = mp

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Deform mesh on %s" % mi.name)
	undo_redo.add_undo_property(mi, "mesh", mi.mesh)
	undo_redo.add_do_property(mi, "mesh", out_mesh)
	undo_redo.add_do_reference(out_mesh)
	undo_redo.commit_action()

	var new_aabb := out_mesh.get_aabb()
	return success({
		"node_path": params["node_path"],
		"deformed_surfaces": deformed_surfaces,
		"vertices": total_v,
		"skipped": skipped,
		"new_aabb_position": str(new_aabb.position),
		"new_aabb_size": str(new_aabb.size),
		"mesh_path": saved_path,
	})


func get_command_docs() -> Dictionary:
	return {
		"mesh.info": {
			"description": "Report a MeshInstance3D's geometry: surface count, per-surface primitive/vertex-count/material, total vertices, and local AABB (primitives are normalized to an ArrayMesh for introspection).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MeshInstance3D (must have a mesh)."),
			],
		},
		"mesh.deform_lattice": {
			"description": "Free-form deform a MeshInstance3D's geometry via trilinear interpolation of 8 displaced AABB-corner handles (warp a square module to fit an irregular cell). Recomputes normals; assigns the new mesh to the node (undoable). Non-triangle surfaces are skipped.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MeshInstance3D."),
				doc_param("handles", "Array", true, "JSON array of exactly 8 local-space Vector3 corner positions, indexed by bit (x=i&1, y=(i>>1)&1, z=(i>>2)&1): 0=(-x-y-z) ... 7=(+x+y+z)."),
				doc_param("mesh_path", "String", false, "If set, also save the deformed mesh to this path (must end in .mesh, .res, or .tres)."),
			],
		},
	}
