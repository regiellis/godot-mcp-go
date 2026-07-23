@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Lighting / global-illumination authoring — the art-pass layer scene3d.setup_lighting
## (which only places Light3D nodes) doesn't cover. Adds GI nodes (VoxelGI/LightmapGI/
## ReflectionProbe/OccluderInstance3D/LightmapProbe), sets GI participation (light bake mode,
## geometry gi_mode), toggles SDFGI on the WorldEnvironment, and bakes.
##
## Reality check from the live 4.7 API (verified via engine.class_info, not memory): only
## VoxelGI exposes a script-callable bake(). LightmapGI and OccluderInstance3D bake ONLY through
## the editor toolbar/plugin in 4.7 — there is no node bake() — so lighting.bake configures and
## bakes VoxelGI, and returns a clear error for the others telling you to bake from the toolbar.
##
## The *_2d commands cover 2D lighting (a separate render path). A PointLight2D is INVISIBLE
## without a texture, so lighting.add_2d generates a radial GradientTexture2D and assigns it —
## the whole point of the wrapper over raw node.add. occluder_2d builds the OccluderPolygon2D a
## LightOccluder2D needs; canvas_modulate sets the scene-wide ambient (darkness) a 2D light lifts.

const _GI_TYPES := ["VoxelGI", "LightmapGI", "ReflectionProbe", "OccluderInstance3D", "LightmapProbe"]
const _VOXEL_SUBDIV := {64: 0, 128: 1, 256: 2, 512: 3}
const _BAKE_MODES := {"disabled": 0, "static": 1, "dynamic": 2}


func get_commands() -> Dictionary:
	return {
		"lighting.add": _add,
		"lighting.bake": _bake,
		"lighting.set_gi": _set_gi,
		"lighting.set_sdfgi": _set_sdfgi,
		"lighting.add_2d": _add_2d,
		"lighting.occluder_2d": _occluder_2d,
		"lighting.canvas_modulate": _canvas_modulate,
		"lighting.emissive_2d": _emissive_2d,
		"lighting.normal_map_2d": _normal_map_2d,
		"lighting.glow_2d": _glow_2d,
	}


func _v3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


# --- add --------------------------------------------------------------------

func _add(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("lighting nodes need a 3D scene")
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var type := optional_string(params, "type", "")
	if type not in _GI_TYPES:
		return error_invalid_params("type must be one of %s" % [_GI_TYPES])

	var node: Node3D = ClassDB.instantiate(type)
	node.name = optional_string(params, "name", type)

	# Type-specific conveniences.
	if type == "VoxelGI":
		if params.has("size"):
			node.size = _v3(params, "size", Vector3(20, 20, 20))
		if params.has("subdiv"):
			var sd := optional_int(params, "subdiv", 128)
			if not _VOXEL_SUBDIV.has(sd):
				node.free()
				return error_invalid_params("subdiv must be one of %s" % [_VOXEL_SUBDIV.keys()])
			node.subdiv = _VOXEL_SUBDIV[sd]
	elif type == "ReflectionProbe":
		if params.has("size"):
			node.size = _v3(params, "size", Vector3(20, 20, 20))
		if params.has("update_mode"):
			node.update_mode = 0 if str(params["update_mode"]).to_lower() in ["once", "0"] else 1
	elif type == "LightmapGI":
		if params.has("bounces"):
			node.bounces = optional_int(params, "bounces", 3)
		if params.has("quality"):
			node.quality = optional_int(params, "quality", 1)

	# Any extra props, version-agnostic.
	var props: Dictionary = params.get("properties", {})
	var ignored: Array = []
	for p: String in props:
		if p in node:
			node.set(p, PropertyParser.parse_value(props[p], typeof(node.get(p))))
		else:
			ignored.append(p)

	node.position = _v3(params, "position", Vector3.ZERO)
	add_child_with_undo(parent, node, root, "MCP: Add %s" % type)
	return success({"node_path": str(root.get_path_to(node)), "name": String(node.name), "type": type, "ignored_properties": ignored})


# --- bake -------------------------------------------------------------------

func _bake(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])

	if node is VoxelGI:
		(node as VoxelGI).bake()
		var baked: bool = (node as VoxelGI).get_probe_data() != null
		return success({"node_path": rn[0], "type": "VoxelGI", "baked": baked,
			"note": "" if baked else "bake() ran but produced no probe_data — a headless editor has no rendering device for GI; bake from a windowed editor."})

	if node is LightmapGI or node is OccluderInstance3D:
		return error(-32000, "%s cannot be baked from script in 4.7 (no node bake() exists)" % node.get_class(),
			{"suggestion": "Configure it here, then trigger the bake from the editor toolbar (Bake Lightmaps / Bake Occluders). Only VoxelGI exposes a scriptable bake()."} as Dictionary)

	return error_invalid_params("Node '%s' (%s) is not a bakeable GI node" % [rn[0], node.get_class()])


# --- set_gi -----------------------------------------------------------------

## Set GI participation: a Light3D's light_bake_mode, or a GeometryInstance3D's gi_mode.
func _set_gi(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])

	var rm := require_string(params, "mode")
	if rm[1] != null:
		return rm[1]
	var mode := str(rm[0]).to_lower()
	if not _BAKE_MODES.has(mode):
		return error_invalid_params("mode must be disabled, static, or dynamic")
	var val: int = _BAKE_MODES[mode]

	var prop := ""
	if node is Light3D:
		prop = "light_bake_mode"
	elif node is GeometryInstance3D:
		prop = "gi_mode"
	else:
		return error_invalid_params("Node '%s' (%s) is neither a Light3D nor a GeometryInstance3D" % [rn[0], node.get_class()])

	var old: Variant = node.get(prop)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set %s on %s" % [prop, node.name])
	undo_redo.add_do_property(node, prop, val)
	undo_redo.add_undo_property(node, prop, old)
	undo_redo.commit_action()
	return success({"node_path": rn[0], prop: mode})


# --- set_sdfgi --------------------------------------------------------------

## Toggle/configure SDFGI on a WorldEnvironment's Environment (dynamic GI, no bake).
func _set_sdfgi(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()

	var we: WorldEnvironment = null
	if params.has("node_path"):
		var n := find_node_by_path(str(params["node_path"]))
		if n is WorldEnvironment:
			we = n as WorldEnvironment
	else:
		we = _find_world_environment(get_edited_root())
	if we == null:
		return error_not_found("WorldEnvironment", "Add one with scene3d.setup_environment first (or pass --node-path)")
	if we.environment == null:
		return error(-32000, "WorldEnvironment has no Environment resource")

	var env := we.environment
	var enabled := optional_bool(params, "enabled", true)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set SDFGI")
	undo_redo.add_undo_property(env, "sdfgi_enabled", env.sdfgi_enabled)
	undo_redo.add_do_property(env, "sdfgi_enabled", enabled)
	if params.has("cascades"):
		undo_redo.add_undo_property(env, "sdfgi_cascades", env.sdfgi_cascades)
		undo_redo.add_do_property(env, "sdfgi_cascades", optional_int(params, "cascades", 4))
	if params.has("energy"):
		undo_redo.add_undo_property(env, "sdfgi_energy", env.sdfgi_energy)
		undo_redo.add_do_property(env, "sdfgi_energy", float(params["energy"]))
	undo_redo.commit_action()
	return success({"sdfgi_enabled": enabled, "world_environment": str(get_edited_root().get_path_to(we))})


func _find_world_environment(start: Node) -> WorldEnvironment:
	var queue: Array[Node] = [start]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is WorldEnvironment:
			return n as WorldEnvironment
		for c in n.get_children():
			queue.append(c)
	return null


# --- 2D lighting ------------------------------------------------------------

const _LIGHT_2D_TYPES := ["PointLight2D", "DirectionalLight2D"]


func _v2(params: Dictionary, key: String, default: Vector2) -> Vector2:
	return vec2_param(params, key, default)


func _color_param(params: Dictionary, key: String, default: Color) -> Color:
	if not params.has(key):
		return default
	return PropertyParser.parse_value(params[key], TYPE_COLOR)


## Guard: 2D lighting needs a non-3D (canvas) scene. Returns [root, error_or_null].
func _require_scene_root_2d() -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	if root is Node3D:
		return [null, error_invalid_params("2D lighting needs a 2D scene (root is a Node3D)")]
	return [root, null]


## A white-to-transparent radial texture so a PointLight2D actually renders. `radius_px`
## is the light's reach in pixels (texture is 2*radius square, texture_scale left at 1).
func _make_radial_texture(radius_px: int) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = maxi(2, radius_px * 2)
	tex.height = maxi(2, radius_px * 2)
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


func _add_2d(params: Dictionary) -> Dictionary:
	var rr := _require_scene_root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var type := optional_string(params, "type", "PointLight2D")
	if type not in _LIGHT_2D_TYPES:
		return error_invalid_params("type must be one of %s" % [_LIGHT_2D_TYPES])

	var node: Node2D = ClassDB.instantiate(type)
	node.name = optional_string(params, "name", type)
	var made_texture := false
	if type == "PointLight2D":
		# A PointLight2D renders nothing without a texture — generate one so the light shows.
		var radius := optional_int(params, "range", 128)
		(node as PointLight2D).texture = _make_radial_texture(radius)
		made_texture = true
		if params.has("texture_scale"):
			(node as PointLight2D).texture_scale = float(params["texture_scale"])

	# Common Light2D properties.
	node.set("color", _color_param(params, "color", Color(1, 1, 1, 1)))
	node.set("energy", float(params.get("energy", 1.0)))
	if params.has("shadows"):
		node.set("shadow_enabled", optional_bool(params, "shadows", false))

	# Any extra props, version-agnostic (same pattern as _add).
	var props: Dictionary = params.get("properties", {})
	var ignored: Array = []
	for p: String in props:
		if p in node:
			node.set(p, PropertyParser.parse_value(props[p], typeof(node.get(p))))
		else:
			ignored.append(p)

	node.position = _v2(params, "position", Vector2.ZERO)
	add_child_with_undo(parent, node, root, "MCP: Add %s" % type)
	return success({
		"node_path": str(root.get_path_to(node)), "name": String(node.name), "type": type,
		"generated_texture": made_texture, "ignored_properties": ignored,
	})


func _occluder_2d(params: Dictionary) -> Dictionary:
	var rr := _require_scene_root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var occ := OccluderPolygon2D.new()
	if params.has("polygon"):
		var pr := require_array(params, "polygon")
		if pr[1] != null:
			return pr[1]
		var pts := PackedVector2Array()
		for e in pr[0]:
			if e is Array and (e as Array).size() >= 2:
				pts.append(Vector2(float(e[0]), float(e[1])))
			else:
				pts.append(PropertyParser.parse_value(e, TYPE_VECTOR2))
		if pts.size() < 2:
			return error_invalid_params("polygon needs at least 2 points")
		occ.polygon = pts
	else:
		# Default: a rectangle centered on the node, from --size (w,h).
		var size := _v2(params, "size", Vector2(64, 64))
		var hw := size.x * 0.5
		var hh := size.y * 0.5
		occ.polygon = PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	occ.closed = optional_bool(params, "closed", true)

	var node := LightOccluder2D.new()
	node.name = optional_string(params, "name", "LightOccluder2D")
	node.occluder = occ
	if params.has("sdf_collision"):
		node.sdf_collision = optional_bool(params, "sdf_collision", true)
	if params.has("occluder_light_mask"):
		node.occluder_light_mask = optional_int(params, "occluder_light_mask", 1)
	node.position = _v2(params, "position", Vector2.ZERO)
	add_child_with_undo(parent, node, root, "MCP: Add LightOccluder2D")
	return success({
		"node_path": str(root.get_path_to(node)), "name": String(node.name),
		"points": occ.polygon.size(), "closed": occ.closed,
	})


## Exempt a CanvasItem from 2D lighting/darkness (fire, sparks, lasers, HUD glow):
## gives it a CanvasItemMaterial with light_mode UNSHADED, optionally additive blending.
## --mode normal restores lighting (light_mode LIGHT_ONLY also accepted via --mode light_only).
func _emissive_2d(params: Dictionary) -> Dictionary:
	var nr := resolve_node_param(params, "node_path")
	if nr[1] != null:
		return nr[1]
	var node: Node = nr[0]
	if not node is CanvasItem:
		return error_invalid_params("Node '%s' is not a CanvasItem" % params.get("node_path"))

	var mode := optional_string(params, "mode", "unshaded").to_lower()
	var light_mode: int
	match mode:
		"unshaded": light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		"normal": light_mode = CanvasItemMaterial.LIGHT_MODE_NORMAL
		"light_only": light_mode = CanvasItemMaterial.LIGHT_MODE_LIGHT_ONLY
		_:
			return error_invalid_params("mode must be unshaded, normal, or light_only")

	var mat := CanvasItemMaterial.new()
	mat.light_mode = light_mode
	if optional_bool(params, "additive", false):
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	set_property_with_undo(node, "material", mat, "MCP: Set 2D light mode")
	return success({
		"node_path": params.get("node_path"),
		"light_mode": mode,
		"blend_mode": "add" if mat.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD else "mix",
	})


## Give a Sprite2D/TextureRect a CanvasTexture so 2D lights shade it with a normal
## (and optional specular) map. Diffuse defaults to the node's current texture.
func _normal_map_2d(params: Dictionary) -> Dictionary:
	var nr := resolve_node_param(params, "node_path")
	if nr[1] != null:
		return nr[1]
	var node: Node = nr[0]
	if not "texture" in node:
		return error_invalid_params("Node '%s' has no texture property" % params.get("node_path"))
	var rn := require_string(params, "normal")
	if rn[1] != null:
		return rn[1]
	var normal_path: String = rn[0]
	if not ResourceLoader.exists(normal_path, "Texture2D"):
		return error_not_found("Normal map '%s'" % normal_path)

	var canvas_tex := CanvasTexture.new()
	var diffuse_path := optional_string(params, "diffuse", "")
	if not diffuse_path.is_empty():
		if not ResourceLoader.exists(diffuse_path, "Texture2D"):
			return error_not_found("Diffuse texture '%s'" % diffuse_path)
		canvas_tex.diffuse_texture = load(diffuse_path)
	else:
		var current: Variant = node.get("texture")
		if current is CanvasTexture:
			canvas_tex.diffuse_texture = (current as CanvasTexture).diffuse_texture
		elif current is Texture2D:
			canvas_tex.diffuse_texture = current
		else:
			return error_invalid_params("Node has no current texture; pass --diffuse")

	canvas_tex.normal_texture = load(normal_path)
	var specular_path := optional_string(params, "specular", "")
	if not specular_path.is_empty():
		if not ResourceLoader.exists(specular_path, "Texture2D"):
			return error_not_found("Specular map '%s'" % specular_path)
		canvas_tex.specular_texture = load(specular_path)
	if params.has("shininess"):
		canvas_tex.specular_shininess = clampf(float(params["shininess"]), 0.0, 1.0)

	set_property_with_undo(node, "texture", canvas_tex, "MCP: Set CanvasTexture")
	return success({
		"node_path": params.get("node_path"),
		"diffuse": canvas_tex.diffuse_texture.resource_path if canvas_tex.diffuse_texture else "",
		"normal": normal_path,
		"specular": specular_path,
	})


## Enable 2D glow: flips rendering/viewport/hdr_2d on (persisted to project.godot,
## needs an editor restart to affect the 2D viewport) and adds/updates a
## WorldEnvironment with glow enabled so bright/additive 2D pixels bloom.
func _glow_2d(params: Dictionary) -> Dictionary:
	var rr := _require_scene_root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]

	var hdr_was_on: bool = ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)
	if not hdr_was_on:
		ProjectSettings.set_setting("rendering/viewport/hdr_2d", true)
		ProjectSettings.save()

	var env_node: WorldEnvironment = null
	for n: Node in walk_tree(root):
		if n is WorldEnvironment:
			env_node = n as WorldEnvironment
			break
	var created := env_node == null
	var env: Environment
	if created:
		env_node = WorldEnvironment.new()
		env_node.name = optional_string(params, "name", "WorldEnvironment")
		env = Environment.new()
		env.background_mode = Environment.BG_CANVAS
		env_node.environment = env
	else:
		env = env_node.environment
		if env == null:
			env = Environment.new()
			env.background_mode = Environment.BG_CANVAS
			env_node.environment = env

	env.glow_enabled = true
	env.glow_bloom = clampf(float(params.get("bloom", 0.1)), 0.0, 1.0)
	env.glow_intensity = float(params.get("intensity", 0.8))
	env.glow_hdr_threshold = float(params.get("threshold", 1.0))
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	if created:
		add_child_with_undo(root, env_node, root, "MCP: Add 2D glow WorldEnvironment")
	return success({
		"node_path": str(root.get_path_to(env_node)),
		"created": created,
		"hdr_2d": true,
		"hdr_2d_needs_restart": not hdr_was_on,
		"threshold": env.glow_hdr_threshold,
		"intensity": env.glow_intensity,
	})


## Add or update the scene's CanvasModulate — the global 2D tint that makes a lit
## scene dark so 2D lights read. One per canvas; updates the existing one if present.
func _canvas_modulate(params: Dictionary) -> Dictionary:
	var rr := _require_scene_root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var color := _color_param(params, "color", Color(0.15, 0.15, 0.25, 1.0))

	var existing: CanvasModulate = null
	for n: Node in walk_tree(root):
		if n is CanvasModulate:
			existing = n as CanvasModulate
			break
	if existing != null:
		set_property_with_undo(existing, "color", color, "MCP: Set CanvasModulate")
		return success({"node_path": str(root.get_path_to(existing)), "color": PropertyParser.serialize_value(color), "created": false})

	var parent := find_node_by_path(optional_string(params, "parent_path", "."))
	if parent == null:
		parent = root
	var node := CanvasModulate.new()
	node.name = optional_string(params, "name", "CanvasModulate")
	node.color = color
	add_child_with_undo(parent, node, root, "MCP: Add CanvasModulate")
	return success({"node_path": str(root.get_path_to(node)), "color": PropertyParser.serialize_value(color), "created": true})


func get_command_docs() -> Dictionary:
	return {
		"lighting.add": {
			"description": "Add a 3D GI node (VoxelGI/LightmapGI/ReflectionProbe/OccluderInstance3D/LightmapProbe) under --parent-path, with type-specific conveniences. 3D scene. Undoable.",
			"params": [
				doc_param("type", "String", true, "One of VoxelGI, LightmapGI, ReflectionProbe, OccluderInstance3D, LightmapProbe."),
				doc_param("parent_path", "NodePath", false, "Parent, relative to the scene root (default '.'; --parent is an alias)."),
				doc_param("name", "String", false, "Name for the new node (defaults to the type)."),
				doc_param("size", "Vector3", false, "Extents (VoxelGI / ReflectionProbe)."),
				doc_param("subdiv", "int", false, "VoxelGI subdivisions: 64, 128, 256, or 512."),
				doc_param("update_mode", "String", false, "ReflectionProbe: 'once' or 'always'."),
				doc_param("bounces", "int", false, "LightmapGI bounce count."),
				doc_param("quality", "int", false, "LightmapGI bake quality."),
				doc_param("properties", "Dictionary", false, "Extra {property: value}; unknown keys reported as ignored."),
				doc_param("position", "Vector3", false, "Local position."),
			],
		},
		"lighting.bake": {
			"description": "Bake a GI node. Only VoxelGI is script-bakeable in 4.7; LightmapGI/OccluderInstance3D return an error telling you to bake from the editor toolbar. Bake from a windowed editor (headless has no rendering device).",
			"params": [
				doc_param("node_path", "NodePath", true, "The VoxelGI to bake."),
			],
		},
		"lighting.set_gi": {
			"description": "Set GI participation: a Light3D's light_bake_mode, or a GeometryInstance3D's gi_mode. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Light3D or GeometryInstance3D."),
				doc_param("mode", "String", true, "disabled, static, or dynamic."),
			],
		},
		"lighting.set_sdfgi": {
			"description": "Toggle/configure SDFGI (dynamic GI, no bake) on a WorldEnvironment's Environment. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", false, "Target WorldEnvironment; omit to auto-find one in the scene."),
				doc_param("enabled", "bool", false, "Enable SDFGI (default true)."),
				doc_param("cascades", "int", false, "SDFGI cascade count (default 4)."),
				doc_param("energy", "float", false, "SDFGI energy."),
			],
		},
		"lighting.add_2d": {
			"description": "Add a 2D light. A PointLight2D is invisible without a texture, so a radial GradientTexture2D is generated and assigned. 2D (non-Node3D) scene. Undoable.",
			"params": [
				doc_param("type", "String", false, "PointLight2D (default) or DirectionalLight2D."),
				doc_param("parent_path", "NodePath", false, "Parent, relative to the scene root (default '.'; --parent alias)."),
				doc_param("name", "String", false, "Name for the new node (defaults to the type)."),
				doc_param("range", "int", false, "PointLight2D reach in px, sizing the generated radial texture (default 128)."),
				doc_param("texture_scale", "float", false, "PointLight2D texture_scale."),
				doc_param("color", "Color", false, "Light color (default white)."),
				doc_param("energy", "float", false, "Light energy (default 1.0)."),
				doc_param("shadows", "bool", false, "Enable shadow casting (shadow_enabled)."),
				doc_param("properties", "Dictionary", false, "Extra {property: value}; unknown keys reported as ignored."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
		"lighting.occluder_2d": {
			"description": "Add a LightOccluder2D with an OccluderPolygon2D, built from --polygon or a rectangle from --size. 2D scene. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent, relative to the scene root (default '.'; --parent alias)."),
				doc_param("polygon", "Array", false, "JSON array of [x,y] points (>= 2). Provide --polygon or --size."),
				doc_param("size", "Vector2", false, "Rectangle occluder size when --polygon is omitted (default 64x64)."),
				doc_param("closed", "bool", false, "Closed polygon (default true)."),
				doc_param("name", "String", false, "Name for the node (default LightOccluder2D)."),
				doc_param("sdf_collision", "bool", false, "Participate in SDF-based shadows."),
				doc_param("occluder_light_mask", "int", false, "Occluder light mask bits."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
		"lighting.canvas_modulate": {
			"description": "Add or update the scene's CanvasModulate, the global 2D tint that darkens the scene so 2D lights read. One per canvas; updates the existing one if present. 2D scene. Undoable.",
			"params": [
				doc_param("color", "Color", false, "Ambient tint (default a dark blue-grey)."),
				doc_param("parent_path", "NodePath", false, "Parent for a new node (default '.')."),
				doc_param("name", "String", false, "Name for a new node (default CanvasModulate)."),
			],
		},
		"lighting.emissive_2d": {
			"description": "Exempt a CanvasItem from 2D lighting/darkness (fire, sparks, HUD glow) via a CanvasItemMaterial light_mode, optionally additive. --mode normal restores lighting. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target CanvasItem."),
				doc_param("mode", "String", false, "unshaded (default), normal, or light_only."),
				doc_param("additive", "bool", false, "Use additive blend (default false)."),
			],
		},
		"lighting.normal_map_2d": {
			"description": "Wrap a Sprite2D/TextureRect's texture in a CanvasTexture so 2D lights shade it with a normal (and optional specular) map. Diffuse defaults to the node's current texture. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node with a 'texture' property."),
				doc_param("normal", "String", true, "Normal map texture path."),
				doc_param("diffuse", "String", false, "Diffuse texture path (default: the node's current texture)."),
				doc_param("specular", "String", false, "Specular map texture path."),
				doc_param("shininess", "float", false, "Specular shininess 0..1."),
			],
		},
		"lighting.glow_2d": {
			"description": "Enable 2D glow: flips rendering/viewport/hdr_2d on (persisted; needs an editor restart) and adds/updates a glow WorldEnvironment so bright/additive 2D pixels bloom. 2D scene. Undoable.",
			"params": [
				doc_param("bloom", "float", false, "glow_bloom 0..1 (default 0.1)."),
				doc_param("intensity", "float", false, "glow_intensity (default 0.8)."),
				doc_param("threshold", "float", false, "glow_hdr_threshold (default 1.0)."),
				doc_param("name", "String", false, "Name for a new WorldEnvironment (default WorldEnvironment)."),
			],
		},
	}
