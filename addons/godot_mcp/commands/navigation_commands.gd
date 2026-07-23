@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"navigation.setup_region": _setup_region,
		"navigation.bake_mesh": _bake_mesh,
		"navigation.setup_agent": _setup_agent,
		"navigation.set_layers": _set_layers,
		"navigation.get_info": _get_info,
		"navigation.query_path": _query_path,
		"navigation.add_link": _add_link,
	}


## Detect whether a node lives in a 3D context (true) or 2D context (false).
func _is_3d_context(node: Node) -> bool:
	var n := node
	while n != null:
		if n is Node3D:
			return true
		if n is Node2D:
			return false
		n = n.get_parent()
	return false


## Resolve the 2d/3d mode from the "mode" param ("2d"/"3d"/"auto") or context.
func _resolve_is_3d(params: Dictionary, node: Node) -> bool:
	match optional_string(params, "mode", "auto"):
		"2d": return false
		"3d": return true
		_: return _is_3d_context(node)


func _set_nav_layers_with_undo(node: Node, value: int) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set navigation layers")
	undo_redo.add_do_property(node, "navigation_layers", value)
	undo_redo.add_undo_property(node, "navigation_layers", node.get("navigation_layers"))
	undo_redo.commit_action()


func _is_navigation_node(node: Node) -> bool:
	return node is NavigationRegion2D or node is NavigationRegion3D \
		or node is NavigationAgent2D or node is NavigationAgent3D


# --- 1. setup_region --------------------------------------------------------

func _setup_region(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node at '%s'" % rp[0])

	if _resolve_is_3d(params, node):
		var region := NavigationRegion3D.new()
		region.name = optional_string(params, "name", "NavigationRegion3D")

		var nav_mesh := NavigationMesh.new()
		nav_mesh.agent_radius = float(params.get("agent_radius", 0.5))
		nav_mesh.agent_height = float(params.get("agent_height", 1.5))
		nav_mesh.agent_max_climb = float(params.get("agent_max_climb", 0.25))
		nav_mesh.agent_max_slope = float(params.get("agent_max_slope", 45.0))
		nav_mesh.cell_size = float(params.get("cell_size", 0.25))
		nav_mesh.cell_height = float(params.get("cell_height", 0.25))
		region.navigation_mesh = nav_mesh

		if params.has("navigation_layers"):
			region.navigation_layers = int(params["navigation_layers"])

		add_child_with_undo(node, region, root, "MCP: Add NavigationRegion3D")

		return success({
			"node_path": str(root.get_path_to(region)),
			"type": "NavigationRegion3D",
			"agent_radius": nav_mesh.agent_radius,
			"agent_height": nav_mesh.agent_height,
			"cell_size": nav_mesh.cell_size,
			"created": true,
		})
	else:
		var region := NavigationRegion2D.new()
		region.name = optional_string(params, "name", "NavigationRegion2D")

		var nav_poly := NavigationPolygon.new()
		if params.has("source_geometry_mode"):
			match str(params["source_geometry_mode"]):
				"root_node":
					nav_poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
				"groups_with_children":
					nav_poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
				"groups_explicit":
					nav_poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_GROUPS_EXPLICIT
		if params.has("cell_size"):
			nav_poly.cell_size = float(params["cell_size"])
		if params.has("agent_radius"):
			nav_poly.agent_radius = float(params["agent_radius"])
		region.navigation_polygon = nav_poly

		if params.has("navigation_layers"):
			region.navigation_layers = int(params["navigation_layers"])

		add_child_with_undo(node, region, root, "MCP: Add NavigationRegion2D")

		return success({
			"node_path": str(root.get_path_to(region)),
			"type": "NavigationRegion2D",
			"cell_size": nav_poly.cell_size,
			"created": true,
		})


# --- 2. bake_mesh -----------------------------------------------------------

func _bake_mesh(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node at '%s'" % rp[0])

	var node_path := str(root.get_path_to(node))

	if node is NavigationRegion3D:
		var region := node as NavigationRegion3D
		if region.navigation_mesh == null:
			return error_invalid_params("NavigationRegion3D has no NavigationMesh resource")
		region.bake_navigation_mesh()
		EditorInterface.mark_scene_as_unsaved()
		return success({
			"node_path": node_path,
			"type": "NavigationRegion3D",
			"baked": true,
		})

	elif node is NavigationRegion2D:
		var region := node as NavigationRegion2D
		if region.navigation_polygon == null:
			region.navigation_polygon = NavigationPolygon.new()

		if params.has("outline"):
			var outline := PackedVector2Array()
			for point: Variant in params["outline"]:
				if point is Array and (point as Array).size() >= 2:
					outline.append(Vector2(float(point[0]), float(point[1])))
				elif point is Dictionary:
					outline.append(Vector2(float(point.get("x", 0)), float(point.get("y", 0))))
			if outline.size() < 3:
				return error_invalid_params("Outline must have at least 3 vertices")
			var nav_poly := region.navigation_polygon
			while nav_poly.get_outline_count() > 0:
				nav_poly.remove_outline(0)
			nav_poly.add_outline(outline)
			nav_poly.make_polygons_from_outlines()
			EditorInterface.mark_scene_as_unsaved()
			return success({
				"node_path": node_path,
				"type": "NavigationRegion2D",
				"outline_vertices": outline.size(),
				"baked": true,
			})
		else:
			region.bake_navigation_polygon()
			EditorInterface.mark_scene_as_unsaved()
			return success({
				"node_path": node_path,
				"type": "NavigationRegion2D",
				"baked": true,
			})

	return error_invalid_params("Node '%s' is not a NavigationRegion2D or NavigationRegion3D" % rp[0])


# --- 3. setup_agent ---------------------------------------------------------

func _setup_agent(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node at '%s'" % rp[0])

	var is_3d := _resolve_is_3d(params, node)
	var agent_name := optional_string(params, "name", "NavigationAgent3D" if is_3d else "NavigationAgent2D")

	if is_3d:
		var agent := NavigationAgent3D.new()
		agent.name = agent_name
		_apply_agent_props(agent, params)
		add_child_with_undo(node, agent, root, "MCP: Add NavigationAgent3D")
		return success({
			"node_path": str(root.get_path_to(agent)),
			"type": "NavigationAgent3D",
			"radius": agent.radius,
			"max_speed": agent.max_speed,
			"avoidance_enabled": agent.avoidance_enabled,
			"navigation_layers": agent.navigation_layers,
			"created": true,
		})
	else:
		var agent := NavigationAgent2D.new()
		agent.name = agent_name
		_apply_agent_props(agent, params)
		add_child_with_undo(node, agent, root, "MCP: Add NavigationAgent2D")
		return success({
			"node_path": str(root.get_path_to(agent)),
			"type": "NavigationAgent2D",
			"radius": agent.radius,
			"max_speed": agent.max_speed,
			"avoidance_enabled": agent.avoidance_enabled,
			"navigation_layers": agent.navigation_layers,
			"created": true,
		})


func _apply_agent_props(agent: Node, params: Dictionary) -> void:
	if params.has("path_desired_distance"):
		agent.path_desired_distance = float(params["path_desired_distance"])
	if params.has("target_desired_distance"):
		agent.target_desired_distance = float(params["target_desired_distance"])
	if params.has("radius"):
		agent.radius = float(params["radius"])
	if params.has("neighbor_distance"):
		agent.neighbor_distance = float(params["neighbor_distance"])
	if params.has("max_neighbors"):
		agent.max_neighbors = int(params["max_neighbors"])
	if params.has("max_speed"):
		agent.max_speed = float(params["max_speed"])
	if params.has("avoidance_enabled"):
		agent.avoidance_enabled = bool(params["avoidance_enabled"])
	if params.has("navigation_layers"):
		agent.navigation_layers = int(params["navigation_layers"])


# --- 4. set_layers ----------------------------------------------------------

func _set_layers(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node at '%s'" % rp[0])
	if not _is_navigation_node(node):
		return error_invalid_params("Node '%s' is not a navigation region or agent" % rp[0])

	var node_path := str(root.get_path_to(node))

	if params.has("layers"):
		var value := int(params["layers"])
		_set_nav_layers_with_undo(node, value)
		return success({"node_path": node_path, "navigation_layers": value, "updated": true})

	if params.has("layer_bits"):
		var bits: Array = params["layer_bits"]
		var value := 0
		for bit: Variant in bits:
			var n := int(bit)
			if n >= 1 and n <= 32:
				value |= (1 << (n - 1))
		_set_nav_layers_with_undo(node, value)
		return success({"node_path": node_path, "navigation_layers": value, "layer_bits": bits, "updated": true})

	if params.has("layer_names"):
		var names: Array = params["layer_names"]
		var is_2d := node is NavigationRegion2D or node is NavigationAgent2D
		var prefix := "layer_names/2d_navigation/layer_" if is_2d else "layer_names/3d_navigation/layer_"
		var value := 0
		for i in range(1, 33):
			var key := prefix + str(i)
			if ProjectSettings.has_setting(key):
				var layer_name := str(ProjectSettings.get_setting(key))
				if layer_name in names:
					value |= (1 << (i - 1))
		_set_nav_layers_with_undo(node, value)
		return success({"node_path": node_path, "navigation_layers": value, "layer_names": names, "updated": true})

	return error_invalid_params("Must provide 'layers' (bitmask), 'layer_bits' (array of layer numbers), or 'layer_names' (array of named layers)")


# --- 5. get_info ------------------------------------------------------------

func _get_info(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node at '%s'" % rp[0])

	var regions: Array = []
	var agents: Array = []
	_collect_navigation_nodes(node, root, regions, agents)

	var layer_names_2d: Dictionary = {}
	var layer_names_3d: Dictionary = {}
	for i in range(1, 33):
		var key_2d := "layer_names/2d_navigation/layer_" + str(i)
		var key_3d := "layer_names/3d_navigation/layer_" + str(i)
		if ProjectSettings.has_setting(key_2d):
			var name_2d := str(ProjectSettings.get_setting(key_2d))
			if not name_2d.is_empty():
				layer_names_2d[i] = name_2d
		if ProjectSettings.has_setting(key_3d):
			var name_3d := str(ProjectSettings.get_setting(key_3d))
			if not name_3d.is_empty():
				layer_names_3d[i] = name_3d

	return success({
		"node_path": str(root.get_path_to(node)),
		"regions": regions,
		"agents": agents,
		"region_count": regions.size(),
		"agent_count": agents.size(),
		"layer_names_2d": layer_names_2d,
		"layer_names_3d": layer_names_3d,
	})


func _collect_navigation_nodes(node: Node, root: Node, regions: Array, agents: Array) -> void:
	if node is NavigationRegion2D:
		var region := node as NavigationRegion2D
		var region_info := {
			"path": str(root.get_path_to(region)),
			"type": "NavigationRegion2D",
			"enabled": region.enabled,
			"navigation_layers": region.navigation_layers,
			"has_polygon": region.navigation_polygon != null,
		}
		if region.navigation_polygon != null:
			var nav_poly := region.navigation_polygon
			region_info["outline_count"] = nav_poly.get_outline_count()
			region_info["polygon_count"] = nav_poly.get_polygon_count()
			region_info["cell_size"] = nav_poly.cell_size
			region_info["agent_radius"] = nav_poly.agent_radius
		regions.append(region_info)

	elif node is NavigationRegion3D:
		var region := node as NavigationRegion3D
		var region_info := {
			"path": str(root.get_path_to(region)),
			"type": "NavigationRegion3D",
			"enabled": region.enabled,
			"navigation_layers": region.navigation_layers,
			"has_mesh": region.navigation_mesh != null,
		}
		if region.navigation_mesh != null:
			var nav_mesh := region.navigation_mesh
			region_info["agent_radius"] = nav_mesh.agent_radius
			region_info["agent_height"] = nav_mesh.agent_height
			region_info["agent_max_climb"] = nav_mesh.agent_max_climb
			region_info["agent_max_slope"] = nav_mesh.agent_max_slope
			region_info["cell_size"] = nav_mesh.cell_size
			region_info["cell_height"] = nav_mesh.cell_height
		regions.append(region_info)

	if node is NavigationAgent2D:
		var agent := node as NavigationAgent2D
		agents.append({
			"path": str(root.get_path_to(agent)),
			"type": "NavigationAgent2D",
			"radius": agent.radius,
			"max_speed": agent.max_speed,
			"path_desired_distance": agent.path_desired_distance,
			"target_desired_distance": agent.target_desired_distance,
			"neighbor_distance": agent.neighbor_distance,
			"max_neighbors": agent.max_neighbors,
			"avoidance_enabled": agent.avoidance_enabled,
			"navigation_layers": agent.navigation_layers,
		})

	elif node is NavigationAgent3D:
		var agent := node as NavigationAgent3D
		agents.append({
			"path": str(root.get_path_to(agent)),
			"type": "NavigationAgent3D",
			"radius": agent.radius,
			"max_speed": agent.max_speed,
			"path_desired_distance": agent.path_desired_distance,
			"target_desired_distance": agent.target_desired_distance,
			"neighbor_distance": agent.neighbor_distance,
			"max_neighbors": agent.max_neighbors,
			"avoidance_enabled": agent.avoidance_enabled,
			"navigation_layers": agent.navigation_layers,
		})

	for child in node.get_children():
		_collect_navigation_nodes(child, root, regions, agents)


# --- 6. query_path (edit-time NavigationServer3D path) ----------------------

func _nav_v3(params: Dictionary, key: String) -> Vector3:
	return vec3_param(params, key)


## Query a path across the baked navmesh at edit time (3D). The world nav map syncs on the
## physics step, so we force an update first; an empty result usually means no baked region
## reaches between the points (or the navmesh isn't baked yet).
func _query_path(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("navigation.query_path is 3D-only (root is not a Node3D); for 2D query a running NavigationAgent2D via runtime.eval")
	if not params.has("from") or not params.has("to"):
		return error_invalid_params("Provide from and to (Vector3)")

	var from := _nav_v3(params, "from")
	var to := _nav_v3(params, "to")
	var optimize := optional_bool(params, "optimize", true)
	var layers := optional_int(params, "navigation_layers", 1)

	var map: RID = (root as Node3D).get_world_3d().get_navigation_map()
	NavigationServer3D.map_force_update(map)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from, to, optimize, layers)

	var pts: Array = []
	var length := 0.0
	for i in path.size():
		pts.append(str(path[i]))
		if i > 0:
			length += path[i].distance_to(path[i - 1])
	return success({
		"from": str(from),
		"to": str(to),
		"point_count": path.size(),
		"reachable": path.size() >= 2,
		"length": length,
		"path": pts,
	})


# --- 7. add_link (off-mesh connection) --------------------------------------

func _add_link(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))
	if not params.has("from") or not params.has("to"):
		return error_invalid_params("Provide from and to (link endpoints)")

	var is_3d := _resolve_is_3d(params, parent)
	if is_3d:
		var link := NavigationLink3D.new()
		link.name = optional_string(params, "name", "NavigationLink3D")
		link.start_position = _nav_v3(params, "from")
		link.end_position = _nav_v3(params, "to")
		link.bidirectional = optional_bool(params, "bidirectional", true)
		if params.has("navigation_layers"):
			link.navigation_layers = optional_int(params, "navigation_layers", 1)
		add_child_with_undo(parent, link, root, "MCP: Add NavigationLink3D")
		return success({"node_path": str(root.get_path_to(link)), "type": "NavigationLink3D", "start": str(link.start_position), "end": str(link.end_position), "bidirectional": link.bidirectional})
	else:
		var link := NavigationLink2D.new()
		link.name = optional_string(params, "name", "NavigationLink2D")
		var f := _nav_v3(params, "from")
		var t := _nav_v3(params, "to")
		link.start_position = Vector2(f.x, f.y)
		link.end_position = Vector2(t.x, t.y)
		link.bidirectional = optional_bool(params, "bidirectional", true)
		if params.has("navigation_layers"):
			link.navigation_layers = optional_int(params, "navigation_layers", 1)
		add_child_with_undo(parent, link, root, "MCP: Add NavigationLink2D")
		return success({"node_path": str(root.get_path_to(link)), "type": "NavigationLink2D", "start": str(link.start_position), "end": str(link.end_position), "bidirectional": link.bidirectional})


func get_command_docs() -> Dictionary:
	return {
		"navigation.setup_region": {
			"description": "Add a NavigationRegion2D/3D (with a fresh NavigationMesh or NavigationPolygon) as a child of --node-path. 2D-vs-3D is chosen by --mode or the node's context.",
			"params": [
				doc_param("node_path", "NodePath", true, "Parent node to add the region under."),
				doc_param("mode", "String", false, "'2d', '3d', or 'auto' (default; inferred from the node's 2D/3D ancestry)."),
				doc_param("name", "String", false, "Region node name (defaults to NavigationRegion2D/3D)."),
				doc_param("agent_radius", "float", false, "Baking agent radius (3D default 0.5; 2D optional)."),
				doc_param("agent_height", "float", false, "3D baking agent height (default 1.5)."),
				doc_param("agent_max_climb", "float", false, "3D max step height the agent climbs (default 0.25)."),
				doc_param("agent_max_slope", "float", false, "3D max walkable slope in degrees (default 45)."),
				doc_param("cell_size", "float", false, "Navmesh cell size (3D default 0.25; 2D optional)."),
				doc_param("cell_height", "float", false, "3D navmesh cell height (default 0.25)."),
				doc_param("navigation_layers", "int", false, "Navigation layers bitmask for the region."),
				doc_param("source_geometry_mode", "String", false, "2D only: 'root_node', 'groups_with_children', or 'groups_explicit'."),
			],
		},
		"navigation.bake_mesh": {
			"description": "Bake the navmesh for a NavigationRegion2D/3D. 3D bakes from child geometry (see the headless-bake gotcha: bake in a windowed editor). 2D with --outline builds the polygon from an explicit outline; without, bakes from source geometry.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target NavigationRegion2D or NavigationRegion3D."),
				doc_param("outline", "Array", false, "2D only: array of >=3 outline points ([x,y] pairs or {x,y} objects); replaces existing outlines and rebuilds polygons."),
			],
		},
		"navigation.setup_agent": {
			"description": "Add a NavigationAgent2D/3D as a child of --node-path (typically the moving body). 2D-vs-3D by --mode or context.",
			"params": [
				doc_param("node_path", "NodePath", true, "Parent node to add the agent under."),
				doc_param("mode", "String", false, "'2d', '3d', or 'auto' (default)."),
				doc_param("name", "String", false, "Agent node name (defaults to NavigationAgent2D/3D)."),
				doc_param("path_desired_distance", "float", false, "Distance to a path point before advancing."),
				doc_param("target_desired_distance", "float", false, "Distance to the target that counts as arrived."),
				doc_param("radius", "float", false, "Agent avoidance radius."),
				doc_param("neighbor_distance", "float", false, "Avoidance neighbor search distance."),
				doc_param("max_neighbors", "int", false, "Max avoidance neighbors considered."),
				doc_param("max_speed", "float", false, "Max speed used by avoidance."),
				doc_param("avoidance_enabled", "bool", false, "Enable RVO avoidance."),
				doc_param("navigation_layers", "int", false, "Agent navigation layers bitmask."),
			],
		},
		"navigation.set_layers": {
			"description": "Set navigation_layers on a region or agent. Provide exactly one of --layers, --layer-bits, or --layer-names. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target NavigationRegion2D/3D or NavigationAgent2D/3D."),
				doc_param("layers", "int", false, "Raw bitmask. Use this OR --layer-bits OR --layer-names."),
				doc_param("layer_bits", "Array", false, "Array of layer numbers 1-32, OR'd into a mask. Use instead of --layers."),
				doc_param("layer_names", "Array", false, "Array of named layers (resolved via ProjectSettings 2d/3d layer names). Use instead of --layers."),
			],
		},
		"navigation.get_info": {
			"description": "Recursively list NavigationRegion/Agent nodes under --node-path with their key settings, plus the project's named navigation layers.",
			"params": [
				doc_param("node_path", "NodePath", true, "Subtree root to scan."),
			],
		},
		"navigation.query_path": {
			"description": "Query a path across the baked navmesh at edit time (3D only; forces a nav-map update first). An empty/short result usually means no baked region connects the points (see the headless-bake gotcha).",
			"params": [
				doc_param("from", "Vector3", true, "Start position (global)."),
				doc_param("to", "Vector3", true, "Goal position (global)."),
				doc_param("optimize", "bool", false, "Corridor-optimize the returned path (default true)."),
				doc_param("navigation_layers", "int", false, "Navigation layers bitmask to query (default 1)."),
			],
		},
		"navigation.add_link": {
			"description": "Add a NavigationLink2D/3D off-mesh connection between two points (e.g. a jump or ladder). 2D-vs-3D by --mode or the parent's context; 2D uses the x,y of the given points. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add the link under (default '.'). --parent is an alias."),
				doc_param("from", "Vector3", true, "Link start position."),
				doc_param("to", "Vector3", true, "Link end position."),
				doc_param("mode", "String", false, "'2d', '3d', or 'auto' (default)."),
				doc_param("name", "String", false, "Link node name (defaults to NavigationLink2D/3D)."),
				doc_param("bidirectional", "bool", false, "Traversable both ways (default true)."),
				doc_param("navigation_layers", "int", false, "Link navigation layers bitmask (default 1)."),
			],
		},
	}
