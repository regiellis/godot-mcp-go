@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Export preset inspection and CLI-export brokering. Direct export from an
## editor plugin is unsupported in Godot 4, so export_project returns a ready
## command line to run rather than performing the export itself.


func get_commands() -> Dictionary:
	return {
		"export.list_presets": _list_presets,
		"export.project": _project,
		"export.info": _info,
	}


const _PRESETS_PATH := "res://export_presets.cfg"


func _list_presets(_params: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(_PRESETS_PATH):
		return success({"presets": [], "count": 0, "message": "No export_presets.cfg found"})

	var cfg := ConfigFile.new()
	var err := cfg.load(_PRESETS_PATH)
	if err != OK:
		return error_internal("Failed to read export_presets.cfg: %s" % error_string(err))

	var presets: Array = []
	var idx := 0
	while cfg.has_section("preset.%d" % idx):
		var section := "preset.%d" % idx
		presets.append({
			"index": idx,
			"name": cfg.get_value(section, "name", ""),
			"platform": cfg.get_value(section, "platform", ""),
			"runnable": cfg.get_value(section, "runnable", false),
			"export_path": cfg.get_value(section, "export_path", ""),
		})
		idx += 1

	return success({"presets": presets, "count": presets.size()})


func _project(params: Dictionary) -> Dictionary:
	var preset_index := optional_int(params, "preset_index", -1)
	var preset_name := optional_string(params, "preset_name", "")
	var debug := optional_bool(params, "debug", true)

	if not FileAccess.file_exists(_PRESETS_PATH):
		return error(-32000, "No export_presets.cfg found. Configure exports in Project > Export first.")

	var cfg := ConfigFile.new()
	if cfg.load(_PRESETS_PATH) != OK:
		return error_internal("Failed to read export_presets.cfg")

	var target_name := ""
	var target_path := ""
	var found := false

	if not preset_name.is_empty():
		var idx := 0
		while cfg.has_section("preset.%d" % idx):
			var section := "preset.%d" % idx
			if cfg.get_value(section, "name", "") == preset_name:
				target_name = preset_name
				target_path = cfg.get_value(section, "export_path", "")
				found = true
				break
			idx += 1
	elif preset_index >= 0:
		var section := "preset.%d" % preset_index
		if cfg.has_section(section):
			target_name = cfg.get_value(section, "name", "")
			target_path = cfg.get_value(section, "export_path", "")
			found = true

	if not found:
		return error_not_found("Export preset")

	if target_path.is_empty():
		return error(-32000, "Export path not configured for preset '%s'" % target_name)

	var godot_path := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	var export_path := ProjectSettings.globalize_path(target_path) if target_path.begins_with("res://") else target_path

	var flag := "--export-debug" if debug else "--export-release"
	var command := '"%s" --headless --path "%s" %s "%s"' % [godot_path, project_path, flag, target_name]

	return success({
		"preset": target_name,
		"export_path": export_path,
		"debug": debug,
		"command": command,
		"message": "Run the command above to export. Direct export from editor plugin is not supported in Godot 4.",
	})


func _info(_params: Dictionary) -> Dictionary:
	var templates_path := OS.get_data_dir().path_join("export_templates")
	return success({
		"has_export_presets": FileAccess.file_exists(_PRESETS_PATH),
		"godot_executable": OS.get_executable_path(),
		"project_path": ProjectSettings.globalize_path("res://"),
		"templates_dir": templates_path,
		"templates_installed": DirAccess.dir_exists_absolute(templates_path),
	})


func get_command_docs() -> Dictionary:
	return {
		"export.list_presets": {
			"description": "List every preset in export_presets.cfg (name, platform, runnable, export_path). Empty if the project has no export config.",
			"params": [],
		},
		"export.project": {
			"description": "Return a ready-to-run headless CLI command line that exports the chosen preset (editor-plugin export is unsupported in Godot 4, so this does NOT export itself). Identify the preset by --preset-name OR --preset-index.",
			"params": [
				doc_param("preset_name", "String", false, "Preset to export, by name. Provide preset_name OR preset_index."),
				doc_param("preset_index", "int", false, "Preset to export, by 0-based index. Provide preset_name OR preset_index."),
				doc_param("debug", "bool", false, "Emit --export-debug (default true) vs --export-release."),
			],
		},
		"export.info": {
			"description": "Report export readiness: whether export_presets.cfg exists, the Godot executable and project paths, and whether export templates are installed.",
			"params": [],
		},
	}
