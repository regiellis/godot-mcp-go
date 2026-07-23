@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"particles.create": _create,
		"particles.set_material": _set_material,
		"particles.set_color_gradient": _set_color_gradient,
		"particles.apply_preset": _apply_preset,
		"particles.get_info": _get_info,
	}


func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "parent_path")
	if r[1] != null:
		return r[1]
	var parent_path: String = r[0]

	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Node at '%s'" % parent_path)

	var node_name := optional_string(params, "name", "Particles")
	var is_3d := optional_bool(params, "is_3d", false)
	var amount := optional_int(params, "amount", 16)
	var lifetime := float(params.get("lifetime", 1.0))
	var one_shot := optional_bool(params, "one_shot", false)
	var explosiveness := float(params.get("explosiveness", 0.0))
	var randomness := float(params.get("randomness", 0.0))
	var emitting := optional_bool(params, "emitting", true)

	var particles_node: Node
	if is_3d:
		particles_node = GPUParticles3D.new()
	else:
		particles_node = GPUParticles2D.new()
	particles_node.name = node_name
	particles_node.amount = amount
	particles_node.lifetime = lifetime
	particles_node.one_shot = one_shot
	particles_node.explosiveness = explosiveness
	particles_node.randomness = randomness
	particles_node.emitting = emitting
	particles_node.process_material = ParticleProcessMaterial.new()

	add_child_with_undo(parent, particles_node, root, "MCP: Create particles")

	return success({
		"name": String(particles_node.name),
		"parent": parent_path,
		"is_3d": is_3d,
		"amount": amount,
		"lifetime": lifetime,
		"one_shot": one_shot,
		"created": true,
	})


func _set_material(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var node_path: String = r[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := _get_particles_node(node_path)
	if node == null:
		return error_not_found("GPUParticles2D/3D at '%s'" % node_path)

	var mat := _clone_process_material(node)
	var changes: Array = []

	if params.has("direction"):
		var dir: Variant = _parse_vector3(params["direction"])
		if dir != null:
			mat.direction = dir
			changes.append("direction")

	if params.has("spread"):
		mat.spread = float(params["spread"])
		changes.append("spread")

	if params.has("initial_velocity_min"):
		mat.initial_velocity_min = float(params["initial_velocity_min"])
		changes.append("initial_velocity_min")
	if params.has("initial_velocity_max"):
		mat.initial_velocity_max = float(params["initial_velocity_max"])
		changes.append("initial_velocity_max")

	if params.has("gravity"):
		var grav: Variant = _parse_vector3(params["gravity"])
		if grav != null:
			mat.gravity = grav
			changes.append("gravity")

	if params.has("scale_min"):
		mat.scale_min = float(params["scale_min"])
		changes.append("scale_min")
	if params.has("scale_max"):
		mat.scale_max = float(params["scale_max"])
		changes.append("scale_max")

	if params.has("color"):
		mat.color = _parse_color(str(params["color"]))
		changes.append("color")

	if params.has("emission_shape"):
		var shape_matched := true
		match str(params["emission_shape"]).to_lower():
			"point":
				mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
			"sphere":
				mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
				if params.has("emission_sphere_radius"):
					mat.emission_sphere_radius = float(params["emission_sphere_radius"])
			"sphere_surface":
				mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
				if params.has("emission_sphere_radius"):
					mat.emission_sphere_radius = float(params["emission_sphere_radius"])
			"box":
				mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
				if params.has("emission_box_extents"):
					var ext: Variant = _parse_vector3(params["emission_box_extents"])
					if ext != null:
						mat.emission_box_extents = ext
			"ring":
				mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
				if params.has("emission_ring_radius"):
					mat.emission_ring_radius = float(params["emission_ring_radius"])
				if params.has("emission_ring_inner_radius"):
					mat.emission_ring_inner_radius = float(params["emission_ring_inner_radius"])
				if params.has("emission_ring_height"):
					mat.emission_ring_height = float(params["emission_ring_height"])
			_:
				shape_matched = false
		if shape_matched:
			changes.append("emission_shape")

	if params.has("angular_velocity_min"):
		mat.angular_velocity_min = float(params["angular_velocity_min"])
		changes.append("angular_velocity_min")
	if params.has("angular_velocity_max"):
		mat.angular_velocity_max = float(params["angular_velocity_max"])
		changes.append("angular_velocity_max")

	if params.has("orbit_velocity_min"):
		mat.orbit_velocity_min = float(params["orbit_velocity_min"])
		changes.append("orbit_velocity_min")
	if params.has("orbit_velocity_max"):
		mat.orbit_velocity_max = float(params["orbit_velocity_max"])
		changes.append("orbit_velocity_max")

	if params.has("damping_min"):
		mat.damping_min = float(params["damping_min"])
		changes.append("damping_min")
	if params.has("damping_max"):
		mat.damping_max = float(params["damping_max"])
		changes.append("damping_max")

	if params.has("attractor_interaction_enabled"):
		mat.attractor_interaction_enabled = bool(params["attractor_interaction_enabled"])
		changes.append("attractor_interaction_enabled")

	if not changes.is_empty():
		_set_process_material_undo(node, mat, "MCP: Set particle material")
	return success({"node_path": node_path, "changes": changes})


func _set_color_gradient(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var node_path: String = r[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := _get_particles_node(node_path)
	if node == null:
		return error_not_found("GPUParticles2D/3D at '%s'" % node_path)

	if not params.has("stops") or not params["stops"] is Array:
		return error_invalid_params("Missing required parameter: stops (array of {offset, color})")
	var stops: Array = params["stops"]
	if stops.is_empty():
		return error_invalid_params("stops array must not be empty")

	var mat := _clone_process_material(node)
	var gradient := Gradient.new()
	while gradient.get_point_count() > 0:
		gradient.remove_point(0)
	for stop in stops:
		if stop is Dictionary:
			gradient.add_point(float(stop.get("offset", 0.0)), _parse_color(str(stop.get("color", "#ffffff"))))

	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = gradient
	mat.color_ramp = grad_tex
	_set_process_material_undo(node, mat, "MCP: Set particle color gradient")

	return success({"node_path": node_path, "stops_count": gradient.get_point_count()})


func _apply_preset(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var node_path: String = r[0]

	var rp := require_string(params, "preset")
	if rp[1] != null:
		return rp[1]
	var preset: String = rp[0].to_lower()

	if get_edited_root() == null:
		return error_no_scene()
	var node := _get_particles_node(node_path)
	if node == null:
		return error_not_found("GPUParticles2D/3D at '%s'" % node_path)

	var old_state := _capture_particle_state(node)
	var preset_state := {}
	var mat := ParticleProcessMaterial.new()
	var is_2d: bool = node is GPUParticles2D

	var gravity_down := Vector3(0, 98.0 if is_2d else 9.8, 0)
	var gravity_none := Vector3.ZERO

	match preset:
		"explosion":
			preset_state["amount"] = 32
			preset_state["lifetime"] = 0.6
			preset_state["one_shot"] = true
			preset_state["explosiveness"] = 1.0
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 180.0
			mat.initial_velocity_min = 100.0 if is_2d else 5.0
			mat.initial_velocity_max = 200.0 if is_2d else 10.0
			mat.gravity = gravity_down * 0.5
			mat.damping_min = 2.0
			mat.damping_max = 4.0
			mat.scale_min = 0.5
			mat.scale_max = 1.5
			mat.color = Color(1.0, 0.6, 0.1)
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color.WHITE},
				{"offset": 0.3, "color": Color(1.0, 0.8, 0.2)},
				{"offset": 0.7, "color": Color(1.0, 0.3, 0.0)},
				{"offset": 1.0, "color": Color(0.2, 0.0, 0.0, 0.0)},
			])

		"fire":
			preset_state["amount"] = 24
			preset_state["lifetime"] = 1.2
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 15.0
			mat.initial_velocity_min = 30.0 if is_2d else 1.5
			mat.initial_velocity_max = 60.0 if is_2d else 3.0
			mat.gravity = gravity_none
			mat.scale_min = 0.8
			mat.scale_max = 1.5
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color(1.0, 1.0, 0.5)},
				{"offset": 0.3, "color": Color(1.0, 0.6, 0.0)},
				{"offset": 0.7, "color": Color(0.8, 0.2, 0.0)},
				{"offset": 1.0, "color": Color(0.2, 0.0, 0.0, 0.0)},
			])

		"smoke":
			preset_state["amount"] = 16
			preset_state["lifetime"] = 3.0
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 25.0
			mat.initial_velocity_min = 10.0 if is_2d else 0.5
			mat.initial_velocity_max = 25.0 if is_2d else 1.2
			mat.gravity = gravity_none
			mat.scale_min = 1.5
			mat.scale_max = 3.0
			mat.damping_min = 1.0
			mat.damping_max = 2.0
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color(0.5, 0.5, 0.5, 0.6)},
				{"offset": 0.5, "color": Color(0.6, 0.6, 0.6, 0.3)},
				{"offset": 1.0, "color": Color(0.7, 0.7, 0.7, 0.0)},
			])

		"sparks":
			preset_state["amount"] = 48
			preset_state["lifetime"] = 0.4
			preset_state["one_shot"] = true
			preset_state["explosiveness"] = 0.95
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 180.0
			mat.initial_velocity_min = 200.0 if is_2d else 8.0
			mat.initial_velocity_max = 400.0 if is_2d else 16.0
			mat.gravity = gravity_down
			mat.scale_min = 0.1
			mat.scale_max = 0.3
			mat.damping_min = 1.0
			mat.damping_max = 3.0
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color(1.0, 1.0, 0.8)},
				{"offset": 0.5, "color": Color(1.0, 0.7, 0.2)},
				{"offset": 1.0, "color": Color(1.0, 0.3, 0.0, 0.0)},
			])

		"rain":
			preset_state["amount"] = 64
			preset_state["lifetime"] = 0.8
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, 1, 0) if is_2d else Vector3(0, -1, 0)
			mat.spread = 5.0
			mat.initial_velocity_min = 300.0 if is_2d else 12.0
			mat.initial_velocity_max = 400.0 if is_2d else 16.0
			mat.gravity = gravity_down
			mat.scale_min = 0.1
			mat.scale_max = 0.2
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			mat.emission_box_extents = Vector3(200, 0, 0) if is_2d else Vector3(5, 0, 5)
			mat.color = Color(0.6, 0.7, 1.0, 0.7)

		"snow":
			preset_state["amount"] = 48
			preset_state["lifetime"] = 4.0
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, 1, 0) if is_2d else Vector3(0, -1, 0)
			mat.spread = 20.0
			mat.initial_velocity_min = 20.0 if is_2d else 0.8
			mat.initial_velocity_max = 40.0 if is_2d else 1.5
			mat.gravity = Vector3(0, 20, 0) if is_2d else Vector3(0, -0.5, 0)
			mat.scale_min = 0.3
			mat.scale_max = 0.8
			mat.angular_velocity_min = -45.0
			mat.angular_velocity_max = 45.0
			mat.damping_min = 0.5
			mat.damping_max = 1.5
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			mat.emission_box_extents = Vector3(200, 0, 0) if is_2d else Vector3(5, 0, 5)
			mat.color = Color(1.0, 1.0, 1.0, 0.9)

		"magic":
			preset_state["amount"] = 24
			preset_state["lifetime"] = 2.0
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 180.0
			mat.initial_velocity_min = 20.0 if is_2d else 1.0
			mat.initial_velocity_max = 50.0 if is_2d else 2.5
			mat.gravity = gravity_none
			mat.orbit_velocity_min = 0.5
			mat.orbit_velocity_max = 1.5
			mat.scale_min = 0.3
			mat.scale_max = 0.8
			mat.damping_min = 1.0
			mat.damping_max = 2.0
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color(0.3, 0.5, 1.0)},
				{"offset": 0.25, "color": Color(1.0, 0.3, 0.8)},
				{"offset": 0.5, "color": Color(0.3, 1.0, 0.5)},
				{"offset": 0.75, "color": Color(1.0, 0.8, 0.2)},
				{"offset": 1.0, "color": Color(0.5, 0.3, 1.0, 0.0)},
			])

		"dust":
			preset_state["amount"] = 12
			preset_state["lifetime"] = 5.0
			preset_state["one_shot"] = false
			preset_state["explosiveness"] = 0.0
			mat.direction = Vector3(0, -1, 0) if is_2d else Vector3(0, 1, 0)
			mat.spread = 180.0
			mat.initial_velocity_min = 3.0 if is_2d else 0.1
			mat.initial_velocity_max = 8.0 if is_2d else 0.3
			mat.gravity = gravity_none
			mat.scale_min = 0.2
			mat.scale_max = 0.5
			mat.damping_min = 0.5
			mat.damping_max = 1.0
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			mat.emission_box_extents = Vector3(100, 100, 0) if is_2d else Vector3(3, 3, 3)
			_apply_gradient(mat, [
				{"offset": 0.0, "color": Color(0.8, 0.75, 0.65, 0.0)},
				{"offset": 0.2, "color": Color(0.8, 0.75, 0.65, 0.3)},
				{"offset": 0.8, "color": Color(0.8, 0.75, 0.65, 0.3)},
				{"offset": 1.0, "color": Color(0.8, 0.75, 0.65, 0.0)},
			])

		_:
			return error_invalid_params("Unknown preset: '%s'. Valid presets: explosion, fire, smoke, sparks, rain, snow, magic, dust" % preset)

	preset_state["process_material"] = mat
	_register_particle_state_undo(node, old_state, preset_state, "MCP: Apply particle preset")

	return success({"node_path": node_path, "preset": preset, "applied": true})


func _get_info(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var node_path: String = r[0]

	if get_edited_root() == null:
		return error_no_scene()
	var node := _get_particles_node(node_path)
	if node == null:
		return error_not_found("GPUParticles2D/3D at '%s'" % node_path)

	var info: Dictionary = {
		"node_path": node_path,
		"type": node.get_class(),
		"amount": node.get("amount"),
		"lifetime": node.get("lifetime"),
		"one_shot": node.get("one_shot"),
		"explosiveness": node.get("explosiveness"),
		"randomness": node.get("randomness"),
		"emitting": node.get("emitting"),
	}

	var mat = node.get("process_material")
	if mat is ParticleProcessMaterial:
		var mat_info: Dictionary = {
			"direction": str(mat.direction),
			"spread": mat.spread,
			"initial_velocity_min": mat.initial_velocity_min,
			"initial_velocity_max": mat.initial_velocity_max,
			"gravity": str(mat.gravity),
			"scale_min": mat.scale_min,
			"scale_max": mat.scale_max,
			"color": str(mat.color),
			"angular_velocity_min": mat.angular_velocity_min,
			"angular_velocity_max": mat.angular_velocity_max,
			"orbit_velocity_min": mat.orbit_velocity_min,
			"orbit_velocity_max": mat.orbit_velocity_max,
			"damping_min": mat.damping_min,
			"damping_max": mat.damping_max,
			"attractor_interaction_enabled": mat.attractor_interaction_enabled,
		}

		var shape_name: String
		match mat.emission_shape:
			ParticleProcessMaterial.EMISSION_SHAPE_POINT: shape_name = "point"
			ParticleProcessMaterial.EMISSION_SHAPE_SPHERE: shape_name = "sphere"
			ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE: shape_name = "sphere_surface"
			ParticleProcessMaterial.EMISSION_SHAPE_BOX: shape_name = "box"
			ParticleProcessMaterial.EMISSION_SHAPE_RING: shape_name = "ring"
			_: shape_name = "unknown(%d)" % mat.emission_shape
		mat_info["emission_shape"] = shape_name

		match mat.emission_shape:
			ParticleProcessMaterial.EMISSION_SHAPE_SPHERE, ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE:
				mat_info["emission_sphere_radius"] = mat.emission_sphere_radius
			ParticleProcessMaterial.EMISSION_SHAPE_BOX:
				mat_info["emission_box_extents"] = str(mat.emission_box_extents)
			ParticleProcessMaterial.EMISSION_SHAPE_RING:
				mat_info["emission_ring_radius"] = mat.emission_ring_radius
				mat_info["emission_ring_inner_radius"] = mat.emission_ring_inner_radius
				mat_info["emission_ring_height"] = mat.emission_ring_height

		if mat.color_ramp is GradientTexture1D:
			var grad_tex: GradientTexture1D = mat.color_ramp
			if grad_tex.gradient != null:
				var gradient_stops: Array = []
				var grad: Gradient = grad_tex.gradient
				for i in grad.get_point_count():
					gradient_stops.append({"offset": grad.get_offset(i), "color": str(grad.get_color(i))})
				mat_info["color_ramp"] = gradient_stops

		info["material"] = mat_info
	else:
		info["material"] = null

	return success(info)


# --- Helpers ----------------------------------------------------------------

func _get_particles_node(node_path: String) -> Node:
	var node := find_node_by_path(node_path)
	if node is GPUParticles2D or node is GPUParticles3D:
		return node
	return null


func _clone_process_material(node: Node) -> ParticleProcessMaterial:
	var old_mat = node.get("process_material")
	if old_mat is ParticleProcessMaterial:
		return old_mat.duplicate(true) as ParticleProcessMaterial
	return ParticleProcessMaterial.new()


func _set_process_material_undo(node: Node, mat: ParticleProcessMaterial, action_name: String) -> void:
	var old_value: Variant = node.get("process_material")
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	undo_redo.add_do_property(node, "process_material", mat)
	undo_redo.add_do_reference(mat)
	undo_redo.add_undo_property(node, "process_material", old_value)
	if old_value is Resource:
		undo_redo.add_undo_reference(old_value)
	undo_redo.commit_action()


func _capture_particle_state(node: Node) -> Dictionary:
	var state := {}
	for property: String in ["amount", "lifetime", "one_shot", "explosiveness", "randomness", "emitting", "process_material"]:
		if property in node:
			state[property] = node.get(property)
	return state


func _register_particle_state_undo(node: Node, old_state: Dictionary, new_state: Dictionary, action_name: String) -> void:
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name)
	for property: String in new_state:
		undo_redo.add_do_property(node, property, new_state[property])
		if new_state[property] is Resource:
			undo_redo.add_do_reference(new_state[property])
		undo_redo.add_undo_property(node, property, old_state.get(property, null))
		if old_state.get(property, null) is Resource:
			undo_redo.add_undo_reference(old_state[property])
	undo_redo.commit_action()


func _apply_gradient(mat: ParticleProcessMaterial, stops: Array) -> void:
	var gradient := Gradient.new()
	for i in range(gradient.get_point_count() - 1, -1, -1):
		gradient.remove_point(i)
	for stop in stops:
		gradient.add_point(stop["offset"], stop["color"])
	var grad_tex := GradientTexture1D.new()
	grad_tex.width = 64
	grad_tex.gradient = gradient
	mat.set_deferred("color_ramp", grad_tex)


func _parse_vector3(value: Variant) -> Variant:
	if value is Dictionary:
		return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
	if value is String:
		var expr := Expression.new()
		if expr.parse(value) == OK:
			var parsed: Variant = expr.execute()
			if parsed is Vector3:
				return parsed
	return null


func _parse_color(color_str: String) -> Color:
	if color_str.begins_with("#"):
		return Color.html(color_str)
	match color_str.to_lower():
		"red": return Color.RED
		"green": return Color.GREEN
		"blue": return Color.BLUE
		"white": return Color.WHITE
		"black": return Color.BLACK
		"yellow": return Color.YELLOW
		"orange": return Color(1.0, 0.5, 0.0)
		"gray", "grey": return Color.GRAY
		"cyan": return Color.CYAN
		"magenta": return Color.MAGENTA
		"transparent": return Color(0, 0, 0, 0)
	var expr := Expression.new()
	if expr.parse(color_str) == OK:
		var parsed: Variant = expr.execute()
		if parsed is Color:
			return parsed
	return Color.WHITE


func get_command_docs() -> Dictionary:
	return {
		"particles.create": {
			"description": "Create a GPUParticles2D/GPUParticles3D node (with a fresh ParticleProcessMaterial) under --parent-path. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", true, "Parent node to add the particles under."),
				doc_param("name", "String", false, "Node name (default 'Particles')."),
				doc_param("is_3d", "bool", false, "Create a GPUParticles3D (default false = GPUParticles2D)."),
				doc_param("amount", "int", false, "Particle count (default 16)."),
				doc_param("lifetime", "float", false, "Particle lifetime in seconds (default 1.0)."),
				doc_param("one_shot", "bool", false, "Emit a single burst then stop (default false)."),
				doc_param("explosiveness", "float", false, "0..1; higher emits more particles at once (default 0)."),
				doc_param("randomness", "float", false, "0..1 emission-timing randomness (default 0)."),
				doc_param("emitting", "bool", false, "Start emitting immediately (default true)."),
			],
		},
		"particles.set_material": {
			"description": "Tweak a particle node's ParticleProcessMaterial (clones it first, undoable). Only the params you pass are changed; returns the list of changed fields.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GPUParticles2D or GPUParticles3D."),
				doc_param("direction", "Vector3", false, "Emission direction."),
				doc_param("spread", "float", false, "Emission cone half-angle in degrees."),
				doc_param("initial_velocity_min", "float", false, "Minimum initial speed."),
				doc_param("initial_velocity_max", "float", false, "Maximum initial speed."),
				doc_param("gravity", "Vector3", false, "Gravity vector."),
				doc_param("scale_min", "float", false, "Minimum particle scale."),
				doc_param("scale_max", "float", false, "Maximum particle scale."),
				doc_param("color", "Color", false, "Base particle color (name, #hex, or Color(...))."),
				doc_param("emission_shape", "String", false, "'point', 'sphere', 'sphere_surface', 'box', or 'ring'."),
				doc_param("emission_sphere_radius", "float", false, "Sphere/sphere_surface radius."),
				doc_param("emission_box_extents", "Vector3", false, "Box half-extents."),
				doc_param("emission_ring_radius", "float", false, "Ring outer radius."),
				doc_param("emission_ring_inner_radius", "float", false, "Ring inner radius."),
				doc_param("emission_ring_height", "float", false, "Ring height."),
				doc_param("angular_velocity_min", "float", false, "Minimum angular velocity."),
				doc_param("angular_velocity_max", "float", false, "Maximum angular velocity."),
				doc_param("orbit_velocity_min", "float", false, "Minimum orbit velocity."),
				doc_param("orbit_velocity_max", "float", false, "Maximum orbit velocity."),
				doc_param("damping_min", "float", false, "Minimum damping."),
				doc_param("damping_max", "float", false, "Maximum damping."),
				doc_param("attractor_interaction_enabled", "bool", false, "Let particles interact with GPUParticlesAttractors."),
			],
		},
		"particles.set_color_gradient": {
			"description": "Set the process material's color_ramp from a list of gradient stops (clones the material, undoable).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GPUParticles2D or GPUParticles3D."),
				doc_param("stops", "Array", true, "Non-empty array of {offset: 0..1, color: name/#hex} objects."),
			],
		},
		"particles.apply_preset": {
			"description": "Apply a ready-made particle look (sets node amount/lifetime/one_shot/explosiveness plus a tuned ParticleProcessMaterial with color gradient). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GPUParticles2D or GPUParticles3D."),
				doc_param("preset", "String", true, "One of: explosion, fire, smoke, sparks, rain, snow, magic, dust."),
			],
		},
		"particles.get_info": {
			"description": "Report a particle node's core settings and its ParticleProcessMaterial (direction, velocities, gravity, emission shape, color ramp, ...).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target GPUParticles2D or GPUParticles3D."),
			],
		},
	}
