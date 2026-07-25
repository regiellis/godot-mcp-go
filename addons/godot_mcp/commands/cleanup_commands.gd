@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Import hygiene — fix what a UE→Godot scene exporter (e.g. UnrealToGodot) gets wrong on the
## way over. Validated against a real export: lighting energy is hardcoded, a single bright
## default WorldEnvironment is stamped on every scene, textures land in the wrong colour space,
## and editor-only geometry (camera bodies, sky domes, water-info meshes) rides along as junk.
##
##   cleanup.strip_junk    — delete editor-only / non-game nodes (CineCam, EnviroDome, WaterInfo, /Engine/Editor*)
##   cleanup.unreal_env    — fix the exported WorldEnvironment (tonemap, blown background_intensity, auto-exposure)
##   cleanup.unreal_lights — drop physical-light-units mode + normalize the garbage intensity the exporter dumps
##   cleanup.fix_imports   — repair *.import source_file paths broken by dropping the export into a subfolder
##
## Exporter-agnostic and re-runnable; wrap risky runs in authoring.checkpoint.

# Node-name / instance-source substrings that mark exporter junk (case-insensitive).
const JUNK_PATTERNS := ["CineCam", "MatineeCam", "EnviroDome", "WaterInfoMesh", "WaterInfoDilated"]
# Any instanced node whose source path contains this is a UE editor asset (camera bodies, gizmos).
const EDITOR_ASSET_MARK := "engine/editor"


func get_commands() -> Dictionary:
	return {
		"cleanup.strip_junk": _strip_junk,
		"cleanup.unreal_env": _unreal_env,
		"cleanup.unreal_lights": _unreal_lights,
		"cleanup.fix_imports": _fix_imports,
	}


const TONEMAP := {"linear": 0, "reinhard": 1, "reinhardt": 1, "filmic": 2, "aces": 3, "agx": 4}


func _str_array(params: Dictionary, key: String, default: Array) -> Array:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Array:
			v = parsed
		else:
			return [String(v)]
	var out: Array = []
	if v is Array:
		for e in v:
			out.append(String(e))
	return out


## Returns a match reason string, or "" if the node is not junk.
func _junk_reason(node: Node, patterns: Array, include_decals: bool, keep: Array) -> String:
	var nm := String(node.name).to_lower()
	var src := ""
	if node.scene_file_path != "":
		src = node.scene_file_path.to_lower()
	for k: String in keep:
		if k != "" and nm.contains(k.to_lower()):
			return ""
	for p: String in patterns:
		var pl := p.to_lower()
		if nm.contains(pl):
			return "name~%s" % p
		if src != "" and src.get_file().contains(pl):
			return "source~%s" % p
	if src.contains(EDITOR_ASSET_MARK):
		return "editor-asset"
	if include_decals and (node is Decal or nm.contains("decal")):
		return "decal"
	return ""


## Delete editor-only / non-game nodes a UE export drags in. Defaults keep real decals; pass
## --include-decals to also remove Decal nodes. --dry-run lists matches without deleting.
func _strip_junk(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var patterns := _str_array(params, "patterns", JUNK_PATTERNS)
	var keep := _str_array(params, "keep", [])
	var include_decals := optional_bool(params, "include_decals", false)
	var dry_run := optional_bool(params, "dry_run", false)

	# collect top-most matches (don't recurse into a matched subtree)
	var matched: Array = []
	var queue: Array[Node] = []
	for c in root.get_children():
		queue.append(c)
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		var reason := _junk_reason(n, patterns, include_decals, keep)
		if reason != "":
			matched.append({"node": n, "path": str(root.get_path_to(n)), "type": n.get_class(), "reason": reason})
		else:
			for c in n.get_children():
				queue.append(c)

	var report: Array = []
	for m: Dictionary in matched:
		report.append({"path": m["path"], "type": m["type"], "reason": m["reason"]})

	if dry_run or matched.is_empty():
		return success({"dry_run": dry_run, "matched": matched.size(), "deleted": 0, "nodes": report})

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Strip %d junk nodes" % matched.size())
	for m: Dictionary in matched:
		var n: Node = m["node"]
		var parent := n.get_parent()
		undo_redo.add_do_method(parent, "remove_child", n)
		undo_redo.add_undo_method(parent, "add_child", n)
		undo_redo.add_undo_method(n, "set_owner", root)
		undo_redo.add_undo_reference(n)
	undo_redo.commit_action()

	return success({"dry_run": false, "matched": matched.size(), "deleted": matched.size(), "nodes": report})


# --- cleanup.unreal_env ------------------------------------------------------

func _find_world_env(root: Node) -> WorldEnvironment:
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is WorldEnvironment:
			return n as WorldEnvironment
		for c in n.get_children():
			queue.append(c)
	return null


## Fix the exported WorldEnvironment's Environment. The exporter stamps one bright default on
## every scene (Filmic tonemap, blown background_intensity, all GI/SSR/SSAO on, an auto-exposure
## CameraAttributes). Set a sane tonemap (default AgX, to match UE5), tune intensity, toggle the
## heavy effects, and optionally drop the auto-exposure that compounds the wash-out.
func _unreal_env(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var we: WorldEnvironment
	if params.has("node_path"):
		var n := find_node_by_path(str(params["node_path"]))
		if n == null:
			return error_not_found("Node at '%s'" % params["node_path"])
		if not n is WorldEnvironment:
			return error_invalid_params("Node '%s' is not a WorldEnvironment" % params["node_path"])
		we = n as WorldEnvironment
	else:
		we = _find_world_env(root)
		if we == null:
			return error(-32001, "No WorldEnvironment in the open scene", {"suggestion": "Open UnrealGodotWorldEnvironment.tscn, or pass --node-path"})
	var env := we.environment
	if env == null:
		return error(-32000, "WorldEnvironment '%s' has no Environment resource" % we.name)

	var before := {
		"tonemap_mode": env.tonemap_mode,
		"background_intensity": env.background_intensity,
		"sdfgi_enabled": env.sdfgi_enabled,
		"ssr_enabled": env.ssr_enabled,
		"ssao_enabled": env.ssao_enabled,
		"glow_enabled": env.glow_enabled,
		"camera_attributes": we.camera_attributes != null,
	}
	# Collect every change first, then apply as undoable actions (consistent with the
	# other cleanup.* commands; the Environment is a sub-resource, camera_attributes is on the WE).
	var do_env := {}

	# tonemap (default agx unless explicitly skipped)
	var tm := optional_string(params, "tonemap", "agx").to_lower()
	if tm != "" and tm != "keep":
		if not TONEMAP.has(tm):
			return error_invalid_params("tonemap must be one of %s" % str(TONEMAP.keys()))
		do_env["tonemap_mode"] = TONEMAP[tm]
	if params.has("exposure"):
		do_env["tonemap_exposure"] = float(params["exposure"])
	if params.has("white"):
		do_env["tonemap_white"] = float(params["white"])
	if params.has("background_intensity"):
		do_env["background_intensity"] = float(params["background_intensity"])
	if params.has("ambient_energy"):
		do_env["ambient_light_energy"] = float(params["ambient_energy"])

	for tog: String in ["sdfgi", "ssr", "ssao", "ssil", "glow"]:
		if params.has(tog):
			do_env[tog + "_enabled"] = optional_bool(params, tog, false)

	# drop the auto-exposure CameraAttributes that compounds the wash-out
	var cleared_ae := optional_bool(params, "clear_auto_exposure", false) and we.camera_attributes != null

	if do_env.is_empty() and not cleared_ae:
		return error_invalid_params("Nothing to change — pass --tonemap / --background_intensity / --sdfgi / --clear_auto_exposure / …")

	var applied := {}
	if not do_env.is_empty():
		set_properties_with_undo(env, do_env, "MCP: cleanup.unreal_env")
		applied = do_env.duplicate()
	if cleared_ae:
		set_property_with_undo(we, "camera_attributes", null, "MCP: cleanup.unreal_env clear auto-exposure")
		applied["camera_attributes"] = null

	return success({
		"node_path": str(root.get_path_to(we)),
		"before": before,
		"applied": applied,
		"note": "Run scene.save to persist (the Environment is a sub-resource of this scene).",
	})


# --- cleanup.unreal_lights ---------------------------------------------------

# NOTE: light_intensity_lumens and light_intensity_lux are two inspector aliases for ONE stored
# intensity param (the inspector shows "lux" for directionals, "lumens" for omni/spot). So the UE
# exporter writing a giant "lumens" onto a directional is live — Godot reads it as lux and blows the
# scene out under use_physical_light_units. The magnitudes are garbage (no clean unit recovery), so
# we normalize the intensity store to Godot's daylight/point defaults and lean on light_energy
# (which the export already leaves at a sane 1.0) once physical units are off.
const DIR_INTENSITY_DEFAULT := 100000.0   # DirectionalLight3D — ~midday-sun lux at energy 1.0
const PT_INTENSITY_DEFAULT := 1000.0      # Omni/Spot — lumens at energy 1.0


func _collect_lights(root: Node) -> Array:
	var out: Array = []
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is Light3D:
			out.append(n)
		for c in n.get_children():
			queue.append(c)
	return out


## Fix lighting a UE export gets wrong. The exporter leaves the project in physical-light-units mode
## and dumps garbage-magnitude UE intensities onto the lights (e.g. 1.875e8 "lumens" on a
## DirectionalLight3D — read as lux, it blows the scene out). This (default) turns off
## use_physical_light_units so lights use standard light_energy, and normalizes the garbage intensity
## store back to Godot's daylight/point default so the scene is sane in either unit mode. The export's
## own light_energy (typically a sane 1.0) is kept unless you pass --energy or --scale. --dry-run.
func _unreal_lights(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var scale := float(params.get("scale", 1.0))
	var energy_override: Variant = params.get("energy", null)  # null = keep the export's energy
	var normalize := optional_bool(params, "normalize_intensity", true)
	var disable_phys := optional_bool(params, "disable_physical_units", true)
	var dry_run := optional_bool(params, "dry_run", false)

	var lights := _collect_lights(root)
	var plan: Array = []
	for li: Light3D in lights:
		var is_dir := li is DirectionalLight3D
		var target := DIR_INTENSITY_DEFAULT if is_dir else PT_INTENSITY_DEFAULT
		var base_energy := float(energy_override) if energy_override != null else li.light_energy
		var entry := {
			"path": str(root.get_path_to(li)),
			"type": li.get_class(),
			"energy_before": li.light_energy,
			"energy_after": base_energy * scale,
			"intensity_before": li.light_intensity_lumens,  # alias of lux — same store
		}
		if normalize and not is_equal_approx(li.light_intensity_lumens, target):
			entry["intensity_after"] = target
		plan.append(entry)

	var phys_before := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))

	if dry_run:
		return success({
			"dry_run": true, "lights": plan.size(), "plan": plan,
			"physical_light_units": {"before": phys_before, "after": (false if disable_phys and phys_before else phys_before)},
		})

	if not lights.is_empty():
		var undo_redo := get_undo_redo()
		undo_redo.create_action("MCP: Fix %d Unreal lights" % lights.size())
		for i in range(lights.size()):
			var li: Light3D = lights[i]
			var entry: Dictionary = plan[i]
			undo_redo.add_do_property(li, "light_energy", entry["energy_after"])
			undo_redo.add_undo_property(li, "light_energy", li.light_energy)
			if entry.has("intensity_after"):
				undo_redo.add_do_property(li, "light_intensity_lumens", entry["intensity_after"])
				undo_redo.add_undo_property(li, "light_intensity_lumens", li.light_intensity_lumens)
		undo_redo.commit_action()

	var phys_after := phys_before
	if disable_phys and phys_before:
		ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", false)
		ProjectSettings.save()
		phys_after = false

	return success({
		"dry_run": false, "lights": plan.size(), "plan": plan,
		"physical_light_units": {"before": phys_before, "after": phys_after},
		"note": "Run scene.save to persist node changes." if not lights.is_empty() else "No lights in scene; only the project setting was touched.",
	})


# --- cleanup.fix_imports -----------------------------------------------------

func _walk_imports(root: String, out: Array) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var full := root.path_join(name)
		if dir.current_is_dir():
			if name != ".godot":  # skip the import cache / project-internal dir
				_walk_imports(full, out)
		elif name.ends_with(".import"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _read_source_file(import_path: String) -> String:
	var f := FileAccess.open(import_path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("source_file="):
			return line.substr("source_file=".length()).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""


func _rewrite_source_file(import_path: String, new_source: String) -> bool:
	var f := FileAccess.open(import_path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n")
	var changed := false
	for i in range(lines.size()):
		if lines[i].begins_with("source_file="):
			lines[i] = "source_file=\"%s\"" % new_source
			changed = true
			break
	if not changed:
		return false
	var w := FileAccess.open(import_path, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string("\n".join(lines))
	w.close()
	return true


## Fix the import metadata a UE export ships with the wrong source path. The exporter writes
## source_file="res://RailBridge/..." assuming the export sits at the project root, but if it was
## dropped into a subfolder (res://scenes/UnrealGodot…) every .import's source_file points at a path
## that no longer exists — rendering still works (textures resolve by uid) but reimport-from-source
## is broken. This scans *.import under --path, flags each whose source_file != its actual sibling
## asset, and (unless --dry-run) rewrites it to the real path. --reimport re-imports the corrected
## assets. Safe by design: only rewrites when the actual sibling file truly exists.
func _fix_imports(params: Dictionary) -> Dictionary:
	var scan_root := optional_string(params, "path", "res://")
	if not scan_root.begins_with("res://"):
		return error_invalid_params("--path must be under res://")
	var dry_run := optional_bool(params, "dry_run", false)
	var do_reimport := optional_bool(params, "reimport", false)

	var imports: Array = []
	_walk_imports(scan_root, imports)

	var mismatched: Array = []
	for ip: String in imports:
		var actual_source := ip.trim_suffix(".import")
		var declared := _read_source_file(ip)
		if declared == "" or declared == actual_source:
			continue
		mismatched.append({
			"import": ip,
			"declared": declared,
			"actual": actual_source,
			"declared_exists": FileAccess.file_exists(declared),
			"actual_exists": FileAccess.file_exists(actual_source),
		})

	if dry_run:
		return success({
			"dry_run": true, "scanned": imports.size(), "mismatched": mismatched.size(),
			"rewritten": 0, "details": mismatched,
		})

	var rewritten := 0
	var reimport_targets: PackedStringArray = []
	for m: Dictionary in mismatched:
		if not m["actual_exists"]:  # only the safe case — the real asset is present
			continue
		if not guard_project_path(m["import"]).is_empty():
			continue
		if _rewrite_source_file(m["import"], m["actual"]):
			rewritten += 1
			reimport_targets.append(m["actual"])

	var reimported := 0
	if do_reimport and not reimport_targets.is_empty():
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.reimport_files(reimport_targets)
			reimported = reimport_targets.size()

	return success({
		"dry_run": false, "scanned": imports.size(), "mismatched": mismatched.size(),
		"rewritten": rewritten, "reimported": reimported, "details": mismatched,
	})


func get_command_docs() -> Dictionary:
	return {
		"cleanup.strip_junk": {
			"description": "Delete editor-only / non-game nodes a UE-to-Godot export drags in (CineCam, EnviroDome, WaterInfo, /engine/editor assets). --dry-run lists matches without deleting. Undoable.",
			"params": [
				doc_param("patterns", "Array", false, "Name/source substrings that mark junk (default the built-in UE set)."),
				doc_param("keep", "Array", false, "Substrings to protect from deletion."),
				doc_param("include_decals", "bool", false, "Also remove Decal nodes (default false)."),
				doc_param("dry_run", "bool", false, "List matches without deleting (default false)."),
			],
		},
		"cleanup.unreal_env": {
			"description": "Fix an exported WorldEnvironment's Environment (tonemap, blown background_intensity, heavy GI/SSR/SSAO, auto-exposure). Pass at least one change. Run scene.save to persist. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", false, "Target WorldEnvironment; omit to auto-find one in the scene."),
				doc_param("tonemap", "String", false, "linear, reinhard, filmic, aces, or agx (default agx); 'keep' leaves it."),
				doc_param("exposure", "float", false, "tonemap_exposure."),
				doc_param("white", "float", false, "tonemap_white."),
				doc_param("background_intensity", "float", false, "Background intensity."),
				doc_param("ambient_energy", "float", false, "ambient_light_energy."),
				doc_param("sdfgi", "bool", false, "Toggle SDFGI."),
				doc_param("ssr", "bool", false, "Toggle screen-space reflections."),
				doc_param("ssao", "bool", false, "Toggle SSAO."),
				doc_param("ssil", "bool", false, "Toggle SSIL."),
				doc_param("glow", "bool", false, "Toggle glow."),
				doc_param("clear_auto_exposure", "bool", false, "Drop the WorldEnvironment's auto-exposure CameraAttributes (default false)."),
			],
		},
		"cleanup.unreal_lights": {
			"description": "Fix UE-export lighting: turn off use_physical_light_units and normalize garbage intensity magnitudes to Godot's daylight/point defaults, keeping the export's light_energy unless overridden. --dry-run. Undoable.",
			"params": [
				doc_param("scale", "float", false, "Multiply each light's energy by this (default 1.0)."),
				doc_param("energy", "float", false, "Override light_energy on every light (default: keep the export's)."),
				doc_param("normalize_intensity", "bool", false, "Reset the intensity store to the Godot default (default true)."),
				doc_param("disable_physical_units", "bool", false, "Turn off the use_physical_light_units project setting (default true)."),
				doc_param("dry_run", "bool", false, "Report the plan without applying (default false)."),
			],
		},
		"cleanup.fix_imports": {
			"description": "Repair *.import source_file paths broken by dropping a UE export into a subfolder: rewrites each to its real sibling asset (only when that file exists). --dry-run previews; --reimport re-imports the fixed assets.",
			"params": [
				doc_param("path", "String", false, "Root under res:// to scan (default res://)."),
				doc_param("dry_run", "bool", false, "List mismatches without rewriting (default false)."),
				doc_param("reimport", "bool", false, "Reimport the corrected assets afterward (default false)."),
			],
		},
	}
