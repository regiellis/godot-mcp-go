@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Editor introspection and control: errors, output log, screenshots, running
## ad-hoc @tool scripts, filesystem reload, signals, and the 3D editor camera.

## Benign engine-internal lines (not from the user's project) that the scene
## save / progress UI paths emit. editor.errors filters these by default so they
## don't masquerade as real errors; pass include_noise=true to keep them.
const _NOISE: PackedStringArray = [
	"ProgressDialog::task_step",
	"Parameter \"t\" is null",
]


func _is_noise(line: String) -> bool:
	for pat in _NOISE:
		if line.contains(pat):
			return true
	return false


func get_commands() -> Dictionary:
	return {
		"editor.errors": _errors,
		"editor.log": _log,
		"editor.screenshot": _screenshot,
		"editor.run_script": _run_script,
		"editor.clear_output": _clear_output,
		"editor.reload": _reload,
		"editor.reload_plugin": _reload_plugin,
		"editor.signals": _signals,
		"editor.compare_screenshots": _compare_screenshots,
		"editor.get_camera": _get_camera,
		"editor.set_camera": _set_camera,
		"editor.selection": _selection,
	}


# --- Editor selection (the "borrow the user's eyes" bridge) -----------------

## Return the editor's currently selected nodes as paths relative to the edited
## scene root. Pair with `--node-path selected` (resolved in base_command) so the
## user can click a node and the agent acts on it without guessing the path.
func _selection(_params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var paths: Array = []
	for n: Node in EditorInterface.get_selection().get_selected_nodes():
		if n == root or root.is_ancestor_of(n):
			paths.append(str(root.get_path_to(n)))
	return success({"count": paths.size(), "selected": paths})


# --- Errors & output --------------------------------------------------------

func _errors(params: Dictionary) -> Dictionary:
	var max_lines := optional_int(params, "max_lines", 50)
	var include_noise := optional_bool(params, "include_noise", false)
	var errors: Array = []
	var suppressed := 0

	# 1. The Output panel (runtime errors, parse errors, warnings).
	var rtl := _find_output_rtl()
	if rtl != null:
		var lines := rtl.get_parsed_text().split("\n")
		var start := maxi(0, lines.size() - max_lines)
		for i in range(start, lines.size()):
			var line: String = lines[i]
			if line.contains("ERROR") or line.contains("SCRIPT ERROR") or line.contains("Parse Error") or line.contains("WARNING"):
				if not include_noise and _is_noise(line):
					suppressed += 1
					continue
				errors.append(line.strip_edges())

	# 2. The GDScript analyzer panels under each open script editor.
	#    Each editor holds a VSplitContainer whose children [1]/[2] are the
	#    warnings / errors RichTextLabels.
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		var open_editors := script_editor.get_open_script_editors()
		var open_scripts := script_editor.get_open_scripts()
		for ei in range(open_editors.size()):
			var path := ""
			if ei < open_scripts.size() and open_scripts[ei] is Resource:
				path = (open_scripts[ei] as Resource).resource_path
			var vsplit: VSplitContainer = null
			for c in open_editors[ei].get_children():
				if c is VSplitContainer:
					vsplit = c
					break
			if vsplit == null:
				continue
			var kids := vsplit.get_children()
			if kids.size() > 1 and kids[1] is RichTextLabel:
				_collect_panel(kids[1], "WARNING", path, errors)
			if kids.size() > 2 and kids[2] is RichTextLabel:
				_collect_panel(kids[2], "SCRIPT ERROR", path, errors)

	# 3. Fallback to the log file when no UI panels were reachable (headless).
	if errors.is_empty():
		for line in _scan_log_file(max_lines, ["ERROR", "SCRIPT ERROR"]):
			if not include_noise and _is_noise(line):
				suppressed += 1
			else:
				errors.append(line)

	var result := {"errors": errors, "count": errors.size()}
	if suppressed > 0:
		result["suppressed_noise"] = suppressed
	return success(result)


func _collect_panel(rtl: RichTextLabel, prefix: String, path: String, out: Array) -> void:
	var text := rtl.get_parsed_text().strip_edges()
	if text.is_empty():
		return
	for line in text.split("\n"):
		var s := line.strip_edges().trim_prefix("[Ignore]")
		if s.is_empty() or s == "[Ignore]":
			continue
		out.append("%s %s%s" % [prefix, (path + ": ") if not path.is_empty() else "", s])


func _log(params: Dictionary) -> Dictionary:
	var max_lines := optional_int(params, "max_lines", 100)
	var filter := optional_string(params, "filter", "")
	var rtl := _find_output_rtl()
	var lines: PackedStringArray
	var source := "output_panel"
	if rtl != null:
		lines = rtl.get_parsed_text().split("\n")
	else:
		lines = PackedStringArray(_read_log_lines())
		source = "log_file"
		if lines.is_empty():
			return error_internal("Output panel not found and no log file available")

	var start := maxi(0, lines.size() - max_lines)
	var out: Array = []
	for i in range(start, lines.size()):
		if filter.is_empty() or lines[i].contains(filter):
			out.append(lines[i])
	return success({"lines": out, "count": out.size(), "source": source})


func _clear_output(_params: Dictionary) -> Dictionary:
	print("\n".repeat(50))
	return success({"cleared": true})


# --- Screenshots ------------------------------------------------------------

func _screenshot(params: Dictionary) -> Dictionary:
	var base := EditorInterface.get_base_control()
	if base == null:
		return error_internal("Could not access editor base control")
	var viewport := base.get_viewport()
	var image := viewport.get_texture().get_image() if viewport else null
	if image == null or image.is_empty():
		return error(-32000, "Could not capture editor viewport", {
			"suggestion": "Editor screenshots require a windowed editor with a render surface; they are unavailable when Godot runs with --headless.",
		})
	return _emit_image(image, optional_string(params, "save_path", ""))


func _compare_screenshots(params: Dictionary) -> Dictionary:
	var ra := require_string(params, "image_a")
	if ra[1] != null:
		return ra[1]
	var rb := require_string(params, "image_b")
	if rb[1] != null:
		return rb[1]
	var la := _load_image(ra[0], "image_a")
	if la[1] != null:
		return la[1]
	var lb := _load_image(rb[0], "image_b")
	if lb[1] != null:
		return lb[1]
	var a: Image = la[0]
	var b: Image = lb[0]
	if a.get_size() != b.get_size():
		return error_invalid_params("Image sizes differ: %s vs %s" % [str(a.get_size()), str(b.get_size())])

	var threshold := optional_int(params, "threshold", 10)
	var w := a.get_width()
	var h := a.get_height()
	var changed := 0
	for y in h:
		for x in w:
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := maxi(absi(ca.r8 - cb.r8), maxi(absi(ca.g8 - cb.g8), absi(ca.b8 - cb.b8)))
			if d > threshold:
				changed += 1
	var total := w * h
	return success({
		"identical": changed == 0,
		"changed_pixels": changed,
		"total_pixels": total,
		"diff_percentage": snappedf(float(changed) / float(total) * 100.0, 0.01),
		"threshold": threshold,
		"width": w,
		"height": h,
	})


func _emit_image(image: Image, save_path: String) -> Dictionary:
	if not save_path.is_empty():
		var abs_path := ProjectSettings.globalize_path(save_path) if save_path.begins_with("res://") or save_path.begins_with("user://") else save_path
		var err := image.save_png(abs_path)
		if err != OK:
			return error_internal("Failed to save screenshot: %s" % error_string(err))
		return success({"saved_path": save_path, "width": image.get_width(), "height": image.get_height(), "format": "png"})
	var base64 := Marshalls.raw_to_base64(image.save_png_to_buffer())
	return success({"image_base64": base64, "width": image.get_width(), "height": image.get_height(), "format": "png"})


func _load_image(value: String, label: String) -> Array:
	var img := Image.new()
	if value.begins_with("res://") or value.begins_with("user://"):
		var err := img.load(value)
		if err != OK:
			return [null, error_invalid_params("Failed to load %s from '%s': %s" % [label, value, error_string(err)])]
		return [img, null]
	var err := img.load_png_from_buffer(Marshalls.base64_to_raw(value))
	if err != OK:
		return [null, error_invalid_params("Failed to decode %s from base64: %s" % [label, error_string(err)])]
	return [img, null]


# --- Run ad-hoc editor script ----------------------------------------------

func _run_script(params: Dictionary) -> Dictionary:
	# Accept either inline `code` or a `path` to a script file (res://, user://, or
	# an absolute OS path) — large scripts are awkward to pass inline via the shell.
	var code: String
	if params.has("path") and not String(params["path"]).strip_edges().is_empty():
		var loaded := _read_script_file(String(params["path"]))
		if loaded[1] != null:
			return loaded[1]
		code = loaded[0]
	else:
		var r := require_string(params, "code")
		if r[1] != null:
			return r[1]
		code = r[0]
	var guard := _guard_unsafe_io(code, optional_bool(params, "allow_unsafe_editor_io", false))
	if not guard.is_empty():
		return guard
	audit_exec("editor.run_script", code)

	var wrapped := "@tool\nextends Node\n\nvar output: Array = []\n\nfunc emit(value: Variant) -> void:\n\toutput.append(str(value))\n\nfunc run() -> void:\n%s\n" % _indent(code)
	var script := GDScript.new()
	script.source_code = wrapped
	if script.reload() != OK:
		return error(-32602, "Script compilation failed", {"wrapped_code": wrapped})

	var node := Node.new()
	node.set_script(script)
	add_child(node)
	if node.has_method("run"):
		node.run()
	var out: Variant = node.get("output")
	node.queue_free()
	return success({"output": out if out is Array else []})


func _guard_unsafe_io(code: String, allow: bool) -> Dictionary:
	if allow:
		return {}
	var compact := code.replace(" ", "").replace("\t", "").replace("\n", "")
	var hits: Array = []
	if compact.contains("ResourceSaver.save("):
		hits.append("ResourceSaver.save")
	if compact.contains("ProjectSettings.save("):
		hits.append("ProjectSettings.save")
	if compact.contains("ConfigFile.save("):
		hits.append("ConfigFile.save")
	if compact.contains("FileAccess.open(") and (compact.contains("FileAccess.WRITE") or compact.contains("FileAccess.READ_WRITE") or compact.contains("FileAccess.WRITE_READ")):
		hits.append("FileAccess write")
	for m in ["DirAccess.remove_absolute(", "DirAccess.rename_absolute(", "DirAccess.make_dir_absolute(", "DirAccess.make_dir_recursive_absolute("]:
		if compact.contains(m):
			hits.append("DirAccess mutation")
			break
	if hits.is_empty():
		return {}
	return error_conflict("Refusing to run editor script with direct file/resource write APIs", {
		"unsafe_patterns": hits,
		"suggestion": "Use the dedicated commands (scene.save, script.*), or pass allow_unsafe_editor_io=true if no open editor resource can be clobbered.",
	})


## Read a script file for run_script's `path` param. Accepts res://, user://, or
## an absolute OS path. Returns [code, error_or_null].
func _read_script_file(path: String) -> Array:
	var abs := ProjectSettings.globalize_path(path) if (path.begins_with("res://") or path.begins_with("user://")) else path
	if not FileAccess.file_exists(abs):
		return ["", error_invalid_params("Script file not found: %s" % path)]
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return ["", error_internal("Could not open script file: %s" % path)]
	var text := f.get_as_text()
	f.close()
	return [text, null]


func _indent(code: String) -> String:
	var out: PackedStringArray = []
	for line in code.split("\n"):
		out.append("\t" + line)
	return "\n".join(out)


# --- Reload, signals, camera ------------------------------------------------

func _reload(_params: Dictionary) -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	return success({"reloaded": true, "message": "Filesystem rescanned."})


func _reload_plugin(_params: Dictionary) -> Dictionary:
	# Reply first; the toggle drops and re-establishes the WebSocket connection.
	_deferred_reload.call_deferred()
	return success({"reloading": true, "message": "Plugin reloading; connection will briefly drop."})


func _deferred_reload() -> void:
	EditorInterface.set_plugin_enabled("godot_mcp", false)
	EditorInterface.set_plugin_enabled("godot_mcp", true)


func _signals(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var node := find_node_by_path(r[0])
	if node == null:
		return error_not_found("Node '%s'" % r[0])

	var signals: Array = []
	for sig in node.get_signal_list():
		var args: Array = []
		for arg in sig["args"]:
			args.append({"name": arg["name"], "type": arg["type"]})
		var connections: Array = []
		for conn in node.get_signal_connection_list(sig["name"]):
			var obj: Object = conn["callable"].get_object()
			connections.append({
				"target": str(root.get_path_to(obj)) if obj is Node else str(obj),
				"method": conn["callable"].get_method(),
			})
		signals.append({"name": sig["name"], "args": args, "connections": connections})
	return success({"node_path": str(root.get_path_to(node)), "type": node.get_class(), "signals": signals, "count": signals.size()})


func _get_camera(_params: Dictionary) -> Dictionary:
	var cam := _editor_camera_3d()
	if cam == null:
		return error(-32000, "No 3D editor camera found", {"suggestion": "Open a 3D scene in the editor first"})
	return success(_camera_state(cam))


func _set_camera(params: Dictionary) -> Dictionary:
	var cam := _editor_camera_3d()
	if cam == null:
		return error(-32000, "No 3D editor camera found", {"suggestion": "Open a 3D scene in the editor first"})
	if params.has("position"):
		cam.global_position = _to_vec3(params["position"], cam.global_position)
	if params.has("rotation_degrees"):
		cam.rotation_degrees = _to_vec3(params["rotation_degrees"], cam.rotation_degrees)
	if params.has("look_at"):
		cam.look_at(_to_vec3(params["look_at"], Vector3.ZERO))
	if params.has("fov"):
		cam.fov = float(params["fov"])
	return success(_camera_state(cam))


## Accept a Vector3 as either a {x,y,z} dict (missing keys keep `fallback`) or a
## "Vector3(x, y, z)" string — the CLI's standard form for vectors, parsed via
## PropertyParser. The earlier `var p: Dictionary = params[...]` cast threw on the
## string form, so set_camera silently no-op'd on the convention every other
## spatial command accepts.
func _to_vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Dictionary:
		return Vector3(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y)),
			float(value.get("z", fallback.z)))
	return PropertyParser.parse_value(value, TYPE_VECTOR3)


func _editor_camera_3d() -> Camera3D:
	var vp := EditorInterface.get_editor_viewport_3d()
	return vp.get_camera_3d() if vp else null


func _camera_state(cam: Camera3D) -> Dictionary:
	var pos := cam.global_position
	var rot := cam.rotation_degrees
	return {
		"position": {"x": pos.x, "y": pos.y, "z": pos.z},
		"rotation_degrees": {"x": rot.x, "y": rot.y, "z": rot.z},
		"fov": cam.fov, "near": cam.near, "far": cam.far,
	}


# --- Shared helpers ---------------------------------------------------------

func _find_output_rtl() -> RichTextLabel:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var output := base.find_child("Output", true, false)
	return _find_rtl(output) if output else null


func _find_rtl(node: Node, depth: int = 0) -> RichTextLabel:
	if depth > 6:
		return null
	if node is RichTextLabel:
		return node
	for child in node.get_children():
		var found := _find_rtl(child, depth + 1)
		if found:
			return found
	return null


func _read_log_lines() -> Array:
	var path := "user://logs/godot.log"
	if not FileAccess.file_exists(path):
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))


func _scan_log_file(max_lines: int, needles: Array) -> Array:
	var lines := _read_log_lines()
	var out: Array = []
	var start := maxi(0, lines.size() - max_lines)
	for i in range(start, lines.size()):
		for needle in needles:
			if lines[i].contains(needle):
				out.append(String(lines[i]).strip_edges())
				break
	return out


func get_command_docs() -> Dictionary:
	return {
		"editor.errors": {
			"description": "Return recent errors/warnings from the Output panel and the per-script analyzer panels (falls back to the log file when headless). Benign engine noise is filtered by default.",
			"params": [
				doc_param("max_lines", "int", false, "How many trailing output lines to scan (default 50)."),
				doc_param("include_noise", "bool", false, "Keep benign engine-internal lines that are filtered by default."),
			],
		},
		"editor.log": {
			"description": "Return the tail of the editor Output panel (or log file), optionally filtered to lines containing --filter.",
			"params": [
				doc_param("max_lines", "int", false, "Trailing lines to return (default 100)."),
				doc_param("filter", "String", false, "Only return lines containing this substring."),
			],
		},
		"editor.screenshot": {
			"description": "Capture the editor viewport to a PNG (base64, or saved to --save-path). Needs a windowed editor; fails under --headless.",
			"params": [
				doc_param("save_path", "String", false, "res://, user://, or absolute path to save the PNG; omit to return base64."),
			],
		},
		"editor.run_script": {
			"description": "Run ad-hoc @tool GDScript in the editor; use emit(value) to return output. Provide inline --code or a --path to a script file. Direct file/resource write APIs are refused unless --allow-unsafe-editor-io. Audited.",
			"params": [
				doc_param("code", "String", false, "Inline script body (its statements are wrapped in a run() function). Provide code OR path."),
				doc_param("path", "String", false, "res://, user://, or absolute path to a script file to run. Provide code OR path."),
				doc_param("allow_unsafe_editor_io", "bool", false, "Permit direct write APIs (ResourceSaver.save, FileAccess write, DirAccess mutations, ...)."),
			],
		},
		"editor.clear_output": {
			"description": "Clear the editor Output panel (scrolls it clean with blank lines).",
		},
		"editor.reload": {
			"description": "Rescan the project filesystem (EditorFileSystem.scan) so disk changes are picked up.",
		},
		"editor.reload_plugin": {
			"description": "Toggle this addon off and on to re-run command registration (the WebSocket connection briefly drops). Does NOT re-parse changed command scripts from disk — that needs a full editor restart.",
		},
		"editor.signals": {
			"description": "List a node's signals with their arguments and current connections (targets resolved to scene paths).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
			],
		},
		"editor.compare_screenshots": {
			"description": "Compare two images pixel-by-pixel, reporting changed-pixel count and percentage. Image sizes must match.",
			"params": [
				doc_param("image_a", "String", true, "First image: res:///user:// path or a base64 PNG."),
				doc_param("image_b", "String", true, "Second image: res:///user:// path or a base64 PNG."),
				doc_param("threshold", "int", false, "Per-channel 0-255 difference that counts a pixel as changed (default 10)."),
			],
		},
		"editor.get_camera": {
			"description": "Read the 3D editor viewport camera (position, rotation, fov, near, far). Needs an open 3D scene.",
		},
		"editor.set_camera": {
			"description": "Move the 3D editor viewport camera. Any of --position, --rotation-degrees, --look-at (a Vector3), or --fov.",
			"params": [
				doc_param("position", "Vector3", false, "New camera global position ({x,y,z} or 'Vector3(...)')."),
				doc_param("rotation_degrees", "Vector3", false, "New camera rotation in degrees."),
				doc_param("look_at", "Vector3", false, "Point to aim the camera at."),
				doc_param("fov", "float", false, "Field of view in degrees."),
			],
		},
		"editor.selection": {
			"description": "Return the editor's currently selected nodes as paths relative to the scene root (pairs with --node-path selected).",
		},
	}
