@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


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


const _BODY_TYPES_3D := ["StaticBody3D", "CharacterBody3D", "RigidBody3D", "Area3D"]
const _SHAPES_3D := ["box", "sphere", "capsule", "trimesh", "convex"]


## A 3D physics body with its CollisionShape3D + shape resource in one call — the
## scene2d.add_body counterpart the 3D side lacked. Primitive shapes come from --size/
## --radius/--height; trimesh/convex build a collider from a --from-mesh MeshInstance3D
## (the common "make this imported geometry collidable" need).
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

	var shape: Shape3D = null
	match shape_kind:
		"box":
			var b := BoxShape3D.new()
			b.size = vec3_param(params, "size", Vector3.ONE)
			shape = b
		"sphere":
			var s := SphereShape3D.new()
			s.radius = float(params.get("radius", 0.5))
			shape = s
		"capsule":
			var c := CapsuleShape3D.new()
			c.radius = float(params.get("radius", 0.5))
			c.height = float(params.get("height", 2.0))
			shape = c
		"trimesh", "convex":
			var mp := optional_string(params, "from_mesh", "")
			if mp.is_empty():
				return error_invalid_params("shape '%s' needs --from-mesh <MeshInstance3D node path>" % shape_kind)
			var mn := find_node_by_path(mp)
			if mn == null or not mn is MeshInstance3D:
				return error_not_found("MeshInstance3D '%s'" % mp, "Pass --from-mesh a MeshInstance3D path")
			var mesh := (mn as MeshInstance3D).mesh
			if mesh == null:
				return error_invalid_params("MeshInstance3D '%s' has no mesh" % mp)
			shape = mesh.create_trimesh_shape() if shape_kind == "trimesh" else mesh.create_convex_shape()
			if shape == null:
				return error_internal("could not build a %s shape from '%s'" % [shape_kind, mp])

	var body: Node3D = ClassDB.instantiate(type)
	body.name = optional_string(params, "name", type)
	body.position = vec3_param(params, "position", Vector3.ZERO)
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape

	add_child_with_undo(parent, body, root, "MCP: Add %s" % type)
	add_child_with_undo(body, col, root, "MCP: Add CollisionShape3D")
	return success({
		"node_path": str(root.get_path_to(body)), "name": String(body.name), "type": type,
		"collision_path": str(root.get_path_to(col)), "shape": shape_kind,
	})


# --- Parameter parsing helpers ----------------------------------------------

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
		var mesh_properties: Dictionary = params.get("mesh_properties", {})
		for prop_name: String in mesh_properties:
			if prop_name in mesh_res:
				mesh_res.set(prop_name, PropertyParser.parse_value(mesh_properties[prop_name], typeof(mesh_res.get(prop_name))))
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
				env.tonemap_mode = Environment.TONE_MAPPER_AGX
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
			"description": "Add a 3D physics body with its CollisionShape3D and shape in one call. Primitive shapes from size/radius/height, or a trimesh/convex collider from a --from-mesh MeshInstance3D. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("type", "String", false, "StaticBody3D (default), CharacterBody3D, RigidBody3D, or Area3D."),
				doc_param("shape", "String", false, "box (default), sphere, capsule, trimesh, or convex."),
				doc_param("name", "String", false, "Body node name (default the type)."),
				doc_param("size", "Vector3", false, "Box size (default 1,1,1)."),
				doc_param("radius", "float", false, "Sphere/capsule radius (default 0.5)."),
				doc_param("height", "float", false, "Capsule height (default 2)."),
				doc_param("from_mesh", "NodePath", false, "MeshInstance3D to build a trimesh/convex collider from (required for those shapes)."),
				doc_param("position", "Vector3", false, "Local position."),
			],
		},
	}
