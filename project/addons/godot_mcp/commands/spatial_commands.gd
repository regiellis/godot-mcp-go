@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Spatial-reasoning group (`spatial.*`). The agent can't see the scene and is bad
## at absolute-coordinate 3D math, so these externalize the reasoning: read a node's
## REAL world bounds back, relate two nodes numerically, seat one on a surface, align
## / distribute / look-at via the engine, and lint a layout. All positions are in
## METERS, GLOBAL space, returned as "Vector3(x, y, z)" strings that feed straight
## back into `node.set --property global_position`.
##
## 3D only (the spatial gap lives in 3D). World bounds come from VisualInstance3D
## AABBs (MeshInstance3D, CSGShape3D, ...) transformed to global by the node's
## global_transform — verified against Godot 4.7.

const _CENTER_TOL := 0.05 # meters; |center delta| within this counts as "centered"


func get_commands() -> Dictionary:
	return {
		"spatial.bounds": _bounds,
		"spatial.relate": _relate,
		"spatial.align": _align,
		"spatial.place_on": _place_on,
		"spatial.distribute": _distribute,
		"spatial.find_in_region": _find_in_region,
		"spatial.lint": _lint,
		"spatial.look_at": _look_at,
		"spatial.raycast": _raycast,
		"spatial.snap": _snap,
	}


# --- helpers ----------------------------------------------------------------

## Resolve `node_path` to a node under the edited scene root. Returns [node, err]
## (mirrors node_commands._resolve_node, which isn't inherited here).
func _resolve_node(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null:
		return [null, error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")]
	return [node, null]


func _v3s(v: Vector3) -> String:
	return "Vector3(%.4f, %.4f, %.4f)" % [v.x, v.y, v.z]


func _v3_param(params: Dictionary, key: String, default: Vector3) -> Vector3:
	if not params.has(key):
		return default
	return PropertyParser.parse_value(params[key], TYPE_VECTOR3)


## World-space AABB of `node`: union of its own and descendants' VisualInstance3D
## AABBs, each transformed to global via 8 corners. Returns {has: bool, aabb: AABB}.
func _world_aabb(node: Node) -> Dictionary:
	var has := false
	var acc := AABB()
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var local := vi.get_aabb()
			var gt := vi.global_transform
			var wa := AABB(gt * local.get_endpoint(0), Vector3.ZERO)
			for i in range(1, 8):
				wa = wa.expand(gt * local.get_endpoint(i))
			acc = wa if not has else acc.merge(wa)
			has = true
		for c in n.get_children():
			stack.append(c)
	return {"has": has, "aabb": acc}


func _require_aabb(node: Node, label: String) -> Array:
	var b := _world_aabb(node)
	if not b["has"]:
		return [null, error(-32001, "%s has no 3D visual geometry (need a VisualInstance3D like MeshInstance3D/CSGShape3D)" % label)]
	return [b["aabb"], null]


func _all_visual_instances() -> Array:
	var out: Array = []
	var root := get_edited_root()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _xz_overlap(a: AABB, b: AABB) -> bool:
	return a.position.x <= b.end.x and b.position.x <= a.end.x \
		and a.position.z <= b.end.z and b.position.z <= a.end.z


func _aabb_dict(a: AABB) -> Dictionary:
	return {
		"center": _v3s(a.get_center()), "size": _v3s(a.size),
		"min": _v3s(a.position), "max": _v3s(a.end),
	}


# --- commands ---------------------------------------------------------------

func _bounds(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var ab := _require_aabb(node, "Node")
	if ab[1] != null:
		return ab[1]
	var a: AABB = ab[0]
	var out := _aabb_dict(a)
	out["node"] = str(get_edited_root().get_path_to(node))
	if node is Node3D:
		out["pivot"] = _v3s((node as Node3D).global_position)
	return success(out)


func _relate(params: Dictionary) -> Dictionary:
	var ca := _resolve_node(params)
	if ca[1] != null:
		return ca[1]
	var other := optional_string(params, "other", "")
	if other.is_empty():
		return error_invalid_params("Missing required parameter: other (the node to compare against)")
	var b_node := find_node_by_path(other)
	if b_node == null:
		return error_not_found("Node '%s'" % other, "Use scene.tree to see available nodes")
	var aa := _require_aabb(ca[0], "node_path")
	if aa[1] != null:
		return aa[1]
	var bb := _require_aabb(b_node, "other")
	if bb[1] != null:
		return bb[1]
	var a: AABB = aa[0]
	var b: AABB = bb[0]
	var tol: float = float(params["tolerance"]) if params.has("tolerance") else _CENTER_TOL
	var d := a.get_center() - b.get_center()
	# per-axis gap: positive = clear separation, negative = overlap depth
	var gap := Vector3(
		max(a.position.x - b.end.x, b.position.x - a.end.x),
		max(a.position.y - b.end.y, b.position.y - a.end.y),
		max(a.position.z - b.end.z, b.position.z - a.end.z))
	return success({
		"node": str(get_edited_root().get_path_to(ca[0])),
		"other": str(get_edited_root().get_path_to(b_node)),
		"center_delta": _v3s(d),
		"centered": {"x": abs(d.x) <= tol, "y": abs(d.y) <= tol, "z": abs(d.z) <= tol},
		"gap": _v3s(gap),
		"overlaps": a.intersects(b),
	})


func _align(params: Dictionary) -> Dictionary:
	var ca := _resolve_node(params)
	if ca[1] != null:
		return ca[1]
	var node: Node3D = ca[0] as Node3D
	if node == null:
		return error_invalid_params("align target must be a Node3D")
	var to := optional_string(params, "to", "")
	if to.is_empty():
		return error_invalid_params("Missing required parameter: to (the node to align against)")
	var b_node := find_node_by_path(to)
	if b_node == null:
		return error_not_found("Node '%s'" % to, "Use scene.tree to see available nodes")
	var aa := _require_aabb(node, "node_path")
	if aa[1] != null:
		return aa[1]
	var bb := _require_aabb(b_node, "to")
	if bb[1] != null:
		return bb[1]
	var a: AABB = aa[0]
	var b: AABB = bb[0]
	var axes := optional_string(params, "axes", "xyz").to_lower()
	var on_top := optional_bool(params, "on_top", false)
	var old_pos := node.global_position
	var new_pos := old_pos
	var bc := b.get_center()
	var ac := a.get_center()
	if "x" in axes:
		new_pos.x += bc.x - ac.x
	if "y" in axes and not on_top:
		new_pos.y += bc.y - ac.y
	if "z" in axes:
		new_pos.z += bc.z - ac.z
	if on_top: # seat A's bottom on B's top, overriding any y-centering
		new_pos.y += b.end.y - a.position.y
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Align %s to %s" % [node.name, b_node.name])
	undo_redo.add_do_property(node, "global_position", new_pos)
	undo_redo.add_undo_property(node, "global_position", old_pos)
	undo_redo.commit_action()
	return success({
		"node": str(get_edited_root().get_path_to(node)),
		"old_position": _v3s(old_pos), "new_position": _v3s(node.global_position),
	})


func _place_on(params: Dictionary) -> Dictionary:
	var ca := _resolve_node(params)
	if ca[1] != null:
		return ca[1]
	var node: Node3D = ca[0] as Node3D
	if node == null:
		return error_invalid_params("place_on target must be a Node3D")
	var aa := _require_aabb(node, "node_path")
	if aa[1] != null:
		return aa[1]
	var a: AABB = aa[0]

	# `samples >= 1` switches to TIER 2: a footprint-aligned bundle of parallel
	# DOWN-rays (not a cone — seating is a footprint problem, not a viewpoint one).
	# Needs colliders (CSG use_collision / StaticBody), conforms to slopes, and
	# detects overhang (rays that miss). samples == 0 keeps TIER 1 AABB seating.
	var samples := optional_int(params, "samples", 0)
	if samples >= 1:
		return _place_on_physics(node, a, params, samples)

	# Candidate surfaces: the subtree named by `surface_from`, else all other
	# VisualInstance3Ds not inside this node. Geometry math (mesh AABBs), so it
	# works regardless of collision; use spatial.raycast for true physics seating.
	var candidates: Array = []
	var surface_from := optional_string(params, "surface_from", "")
	if not surface_from.is_empty():
		var s := find_node_by_path(surface_from)
		if s == null:
			return error_not_found("Node '%s'" % surface_from, "surface_from must be a node path")
		for vi in _flatten_visuals(s):
			candidates.append(vi)
	else:
		for vi in _all_visual_instances():
			if vi != node and not node.is_ancestor_of(vi):
				candidates.append(vi)

	var best_top := -INF
	var hit_name := ""
	for vi in candidates:
		var cb := _world_aabb(vi)
		if not cb["has"]:
			continue
		var cab: AABB = cb["aabb"]
		if not _xz_overlap(a, cab):
			continue
		if cab.end.y > a.get_center().y: # only surfaces at/below A
			continue
		if cab.end.y > best_top:
			best_top = cab.end.y
			hit_name = String((vi as Node).name)
	if best_top == -INF:
		return error(-32001, "No surface found under %s's footprint" % node.name, {"suggestion": "Pass surface_from, or check the node sits above a floor"})

	var old_pos := node.global_position
	var new_pos := old_pos
	new_pos.y += best_top - a.position.y # seat A's bottom on the surface top
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Place %s on %s" % [node.name, hit_name])
	undo_redo.add_do_property(node, "global_position", new_pos)
	undo_redo.add_undo_property(node, "global_position", old_pos)
	undo_redo.commit_action()
	return success({
		"node": str(get_edited_root().get_path_to(node)),
		"seated_on": hit_name, "surface_top_y": best_top,
		"old_position": _v3s(old_pos), "new_position": _v3s(node.global_position),
	})


## TIER 2 seating: fire `samples`×`samples` parallel down-rays across the target's
## XZ footprint, excluding the target's own colliders. The object's bottom rests on
## the HIGHEST contact (max hit y) so it never clips into the highest point of uneven
## ground; misses reveal overhang; the averaged hit normal drives optional conform.
func _place_on_physics(node: Node3D, a: AABB, params: Dictionary, samples: int) -> Dictionary:
	var root := get_edited_root()
	if not root is Node3D:
		return error_invalid_params("physics place_on needs a 3D scene (root is not a Node3D)")
	var world := (root as Node3D).get_world_3d()
	if world == null:
		return error_internal("no World3D for the edited scene")
	var space := world.direct_space_state
	var exclude := _collision_rids(node)
	var margin := float(params.get("margin", 0.1)) # start the ray this far above the footprint top
	var max_drop := float(params.get("max_drop", 1000.0)) # how far down to probe
	var top_y := a.end.y + margin
	var bottom_y := a.position.y - max_drop

	var pts := _footprint_samples(a, samples)
	var avg_n := Vector3.ZERO
	var max_y := -INF
	var min_y := INF
	var hit_count := 0
	var colliders := {}
	for p in pts:
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, top_y, p.y), Vector3(p.x, bottom_y, p.y))
		q.collide_with_areas = false
		q.collide_with_bodies = true
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var hp: Vector3 = hit["position"]
		hit_count += 1
		max_y = max(max_y, hp.y)
		min_y = min(min_y, hp.y)
		avg_n += hit["normal"]
		var col: Object = hit.get("collider")
		if col is Node:
			colliders[str(root.get_path_to(col as Node))] = true
	if hit_count == 0:
		return error(-32001, "No collider hit under %s's footprint" % node.name,
			{"suggestion": "Enable use_collision on greybox CSG / add a StaticBody, or drop --samples for collider-free AABB seating"})
	avg_n = avg_n.normalized()

	var old_xform := node.global_transform
	var old_pos := node.global_position
	var new_pos := old_pos
	new_pos.y += max_y - a.position.y # seat bottom on the highest contact
	var conform := optional_bool(params, "conform", false)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Place %s on surface (%d samples)" % [node.name, samples])
	if conform:
		# Re-frame so local +Y follows the averaged surface normal, preserving yaw
		# as much as possible. Engine basis math — never hand-rolled Euler.
		var up := avg_n
		var fwd := old_xform.basis.z
		var right := up.cross(fwd)
		if right.length() < 0.001:
			right = up.cross(old_xform.basis.x)
		right = right.normalized()
		fwd = right.cross(up).normalized()
		var new_xform := Transform3D(Basis(right, up, fwd), new_pos)
		undo_redo.add_do_property(node, "global_transform", new_xform)
		undo_redo.add_undo_property(node, "global_transform", old_xform)
	else:
		undo_redo.add_do_property(node, "global_position", new_pos)
		undo_redo.add_undo_property(node, "global_position", old_pos)
	undo_redo.commit_action()

	return success({
		"node": str(root.get_path_to(node)),
		"mode": "physics_bundle",
		"samples": pts.size(),
		"hits": hit_count,
		"misses": pts.size() - hit_count, # >0 means part of the footprint overhangs empty space
		"surface_top_y": max_y,
		"unevenness": max_y - min_y, # 0 = flat; large = sitting across a step/slope
		"avg_normal": _v3s(avg_n),
		"conformed": conform,
		"seated_on": colliders.keys(),
		"old_position": _v3s(old_pos), "new_position": _v3s(node.global_position),
	})


## XZ sample points (Vector2 = x,z) spanning the footprint AABB: a single center
## point for samples<=1, else an n×n grid across [min,max] on both axes.
func _footprint_samples(a: AABB, n: int) -> Array:
	var pts: Array = []
	if n <= 1:
		var c := a.get_center()
		pts.append(Vector2(c.x, c.z))
		return pts
	for i in n:
		for j in n:
			var fx := float(i) / float(n - 1)
			var fz := float(j) / float(n - 1)
			pts.append(Vector2(lerpf(a.position.x, a.end.x, fx), lerpf(a.position.z, a.end.z, fz)))
	return pts


## RIDs of every CollisionObject3D in `node`'s subtree — so a down-ray seating the
## node doesn't hit the node's own colliders.
func _collision_rids(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D:
			out.append((n as CollisionObject3D).get_rid())
		for c in n.get_children():
			stack.append(c)
	return out


func _flatten_visuals(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _distribute(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	if not params.has("nodes") or not params["nodes"] is Array:
		return error_invalid_params("Missing required parameter: nodes (a JSON array of node paths)")
	var paths: Array = params["nodes"]
	if paths.size() < 2:
		return error_invalid_params("distribute needs at least 2 nodes")
	var axis := optional_string(params, "axis", "x").to_lower()
	if axis not in ["x", "y", "z"]:
		return error_invalid_params("axis must be x, y, or z")
	var idx: int = {"x": 0, "y": 1, "z": 2}[axis]

	var nodes: Array = []
	var centers: Array = []
	for p in paths:
		var n := find_node_by_path(str(p))
		if n == null or not n is Node3D:
			return error_not_found("Node3D '%s'" % str(p), "all nodes must exist and be Node3D")
		var ab := _world_aabb(n)
		if not ab["has"]:
			return error(-32001, "Node '%s' has no 3D geometry" % str(p))
		nodes.append(n)
		centers.append((ab["aabb"] as AABB).get_center())

	var anchor: float = (centers[0] as Vector3)[idx]
	var step := 0.0
	if params.has("spacing"):
		step = float(params["spacing"])
	elif params.has("span"):
		step = float(params["span"]) / float(nodes.size() - 1)
	else:
		return error_invalid_params("Provide spacing or span")

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Distribute %d nodes on %s" % [nodes.size(), axis])
	var result: Array = []
	for i in nodes.size():
		var node: Node3D = nodes[i]
		var target_center: float = anchor + step * i
		var delta: float = target_center - (centers[i] as Vector3)[idx]
		var old_pos: Vector3 = node.global_position
		var new_pos := old_pos
		new_pos[idx] += delta
		undo_redo.add_do_property(node, "global_position", new_pos)
		undo_redo.add_undo_property(node, "global_position", old_pos)
		result.append({"node": str(get_edited_root().get_path_to(node)), "position": _v3s(new_pos)})
	undo_redo.commit_action()
	return success({"axis": axis, "step": step, "nodes": result})


func _find_in_region(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	if not params.has("min") or not params.has("max"):
		return error_invalid_params("Provide min and max (Vector3 corners of the region)")
	var mn := _v3_param(params, "min", Vector3.ZERO)
	var mx := _v3_param(params, "max", Vector3.ZERO)
	var region := AABB(mn, mx - mn).abs()
	var found: Array = []
	for vi in _all_visual_instances():
		var ab := _world_aabb(vi)
		if ab["has"] and region.intersects(ab["aabb"]):
			found.append({
				"node": str(get_edited_root().get_path_to(vi)),
				"center": _v3s((ab["aabb"] as AABB).get_center()),
			})
	return success({"region_min": _v3s(region.position), "region_max": _v3s(region.end), "count": found.size(), "nodes": found})


func _lint(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var check_floating := optional_bool(params, "check_floating", false)
	var float_threshold := float(params.get("float_threshold", 0.5))
	var visuals := _all_visual_instances()
	var boxes: Array = []
	for vi in visuals:
		var ab := _world_aabb(vi)
		if ab["has"]:
			boxes.append({"node": vi, "aabb": ab["aabb"]})

	var duplicates: Array = []
	for i in boxes.size():
		for j in range(i + 1, boxes.size()):
			var ai: AABB = boxes[i]["aabb"]
			var aj: AABB = boxes[j]["aabb"]
			if ai.get_center().distance_to(aj.get_center()) <= _CENTER_TOL \
					and (ai.size - aj.size).length() <= _CENTER_TOL:
				duplicates.append({
					"a": str(get_edited_root().get_path_to(boxes[i]["node"])),
					"b": str(get_edited_root().get_path_to(boxes[j]["node"])),
					"center": _v3s(ai.get_center()),
				})

	var floating: Array = []
	if check_floating:
		# "Floating/unsupported" only applies to solid placeable geometry (meshes,
		# CSG). Lights, decals, fog, GI probes, particles, sprites/labels and
		# MultiMesh scatter are VisualInstance3D too but have no "rests on a surface"
		# semantics — they were false-flagged. Restrict both the candidates and the
		# supporters to solid geometry.
		var solids: Array = []
		for b in boxes:
			var bn: Node = b["node"]
			if bn is MeshInstance3D or bn is CSGShape3D:
				solids.append(b)
		for i in solids.size():
			var ai: AABB = solids[i]["aabb"]
			var supported := false
			for j in solids.size():
				if i == j:
					continue
				var aj: AABB = solids[j]["aabb"]
				# Connected to the structure: AABBs touch/overlap (mounted, hanging,
				# attached) — not floating in empty space. Grow by a 5 cm contact
				# tolerance so flush/edge-touching decals & trim count as attached
				# (AABB.intersects misses exact-boundary contact).
				if ai.grow(0.05).intersects(aj):
					supported = true
					break
				# Or resting on a surface just below (xz overlap + a small gap).
				if _xz_overlap(ai, aj) and aj.end.y <= ai.position.y + 0.001 and ai.position.y - aj.end.y <= float_threshold:
					supported = true
					break
			if not supported:
				floating.append({
					"node": str(get_edited_root().get_path_to(solids[i]["node"])),
					"bottom_y": ai.position.y,
				})

	return success({"checked": boxes.size(), "duplicates": duplicates, "floating": floating})


func _look_at(params: Dictionary) -> Dictionary:
	var ca := _resolve_node(params)
	if ca[1] != null:
		return ca[1]
	var node: Node3D = ca[0] as Node3D
	if node == null:
		return error_invalid_params("look_at target must be a Node3D")
	var target := Vector3.ZERO
	var target_label := ""
	if params.has("target"):
		var t := find_node_by_path(str(params["target"]))
		if t == null or not t is Node3D:
			return error_not_found("Node3D '%s'" % str(params["target"]), "target must be a Node3D path, or pass 'point'")
		target = (t as Node3D).global_position
		target_label = String((t as Node3D).name)
	elif params.has("point"):
		target = _v3_param(params, "point", Vector3.ZERO)
		target_label = _v3s(target)
	else:
		return error_invalid_params("Provide target (a node path) or point (a Vector3)")
	if node.global_position.is_equal_approx(target):
		return error_invalid_params("Node and target are at the same position; can't aim")
	var old_xform := node.global_transform
	var new_xform := old_xform.looking_at(target, Vector3.UP) # engine math, never hand-rolled Euler
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: %s look_at %s" % [node.name, target_label])
	undo_redo.add_do_property(node, "global_transform", new_xform)
	undo_redo.add_undo_property(node, "global_transform", old_xform)
	undo_redo.commit_action()
	return success({
		"node": str(get_edited_root().get_path_to(node)),
		"target": target_label,
		"rotation_degrees": _v3s(node.rotation_degrees),
	})


func _raycast(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("raycast needs a 3D scene (root is not a Node3D)")
	if not params.has("from") or not params.has("to"):
		return error_invalid_params("Provide from and to (Vector3 ray endpoints)")
	var from := _v3_param(params, "from", Vector3.ZERO)
	var to := _v3_param(params, "to", Vector3.ZERO)
	var world := (root as Node3D).get_world_3d()
	if world == null:
		return error_internal("no World3D for the edited scene")
	var space := world.direct_space_state
	# Edit-time physics: hits CSG use_collision and any StaticBody/CollisionObject3D.
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = optional_bool(params, "collide_with_areas", false)
	q.collide_with_bodies = optional_bool(params, "collide_with_bodies", true)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return success({"hit": false, "from": _v3s(from), "to": _v3s(to),
			"note": "No collider hit. Greybox CSG needs use_collision=true; a bare MeshInstance3D has no collider."})
	var collider: Object = hit.get("collider")
	var collider_path := ""
	if collider is Node:
		collider_path = str(root.get_path_to(collider as Node))
	var pos: Vector3 = hit["position"]
	return success({
		"hit": true,
		"position": _v3s(pos),
		"normal": _v3s(hit["normal"]),
		"collider": collider_path,
		"distance": from.distance_to(pos),
	})


## TIER 3 seating: snap `node_path`'s anchor point onto the target's real mesh
## geometry. The scriptable analog of 4.7's editor-only vertex snapping — 4.7
## exposes no callable for it, so we read the actual vertices via Mesh.get_faces()
## (CSG via bake_static_mesh()), transform to world, and move to the nearest one.
## `mode=vertex` snaps to the closest mesh vertex; `mode=face` to the closest point
## on the closest triangle (better on large flat faces where vertices are far).
## No collider needed; works headless. `axes` constrains which components move.
func _snap(params: Dictionary) -> Dictionary:
	var ca := _resolve_node(params)
	if ca[1] != null:
		return ca[1]
	var node: Node3D = ca[0] as Node3D
	if node == null:
		return error_invalid_params("snap target must be a Node3D")
	var to := optional_string(params, "to", "")
	if to.is_empty():
		return error_invalid_params("Missing required parameter: to (the node whose mesh to snap onto)")
	var b_node := find_node_by_path(to)
	if b_node == null:
		return error_not_found("Node '%s'" % to, "Use scene.tree to see available nodes")

	var mode := optional_string(params, "mode", "vertex").to_lower()
	if mode not in ["vertex", "face"]:
		return error_invalid_params("mode must be 'vertex' or 'face'")
	var anchor := optional_string(params, "anchor", "pivot").to_lower()
	if anchor not in ["pivot", "center", "min", "max", "bottom"]:
		return error_invalid_params("anchor must be pivot, center, min, max, or bottom")

	# Anchor point on the mover, in world space. 'pivot' = origin (no geometry needed,
	# mirrors how the editor snaps the node's origin); others need its world AABB.
	var p := node.global_position
	if anchor != "pivot":
		var ab := _require_aabb(node, "node_path")
		if ab[1] != null:
			return ab[1]
		p = _anchor_point(ab[0], anchor)

	var faces := _gather_world_faces(b_node)
	if faces.is_empty():
		return error(-32001, "Target '%s' has no readable mesh geometry" % to,
			{"suggestion": "Snap target must contain a MeshInstance3D or CSGShape3D"})

	var best := Vector3.ZERO
	var best_d := INF
	if mode == "vertex":
		for v in faces:
			var d := p.distance_squared_to(v)
			if d < best_d:
				best_d = d
				best = v
	else: # face: closest point on each triangle
		var tri := faces.size() - (faces.size() % 3)
		var i := 0
		while i < tri:
			var cp := _closest_point_on_triangle(p, faces[i], faces[i + 1], faces[i + 2])
			var d := p.distance_squared_to(cp)
			if d < best_d:
				best_d = d
				best = cp
			i += 3
	var dist := sqrt(best_d)

	var max_distance := float(params.get("max_distance", INF))
	if dist > max_distance:
		return success({
			"node": str(get_edited_root().get_path_to(node)),
			"snapped": false,
			"reason": "nearest snap point is %.4f away, beyond max_distance %.4f" % [dist, max_distance],
			"nearest_point": _v3s(best), "distance": dist,
		})

	var axes := optional_string(params, "axes", "xyz").to_lower()
	var delta := best - p
	var masked := Vector3(
		delta.x if "x" in axes else 0.0,
		delta.y if "y" in axes else 0.0,
		delta.z if "z" in axes else 0.0)
	var old_pos := node.global_position
	var new_pos := old_pos + masked

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Snap %s to %s (%s)" % [node.name, b_node.name, mode])
	undo_redo.add_do_property(node, "global_position", new_pos)
	undo_redo.add_undo_property(node, "global_position", old_pos)
	undo_redo.commit_action()
	return success({
		"node": str(get_edited_root().get_path_to(node)),
		"snapped": true,
		"mode": mode, "anchor": anchor, "axes": axes,
		"snap_point": _v3s(best),
		"distance": dist,
		"old_position": _v3s(old_pos), "new_position": _v3s(node.global_position),
	})


func _anchor_point(a: AABB, anchor: String) -> Vector3:
	match anchor:
		"center": return a.get_center()
		"min": return a.position
		"max": return a.end
		"bottom":
			var c := a.get_center()
			return Vector3(c.x, a.position.y, c.z)
	return a.get_center()


## World-space triangle vertices (triplets preserved for face mode) from every
## MeshInstance3D / CSGShape3D under `root`. CSG is baked once and its CSG children
## skipped (bake already includes them) to avoid double-counting.
func _gather_world_faces(root: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mesh: Mesh = null
		var xform := Transform3D()
		var skip_children := false
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			mesh = (n as MeshInstance3D).mesh
			xform = (n as MeshInstance3D).global_transform
		elif n is CSGShape3D:
			mesh = (n as CSGShape3D).bake_static_mesh()
			xform = (n as CSGShape3D).global_transform
			skip_children = true
		if mesh != null:
			for v in mesh.get_faces():
				out.append(xform * v)
		if not skip_children:
			for c in n.get_children():
				stack.append(c)
	return out


## Closest point on triangle (a,b,c) to p — Ericson, Real-Time Collision Detection.
## GDScript Geometry3D has no direct call for this.
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


func get_command_docs() -> Dictionary:
	return {
		"spatial.bounds": {
			"description": "Return a node's real world-space AABB (center/size/min/max as Vector3 strings) plus its pivot, from its VisualInstance3D geometry. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node (must contain 3D visual geometry)."),
			],
		},
		"spatial.relate": {
			"description": "Compare two nodes numerically: center delta, per-axis centered flags, per-axis gap (negative = overlap depth), and whether their AABBs intersect. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "First node."),
				doc_param("other", "NodePath", true, "Node to compare against."),
				doc_param("tolerance", "float", false, "Meters within which an axis counts as centered (default 0.05)."),
			],
		},
		"spatial.align": {
			"description": "Move --node-path so its center matches --to's on the chosen --axes; --on-top instead seats its bottom on the target's top. Undoable. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to move (a Node3D)."),
				doc_param("to", "NodePath", true, "Node to align against."),
				doc_param("axes", "String", false, "Which axes to align on, e.g. 'xz' (default 'xyz')."),
				doc_param("on_top", "bool", false, "Seat the mover's bottom on the target's top (overrides y-centering)."),
			],
		},
		"spatial.place_on": {
			"description": "Seat --node-path onto a surface below it. Default (samples=0): AABB seating against the highest mesh under its footprint. --samples N>=1: an NxN bundle of down-rays (needs colliders), conforms to slopes and detects overhang. Undoable. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to seat (a Node3D)."),
				doc_param("samples", "int", false, "0 = AABB seating (default); N>=1 = NxN raycast footprint bundle (needs colliders)."),
				doc_param("surface_from", "NodePath", false, "Restrict the surface search to this subtree (AABB mode)."),
				doc_param("margin", "float", false, "Ray start height above the footprint top, meters (raycast mode; default 0.1)."),
				doc_param("max_drop", "float", false, "How far down to probe, meters (raycast mode; default 1000)."),
				doc_param("conform", "bool", false, "Re-orient so local +Y follows the averaged surface normal (raycast mode)."),
			],
		},
		"spatial.distribute": {
			"description": "Evenly space --nodes along one --axis using --spacing (fixed step) OR --span (total spread), anchored on the first node. Undoable. 3D only.",
			"params": [
				doc_param("nodes", "Array", true, "JSON array of node paths (>= 2), all Node3D with geometry."),
				doc_param("axis", "String", false, "'x', 'y', or 'z' (default 'x')."),
				doc_param("spacing", "float", false, "Fixed gap between successive centers. Provide spacing OR span."),
				doc_param("span", "float", false, "Total spread divided across the nodes. Provide spacing OR span."),
			],
		},
		"spatial.find_in_region": {
			"description": "List every node whose world AABB intersects the box between --min and --max. 3D only.",
			"params": [
				doc_param("min", "Vector3", true, "One corner of the region box."),
				doc_param("max", "Vector3", true, "Opposite corner of the region box."),
			],
		},
		"spatial.lint": {
			"description": "Report layout problems: overlapping duplicate geometry, and (with --check-floating) solid meshes/CSG that rest on or touch nothing. 3D only.",
			"params": [
				doc_param("check_floating", "bool", false, "Also flag unsupported/floating solid geometry."),
				doc_param("float_threshold", "float", false, "Max gap to a surface below that still counts as resting, meters (default 0.5)."),
			],
		},
		"spatial.look_at": {
			"description": "Aim --node-path at a --target node OR a --point (Vector3), using engine basis math. Undoable. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to rotate (a Node3D)."),
				doc_param("target", "NodePath", false, "Node to look at. Provide target OR point."),
				doc_param("point", "Vector3", false, "World point to look at. Provide target OR point."),
			],
		},
		"spatial.raycast": {
			"description": "Cast an edit-time physics ray from --from to --to; returns the first collider hit, position, normal, and distance. Hits CSG use_collision and StaticBody/CollisionObject3D. 3D only.",
			"params": [
				doc_param("from", "Vector3", true, "Ray start point."),
				doc_param("to", "Vector3", true, "Ray end point."),
				doc_param("collide_with_areas", "bool", false, "Also hit Area3D (default false)."),
				doc_param("collide_with_bodies", "bool", false, "Hit physics bodies (default true)."),
			],
		},
		"spatial.snap": {
			"description": "Snap --node-path's anchor point onto --to's real mesh geometry: --mode vertex (nearest vertex) or face (nearest point on nearest triangle). No collider needed; works headless. Undoable. 3D only.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to move (a Node3D)."),
				doc_param("to", "NodePath", true, "Node whose mesh geometry to snap onto."),
				doc_param("mode", "String", false, "'vertex' (default) or 'face'."),
				doc_param("anchor", "String", false, "Which point on the mover to snap: pivot (default), center, min, max, or bottom."),
				doc_param("max_distance", "float", false, "Skip the move if the nearest snap point is farther than this."),
				doc_param("axes", "String", false, "Constrain which components move, e.g. 'y' (default 'xyz')."),
			],
		},
	}
