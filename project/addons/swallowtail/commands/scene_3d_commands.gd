@tool
extends "res://addons/swallowtail/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"scene3d.add_mesh": _add_mesh,
		"scene3d.setup_lighting": _setup_lighting,
		"scene3d.set_material": _set_material,
		"scene3d.setup_environment": _setup_environment,
		"scene3d.setup_camera": _setup_camera,
		"scene3d.add_gridmap": _add_gridmap,
		"scene3d.add_body": _add_body,
	}


const NodeUtils := preload("res://addons/swallowtail/utils/node_utils.gd")
const _BODY_TYPES_3D := ["StaticBody3D", "CharacterBody3D", "RigidBody3D", "Area3D"]
const _SHAPES_3D := ["box", "sphere", "capsule", "trimesh", "convex"]


## A 3D physics body with its CollisionShape3D + shape resource in one call, the
## scene2d.add_body counterpart the 3D side lacked. Primitive shapes come from --size/
## --radius/--height. With --from-mesh the body is seated on that MeshInstance3D
## (its rotation and origin; scale is baked into the shape, since a scaled body
## does not simulate), a primitive is sized from the mesh bounds read in the
## body's own frame, and trimesh/convex build the collider from the mesh geometry
## (the common "make this imported geometry collidable" need). --reparent-mesh
## moves the mesh under the new body so the two stay transform-coupled, in the
## same undo step.
func _add_body(params: Dictionary) -> Dictionary:
	var rr := require_scene_root_3d("scene3d.add_body")
	if rr[1] != null:
		return rr[1]
	var root: Node3D = rr[0]
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var type := optional_string(params, "type", "StaticBody3D")
	if type not in _BODY_TYPES_3D:
		return error_invalid_params("type must be one of %s" % [_BODY_TYPES_3D])
	var shape_kind := optional_string(params, "shape", "box").to_lower()
	if shape_kind not in _SHAPES_3D:
		return error_invalid_params("shape must be one of %s" % [_SHAPES_3D])

	# --from-mesh resolution happens up front so nothing below can half-apply.
	var mesh_path := optional_string(params, "from_mesh", "")
	var mesh_node: MeshInstance3D = null
	var reparent := optional_bool(params, "reparent_mesh", false)
	if mesh_path.is_empty():
		if shape_kind in ["trimesh", "convex"]:
			return error_invalid_params("shape '%s' needs --from-mesh <MeshInstance3D node path>" % shape_kind)
		if reparent:
			return error_invalid_params("reparent_mesh needs --from-mesh")
	else:
		var mn := find_node_by_path(mesh_path)
		if mn == null or not mn is MeshInstance3D:
			return error_not_found("MeshInstance3D '%s'" % mesh_path, "Pass --from-mesh a MeshInstance3D path")
		mesh_node = mn as MeshInstance3D
		if mesh_node.mesh == null:
			return error_invalid_params("MeshInstance3D '%s' has no mesh" % mesh_path)
		if params.has("position"):
			return error_invalid_params("from_mesh seats the body on the mesh, so 'position' does not apply; move the body afterwards with node.set")
		if reparent:
			if mesh_node == root or mesh_node.get_parent() == null:
				return error_invalid_params("cannot reparent the scene root '%s' under a new body" % mesh_path)
			if mesh_node == parent or mesh_node.is_ancestor_of(parent):
				return error_invalid_params("reparent_mesh would put '%s' under its own descendant; pick a parent_path outside the mesh" % mesh_path)
			var guard := guard_instance_write(mesh_node)
			if not guard.is_empty():
				return guard

	# The body's frame: the mesh's rotation and origin without its scale (with no
	# mesh, the parent's frame at --position). Every fit below is measured here.
	var parent_gt := (parent as Node3D).global_transform if parent is Node3D else Transform3D.IDENTITY
	var body_gt := parent_gt
	var mesh_scale := Vector3.ONE
	if mesh_node != null:
		var mesh_gt := mesh_node.global_transform
		mesh_scale = mesh_gt.basis.get_scale()
		body_gt = Transform3D(mesh_gt.basis.orthonormalized(), mesh_gt.origin)
	else:
		body_gt.origin = parent_gt * vec3_param(params, "position", Vector3.ZERO)

	# Mesh bounds in the body's frame: the eight local corners through the mesh's
	# full transform (scale included) and back through the body's, then the union.
	var fit := AABB()
	if mesh_node != null:
		var local := mesh_node.get_aabb()
		var to_body := body_gt.affine_inverse() * mesh_node.global_transform
		fit = AABB(to_body * local.get_endpoint(0), Vector3.ZERO)
		for i in range(1, 8):
			fit = fit.expand(to_body * local.get_endpoint(i))

	var shape: Shape3D = null
	var shape_offset := Vector3.ZERO
	match shape_kind:
		"box":
			var b := BoxShape3D.new()
			b.size = vec3_param(params, "size", fit.size if mesh_node != null else Vector3.ONE)
			shape = b
		"sphere":
			var s := SphereShape3D.new()
			var fit_r := maxf(fit.size.x, maxf(fit.size.y, fit.size.z)) / 2.0
			s.radius = float(params.get("radius", fit_r if mesh_node != null else 0.5))
			shape = s
		"capsule":
			var c := CapsuleShape3D.new()
			c.radius = float(params.get("radius", maxf(fit.size.x, fit.size.z) / 2.0 if mesh_node != null else 0.5))
			c.height = float(params.get("height", fit.size.y if mesh_node != null else 2.0))
			shape = c
		"trimesh", "convex":
			shape = _mesh_shape(mesh_node.mesh, shape_kind, mesh_scale)
			if shape == null:
				return error_internal("could not build a %s shape from '%s'" % [shape_kind, mesh_path])
	if mesh_node != null and shape_kind not in ["trimesh", "convex"]:
		shape_offset = fit.get_center()

	var body: Node3D = ClassDB.instantiate(type)
	body.name = optional_string(params, "name", type)
	body.transform = parent_gt.affine_inverse() * body_gt
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape
	col.position = shape_offset

	# One action for the body, its shape, and the optional reparent: undo puts the
	# mesh back where it was and drops the body in a single step.
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add %s" % type)
	undo_redo.add_do_method(parent, "add_child", body)
	undo_redo.add_do_method(body, "set_owner", root)
	undo_redo.add_do_method(body, "add_child", col)
	undo_redo.add_do_method(col, "set_owner", root)
	undo_redo.add_do_reference(body)
	var old_mesh_parent: Node = null
	var old_mesh_index := -1
	var old_mesh_transform := Transform3D.IDENTITY
	if reparent:
		old_mesh_parent = mesh_node.get_parent()
		old_mesh_index = mesh_node.get_index()
		old_mesh_transform = mesh_node.transform
		# Leaving the tree clears the owner of the whole moved subtree, so both
		# directions re-own it after the add.
		undo_redo.add_do_method(old_mesh_parent, "remove_child", mesh_node)
		undo_redo.add_do_method(body, "add_child", mesh_node)
		undo_redo.add_do_method(self, "_reown", mesh_node, root)
		undo_redo.add_do_property(mesh_node, "transform", body_gt.affine_inverse() * mesh_node.global_transform)
		undo_redo.add_undo_property(mesh_node, "transform", old_mesh_transform)
		undo_redo.add_undo_method(body, "remove_child", mesh_node)
		undo_redo.add_undo_method(old_mesh_parent, "add_child", mesh_node)
		undo_redo.add_undo_method(old_mesh_parent, "move_child", mesh_node, old_mesh_index)
		undo_redo.add_undo_method(self, "_reown", mesh_node, root)
	undo_redo.add_undo_method(parent, "remove_child", body)
	undo_redo.commit_action()

	var result := {
		"node_path": str(root.get_path_to(body)), "name": String(body.name), "type": type,
		"collision_path": str(root.get_path_to(col)), "shape": shape_kind,
	}
	if mesh_node != null:
		result["seated_on"] = mesh_path
		result["global_position"] = PropertyParser.serialize_value(body_gt.origin)
		result["mesh_scale_baked"] = PropertyParser.serialize_value(mesh_scale)
		result["fit"] = {
			"size": PropertyParser.serialize_value(fit.size),
			"center": PropertyParser.serialize_value(fit.get_center()),
			"shape_offset": PropertyParser.serialize_value(shape_offset),
		}
		if reparent:
			result["mesh_path"] = str(root.get_path_to(mesh_node))
	return success(result)


## A trimesh or convex shape from a Mesh, with the instance's scale baked into
## the vertices. The body carrying the shape is unscaled on purpose, so a scaled
## MeshInstance3D would otherwise get a collider at the mesh's unit size.
func _mesh_shape(mesh: Mesh, kind: String, scale: Vector3) -> Shape3D:
	if scale.is_equal_approx(Vector3.ONE):
		return mesh.create_trimesh_shape() if kind == "trimesh" else mesh.create_convex_shape()
	if kind == "trimesh":
		var faces := mesh.get_faces()
		if faces.is_empty():
			return null
		for i in faces.size():
			faces[i] = faces[i] * scale
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(faces)
		return concave
	var convex := mesh.create_convex_shape()
	if convex == null:
		return null
	var points := convex.points
	for i in points.size():
		points[i] = points[i] * scale
	convex.points = points
	return convex


## Undo/redo target for the reparent step: a subtree re-added to the tree needs
## its owner set again before the packer will save it.
func _reown(node: Node, root: Node) -> void:
	node.owner = root
	NodeUtils.set_owner_recursive(node, root)


# --- Parameter parsing helpers ----------------------------------------------

## Environment.TONE_MAPPER_AGX read from the live build, -1 when this engine has
## no such tonemapper (below 4.4). Naming the constant would be a parse error
## there, which costs the whole scene3d group rather than the one option.
func _agx_tonemap() -> int:
	if not ClassDB.class_has_integer_constant("Environment", "TONE_MAPPER_AGX"):
		return -1
	return ClassDB.class_get_integer_constant("Environment", "TONE_MAPPER_AGX")


func _color_param(params: Dictionary, key: String, default: Color) -> Color:
	if not params.has(key):
		return default
	var val: Variant = params[key]
	if val is String:
		return PropertyParser.parse_value(val, TYPE_COLOR)
	if val is Dictionary:
		return Color(
			float(val.get("r", default.r)),
			float(val.get("g", default.g)),
			float(val.get("b", default.b)),
			float(val.get("a", default.a)))
	return default


func _vector3_param(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


# --- 1. add_mesh ------------------------------------------------------------

const _MESH_TYPES := ["BoxMesh", "SphereMesh", "CylinderMesh", "CapsuleMesh", "PlaneMesh", "PrismMesh", "TorusMesh", "QuadMesh"]


func _add_mesh(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var mesh_type := optional_string(params, "mesh_type", "")
	var mesh_file := optional_string(params, "mesh_file", "")
	if mesh_type.is_empty() and mesh_file.is_empty():
		return error_invalid_params("Either 'mesh_type' or 'mesh_file' is required")

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = optional_string(params, "name", "MeshInstance3D")

	if not mesh_file.is_empty():
		if not ResourceLoader.exists(mesh_file):
			mesh_instance.free()
			return error_not_found("Mesh file '%s'" % mesh_file, "Provide a valid res:// path to .glb, .gltf, or .obj")
		var loaded: Resource = load(mesh_file)
		if loaded is Mesh:
			mesh_instance.mesh = loaded as Mesh
		elif loaded is PackedScene:
			var scene_instance := (loaded as PackedScene).instantiate()
			var found_mesh := _find_first_mesh(scene_instance)
			scene_instance.free()
			if found_mesh == null:
				mesh_instance.free()
				return error_invalid_params("No mesh found in '%s'" % mesh_file)
			mesh_instance.mesh = found_mesh
		else:
			mesh_instance.free()
			return error_invalid_params("'%s' is not a Mesh or PackedScene" % mesh_file)
	else:
		if mesh_type not in _MESH_TYPES:
			mesh_instance.free()
			return error_invalid_params("Unknown mesh_type '%s'. Available: %s" % [mesh_type, _MESH_TYPES])
		var mesh_res: Mesh = ClassDB.instantiate(mesh_type)
		var mpd := optional_dict(params, "mesh_properties")
		if mpd[1] != null:
			mesh_instance.free()
			return mpd[1]
		var mesh_props := apply_initial_properties(mesh_res, mpd[0])
		if not mesh_props["failures"].is_empty():
			mesh_instance.free()
			return error_property_failures(mesh_props)
		mesh_instance.mesh = mesh_res

	mesh_instance.position = _vector3_param(params, "position", Vector3.ZERO)
	mesh_instance.rotation_degrees = _vector3_param(params, "rotation", Vector3.ZERO)
	mesh_instance.scale = _vector3_param(params, "scale", Vector3.ONE)

	add_child_with_undo(parent, mesh_instance, root, "MCP: Add MeshInstance3D")

	return success({
		"node_path": str(root.get_path_to(mesh_instance)),
		"name": String(mesh_instance.name),
		"mesh_type": mesh_type if mesh_file.is_empty() else mesh_file,
	})


func _find_first_mesh(start: Node) -> Mesh:
	var queue: Array[Node] = [start]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			return (n as MeshInstance3D).mesh
		for child in n.get_children():
			queue.append(child)
	return null


# --- 2. setup_lighting ------------------------------------------------------

func _setup_lighting(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var light_type := optional_string(params, "light_type", "")
	var preset := optional_string(params, "preset", "")
	var node_name := optional_string(params, "name", "")

	if not preset.is_empty():
		match preset:
			"sun":
				light_type = "DirectionalLight3D"
				if node_name.is_empty():
					node_name = "SunLight"
			"indoor":
				light_type = "OmniLight3D"
				if node_name.is_empty():
					node_name = "IndoorLight"
			"dramatic":
				light_type = "SpotLight3D"
				if node_name.is_empty():
					node_name = "DramaticLight"
			_:
				return error_invalid_params("Unknown preset '%s'. Available: sun, indoor, dramatic" % preset)

	if light_type.is_empty():
		return error_invalid_params("Either 'light_type' or 'preset' is required")

	var light: Light3D
	match light_type:
		"DirectionalLight3D":
			light = DirectionalLight3D.new()
		"OmniLight3D":
			light = OmniLight3D.new()
		"SpotLight3D":
			light = SpotLight3D.new()
		_:
			return error_invalid_params("Unknown light_type '%s'. Available: DirectionalLight3D, OmniLight3D, SpotLight3D" % light_type)

	if node_name.is_empty():
		node_name = light_type
	light.name = node_name

	light.light_color = _color_param(params, "color", Color.WHITE)
	light.light_energy = float(params.get("energy", 1.0))
	light.shadow_enabled = optional_bool(params, "shadows", false)

	if light is OmniLight3D:
		var omni := light as OmniLight3D
		omni.omni_range = float(params.get("range", 5.0))
		omni.omni_attenuation = float(params.get("attenuation", 1.0))
	elif light is SpotLight3D:
		var spot := light as SpotLight3D
		spot.spot_range = float(params.get("range", 5.0))
		spot.spot_attenuation = float(params.get("attenuation", 1.0))
		spot.spot_angle = float(params.get("spot_angle", 45.0))
		spot.spot_angle_attenuation = float(params.get("spot_angle_attenuation", 1.0))

	if not preset.is_empty():
		match preset:
			"sun":
				light.light_energy = float(params.get("energy", 1.0))
				light.shadow_enabled = optional_bool(params, "shadows", true)
				light.rotation_degrees = _vector3_param(params, "rotation", Vector3(-45, -30, 0))
			"indoor":
				light.light_energy = float(params.get("energy", 0.8))
				light.light_color = _color_param(params, "color", Color(1.0, 0.95, 0.85))
				if light is OmniLight3D:
					(light as OmniLight3D).omni_range = float(params.get("range", 8.0))
			"dramatic":
				light.light_energy = float(params.get("energy", 2.0))
				light.shadow_enabled = optional_bool(params, "shadows", true)
				if light is SpotLight3D:
					(light as SpotLight3D).spot_angle = float(params.get("spot_angle", 25.0))
					(light as SpotLight3D).spot_range = float(params.get("range", 10.0))

	light.position = _vector3_param(params, "position", Vector3.ZERO)
	if params.has("rotation"):
		light.rotation_degrees = _vector3_param(params, "rotation", light.rotation_degrees)

	add_child_with_undo(parent, light, root, "MCP: Add %s" % light_type)

	return success({
		"node_path": str(root.get_path_to(light)),
		"name": String(light.name),
		"light_type": light_type,
		"preset": preset,
	})


# --- 3. set_material --------------------------------------------------------

func _set_material(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var node := find_node_by_path(r[0])
	if node == null:
		return error_not_found("Node '%s'" % r[0])
	if not node is MeshInstance3D:
		return error_invalid_params("Node '%s' is not a MeshInstance3D (is %s)" % [r[0], node.get_class()])

	var mesh_inst := node as MeshInstance3D
	var surface_index := optional_int(params, "surface_index", 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_param(params, "albedo_color", Color.WHITE)
	if params.has("albedo_texture") and ResourceLoader.exists(params["albedo_texture"]):
		mat.albedo_texture = load(params["albedo_texture"]) as Texture2D

	mat.metallic = float(params.get("metallic", 0.0))
	mat.roughness = float(params.get("roughness", 1.0))
	if params.has("metallic_texture") and ResourceLoader.exists(params["metallic_texture"]):
		mat.metallic_texture = load(params["metallic_texture"]) as Texture2D
	if params.has("roughness_texture") and ResourceLoader.exists(params["roughness_texture"]):
		mat.roughness_texture = load(params["roughness_texture"]) as Texture2D
	if params.has("normal_texture"):
		mat.normal_enabled = true
		if ResourceLoader.exists(params["normal_texture"]):
			mat.normal_texture = load(params["normal_texture"]) as Texture2D

	if params.has("emission") or params.has("emission_color"):
		mat.emission_enabled = true
		mat.emission = _color_param(params, "emission", _color_param(params, "emission_color", Color.BLACK))
		mat.emission_energy_multiplier = float(params.get("emission_energy", 1.0))
	if params.has("emission_texture"):
		mat.emission_enabled = true
		if ResourceLoader.exists(params["emission_texture"]):
			mat.emission_texture = load(params["emission_texture"]) as Texture2D

	if params.has("transparency"):
		match str(params["transparency"]).to_upper():
			"DISABLED", "0":
				mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			"ALPHA", "1":
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			"ALPHA_SCISSOR", "2":
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			"ALPHA_HASH", "3":
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
			"ALPHA_DEPTH_PRE_PASS", "4":
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS

	if params.has("cull_mode"):
		match str(params["cull_mode"]).to_upper():
			"BACK", "0":
				mat.cull_mode = BaseMaterial3D.CULL_BACK
			"FRONT", "1":
				mat.cull_mode = BaseMaterial3D.CULL_FRONT
			"DISABLED", "2":
				mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var old_mat := mesh_inst.get_surface_override_material(surface_index)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set material on %s" % mesh_inst.name)
	undo_redo.add_do_method(mesh_inst, "set_surface_override_material", surface_index, mat)
	undo_redo.add_do_reference(mat)
	undo_redo.add_undo_method(mesh_inst, "set_surface_override_material", surface_index, old_mat)
	undo_redo.commit_action()

	return success({
		"node_path": str(root.get_path_to(mesh_inst)),
		"surface_index": surface_index,
		"albedo_color": str(mat.albedo_color),
		"metallic": mat.metallic,
		"roughness": mat.roughness,
	})


# --- 4. setup_environment ---------------------------------------------------

func _setup_environment(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	# AGX tonemapping is 4.4+, and the constant resolves at COMPILE time, so it is
	# read from ClassDB instead of named. Checked here rather than at the tonemap
	# branch below: refusing halfway through would leave a half-configured
	# environment behind for a call that reports failure.
	var tonemap := str(params.get("tonemap_mode", "")).to_upper()
	if (tonemap == "AGX" or tonemap == "4") and _agx_tonemap() < 0:
		return editor_method_error("TONE_MAPPER_AGX", "4.4", "Environment")

	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var node_name := optional_string(params, "name", "WorldEnvironment")
	var node_path := optional_string(params, "node_path", "")
	var world_env: WorldEnvironment = null
	var is_existing := false

	if not node_path.is_empty():
		var existing := find_node_by_path(node_path)
		if existing != null and existing is WorldEnvironment:
			world_env = existing as WorldEnvironment
			is_existing = true

	if world_env == null:
		world_env = WorldEnvironment.new()
		world_env.name = node_name

	var env: Environment = world_env.environment
	if env == null:
		env = Environment.new()

	var bg_mode := optional_string(params, "background_mode", "sky")
	match bg_mode.to_lower():
		"sky":
			env.background_mode = Environment.BG_SKY
		"color":
			env.background_mode = Environment.BG_COLOR
			env.background_color = _color_param(params, "background_color", Color(0.3, 0.3, 0.3))
		"canvas":
			env.background_mode = Environment.BG_CANVAS
		"clear_color":
			env.background_mode = Environment.BG_CLEAR_COLOR

	if params.has("sky"):
		var sky_r := require_dict(params, "sky")
		if sky_r[1] != null:
			return sky_r[1]
		var sky_params: Dictionary = sky_r[0]
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = _color_param(sky_params, "sky_top_color", Color(0.385, 0.454, 0.55))
		sky_mat.sky_horizon_color = _color_param(sky_params, "sky_horizon_color", Color(0.646, 0.654, 0.67))
		sky_mat.ground_bottom_color = _color_param(sky_params, "ground_bottom_color", Color(0.2, 0.169, 0.133))
		sky_mat.ground_horizon_color = _color_param(sky_params, "ground_horizon_color", Color(0.646, 0.654, 0.67))
		sky_mat.sun_angle_max = float(sky_params.get("sun_angle_max", 30.0))
		sky_mat.sky_curve = float(sky_params.get("sky_curve", 0.15))

		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.sky = sky
		env.background_mode = Environment.BG_SKY

	if params.has("ambient_light_color"):
		env.ambient_light_color = _color_param(params, "ambient_light_color", Color.WHITE)
	if params.has("ambient_light_energy"):
		env.ambient_light_energy = float(params["ambient_light_energy"])
	if params.has("ambient_light_source"):
		match str(params["ambient_light_source"]).to_upper():
			"BACKGROUND", "0":
				env.ambient_light_source = Environment.AMBIENT_SOURCE_BG
			"DISABLED", "1":
				env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
			"COLOR", "2":
				env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			"SKY", "3":
				env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	if params.has("tonemap_mode"):
		match str(params["tonemap_mode"]).to_upper():
			"LINEAR", "0":
				env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			"REINHARDT", "1":
				env.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
			"FILMIC", "2":
				env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
			"ACES", "3":
				env.tonemap_mode = Environment.TONE_MAPPER_ACES
			"AGX", "4":
				env.tonemap_mode = _agx_tonemap()
	if params.has("tonemap_exposure"):
		env.tonemap_exposure = float(params["tonemap_exposure"])
	if params.has("tonemap_white"):
		env.tonemap_white = float(params["tonemap_white"])

	if params.has("fog_enabled"):
		env.fog_enabled = optional_bool(params, "fog_enabled", false)
	if env.fog_enabled:
		# Guard each sub-property so reusing an existing env doesn't reset an unset one.
		if params.has("fog_light_color"):
			env.fog_light_color = _color_param(params, "fog_light_color", Color(0.518, 0.553, 0.608))
		if params.has("fog_density"):
			env.fog_density = float(params["fog_density"])
		if params.has("fog_light_energy"):
			env.fog_light_energy = float(params["fog_light_energy"])

	if params.has("glow_enabled"):
		env.glow_enabled = optional_bool(params, "glow_enabled", false)
	if env.glow_enabled:
		if params.has("glow_intensity"):
			env.glow_intensity = float(params["glow_intensity"])
		if params.has("glow_strength"):
			env.glow_strength = float(params["glow_strength"])
		if params.has("glow_bloom"):
			env.glow_bloom = float(params["glow_bloom"])

	if params.has("ssao_enabled"):
		env.ssao_enabled = optional_bool(params, "ssao_enabled", false)
	if env.ssao_enabled:
		if params.has("ssao_radius"):
			env.ssao_radius = float(params["ssao_radius"])
		if params.has("ssao_intensity"):
			env.ssao_intensity = float(params["ssao_intensity"])

	if params.has("ssr_enabled"):
		env.ssr_enabled = optional_bool(params, "ssr_enabled", false)
	if env.ssr_enabled:
		if params.has("ssr_max_steps"):
			env.ssr_max_steps = optional_int(params, "ssr_max_steps", 64)
		if params.has("ssr_fade_in"):
			env.ssr_fade_in = float(params["ssr_fade_in"])
		if params.has("ssr_fade_out"):
			env.ssr_fade_out = float(params["ssr_fade_out"])

	if params.has("sdfgi_enabled"):
		env.sdfgi_enabled = optional_bool(params, "sdfgi_enabled", false)

	world_env.environment = env

	if not is_existing:
		add_child_with_undo(parent, world_env, root, "MCP: Add WorldEnvironment")

	var features: Array = []
	if env.fog_enabled: features.append("fog")
	if env.glow_enabled: features.append("glow")
	if env.ssao_enabled: features.append("ssao")
	if env.ssr_enabled: features.append("ssr")
	if env.sdfgi_enabled: features.append("sdfgi")

	return success({
		"node_path": str(root.get_path_to(world_env)),
		"name": String(world_env.name),
		"background_mode": bg_mode,
		"features": features,
		"is_existing": is_existing,
	})


# --- 5. setup_camera --------------------------------------------------------

func _setup_camera(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var node_path := optional_string(params, "node_path", "")
	var camera: Camera3D = null
	var is_existing := false

	if not node_path.is_empty():
		var existing := find_node_by_path(node_path)
		if existing != null and existing is Camera3D:
			camera = existing as Camera3D
			is_existing = true
		elif existing != null:
			return error_invalid_params("Node '%s' is not a Camera3D (is %s)" % [node_path, existing.get_class()])

	if camera == null:
		camera = Camera3D.new()
		camera.name = optional_string(params, "name", "Camera3D")

	var projection_str := optional_string(params, "projection", "")
	if not projection_str.is_empty():
		match projection_str.to_lower():
			"perspective", "0":
				camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			"orthogonal", "orthographic", "1":
				camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			"frustum", "2":
				camera.projection = Camera3D.PROJECTION_FRUSTUM

	if params.has("fov"):
		camera.fov = float(params["fov"])
	if params.has("size"):
		camera.size = float(params["size"])
	if params.has("near"):
		camera.near = float(params["near"])
	if params.has("far"):
		camera.far = float(params["far"])
	if params.has("cull_mask"):
		camera.cull_mask = optional_int(params, "cull_mask", 1048575)

	camera.current = optional_bool(params, "current", false)

	camera.position = _vector3_param(params, "position", camera.position if is_existing else Vector3(0, 1, 3))
	if params.has("rotation"):
		camera.rotation_degrees = _vector3_param(params, "rotation", camera.rotation_degrees)
	if params.has("look_at"):
		camera.look_at(_vector3_param(params, "look_at", Vector3.ZERO))

	if params.has("environment_path") and ResourceLoader.exists(params["environment_path"]):
		var env_res: Resource = load(params["environment_path"])
		if env_res is Environment:
			camera.environment = env_res as Environment

	if not is_existing:
		add_child_with_undo(parent, camera, root, "MCP: Add Camera3D")

	return success({
		"node_path": str(root.get_path_to(camera)),
		"name": String(camera.name),
		"projection": "perspective" if camera.projection == Camera3D.PROJECTION_PERSPECTIVE else "orthogonal",
		"fov": camera.fov,
		"position": str(camera.position),
		"is_existing": is_existing,
	})


# --- 6. add_gridmap ---------------------------------------------------------

func _add_gridmap(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var parent_path := optional_string(params, "parent_path", ".")
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node '%s'" % parent_path)

	var node_name := optional_string(params, "name", "GridMap")
	var node_path := optional_string(params, "node_path", "")
	var gridmap: GridMap = null
	var is_existing := false

	if not node_path.is_empty():
		var existing := find_node_by_path(node_path)
		if existing != null and existing is GridMap:
			gridmap = existing as GridMap
			is_existing = true
		elif existing != null:
			return error_invalid_params("Node '%s' is not a GridMap (is %s)" % [node_path, existing.get_class()])

	if gridmap == null:
		gridmap = GridMap.new()
		gridmap.name = node_name

	if params.has("mesh_library_path"):
		var lib_path: String = params["mesh_library_path"]
		if not ResourceLoader.exists(lib_path):
			if not is_existing:
				gridmap.free()
			return error_not_found("MeshLibrary '%s'" % lib_path, "Provide a valid res:// path to a .meshlib or .tres file")
		var lib: Resource = load(lib_path)
		if lib is MeshLibrary:
			gridmap.mesh_library = lib as MeshLibrary
		else:
			if not is_existing:
				gridmap.free()
			return error_invalid_params("'%s' is not a MeshLibrary" % lib_path)

	if params.has("cell_size"):
		gridmap.cell_size = _vector3_param(params, "cell_size", Vector3(2, 2, 2))

	gridmap.position = _vector3_param(params, "position", gridmap.position if is_existing else Vector3.ZERO)

	if not is_existing:
		add_child_with_undo(parent, gridmap, root, "MCP: Add GridMap")

	var cells: Array = params.get("cells", [])
	var cells_set := 0
	for cell: Variant in cells:
		if cell is Dictionary:
			var x := int(cell.get("x", 0))
			var y := int(cell.get("y", 0))
			var z := int(cell.get("z", 0))
			var item := int(cell.get("item", 0))
			var orientation := int(cell.get("orientation", 0))
			gridmap.set_cell_item(Vector3i(x, y, z), item, orientation)
			cells_set += 1

	return success({
		"node_path": str(root.get_path_to(gridmap)),
		"name": String(gridmap.name),
		"cells_set": cells_set,
		"is_existing": is_existing,
		"has_mesh_library": gridmap.mesh_library != null,
	})


func get_command_docs() -> Dictionary:
	return {
		"scene3d.add_mesh": {
			"description": "Add a MeshInstance3D under --parent-path: either a primitive --mesh-type OR a --mesh-file (.glb/.gltf/.obj/.tres, first mesh extracted). Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("mesh_type", "String", false, "Primitive mesh class (BoxMesh, SphereMesh, CylinderMesh, CapsuleMesh, PlaneMesh, PrismMesh, TorusMesh, QuadMesh). Provide mesh_type OR mesh_file."),
				doc_param("mesh_file", "String", false, "res:// path to a mesh/scene. Provide mesh_type OR mesh_file."),
				doc_param("name", "String", false, "Node name (default 'MeshInstance3D')."),
				doc_param("mesh_properties", "Dictionary", false, "Property values on the primitive mesh resource."),
				doc_param("position", "Vector3", false, "Local position."),
				doc_param("rotation", "Vector3", false, "Local rotation in degrees."),
				doc_param("scale", "Vector3", false, "Local scale (default 1,1,1)."),
			],
		},
		"scene3d.setup_lighting": {
			"description": "Add a light. Give --light-type (DirectionalLight3D/OmniLight3D/SpotLight3D) OR a --preset (sun/indoor/dramatic). Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("light_type", "String", false, "Light class. Provide light_type OR preset."),
				doc_param("preset", "String", false, "sun, indoor, or dramatic. Provide light_type OR preset."),
				doc_param("name", "String", false, "Node name."),
				doc_param("color", "Color", false, "Light color."),
				doc_param("energy", "float", false, "Light energy."),
				doc_param("shadows", "bool", false, "Enable shadows."),
				doc_param("range", "float", false, "Omni/Spot range."),
				doc_param("attenuation", "float", false, "Omni/Spot attenuation."),
				doc_param("spot_angle", "float", false, "Spot cone angle in degrees."),
				doc_param("spot_angle_attenuation", "float", false, "Spot angle falloff."),
				doc_param("position", "Vector3", false, "Local position."),
				doc_param("rotation", "Vector3", false, "Local rotation in degrees."),
			],
		},
		"scene3d.set_material": {
			"description": "Assign a new StandardMaterial3D to a MeshInstance3D surface, configured from albedo/metallic/roughness/normal/emission/transparency/cull params. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MeshInstance3D."),
				doc_param("surface_index", "int", false, "Which surface to override (default 0)."),
				doc_param("albedo_color", "Color", false, "Base color."),
				doc_param("albedo_texture", "String", false, "res:// albedo texture path."),
				doc_param("metallic", "float", false, "Metallic 0..1 (default 0)."),
				doc_param("roughness", "float", false, "Roughness 0..1 (default 1)."),
				doc_param("metallic_texture", "String", false, "res:// metallic texture."),
				doc_param("roughness_texture", "String", false, "res:// roughness texture."),
				doc_param("normal_texture", "String", false, "res:// normal map (enables normal mapping)."),
				doc_param("emission", "Color", false, "Emission color (enables emission)."),
				doc_param("emission_color", "Color", false, "Alias for --emission."),
				doc_param("emission_energy", "float", false, "Emission energy multiplier."),
				doc_param("emission_texture", "String", false, "res:// emission texture."),
				doc_param("transparency", "String", false, "DISABLED/ALPHA/ALPHA_SCISSOR/ALPHA_HASH/ALPHA_DEPTH_PRE_PASS (or 0-4)."),
				doc_param("cull_mode", "String", false, "BACK/FRONT/DISABLED (or 0-2)."),
			],
		},
		"scene3d.setup_environment": {
			"description": "Add or update a WorldEnvironment: background, sky, ambient, tonemap, fog, glow, SSAO, SSR, and SDFGI. Reuses an existing node via --node-path. Undoable when created.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("node_path", "NodePath", false, "Existing WorldEnvironment to update instead of creating one."),
				doc_param("name", "String", false, "Node name (default 'WorldEnvironment')."),
				doc_param("background_mode", "String", false, "sky (default), color, canvas, or clear_color."),
				doc_param("background_color", "Color", false, "Background color (color mode)."),
				doc_param("sky", "Dictionary", false, "ProceduralSkyMaterial params (sky/ground colors, sun_angle_max, sky_curve)."),
				doc_param("ambient_light_color", "Color", false, "Ambient light color."),
				doc_param("ambient_light_energy", "float", false, "Ambient light energy."),
				doc_param("ambient_light_source", "String", false, "BACKGROUND/DISABLED/COLOR/SKY (or 0-3)."),
				doc_param("tonemap_mode", "String", false, "LINEAR/REINHARDT/FILMIC/ACES/AGX (or 0-4)."),
				doc_param("tonemap_exposure", "float", false, "Tonemap exposure."),
				doc_param("tonemap_white", "float", false, "Tonemap white point."),
				doc_param("fog_enabled", "bool", false, "Enable distance fog."),
				doc_param("fog_light_color", "Color", false, "Fog color (when enabled)."),
				doc_param("fog_density", "float", false, "Fog density (when enabled)."),
				doc_param("fog_light_energy", "float", false, "Fog light energy (when enabled)."),
				doc_param("glow_enabled", "bool", false, "Enable glow/bloom."),
				doc_param("glow_intensity", "float", false, "Glow intensity (when enabled)."),
				doc_param("glow_strength", "float", false, "Glow strength (when enabled)."),
				doc_param("glow_bloom", "float", false, "Glow bloom (when enabled)."),
				doc_param("ssao_enabled", "bool", false, "Enable SSAO."),
				doc_param("ssao_radius", "float", false, "SSAO radius (when enabled)."),
				doc_param("ssao_intensity", "float", false, "SSAO intensity (when enabled)."),
				doc_param("ssr_enabled", "bool", false, "Enable screen-space reflections."),
				doc_param("ssr_max_steps", "int", false, "SSR max steps (when enabled; default 64)."),
				doc_param("ssr_fade_in", "float", false, "SSR fade-in (when enabled)."),
				doc_param("ssr_fade_out", "float", false, "SSR fade-out (when enabled)."),
				doc_param("sdfgi_enabled", "bool", false, "Enable SDFGI global illumination."),
			],
		},
		"scene3d.setup_camera": {
			"description": "Add or update a Camera3D: projection, fov/size, clipping, cull mask, transform, and optional environment. Reuses an existing node via --node-path. Undoable when created.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("node_path", "NodePath", false, "Existing Camera3D to update instead of creating one."),
				doc_param("name", "String", false, "Node name (default 'Camera3D')."),
				doc_param("projection", "String", false, "perspective, orthogonal, or frustum (or 0-2)."),
				doc_param("fov", "float", false, "Field of view (perspective)."),
				doc_param("size", "float", false, "Orthographic size."),
				doc_param("near", "float", false, "Near clip distance."),
				doc_param("far", "float", false, "Far clip distance."),
				doc_param("cull_mask", "int", false, "Visibility layer cull mask."),
				doc_param("current", "bool", false, "Make this the active camera."),
				doc_param("position", "Vector3", false, "Local position (default 0,1,3 for a new camera)."),
				doc_param("rotation", "Vector3", false, "Local rotation in degrees."),
				doc_param("look_at", "Vector3", false, "Point to aim the camera at."),
				doc_param("environment_path", "String", false, "res:// Environment resource to attach."),
			],
		},
		"scene3d.add_gridmap": {
			"description": "Add or update a GridMap, optionally with a --mesh-library-path and a --cells list to paint. Undoable when created.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("node_path", "NodePath", false, "Existing GridMap to update."),
				doc_param("name", "String", false, "Node name (default 'GridMap')."),
				doc_param("mesh_library_path", "String", false, "res:// .meshlib/.tres MeshLibrary."),
				doc_param("cell_size", "Vector3", false, "Cell size."),
				doc_param("position", "Vector3", false, "Local position."),
				doc_param("cells", "Array", false, "Cells to set: [{x,y,z,item,orientation}, ...]."),
			],
		},
		"scene3d.add_body": {
			"description": "Add a 3D physics body with its CollisionShape3D and shape in one call. Primitive shapes from size/radius/height. With --from-mesh the body is seated on that MeshInstance3D (rotation and origin; its scale is baked into the shape), a primitive is sized to the mesh bounds unless size/radius/height are given, and trimesh/convex build the collider from the mesh geometry; --reparent-mesh moves the mesh under the body so the two move together. One undo step.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("type", "String", false, "StaticBody3D (default), CharacterBody3D, RigidBody3D, or Area3D."),
				doc_param("shape", "String", false, "box (default), sphere, capsule, trimesh, or convex."),
				doc_param("name", "String", false, "Body node name (default the type)."),
				doc_param("size", "Vector3", false, "Box size (default 1,1,1, or the mesh bounds with --from-mesh)."),
				doc_param("radius", "float", false, "Sphere/capsule radius (default 0.5, or fitted to the mesh bounds with --from-mesh)."),
				doc_param("height", "float", false, "Capsule height (default 2, or the mesh's Y extent with --from-mesh)."),
				doc_param("from_mesh", "NodePath", false, "MeshInstance3D to seat the body on and size the shape from (required for trimesh/convex). The result reports fit and the baked scale."),
				doc_param("reparent_mesh", "bool", false, "With --from-mesh: move the MeshInstance3D under the new body, keeping its world placement (default false)."),
				doc_param("position", "Vector3", false, "Local position. Not accepted with --from-mesh, which seats the body on the mesh."),
			],
		},
	}
