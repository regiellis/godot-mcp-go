@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Reusable material resources. The gap this fills: scene3d.set_material bakes a
## throwaway StandardMaterial3D as a single MeshInstance3D surface-override — it can't
## save a shareable .tres, can't do triplanar (the greybox prototype-texture need), and
## can't target CSG / Sprite3D / a GridMap mesh-library item. This group does all three.
##
## A texture path can't be set through node.set/node.add_resource (it needs load()), so
## .create/.set are the supported way to wire albedo/normal/roughness/emission/ORM maps.


func get_commands() -> Dictionary:
	return {
		"material.create": _create,
		"material.set": _set_props,
		"material.apply": _apply,
		"material.info": _info,
	}


# --- Param helpers ----------------------------------------------------------

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


# --- create / set -----------------------------------------------------------

func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not (path.ends_with(".tres") or path.ends_with(".res")):
		return error_invalid_params("Material path must end in .tres or .res (got '%s')" % path)
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard

	var force := optional_bool(params, "force", false)
	if FileAccess.file_exists(path) and not force:
		return error_conflict("Material '%s' already exists" % path,
			{"suggestion": "Use material.set to edit it, or pass force=true to overwrite."})

	var type := optional_string(params, "type", "standard").to_lower()
	var mat: BaseMaterial3D
	match type:
		"standard", "standardmaterial3d":
			mat = StandardMaterial3D.new()
		"orm", "ormmaterial3d":
			mat = ORMMaterial3D.new()
		_:
			return error_invalid_params("Unknown type '%s'. Available: standard, orm" % type)

	var warnings := _configure(mat, params)

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err := ResourceSaver.save(mat, path)
	if err != OK:
		return error_internal("Failed to save material: %s" % error_string(err))
	EditorInterface.get_resource_filesystem().update_file(path)

	return success({"path": path, "type": mat.get_class(), "created": true, "warnings": warnings})


func _set_props(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not ResourceLoader.exists(path):
		return error_not_found("Material '%s'" % path, "Use material.create to make a new one")
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard

	var loaded: Resource = load(path)
	if not loaded is BaseMaterial3D:
		return error_invalid_params("'%s' is not a StandardMaterial3D/ORMMaterial3D (is %s)" % [path, loaded.get_class()])
	var mat := loaded as BaseMaterial3D

	var warnings := _configure(mat, params)

	var err := ResourceSaver.save(mat, path)
	if err != OK:
		return error_internal("Failed to save material: %s" % error_string(err))
	EditorInterface.get_resource_filesystem().update_file(path)

	return success({"path": path, "type": mat.get_class(), "updated": true, "warnings": warnings})


## Apply every recognized param onto a BaseMaterial3D. Missing texture files are
## collected as warnings rather than aborting, so one typo doesn't void the material.
func _configure(mat: BaseMaterial3D, params: Dictionary) -> Array:
	var warnings: Array = []

	if params.has("albedo_color"):
		mat.albedo_color = _color_param(params, "albedo_color", mat.albedo_color)
	_apply_texture(mat, "albedo_texture", params, "albedo_texture", warnings)

	if params.has("metallic"):
		mat.metallic = float(params["metallic"])
	if params.has("roughness"):
		mat.roughness = float(params["roughness"])
	_apply_texture(mat, "metallic_texture", params, "metallic_texture", warnings)
	_apply_texture(mat, "roughness_texture", params, "roughness_texture", warnings)

	# ORMMaterial3D packs occlusion/roughness/metallic in one texture.
	if params.has("orm_texture"):
		if mat is ORMMaterial3D:
			_apply_texture(mat, "orm_texture", params, "orm_texture", warnings)
		else:
			warnings.append("orm_texture ignored: material is not an ORMMaterial3D")

	if params.has("normal_texture"):
		mat.normal_enabled = true
		_apply_texture(mat, "normal_texture", params, "normal_texture", warnings)
	if params.has("normal_scale"):
		mat.normal_scale = float(params["normal_scale"])

	if params.has("emission") or params.has("emission_color"):
		mat.emission_enabled = true
		mat.emission = _color_param(params, "emission", _color_param(params, "emission_color", Color.BLACK))
	if params.has("emission_energy"):
		mat.emission_enabled = true
		mat.emission_energy_multiplier = float(params["emission_energy"])
	if params.has("emission_texture"):
		mat.emission_enabled = true
		_apply_texture(mat, "emission_texture", params, "emission_texture", warnings)

	# Triplanar: the greybox prototype-texture key. world_triplanar tiles by world
	# units so a stretched/scaled mesh keeps a uniform grid; uv1_scale sets density.
	if params.has("triplanar"):
		mat.uv1_triplanar = optional_bool(params, "triplanar", false)
	if params.has("world_triplanar"):
		mat.uv1_world_triplanar = optional_bool(params, "world_triplanar", false)
	if params.has("triplanar_sharpness"):
		mat.uv1_triplanar_sharpness = float(params["triplanar_sharpness"])
	if params.has("uv1_scale"):
		mat.uv1_scale = _vector3_param(params, "uv1_scale", mat.uv1_scale)
	if params.has("uv1_offset"):
		mat.uv1_offset = _vector3_param(params, "uv1_offset", mat.uv1_offset)

	if params.has("transparency"):
		match str(params["transparency"]).to_upper():
			"DISABLED", "0": mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			"ALPHA", "1": mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			"ALPHA_SCISSOR", "2": mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			"ALPHA_HASH", "3": mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
			"ALPHA_DEPTH_PRE_PASS", "4": mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			_: warnings.append("unknown transparency '%s'" % params["transparency"])
	if params.has("alpha_scissor_threshold"):
		mat.alpha_scissor_threshold = float(params["alpha_scissor_threshold"])

	if params.has("cull_mode"):
		match str(params["cull_mode"]).to_upper():
			"BACK", "0": mat.cull_mode = BaseMaterial3D.CULL_BACK
			"FRONT", "1": mat.cull_mode = BaseMaterial3D.CULL_FRONT
			"DISABLED", "2": mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			_: warnings.append("unknown cull_mode '%s'" % params["cull_mode"])

	if params.has("shading_mode"):
		match str(params["shading_mode"]).to_upper():
			"UNSHADED", "0": mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			"PER_PIXEL", "1": mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			"PER_VERTEX", "2": mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
			_: warnings.append("unknown shading_mode '%s'" % params["shading_mode"])

	# Crisp/pixel filtering — common for prototype grid skins.
	if params.has("texture_filter"):
		match str(params["texture_filter"]).to_upper():
			"NEAREST", "0": mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			"LINEAR", "1": mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
			"NEAREST_MIPMAP", "2": mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
			"LINEAR_MIPMAP", "3": mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			_: warnings.append("unknown texture_filter '%s'" % params["texture_filter"])

	return warnings


func _apply_texture(mat: BaseMaterial3D, prop: String, params: Dictionary, key: String, warnings: Array) -> void:
	if not params.has(key):
		return
	var tex_path := str(params[key])
	if tex_path.is_empty():
		mat.set(prop, null)
		return
	if not ResourceLoader.exists(tex_path):
		warnings.append("%s '%s' not found — skipped" % [key, tex_path])
		return
	var tex: Resource = load(tex_path)
	if not tex is Texture2D:
		warnings.append("%s '%s' is not a Texture2D — skipped" % [key, tex_path])
		return
	mat.set(prop, tex as Texture2D)


# --- apply ------------------------------------------------------------------

func _apply(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])

	var rm := require_string(params, "material_path")
	if rm[1] != null:
		return rm[1]
	if not ResourceLoader.exists(rm[0]):
		return error_not_found("Material '%s'" % rm[0])
	var mat: Resource = load(rm[0])
	if not mat is Material:
		return error_invalid_params("'%s' is not a Material (is %s)" % [rm[0], mat.get_class()])

	# MeshInstance3D supports per-surface override material; everything else gets a
	# single slot (material_override on GeometryInstance3D, material on CSG/CanvasItem).
	var undo_redo := get_undo_redo()
	if node is MeshInstance3D and params.has("surface_index"):
		var mi := node as MeshInstance3D
		var idx := optional_int(params, "surface_index", 0)
		var surf_count := mi.mesh.get_surface_count() if mi.mesh != null else 0
		if idx < 0 or idx >= surf_count:
			return error_invalid_params("surface_index %d out of range (mesh has %d surfaces)" % [idx, surf_count])
		var old: Variant = mi.get_surface_override_material(idx)
		undo_redo.create_action("MCP: Apply material to %s surface %d" % [mi.name, idx])
		undo_redo.add_do_method(mi, "set_surface_override_material", idx, mat)
		undo_redo.add_undo_method(mi, "set_surface_override_material", idx, old)
		undo_redo.commit_action()
		return success({"node_path": rn[0], "material_path": rm[0], "target": "surface_override[%d]" % idx})

	# Slot resolution. An explicit --slot wins. Otherwise: CSG shapes use their own
	# `material` (what a CSG bake consumes) even though they're GeometryInstance3D;
	# other GeometryInstance3D get material_override; 2D CanvasItem gets `material`.
	var slot := optional_string(params, "slot", "auto").to_lower()
	var prop := ""
	match slot:
		"override", "material_override":
			if not node is GeometryInstance3D:
				return error_invalid_params("Node '%s' (%s) has no material_override" % [rn[0], node.get_class()])
			prop = "material_override"
		"material":
			if not "material" in node:
				return error_invalid_params("Node '%s' (%s) has no `material` property" % [rn[0], node.get_class()])
			prop = "material"
		"auto":
			if node is CSGShape3D and "material" in node:
				prop = "material"
			elif node is GeometryInstance3D:
				prop = "material_override"
			elif "material" in node:
				prop = "material"
			else:
				return error_invalid_params("Node '%s' (%s) has no material slot" % [rn[0], node.get_class()])
		_:
			return error_invalid_params("Unknown slot '%s'. Use auto, override, or material" % slot)

	var old_value: Variant = node.get(prop)
	undo_redo.create_action("MCP: Apply material to %s" % node.name)
	undo_redo.add_do_property(node, prop, mat)
	undo_redo.add_undo_property(node, prop, old_value)
	undo_redo.commit_action()
	return success({"node_path": rn[0], "material_path": rm[0], "target": prop})


# --- info -------------------------------------------------------------------

func _info(params: Dictionary) -> Dictionary:
	var mat: BaseMaterial3D = null
	var src := ""

	if params.has("path"):
		var path := str(params["path"])
		if not ResourceLoader.exists(path):
			return error_not_found("Material '%s'" % path)
		var loaded: Resource = load(path)
		if not loaded is BaseMaterial3D:
			return error_invalid_params("'%s' is not a BaseMaterial3D (is %s)" % [path, loaded.get_class()])
		mat = loaded as BaseMaterial3D
		src = path
	elif params.has("node_path"):
		if get_edited_root() == null:
			return error_no_scene()
		var node := find_node_by_path(str(params["node_path"]))
		if node == null:
			return error_not_found("Node at '%s'" % params["node_path"])
		var found: Variant = null
		if node is GeometryInstance3D and (node as GeometryInstance3D).material_override != null:
			found = (node as GeometryInstance3D).material_override
		elif node is MeshInstance3D and (node as MeshInstance3D).get_surface_override_material(0) != null:
			found = (node as MeshInstance3D).get_surface_override_material(0)
		elif "material" in node:
			found = node.get("material")
		if not found is BaseMaterial3D:
			return error_not_found("BaseMaterial3D on '%s'" % params["node_path"])
		mat = found as BaseMaterial3D
		src = str(params["node_path"])
	else:
		return error_invalid_params("Provide 'path' (a .tres) or 'node_path'")

	var info := {
		"source": src,
		"type": mat.get_class(),
		"albedo_color": str(mat.albedo_color),
		"metallic": mat.metallic,
		"roughness": mat.roughness,
		"emission_enabled": mat.emission_enabled,
		"transparency": mat.transparency,
		"cull_mode": mat.cull_mode,
		"triplanar": mat.uv1_triplanar,
		"world_triplanar": mat.uv1_world_triplanar,
		"uv1_scale": str(mat.uv1_scale),
		"textures": _texture_summary(mat),
	}
	if mat.emission_enabled:
		info["emission"] = str(mat.emission)
	return success(info)


func _texture_summary(mat: BaseMaterial3D) -> Dictionary:
	var out := {}
	for slot in ["albedo_texture", "metallic_texture", "roughness_texture", "normal_texture", "emission_texture", "orm_texture"]:
		if slot == "orm_texture" and not mat is ORMMaterial3D:
			continue
		var tex: Variant = mat.get(slot)
		if tex is Texture2D:
			out[slot] = (tex as Texture2D).resource_path
	return out


func get_command_docs() -> Dictionary:
	return {
		"material.create": {
			"description": "Create a reusable StandardMaterial3D/ORMMaterial3D .tres (the supported way to wire texture paths + triplanar, which node.set/node.add_resource can't reach). Refuses to overwrite without --force.",
			"params": [
				doc_param("path", "String", true, "Save path for the material; must end in .tres or .res."),
				doc_param("type", "String", false, "'standard' (default, StandardMaterial3D) or 'orm' (ORMMaterial3D)."),
				doc_param("force", "bool", false, "Overwrite an existing file at --path."),
				doc_param("albedo_color", "Color", false, "Base color (name, #hex, or Color(r,g,b,a))."),
				doc_param("albedo_texture", "String", false, "Path to the albedo Texture2D (empty string clears it; missing file becomes a warning, not an error)."),
				doc_param("metallic", "float", false, "Metallic scalar 0..1."),
				doc_param("roughness", "float", false, "Roughness scalar 0..1."),
				doc_param("metallic_texture", "String", false, "Path to the metallic map."),
				doc_param("roughness_texture", "String", false, "Path to the roughness map."),
				doc_param("orm_texture", "String", false, "Path to a packed occlusion/roughness/metallic map (ORMMaterial3D only; warned + ignored on a StandardMaterial3D)."),
				doc_param("normal_texture", "String", false, "Path to a normal map (also enables normal mapping)."),
				doc_param("normal_scale", "float", false, "Normal-map strength."),
				doc_param("emission", "Color", false, "Emission color (also enables emission); --emission-color is an alias."),
				doc_param("emission_color", "Color", false, "Alias for --emission."),
				doc_param("emission_energy", "float", false, "Emission energy multiplier (also enables emission)."),
				doc_param("emission_texture", "String", false, "Path to an emission map (also enables emission)."),
				doc_param("triplanar", "bool", false, "Enable triplanar UV1 mapping (the prototype-grid skin key)."),
				doc_param("world_triplanar", "bool", false, "Tile triplanar by world units so a scaled mesh keeps a uniform grid."),
				doc_param("triplanar_sharpness", "float", false, "Triplanar blend sharpness."),
				doc_param("uv1_scale", "Vector3", false, "UV1 scale (triplanar tiling density)."),
				doc_param("uv1_offset", "Vector3", false, "UV1 offset."),
				doc_param("transparency", "String", false, "DISABLED/ALPHA/ALPHA_SCISSOR/ALPHA_HASH/ALPHA_DEPTH_PRE_PASS (or 0-4)."),
				doc_param("alpha_scissor_threshold", "float", false, "Alpha-scissor cutoff."),
				doc_param("cull_mode", "String", false, "BACK/FRONT/DISABLED (or 0-2)."),
				doc_param("shading_mode", "String", false, "UNSHADED/PER_PIXEL/PER_VERTEX (or 0-2)."),
				doc_param("texture_filter", "String", false, "NEAREST/LINEAR/NEAREST_MIPMAP/LINEAR_MIPMAP (or 0-3); NEAREST for crisp pixel grids."),
			],
		},
		"material.set": {
			"description": "Edit an existing material .tres in place — same property/texture params as material.create (minus --type/--force). Missing texture files come back as warnings, not errors.",
			"params": [
				doc_param("path", "String", true, "Path to the existing StandardMaterial3D/ORMMaterial3D .tres to edit."),
				doc_param("albedo_color", "Color", false, "Base color (name, #hex, or Color(r,g,b,a))."),
				doc_param("albedo_texture", "String", false, "Path to the albedo Texture2D (empty string clears it)."),
				doc_param("metallic", "float", false, "Metallic scalar 0..1."),
				doc_param("roughness", "float", false, "Roughness scalar 0..1."),
				doc_param("metallic_texture", "String", false, "Path to the metallic map."),
				doc_param("roughness_texture", "String", false, "Path to the roughness map."),
				doc_param("orm_texture", "String", false, "Path to a packed ORM map (ORMMaterial3D only)."),
				doc_param("normal_texture", "String", false, "Path to a normal map (also enables normal mapping)."),
				doc_param("normal_scale", "float", false, "Normal-map strength."),
				doc_param("emission", "Color", false, "Emission color (also enables emission); --emission-color is an alias."),
				doc_param("emission_color", "Color", false, "Alias for --emission."),
				doc_param("emission_energy", "float", false, "Emission energy multiplier (also enables emission)."),
				doc_param("emission_texture", "String", false, "Path to an emission map (also enables emission)."),
				doc_param("triplanar", "bool", false, "Enable triplanar UV1 mapping."),
				doc_param("world_triplanar", "bool", false, "Tile triplanar by world units."),
				doc_param("triplanar_sharpness", "float", false, "Triplanar blend sharpness."),
				doc_param("uv1_scale", "Vector3", false, "UV1 scale (triplanar tiling density)."),
				doc_param("uv1_offset", "Vector3", false, "UV1 offset."),
				doc_param("transparency", "String", false, "DISABLED/ALPHA/ALPHA_SCISSOR/ALPHA_HASH/ALPHA_DEPTH_PRE_PASS (or 0-4)."),
				doc_param("alpha_scissor_threshold", "float", false, "Alpha-scissor cutoff."),
				doc_param("cull_mode", "String", false, "BACK/FRONT/DISABLED (or 0-2)."),
				doc_param("shading_mode", "String", false, "UNSHADED/PER_PIXEL/PER_VERTEX (or 0-2)."),
				doc_param("texture_filter", "String", false, "NEAREST/LINEAR/NEAREST_MIPMAP/LINEAR_MIPMAP (or 0-3)."),
			],
		},
		"material.apply": {
			"description": "Assign a Material .tres to a node's material slot. MeshInstance3D + --surface-index sets a per-surface override; otherwise the slot is picked by --slot. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node (MeshInstance3D, GeometryInstance3D, CSGShape3D, or a CanvasItem)."),
				doc_param("material_path", "String", true, "Path to the Material resource to assign."),
				doc_param("surface_index", "int", false, "MeshInstance3D only: set the per-surface override at this index instead of a whole-node slot."),
				doc_param("slot", "String", false, "Slot to write: 'auto' (default; CSG/CanvasItem 'material', else material_override), 'override', or 'material'."),
			],
		},
		"material.info": {
			"description": "Summarize a material's key properties and texture slots. Reads from a .tres via --path OR the material on a node via --node-path (provide exactly one).",
			"params": [
				doc_param("path", "String", false, "Path to a material .tres. Provide this OR --node-path."),
				doc_param("node_path", "NodePath", false, "Node whose material_override/surface-0/`material` slot to read. Provide this OR --path."),
			],
		},
	}
