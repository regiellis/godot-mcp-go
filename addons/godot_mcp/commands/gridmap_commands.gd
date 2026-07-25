@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## GridMap authoring — the 3D analog of the tilemap group. scene3d.add_gridmap creates the
## node and can bulk-set cells, but a GridMap is useless without a MeshLibrary, and there was no
## painting/inspection layer. This group: build a MeshLibrary from a scene (the scriptable
## "Scene → MeshLibrary" the editor only exposes as a menu item), then paint/fill/read/clear cells.

const INVALID := -1  # GridMap.INVALID_CELL_ITEM


func get_commands() -> Dictionary:
	return {
		"gridmap.meshlibrary_from_scene": _meshlibrary_from_scene,
		"gridmap.list_items": _list_items,
		"gridmap.set_cell": _set_cell,
		"gridmap.set_cell_variant": _set_cell_variant,
		"gridmap.fill": _fill,
		"gridmap.get_cell": _get_cell,
		"gridmap.clear": _clear,
		"gridmap.get_used_cells": _get_used_cells,
	}


# --- helpers ----------------------------------------------------------------

func _vector3i_param(params: Dictionary, key: String, default: Vector3i) -> Vector3i:
	if params.has(key):
		var val: Variant = params[key]
		if val is String:
			return PropertyParser.parse_value(val, TYPE_VECTOR3I)
		if val is Array and (val as Array).size() >= 3:
			return Vector3i(int(val[0]), int(val[1]), int(val[2]))
		if val is Dictionary:
			return Vector3i(int(val.get("x", default.x)), int(val.get("y", default.y)), int(val.get("z", default.z)))
	# fall back to discrete x/y/z params
	if params.has("x") or params.has("y") or params.has("z"):
		return Vector3i(optional_int(params, "x", default.x), optional_int(params, "y", default.y), optional_int(params, "z", default.z))
	return default


func _resolve_gridmap(params: Dictionary) -> Array:
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return [null, rn[1]]
	var node := find_node_by_path(rn[0])
	if node == null:
		return [null, error_not_found("Node at '%s'" % rn[0])]
	if not node is GridMap:
		return [null, error_invalid_params("Node '%s' is not a GridMap (is %s)" % [rn[0], node.get_class()])]
	return [node as GridMap, null]


func _collect_shapes(item_root: Node) -> Array:
	# Flat [Shape3D, Transform3D, …] array as MeshLibrary.set_item_shapes wants,
	# gathered from any CollisionShape3D under the item (relative to the item root).
	var shapes: Array = []
	var queue: Array[Node] = [item_root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is CollisionShape3D and (n as CollisionShape3D).shape != null:
			var cs := n as CollisionShape3D
			var xform: Transform3D = item_root.global_transform.affine_inverse() * cs.global_transform if item_root is Node3D else cs.transform
			shapes.append(cs.shape)
			shapes.append(xform)
		for c in n.get_children():
			queue.append(c)
	return shapes


func _first_mesh_instance(item_root: Node) -> MeshInstance3D:
	var queue: Array[Node] = [item_root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			return n as MeshInstance3D
		for c in n.get_children():
			queue.append(c)
	return null


# --- meshlibrary_from_scene -------------------------------------------------

## Replicates the editor's "Scene → MeshLibrary": each direct child of the scene root that
## contains a MeshInstance3D becomes a library item (mesh + collision shapes + name).
func _meshlibrary_from_scene(params: Dictionary) -> Dictionary:
	var rs := require_string(params, "scene_path")
	if rs[1] != null:
		return rs[1]
	var scene_path: String = rs[0]
	if not ResourceLoader.exists(scene_path):
		return error_not_found("Scene '%s'" % scene_path)
	var ro := require_string(params, "output_path")
	if ro[1] != null:
		return ro[1]
	var output_path: String = ro[0]
	if not (output_path.ends_with(".meshlib") or output_path.ends_with(".tres") or output_path.ends_with(".res")):
		return error_invalid_params("output_path must end in .meshlib, .tres or .res")
	var guard := guard_project_path(output_path)
	if not guard.is_empty():
		return guard

	var packed: Resource = load(scene_path)
	if not packed is PackedScene:
		return error_invalid_params("'%s' is not a PackedScene" % scene_path)
	var instance := (packed as PackedScene).instantiate()
	var with_collision := optional_bool(params, "collision", true)

	# Merge into an existing library if requested, else fresh.
	var lib: MeshLibrary
	if optional_bool(params, "merge", false) and ResourceLoader.exists(output_path):
		var existing: Resource = load(output_path)
		lib = existing as MeshLibrary if existing is MeshLibrary else MeshLibrary.new()
	else:
		lib = MeshLibrary.new()

	var items: Array = []
	for child in instance.get_children():
		var mi := _first_mesh_instance(child)
		if mi == null:
			continue
		var id: int = lib.get_last_unused_item_id()
		lib.create_item(id)
		lib.set_item_name(id, String(child.name))
		lib.set_item_mesh(id, mi.mesh)
		if child is Node3D and mi is Node3D:
			lib.set_item_mesh_transform(id, (child as Node3D).transform.affine_inverse() * mi.global_transform if child != mi else mi.transform)
		if with_collision:
			var shapes := _collect_shapes(child)
			if not shapes.is_empty():
				lib.set_item_shapes(id, shapes)
		items.append({"id": id, "name": String(child.name), "has_collision": with_collision and not _collect_shapes(child).is_empty()})

	instance.free()

	if items.is_empty():
		return error(-32000, "No MeshInstance3D items found among the scene root's children")

	var dir := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := ResourceSaver.save(lib, output_path)
	if err != OK:
		return error_internal("Failed to save MeshLibrary: %s" % error_string(err))
	EditorInterface.get_resource_filesystem().update_file(output_path)

	return success({"output_path": output_path, "item_count": items.size(), "items": items})


# --- list_items -------------------------------------------------------------

func _list_items(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	if gm.mesh_library == null:
		return error(-32000, "GridMap '%s' has no mesh_library assigned" % params["node_path"],
			{"suggestion": "Build one with gridmap.meshlibrary_from_scene, then assign via node.set mesh_library, or scene3d.add_gridmap --mesh_library_path"} as Dictionary)
	var lib := gm.mesh_library
	var items: Array = []
	for id in lib.get_item_list():
		items.append({"id": id, "name": lib.get_item_name(id)})
	return success({"node_path": params["node_path"], "item_count": items.size(), "items": items})


# --- set_cell ---------------------------------------------------------------

func _set_cell(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	var pos := _vector3i_param(params, "cell", Vector3i.ZERO)
	var item := optional_int(params, "item", INVALID)
	var orient := optional_int(params, "orientation", 0)

	var old_item: int = gm.get_cell_item(pos)
	var old_orient: int = gm.get_cell_item_orientation(pos)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set GridMap cell %s" % pos)
	undo_redo.add_do_method(gm, "set_cell_item", pos, item, orient)
	undo_redo.add_undo_method(gm, "set_cell_item", pos, old_item, old_orient)
	undo_redo.commit_action()
	return success({"cell": str(pos), "item": item, "orientation": orient})


# --- set_cell_variant -------------------------------------------------------

## Deterministic spatial hash → index into a candidate list. Same (cell, seed) always
## picks the same variant, so a re-run converges and neighbours don't visibly repeat.
static func variant_index(cell: Vector3i, seed: int, n: int) -> int:
	if n <= 1:
		return 0
	var h := (cell.x * 73856093) ^ (cell.y * 19349663) ^ (cell.z * 83492791) ^ (seed * 2654435761)
	return ((h % n) + n) % n


## Paint a cell with one item chosen from a candidate set, picked deterministically by
## (cell, seed). The de-repetition primitive: author several mesh variants for a logical
## tile, hand them all here, and identical-looking neighbours stop forming.
func _set_cell_variant(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	if not params.has("variants"):
		return error_invalid_params("Missing --variants (JSON array of MeshLibrary item ids)")
	var raw: Variant = params["variants"]
	if raw is String:
		raw = JSON.parse_string(raw)
	if not raw is Array or (raw as Array).is_empty():
		return error_invalid_params("--variants must be a non-empty JSON array of item ids")
	var variants: Array = raw
	var pos := _vector3i_param(params, "cell", Vector3i.ZERO)
	var seed := optional_int(params, "seed", 0)
	var idx := variant_index(pos, seed, variants.size())
	var item := int(variants[idx])
	var orient := optional_int(params, "orientation", 0)

	var old_item: int = gm.get_cell_item(pos)
	var old_orient: int = gm.get_cell_item_orientation(pos)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set GridMap cell variant %s" % pos)
	undo_redo.add_do_method(gm, "set_cell_item", pos, item, orient)
	undo_redo.add_undo_method(gm, "set_cell_item", pos, old_item, old_orient)
	undo_redo.commit_action()
	return success({"cell": str(pos), "item": item, "variant_index": idx, "variants": variants.size(), "orientation": orient})


# --- fill -------------------------------------------------------------------

func _fill(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	var from := _vector3i_param(params, "from", Vector3i.ZERO)
	var to := _vector3i_param(params, "to", from)
	var item := optional_int(params, "item", INVALID)
	var orient := optional_int(params, "orientation", 0)

	var lo := Vector3i(mini(from.x, to.x), mini(from.y, to.y), mini(from.z, to.z))
	var hi := Vector3i(maxi(from.x, to.x), maxi(from.y, to.y), maxi(from.z, to.z))
	var count := (hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1)
	if count > 8192:
		return error_invalid_params("Region too large (%d cells, max 8192). Narrow from/to." % count)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Fill %d GridMap cells" % count)
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var pos := Vector3i(x, y, z)
				undo_redo.add_do_method(gm, "set_cell_item", pos, item, orient)
				undo_redo.add_undo_method(gm, "set_cell_item", pos, gm.get_cell_item(pos), gm.get_cell_item_orientation(pos))
	undo_redo.commit_action()
	return success({"from": str(lo), "to": str(hi), "item": item, "cells_filled": count})


# --- get_cell ---------------------------------------------------------------

func _get_cell(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	var pos := _vector3i_param(params, "cell", Vector3i.ZERO)
	var item: int = gm.get_cell_item(pos)
	var name := ""
	if item != INVALID and gm.mesh_library != null:
		name = gm.mesh_library.get_item_name(item)
	return success({
		"cell": str(pos),
		"item": item,
		"empty": item == INVALID,
		"item_name": name,
		"orientation": gm.get_cell_item_orientation(pos),
	})


# --- clear ------------------------------------------------------------------

func _clear(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]

	# Region clear if from/to given, else whole map.
	if params.has("from") or params.has("to"):
		var fp := params.duplicate()
		fp["item"] = INVALID
		return _fill(fp)

	var used := gm.get_used_cells()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Clear GridMap (%d cells)" % used.size())
	for pos: Vector3i in used:
		undo_redo.add_do_method(gm, "set_cell_item", pos, INVALID, 0)
		undo_redo.add_undo_method(gm, "set_cell_item", pos, gm.get_cell_item(pos), gm.get_cell_item_orientation(pos))
	undo_redo.commit_action()
	return success({"cleared": used.size()})


# --- get_used_cells ---------------------------------------------------------

func _get_used_cells(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	var cells: Array
	if params.has("item"):
		cells = gm.get_used_cells_by_item(optional_int(params, "item", INVALID))
	else:
		cells = gm.get_used_cells()
	var out: Array = []
	for pos: Vector3i in cells:
		out.append({"cell": str(pos), "item": gm.get_cell_item(pos)})
	return success({"count": out.size(), "cells": out})


func get_command_docs() -> Dictionary:
	return {
		"gridmap.meshlibrary_from_scene": {
			"description": "Build a MeshLibrary from a scene (the scriptable 'Scene to MeshLibrary'): each direct child of the scene root containing a MeshInstance3D becomes an item (mesh + collision shapes + name).",
			"params": [
				doc_param("scene_path", "String", true, "Source scene to convert."),
				doc_param("output_path", "String", true, "Output library path; must end in .meshlib, .tres, or .res."),
				doc_param("collision", "bool", false, "Include CollisionShape3D shapes as item collision (default true)."),
				doc_param("merge", "bool", false, "Merge into an existing library at output_path instead of replacing (default false)."),
			],
		},
		"gridmap.list_items": {
			"description": "List the id and name of every item in the GridMap's assigned MeshLibrary. Errors if no library is assigned.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
			],
		},
		"gridmap.set_cell": {
			"description": "Set a GridMap cell to a MeshLibrary item (item=-1 clears it). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("cell", "Vector3", true, "Integer cell coordinate, e.g. 'Vector3i(1,0,2)' (discrete --x/--y/--z also accepted)."),
				doc_param("item", "int", false, "MeshLibrary item id, or -1 to clear (default -1)."),
				doc_param("orientation", "int", false, "Orthogonal cell orientation index (default 0)."),
			],
		},
		"gridmap.set_cell_variant": {
			"description": "Paint a cell with one item chosen deterministically by (cell, seed) from a candidate list, the de-repetition primitive so identical neighbours stop forming. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("variants", "Array", true, "JSON array of MeshLibrary item ids to choose among."),
				doc_param("cell", "Vector3", true, "Integer cell coordinate (or --x/--y/--z)."),
				doc_param("seed", "int", false, "Hash seed; same (cell, seed) always picks the same variant (default 0)."),
				doc_param("orientation", "int", false, "Cell orientation index (default 0)."),
			],
		},
		"gridmap.fill": {
			"description": "Fill a box region of cells (--from to --to inclusive) with one item (max 8192 cells). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("from", "Vector3", true, "One corner cell (integer coords)."),
				doc_param("to", "Vector3", false, "Opposite corner cell (default = from)."),
				doc_param("item", "int", false, "Item id to fill with, or -1 to clear (default -1)."),
				doc_param("orientation", "int", false, "Cell orientation index (default 0)."),
			],
		},
		"gridmap.get_cell": {
			"description": "Read a cell's item id, item name, orientation, and whether it's empty.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("cell", "Vector3", true, "Integer cell coordinate (or --x/--y/--z)."),
			],
		},
		"gridmap.clear": {
			"description": "Clear cells: a box region if --from/--to given, else the whole map. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("from", "Vector3", false, "Region start cell (with --to); omit both to clear all."),
				doc_param("to", "Vector3", false, "Region end cell (with --from)."),
			],
		},
		"gridmap.get_used_cells": {
			"description": "List used (non-empty) cells with their item ids; with --item, only cells holding that item.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("item", "int", false, "Filter to cells holding this item id."),
			],
		},
	}
