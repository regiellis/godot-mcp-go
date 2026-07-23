@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Filesystem / asset-management commands: create folders, and move/rename, copy,
## or delete resource files WITH dependency fixup — the one workflow the generic
## node.* layer can't reach (there is no property to "move res://a.tscn and fix its
## referencers"). Godot's EditorFileSystem exposes no move/rename, so we move on disk
## via DirAccess, update the ResourceUID cache, rewrite path-based references, and
## rescan. UID-based references (uid://…) survive the move untouched; only literal
## res:// path references need rewriting.

# Text file types whose contents may carry res:// path references worth rewriting.
const _TEXT_EXTS := ["tscn", "tres", "gd", "gdshader", "gdshaderinc", "import", "cfg", "json", "godot", "cs"]


func get_commands() -> Dictionary:
	return {
		"fs.mkdir": _mkdir,
		"fs.move": _move,
		"fs.copy": _copy,
		"fs.delete": _delete,
	}


# --- Commands ---------------------------------------------------------------

func _mkdir(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path := normalize_project_path(r[0])
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard
	if DirAccess.dir_exists_absolute(_g(path)):
		return success({"path": path, "created": false, "already_exists": true})
	if DirAccess.make_dir_recursive_absolute(_g(path)) != OK:
		return error_internal("could not create directory '%s'" % path)
	_rescan()
	return success({"path": path, "created": true})


func _move(params: Dictionary) -> Dictionary:
	var pr := _resolve_src_dest(params)
	if pr[2] != null:
		return pr[2]
	var src: String = pr[0]
	var dest: String = pr[1]
	var is_dir := DirAccess.dir_exists_absolute(_g(src))

	# Refuse to move a scene that's open in the editor (would desync editor state).
	if not is_dir and is_scene_path_open(src):
		return error_conflict(
			"Refusing to move open scene '%s'" % src,
			{"open_scenes": get_open_scene_paths(), "suggestion": "Close the scene tab first."})

	var old_uid := ResourceLoader.get_resource_uid(src) if not is_dir else ResourceUID.INVALID_ID

	if DirAccess.rename_absolute(_g(src), _g(dest)) != OK:
		return error_internal("could not move '%s' to '%s'" % [src, dest])
	# Move the .import sidecar alongside an imported asset.
	if not is_dir and FileAccess.file_exists(src + ".import"):
		DirAccess.rename_absolute(_g(src + ".import"), _g(dest + ".import"))

	# Keep uid://→path resolution valid for the moved file without waiting on a rescan.
	if old_uid != ResourceUID.INVALID_ID:
		ResourceUID.set_id(old_uid, dest)

	var rewritten := _rewrite_refs(src, dest, is_dir)
	_rescan()
	return success({
		"moved": true, "from": src, "to": dest, "is_directory": is_dir,
		"uid": ResourceUID.id_to_text(old_uid) if old_uid != ResourceUID.INVALID_ID else "",
		"references_updated": rewritten,
	})


func _copy(params: Dictionary) -> Dictionary:
	var pr := _resolve_src_dest(params)
	if pr[2] != null:
		return pr[2]
	var src: String = pr[0]
	var dest: String = pr[1]

	if DirAccess.dir_exists_absolute(_g(src)):
		return error_invalid_params("fs.copy handles files, not directories: '%s'" % src)
	if DirAccess.copy_absolute(_g(src), _g(dest)) != OK:
		return error_internal("could not copy '%s' to '%s'" % [src, dest])
	if FileAccess.file_exists(src + ".import"):
		DirAccess.copy_absolute(_g(src + ".import"), _g(dest + ".import"))

	# Give the copy a fresh uid so it doesn't collide with the source's.
	var new_uid := _regen_uid(dest)
	_rescan()
	return success({"copied": true, "from": src, "to": dest, "uid": new_uid})


func _delete(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path := normalize_project_path(r[0])
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return error_invalid_params("fs.delete path must be under res:// or user://")
	var is_dir := DirAccess.dir_exists_absolute(_g(path))
	if not is_dir and not FileAccess.file_exists(path):
		return error_not_found("Path '%s'" % path)
	if not is_dir and is_scene_path_open(path):
		return error_conflict(
			"Refusing to delete open scene '%s'" % path,
			{"open_scenes": get_open_scene_paths(), "suggestion": "Close the scene tab first."})

	var force := optional_bool(params, "force", false)
	# A directory delete is recursive, so it must also refuse to nuke an open scene
	# living underneath it (the file-delete guard above only covers a direct target).
	if is_dir and not force:
		var open_under: Array = []
		for sp: String in get_open_scene_paths():
			if sp.begins_with(path + "/"):
				open_under.append(sp)
		if not open_under.is_empty():
			return error_conflict(
				"Refusing to delete '%s': it contains %d open scene(s)" % [path, open_under.size()],
				{"open_scenes": open_under, "suggestion": "Close those scene tabs, or pass --force."})
	var refs := _referencers(path) if not is_dir else []
	if not refs.is_empty() and not force:
		return error_conflict(
			"'%s' is referenced by %d file(s); pass --force to delete anyway" % [path, refs.size()],
			{"referencers": refs, "suggestion": "Repoint or remove the referencers first, or --force."})

	var old_uid := ResourceLoader.get_resource_uid(path) if not is_dir else ResourceUID.INVALID_ID
	var err := _remove_recursive(path) if is_dir else _remove_file(path)
	if err != OK:
		return error_internal("could not delete '%s'" % path)
	if old_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(old_uid):
		ResourceUID.remove_id(old_uid)
	_rescan()
	return success({"deleted": true, "path": path, "is_directory": is_dir, "was_referenced_by": refs})


# --- Helpers ----------------------------------------------------------------

func _g(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _rescan() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.scan()


## Validate src (exists, in project) and dest (in project, free unless --force).
## Makes dest's parent dir if needed. Returns [src, dest, error_or_null].
func _resolve_src_dest(params: Dictionary) -> Array:
	var sr := require_string(params, "from")
	if sr[1] != null:
		return [null, null, sr[1]]
	var dr := require_string(params, "to")
	if dr[1] != null:
		return [null, null, dr[1]]
	var src := normalize_project_path(sr[0])
	var dest := normalize_project_path(dr[0])
	if not (src.begins_with("res://") or src.begins_with("user://")):
		return [null, null, error_invalid_params("--from must be under res:// or user://")]
	var guard := guard_project_path(dest)
	if not guard.is_empty():
		return [null, null, guard]
	if not (DirAccess.dir_exists_absolute(_g(src)) or FileAccess.file_exists(src)):
		return [null, null, error_not_found("Source '%s'" % src)]
	var force := optional_bool(params, "force", false)
	if (FileAccess.file_exists(dest) or DirAccess.dir_exists_absolute(_g(dest))) and not force:
		return [null, null, error_conflict("Destination '%s' already exists; pass --force to overwrite" % dest)]
	var parent := dest.get_base_dir()
	if not parent.is_empty() and not DirAccess.dir_exists_absolute(_g(parent)):
		DirAccess.make_dir_recursive_absolute(_g(parent))
	return [src, dest, null]


## Rewrite literal res:// path references from `old` to `new` across every text file.
## For a file move, references end with a quote (`path="res://old"`, `preload("…")`),
## so match `old"` / `old'`. For a directory, references share the `old/` prefix.
## Returns the list of files changed.
func _rewrite_refs(old: String, new: String, is_dir: bool) -> Array:
	var changed: Array = []
	for fp: String in _all_project_files():
		if not _TEXT_EXTS.has(fp.get_extension().to_lower()):
			continue
		var f := FileAccess.open(fp, FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		var updated := text
		if is_dir:
			updated = updated.replace(old + "/", new + "/")
		else:
			updated = updated.replace(old + "\"", new + "\"").replace(old + "'", new + "'")
		if updated == text:
			continue
		var w := FileAccess.open(fp, FileAccess.WRITE)
		if w == null:
			continue
		w.store_string(updated)
		w.close()
		changed.append(fp)
	return changed


## Files that depend on `path` (by path or by its uid). No reverse index exists, so
## this is O(files) get_dependencies calls — same approach as resource.info.
func _referencers(path: String) -> Array:
	var uid_id := ResourceLoader.get_resource_uid(path)
	var uid_text := ResourceUID.id_to_text(uid_id) if uid_id != ResourceUID.INVALID_ID else ""
	var refs: Array = []
	for fp: String in _all_project_files():
		if fp == path:
			continue
		for d in ResourceLoader.get_dependencies(fp):
			if d.contains(path) or (not uid_text.is_empty() and d.contains(uid_text)):
				refs.append(fp)
				break
	return refs


## Replace the copied file's own uid with a fresh one so source and copy don't clash.
## The uid literal lives on line 0 of a text resource, or on the uid= line of a .import.
func _regen_uid(path: String) -> String:
	var target := path + ".import" if FileAccess.file_exists(path + ".import") else path
	if not FileAccess.file_exists(target):
		return ""
	var f := FileAccess.open(target, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	var re := RegEx.new()
	re.compile("uid://[0-9a-z]+")
	var m := re.search(text)
	if m == null:
		return ""  # no uid in this resource (unusual); leave as-is
	var new_id := ResourceUID.create_id()
	var new_text := ResourceUID.id_to_text(new_id)
	var updated := text.substr(0, m.get_start()) + new_text + text.substr(m.get_end())
	var w := FileAccess.open(target, FileAccess.WRITE)
	if w == null:
		return ""
	w.store_string(updated)
	w.close()
	ResourceUID.add_id(new_id, path)
	return new_text


## Every file under res:// (recursive), skipping hidden/engine dirs (.godot, .git).
func _all_project_files() -> Array:
	var out: Array = []
	var stack: Array = ["res://"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var da := DirAccess.open(dir)
		if da == null:
			continue
		da.list_dir_begin()
		var name := da.get_next()
		while name != "":
			if name.begins_with("."):
				name = da.get_next()
				continue
			var child := dir.path_join(name)
			if da.current_is_dir():
				stack.append(child)
			else:
				out.append(child)
			name = da.get_next()
		da.list_dir_end()
	return out


func _remove_file(path: String) -> int:
	if FileAccess.file_exists(path + ".import"):
		DirAccess.remove_absolute(_g(path + ".import"))
	return DirAccess.remove_absolute(_g(path))


func _remove_recursive(dir: String) -> int:
	var da := DirAccess.open(dir)
	if da == null:
		return FAILED
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		var child := dir.path_join(name)
		if da.current_is_dir():
			_remove_recursive(child)
		else:
			DirAccess.remove_absolute(_g(child))
		name = da.get_next()
	da.list_dir_end()
	return DirAccess.remove_absolute(_g(dir))


func get_command_docs() -> Dictionary:
	return {
		"fs.mkdir": {
			"description": "Create a folder under the project (recursive; no-op if it already exists), then rescan the filesystem.",
			"params": [
				doc_param("path", "String", true, "Folder path to create (res:// or user://)."),
			],
		},
		"fs.move": {
			"description": "Move/rename a file or directory WITH dependency fixup: updates the ResourceUID cache, rewrites literal res:// path references across text files, moves the .import sidecar, and rescans. Refuses to move a scene open in the editor.",
			"params": [
				doc_param("from", "String", true, "Source file/dir path (res:// or user://)."),
				doc_param("to", "String", true, "Destination path."),
				doc_param("force", "bool", false, "Overwrite an existing destination (default false)."),
			],
		},
		"fs.copy": {
			"description": "Copy a file (not a directory), giving the copy a fresh uid so it doesn't collide with the source. Copies the .import sidecar too, then rescans.",
			"params": [
				doc_param("from", "String", true, "Source file path (files only)."),
				doc_param("to", "String", true, "Destination path."),
				doc_param("force", "bool", false, "Overwrite an existing destination (default false)."),
			],
		},
		"fs.delete": {
			"description": "Delete a file or directory. Refuses (without --force) to delete a file that has referencers, or a directory containing an open scene; reports what would break.",
			"params": [
				doc_param("path", "String", true, "File/dir path to delete (res:// or user://)."),
				doc_param("force", "bool", false, "Delete despite referencers / contained open scenes (default false)."),
			],
		},
	}
