@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Android device tooling: list adb devices, read Android export presets, and
## export + install + launch an APK. Shells out to adb and the Godot CLI;
## degrades gracefully when tools or presets are missing.


func get_commands() -> Dictionary:
	return {
		"android.list_devices": _list_devices,
		"android.preset_info": _preset_info,
		"android.deploy": _deploy,
	}


const _PRESETS_PATH := "res://export_presets.cfg"


## Resolve adb path from editor settings, falling back to PATH lookup.
func _resolve_adb_path() -> String:
	var editor_settings := EditorInterface.get_editor_settings()
	if editor_settings.has_setting("export/android/adb"):
		var configured := str(editor_settings.get_setting("export/android/adb"))
		if not configured.is_empty() and FileAccess.file_exists(configured):
			return configured
	return "adb"


func _run(cmd: String, args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute(cmd, args, output, true)
	var stdout := str(output[0]) if not output.is_empty() else ""
	return {"exit_code": exit_code, "stdout": stdout}


func _list_devices(_params: Dictionary) -> Dictionary:
	var adb := _resolve_adb_path()
	var result := _run(adb, PackedStringArray(["devices", "-l"]))
	if result["exit_code"] != 0:
		return error(-32000,
			"adb failed (exit %d). Install Android platform-tools or set Editor Settings > Export > Android > Adb." % result["exit_code"],
			{"adb_path": adb, "output": result["stdout"]})

	var devices: Array = []
	for raw_line in str(result["stdout"]).split("\n"):
		var line := (raw_line as String).strip_edges()
		if line.is_empty() or line.begins_with("List of devices") or line.begins_with("* daemon"):
			continue
		var parts := line.split(" ", false)
		if parts.size() < 2:
			continue
		var dev: Dictionary = {"serial": parts[0], "state": parts[1]}
		for i in range(2, parts.size()):
			var kv: String = parts[i]
			var eq := kv.find(":")
			if eq > 0:
				dev[kv.substr(0, eq)] = kv.substr(eq + 1)
		devices.append(dev)

	return success({"devices": devices, "count": devices.size(), "adb_path": adb})


## Locate an Android preset by name, index, or first-Android fallback.
func _find_android_preset(preset_name: String, preset_index: int) -> Dictionary:
	if not FileAccess.file_exists(_PRESETS_PATH):
		return {}
	var cfg := ConfigFile.new()
	if cfg.load(_PRESETS_PATH) != OK:
		return {}

	var idx := 0
	while cfg.has_section("preset.%d" % idx):
		var section := "preset.%d" % idx
		var platform := str(cfg.get_value(section, "platform", ""))
		var name := str(cfg.get_value(section, "name", ""))
		var matches := false
		if not preset_name.is_empty():
			matches = name == preset_name
		elif preset_index >= 0:
			matches = idx == preset_index
		else:
			matches = platform == "Android"
		if matches:
			var options_section := "preset.%d.options" % idx
			var package_name := ""
			if cfg.has_section(options_section):
				package_name = str(cfg.get_value(options_section, "package/unique_name", ""))
			return {
				"index": idx,
				"name": name,
				"platform": platform,
				"runnable": bool(cfg.get_value(section, "runnable", false)),
				"export_path": str(cfg.get_value(section, "export_path", "")),
				"package_name": package_name,
			}
		idx += 1
	return {}


func _preset_info(params: Dictionary) -> Dictionary:
	var preset_name := optional_string(params, "preset_name", "")
	var preset_index := optional_int(params, "preset_index", -1)
	var preset := _find_android_preset(preset_name, preset_index)
	if preset.is_empty():
		return error_not_found("Android export preset", "Configure an Android preset in Project > Export first.")
	if preset["platform"] != "Android":
		return error(-32000, "Preset '%s' is not an Android preset (platform=%s)" % [preset["name"], preset["platform"]])
	return success(preset)


## Export an APK, install it via adb, then optionally launch the main activity.
func _deploy(params: Dictionary) -> Dictionary:
	var preset_name := optional_string(params, "preset_name", "")
	var preset_index := optional_int(params, "preset_index", -1)
	var device_serial := optional_string(params, "device_serial", "")
	var debug := optional_bool(params, "debug", true)
	var launch := optional_bool(params, "launch", true)
	var skip_export := optional_bool(params, "skip_export", false)

	var preset := _find_android_preset(preset_name, preset_index)
	if preset.is_empty():
		return error_not_found("Android export preset", "Configure an Android preset in Project > Export first.")
	if preset["platform"] != "Android":
		return error(-32000, "Preset '%s' is not an Android preset" % preset["name"])

	var export_path_res: String = preset["export_path"]
	if export_path_res.is_empty():
		return error(-32000, "Export path not configured for preset '%s'" % preset["name"])
	var export_path_abs := ProjectSettings.globalize_path(export_path_res) if export_path_res.begins_with("res://") else export_path_res

	var steps: Array = []

	if not skip_export:
		var godot_bin := OS.get_executable_path()
		var project_dir := ProjectSettings.globalize_path("res://")
		var export_flag := "--export-debug" if debug else "--export-release"
		var export_args := PackedStringArray(["--headless", "--path", project_dir, export_flag, preset["name"], export_path_abs])
		var export_result := _run(godot_bin, export_args)
		steps.append({"step": "export", "command": godot_bin, "args": export_args, "exit_code": export_result["exit_code"]})
		if export_result["exit_code"] != 0:
			return error(-32000, "Godot export failed (exit %d). See stdout." % export_result["exit_code"],
				{"steps": steps, "stdout": export_result["stdout"]})

	if not FileAccess.file_exists(export_path_abs):
		return error(-32000, "APK not found at %s after export" % export_path_abs, {"steps": steps})

	var adb := _resolve_adb_path()
	var install_args := PackedStringArray()
	if not device_serial.is_empty():
		install_args.append("-s")
		install_args.append(device_serial)
	install_args.append("install")
	install_args.append("-r")
	install_args.append(export_path_abs)
	var install_result := _run(adb, install_args)
	steps.append({"step": "install", "command": adb, "args": install_args, "exit_code": install_result["exit_code"], "stdout": install_result["stdout"]})
	if install_result["exit_code"] != 0:
		return error(-32000, "adb install failed (exit %d)" % install_result["exit_code"], {"steps": steps})

	if launch:
		var package_name: String = preset["package_name"]
		if package_name.is_empty():
			steps.append({"step": "launch", "skipped": true, "reason": "package_name not found in preset"})
		else:
			var launch_args := PackedStringArray()
			if not device_serial.is_empty():
				launch_args.append("-s")
				launch_args.append(device_serial)
			launch_args.append("shell")
			launch_args.append("monkey")
			launch_args.append("-p")
			launch_args.append(package_name)
			launch_args.append("-c")
			launch_args.append("android.intent.category.LAUNCHER")
			launch_args.append("1")
			var launch_result := _run(adb, launch_args)
			steps.append({"step": "launch", "command": adb, "args": launch_args, "exit_code": launch_result["exit_code"], "stdout": launch_result["stdout"]})

	return success({
		"preset": preset["name"],
		"apk_path": export_path_abs,
		"device": device_serial if not device_serial.is_empty() else "(default)",
		"package_name": preset["package_name"],
		"steps": steps,
	})


func get_command_docs() -> Dictionary:
	return {
		"android.list_devices": {
			"description": "List Android devices via `adb devices -l` (serial, state, and extra fields). Errors clearly if adb is missing; install platform-tools or set the Adb path in Editor Settings.",
			"params": [],
		},
		"android.preset_info": {
			"description": "Report an Android export preset (index, name, runnable, export_path, package_name). Identify it by --preset-name or --preset-index, else the first Android preset is used.",
			"params": [
				doc_param("preset_name", "String", false, "Android preset by name. Omit both to use the first Android preset."),
				doc_param("preset_index", "int", false, "Android preset by 0-based index."),
			],
		},
		"android.deploy": {
			"description": "Export an APK (headless Godot CLI), install it with `adb install -r`, then optionally launch it. Needs platform-tools, an Android preset, and export templates.",
			"params": [
				doc_param("preset_name", "String", false, "Android preset by name (else the first Android preset)."),
				doc_param("preset_index", "int", false, "Android preset by 0-based index."),
				doc_param("device_serial", "String", false, "Target device serial (`adb -s`); default the only/first device."),
				doc_param("debug", "bool", false, "Export as debug (default true) vs release."),
				doc_param("launch", "bool", false, "Launch the app after install (default true)."),
				doc_param("skip_export", "bool", false, "Skip the export step and install the existing APK (default false)."),
			],
		},
	}
