@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"physics.setup_collision": _setup_collision,
		"physics.set_layers": _set_layers,
		"physics.get_layers": _get_layers,
		"physics.add_raycast": _add_raycast,
		"physics.setup_body": _setup_body,
		"physics.get_collision_info": _get_collision_info,
		"physics.add_joint": _add_joint,
	}


# --- Dimension / layer helpers ----------------------------------------------

## Detect whether a node lives in a 2D or 3D context. Returns "2d", "3d", or "".
func _detect_dimension(node: Node) -> String:
	var n := node
	while n != null:
		if n is Node2D or n is Control:
			return "2d"
		if n is Node3D:
			return "3d"
		n = n.get_parent()
	return ""


func _layer_name(dim: String, layer_index: int) -> String:
	var key := "layer_names/%s_physics/layer_%d" % [dim, layer_index]
	if ProjectSettings.has_setting(key):
		var val: Variant = ProjectSettings.get_setting(key)
		if val is String and not (val as String).is_empty():
			return val as String
	return ""


func _bitmask_info(bitmask: int, dim: String) -> Array:
	var layers: Array = []
	for i in range(1, 33):
		if bitmask & (1 << (i - 1)):
			var entry: Dictionary = {"layer": i}
			var name := _layer_name(dim, i)
			if not name.is_empty():
				entry["name"] = name
			layers.append(entry)
	return layers


## Parse a layer value: an int bitmask or an array of 1-based layer numbers.
func _parse_layer_value(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	if value is Array:
		var bitmask := 0
		for layer_num: Variant in value:
			var n := int(layer_num)
			if n >= 1 and n <= 32:
				bitmask |= (1 << (n - 1))
		return bitmask
	return int(value)


# --- 1. setup_collision -----------------------------------------------------

const _VALID_PARENTS_2D := ["PhysicsBody2D", "Area2D", "StaticBody2D", "CharacterBody2D", "RigidBody2D", "AnimatableBody2D"]
const _VALID_PARENTS_3D := ["PhysicsBody3D", "Area3D", "StaticBody3D", "CharacterBody3D", "RigidBody3D", "AnimatableBody3D"]


func _setup_collision(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var rs := require_string(params, "shape")
	if rs[1] != null:
		return rs[1]
	var shape_name: String = rs[0]

	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")

	var dim := _detect_dimension(node)
	if dim.is_empty():
		dim = optional_string(params, "dimension", "2d")

	var valid_parents := _VALID_PARENTS_2D if dim == "2d" else _VALID_PARENTS_3D
	var is_valid_parent := false
	for vp: String in valid_parents:
		if node.is_class(vp):
			is_valid_parent = true
			break
	if not is_valid_parent:
		return error_invalid_params("Node '%s' (%s) is not a physics body or area. CollisionShape should be added to a PhysicsBody or Area node." % [rp[0], node.get_class()])

	if dim == "2d":
		var shape := _build_shape_2d(shape_name, params)
		if shape == null:
			return error_invalid_params("Unknown 2D shape: '%s'. Available: rectangle, circle, capsule, segment, custom" % shape_name)
		var collision_node := CollisionShape2D.new()
		collision_node.shape = shape
		collision_node.name = "CollisionShape"
		collision_node.disabled = optional_bool(params, "disabled", false)
		collision_node.one_way_collision = optional_bool(params, "one_way_collision", false)
		add_child_with_undo(node, collision_node, root, "MCP: Add CollisionShape2D to %s" % node.name)
		return success({
			"node_path": str(root.get_path_to(collision_node)),
			"shape_type": shape.get_class(),
			"dimension": "2D",
		})
	else:
		var shape := _build_shape_3d(shape_name, params)
		if shape == null:
			return error_invalid_params("Unknown 3D shape: '%s'. Available: box, sphere, capsule, cylinder, convex" % shape_name)
		var collision_node := CollisionShape3D.new()
		collision_node.shape = shape
		collision_node.name = "CollisionShape"
		collision_node.disabled = optional_bool(params, "disabled", false)
		add_child_with_undo(node, collision_node, root, "MCP: Add CollisionShape3D to %s" % node.name)
		return success({
			"node_path": str(root.get_path_to(collision_node)),
			"shape_type": shape.get_class(),
			"dimension": "3D",
		})


func _build_shape_2d(shape_name: String, params: Dictionary) -> Shape2D:
	match shape_name:
		"rectangle", "rect":
			var s := RectangleShape2D.new()
			s.size = Vector2(float(params.get("width", 32.0)), float(params.get("height", 32.0)))
			return s
		"circle":
			var s := CircleShape2D.new()
			s.radius = float(params.get("radius", 16.0))
			return s
		"capsule":
			var s := CapsuleShape2D.new()
			s.radius = float(params.get("radius", 16.0))
			s.height = float(params.get("height", 40.0))
			return s
		"segment":
			var s := SegmentShape2D.new()
			s.a = Vector2(float(params.get("ax", 0.0)), float(params.get("ay", 0.0)))
			s.b = Vector2(float(params.get("bx", 32.0)), float(params.get("by", 0.0)))
			return s
		"custom":
			var s := ConvexPolygonShape2D.new()
			var pool := PackedVector2Array()
			for p: Variant in params.get("points", []):
				if p is Array and (p as Array).size() >= 2:
					pool.append(Vector2(float(p[0]), float(p[1])))
			if pool.size() >= 3:
				s.points = pool
			return s
	return null


func _build_shape_3d(shape_name: String, params: Dictionary) -> Shape3D:
	match shape_name:
		"box", "rectangle", "rect":
			var s := BoxShape3D.new()
			s.size = Vector3(float(params.get("width", 1.0)), float(params.get("height", 1.0)), float(params.get("depth", 1.0)))
			return s
		"sphere", "circle":
			var s := SphereShape3D.new()
			s.radius = float(params.get("radius", 0.5))
			return s
		"capsule":
			var s := CapsuleShape3D.new()
			s.radius = float(params.get("radius", 0.5))
			s.height = float(params.get("height", 2.0))
			return s
		"cylinder":
			var s := CylinderShape3D.new()
			s.radius = float(params.get("radius", 0.5))
			s.height = float(params.get("height", 2.0))
			return s
		"convex", "custom":
			var s := ConvexPolygonShape3D.new()
			var pool := PackedVector3Array()
			for p: Variant in params.get("points", []):
				if p is Array and (p as Array).size() >= 3:
					pool.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
			if pool.size() >= 4:
				s.points = pool
			return s
	return null


# --- 2. set_layers ----------------------------------------------------------

func _set_layers(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")
	if not "collision_layer" in node:
		return error_invalid_params("Node '%s' (%s) does not have collision_layer property" % [rp[0], node.get_class()])

	var changes: Dictionary = {}
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set physics layers on %s" % node.name)

	if params.has("collision_layer"):
		var new_layer := _parse_layer_value(params["collision_layer"])
		undo_redo.add_do_property(node, "collision_layer", new_layer)
		undo_redo.add_undo_property(node, "collision_layer", node.get("collision_layer"))
		changes["collision_layer"] = new_layer

	if params.has("collision_mask"):
		var new_mask := _parse_layer_value(params["collision_mask"])
		undo_redo.add_do_property(node, "collision_mask", new_mask)
		undo_redo.add_undo_property(node, "collision_mask", node.get("collision_mask"))
		changes["collision_mask"] = new_mask

	if changes.is_empty():
		return error_invalid_params("Must provide collision_layer and/or collision_mask")

	undo_redo.commit_action()

	var dim := _detect_dimension(node)
	if dim.is_empty():
		dim = "2d"

	var data: Dictionary = {"node_path": str(root.get_path_to(node))}
	if changes.has("collision_layer"):
		data["collision_layer"] = changes["collision_layer"]
		data["collision_layer_info"] = _bitmask_info(changes["collision_layer"], dim)
	if changes.has("collision_mask"):
		data["collision_mask"] = changes["collision_mask"]
		data["collision_mask_info"] = _bitmask_info(changes["collision_mask"], dim)
	return success(data)


# --- 3. get_layers ----------------------------------------------------------

func _get_layers(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")
	if not "collision_layer" in node:
		return error_invalid_params("Node '%s' (%s) does not have collision_layer property" % [rp[0], node.get_class()])

	var layer := int(node.get("collision_layer"))
	var mask := int(node.get("collision_mask"))
	var dim := _detect_dimension(node)
	if dim.is_empty():
		dim = "2d"

	return success({
		"node_path": str(root.get_path_to(node)),
		"type": node.get_class(),
		"collision_layer": layer,
		"collision_layer_info": _bitmask_info(layer, dim),
		"collision_mask": mask,
		"collision_mask_info": _bitmask_info(mask, dim),
	})


# --- 4. add_raycast ---------------------------------------------------------

func _add_raycast(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")

	var dim := _detect_dimension(node)
	if dim.is_empty():
		dim = optional_string(params, "dimension", "2d")

	var ray_name := optional_string(params, "name", "RayCast")
	var enabled := optional_bool(params, "enabled", true)
	var collision_mask := optional_int(params, "collision_mask", 1)
	var collide_with_areas := optional_bool(params, "collide_with_areas", false)
	var collide_with_bodies := optional_bool(params, "collide_with_bodies", true)
	var hit_from_inside := optional_bool(params, "hit_from_inside", false)

	if dim == "2d":
		var ray := RayCast2D.new()
		ray.name = ray_name
		ray.enabled = enabled
		ray.collision_mask = collision_mask
		ray.collide_with_areas = collide_with_areas
		ray.collide_with_bodies = collide_with_bodies
		ray.hit_from_inside = hit_from_inside
		var tx := float(params.get("target_x", 0.0))
		var ty := float(params.get("target_y", 50.0))
		ray.target_position = Vector2(tx, ty)
		add_child_with_undo(node, ray, root, "MCP: Add RayCast2D to %s" % node.name)
		return success({
			"node_path": str(root.get_path_to(ray)),
			"type": "RayCast2D",
			"target_position": "Vector2(%s, %s)" % [tx, ty],
			"collision_mask": collision_mask,
		})
	else:
		var ray := RayCast3D.new()
		ray.name = ray_name
		ray.enabled = enabled
		ray.collision_mask = collision_mask
		ray.collide_with_areas = collide_with_areas
		ray.collide_with_bodies = collide_with_bodies
		ray.hit_from_inside = hit_from_inside
		var tx := float(params.get("target_x", 0.0))
		var ty := float(params.get("target_y", -1.0))
		var tz := float(params.get("target_z", 0.0))
		ray.target_position = Vector3(tx, ty, tz)
		add_child_with_undo(node, ray, root, "MCP: Add RayCast3D to %s" % node.name)
		return success({
			"node_path": str(root.get_path_to(ray)),
			"type": "RayCast3D",
			"target_position": "Vector3(%s, %s, %s)" % [tx, ty, tz],
			"collision_mask": collision_mask,
		})


# --- 5. setup_body ----------------------------------------------------------

func _setup_body(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Setup physics body %s" % node.name)
	var applied: Dictionary = {}

	if node is CharacterBody2D or node is CharacterBody3D:
		_apply_float(node, params, "floor_max_angle", undo_redo, applied)
		_apply_float(node, params, "floor_snap_length", undo_redo, applied)
		_apply_float(node, params, "wall_min_slide_angle", undo_redo, applied)
		_apply_bool(node, params, "floor_stop_on_slope", undo_redo, applied)
		_apply_bool(node, params, "slide_on_ceiling", undo_redo, applied)
		_apply_int(node, params, "max_slides", undo_redo, applied)
		if params.has("motion_mode"):
			var mode_str := str(params["motion_mode"])
			var mode_val := 0
			match mode_str.to_lower():
				"grounded":
					mode_val = 0  # MOTION_MODE_GROUNDED
				"floating":
					mode_val = 1  # MOTION_MODE_FLOATING
				_:
					mode_val = int(params["motion_mode"])
			undo_redo.add_do_property(node, "motion_mode", mode_val)
			undo_redo.add_undo_property(node, "motion_mode", node.get("motion_mode"))
			applied["motion_mode"] = mode_str

	elif node is RigidBody2D or node is RigidBody3D:
		_apply_float(node, params, "mass", undo_redo, applied)
		_apply_float(node, params, "gravity_scale", undo_redo, applied)
		_apply_float(node, params, "linear_damp", undo_redo, applied)
		_apply_float(node, params, "angular_damp", undo_redo, applied)
		_apply_bool(node, params, "freeze", undo_redo, applied)
		_apply_bool(node, params, "contact_monitor", undo_redo, applied)
		_apply_int(node, params, "max_contacts_reported", undo_redo, applied)
		if params.has("freeze_mode"):
			var mode_str := str(params["freeze_mode"])
			var mode_val := 0
			match mode_str.to_lower():
				"static":
					mode_val = 0  # FREEZE_MODE_STATIC
				"kinematic":
					mode_val = 1  # FREEZE_MODE_KINEMATIC
				_:
					mode_val = int(params["freeze_mode"])
			undo_redo.add_do_property(node, "freeze_mode", mode_val)
			undo_redo.add_undo_property(node, "freeze_mode", node.get("freeze_mode"))
			applied["freeze_mode"] = mode_str
		if params.has("continuous_cd"):
			if node is RigidBody2D:
				var ccd_str := str(params["continuous_cd"])
				var ccd_val := 0
				match ccd_str.to_lower():
					"disabled":
						ccd_val = RigidBody2D.CCD_MODE_DISABLED
					"cast_ray":
						ccd_val = RigidBody2D.CCD_MODE_CAST_RAY
					"cast_shape":
						ccd_val = RigidBody2D.CCD_MODE_CAST_SHAPE
					_:
						ccd_val = int(params["continuous_cd"])
				undo_redo.add_do_property(node, "continuous_cd", ccd_val)
				undo_redo.add_undo_property(node, "continuous_cd", node.get("continuous_cd"))
				applied["continuous_cd"] = ccd_str
			else:
				var new_val := bool(params["continuous_cd"])
				undo_redo.add_do_property(node, "continuous_cd", new_val)
				undo_redo.add_undo_property(node, "continuous_cd", node.get("continuous_cd"))
				applied["continuous_cd"] = new_val

	elif node is StaticBody2D or node is StaticBody3D or node is AnimatableBody2D or node is AnimatableBody3D:
		if params.has("physics_material_override"):
			return error_invalid_params("Use node.add_resource to set physics_material_override")
	else:
		return error_invalid_params("Node '%s' (%s) is not a recognized physics body type. Supported: CharacterBody2D/3D, RigidBody2D/3D, StaticBody2D/3D, AnimatableBody2D/3D" % [rp[0], node.get_class()])

	if applied.is_empty():
		undo_redo.commit_action()
		return error_invalid_params("No valid properties provided for %s" % node.get_class())

	undo_redo.commit_action()
	return success({
		"node_path": str(root.get_path_to(node)),
		"type": node.get_class(),
		"applied": applied,
	})


func _apply_float(node: Node, params: Dictionary, key: String, undo_redo: EditorUndoRedoManager, applied: Dictionary) -> void:
	if params.has(key):
		var new_val := float(params[key])
		undo_redo.add_do_property(node, key, new_val)
		undo_redo.add_undo_property(node, key, node.get(key))
		applied[key] = new_val


func _apply_int(node: Node, params: Dictionary, key: String, undo_redo: EditorUndoRedoManager, applied: Dictionary) -> void:
	if params.has(key):
		var new_val := int(params[key])
		undo_redo.add_do_property(node, key, new_val)
		undo_redo.add_undo_property(node, key, node.get(key))
		applied[key] = new_val


func _apply_bool(node: Node, params: Dictionary, key: String, undo_redo: EditorUndoRedoManager, applied: Dictionary) -> void:
	if params.has(key):
		var new_val := bool(params[key])
		undo_redo.add_do_property(node, key, new_val)
		undo_redo.add_undo_property(node, key, node.get(key))
		applied[key] = new_val


# --- 6. get_collision_info --------------------------------------------------

func _get_collision_info(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(rp[0])
	if node == null:
		return error_not_found("Node '%s'" % rp[0], "Use scene.tree to see available nodes")

	var include_children := optional_bool(params, "include_children", true)
	var info: Dictionary = {
		"node_path": str(root.get_path_to(node)),
		"type": node.get_class(),
	}

	if "collision_layer" in node:
		var dim := _detect_dimension(node)
		if dim.is_empty():
			dim = "2d"
		info["collision_layer"] = int(node.get("collision_layer"))
		info["collision_layer_info"] = _bitmask_info(int(node.get("collision_layer")), dim)
		info["collision_mask"] = int(node.get("collision_mask"))
		info["collision_mask_info"] = _bitmask_info(int(node.get("collision_mask")), dim)

	if node is CharacterBody2D or node is CharacterBody3D:
		info["body_settings"] = {
			"motion_mode": node.motion_mode,
			"floor_stop_on_slope": node.floor_stop_on_slope,
			"floor_max_angle": node.floor_max_angle,
			"floor_snap_length": node.floor_snap_length,
			"wall_min_slide_angle": node.wall_min_slide_angle,
			"max_slides": node.max_slides,
			"slide_on_ceiling": node.slide_on_ceiling,
		}
	elif node is RigidBody2D or node is RigidBody3D:
		info["body_settings"] = {
			"mass": node.mass,
			"gravity_scale": node.gravity_scale,
			"linear_damp": node.linear_damp,
			"angular_damp": node.angular_damp,
			"freeze": node.freeze,
			"freeze_mode": node.freeze_mode,
			"contact_monitor": node.contact_monitor,
			"max_contacts_reported": node.max_contacts_reported,
		}

	var shapes: Array = []
	var raycasts: Array = []
	var nodes_to_check: Array[Node] = [node]
	if include_children:
		var queue: Array[Node] = [node]
		while not queue.is_empty():
			var current: Node = queue.pop_front()
			for child in current.get_children():
				nodes_to_check.append(child)
				queue.append(child)

	for check_node: Node in nodes_to_check:
		if check_node is CollisionShape2D:
			var cs := check_node as CollisionShape2D
			var shape_info: Dictionary = {
				"node_path": str(root.get_path_to(cs)),
				"disabled": cs.disabled,
				"one_way_collision": cs.one_way_collision,
			}
			if cs.shape != null:
				shape_info["shape_type"] = cs.shape.get_class()
				if cs.shape is RectangleShape2D:
					shape_info["size"] = "Vector2(%s, %s)" % [(cs.shape as RectangleShape2D).size.x, (cs.shape as RectangleShape2D).size.y]
				elif cs.shape is CircleShape2D:
					shape_info["radius"] = (cs.shape as CircleShape2D).radius
				elif cs.shape is CapsuleShape2D:
					shape_info["radius"] = (cs.shape as CapsuleShape2D).radius
					shape_info["height"] = (cs.shape as CapsuleShape2D).height
			shapes.append(shape_info)

		elif check_node is CollisionShape3D:
			var cs := check_node as CollisionShape3D
			var shape_info: Dictionary = {
				"node_path": str(root.get_path_to(cs)),
				"disabled": cs.disabled,
			}
			if cs.shape != null:
				shape_info["shape_type"] = cs.shape.get_class()
				if cs.shape is BoxShape3D:
					var sz := (cs.shape as BoxShape3D).size
					shape_info["size"] = "Vector3(%s, %s, %s)" % [sz.x, sz.y, sz.z]
				elif cs.shape is SphereShape3D:
					shape_info["radius"] = (cs.shape as SphereShape3D).radius
				elif cs.shape is CapsuleShape3D:
					shape_info["radius"] = (cs.shape as CapsuleShape3D).radius
					shape_info["height"] = (cs.shape as CapsuleShape3D).height
				elif cs.shape is CylinderShape3D:
					shape_info["radius"] = (cs.shape as CylinderShape3D).radius
					shape_info["height"] = (cs.shape as CylinderShape3D).height
			shapes.append(shape_info)

		elif check_node is CollisionPolygon2D:
			var cp := check_node as CollisionPolygon2D
			shapes.append({
				"node_path": str(root.get_path_to(cp)),
				"shape_type": "CollisionPolygon2D",
				"disabled": cp.disabled,
				"one_way_collision": cp.one_way_collision,
				"polygon_points": cp.polygon.size(),
			})

		elif check_node is CollisionPolygon3D:
			var cp := check_node as CollisionPolygon3D
			shapes.append({
				"node_path": str(root.get_path_to(cp)),
				"shape_type": "CollisionPolygon3D",
				"disabled": cp.disabled,
				"polygon_points": cp.polygon.size(),
			})

		elif check_node is RayCast2D:
			var ray := check_node as RayCast2D
			raycasts.append({
				"node_path": str(root.get_path_to(ray)),
				"type": "RayCast2D",
				"enabled": ray.enabled,
				"target_position": "Vector2(%s, %s)" % [ray.target_position.x, ray.target_position.y],
				"collision_mask": ray.collision_mask,
				"collide_with_areas": ray.collide_with_areas,
				"collide_with_bodies": ray.collide_with_bodies,
			})

		elif check_node is RayCast3D:
			var ray := check_node as RayCast3D
			raycasts.append({
				"node_path": str(root.get_path_to(ray)),
				"type": "RayCast3D",
				"enabled": ray.enabled,
				"target_position": "Vector3(%s, %s, %s)" % [ray.target_position.x, ray.target_position.y, ray.target_position.z],
				"collision_mask": ray.collision_mask,
				"collide_with_areas": ray.collide_with_areas,
				"collide_with_bodies": ray.collide_with_bodies,
			})

	info["collision_shapes"] = shapes
	info["raycasts"] = raycasts
	return success(info)


# --- 7. add_joint -----------------------------------------------------------

## Add a Joint3D/Joint2D between two physics bodies. node_a/node_b are NodePaths the joint
## resolves relative to itself — fiddly to wire through node.set, so we do it here.
func _add_joint(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var rt := require_string(params, "type")
	if rt[1] != null:
		return rt[1]
	var type: String = rt[0]
	var is3d := ClassDB.is_parent_class(type, "Joint3D")
	var is2d := ClassDB.is_parent_class(type, "Joint2D")
	if not (is3d or is2d) or not ClassDB.can_instantiate(type):
		return error_invalid_params("type must be an instantiable Joint3D/Joint2D subclass (PinJoint3D/HingeJoint3D/SliderJoint3D/ConeTwistJoint3D/Generic6DOFJoint3D, or PinJoint2D/GrooveJoint2D/DampedSpringJoint2D)")

	var joint: Node = ClassDB.instantiate(type)
	joint.name = optional_string(params, "name", type)
	if is3d:
		(joint as Node3D).position = _vec3(params, "position", Vector3.ZERO)
	else:
		(joint as Node2D).position = _vec2(params, "position", Vector2.ZERO)
	add_child_with_undo(parent, joint, root, "MCP: Add %s" % type)

	# Wire node_a/node_b now that the joint is in the tree (get_path_to needs it).
	# Resolve both paths before committing so a bad path can't leave a dangling action.
	var wired := {}
	var props := {}
	for key in ["node_a", "node_b"]:
		if params.has(key):
			var body := find_node_by_path(str(params[key]))
			if body == null:
				return error_not_found("%s node '%s'" % [key, params[key]])
			var np: NodePath = joint.get_path_to(body)
			props[key] = np
			wired[key] = str(np)
	if not props.is_empty():
		set_properties_with_undo(joint, props, "MCP: Wire %s bodies" % type)

	return success({"node_path": str(root.get_path_to(joint)), "type": type, "wired": wired})


func _vec3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


func _vec2(params: Dictionary, key: String, default: Vector2) -> Vector2:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is String:
		return PropertyParser.parse_value(v, TYPE_VECTOR2)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return default


func get_command_docs() -> Dictionary:
	return {
		"physics.setup_collision": {
			"description": "Add a CollisionShape2D/3D (with a built shape) under a physics body or area. 2D-vs-3D inferred from context, else --dimension. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target PhysicsBody/Area node to add the collision shape under."),
				doc_param("shape", "String", true, "2D: rectangle, circle, capsule, segment, custom. 3D: box, sphere, capsule, cylinder, convex."),
				doc_param("dimension", "String", false, "'2d' or '3d' fallback when context can't be inferred (default '2d')."),
				doc_param("disabled", "bool", false, "Create the shape disabled (default false)."),
				doc_param("one_way_collision", "bool", false, "2D only: enable one-way collision (default false)."),
				doc_param("width", "float", false, "Rectangle/box width (2D default 32; 3D default 1)."),
				doc_param("height", "float", false, "Rectangle/box/capsule/cylinder height (2D rect 32, capsule 40; 3D box 1, capsule/cylinder 2)."),
				doc_param("depth", "float", false, "3D box depth (default 1)."),
				doc_param("radius", "float", false, "Circle/sphere/capsule/cylinder radius (2D circle/capsule 16; 3D 0.5)."),
				doc_param("ax", "float", false, "2D segment endpoint A x (default 0)."),
				doc_param("ay", "float", false, "2D segment endpoint A y (default 0)."),
				doc_param("bx", "float", false, "2D segment endpoint B x (default 32)."),
				doc_param("by", "float", false, "2D segment endpoint B y (default 0)."),
				doc_param("points", "Array", false, "Convex/custom hull points: array of [x,y] (2D, >=3) or [x,y,z] (3D, >=4)."),
			],
		},
		"physics.set_layers": {
			"description": "Set collision_layer and/or collision_mask on a node. Provide at least one. Each accepts a bitmask int or an array of 1-based layer numbers. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node with a collision_layer property."),
				doc_param("collision_layer", "JSON", false, "New layer: bitmask int or array of layer numbers (1-32)."),
				doc_param("collision_mask", "JSON", false, "New mask: bitmask int or array of layer numbers (1-32)."),
			],
		},
		"physics.get_layers": {
			"description": "Read a node's collision_layer/collision_mask, decoded into per-layer entries with any named layers from ProjectSettings.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node with a collision_layer property."),
			],
		},
		"physics.add_raycast": {
			"description": "Add a RayCast2D/3D under a node. 2D-vs-3D inferred from context, else --dimension. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Parent node to add the raycast under."),
				doc_param("dimension", "String", false, "'2d' or '3d' fallback when context can't be inferred (default '2d')."),
				doc_param("name", "String", false, "Node name (default 'RayCast')."),
				doc_param("enabled", "bool", false, "Enable the raycast (default true)."),
				doc_param("collision_mask", "int", false, "Collision mask bitmask (default 1)."),
				doc_param("collide_with_areas", "bool", false, "Detect Areas (default false)."),
				doc_param("collide_with_bodies", "bool", false, "Detect bodies (default true)."),
				doc_param("hit_from_inside", "bool", false, "Report a hit when starting inside a shape (default false)."),
				doc_param("target_x", "float", false, "Local target x (default 0)."),
				doc_param("target_y", "float", false, "Local target y (2D default 50; 3D default -1)."),
				doc_param("target_z", "float", false, "3D local target z (default 0)."),
			],
		},
		"physics.setup_body": {
			"description": "Apply physics-body properties valid for the node's class (CharacterBody, RigidBody). Only the params you pass are set, atomically. Static/Animatable bodies take no props here (use node.add_resource for physics_material_override). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target physics body."),
				doc_param("floor_max_angle", "float", false, "CharacterBody: max floor angle (radians)."),
				doc_param("floor_snap_length", "float", false, "CharacterBody: floor snap length."),
				doc_param("wall_min_slide_angle", "float", false, "CharacterBody: min wall slide angle."),
				doc_param("floor_stop_on_slope", "bool", false, "CharacterBody: stop sliding on slopes."),
				doc_param("slide_on_ceiling", "bool", false, "CharacterBody: slide along ceilings."),
				doc_param("max_slides", "int", false, "CharacterBody: max slide iterations."),
				doc_param("motion_mode", "String", false, "CharacterBody: 'grounded', 'floating', or an int."),
				doc_param("mass", "float", false, "RigidBody: mass."),
				doc_param("gravity_scale", "float", false, "RigidBody: gravity scale."),
				doc_param("linear_damp", "float", false, "RigidBody: linear damping."),
				doc_param("angular_damp", "float", false, "RigidBody: angular damping."),
				doc_param("freeze", "bool", false, "RigidBody: freeze the body."),
				doc_param("contact_monitor", "bool", false, "RigidBody: enable contact monitoring."),
				doc_param("max_contacts_reported", "int", false, "RigidBody: max reported contacts."),
				doc_param("freeze_mode", "String", false, "RigidBody: 'static', 'kinematic', or an int."),
				doc_param("continuous_cd", "JSON", false, "RigidBody CCD: 2D 'disabled'/'cast_ray'/'cast_shape' or int; 3D a bool."),
			],
		},
		"physics.get_collision_info": {
			"description": "Report a node's collision layers/masks, body settings, and (optionally recursing) its CollisionShape/CollisionPolygon/RayCast descendants with shape details.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("include_children", "bool", false, "Recurse into descendants for shapes/raycasts (default true)."),
			],
		},
		"physics.add_joint": {
			"description": "Add a Joint2D/Joint3D between two bodies (node_a/node_b are stored relative to the joint). Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add the joint under (default '.'). --parent is an alias."),
				doc_param("type", "String", true, "Instantiable Joint2D/Joint3D subclass (PinJoint3D/HingeJoint3D/SliderJoint3D/ConeTwistJoint3D/Generic6DOFJoint3D, or PinJoint2D/GrooveJoint2D/DampedSpringJoint2D)."),
				doc_param("name", "String", false, "Node name (defaults to the type)."),
				doc_param("position", "Vector3", false, "Local position of the joint (Vector2 for a 2D joint)."),
				doc_param("node_a", "NodePath", false, "First body to connect."),
				doc_param("node_b", "NodePath", false, "Second body to connect."),
			],
		},
	}
