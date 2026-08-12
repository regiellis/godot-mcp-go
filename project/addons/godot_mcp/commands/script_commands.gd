@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Script authoring (GDScript + C#): list, read, create, edit, attach, validate,
## symbols, lint. Every command here is self-contained — no external tool.

const CSharpCommands := preload("res://addons/godot_mcp/commands/csharp_commands.gd")
const GDScriptLinter := preload("res://addons/godot_mcp/utils/gdscript_linter.gd")


func get_commands() -> Dictionary:
	return {
		"script.list": _list,
		"script.read": _read,
		"script.create": _create,
		"script.edit": _edit,
		"script.attach": _attach,
		"script.validate": _validate,
		"script.list_open": _list_open,
		"script.symbols": _symbols,
		"script.lint": _lint,
	}


func _guard_script_ext(path: String, op: String) -> Dictionary:
	var ext := path.get_extension().to_lower()
	if ext in ["gd", "cs"]:
		return {}
	return error_invalid_params("%s only supports script files (.gd, .cs), got '.%s'" % [op, ext])


func _list(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var recursive := optional_bool(params, "recursive", true)
	var scripts: Array = []
	_find_scripts(path, recursive, scripts)
	return success({"scripts": scripts, "count": scripts.size()})


func _find_scripts(path: String, recursive: bool, scripts: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var full_path := path.path_join(file_name)
		if dir.current_is_dir():
			if recursive and file_name != "addons":
				_find_scripts(full_path, recursive, scripts)
		elif file_name.get_extension() in ["gd", "cs"]:
			var info := {"path": full_path, "type": file_name.get_extension()}
			var file := FileAccess.open(full_path, FileAccess.READ)
			if file:
				info["size"] = file.get_length()
				if file_name.get_extension() == "cs":
					_sniff_cs(file.get_as_text(), info)
				else:
					var first := file.get_line().strip_edges()
					if first.begins_with("class_name "):
						info["class_name"] = first.substr(11).strip_edges()
					elif first.begins_with("extends "):
						info["extends"] = first.substr(8).strip_edges()
				file.close()
			scripts.append(info)
		file_name = dir.get_next()
	dir.list_dir_end()


## Sniff a C# file's declared type into `info` (best-effort, mirroring the .gd
## first-line sniff): `public partial class X [: Base]` → class_name / extends.
func _sniff_cs(text: String, info: Dictionary) -> void:
	var re := RegEx.new()
	re.compile("public\\s+partial\\s+class\\s+(\\w+)\\s*(?::\\s*([\\w.]+))?")
	var m := re.search(text)
	if m == null:
		return
	info["class_name"] = m.get_string(1)
	var base_type := m.get_string(2)
	if not base_type.is_empty():
		info["extends"] = base_type


func _read(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not FileAccess.file_exists(path):
		return error_not_found("Script '%s'" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return error_internal("Cannot read script: %s" % error_string(FileAccess.get_open_error()))
	var content := file.get_as_text()
	file.close()
	var total := content.count("\n") + 1
	var result := {"path": path, "content": content, "line_count": total, "size": content.length()}

	# --start-line/--end-line (1-based, inclusive) return a slice instead of the
	# whole file — the same line addressing script.edit already uses, so a read
	# around a reported error line doesn't cost the file. Out-of-range values clamp.
	if params.has("start_line") or params.has("end_line"):
		var lines := content.split("\n")
		var start := clampi(optional_int(params, "start_line", 1), 1, lines.size())
		var end := clampi(optional_int(params, "end_line", lines.size()), start, lines.size())
		var slice: PackedStringArray = []
		for i in range(start - 1, end):
			slice.append(lines[i])
		result["content"] = "\n".join(slice)
		result["start_line"] = start
		result["end_line"] = end
		result["size"] = String(result["content"]).length()
	return success(result)


func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var path_guard := guard_project_path(path)
	if not path_guard.is_empty():
		return path_guard
	var guard := _guard_script_ext(path, "script.create")
	if not guard.is_empty():
		return guard
	guard = guard_text_resource_write(path, optional_bool(params, "force", false))
	if not guard.is_empty():
		return guard

	var content := optional_string(params, "content", "")
	if content.is_empty():
		if path.get_extension().to_lower() == "cs":
			var cs := _cs_template(path, params)
			if cs[1] != null:
				return cs[1]
			content = cs[0]
		else:
			var lines: PackedStringArray = []
			var class_name_str := optional_string(params, "class_name", "")
			if not class_name_str.is_empty():
				lines.append("class_name %s" % class_name_str)
			lines.append("extends %s" % optional_string(params, "extends", "Node"))
			lines.append("")
			lines.append("")
			lines.append("func _ready() -> void:")
			lines.append("\tpass")
			lines.append("")
			content = "\n".join(lines)

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return error_internal("Cannot create script: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(content)
	file.close()

	_reload_script(path)
	return success({"path": path, "created": true, "size": content.length()})


## Build a C# script template. `--class-name` (default the file basename) must be
## a valid C# identifier and should match the file name so Godot resolves it;
## `--extends` (default "Node") is the base type. Returns [content, error_or_null].
func _cs_template(path: String, params: Dictionary) -> Array:
	var class_name_str := optional_string(params, "class_name", "")
	if class_name_str.is_empty():
		class_name_str = path.get_file().get_basename()
	var name_re := RegEx.new()
	name_re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	if name_re.search(class_name_str) == null:
		return [null, error_invalid_params(
			"Invalid C# class name '%s'. It must match ^[A-Za-z_][A-Za-z0-9_]*$ and should match the file name so Godot can find the class." % class_name_str
		)]
	var base_type := optional_string(params, "extends", "Node")
	# 4-space indentation in the C# body — C# convention (GDScript files use tabs).
	var lines: PackedStringArray = [
		"using Godot;",
		"",
		"public partial class %s : %s" % [class_name_str, base_type],
		"{",
		"    public override void _Ready()",
		"    {",
		"    }",
		"}",
		"",
	]
	return ["\n".join(lines), null]


func _edit(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var guard := _guard_script_ext(path, "script.edit")
	if not guard.is_empty():
		return guard
	if not FileAccess.file_exists(path):
		return error_not_found("Script '%s'" % path)
	guard = guard_text_resource_write(path, optional_bool(params, "force", false))
	if not guard.is_empty():
		return guard

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return error_internal("Cannot read script: %s" % error_string(FileAccess.get_open_error()))
	var content := file.get_as_text()
	file.close()

	var edited := _apply_edit(content, params)
	if edited[1] != null:
		return edited[1]
	var new_content: String = edited[0]
	var changes: int = edited[2]

	if changes == 0:
		return success({"path": path, "changes_made": 0, "message": "No changes applied"})

	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return error_internal("Cannot write script: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(new_content)
	file.close()

	_reload_script(path)
	return success({"path": path, "changes_made": changes})


## Apply one edit mode to `content`. Returns [new_content, error_or_null, changes].
## Modes (checked in order): replacements[] | content+start_line/end_line |
## content (full replace) | insert_at_line+text.
func _apply_edit(content: String, params: Dictionary) -> Array:
	if params.has("replacements") and params["replacements"] is Array:
		var changes := 0
		for replacement in params["replacements"]:
			if not replacement is Dictionary:
				continue
			var search: String = replacement.get("search", "")
			if search.is_empty():
				continue
			var replace: String = replacement.get("replace", "")
			if replacement.get("regex", false):
				var regex := RegEx.new()
				if regex.compile(search) == OK:
					var updated := regex.sub(content, replace, true)
					if updated != content:
						content = updated
						changes += 1
			elif content.contains(search):
				content = content.replace(search, replace)
				changes += 1
		return [content, null, changes]

	if params.has("content") and (params.has("start_line") or params.has("end_line")):
		if not params.has("start_line"):
			return [content, error_invalid_params("start_line is required when end_line is provided"), 0]
		var start_line := int(params["start_line"])
		var end_line := int(params.get("end_line", start_line))
		var lines := content.split("\n")
		if start_line < 1:
			return [content, error_invalid_params("start_line must be >= 1"), 0]
		if end_line < start_line:
			return [content, error_invalid_params("end_line must be >= start_line"), 0]
		if start_line > lines.size() or end_line > lines.size():
			return [content, error_invalid_params("line range is beyond the end of the file (%d lines)" % lines.size()), 0]
		var replacement_lines := str(params["content"]).split("\n")
		var start_index := start_line - 1
		for _i in range(end_line - start_line + 1):
			lines.remove_at(start_index)
		for i in range(replacement_lines.size()):
			lines.insert(start_index + i, replacement_lines[i])
		return ["\n".join(lines), null, 1]

	if params.has("content"):
		return [str(params["content"]), null, 1]

	if params.has("insert_at_line") and params.has("text"):
		var lines := content.split("\n")
		var line_num := clampi(int(params["insert_at_line"]), 0, lines.size())
		lines.insert(line_num, str(params["text"]))
		return ["\n".join(lines), null, 1]

	return [content, error_invalid_params("No edit specified. Provide replacements, content, or insert_at_line+text."), 0]


## Reload a script so the editor reflects disk changes immediately.
func _reload_script(path: String) -> void:
	EditorInterface.get_resource_filesystem().scan()
	if ResourceLoader.exists(path):
		var script = load(path)
		if script is Script:
			script.reload(true)


func _attach(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var sr := require_string(params, "script_path")
	if sr[1] != null:
		return sr[1]
	var node_path: String = r[0]
	var script_path: String = sr[0]

	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(node_path)
	if node == null:
		return error_not_found("Node '%s'" % node_path, "Use scene.tree to see available nodes")
	if not FileAccess.file_exists(script_path):
		return error_not_found("Script '%s'" % script_path)
	var script: Script = load(script_path)
	if script == null:
		return error_internal("Failed to load script: %s" % script_path)

	var old_script: Variant = node.get_script()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Attach script to %s" % node.name)
	undo_redo.add_do_method(node, "set_script", script)
	undo_redo.add_undo_method(node, "set_script", old_script)
	undo_redo.commit_action()
	return success({"node_path": str(root.get_path_to(node)), "script_path": script_path, "attached": true})


## Validate one file (--path), all modified/untracked .gd (--modified, git-aware),
## or every project .gd (--all). Exactly one mode; single-file mode is unchanged.
func _validate(params: Dictionary) -> Dictionary:
	var modified := optional_bool(params, "modified", false)
	var all := optional_bool(params, "all", false)
	var has_path := params.has("path")
	var mode_count := int(has_path) + int(modified) + int(all)
	if mode_count == 0:
		return error_invalid_params("script.validate needs exactly one of: --path <file>, --modified, or --all")
	if mode_count > 1:
		return error_invalid_params("script.validate takes exactly one of --path, --modified, or --all (not several)")

	if modified:
		return _validate_modified()
	if all:
		return _validate_all()

	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var guard := _guard_script_ext(path, "script.validate")
	if not guard.is_empty():
		return guard
	if not FileAccess.file_exists(path):
		return error_not_found("Script '%s'" % path)
	if path.get_extension().to_lower() == "cs":
		return await _validate_cs(path)
	return success(_validate_one(path))


## Validate a single .cs file. There is no per-file C# compile — the csproj is the
## unit — so this runs the same `dotnet build` csharp.build uses (shared via the
## static CSharpCommands.run_build), then filters diagnostics to this file.
func _validate_cs(path: String) -> Dictionary:
	var csproj := CSharpCommands.find_file_at_root("csproj")
	if csproj == null:
		return error_invalid_params("C# validation builds the project; no .csproj found — run csharp.setup first")

	var out: Array = []
	if OS.execute("dotnet", ["--version"], out, true) != 0:
		return error_invalid_params("C# validation needs the .NET SDK ('dotnet'), which was not found on PATH. Install it and reopen the editor.")

	var csproj_abs := ProjectSettings.globalize_path(String(csproj))
	var res: Dictionary = await CSharpCommands.run_build(csproj_abs, 240.0)
	var status := String(res.get("status", ""))
	if status == "spawn_failed":
		return error_internal("Failed to spawn the dotnet build process for C# validation")
	if status == "timeout":
		return error_internal("C# validation build timed out; see the log at %s" % String(res.get("log_path", "")))

	var target_abs := ProjectSettings.globalize_path(path).replace("\\", "/")
	var diagnostics: Array = []
	var file_has_error := false
	for entry in res.get("errors", []):
		if _diag_matches_file(entry, path, target_abs):
			diagnostics.append(entry)
			file_has_error = true
	for entry in res.get("warnings", []):
		if _diag_matches_file(entry, path, target_abs):
			diagnostics.append(entry)

	var project_error_count := int(res.get("error_count", 0))
	return success({
		"path": path,
		"valid": not file_has_error,
		"diagnostics": diagnostics,
		"project_error_count": project_error_count,
		"message": "C# validation builds the whole project; diagnostics are filtered to this file. Project reported %d error(s)." % project_error_count,
	})


## True if a build diagnostic refers to `res_path` (whose globalized path is
## `target_abs`). MSBuild file paths may be absolute or relative to the csproj
## dir, so match by path suffix, then fall back to basename.
func _diag_matches_file(entry: Dictionary, res_path: String, target_abs: String) -> bool:
	var diag_file := String(entry.get("file", "")).replace("\\", "/").strip_edges()
	if diag_file.is_empty():
		return false
	if target_abs.to_lower().ends_with(diag_file.to_lower()):
		return true
	if diag_file.to_lower().ends_with(target_abs.to_lower()):
		return true
	return diag_file.get_file().to_lower() == res_path.get_file().to_lower()


## Compile one .gd and return its result payload (the same dict single-mode wraps
## in success()): {path, valid, [error_code, error_string], message}.
func _validate_one(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"path": path,
			"valid": false,
			"error_string": error_string(FileAccess.get_open_error()),
			"message": "Cannot read script.",
		}
	var source := file.get_as_text()
	file.close()

	var err := _compile(source)
	# A `class_name` declaration registers a global class. When validating a file
	# whose class is already registered (e.g. right after creating it), the temp
	# script's identical `class_name` collides and fails to compile even though
	# the syntax is fine. Retry without that line to isolate real errors.
	if err != OK:
		var stripped := _strip_class_name(source)
		if stripped != source and _compile(stripped) == OK:
			err = OK

	if err == OK:
		return {"path": path, "valid": true, "message": "Script compiles successfully"}
	return {
		"path": path,
		"valid": false,
		"error_code": err,
		"error_string": error_string(err),
		"message": "Compilation failed. Check the editor output for line details.",
	}


## Run a list of res:// paths through _validate_one, returning only the failures.
func _validate_batch(paths: Array, mode: String) -> Dictionary:
	var checked := 0
	var passed := 0
	var failures: Array = []
	for res_path in paths:
		var result := _validate_one(res_path)
		checked += 1
		if result.get("valid", false):
			passed += 1
		else:
			failures.append(result)
	return success({
		"mode": mode,
		"checked": checked,
		"passed": passed,
		"failed": checked - passed,
		"results": failures,
		"note": "results lists failures only",
		"csharp_note": "C# files (.cs) validate via csharp.build",
	})


## Absolute path of the Godot project root, no trailing slash.
func _project_root_abs() -> String:
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/"):
		root = root.substr(0, root.length() - 1)
	return root


## Run `git -C <root> <args>` (OS.execute has no cwd, so -C is required).
## Returns [exit_code, merged_stdout_stderr].
func _exec_git(root: String, args: Array) -> Array:
	var full: PackedStringArray = ["-C", root]
	for a in args:
		full.append(String(a))
	var out: Array = []
	var code := OS.execute("git", full, out, true)
	var text := ""
	if out.size() > 0:
		text = String(out[0])
	return [code, text]


## --modified: validate every modified (vs HEAD) or untracked .gd tracked by git.
func _validate_modified() -> Dictionary:
	var root := _project_root_abs()

	var top := _exec_git(root, ["rev-parse", "--show-toplevel"])
	if int(top[0]) != 0:
		return error_invalid_params("script.validate --modified requires a git repository (git failed): %s" % String(top[1]).strip_edges())
	var git_top := String(top[1]).strip_edges().replace("\\", "/")
	if git_top.is_empty():
		return error_invalid_params("script.validate --modified could not determine the git repository root")

	var diff := _exec_git(root, ["diff", "--name-only", "HEAD"])
	if int(diff[0]) != 0:
		return error_invalid_params("script.validate --modified: git diff failed: %s" % String(diff[1]).strip_edges())
	# --full-name: ls-files is cwd-relative by default (unlike diff, which is
	# toplevel-relative); force toplevel-relative so both lists rebase the same way.
	var others := _exec_git(root, ["ls-files", "--others", "--exclude-standard", "--full-name"])
	if int(others[0]) != 0:
		return error_invalid_params("script.validate --modified: git ls-files failed: %s" % String(others[1]).strip_edges())

	# git returns forward-slash paths relative to git_top, which may sit ABOVE the
	# Godot project root. Build each absolute path, keep only those under the
	# project root, and rebase onto res://.
	var proj_prefix := root.replace("\\", "/")
	if not proj_prefix.ends_with("/"):
		proj_prefix += "/"

	var combined := String(diff[1]) + "\n" + String(others[1])
	var seen: Dictionary = {}
	var paths: Array = []
	for line in combined.split("\n"):
		var rel := line.strip_edges()
		if rel.is_empty() or not rel.ends_with(".gd"):
			continue
		var abs_path := (git_top + "/" + rel).replace("\\", "/")
		if not abs_path.begins_with(proj_prefix):
			continue  # outside the Godot project root
		var res_path := "res://" + abs_path.substr(proj_prefix.length())
		if seen.has(res_path):
			continue
		seen[res_path] = true
		if not FileAccess.file_exists(res_path):
			continue  # deleted in the working tree; nothing to validate
		paths.append(res_path)
	return _validate_batch(paths, "modified")


## --all: validate every .gd under res://, skipping addons/ and .godot/ (and
## hidden dirs), consistent with the project.grep skip convention.
func _validate_all() -> Dictionary:
	var paths: Array = []
	_collect_all_gd("res://", paths)
	return _validate_batch(paths, "all")


func _collect_all_gd(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var full_path := dir_path.path_join(file_name)
		if dir.current_is_dir():
			if file_name != "addons":
				_collect_all_gd(full_path, out)
		elif file_name.get_extension() == "gd":
			out.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()


func _compile(source: String) -> int:
	var script := GDScript.new()
	script.source_code = source
	return script.reload()


func _strip_class_name(source: String) -> String:
	var lines := source.split("\n")
	for i in range(lines.size()):
		if lines[i].strip_edges().begins_with("class_name "):
			lines.remove_at(i)
			return "\n".join(lines)
	return source


func _list_open(_params: Dictionary) -> Dictionary:
	var script_editor := EditorInterface.get_script_editor()
	var open_scripts: Array = []
	if script_editor != null:
		for script_base in script_editor.get_open_scripts():
			if script_base is Resource:
				open_scripts.append({"path": (script_base as Resource).resource_path, "type": script_base.get_class()})
	return success({"scripts": open_scripts, "count": open_scripts.size()})


## The API surface one script declares: methods, properties, signals, constants.
##
## engine.class_info covers only scripts registered as a global class_name, which
## leaves the ordinary case — a player.gd attached to a node — with no answer but
## script.read and a few hundred lines of context spent to learn six signatures.
func _symbols(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if path.get_extension().to_lower() != "gd":
		return error_invalid_params(
			"script.symbols reads GDScript (.gd). For C#, build the project and use engine.class_info."
		)
	if not FileAccess.file_exists(path):
		return error_not_found("Script '%s'" % path)

	var script := load(path) as Script
	if script == null:
		return error_internal(
			"Could not load '%s' as a script. Run script.validate --path %s for the parse error." % [path, path]
		)

	var payload := script_symbols(
		script,
		optional_string(params, "filter", ""),
		optional_bool(params, "include_private", false),
		optional_bool(params, "include_inherited", false),
	)
	payload.merge({
		"path": normalize_project_path(path),
		"base_type": script.get_instance_base_type(),
		"can_instantiate": script.can_instantiate(),
		"global_name": script.get_global_name(),
	})
	return success(payload)


## Every .gd file under `path` (or just `path` when it is a file). Mirrors
## script.list's skips: addons/ unless asked for, and hidden directories.
func _collect_gd_files(path: String, include_addons: bool, out: Array) -> void:
	if FileAccess.file_exists(path):
		out.append(path)
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := path.path_join(entry)
		if dir.current_is_dir():
			if include_addons or entry != "addons":
				_collect_gd_files(full, include_addons, out)
		elif entry.get_extension().to_lower() == "gd":
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## Lint GDScript against the official style guide. Native — no external binary, so
## this works wherever the addon does.
func _lint(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var is_file := FileAccess.file_exists(path)
	if not is_file and not DirAccess.dir_exists_absolute(path):
		return error_not_found("Path '%s'" % path)
	if is_file and path.get_extension().to_lower() != "gd":
		return error_invalid_params("script.lint reads GDScript (.gd). For C#, use script.validate.")

	var disable: Array = []
	for name in optional_string(params, "disable", "").split(",", false):
		var rule := name.strip_edges()
		if not rule.is_empty():
			disable.append(rule)
	var unknown: Array = []
	for rule in disable:
		if not GDScriptLinter.SEVERITY.has(rule):
			unknown.append(rule)
	if not unknown.is_empty():
		return error_invalid_params(
			"Unknown lint rule(s): %s. Known rules: %s"
			% [", ".join(PackedStringArray(unknown)), ", ".join(PackedStringArray(GDScriptLinter.rule_names()))]
		)

	var opts := {
		"max_line_length": optional_int(params, "max_line_length", 100),
		"disable": disable,
	}

	var targets: Array = []
	_collect_gd_files(path, optional_bool(params, "include_addons", false), targets)
	if targets.is_empty():
		return error_not_found("GDScript files under '%s'" % path)

	var findings: Array = []
	var errors := 0
	var warnings := 0
	var invalid: Array = []

	for file_path in targets:
		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			continue
		var source := file.get_as_text()
		file.close()

		var res_path := normalize_project_path(file_path)
		for f in GDScriptLinter.lint(source, opts):
			f["path"] = res_path
			findings.append(f)
			if f["severity"] == "error":
				errors += 1
			else:
				warnings += 1

		# Style rules read source, so they report on a file that does not compile —
		# and "no findings" would then read as "fine", which is the opposite of the
		# truth. Only single-file runs pay for the compile check: it builds a
		# throwaway GDScript per file, and every one of those writes its diagnostics
		# to the editor's error log, so sweeping a directory would bury the real
		# contents of editor.errors under temp-compile noise. Directory runs point at
		# script.validate --all instead, which is the command for exactly that.
		if is_file:
			var check := _validate_one(file_path)
			if not check["valid"]:
				invalid.append({"path": res_path, "reason": check.get("error_string", "parse error")})

	var payload := {
		"path": normalize_project_path(path),
		"findings": findings,
		"count": findings.size(),
		"error_count": errors,
		"warning_count": warnings,
		"files_checked": targets.size(),
	}
	if is_file:
		payload["syntax_valid"] = invalid.is_empty()
		payload["does_not_compile"] = invalid
		if not invalid.is_empty():
			payload["warning"] = (
				"This file does not compile, so style findings are incomplete: %s. Fix it first (script.validate)."
				% invalid[0]["reason"]
			)
	else:
		payload["syntax_checked"] = false
		payload["note"] = "Style only — run script.validate --all to compile-check these files."
	return success(payload)


func get_command_docs() -> Dictionary:
	return {
		"script.list": {
			"description": "List GDScript/C# files under --path, sniffing each file's class_name/extends.",
			"params": [
				doc_param("path", "String", false, "Root directory (default 'res://')."),
				doc_param("recursive", "bool", false, "Recurse into subdirectories (default true; skips addons/)."),
			],
		},
		"script.read": {
			"description": "Read a script file by --path: the whole text, or the 1-based inclusive line range --start-line..--end-line. line_count is always the file's real total.",
			"params": [
				doc_param("path", "String", true, "res:// path to a .gd or .cs file."),
				doc_param("start_line", "int", false, "1-based first line to return (default 1). Clamped to the file."),
				doc_param("end_line", "int", false, "1-based last line to return, inclusive (default the last line)."),
			],
		},
		"script.create": {
			"description": "Create a new script at --path (.gd or .cs). Without --content, writes a stub: GDScript uses --class-name/--extends; C# writes a `public partial class` (--class-name defaults to the file basename and must be a valid identifier).",
			"params": [
				doc_param("path", "String", true, "res:// path to write (.gd or .cs)."),
				doc_param("content", "String", false, "Full file contents; when omitted a stub template is generated."),
				doc_param("class_name", "String", false, "class_name (GDScript) / C# class name (defaults to the file basename for .cs)."),
				doc_param("extends", "String", false, "Base type for the stub (default 'Node')."),
				doc_param("force", "bool", false, "Overwrite a file open in the script editor."),
			],
		},
		"script.edit": {
			"description": "Edit an existing script via one of four modes: --replacements (search/replace list), --content with --start-line/--end-line (replace a line range), --content alone (full replace), or --insert-at-line + --text (insert).",
			"params": [
				doc_param("path", "String", true, "res:// path to the script."),
				doc_param("replacements", "Array", false, "List of {search, replace, regex?} edits."),
				doc_param("content", "String", false, "Replacement text — a line range (with --start-line/--end-line) or the whole file."),
				doc_param("start_line", "int", false, "1-based first line to replace (with --content)."),
				doc_param("end_line", "int", false, "1-based last line to replace (default start_line)."),
				doc_param("insert_at_line", "int", false, "Line index to insert --text at."),
				doc_param("text", "String", false, "Text to insert (with --insert-at-line)."),
				doc_param("force", "bool", false, "Overwrite a file open in the script editor."),
			],
		},
		"script.attach": {
			"description": "Attach an existing script (--script-path) to a node (--node-path) in the edited scene. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to attach the script to."),
				doc_param("script_path", "String", true, "res:// path to the script."),
			],
		},
		"script.validate": {
			"description": "Compile-check scripts. Exactly one of: --path (one file; .gd compiles, .cs runs a filtered dotnet build), --modified (git-modified/untracked .gd), or --all (every .gd under res://).",
			"params": [
				doc_param("path", "String", false, "Single file to validate (.gd or .cs). Exactly one of path/modified/all."),
				doc_param("modified", "bool", false, "Validate git-modified and untracked .gd files. Exactly one of path/modified/all."),
				doc_param("all", "bool", false, "Validate every .gd under res:// (skips addons/). Exactly one of path/modified/all."),
			],
		},
		"script.list_open": {
			"description": "List scripts currently open in the editor's script editor.",
		},
		"script.symbols": {
			"description": "Read one GDScript's declared API — methods, properties, signals, constants — without reading the file. Works on any .gd path, including scripts with no class_name (which engine.class_info cannot reach). Reports what this file declares; --include-inherited adds members from the scripts it extends. Engine members are never included — get those from engine.class_info on the reported base_type.",
			"params": [
				doc_param("path", "String", true, "res:// path to a .gd file."),
				doc_param("filter", "String", false, "Case-insensitive substring filter over member names."),
				doc_param("include_private", "bool", false, "Include methods starting with '_' (default false)."),
				doc_param("include_inherited", "bool", false, "Add members inherited from base scripts (default false)."),
			],
		},
		"script.lint": {
			"description": "Lint GDScript against the official style guide. Native — needs no external tool. Returns structured findings: path, line, rule, severity, message. --path may be a file or a directory (default 'res://', skipping addons/). 17 rules: the 9 naming rules are severity 'error', the rest ('duplicated-load', 'unnecessary-pass', 'unused-argument', 'comparison-with-itself', 'private-access', 'no-else-return', 'standalone-expression', 'max-line-length') are warnings. Style rules read source, so they also report on a file that does not compile: a single-file run therefore also compile-checks it and reports `syntax_valid`, since zero findings on a broken file would otherwise read as clean. A directory run is style-only (`syntax_checked: false`) — use script.validate --all to compile-check a tree. Suppress inline with `# gdlint-ignore[-next-line] rule[,rule]`.",
			"params": [
				doc_param("path", "String", false, "File or directory to lint (default 'res://')."),
				doc_param("disable", "String", false, "Comma-separated rule names to skip, e.g. 'max-line-length,unused-argument'. An unknown name is an error listing the known ones."),
				doc_param("max_line_length", "int", false, "Line-length limit for the max-line-length rule (default 100; 0 disables it)."),
				doc_param("include_addons", "bool", false, "Lint addons/ too (skipped by default unless --path points inside it)."),
			],
		},
	}
