@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"tilemap.create": _create,
		"tilemap.add_atlas_source": _add_atlas_source,
		"tilemap.add_scenes_source": _add_scenes_source,
		"tilemap.set_cell": _set_cell,
		"tilemap.set_terrain": _set_terrain,
		"tilemap.fill_rect": _fill_rect,
		"tilemap.get_cell": _get_cell,
		"tilemap.clear": _clear,
		"tilemap.get_info": _get_info,
		"tilemap.get_used_cells": _get_used_cells,
	}


# --- Resolution -------------------------------------------------------------

## Resolve params.node_path to a TileMapLayer. Returns [layer, null] or [null, error].
func _resolve_tilemap(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node is TileMapLayer:
		return [node as TileMapLayer, null]
	return [null, error_not_found("TileMapLayer at '%s'" % r[0])]


# --- Commands ---------------------------------------------------------------

func _create(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Node '%s'" % parent_path, "Use scene.tree to see available nodes")

	var tile_size := vec2_param(params, "tile_size", Vector2(64, 64))
	var layer := TileMapLayer.new()
	layer.name = optional_string(params, "name", "TileMapLayer")
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_size)
	layer.tile_set = tile_set

	add_child_with_undo(parent, layer, root, "MCP: Create TileMapLayer")

	return success({
		"name": String(layer.name),
		"node_path": str(root.get_path_to(layer)),
		"tile_size": [tile_set.tile_size.x, tile_set.tile_size.y],
		"created": true,
	})


## Add a TileSetAtlasSource from a texture, creating a tile per grid cell so the
## atlas is paintable immediately (an atlas with no created tiles paints nothing).
func _add_atlas_source(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]
	var rt := require_string(params, "texture")
	if rt[1] != null:
		return rt[1]
	var texture_path: String = rt[0]
	if tilemap.tile_set == null:
		return error_invalid_params("TileMapLayer has no TileSet; create one with tilemap.create")
	if not ResourceLoader.exists(texture_path, "Texture2D"):
		return error_not_found("Texture '%s'" % texture_path)

	var tile_set := tilemap.tile_set
	var source := TileSetAtlasSource.new()
	source.texture = load(texture_path)
	source.texture_region_size = Vector2i(vec2_param(params, "tile_size", Vector2(tile_set.tile_size)))
	source.margins = Vector2i(vec2_param(params, "margins", Vector2.ZERO))
	source.separation = Vector2i(vec2_param(params, "separation", Vector2.ZERO))

	var grid := source.get_atlas_grid_size()
	var tiles_created := 0
	if optional_bool(params, "auto_create_tiles", true):
		for gx in grid.x:
			for gy in grid.y:
				source.create_tile(Vector2i(gx, gy))
				tiles_created += 1

	var source_id := tile_set.get_next_source_id()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add TileSet atlas source")
	undo_redo.add_do_method(tile_set, "add_source", source, source_id)
	undo_redo.add_do_reference(source)
	undo_redo.add_undo_method(tile_set, "remove_source", source_id)
	undo_redo.commit_action()

	return success({
		"source_id": source_id,
		"texture": texture_path,
		"grid_size": [grid.x, grid.y],
		"tiles_created": tiles_created,
		"hint": "Paint with tilemap.set_cell/fill_rect --source-id %d --atlas-x/--atlas-y" % source_id,
	})


## Register PackedScenes as a TileSetScenesCollectionSource (the scene-tile
## blockout workflow: paint whole scenes, e.g. floor/slope prefabs, on the grid).
func _add_scenes_source(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]
	var ra := require_array(params, "scenes")
	if ra[1] != null:
		return ra[1]
	var scene_paths: Array = ra[0]
	if tilemap.tile_set == null:
		return error_invalid_params("TileMapLayer has no TileSet; create one with tilemap.create")

	# Validate every path before mutating anything.
	var packed: Array = []
	for path in scene_paths:
		if not (path is String) or not ResourceLoader.exists(path, "PackedScene"):
			return error_not_found("Scene '%s'" % str(path))
		packed.append(load(path))

	var source := TileSetScenesCollectionSource.new()
	var tiles: Array = []
	for i in packed.size():
		var scene_tile_id: int = source.create_scene_tile(packed[i])
		tiles.append({"scene": scene_paths[i], "alternative": scene_tile_id})

	var tile_set := tilemap.tile_set
	var source_id := tile_set.get_next_source_id()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add TileSet scenes source")
	undo_redo.add_do_method(tile_set, "add_source", source, source_id)
	undo_redo.add_do_reference(source)
	undo_redo.add_undo_method(tile_set, "remove_source", source_id)
	undo_redo.commit_action()

	return success({
		"source_id": source_id,
		"tiles": tiles,
		"hint": "Paint with tilemap.set_cell/fill_rect --source-id %d --alternative <id> (atlas coords stay 0,0)" % source_id,
	})


func _set_cell(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var x := int(params.get("x", 0))
	var y := int(params.get("y", 0))
	var source_id := int(params.get("source_id", 0))
	var atlas_x := int(params.get("atlas_x", 0))
	var atlas_y := int(params.get("atlas_y", 0))
	var alternative := int(params.get("alternative", 0))

	var coords := Vector2i(x, y)
	var old_cells := [_capture_cell(tilemap, coords)]
	var new_cells := [_make_cell(coords, source_id, Vector2i(atlas_x, atlas_y), alternative)]

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set TileMap cell")
	_add_do_set_cells(undo_redo, tilemap, new_cells)
	_add_undo_set_cells(undo_redo, tilemap, old_cells)
	undo_redo.commit_action()

	return success({"x": x, "y": y, "source_id": source_id, "atlas_coords": [atlas_x, atlas_y]})


func _fill_rect(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var x1 := int(params.get("x1", 0))
	var y1 := int(params.get("y1", 0))
	var x2 := int(params.get("x2", 0))
	var y2 := int(params.get("y2", 0))
	var source_id := int(params.get("source_id", 0))
	var atlas_x := int(params.get("atlas_x", 0))
	var atlas_y := int(params.get("atlas_y", 0))
	var alternative := int(params.get("alternative", 0))

	var count := 0
	var old_cells: Array = []
	var new_cells: Array = []
	for cx in range(mini(x1, x2), maxi(x1, x2) + 1):
		for cy in range(mini(y1, y2), maxi(y1, y2) + 1):
			var coords := Vector2i(cx, cy)
			old_cells.append(_capture_cell(tilemap, coords))
			new_cells.append(_make_cell(coords, source_id, Vector2i(atlas_x, atlas_y), alternative))
			count += 1

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Fill TileMap rect")
	_add_do_set_cells(undo_redo, tilemap, new_cells)
	_add_undo_set_cells(undo_redo, tilemap, old_cells)
	undo_redo.commit_action()

	return success({"filled": count, "rect": [x1, y1, x2, y2]})


## Paint cells with a terrain (autotiling): the engine picks tiles whose peering
## bits connect with neighbors. --terrain -1 erases back to empty. This is how
## gameplay ground-painting works (e.g. tilling soil in a farming sim).
func _set_terrain(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]
	var ra := require_array(params, "cells")
	if ra[1] != null:
		return ra[1]
	if tilemap.tile_set == null:
		return error_invalid_params("TileMapLayer has no TileSet")

	var terrain_set := optional_int(params, "terrain_set", 0)
	var terrain := optional_int(params, "terrain", 0)
	if terrain_set < 0 or terrain_set >= tilemap.tile_set.get_terrain_sets_count():
		return error_invalid_params("terrain_set %d out of range (tile set has %d)" % [terrain_set, tilemap.tile_set.get_terrain_sets_count()])

	var cells: Array[Vector2i] = []
	for item in ra[0]:
		if item is Array and item.size() >= 2:
			cells.append(Vector2i(int(item[0]), int(item[1])))
		else:
			return error_invalid_params("cells must be an array of [x, y] pairs")

	var old_cells: Array = []
	for coords in cells:
		old_cells.append(_capture_cell(tilemap, coords))

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Paint TileMap terrain")
	undo_redo.add_do_method(tilemap, "set_cells_terrain_connect", cells, terrain_set, terrain, true)
	_add_undo_set_cells(undo_redo, tilemap, old_cells)
	undo_redo.commit_action()

	return success({
		"painted": cells.size(),
		"terrain_set": terrain_set,
		"terrain": terrain,
	})


func _get_cell(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var x := int(params.get("x", 0))
	var y := int(params.get("y", 0))
	var coords := Vector2i(x, y)

	var source_id := tilemap.get_cell_source_id(coords)
	var atlas_coords := tilemap.get_cell_atlas_coords(coords)
	var alternative := tilemap.get_cell_alternative_tile(coords)

	return success({
		"x": x, "y": y,
		"source_id": source_id,
		"atlas_coords": [atlas_coords.x, atlas_coords.y],
		"alternative": alternative,
		"empty": source_id == -1,
	})


func _clear(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var old_cells: Array = []
	for coords: Vector2i in tilemap.get_used_cells():
		old_cells.append(_capture_cell(tilemap, coords))

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Clear TileMap")
	undo_redo.add_do_method(tilemap, "clear")
	_add_undo_set_cells(undo_redo, tilemap, old_cells)
	undo_redo.commit_action()
	return success({"cleared": true})


func _get_info(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var tile_set := tilemap.tile_set
	var sources: Array = []
	if tile_set:
		for i in tile_set.get_source_count():
			var source_id := tile_set.get_source_id(i)
			var source := tile_set.get_source(source_id)
			var info := {"id": source_id, "type": source.get_class()}
			if source is TileSetAtlasSource:
				var atlas: TileSetAtlasSource = source
				info["texture"] = atlas.texture.resource_path if atlas.texture else ""
				info["tile_count"] = atlas.get_tiles_count()
			elif source is TileSetScenesCollectionSource:
				var scenes_source: TileSetScenesCollectionSource = source
				var scenes: Array = []
				for j in scenes_source.get_scene_tiles_count():
					var scene_tile_id := scenes_source.get_scene_tile_id(j)
					var packed := scenes_source.get_scene_tile_scene(scene_tile_id)
					scenes.append({
						"alternative": scene_tile_id,
						"scene": packed.resource_path if packed else "",
					})
				info["scenes"] = scenes
			sources.append(info)

	var terrain_sets: Array = []
	if tile_set:
		for ts in tile_set.get_terrain_sets_count():
			var terrains: Array = []
			for t in tile_set.get_terrains_count(ts):
				terrains.append({"id": t, "name": tile_set.get_terrain_name(ts, t)})
			terrain_sets.append({"id": ts, "terrains": terrains})

	return success({
		"node_path": str(get_edited_root().get_path_to(tilemap)),
		"used_cells": tilemap.get_used_cells().size(),
		"tile_set_sources": sources,
		"tile_size": [tile_set.tile_size.x, tile_set.tile_size.y] if tile_set else [0, 0],
		"terrain_sets": terrain_sets,
	})


func _get_used_cells(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tilemap(params)
	if ctx[1] != null:
		return ctx[1]
	var tilemap: TileMapLayer = ctx[0]

	var max_count := optional_int(params, "max_count", 500)
	var cells: Array = []
	var used := tilemap.get_used_cells()

	for i in mini(used.size(), max_count):
		var pos: Vector2i = used[i]
		cells.append({"x": pos.x, "y": pos.y, "source_id": tilemap.get_cell_source_id(pos)})

	return success({"cells": cells, "total": used.size(), "returned": cells.size()})


# --- Cell helpers -----------------------------------------------------------

func _make_cell(coords: Vector2i, source_id: int, atlas_coords: Vector2i, alternative: int) -> Dictionary:
	return {
		"coords": coords,
		"source_id": source_id,
		"atlas_coords": atlas_coords,
		"alternative": alternative,
	}


func _capture_cell(tilemap: TileMapLayer, coords: Vector2i) -> Dictionary:
	return _make_cell(
		coords,
		tilemap.get_cell_source_id(coords),
		tilemap.get_cell_atlas_coords(coords),
		tilemap.get_cell_alternative_tile(coords)
	)


func _add_do_set_cells(undo_redo: EditorUndoRedoManager, tilemap: TileMapLayer, cells: Array) -> void:
	for cell: Dictionary in cells:
		undo_redo.add_do_method(tilemap, "set_cell", cell["coords"], cell["source_id"], cell["atlas_coords"], cell["alternative"])


func _add_undo_set_cells(undo_redo: EditorUndoRedoManager, tilemap: TileMapLayer, cells: Array) -> void:
	for cell: Dictionary in cells:
		undo_redo.add_undo_method(tilemap, "set_cell", cell["coords"], cell["source_id"], cell["atlas_coords"], cell["alternative"])


func get_command_docs() -> Dictionary:
	return {
		"tilemap.create": {
			"description": "Add a TileMapLayer (with a fresh empty TileSet) under --parent-path. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add the layer under (default '.')."),
				doc_param("name", "String", false, "Node name (default 'TileMapLayer')."),
				doc_param("tile_size", "Vector2", false, "TileSet tile size in px (default 64x64)."),
			],
		},
		"tilemap.add_atlas_source": {
			"description": "Add a TileSetAtlasSource from a texture to the layer's TileSet, auto-creating a tile per grid cell (an atlas with no created tiles paints nothing). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer (must already have a TileSet)."),
				doc_param("texture", "String", true, "Path to the atlas Texture2D."),
				doc_param("tile_size", "Vector2", false, "Atlas region (tile) size in px (default the TileSet tile size)."),
				doc_param("margins", "Vector2", false, "Atlas margins in px (default 0,0)."),
				doc_param("separation", "Vector2", false, "Atlas separation between tiles in px (default 0,0)."),
				doc_param("auto_create_tiles", "bool", false, "Create a tile for every atlas grid cell (default true)."),
			],
		},
		"tilemap.add_scenes_source": {
			"description": "Register PackedScenes as a TileSetScenesCollectionSource (paint whole scenes as tiles). Undoable. Paint with --alternative <id>; atlas coords stay 0,0.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer (must have a TileSet)."),
				doc_param("scenes", "Array", true, "JSON array of PackedScene paths to register as scene tiles."),
			],
		},
		"tilemap.set_cell": {
			"description": "Paint one cell. Note: --source-id is not validated to exist (a dangling ref paints nothing). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
				doc_param("x", "int", false, "Cell x (default 0)."),
				doc_param("y", "int", false, "Cell y (default 0)."),
				doc_param("source_id", "int", false, "TileSet source id to paint from (default 0)."),
				doc_param("atlas_x", "int", false, "Atlas tile x within the source (default 0)."),
				doc_param("atlas_y", "int", false, "Atlas tile y within the source (default 0)."),
				doc_param("alternative", "int", false, "Alternative tile id (scene-tile id for scenes sources; default 0)."),
			],
		},
		"tilemap.set_terrain": {
			"description": "Paint cells with a terrain (autotiling via peering bits); --terrain -1 erases. Note: a terrain with no island tile places nothing for isolated cells (author terrains in the TileSet editor). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer (must have a TileSet)."),
				doc_param("cells", "Array", true, "JSON array of [x, y] cell coordinates to paint."),
				doc_param("terrain_set", "int", false, "Terrain set index (default 0)."),
				doc_param("terrain", "int", false, "Terrain index within the set (-1 erases; default 0)."),
			],
		},
		"tilemap.fill_rect": {
			"description": "Paint a rectangle of cells from (x1,y1) to (x2,y2) inclusive with one tile. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
				doc_param("x1", "int", false, "Rect corner x1 (default 0)."),
				doc_param("y1", "int", false, "Rect corner y1 (default 0)."),
				doc_param("x2", "int", false, "Rect corner x2 (default 0)."),
				doc_param("y2", "int", false, "Rect corner y2 (default 0)."),
				doc_param("source_id", "int", false, "TileSet source id (default 0)."),
				doc_param("atlas_x", "int", false, "Atlas tile x (default 0)."),
				doc_param("atlas_y", "int", false, "Atlas tile y (default 0)."),
				doc_param("alternative", "int", false, "Alternative tile id (default 0)."),
			],
		},
		"tilemap.get_cell": {
			"description": "Read one cell's source id, atlas coords, and alternative (source_id -1 means empty).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
				doc_param("x", "int", false, "Cell x (default 0)."),
				doc_param("y", "int", false, "Cell y (default 0)."),
			],
		},
		"tilemap.clear": {
			"description": "Clear every painted cell in the layer. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
			],
		},
		"tilemap.get_info": {
			"description": "Report the layer's TileSet: sources (atlas/scenes with tile counts), tile size, terrain sets, and used-cell count.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
			],
		},
		"tilemap.get_used_cells": {
			"description": "List painted cells (x, y, source_id), capped at --max-count.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target TileMapLayer."),
				doc_param("max_count", "int", false, "Max cells returned (default 500)."),
			],
		},
	}
