@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Constraint tile-assembly — the *other* PCG family (the pcg/scatter groups do point-scatter;
## this does handmade-tile assembly driven by constraints, à la Townscaper / Bad North).
##
## Phase A: the DUAL-GRID marching-squares solver (the "fix" from Stålberg's approach).
## Instead of typing whole cells (where shared corners conflict), type the grid's *corners*:
## each main cell reads its 4 corners and picks a module + rotation. For 2 states that's
## 2^4 = 16 corner configs, which collapse under rotation to just 6 canonical tiles — and
## modeling corners *inside* a tile fixes the convex/concave rounded-corner problem for free.
##
## GridMap orientations are the 24 PROPER rotations (no reflections), so canonicalization is
## rotation-only — which is exactly what yields 6 tiles for binary. Mirror folding would emit
## reflected variants GridMap can't place, so it's deliberately omitted.
##
## Corner winding (document this so authored meshes match): a main cell at (cx,cz) on layer y
## owns 4 corners, indexed CCW-from-above:
##   0 = SW (cx,   cz)
##   1 = SE (cx+1, cz)
##   2 = NE (cx+1, cz+1)
##   3 = NW (cx,   cz+1)
## A rotation "step" is +90° about +Y; the solver's orientation = the canonical tile rotated
## `steps` steps to reach the cell's actual config. Author the 6 base meshes in the case_table's
## canonical orientation (steps=0); the solver rotates them.

const INVALID := -1  # GridMap.INVALID_CELL_ITEM
const CORNER_META := "_wfc_corners"  # Dictionary "x,z" -> int state, stored on the GridMap


func get_commands() -> Dictionary:
	return {
		"wfc.case_table": _case_table,
		"wfc.set_corner": _set_corner,
		"wfc.solve_dual": _solve_dual,
		"wfc.rules_from_example": _rules_from_example,
		"wfc.collapse": _collapse,
		"wfc.match_pattern": _match_pattern,
		"wfc.stalberg_grid": _stalberg_grid,
	}


# --- direction helpers (horizontal adjacency on one layer) ------------------
# 0=+X(east) 1=-X(west) 2=+Z(south) 3=-Z(north)

const DIRS: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


func _opposite(dir: int) -> int:
	return [1, 0, 3, 2][dir]


## Resolve a --node-path to a GridMap (or an error). Returns [GridMap, null] | [null, error].
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


# --- canonicalization (pure) ------------------------------------------------

## One 90° rotation of a 4-corner config (cyclic shift, matching the CCW winding above).
func _rotate(t: Array) -> Array:
	return [t[3], t[0], t[1], t[2]]


func _key(t: Array) -> String:
	return ",".join(t.map(func(v): return str(v)))


## Lexicographic compare of two equal-length int arrays: true if a < b.
func _less(a: Array, b: Array) -> bool:
	for i in a.size():
		if int(a[i]) != int(b[i]):
			return int(a[i]) < int(b[i])
	return false


## Build the rotation-canonical case table for `states` states over 4 corners.
## Returns {tiles:[{mask,config_count,label}], mapping:{"a,b,c,d":{tile,steps}}}.
func _build_table(states: int) -> Dictionary:
	var canon: Dictionary = {}  # canonical key -> tile index
	var tiles: Array = []
	var mapping: Dictionary = {}
	for a in states:
		for b in states:
			for c in states:
				for d in states:
					var cfg: Array = [a, b, c, d]
					# canonical = lexicographically smallest rotation
					var best: Array = cfg.duplicate()
					var r: Array = cfg.duplicate()
					for _i in 3:
						r = _rotate(r)
						if _less(r, best):
							best = r.duplicate()
					var bkey := _key(best)
					var tile_idx: int
					if canon.has(bkey):
						tile_idx = canon[bkey]
					else:
						tile_idx = tiles.size()
						canon[bkey] = tile_idx
						tiles.append({"mask": best.duplicate(), "config_count": 0, "label": ""})
					tiles[tile_idx]["config_count"] = int(tiles[tile_idx]["config_count"]) + 1
					# steps to rotate canonical(best) -> cfg
					var steps := 0
					var rr: Array = best.duplicate()
					for k in 4:
						if _key(rr) == _key(cfg):
							steps = k
							break
						rr = _rotate(rr)
					mapping[_key(cfg)] = {"tile": tile_idx, "steps": steps}
	if states == 2:
		for tile: Dictionary in tiles:
			tile["label"] = _binary_label(tile["mask"])
	return {"tiles": tiles, "mapping": mapping}


## Human label for a binary canonical mask (count + arrangement of land corners).
func _binary_label(mask: Array) -> String:
	var n := 0
	for v in mask:
		n += int(v)
	match n:
		0: return "empty"
		4: return "full"
		1: return "outer_corner"  # one land corner — convex
		3: return "inner_corner"  # three land corners — concave
		2:
			# adjacent (edge) vs diagonal (saddle)
			if int(mask[0]) == int(mask[2]):
				return "diagonal"  # opposite corners share a state
			return "edge"
	return "?"


# --- wfc.case_table ---------------------------------------------------------

func _case_table(params: Dictionary) -> Dictionary:
	var states := optional_int(params, "states", 2)
	if states < 2 or states > 6:
		return error_invalid_params("states must be 2..6 (got %d)" % states)
	var table := _build_table(states)
	return success({
		"states": states,
		"corner_order": ["SW", "SE", "NE", "NW"],
		"winding": "CCW-from-above; SW=(cx,cz) SE=(cx+1,cz) NE=(cx+1,cz+1) NW=(cx,cz+1); 1 step = +90° about +Y",
		"tile_count": table["tiles"].size(),
		"tiles": table["tiles"],
		"mapping": table["mapping"],
		"hint": "Author one mesh per tile in its steps=0 orientation, map tile index -> MeshLibrary item id via wfc.solve_dual --rules.",
	})


# --- corner field helpers ---------------------------------------------------

func _corner_param(params: Dictionary, key: String, default: Vector2i) -> Vector2i:
	if params.has(key):
		var v: Variant = params[key]
		if v is String:
			var pv: Variant = PropertyParser.parse_value(v, TYPE_VECTOR2I)
			if pv is Vector2i:
				return pv
			# accept plain "x,z"
			var parts := (v as String).split(",")
			if parts.size() >= 2:
				return Vector2i(int(parts[0]), int(parts[1]))
		if v is Array and (v as Array).size() >= 2:
			return Vector2i(int(v[0]), int(v[1]))
	if params.has("x") or params.has("z"):
		return Vector2i(optional_int(params, "x", default.x), optional_int(params, "z", default.y))
	return default


func _read_corners(gm: GridMap) -> Dictionary:
	if gm.has_meta(CORNER_META):
		var m: Variant = gm.get_meta(CORNER_META)
		if m is Dictionary:
			return (m as Dictionary).duplicate()
	return {}


func _ck(c: Vector2i) -> String:
	return "%d,%d" % [c.x, c.y]


## Map a "state" param: int directly, or land/water/empty words.
func _state_param(params: Dictionary) -> int:
	if params.has("state"):
		return int(params["state"])
	if params.has("type"):
		var t := String(params["type"]).to_lower()
		if t in ["land", "solid", "filled", "1"]:
			return 1
		if t in ["water", "empty", "air", "0"]:
			return 0
		return int(params["type"]) if t.is_valid_int() else 1
	return 1


# --- wfc.set_corner ---------------------------------------------------------

## Paint a corner-type field onto the GridMap (stored as node metadata so it persists
## with the scene and can be edited incrementally, like the video's click-to-toggle).
## Single corner via --corner/--x/--z, or a rectangle via --from/--to (corner coords).
func _set_corner(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not node is GridMap:
		return error_invalid_params("Node '%s' is not a GridMap (is %s)" % [rn[0], node.get_class()])
	var gm := node as GridMap

	var state := _state_param(params)
	if state < 0:
		return error_invalid_params("state must be >= 0")

	var corners := _read_corners(gm)
	var changed: Array = []
	if params.has("from") or params.has("to"):
		var from := _corner_param(params, "from", Vector2i.ZERO)
		var to := _corner_param(params, "to", from)
		var lo := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
		var hi := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
		var count := (hi.x - lo.x + 1) * (hi.y - lo.y + 1)
		if count > 65536:
			return error_invalid_params("Region too large (%d corners, max 65536)" % count)
		for cx in range(lo.x, hi.x + 1):
			for cz in range(lo.y, hi.y + 1):
				corners[_ck(Vector2i(cx, cz))] = state
		changed.append(str(lo))
		changed.append(str(hi))
	else:
		var c := _corner_param(params, "corner", Vector2i.ZERO)
		corners[_ck(c)] = state
		changed.append(str(c))

	var old: Variant = gm.get_meta(CORNER_META) if gm.has_meta(CORNER_META) else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Paint %d WFC corner(s)" % (corners.size()))
	undo_redo.add_do_method(gm, "set_meta", CORNER_META, corners)
	if old == null:
		undo_redo.add_undo_method(gm, "remove_meta", CORNER_META)
	else:
		undo_redo.add_undo_method(gm, "set_meta", CORNER_META, old)
	undo_redo.commit_action()

	# Bounds of the field (for the agent to feed solve_dual).
	var bounds := _field_bounds(corners)
	return success({
		"node_path": rn[0],
		"state": state,
		"changed": changed,
		"corner_count": corners.size(),
		"field_min": str(bounds[0]),
		"field_max": str(bounds[1]),
	})


func _field_bounds(corners: Dictionary) -> Array:
	var lo := Vector2i(2147483647, 2147483647)
	var hi := Vector2i(-2147483648, -2147483648)
	for k: String in corners:
		var p := k.split(",")
		var c := Vector2i(int(p[0]), int(p[1]))
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	if corners.is_empty():
		return [Vector2i.ZERO, Vector2i.ZERO]
	return [lo, hi]


# --- wfc.solve_dual ---------------------------------------------------------

## Read the corner field (metadata, or inline --corners), and for each main cell pick the
## canonical tile + rotation from its 4-corner config, writing set_cell_item on the GridMap.
func _solve_dual(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not node is GridMap:
		return error_invalid_params("Node '%s' is not a GridMap (is %s)" % [rn[0], node.get_class()])
	var gm := node as GridMap

	var states := optional_int(params, "states", 2)
	if states < 2 or states > 6:
		return error_invalid_params("states must be 2..6")

	# rules: tile index -> MeshLibrary item id (use -1 / omit for "place nothing").
	var rd := require_dict(params, "rules")
	if rd[1] != null:
		return rd[1]
	var rules: Dictionary = rd[0]

	# corner field: inline --corners overrides stored metadata.
	var corners: Dictionary
	if params.has("corners"):
		var cd := require_dict(params, "corners")
		if cd[1] != null:
			return cd[1]
		corners = cd[0]
	else:
		corners = _read_corners(gm)
	if corners.is_empty():
		return error(-32000, "No corner field. Paint corners with wfc.set_corner, or pass --corners.")

	var layer := optional_int(params, "layer", 0)
	var seed := optional_int(params, "seed", 0)
	var cw := optional_bool(params, "cw", false)  # rotation direction for orientation
	var table := _build_table(states)
	var mapping: Dictionary = table["mapping"]

	var bounds := _field_bounds(corners)
	var lo: Vector2i = bounds[0]
	var hi: Vector2i = bounds[1]

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: WFC dual-solve %s" % gm.name)

	if optional_bool(params, "clear", false):
		for pos: Vector3i in gm.get_used_cells():
			if pos.y == layer:
				undo_redo.add_do_method(gm, "set_cell_item", pos, INVALID, 0)
				undo_redo.add_undo_method(gm, "set_cell_item", pos, gm.get_cell_item(pos), gm.get_cell_item_orientation(pos))

	var per_tile: Dictionary = {}
	var cells_set := 0
	var skipped := 0
	var out_of_range := 0
	# main cells span [lo .. hi-1] in each axis (a cell needs its +x,+z corners).
	for cx in range(lo.x, hi.x):
		for cz in range(lo.y, hi.y):
			var sw := int(corners.get(_ck(Vector2i(cx, cz)), 0))
			var se := int(corners.get(_ck(Vector2i(cx + 1, cz)), 0))
			var ne := int(corners.get(_ck(Vector2i(cx + 1, cz + 1)), 0))
			var nw := int(corners.get(_ck(Vector2i(cx, cz + 1)), 0))
			var cfg := [sw, se, ne, nw]
			var mkey := _key(cfg)
			if not mapping.has(mkey):
				# A corner was painted with a state >= `states`; its config has no table
				# entry. Skip (can't return here — the undo action is already open).
				out_of_range += 1
				continue
			var entry: Dictionary = mapping[mkey]
			var tile: int = entry["tile"]
			var steps: int = entry["steps"]
			var pos := Vector3i(cx, layer, cz)
			# rules maps tile index (string/int key) -> item id, OR an array of item
			# variants (one is picked per cell by seed for de-repetition).
			var item := _rule_item(rules, tile, pos, seed)
			var orient := 0
			if item != INVALID:
				var ang := deg_to_rad(90.0 * steps * (-1.0 if cw else 1.0))
				orient = gm.get_orthogonal_index_from_basis(Basis(Vector3.UP, ang))
			undo_redo.add_do_method(gm, "set_cell_item", pos, item, orient)
			undo_redo.add_undo_method(gm, "set_cell_item", pos, gm.get_cell_item(pos), gm.get_cell_item_orientation(pos))
			if item == INVALID:
				skipped += 1
			else:
				cells_set += 1
				per_tile[str(tile)] = int(per_tile.get(str(tile), 0)) + 1
	undo_redo.commit_action()

	return success({
		"node_path": rn[0],
		"states": states,
		"layer": layer,
		"region_min": str(lo),
		"region_max": str(hi),
		"cells_set": cells_set,
		"cells_skipped_empty": skipped,
		"cells_out_of_range": out_of_range,
		"per_tile": per_tile,
		"tile_count": table["tiles"].size(),
	})


## Deterministic spatial hash → variant index (same recipe as gridmap.set_cell_variant).
static func _variant_index(cell: Vector3i, seed: int, n: int) -> int:
	if n <= 1:
		return 0
	var h := (cell.x * 73856093) ^ (cell.y * 19349663) ^ (cell.z * 83492791) ^ (seed * 2654435761)
	return ((h % n) + n) % n


func _rule_item(rules: Dictionary, tile: int, cell: Vector3i, seed: int) -> int:
	var v: Variant = null
	if rules.has(str(tile)):
		v = rules[str(tile)]
	elif rules.has(tile):
		v = rules[tile]
	if v == null:
		return INVALID
	# Array of variant item ids → pick one per cell by seed (de-repetition).
	if v is Array:
		var arr: Array = v
		if arr.is_empty():
			return INVALID
		return int(arr[_variant_index(cell, seed, arr.size())])
	return int(v)


# --- wfc.rules_from_example -------------------------------------------------

## Learn adjacency rules + tile weights by scanning an authored example GridMap: for every
## pair of horizontally-adjacent placed cells, record "item A may sit <dir> of item B". The
## "simple tiled model" — author a small hand-built example, get the constraints for free.
## (v1: orientation-agnostic — each MeshLibrary item id is one tile; empties aren't a tile.)
func _rules_from_example(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]
	var has_layer := params.has("layer")
	var layer := optional_int(params, "layer", 0)

	var adjacency := {0: {}, 1: {}, 2: {}, 3: {}}  # dir -> item -> {neighbor:true}
	var weights := {}
	var tileset := {}
	var pair_count := 0
	for cell: Vector3i in gm.get_used_cells():
		if has_layer and cell.y != layer:
			continue
		var item := gm.get_cell_item(cell)
		weights[item] = int(weights.get(item, 0)) + 1
		tileset[item] = true
		for di in DIRS.size():
			var n: Vector3i = cell + DIRS[di]
			if has_layer and n.y != layer:
				continue
			var ni := gm.get_cell_item(n)
			if ni == INVALID:
				continue
			if not adjacency[di].has(item):
				adjacency[di][item] = {}
			adjacency[di][item][ni] = true
			pair_count += 1

	if tileset.is_empty():
		return error(-32000, "Example GridMap has no placed cells to learn from")

	# Serialize: {dir_str: {item_str: [neighbors]}}
	var adj_out := {}
	for di in 4:
		var dd := {}
		for item: int in adjacency[di]:
			dd[str(item)] = adjacency[di][item].keys()
		adj_out[str(di)] = dd
	var w_out := {}
	for item: int in weights:
		w_out[str(item)] = weights[item]
	var rules := {"tiles": tileset.keys(), "weights": w_out, "adjacency": adj_out}

	var out := {
		"tiles": tileset.keys(),
		"tile_count": tileset.size(),
		"adjacency_pairs": pair_count,
		"weights": w_out,
		"rules": rules,
	}
	# Optionally persist to a .json the agent can feed to wfc.collapse --rules-path.
	if params.has("output_path"):
		var op := String(params["output_path"])
		var guard := guard_project_path(op)
		if not guard.is_empty():
			return guard
		if not op.ends_with(".json"):
			return error_invalid_params("output_path must end in .json")
		var f := FileAccess.open(op, FileAccess.WRITE)
		if f == null:
			return error_internal("Cannot write '%s': %s" % [op, error_string(FileAccess.get_open_error())])
		f.store_string(JSON.stringify(rules, "  "))
		f.close()
		EditorInterface.get_resource_filesystem().update_file(op)
		out["output_path"] = op
	return success(out)


# --- wfc.collapse (Wave Function Collapse / Model Synthesis) -----------------

## Fill a GridMap region by constraint propagation: every cell starts in superposition of all
## tiles; repeatedly collapse the lowest-entropy cell (weighted-random by seed) and propagate
## the adjacency constraints, until all cells are decided or a contradiction forces a restart.
func _collapse(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]

	# rules: inline --rules, or load --rules-path JSON.
	var rules: Dictionary
	if params.has("rules_path"):
		var rp := String(params["rules_path"])
		if not ResourceLoader.exists(rp) and not FileAccess.file_exists(rp):
			return error_not_found("Rules file '%s'" % rp)
		var f := FileAccess.open(rp, FileAccess.READ)
		if f == null:
			return error_internal("Cannot read '%s'" % rp)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not parsed is Dictionary:
			return error_invalid_params("Rules file is not a JSON object")
		rules = parsed
	else:
		var rd := require_dict(params, "rules")
		if rd[1] != null:
			return rd[1]
		rules = rd[0]
	if not rules.has("adjacency") or not rules.has("tiles"):
		return error_invalid_params("rules must have 'tiles' and 'adjacency' (use wfc.rules_from_example)")

	var tiles: Array = []
	for t in rules["tiles"]:
		tiles.append(int(t))
	if tiles.is_empty():
		return error_invalid_params("rules.tiles is empty")
	var weights := {}
	if rules.has("weights"):
		for k in rules["weights"]:
			weights[int(k)] = float(rules["weights"][k])
	# adj[dir][item] -> {neighbor:true}
	var adj := {0: {}, 1: {}, 2: {}, 3: {}}
	for ds in rules["adjacency"]:
		var di := int(ds)
		for items in rules["adjacency"][ds]:
			var iset := {}
			for n in rules["adjacency"][ds][items]:
				iset[int(n)] = true
			adj[di][int(items)] = iset

	var from := _v3i(params, "from", Vector3i.ZERO)
	var to := _v3i(params, "to", from)
	var layer := from.y
	if to.y != from.y:
		return error_invalid_params("collapse is single-layer: from.y must equal to.y (got %d, %d)" % [from.y, to.y])
	var lo := Vector3i(mini(from.x, to.x), layer, mini(from.z, to.z))
	var hi := Vector3i(maxi(from.x, to.x), layer, maxi(from.z, to.z))
	var w := hi.x - lo.x + 1
	var h := hi.z - lo.z + 1
	if w * h > 16384:
		return error_invalid_params("Region too large (%d cells, max 16384)" % (w * h))

	# Fixed constraints: explicit --fixed {"x,z":item}, plus existing in-tileset cells.
	var fixed := {}
	var tile_has := {}
	for t: int in tiles:
		tile_has[t] = true
	if optional_bool(params, "respect_existing", true):
		for x in range(lo.x, hi.x + 1):
			for z in range(lo.z, hi.z + 1):
				var it := gm.get_cell_item(Vector3i(x, layer, z))
				if it != INVALID and tile_has.has(it):
					fixed["%d,%d" % [x, z]] = it
	if params.has("fixed"):
		var fd := require_dict(params, "fixed")
		if fd[1] != null:
			return fd[1]  # surface a malformed --fixed instead of silently ignoring it
		for k in fd[0]:
			fixed[String(k)] = int(fd[0][k])

	var seed := optional_int(params, "seed", 0)
	var max_retries := optional_int(params, "max_retries", 12)

	var attempt := 0
	var result: Dictionary
	while attempt < max_retries:
		result = _run_wfc(tiles, weights, adj, lo, hi, fixed, seed + attempt * 7919)
		if result.get("ok", false):
			break
		attempt += 1
	if not result.get("ok", false):
		return error(-32000, "WFC hit a contradiction after %d attempts at %s — the example may lack a consistent tiling, or the region/fixed set is over-constrained." % [max_retries, result.get("at", "?")],
			{"attempts": max_retries, "contradiction_at": result.get("at", "")})

	# Write the collapsed grid (undoable).
	var grid: Dictionary = result["grid"]  # "x,z" -> item
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: WFC collapse %s" % gm.name)
	var per_tile := {}
	for key: String in grid:
		var p := key.split(",")
		var pos := Vector3i(int(p[0]), layer, int(p[1]))
		var item: int = grid[key]
		undo_redo.add_do_method(gm, "set_cell_item", pos, item, 0)
		undo_redo.add_undo_method(gm, "set_cell_item", pos, gm.get_cell_item(pos), gm.get_cell_item_orientation(pos))
		per_tile[str(item)] = int(per_tile.get(str(item), 0)) + 1
	undo_redo.commit_action()

	return success({
		"node_path": params["node_path"],
		"region_min": str(lo),
		"region_max": str(hi),
		"layer": layer,
		"cells": w * h,
		"attempts": attempt + 1,
		"fixed_count": fixed.size(),
		"per_tile": per_tile,
	})


## One WFC attempt. Returns {ok:true, grid:{"x,z":item}} or {ok:false, at:"x,z"}.
func _run_wfc(tiles: Array, weights: Dictionary, adj: Dictionary, lo: Vector3i, hi: Vector3i, fixed: Dictionary, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var poss := {}  # "x,z" -> {item:true}
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.z, hi.z + 1):
			var key := "%d,%d" % [x, z]
			if fixed.has(key):
				poss[key] = {int(fixed[key]): true}
			else:
				var s := {}
				for t: int in tiles:
					s[t] = true
				poss[key] = s

	# Propagate initial constraints from every fixed/seeded cell.
	var queue: Array = fixed.keys()
	if not _propagate(poss, adj, lo, hi, queue):
		return {"ok": false, "at": "initial"}

	while true:
		# lowest-entropy uncollapsed cell (option count + tiny noise tiebreak)
		var best_key := ""
		var best_score := INF
		for key: String in poss:
			var sz: int = poss[key].size()
			if sz <= 1:
				continue
			var score := float(sz) + rng.randf() * 0.4
			if score < best_score:
				best_score = score
				best_key = key
		if best_key == "":
			break  # all collapsed
		# collapse weighted-random
		var opts: Array = poss[best_key].keys()
		var chosen := _weighted_pick(opts, weights, rng)
		poss[best_key] = {chosen: true}
		if not _propagate(poss, adj, lo, hi, [best_key]):
			return {"ok": false, "at": best_key}

	var grid := {}
	for key: String in poss:
		grid[key] = (poss[key] as Dictionary).keys()[0]
	return {"ok": true, "grid": grid}


func _propagate(poss: Dictionary, adj: Dictionary, lo: Vector3i, hi: Vector3i, start: Array) -> bool:
	var stack: Array = start.duplicate()
	while not stack.is_empty():
		var key: String = stack.pop_back()
		var p := key.split(",")
		var cell := Vector3i(int(p[0]), lo.y, int(p[1]))
		for di in DIRS.size():
			var n: Vector3i = cell + DIRS[di]
			if n.x < lo.x or n.x > hi.x or n.z < lo.z or n.z > hi.z:
				continue
			var nkey := "%d,%d" % [n.x, n.z]
			# allowed neighbor items = union over current options of adj[di][option]
			var allowed := {}
			for s: int in poss[key]:
				var a: Variant = adj[di].get(s, null)
				if a != null:
					for nb in a:
						allowed[nb] = true
			# intersect neighbor's set with allowed
			var nset: Dictionary = poss[nkey]
			var changed := false
			for nb in nset.keys():
				if not allowed.has(nb):
					nset.erase(nb)
					changed = true
			if nset.is_empty():
				return false
			if changed:
				stack.push_back(nkey)
	return true


func _weighted_pick(items: Array, weights: Dictionary, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for it: int in items:
		total += float(weights.get(it, 1.0))
	var r := rng.randf() * total
	for it: int in items:
		r -= float(weights.get(it, 1.0))
		if r <= 0.0:
			return it
	return int(items[items.size() - 1])


# --- wfc.match_pattern (multi-tile special pieces) --------------------------

## Rotate a 2D (dx,dz) offset by k * 90° about +Y (CCW): (x,z) -> (-z, x).
func _rot_off(o: Vector2i, k: int) -> Vector2i:
	var r := o
	for _i in k:
		r = Vector2i(-r.y, r.x)
	return r


func _parse_offset_map(d: Dictionary) -> Dictionary:
	# {"dx,dz": item} -> {Vector2i: int}
	var out := {}
	for k in d:
		var p := String(k).split(",")
		if p.size() >= 2:
			out[Vector2i(int(p[0]), int(p[1]))] = int(d[k])
	return out


## Scan the GridMap for a multi-cell pattern and swap each match for a special piece — the
## Townscaper moment ("4 grass cells touching → a fountain"). The pattern's origin is tried at
## every placed cell (and, by default, in all 4 rotations); on a match the `replace` cells are
## written. Matched/replaced cells are consumed so pieces never overlap.
##   --pattern '{"match":{"0,0":5,"1,0":5,"0,1":5,"1,1":5}, "replace":{"0,0":10,"1,0":-1,"0,1":-1,"1,1":-1}}'
## In `match`, item -1 means "require empty". In `replace`, item -1 clears the cell.
func _match_pattern(params: Dictionary) -> Dictionary:
	var ctx := _resolve_gridmap(params)
	if ctx[1] != null:
		return ctx[1]
	var gm: GridMap = ctx[0]

	var pd := require_dict(params, "pattern")
	if pd[1] != null:
		return pd[1]
	var pattern: Dictionary = pd[0]
	if not pattern.has("match") or not pattern.has("replace"):
		return error_invalid_params("pattern needs 'match' and 'replace' offset maps")
	if not (pattern["match"] is Dictionary) or not (pattern["replace"] is Dictionary):
		return error_invalid_params("pattern.match / pattern.replace must be objects {\"dx,dz\": item}")
	var match_map := _parse_offset_map(pattern["match"])
	var replace_map := _parse_offset_map(pattern["replace"])
	if match_map.is_empty():
		return error_invalid_params("pattern.match is empty")

	var layer := optional_int(params, "layer", 0)
	var rotate := optional_bool(params, "rotate", true)
	var limit := optional_int(params, "limit", 100000)
	var rotations := [0, 1, 2, 3] if rotate else [0]

	# deterministic anchor order
	var anchors: Array = []
	for cell: Vector3i in gm.get_used_cells():
		if cell.y == layer:
			anchors.append(cell)
	anchors.sort_custom(func(a, b): return a.x < b.x if a.x != b.x else a.z < b.z)

	var consumed := {}  # "x,z" -> true
	var placements: Array = []
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: WFC match_pattern on %s" % gm.name)

	for anchor: Vector3i in anchors:
		if placements.size() >= limit:
			break
		for k: int in rotations:
			# test the match under rotation k
			var ok := true
			for off: Vector2i in match_map:
				var ro := _rot_off(off, k)
				var ckey := "%d,%d" % [anchor.x + ro.x, anchor.z + ro.y]
				if consumed.has(ckey):
					ok = false
					break
				var cell := Vector3i(anchor.x + ro.x, layer, anchor.z + ro.y)
				var want: int = match_map[off]
				var actual := gm.get_cell_item(cell)
				if want == INVALID:
					if actual != INVALID:
						ok = false
						break
				elif actual != want:
					ok = false
					break
			if not ok:
				continue
			# apply the replacement, orienting directional pieces by the rotation
			var orient := gm.get_orthogonal_index_from_basis(Basis(Vector3.UP, deg_to_rad(90.0 * k)))
			for off: Vector2i in match_map:
				var ro := _rot_off(off, k)
				consumed["%d,%d" % [anchor.x + ro.x, anchor.z + ro.y]] = true
			for off: Vector2i in replace_map:
				var ro := _rot_off(off, k)
				var cell := Vector3i(anchor.x + ro.x, layer, anchor.z + ro.y)
				var item: int = replace_map[off]
				var o := orient if item != INVALID else 0
				undo_redo.add_do_method(gm, "set_cell_item", cell, item, o)
				undo_redo.add_undo_method(gm, "set_cell_item", cell, gm.get_cell_item(cell), gm.get_cell_item_orientation(cell))
				consumed["%d,%d" % [cell.x, cell.z]] = true
			placements.append({"anchor": str(anchor), "rotation": k})
			break  # one placement per anchor
	undo_redo.commit_action()

	return success({
		"node_path": params["node_path"],
		"layer": layer,
		"placements": placements.size(),
		"cells_consumed": consumed.size(),
		"matched": placements,
	})


func _v3i(params: Dictionary, key: String, default: Vector3i) -> Vector3i:
	if params.has(key):
		var v: Variant = params[key]
		if v is String:
			var pv: Variant = PropertyParser.parse_value(v, TYPE_VECTOR3I)
			if pv is Vector3i:
				return pv
		if v is Array and (v as Array).size() >= 3:
			return Vector3i(int(v[0]), int(v[1]), int(v[2]))
	return default


# --- wfc.stalberg_grid (irregular all-quad grid) ----------------------------

## Point registry: dedup by rounded XZ so shared vertices connect for edges/relaxation.
func _reg(pts: Array, pidx: Dictionary, p: Vector3) -> int:
	var key := "%.3f,%.3f" % [p.x, p.z]
	if pidx.has(key):
		return pidx[key]
	var i := pts.size()
	pts.append(p)
	pidx[key] = i
	return i


func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = t


## Generate Stålberg's irregular all-quad grid: jittered triangular lattice → randomly merge
## adjacent triangle pairs into quads (leftovers split into 3 quads) → subdivide every quad into
## 4 (guarantees all-quad) → relax interior points. The organic non-grid look that still tiles.
## Returns the quads as corner-position lists; optionally drops Marker3D nodes at quad centers.
func _stalberg_grid(params: Dictionary) -> Dictionary:
	var w := optional_int(params, "width", 6)
	var d := optional_int(params, "depth", 6)
	if w < 1 or d < 1 or w * d > 4096:
		return error_invalid_params("width/depth must be >=1 and width*depth <= 4096")
	var spacing := float(params.get("spacing", 1.0))
	var jitter := float(params.get("jitter", 0.28)) * spacing
	var relax_iter := optional_int(params, "relax_iterations", 12)
	var rng := RandomNumberGenerator.new()
	rng.seed = optional_int(params, "seed", 0)

	var pts: Array = []
	var pidx := {}

	# --- jittered base lattice (interior points pushed off-grid for irregularity) ---
	var gi: Array = []  # gi[r][c] -> point index
	for r in range(d + 1):
		var row: Array = []
		for c in range(w + 1):
			var base := Vector3(c * spacing, 0.0, r * spacing)
			var interior := r > 0 and r < d and c > 0 and c < w
			if interior and jitter > 0.0:
				base += Vector3(rng.randf_range(-jitter, jitter), 0.0, rng.randf_range(-jitter, jitter))
			row.append(_reg(pts, pidx, base))
		gi.append(row)

	# --- triangulate each square with a random diagonal ---
	var tris: Array = []  # each [i,j,k]
	for r in range(d):
		for c in range(w):
			var a: int = gi[r][c]
			var b: int = gi[r][c + 1]
			var e: int = gi[r + 1][c + 1]
			var f: int = gi[r + 1][c]
			if rng.randf() < 0.5:
				tris.append([a, b, e])
				tris.append([a, e, f])
			else:
				tris.append([a, b, f])
				tris.append([b, e, f])

	# --- triangle adjacency by shared edge ---
	var edge_map := {}  # "min,max" -> [tri indices]
	for ti in tris.size():
		var t: Array = tris[ti]
		for k in 3:
			var i0: int = t[k]
			var i1: int = t[(k + 1) % 3]
			var ek := "%d,%d" % [mini(i0, i1), maxi(i0, i1)]
			if not edge_map.has(ek):
				edge_map[ek] = []
			edge_map[ek].append(ti)

	# --- random greedy matching of triangle pairs into quads ---
	var order: Array = range(tris.size())
	_shuffle(order, rng)
	var matched := {}
	var quads: Array = []  # each [4 point indices]
	for ti: int in order:
		if matched.has(ti):
			continue
		var t: Array = tris[ti]
		var partner := -1
		var shared: Array = []
		for k in 3:
			var i0: int = t[k]
			var i1: int = t[(k + 1) % 3]
			var ek := "%d,%d" % [mini(i0, i1), maxi(i0, i1)]
			for tj: int in edge_map[ek]:
				if tj != ti and not matched.has(tj):
					partner = tj
					shared = [i0, i1]
					break
			if partner >= 0:
				break
		if partner >= 0:
			matched[ti] = true
			matched[partner] = true
			var apex_i: int = _third(t, shared)
			var apex_j: int = _third(tris[partner], shared)
			quads.append([shared[0], apex_i, shared[1], apex_j])
		else:
			# leftover triangle → split into 3 quads (centroid + edge mids)
			matched[ti] = true
			var pa: Vector3 = pts[t[0]]
			var pb: Vector3 = pts[t[1]]
			var pc: Vector3 = pts[t[2]]
			var g := _reg(pts, pidx, (pa + pb + pc) / 3.0)
			var mab := _reg(pts, pidx, (pa + pb) * 0.5)
			var mbc := _reg(pts, pidx, (pb + pc) * 0.5)
			var mca := _reg(pts, pidx, (pc + pa) * 0.5)
			quads.append([t[0], mab, g, mca])
			quads.append([t[1], mbc, g, mab])
			quads.append([t[2], mca, g, mbc])

	# --- subdivide every quad into 4 (guarantees all-quad output) ---
	var fine: Array = []
	for q: Array in quads:
		var c0: Vector3 = pts[q[0]]
		var c1: Vector3 = pts[q[1]]
		var c2: Vector3 = pts[q[2]]
		var c3: Vector3 = pts[q[3]]
		var e01 := _reg(pts, pidx, (c0 + c1) * 0.5)
		var e12 := _reg(pts, pidx, (c1 + c2) * 0.5)
		var e23 := _reg(pts, pidx, (c2 + c3) * 0.5)
		var e30 := _reg(pts, pidx, (c3 + c0) * 0.5)
		var g := _reg(pts, pidx, (c0 + c1 + c2 + c3) * 0.25)
		fine.append([q[0], e01, g, e30])
		fine.append([e01, q[1], e12, g])
		fine.append([g, e12, q[2], e23])
		fine.append([e30, g, e23, q[3]])

	# --- relax interior points (boundary on the outer rectangle stays fixed) ---
	var nbr: Array = []
	for _i in pts.size():
		nbr.append({})
	for q: Array in fine:
		for k in 4:
			var i0: int = q[k]
			var i1: int = q[(k + 1) % 4]
			nbr[i0][i1] = true
			nbr[i1][i0] = true
	var max_x := w * spacing
	var max_z := d * spacing
	var eps := 0.001
	var fixed := {}
	for i in pts.size():
		var p: Vector3 = pts[i]
		if p.x <= eps or p.x >= max_x - eps or p.z <= eps or p.z >= max_z - eps:
			fixed[i] = true
	for _it in relax_iter:
		var next: Array = pts.duplicate()
		for i in pts.size():
			if fixed.has(i) or nbr[i].is_empty():
				continue
			var mean := Vector3.ZERO
			for n in nbr[i]:
				mean += pts[n]
			mean /= float(nbr[i].size())
			next[i] = pts[i].lerp(mean, 0.5)
		pts = next

	# --- output: quad corner positions, offset by --origin ---
	var origin := _v3p(params, "origin", Vector3.ZERO)
	var out_quads: Array = []
	for q: Array in fine:
		var corners: Array = []
		for k in 4:
			corners.append(str(pts[q[k]] + origin))
		out_quads.append(corners)

	# optional: drop Marker3D nodes at quad centres so the agent can see the layout
	var emitted := 0
	if optional_string(params, "emit", "") == "markers":
		var root := get_edited_root()
		if root == null:
			return error_no_scene()
		var parent := root
		if params.has("parent"):
			var pn := find_node_by_path(str(params["parent"]))
			if pn != null:
				parent = pn
		var container := Node3D.new()
		container.name = optional_string(params, "name", "StalbergGrid")
		var undo_redo := get_undo_redo()
		undo_redo.create_action("MCP: Stalberg grid markers")
		undo_redo.add_do_method(parent, "add_child", container)
		undo_redo.add_do_method(container, "set_owner", root)
		undo_redo.add_do_reference(container)
		undo_redo.add_undo_method(parent, "remove_child", container)
		undo_redo.commit_action()
		for q: Array in fine:
			var center: Vector3 = (pts[q[0]] + pts[q[1]] + pts[q[2]] + pts[q[3]]) * 0.25 + origin
			var m := Marker3D.new()
			container.add_child(m)
			m.owner = root
			m.position = center
			emitted += 1

	return success({
		"width": w,
		"depth": d,
		"point_count": pts.size(),
		"quad_count": out_quads.size(),
		"all_quad": true,
		"relax_iterations": relax_iter,
		"markers_emitted": emitted,
		"quads": out_quads if optional_bool(params, "return_quads", true) else [],
	})


## The vertex of triangle `t` not on the shared `edge` [a,b].
func _third(t: Array, edge: Array) -> int:
	for v: int in t:
		if v != edge[0] and v != edge[1]:
			return v
	return t[0]


func _v3p(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


func get_command_docs() -> Dictionary:
	return {
		"wfc.case_table": {
			"description": "Compute the dual-grid marching-squares case table for --states states over 4 corners: the rotation-canonical tiles (binary yields 6) and the config->tile+rotation mapping. Author one mesh per tile in its steps=0 orientation.",
			"params": [
				doc_param("states", "int", false, "Number of corner states, 2..6 (default 2 = binary)."),
			],
		},
		"wfc.set_corner": {
			"description": "Paint the dual-grid corner-state field onto a GridMap (stored as node metadata, editable incrementally). Single corner via --corner/--x/--z, or a rectangle via --from/--to. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("state", "int", false, "Corner state to paint (default 1). Use this OR --type."),
				doc_param("type", "String", false, "Named state: land/solid/filled/1 -> 1, water/empty/air/0 -> 0. Use instead of --state."),
				doc_param("corner", "Vector2", false, "Single corner (x,z) to paint. Use with a single corner, not --from/--to."),
				doc_param("x", "int", false, "Corner x (alternative to --corner)."),
				doc_param("z", "int", false, "Corner z (alternative to --corner)."),
				doc_param("from", "Vector2", false, "Rectangle start corner (x,z); pair with --to. Use instead of --corner."),
				doc_param("to", "Vector2", false, "Rectangle end corner (x,z); pair with --from."),
			],
		},
		"wfc.solve_dual": {
			"description": "Read the corner field and, for each main cell, pick the canonical tile + rotation from its 4-corner config, writing it to the GridMap. Canonicalization is rotation-only (GridMap's 24 proper rotations). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap (also the corner-field store)."),
				doc_param("rules", "Dictionary", true, "Map tile index -> MeshLibrary item id (or an array of item variants picked per-cell by seed; -1/omit places nothing)."),
				doc_param("states", "int", false, "Number of corner states, 2..6 (default 2)."),
				doc_param("corners", "Dictionary", false, "Inline corner field {\"x,z\": state}, overriding the stored metadata."),
				doc_param("layer", "int", false, "GridMap Y layer to write (default 0)."),
				doc_param("seed", "int", false, "Seed for variant selection (default 0)."),
				doc_param("cw", "bool", false, "Rotate orientation clockwise instead of CCW (default false)."),
				doc_param("clear", "bool", false, "Clear existing cells on the layer first (default false)."),
			],
		},
		"wfc.rules_from_example": {
			"description": "Learn adjacency rules + tile weights from an authored GridMap (the simple tiled model): for each horizontally-adjacent placed pair, record which item may sit in each direction. Feeds wfc.collapse.",
			"params": [
				doc_param("node_path", "NodePath", true, "Example GridMap to learn from."),
				doc_param("layer", "int", false, "Restrict learning to this Y layer (default: all layers)."),
				doc_param("output_path", "String", false, "Also write the rules to this .json (for wfc.collapse --rules-path)."),
			],
		},
		"wfc.collapse": {
			"description": "Fill a GridMap region by Wave Function Collapse: collapse the lowest-entropy cell (weighted-random by seed) and propagate adjacency until solved or a contradiction retries. Single-layer. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("rules", "Dictionary", false, "Inline rules {tiles, weights, adjacency}. Use this OR --rules-path."),
				doc_param("rules_path", "String", false, "Path to a rules JSON (from wfc.rules_from_example). Use instead of --rules."),
				doc_param("from", "Vector3", false, "Region start cell (x,y,z); y is the layer (default 0,0,0)."),
				doc_param("to", "Vector3", false, "Region end cell; its y must equal from.y (single layer)."),
				doc_param("respect_existing", "bool", false, "Pin already-placed in-tileset cells as fixed (default true)."),
				doc_param("fixed", "Dictionary", false, "Explicit fixed cells {\"x,z\": item}."),
				doc_param("seed", "int", false, "RNG seed (default 0)."),
				doc_param("max_retries", "int", false, "Contradiction restart attempts (default 12)."),
			],
		},
		"wfc.match_pattern": {
			"description": "Scan the GridMap for a multi-cell pattern and swap each match for a special piece (the Townscaper 'these cells -> a fountain' moment). Tries every placed cell as origin, in all 4 rotations by default; matched cells are consumed so pieces never overlap. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GridMap."),
				doc_param("pattern", "Dictionary", true, "{match: {\"dx,dz\": item}, replace: {\"dx,dz\": item}} offset maps. In match, -1 requires empty; in replace, -1 clears the cell."),
				doc_param("layer", "int", false, "GridMap Y layer to operate on (default 0)."),
				doc_param("rotate", "bool", false, "Also try the pattern in all 4 rotations (default true)."),
				doc_param("limit", "int", false, "Max placements (default 100000)."),
			],
		},
		"wfc.stalberg_grid": {
			"description": "Generate Stalberg's irregular all-quad grid (jittered lattice -> merge triangles into quads -> subdivide -> relax): the organic non-grid look that still tiles. Returns quad corner positions; optionally drops Marker3D nodes at quad centres (undoable when --emit markers).",
			"params": [
				doc_param("width", "int", false, "Grid width in cells (default 6; width*depth <= 4096)."),
				doc_param("depth", "int", false, "Grid depth in cells (default 6)."),
				doc_param("spacing", "float", false, "Base lattice spacing (default 1.0)."),
				doc_param("jitter", "float", false, "Interior-point jitter as a fraction of spacing (default 0.28)."),
				doc_param("relax_iterations", "int", false, "Laplacian relaxation passes (default 12)."),
				doc_param("seed", "int", false, "RNG seed (default 0)."),
				doc_param("origin", "Vector3", false, "World offset added to every output point (default origin)."),
				doc_param("emit", "String", false, "'markers' drops Marker3D nodes at quad centres; '' (default) returns data only."),
				doc_param("parent", "NodePath", false, "Parent for the emitted markers container (default the scene root)."),
				doc_param("name", "String", false, "Name for the emitted markers container (default 'StalbergGrid')."),
				doc_param("return_quads", "bool", false, "Include the quad corner list in the response (default true)."),
			],
		},
	}
