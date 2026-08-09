@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Project-local command group: the reference audit.
##
## [code]example_commands.gd[/code] shows the minimal shape of the res://mcp_commands/
## hook; this file shows what it is FOR — a chore your project actually has, exposed
## as one tool instead of a run-script snippet you rewrite from memory every time.
##
## - [b]custom.broken_refs[/b] reports every res:// path and uid:// id in the project's
##   text files that no longer resolves, with the file and line it sits on.
## - [b]custom.replace_ref[/b] repoints every reference from one resource to another in
##   one pass, fixing the ext_resource uid attribute beside each rewritten path.
##
## Read-only sweep and guarded write path, so between them the pair covers both halves
## of what a project command may do. Copy the file, keep the two guards.
##
## Editing this file needs a FULL editor restart to recompile; editor.reload_plugin
## re-runs registration but does not re-parse changed GDScript from disk.

## Text formats that can carry a resource reference. Binary .scn/.res are deliberately
## absent: a text scan cannot read one, and skipping it beats reporting it as clean.
const SCANNED_EXTS := [
	"tscn", "tres", "gd", "gdshader", "gdshaderinc", "import", "cfg", "json", "godot", "cs",
]
## A path built at runtime ("res://levels/%s.tscn") cannot be checked from source, so it
## is reported apart from the broken ones rather than accused of being one.
const DYNAMIC_MARKERS := ["%", "{", "*", "+"]
const DEFAULT_LIMIT := 200


func get_commands() -> Dictionary:
	return {
		"custom.broken_refs": _broken_refs,
		"custom.replace_ref": _replace_ref,
	}


## Param metadata, the [CliArg] equivalent: engine.commands --group custom serves it and
## the CLI renders `godot-mcp custom broken-refs --help` from it. Extending base_command
## buys the doc_param() helper; example_commands.gd writes the same dicts by hand for a
## group that only `extends Node`.
func get_command_docs() -> Dictionary:
	return {
		"custom.broken_refs": {
			"description": "Report res:// paths and uid:// ids that no longer resolve.",
			"params": [
				doc_param("path", "String", false, "Directory to scan (default res://)."),
				doc_param("include_addons", "bool", false, "Scan addons/ too (default false)."),
				doc_param("limit", "int", false, "Max findings per list (default 200)."),
			],
		},
		"custom.replace_ref": {
			"description": "Repoint every reference from one resource to another, uid included.",
			"params": [
				doc_param("from", "String", true, "res:// path referenced today (may be missing on disk)."),
				doc_param("to", "String", true, "res:// path to point at; must exist."),
				doc_param("dry_run", "bool", false, "Report changes without writing (default false)."),
				doc_param("path", "String", false, "Directory to rewrite under (default res://)."),
				doc_param("include_addons", "bool", false, "Rewrite under addons/ too (default false)."),
				doc_param("force", "bool", false, "Rewrite a scene open in the editor anyway (default false)."),
			],
		},
	}


# --- Commands ---------------------------------------------------------------

func _broken_refs(params: Dictionary) -> Dictionary:
	var root := normalize_project_path(optional_string(params, "path", "res://"))
	if not root.begins_with("res://"):
		return error_invalid_params("custom.broken_refs scans under res://, got '%s'" % root)
	var limit := maxi(1, optional_int(params, "limit", DEFAULT_LIMIT))
	var files := _scan_files(root, optional_bool(params, "include_addons", false))

	var broken: Array = []
	var dynamic: Array = []
	var checked := 0

	for file_path: String in files:
		var text := _read(file_path)
		if text.is_empty():
			continue
		var line_no := 0
		for line: String in text.split("\n"):
			line_no += 1
			for ref: Dictionary in _refs_in_line(line):
				var value: String = ref["ref"]
				if _is_dynamic(value):
					dynamic.append({"file": file_path, "line": line_no, "ref": value})
					continue
				checked += 1
				if not _resolves(value, ref["kind"]):
					broken.append({
						"file": file_path, "line": line_no, "ref": value, "kind": ref["kind"],
					})

	return success({
		"scanned_files": files.size(),
		"checked_refs": checked,
		"broken_count": broken.size(),
		"broken": broken.slice(0, limit),
		"dynamic_count": dynamic.size(),
		"dynamic": dynamic.slice(0, limit),
		"truncated": broken.size() > limit or dynamic.size() > limit,
	})


func _replace_ref(params: Dictionary) -> Dictionary:
	var from_r := require_string(params, "from")
	if from_r[1] != null:
		return from_r[1]
	var to_r := require_string(params, "to")
	if to_r[1] != null:
		return to_r[1]
	var from_path := normalize_project_path(from_r[0])
	var to_path := normalize_project_path(to_r[0])

	# Both are write targets: `to` gets written INTO the project's files, `from` decides
	# which token those writes replace. Guard the pair before touching anything.
	for candidate: String in [from_path, to_path]:
		var guard := guard_project_path(candidate)
		if not guard.is_empty():
			return guard
	if from_path == to_path:
		return error_invalid_params("custom.replace_ref: --from and --to are the same path")
	# `from` may be gone — repointing a dangling reference is the whole point — but a
	# `to` that does not exist would only trade one broken reference for another.
	if not _resource_exists(to_path):
		return error_not_found("Replacement '%s'" % to_path)

	var root := normalize_project_path(optional_string(params, "path", "res://"))
	var dry_run := optional_bool(params, "dry_run", false)
	var force := optional_bool(params, "force", false)
	var files := _scan_files(root, optional_bool(params, "include_addons", false))
	var to_uid := ResourceUID.id_to_text(ResourceLoader.get_resource_uid(to_path))
	if not to_uid.begins_with("uid://"):
		to_uid = ""

	# Plan every file first, THEN write. A refusal discovered halfway through would leave
	# the project half repointed, which is the state this command exists to get out of.
	var plan: Array = []
	var blocked: Array = []
	var occurrences := 0
	for file_path: String in files:
		var text := _read(file_path)
		if not text.contains(from_path):
			continue
		var rewrite := _rewrite(text, from_path, to_path, to_uid)
		if rewrite["hits"] == 0:
			continue
		occurrences += int(rewrite["hits"])
		rewrite["file"] = file_path
		plan.append(rewrite)
		# A scene open in the editor is held in memory, and the tab's next save would write
		# it back over our edit — the same -32009 refusal the built-in file commands raise,
		# with --force left to the caller.
		if is_scene_path_open(file_path):
			blocked.append(file_path)

	if not blocked.is_empty() and not dry_run and not force:
		return error_conflict(
			"Refusing to rewrite %d file(s) open in the editor" % blocked.size(),
			{"open_scenes": blocked, "suggestion": "Close the scene tab, or pass --force."})

	var changed: Array = []
	for rewrite: Dictionary in plan:
		changed.append({
			"file": rewrite["file"],
			"lines": rewrite["lines"],
			"uid_updated": rewrite["uid_updated"],
		})
		if dry_run:
			continue
		var w := FileAccess.open(rewrite["file"], FileAccess.WRITE)
		if w == null:
			return error_internal("could not write '%s'" % rewrite["file"])
		w.store_string(rewrite["text"])
		w.close()

	if not dry_run and not changed.is_empty():
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.scan()

	return success({
		"from": from_path,
		"to": to_path,
		"to_uid": to_uid,
		"dry_run": dry_run,
		"occurrences": occurrences,
		"files_changed": changed,
		"open_in_editor": blocked,
	})


# --- Internals --------------------------------------------------------------

## Every scannable text file under `root`. Skips dot-directories (.godot, .git) and,
## unless asked, addons/ — the same exclusions project.grep applies, for the same
## reason: findings in vendored code are somebody else's chore.
func _scan_files(root: String, include_addons: bool) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var da := DirAccess.open(dir)
		if da == null:
			continue
		da.list_dir_begin()
		var entry := da.get_next()
		while entry != "":
			var child := dir.path_join(entry)
			if entry.begins_with("."):
				entry = da.get_next()
				continue
			if da.current_is_dir():
				if include_addons or entry != "addons":
					stack.append(child)
			elif SCANNED_EXTS.has(entry.get_extension().to_lower()):
				out.append(child)
			entry = da.get_next()
		da.list_dir_end()
	out.sort()
	return out


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## Rewrite `from` to `to` line by line, and repair the uid attribute that sits beside a
## rewritten path on an ext_resource line — a .tscn carries both, and the loader prefers a
## uid that resolves, so a path-only rewrite still loads the old resource. Token replacement
## (path + closing quote) is fs.move's idiom, deliberately: it survives a scene format
## that grows new attributes, which 4.8 does.
func _rewrite(text: String, from_path: String, to_path: String, to_uid: String) -> Dictionary:
	var uid_re := RegEx.create_from_string("uid=\"uid://[0-9a-z]+\"")
	var lines := text.split("\n")
	var hits := 0
	var touched: Array = []
	var uid_updated := false
	for i in lines.size():
		var line: String = lines[i]
		var updated := line.replace(from_path + "\"", to_path + "\"")
		updated = updated.replace(from_path + "'", to_path + "'")
		if updated == line:
			continue
		hits += 1
		touched.append(i + 1)
		if not to_uid.is_empty() and uid_re.search(updated) != null:
			updated = uid_re.sub(updated, "uid=\"%s\"" % to_uid)
			uid_updated = true
		lines[i] = updated
	return {
		"text": "\n".join(lines),
		"hits": hits,
		"lines": touched,
		"uid_updated": uid_updated,
	}


## References carried by one line, read out of its QUOTED spans only, then shape-checked.
## Every reference in a Godot text format is quoted — path=res://x.png in a scene, a preload
## argument in a script, the autoload's leading-star form — so matching the bare scheme
## instead reports the prose of every comment that mentions res://, this file's own header
## included, which is how the first sweep found it. A quoted value counts from wherever
## res:// starts inside it, and then has to look like a path: no whitespace, and a file
## extension or a trailing slash.
##
## What survives is a quoted string in CODE that is shaped exactly like a real reference
## (an error message naming a path, say). Source scanning cannot tell that from a preload
## without parsing the file, so it is reported and left to the reader.
func _refs_in_line(line: String) -> Array:
	var out: Array = []
	var quoted := RegEx.create_from_string("\"[^\"]*\"|'[^']*'")
	var uid_shape := RegEx.create_from_string("^uid://[a-z0-9]+$")
	for m: RegExMatch in quoted.search_all(line):
		var value := m.get_string().substr(1, m.get_string().length() - 2)
		var at := value.find("res://")
		if at >= 0:
			var ref := value.substr(at)
			if not _path_shaped(ref):
				continue
			out.append({"ref": ref, "kind": "path"})
		elif uid_shape.search(value) != null:
			out.append({"ref": value, "kind": "uid"})
	return out


func _path_shaped(ref: String) -> bool:
	if ref.contains(" ") or ref.contains("\t"):
		return false
	return ref.ends_with("/") or not ref.get_file().get_extension().is_empty()


func _resolves(ref: String, kind: String) -> bool:
	if kind == "uid":
		var id := ResourceUID.text_to_id(ref)
		return id != ResourceUID.INVALID_ID and ResourceUID.has_id(id)
	return _resource_exists(ref)


## A reference is dynamic when the source builds it at runtime; there is nothing on disk
## to check it against, so it is reported separately instead of called broken.
func _is_dynamic(ref: String) -> bool:
	for marker: String in DYNAMIC_MARKERS:
		if ref.contains(marker):
			return true
	return false


## A res:// reference resolves if the file is there, the directory is there, or an
## imported source sits beside a .import (Godot writes the SOURCE path into a scene, and
## the imported copy lives in .godot/imported/).
func _resource_exists(ref: String) -> bool:
	var path := ref
	if path.contains("::"):
		path = path.get_slice("::", 0)  # sub-resource ids ride on the file path
	return FileAccess.file_exists(path) \
		or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)) \
		or FileAccess.file_exists(path + ".import")
