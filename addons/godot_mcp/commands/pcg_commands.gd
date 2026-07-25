@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## PCG — Godot has no Unreal-style procedural-generation framework. Rather than a visual graph,
## this exposes the three PCG primitives and lets the agent's command sequence BE the graph:
##   DOMAIN (sample)  →  FILTERS (cull by rule)  →  EMITTER (realize)
## seeded for reproducibility, and pairs with authoring.checkpoint for non-destructive runs.
##
##   domain:        --on <surface> | --region min/max | --along <Path3D>
##   distribution:  --count N (random) | --poisson --radius R (blue-noise) | --grid --spacing S
##   filters:       --min_slope/--max_slope (deg) · --min_height/--max_height · --noise_threshold (+--noise_frequency/--noise_seed)
##   emitter:       --emit multimesh (one draw call) | --emit scene --scene res://x.tscn (real nodes)
##   jitter:        --align_to_normal --yaw_random --scale_min/--scale_max   ·   --seed
##
## pcg.sample previews the point set (no mutation, with per-filter cull stats); pcg.scatter emits.

const _PRIMITIVES := ["BoxMesh", "SphereMesh", "CylinderMesh", "CapsuleMesh", "PlaneMesh", "PrismMesh", "TorusMesh", "QuadMesh"]
const MAX_CANDIDATES := 20000


func get_commands() -> Dictionary:
	return {
		"pcg.sample": _sample,
		"pcg.scatter": _scatter,
		"pcg.relax": _relax,
	}


# --- pcg.relax (Laplacian / centroidal smoothing of a point graph) ----------

## Move each point toward the average of its graph neighbours, N times — the relaxation step
## that smooths an irregular grid (Stålberg's organic look) or de-clumps a scatter. Pure data:
## --points '[Vector3,…]' --edges '[[i,j],…]' [--iterations N --strength 0..1 --fixed '[idx,…]'].
func _relax(params: Dictionary) -> Dictionary:
	if not params.has("points"):
		return error_invalid_params("Missing --points (JSON array of Vector3)")
	var praw: Variant = params["points"]
	if praw is String:
		praw = JSON.parse_string(praw)
	if not praw is Array or (praw as Array).is_empty():
		return error_invalid_params("--points must be a non-empty JSON array")
	var points: Array[Vector3] = []
	for e in praw:
		points.append(_v3({"v": e}, "v", Vector3.ZERO))

	var eraw: Variant = params.get("edges", [])
	if eraw is String:
		eraw = JSON.parse_string(eraw)
	var nbr: Array = []
	for _i in points.size():
		nbr.append({})
	if eraw is Array:
		for pair in eraw:
			if pair is Array and (pair as Array).size() >= 2:
				var a := int(pair[0])
				var b := int(pair[1])
				if a >= 0 and a < points.size() and b >= 0 and b < points.size() and a != b:
					nbr[a][b] = true
					nbr[b][a] = true

	var fixed := {}
	var fraw: Variant = params.get("fixed", [])
	if fraw is String:
		fraw = JSON.parse_string(fraw)
	if fraw is Array:
		for idx in fraw:
			fixed[int(idx)] = true

	var iterations := optional_int(params, "iterations", 10)
	var strength := float(params.get("strength", 1.0))
	strength = clampf(strength, 0.0, 1.0)

	for _it in iterations:
		var next := points.duplicate()
		for i in points.size():
			if fixed.has(i) or nbr[i].is_empty():
				continue
			var mean := Vector3.ZERO
			for n in nbr[i]:
				mean += points[n]
			mean /= float(nbr[i].size())
			next[i] = points[i].lerp(mean, strength)
		points = next

	var out: Array = []
	for p: Vector3 in points:
		out.append(str(p))
	return success({"points": out, "count": points.size(), "iterations": iterations, "fixed": fixed.size()})


func _v3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


# --- the shared pipeline ----------------------------------------------------

## Returns {transforms: Array[Transform3D], stats: Dictionary} or [null, error].
func _run_pipeline(params: Dictionary) -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	if not root is Node3D:
		return [null, error_invalid_params("pcg needs a 3D scene")]

	var rng := RandomNumberGenerator.new()
	rng.seed = optional_int(params, "seed", 0)

	var stats := {"candidates": 0, "ray_miss": 0, "filtered_slope": 0, "filtered_height": 0, "filtered_noise": 0, "placed": 0}

	# --- DOMAIN + DISTRIBUTION → candidate seed points (with normals) ---
	var seats: Array = []  # Array of {pos: Vector3, normal: Vector3}

	if params.has("along"):
		var p := find_node_by_path(str(params["along"]))
		if p == null or not p is Path3D or (p as Path3D).curve == null:
			return [null, error_invalid_params("'along' must be a Path3D with a curve")]
		var curve := (p as Path3D).curve
		var length := curve.get_baked_length()
		var n := optional_int(params, "count", 0)
		if n <= 0 and params.has("spacing"):
			n = maxi(2, int(length / maxf(float(params["spacing"]), 0.0001)) + 1)
		if n < 1:
			n = 10
		var gt := (p as Path3D).global_transform
		for i in n:
			var off := length * (float(i) / float(maxi(1, n - 1)))
			seats.append({"pos": gt * curve.sample_baked(off, true), "normal": Vector3.UP})
		stats["candidates"] = seats.size()
	else:
		# region: explicit min/max, or an 'on' surface AABB footprint
		var rmin: Vector3
		var rmax: Vector3
		if params.has("on"):
			var surf := find_node_by_path(str(params["on"]))
			if surf == null or not surf is VisualInstance3D:
				return [null, error_invalid_params("'on' must be a VisualInstance3D node")]
			var wa: AABB = world_aabb(surf)["aabb"]  # unions surf + visual descendants, world-space
			rmin = wa.position
			rmax = wa.end
		elif params.has("region_min") and params.has("region_max"):
			rmin = _v3(params, "region_min", Vector3.ZERO)
			rmax = _v3(params, "region_max", Vector3.ONE)
		else:
			return [null, error_invalid_params("Provide a domain: --on <node>, --region_min/--region_max, or --along <path>")]

		var candidates := _distribute(params, rng, Vector2(rmin.x, rmin.z), Vector2(rmax.x, rmax.z))
		stats["candidates"] = candidates.size()
		if candidates.size() > MAX_CANDIDATES:
			return [null, error_invalid_params("Too many candidates (%d > %d). Lower count / raise spacing/radius." % [candidates.size(), MAX_CANDIDATES])]

		var use_ray := optional_bool(params, "raycast", true)
		var base_y := float(params.get("base_y", rmin.y))
		if use_ray:
			var space: PhysicsDirectSpaceState3D = (root as Node3D).get_world_3d().direct_space_state
			var top_y := rmax.y + float(params.get("margin", 1.0))
			var bottom_y := rmin.y - float(params.get("max_drop", 1000.0))
			for c: Vector2 in candidates:
				var q := PhysicsRayQueryParameters3D.create(Vector3(c.x, top_y, c.y), Vector3(c.x, bottom_y, c.y))
				q.collide_with_areas = false
				var hit := space.intersect_ray(q)
				if hit.is_empty():
					stats["ray_miss"] += 1
				else:
					seats.append({"pos": hit.position, "normal": hit.normal})
		else:
			for c: Vector2 in candidates:
				seats.append({"pos": Vector3(c.x, base_y, c.y), "normal": Vector3.UP})

	# --- FILTERS ---
	var min_slope := float(params.get("min_slope", 0.0))
	var max_slope := float(params.get("max_slope", 180.0))
	var has_height := params.has("min_height") or params.has("max_height")
	var min_h := float(params.get("min_height", -INF))
	var max_h := float(params.get("max_height", INF))
	var has_noise := params.has("noise_threshold")
	var noise: FastNoiseLite = null
	var noise_thr := 0.0
	if has_noise:
		noise = FastNoiseLite.new()
		noise.seed = optional_int(params, "noise_seed", optional_int(params, "seed", 0))
		noise.frequency = float(params.get("noise_frequency", 0.05))
		noise_thr = float(params["noise_threshold"])

	var kept: Array = []
	for s in seats:
		var pos: Vector3 = s["pos"]
		var normal: Vector3 = s["normal"]
		var slope := rad_to_deg(normal.angle_to(Vector3.UP))
		if slope < min_slope or slope > max_slope:
			stats["filtered_slope"] += 1
			continue
		if has_height and (pos.y < min_h or pos.y > max_h):
			stats["filtered_height"] += 1
			continue
		if has_noise:
			var nv := (noise.get_noise_2d(pos.x, pos.z) + 1.0) * 0.5  # → [0,1]
			if nv < noise_thr:
				stats["filtered_noise"] += 1
				continue
		kept.append(s)

	# --- JITTER → transforms ---
	var align := optional_bool(params, "align_to_normal", false)
	var yaw_random := optional_bool(params, "yaw_random", true)
	var scale_min := float(params.get("scale_min", 1.0))
	var scale_max := float(params.get("scale_max", 1.0))

	var transforms: Array[Transform3D] = []
	for s in kept:
		var basis := Basis()
		if align:
			basis = _basis_from_up(s["normal"])
		if yaw_random:
			basis = basis * Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3.ONE * rng.randf_range(scale_min, scale_max))
		transforms.append(Transform3D(basis, s["pos"]))
	stats["placed"] = transforms.size()

	return [{"transforms": transforms, "stats": stats}, null]


## Candidate XZ points via distribution: poisson (blue-noise) | grid | random.
func _distribute(params: Dictionary, rng: RandomNumberGenerator, lo: Vector2, hi: Vector2) -> Array:
	var out: Array = []
	if optional_bool(params, "poisson", false) or params.has("radius"):
		var radius := float(params.get("radius", 1.0))
		var target := optional_int(params, "count", 200)
		var max_attempts := target * 30
		var attempts := 0
		while out.size() < target and attempts < max_attempts:
			attempts += 1
			var c := Vector2(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y))
			var ok := true
			for a: Vector2 in out:
				if c.distance_to(a) < radius:
					ok = false
					break
			if ok:
				out.append(c)
		return out
	if optional_bool(params, "grid", false) or params.has("spacing"):
		var spacing := float(params.get("spacing", 2.0))
		var jitter := float(params.get("grid_jitter", 0.0))
		var x := lo.x
		while x <= hi.x:
			var z := lo.y
			while z <= hi.y:
				out.append(Vector2(x + rng.randf_range(-jitter, jitter), z + rng.randf_range(-jitter, jitter)))
				z += spacing
			x += spacing
		return out
	# random
	var n := optional_int(params, "count", 100)
	for i in n:
		out.append(Vector2(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y)))
	return out


func _basis_from_up(up: Vector3) -> Basis:
	up = up.normalized()
	var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := arbitrary.cross(up).normalized()
	var z := up.cross(x).normalized()
	return Basis(x, up, z)


# --- pcg.sample (preview, no mutation) --------------------------------------

func _sample(params: Dictionary) -> Dictionary:
	var r := _run_pipeline(params)
	if r[1] != null:
		return r[1]
	var transforms: Array = r[0]["transforms"]
	var limit := optional_int(params, "limit", 50)
	var pts: Array = []
	for i in mini(transforms.size(), limit):
		pts.append(str((transforms[i] as Transform3D).origin))
	return success({
		"stats": r[0]["stats"],
		"returned": pts.size(),
		"truncated": transforms.size() > limit,
		"positions": pts,
	})


# --- pcg.scatter (emit) -----------------------------------------------------

func _scatter(params: Dictionary) -> Dictionary:
	var r := _run_pipeline(params)
	if r[1] != null:
		return r[1]
	var transforms: Array = r[0]["transforms"]
	var stats: Dictionary = r[0]["stats"]
	if transforms.is_empty():
		return error(-32000, "PCG produced 0 points after filtering", {"stats": stats} as Dictionary)

	var emit := optional_string(params, "emit", "multimesh").to_lower()
	match emit:
		"multimesh":
			return _emit_multimesh(params, transforms, stats)
		"scene":
			return _emit_scene(params, transforms, stats)
		_:
			return error_invalid_params("emit must be 'multimesh' or 'scene'")


func _emit_multimesh(params: Dictionary, transforms: Array, stats: Dictionary) -> Dictionary:
	var root := get_edited_root()
	var mesh: Mesh = null
	if params.has("mesh_path"):
		if not ResourceLoader.exists(str(params["mesh_path"])):
			return error_not_found("Mesh '%s'" % params["mesh_path"])
		mesh = load(str(params["mesh_path"])) as Mesh
	elif params.has("mesh_from"):
		var n := find_node_by_path(str(params["mesh_from"]))
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
	else:
		var mt := optional_string(params, "mesh_type", "BoxMesh")
		if mt in _PRIMITIVES:
			mesh = ClassDB.instantiate(mt) as Mesh
	if mesh == null:
		return error_invalid_params("Provide a mesh: --mesh_type / --mesh_path / --mesh_from")

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])

	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node")
	var mmi := MultiMeshInstance3D.new()
	mmi.name = optional_string(params, "name", "PCG_Scatter")
	mmi.multimesh = mm
	add_child_with_undo(parent, mmi, root, "MCP: PCG scatter %d (multimesh)" % transforms.size())
	return success({"node_path": str(root.get_path_to(mmi)), "emit": "multimesh", "placed": transforms.size(), "stats": stats})


func _emit_scene(params: Dictionary, transforms: Array, stats: Dictionary) -> Dictionary:
	var root := get_edited_root()
	var rs := require_string(params, "scene")
	if rs[1] != null:
		return rs[1]
	if not ResourceLoader.exists(rs[0]):
		return error_not_found("Scene '%s'" % rs[0])
	var packed: Resource = load(rs[0])
	if not packed is PackedScene:
		return error_invalid_params("'%s' is not a PackedScene" % rs[0])

	var cap := optional_int(params, "max_instances", 2000)
	if transforms.size() > cap:
		return error_invalid_params("scene emit would create %d nodes (> max_instances %d). Use --emit multimesh for large counts, or raise --max_instances." % [transforms.size(), cap])

	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node")

	var container := Node3D.new()
	container.name = optional_string(params, "name", "PCG_Scatter")
	var inv := (parent as Node3D).global_transform.affine_inverse() if parent is Node3D else Transform3D.IDENTITY

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: PCG scatter %d (scene)" % transforms.size())
	undo_redo.add_do_method(parent, "add_child", container)
	undo_redo.add_do_method(container, "set_owner", root)
	undo_redo.add_do_reference(container)
	var instances: Array[Node] = []
	for t: Transform3D in transforms:
		var inst := (packed as PackedScene).instantiate()
		if inst is Node3D:
			(inst as Node3D).transform = inv * t  # container sits under parent at identity-ish; keep world placement
		instances.append(inst)
		undo_redo.add_do_method(container, "add_child", inst)
		undo_redo.add_do_method(inst, "set_owner", root)
		undo_redo.add_do_reference(inst)
	undo_redo.add_undo_method(parent, "remove_child", container)
	undo_redo.commit_action()

	return success({"node_path": str(root.get_path_to(container)), "emit": "scene", "placed": transforms.size(), "stats": stats})


func get_command_docs() -> Dictionary:
	return {
		"pcg.sample": {
			"description": "Preview the PCG point set without mutating the scene (DOMAIN -> DISTRIBUTION -> raycast seat -> FILTERS -> JITTER), with per-stage cull stats. Seeded. 3D scene only. Provide one domain: --on, --region-min/--region-max, or --along.",
			"params": [
				doc_param("seed", "int", false, "RNG seed for reproducibility (default 0)."),
				doc_param("on", "NodePath", false, "Domain: a VisualInstance3D whose world AABB footprint is the region. Use one domain."),
				doc_param("region_min", "Vector3", false, "Domain: region min corner (pair with --region-max). Use one domain."),
				doc_param("region_max", "Vector3", false, "Domain: region max corner (pair with --region-min)."),
				doc_param("along", "NodePath", false, "Domain: a Path3D to distribute along its curve. Use one domain."),
				doc_param("count", "int", false, "Point count for random / poisson / along distribution (random default 100, poisson 200)."),
				doc_param("spacing", "float", false, "Grid/along spacing between points (selects grid distribution when set)."),
				doc_param("poisson", "bool", false, "Blue-noise (Poisson-disk) distribution; --radius also selects it."),
				doc_param("radius", "float", false, "Poisson minimum spacing between points (default 1.0)."),
				doc_param("grid", "bool", false, "Regular grid distribution (--spacing also selects it)."),
				doc_param("grid_jitter", "float", false, "Random per-axis jitter added to grid points (default 0)."),
				doc_param("raycast", "bool", false, "Down-ray each candidate onto edit-time colliders to seat it (default true)."),
				doc_param("base_y", "float", false, "Y to place points at when --raycast is false (default region min Y)."),
				doc_param("margin", "float", false, "Height above the region top the seating ray starts (default 1.0)."),
				doc_param("max_drop", "float", false, "How far below the region bottom the seating ray reaches (default 1000)."),
				doc_param("min_slope", "float", false, "Filter: drop seats whose surface slope (deg from up) is below this (default 0)."),
				doc_param("max_slope", "float", false, "Filter: drop seats above this slope in degrees (default 180)."),
				doc_param("min_height", "float", false, "Filter: drop seats below this world Y."),
				doc_param("max_height", "float", false, "Filter: drop seats above this world Y."),
				doc_param("noise_threshold", "float", false, "Filter: keep seats where FastNoiseLite value (0..1) >= this (enables the noise mask)."),
				doc_param("noise_frequency", "float", false, "Noise-mask frequency (default 0.05)."),
				doc_param("noise_seed", "int", false, "Noise-mask seed (defaults to --seed)."),
				doc_param("align_to_normal", "bool", false, "Orient instances to the surface normal (default false)."),
				doc_param("yaw_random", "bool", false, "Apply a random yaw to each instance (default true)."),
				doc_param("scale_min", "float", false, "Minimum uniform scale jitter (default 1.0)."),
				doc_param("scale_max", "float", false, "Maximum uniform scale jitter (default 1.0)."),
				doc_param("limit", "int", false, "Max preview positions returned (default 50)."),
			],
		},
		"pcg.scatter": {
			"description": "Run the same PCG pipeline as pcg.sample and realize the points, either as one MultiMeshInstance3D (--emit multimesh, one draw call) or instantiated scenes (--emit scene). Undoable. Errors if 0 points survive filtering.",
			"params": [
				doc_param("seed", "int", false, "RNG seed (default 0)."),
				doc_param("on", "NodePath", false, "Domain: VisualInstance3D footprint. Use one domain."),
				doc_param("region_min", "Vector3", false, "Domain: region min corner (with --region-max)."),
				doc_param("region_max", "Vector3", false, "Domain: region max corner."),
				doc_param("along", "NodePath", false, "Domain: a Path3D to distribute along."),
				doc_param("count", "int", false, "Point count (random default 100, poisson 200)."),
				doc_param("spacing", "float", false, "Grid/along spacing (selects grid distribution)."),
				doc_param("poisson", "bool", false, "Blue-noise distribution (--radius also selects it)."),
				doc_param("radius", "float", false, "Poisson minimum spacing (default 1.0)."),
				doc_param("grid", "bool", false, "Regular grid distribution."),
				doc_param("grid_jitter", "float", false, "Grid point jitter (default 0)."),
				doc_param("raycast", "bool", false, "Down-ray seat candidates onto colliders (default true)."),
				doc_param("base_y", "float", false, "Y used when --raycast is false (default region min Y)."),
				doc_param("margin", "float", false, "Seating-ray top margin (default 1.0)."),
				doc_param("max_drop", "float", false, "Seating-ray reach below the region (default 1000)."),
				doc_param("min_slope", "float", false, "Filter: min surface slope in degrees (default 0)."),
				doc_param("max_slope", "float", false, "Filter: max surface slope in degrees (default 180)."),
				doc_param("min_height", "float", false, "Filter: min world Y."),
				doc_param("max_height", "float", false, "Filter: max world Y."),
				doc_param("noise_threshold", "float", false, "Filter: noise-value cutoff (enables the noise mask)."),
				doc_param("noise_frequency", "float", false, "Noise-mask frequency (default 0.05)."),
				doc_param("noise_seed", "int", false, "Noise-mask seed (defaults to --seed)."),
				doc_param("align_to_normal", "bool", false, "Orient to surface normal (default false)."),
				doc_param("yaw_random", "bool", false, "Random yaw per instance (default true)."),
				doc_param("scale_min", "float", false, "Min uniform scale jitter (default 1.0)."),
				doc_param("scale_max", "float", false, "Max uniform scale jitter (default 1.0)."),
				doc_param("emit", "String", false, "'multimesh' (default, one draw call) or 'scene' (real nodes)."),
				doc_param("mesh_type", "String", false, "multimesh: primitive mesh class (BoxMesh, SphereMesh, ...; default BoxMesh)."),
				doc_param("mesh_path", "String", false, "multimesh: path to a Mesh resource to instance (overrides --mesh-type)."),
				doc_param("mesh_from", "NodePath", false, "multimesh: borrow the mesh from this MeshInstance3D."),
				doc_param("scene", "String", false, "scene emit: PackedScene path to instantiate at each point (required for --emit scene)."),
				doc_param("max_instances", "int", false, "scene emit: refuse if more nodes than this would be created (default 2000)."),
				doc_param("parent_path", "NodePath", false, "Parent for the emitted node(s) (default '.'). --parent is an alias."),
				doc_param("name", "String", false, "Name for the emitted container/instance (default 'PCG_Scatter')."),
			],
		},
		"pcg.relax": {
			"description": "Laplacian smoothing of a point graph: move each point toward the average of its edge-neighbours over N iterations (de-clump a scatter, organic-ize a grid). Pure data in/out, no scene mutation.",
			"params": [
				doc_param("points", "Array", true, "Non-empty JSON array of Vector3 points."),
				doc_param("edges", "Array", false, "JSON array of [i, j] index pairs defining neighbour links."),
				doc_param("fixed", "Array", false, "JSON array of point indices to pin in place."),
				doc_param("iterations", "int", false, "Smoothing passes (default 10)."),
				doc_param("strength", "float", false, "Per-pass lerp toward the neighbour mean, 0..1 (default 1.0)."),
			],
		},
	}
