@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## C# project support: info, setup, build.


func get_commands() -> Dictionary:
	return {
		"csharp.info": _info,
		"csharp.setup": _setup,
		"csharp.build": _build,
	}


## Report the project's C# toolchain state: the dotnet CLI, whether this is a
## .NET (mono) editor, any existing csproj/sln at the project root, and the
## configured assembly name. Read-only; runs no build.
func _info(_params: Dictionary) -> Dictionary:
	var dotnet_found := false
	var dotnet_version: Variant = null
	var out: Array = []
	if OS.execute("dotnet", ["--version"], out, true) == 0 and out.size() > 0:
		dotnet_found = true
		dotnet_version = String(out[0]).strip_edges()

	var vi := Engine.get_version_info()
	var engine_version := "%d.%d.%d" % [int(vi.get("major", 0)), int(vi.get("minor", 0)), int(vi.get("patch", 0))]
	var status := String(vi.get("status", ""))
	if not status.is_empty():
		engine_version += "." + status

	var assembly_name: Variant = null
	if ProjectSettings.has_setting("dotnet/project/assembly_name"):
		var an := String(ProjectSettings.get_setting("dotnet/project/assembly_name"))
		if not an.is_empty():
			assembly_name = an

	return success({
		"dotnet_found": dotnet_found,
		"dotnet_version": dotnet_version,
		"dotnet_editor": ClassDB.class_exists("CSharpScript"),
		"engine_version": engine_version,
		"csproj": find_file_at_root("csproj"),
		"sln": find_file_at_root("sln"),
		"assembly_name": assembly_name,
	})


## Scaffold a `<Name>.csproj` + `<Name>.sln` at the project root (Godot.NET.Sdk,
## net8.0), set dotnet/project/assembly_name, and rescan. <Name> is the sanitized
## project name. Refuses to overwrite existing files without --force (-32009).
func _setup(params: Dictionary) -> Dictionary:
	var raw_name := ""
	if ProjectSettings.has_setting("application/config/name"):
		raw_name = String(ProjectSettings.get_setting("application/config/name"))
	var project_name := _sanitize_name(raw_name)

	var vi := Engine.get_version_info()
	var default_sdk := "%d.%d.%d" % [int(vi.get("major", 0)), int(vi.get("minor", 0)), int(vi.get("patch", 0))]
	# Non-stable engines publish their SDK with the status suffix (e.g. 4.7.2-rc,
	# matching the nupkgs a source build generates); stable releases drop it.
	var vstatus := String(vi.get("status", ""))
	if not vstatus.is_empty() and vstatus != "stable":
		default_sdk += "-" + vstatus
	var sdk_version := optional_string(params, "sdk_version", default_sdk)
	if sdk_version.is_empty():
		sdk_version = default_sdk

	var force := optional_bool(params, "force", false)
	var csproj_path := "res://%s.csproj" % project_name
	var sln_path := "res://%s.sln" % project_name

	# Invariant #4: guard every caller-derived write path before touching disk.
	for p in [csproj_path, sln_path]:
		var g := guard_project_path(p)
		if not g.is_empty():
			return g

	if not force:
		var existing: Array = []
		if FileAccess.file_exists(csproj_path):
			existing.append(csproj_path)
		if FileAccess.file_exists(sln_path):
			existing.append(sln_path)
		if not existing.is_empty():
			return error_conflict(
				"C# project files already exist: %s" % ", ".join(existing),
				{"existing": existing, "suggestion": "Pass --force to overwrite them."}
			)

	var created: Array = []
	var wr: Variant = _write_file(csproj_path, _csproj_content(project_name, sdk_version))
	if wr != null:
		return wr
	created.append(csproj_path)
	wr = _write_file(sln_path, _sln_content(project_name))
	if wr != null:
		return wr
	created.append(sln_path)

	# Match what the Godot editor records when it creates a C# solution.
	ProjectSettings.set_setting("dotnet/project/assembly_name", project_name)
	ProjectSettings.save()

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.scan()

	return success({
		"csproj": csproj_path,
		"sln": sln_path,
		"assembly_name": project_name,
		"sdk_version": sdk_version,
		"created": created,
	})


## Build the C# project with `dotnet build` WITHOUT blocking the editor main
## thread (shell-spawn + poll). A FAILED build is still a JSON-RPC success with
## success:false so the agent gets the diagnostics; only a missing csproj/dotnet,
## a spawn failure, or a timeout return a transport error.
func _build(params: Dictionary) -> Dictionary:
	var csproj := find_file_at_root("csproj")
	if csproj == null:
		return error_invalid_params("No .csproj found at the project root — run csharp.setup first")

	var out: Array = []
	if OS.execute("dotnet", ["--version"], out, true) != 0:
		return error_invalid_params("The .NET SDK ('dotnet') was not found on PATH. Install it from https://dotnet.microsoft.com/download and reopen the editor.")

	var timeout := float(params.get("timeout", 240.0))
	if timeout <= 0.0:
		timeout = 240.0

	var csproj_abs := ProjectSettings.globalize_path(String(csproj))
	var res: Dictionary = await run_build(csproj_abs, timeout)

	var status := String(res.get("status", ""))
	if status == "spawn_failed":
		return error_internal("Failed to spawn the dotnet build process (OS.create_process returned an invalid pid)")
	if status == "timeout":
		return error_internal("dotnet build timed out after %.0fs; see the log at %s" % [timeout, String(res.get("log_path", ""))])

	return success({
		"success": res.get("success", false),
		"errors": res.get("errors", []),
		"warnings": res.get("warnings", []),
		"error_count": res.get("error_count", 0),
		"warning_count": res.get("warning_count", 0),
		"duration_ms": res.get("duration_ms", 0),
		"log_tail": res.get("log_tail", ""),
	})


# --- Shared build execution (STATIC so script.validate can reuse it) ---------

## Run `dotnet build <csproj_abs>` in a shell WITHOUT blocking the editor main
## thread, polling the process to completion (up to timeout_sec). Static so
## script.validate shares one implementation; statics await via the main-loop
## timer (Engine.get_main_loop()) instead of instance/Node state. Returns a raw
## result the caller wraps: {status: "ok"|"timeout"|"spawn_failed", success,
## errors, warnings, error_count, warning_count, duration_ms, log_tail, log_path}.
static func run_build(csproj_abs: String, timeout_sec: float) -> Dictionary:
	var log_path := ProjectSettings.globalize_path("user://mcp_dotnet_build.log")
	# Drop any stale log so we never parse a previous run's output.
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)

	var csproj_shell := csproj_abs
	var log_shell := log_path
	var shell := "sh"
	var shell_args: PackedStringArray = []
	if OS.get_name() == "Windows":
		csproj_shell = csproj_abs.replace("/", "\\")
		log_shell = log_path.replace("/", "\\")
		shell = "cmd.exe"
		shell_args = ["/c", "dotnet build \"%s\" -nologo -v m > \"%s\" 2>&1" % [csproj_shell, log_shell]]
	else:
		shell_args = ["-c", "dotnet build \"%s\" -nologo -v m > \"%s\" 2>&1" % [csproj_shell, log_shell]]

	var start_ms := Time.get_ticks_msec()
	var pid := OS.create_process(shell, shell_args)
	if pid <= 0:
		return {"status": "spawn_failed", "log_path": log_path}

	var loop := Engine.get_main_loop() as SceneTree
	var deadline := start_ms + int(timeout_sec * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() >= deadline:
			OS.kill(pid)  # best-effort; the shell child may outlive it
			return {
				"status": "timeout",
				"log_path": log_path,
				"duration_ms": Time.get_ticks_msec() - start_ms,
			}
		await loop.create_timer(0.25).timeout

	var result := parse_build_log(log_path)
	result["status"] = "ok"
	result["duration_ms"] = Time.get_ticks_msec() - start_ms
	result["log_path"] = log_path
	return result


## Parse an MSBuild log into deduped diagnostics plus a success verdict. Static
## so csharp.build and script.validate share one parser. Returns {success,
## errors, warnings, error_count, warning_count, log_tail}.
static func parse_build_log(log_path: String) -> Dictionary:
	var text := ""
	if FileAccess.file_exists(log_path):
		var f := FileAccess.open(log_path, FileAccess.READ)
		if f != null:
			text = f.get_as_text()
			f.close()

	var diag_re := RegEx.new()
	diag_re.compile("^(.*)\\((\\d+),(\\d+)\\): (error|warning) ([A-Z0-9]+): (.*)$")
	# Project-level diagnostics (SDK resolution, MSBuild errors) carry no
	# (line,col): "<file> : error [CODE]: <message>".
	var proj_re := RegEx.new()
	proj_re.compile("^(.*?) : (error|warning)(?: ([A-Z0-9]+))?\\s?: (.*)$")

	var errors: Array = []
	var warnings: Array = []
	var seen: Dictionary = {}
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		var diag_file := ""
		var line_no := 0
		var col := 0
		var severity := ""
		var code := ""
		var message := ""
		var m := diag_re.search(line)
		if m != null:
			diag_file = m.get_string(1).strip_edges()
			line_no = int(m.get_string(2))
			col = int(m.get_string(3))
			severity = m.get_string(4)
			code = m.get_string(5)
			message = m.get_string(6)
		else:
			m = proj_re.search(line)
			if m == null:
				continue
			diag_file = m.get_string(1).strip_edges()
			severity = m.get_string(2)
			code = m.get_string(3)
			message = m.get_string(4)
		# MSBuild appends " [<csproj path>]" to summary diagnostics; strip it.
		var bracket := message.rfind(" [")
		if bracket != -1 and message.ends_with("]"):
			message = message.substr(0, bracket)
		# Dedupe: MSBuild repeats each diagnostic in its trailing summary.
		var key := "%s|%d|%d|%s|%s|%s" % [diag_file, line_no, col, severity, code, message]
		if seen.has(key):
			continue
		seen[key] = true
		var entry := {
			"file": diag_file,
			"line": line_no,
			"col": col,
			"severity": severity,
			"code": code,
			"message": message,
		}
		if severity == "error":
			errors.append(entry)
		else:
			warnings.append(entry)

	var succeeded := text.contains("Build succeeded")
	if not succeeded and errors.is_empty() and not text.contains("Build FAILED"):
		succeeded = true

	return {
		"success": succeeded,
		"errors": errors,
		"warnings": warnings,
		"error_count": errors.size(),
		"warning_count": warnings.size(),
		"log_tail": _log_tail(text, 30),
	}


## Find the first file with extension `ext` directly at the res:// root (not
## recursive), returned as a res:// path, or null. Static so callers in other
## groups (script.validate) can reuse it.
static func find_file_at_root(ext: String) -> Variant:
	var dir := DirAccess.open("res://")
	if dir == null:
		return null
	var target_ext := ext.to_lower()
	var found: Variant = null
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == target_ext:
			found = "res://" + file_name
			break
		file_name = dir.get_next()
	dir.list_dir_end()
	return found


# --- Content builders -------------------------------------------------------

## Sanitize a project name to a valid C#/MSBuild identifier: non-[A-Za-z0-9_]
## become "_", a leading digit gets an "_" prefix, empty falls back.
func _sanitize_name(raw: String) -> String:
	if raw.strip_edges().is_empty():
		return "GodotProject"
	var re := RegEx.new()
	re.compile("[^A-Za-z0-9_]")
	var sanitized := re.sub(raw, "_", true)
	if sanitized.is_empty():
		return "GodotProject"
	var first := sanitized.substr(0, 1)
	if first >= "0" and first <= "9":
		sanitized = "_" + sanitized
	return sanitized


func _csproj_content(project_name: String, sdk_version: String) -> String:
	var lines: PackedStringArray = [
		"<Project Sdk=\"Godot.NET.Sdk/%s\">" % sdk_version,
		"  <PropertyGroup>",
		"    <TargetFramework>net8.0</TargetFramework>",
		"    <EnableDynamicLoading>true</EnableDynamicLoading>",
		"    <RootNamespace>%s</RootNamespace>" % project_name,
		"  </PropertyGroup>",
		"</Project>",
		"",
	]
	return "\n".join(lines)


func _sln_content(project_name: String) -> String:
	var guid := _random_guid()
	# The C# project-type GUID recognized by MSBuild/Visual Studio.
	var project_type := "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"
	var lines: PackedStringArray = [
		"Microsoft Visual Studio Solution File, Format Version 12.00",
		"# Visual Studio 2012",
		"Project(\"{%s}\") = \"%s\", \"%s.csproj\", \"{%s}\"" % [project_type, project_name, project_name, guid],
		"EndProject",
		"Global",
		"\tGlobalSection(SolutionConfigurationPlatforms) = preSolution",
		"\t\tDebug|Any CPU = Debug|Any CPU",
		"\t\tExportDebug|Any CPU = ExportDebug|Any CPU",
		"\t\tExportRelease|Any CPU = ExportRelease|Any CPU",
		"\tEndGlobalSection",
		"\tGlobalSection(ProjectConfigurationPlatforms) = postSolution",
		"\t\t{%s}.Debug|Any CPU.ActiveCfg = Debug|Any CPU" % guid,
		"\t\t{%s}.Debug|Any CPU.Build.0 = Debug|Any CPU" % guid,
		"\t\t{%s}.ExportDebug|Any CPU.ActiveCfg = ExportDebug|Any CPU" % guid,
		"\t\t{%s}.ExportDebug|Any CPU.Build.0 = ExportDebug|Any CPU" % guid,
		"\t\t{%s}.ExportRelease|Any CPU.ActiveCfg = ExportRelease|Any CPU" % guid,
		"\t\t{%s}.ExportRelease|Any CPU.Build.0 = ExportRelease|Any CPU" % guid,
		"\tEndGlobalSection",
		"EndGlobal",
		"",
	]
	return "\n".join(lines)


## A random RFC-4122-shaped GUID (8-4-4-4-12 hex) built from randi() chunks. Any
## valid GUID text suffices for the sln; uniqueness across runs is not required.
func _random_guid() -> String:
	var chunks: PackedStringArray = []
	for i in range(4):
		chunks.append("%08x" % randi())
	var hex := "".join(chunks)
	var guid := "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
	return guid.to_upper()


func _write_file(path: String, content: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return error_internal("Cannot write '%s': %s" % [path, error_string(FileAccess.get_open_error())])
	file.store_string(content)
	file.close()
	return null


## Last `max_lines` non-trailing-blank lines of `text`, joined with newlines.
static func _log_tail(text: String, max_lines: int) -> String:
	var arr: Array = []
	for l in text.split("\n"):
		arr.append(String(l))
	while arr.size() > 0 and String(arr[arr.size() - 1]).strip_edges().is_empty():
		arr.remove_at(arr.size() - 1)
	var start := maxi(0, arr.size() - max_lines)
	var tail: Array = []
	for i in range(start, arr.size()):
		tail.append(arr[i])
	return "\n".join(tail)


func get_command_docs() -> Dictionary:
	return {
		"csharp.info": {
			"description": "Report the C# toolchain state: the dotnet CLI (presence/version), whether this is a .NET editor build, any csproj/sln at the root, and the configured assembly name. Read-only.",
		},
		"csharp.setup": {
			"description": "Scaffold <Name>.csproj + <Name>.sln (Godot.NET.Sdk, net8.0) from the sanitized project name, set dotnet/project/assembly_name, and rescan. Refuses to overwrite existing files without --force.",
			"params": [
				doc_param("sdk_version", "String", false, "Godot.NET.Sdk version (default the engine's major.minor.patch[-status]; override when a build's self-reported version has no published/local nupkg)."),
				doc_param("force", "bool", false, "Overwrite existing csproj/sln."),
			],
		},
		"csharp.build": {
			"description": "Run `dotnet build` without blocking the editor main thread, returning deduped structured diagnostics. A failed build is a success payload with success:false; only a missing csproj/dotnet, spawn failure, or timeout is a transport error.",
			"params": [
				doc_param("timeout", "float", false, "Build timeout in seconds (default 240)."),
			],
		},
	}
