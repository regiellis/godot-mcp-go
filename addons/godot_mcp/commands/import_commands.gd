@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Asset import settings — the one asset lever the agent should own (meshes/textures are authored
## externally, but how Godot *imports* them is project config). No other command touches the
## `<asset>.import` ConfigFile. This reads it, edits its [params], and reimports.
##
## A `.import` is a ConfigFile: [remap] (importer/type/uid), [deps] (source/dest), [params]
## (the dotted import options, e.g. compress/mode, mipmaps/generate). Reimport via
## EditorFileSystem.reimport_files (verified live).


func get_commands() -> Dictionary:
	return {
		"import.info": _info,
		"import.set": _set_params,
		"import.reimport": _reimport,
	}


func _import_file(asset_path: String) -> String:
	return asset_path + ".import"


## JSON numbers arrive as float; keep whole numbers as int so the .import stays clean and
## importers that expect ints (compress/mode, *_remap) get ints.
func _coerce(v: Variant) -> Variant:
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return int(v)
	return v


# --- info -------------------------------------------------------------------

func _info(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var imp := _import_file(path)
	if not FileAccess.file_exists(imp):
		return error_not_found("Import file for '%s'" % path,
			"No <asset>.import exists — the asset isn't imported (e.g. .tscn/.gd aren't, or it's not in res://).")

	var cfg := ConfigFile.new()
	if cfg.load(imp) != OK:
		return error_internal("Failed to read '%s'" % imp)

	var params_out := {}
	if cfg.has_section("params"):
		for key in cfg.get_section_keys("params"):
			params_out[key] = cfg.get_value("params", key)

	return success({
		"path": path,
		"importer": cfg.get_value("remap", "importer", ""),
		"type": cfg.get_value("remap", "type", ""),
		"uid": cfg.get_value("remap", "uid", ""),
		"params": params_out,
	})


# --- set --------------------------------------------------------------------

func _set_params(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard
	var imp := _import_file(path)
	if not FileAccess.file_exists(imp):
		return error_not_found("Import file for '%s'" % path, "The asset isn't imported, so it has no import params to set.")

	var pr := require_dict(params, "params")
	if pr[1] != null:
		return pr[1]
	var to_set: Dictionary = pr[0]
	if to_set.is_empty():
		return error_invalid_params("'params' is empty — nothing to set")

	var cfg := ConfigFile.new()
	if cfg.load(imp) != OK:
		return error_internal("Failed to read '%s'" % imp)

	var applied := {}
	for key: String in to_set:
		var val: Variant = _coerce(to_set[key])
		cfg.set_value("params", key, val)
		applied[key] = val
	if cfg.save(imp) != OK:
		return error_internal("Failed to write '%s'" % imp)

	# Reimport unless explicitly deferred.
	var reimported := false
	if optional_bool(params, "reimport", true):
		var efs := EditorInterface.get_resource_filesystem()
		efs.update_file(path)
		efs.reimport_files(PackedStringArray([path]))
		reimported = true

	return success({"path": path, "applied": applied, "reimported": reimported})


# --- reimport ---------------------------------------------------------------

func _reimport(params: Dictionary) -> Dictionary:
	var paths: Array = []
	if params.has("paths"):
		var v: Variant = params["paths"]
		if v is String:
			var parsed: Variant = JSON.parse_string(v)
			if parsed is Array:
				paths = parsed
		elif v is Array:
			paths = v
	elif params.has("path"):
		paths = [str(params["path"])]
	else:
		return error_invalid_params("Provide 'path' or 'paths' (a JSON array)")

	var valid: Array = []
	var missing: Array = []
	for p: Variant in paths:
		if FileAccess.file_exists(_import_file(str(p))):
			valid.append(str(p))
		else:
			missing.append(str(p))
	if valid.is_empty():
		return error_not_found("Any importable asset", "None of the given paths have a .import file")

	var efs := EditorInterface.get_resource_filesystem()
	efs.reimport_files(PackedStringArray(valid))
	return success({"reimported": valid, "skipped_no_import": missing})


func get_command_docs() -> Dictionary:
	return {
		"import.info": {
			"description": "Read an asset's <asset>.import ConfigFile: its importer, resource type, uid, and current [params] import options. Errors if the asset isn't imported (e.g. .tscn/.gd have no .import).",
			"params": [
				doc_param("path", "String", true, "Asset path (the source, e.g. res://tex.png, not the .import sidecar)."),
			],
		},
		"import.set": {
			"description": "Set one or more import options in an asset's .import [params], then (unless --reimport=false) reimport. Whole JSON numbers are stored as int so importers get clean values.",
			"params": [
				doc_param("path", "String", true, "Asset path whose import options to change."),
				doc_param("params", "Dictionary", true, "{import_option: value} to set (e.g. {\"compress/mode\": 0, \"mipmaps/generate\": true})."),
				doc_param("reimport", "bool", false, "Reimport after writing (default true); false defers the reimport."),
			],
		},
		"import.reimport": {
			"description": "Reimport one or more already-imported assets. Provide --path (one) OR --paths (a JSON array); paths without a .import are skipped.",
			"params": [
				doc_param("path", "String", false, "Single asset path to reimport. Provide path OR paths."),
				doc_param("paths", "Array", false, "JSON array of asset paths to reimport. Provide path OR paths."),
			],
		},
	}
