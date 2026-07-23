@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Project-wide static analysis: unused resources, signal flow, scene
## complexity, reference search, circular dependencies and overall statistics.
## These commands read files from disk and walk the edited scene tree.


func get_commands() -> Dictionary:
	return {
		"analysis.unused_resources": _unused_resources,
		"analysis.signal_flow": _signal_flow,
		"analysis.scene_complexity": _scene_complexity,
		"analysis.script_references": _script_references,
		"analysis.circular_dependencies": _circular_dependencies,
		"analysis.project_statistics": _project_statistics,
	}


const _RESOURCE_EXTENSIONS := ["tres", "tscn", "png", "jpg", "jpeg", "svg",
	"wav", "ogg", "mp3", "ttf", "otf", "gdshader", "material",
	"theme", "stylebox", "font", "anim"]
const _REFERENCING_EXTENSIONS := ["tscn", "gd", "tres", "cfg", "godot"]


func _unused_resources(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var include_addons := optional_bool(params, "include_addons", false)

	var all_resources: Array = []
	_collect_files_by_ext(path, _RESOURCE_EXTENSIONS, all_resources, include_addons)

	var ref_files: Array = []
	_collect_files_by_ext(path, _REFERENCING_EXTENSIONS, ref_files, include_addons)

	var referenced: Dictionary = {}
	for ref_file: String in ref_files:
		var content := _read_file_text(ref_file)
		if content.is_empty():
			continue
		var idx := 0
		while idx < content.length():
			var found := content.find("res://", idx)
			if found == -1:
				break
			var end := found + 6
			while end < content.length():
				var c := content[end]
				if c == '"' or c == "'" or c == ' ' or c == '\n' or c == '\r' or c == ')' or c == ']' or c == '}':
					break
				end += 1
			referenced[content.substr(found, end - found)] = true
			idx = end

	var unused: Array = []
	for res_path: String in all_resources:
		if not referenced.has(res_path):
			unused.append(res_path)

	return success({
		"unused_resources": unused,
		"unused_count": unused.size(),
		"total_resources_scanned": all_resources.size(),
		"total_files_checked": ref_files.size(),
	})


func _signal_flow(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()

	var nodes_data: Array = []
	_collect_signal_data(root, root, nodes_data)

	return success({
		"scene": root.scene_file_path,
		"nodes": nodes_data,
		"total_nodes": nodes_data.size(),
	})


func _collect_signal_data(node: Node, root: Node, out: Array) -> void:
	var node_path := str(root.get_path_to(node))
	var signals_emitted: Array = []
	var signals_connected_to: Array = []

	for sig: Dictionary in node.get_signal_list():
		var sig_name: String = sig["name"]
		var connections := node.get_signal_connection_list(sig_name)
		if connections.is_empty():
			continue
		var targets: Array = []
		for conn: Dictionary in connections:
			var callable: Callable = conn["callable"]
			var target_node := callable.get_object() as Node
			var target_path := str(root.get_path_to(target_node)) if target_node != null else ""
			targets.append({"target_node": target_path, "method": callable.get_method()})
			signals_connected_to.append({
				"from_node": node_path,
				"signal": sig_name,
				"method": callable.get_method(),
			})
		signals_emitted.append({"signal": sig_name, "targets": targets})

	if not signals_emitted.is_empty() or not signals_connected_to.is_empty():
		out.append({
			"name": String(node.name),
			"path": node_path,
			"type": node.get_class(),
			"signals_emitted": signals_emitted,
			"signals_connected_to": signals_connected_to,
		})

	for child in node.get_children():
		_collect_signal_data(child, root, out)


func _scene_complexity(params: Dictionary) -> Dictionary:
	var scene_path := optional_string(params, "path", "")

	var root: Node = null
	var owns_root := false
	if scene_path.is_empty():
		root = get_edited_root()
		if root == null:
			return error_no_scene()
		scene_path = root.scene_file_path
	else:
		if not ResourceLoader.exists(scene_path):
			return error_not_found("Scene '%s'" % scene_path)
		var packed := ResourceLoader.load(scene_path) as PackedScene
		if packed == null:
			return error_internal("Failed to load scene: %s" % scene_path)
		root = packed.instantiate()
		owns_root = true

	var types: Dictionary = {}
	var scripts_attached: Array = []
	var resources_used: Dictionary = {}
	_walk_complexity(root, root, types, scripts_attached, resources_used)

	var total_nodes := _count_nodes(root)
	var max_depth := _max_depth(root, 0)

	var issues: Array = []
	if total_nodes > 1000:
		issues.append({"severity": "warning", "message": "Scene has %d nodes (>1000). Consider splitting into sub-scenes." % total_nodes})
	elif total_nodes > 500:
		issues.append({"severity": "info", "message": "Scene has %d nodes (>500). Monitor performance." % total_nodes})

	if max_depth > 15:
		issues.append({"severity": "warning", "message": "Max nesting depth is %d (>15). Deep hierarchies can be hard to maintain." % max_depth})
	elif max_depth > 10:
		issues.append({"severity": "info", "message": "Max nesting depth is %d (>10)." % max_depth})

	if owns_root:
		root.queue_free()

	return success({
		"scene_path": scene_path,
		"total_nodes": total_nodes,
		"max_depth": max_depth,
		"nodes_by_type": types,
		"scripts_attached": scripts_attached,
		"unique_resource_count": resources_used.size(),
		"issues": issues,
	})


func _walk_complexity(node: Node, root: Node, types: Dictionary, scripts: Array, resources: Dictionary) -> void:
	var type_name := node.get_class()
	types[type_name] = types.get(type_name, 0) + 1

	var script := node.get_script() as Script
	if script != null and not script.resource_path.is_empty():
		scripts.append({"node": str(root.get_path_to(node)), "script": script.resource_path})

	# Count unique external resources referenced by this node's stored properties.
	for prop in node.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_STORAGE:
			var val: Variant = node.get(prop["name"])
			if val is Resource and not (val as Resource).resource_path.is_empty():
				resources[(val as Resource).resource_path] = true

	for child in node.get_children():
		_walk_complexity(child, root, types, scripts, resources)


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _max_depth(node: Node, current_depth: int) -> int:
	var max_d := current_depth
	for child in node.get_children():
		max_d = max(max_d, _max_depth(child, current_depth + 1))
	return max_d


func _script_references(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var query: String = r[0]

	var path := optional_string(params, "path", "res://")
	var include_addons := optional_bool(params, "include_addons", false)

	var search_files: Array = []
	_collect_files_by_ext(path, _REFERENCING_EXTENSIONS, search_files, include_addons)

	var references: Array = []
	for fp: String in search_files:
		var content := _read_file_text(fp)
		if content.is_empty():
			continue
		var line_num := 0
		for line in content.split("\n"):
			line_num += 1
			if (line as String).contains(query):
				references.append({"file": fp, "line": line_num, "content": (line as String).strip_edges()})

	return success({
		"query": query,
		"references": references,
		"reference_count": references.size(),
		"files_searched": search_files.size(),
	})


func _circular_dependencies(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var include_addons := optional_bool(params, "include_addons", false)

	var tscn_files: Array = []
	_collect_files_by_ext(path, ["tscn"], tscn_files, include_addons)

	var dep_graph: Dictionary = {}
	for tp: String in tscn_files:
		var content := _read_file_text(tp)
		if content.is_empty():
			dep_graph[tp] = []
			continue
		var deps: Array = []
		for line in content.split("\n"):
			var l: String = line
			if l.begins_with("[ext_resource") and ".tscn" in l:
				var path_start := l.find('path="')
				if path_start == -1:
					continue
				path_start += 6
				var path_end := l.find('"', path_start)
				if path_end == -1:
					continue
				var ref_path := l.substr(path_start, path_end - path_start)
				if ref_path.ends_with(".tscn"):
					deps.append(ref_path)
		dep_graph[tp] = deps

	var cycles: Array = []
	var visited: Dictionary = {}
	for scene: String in dep_graph:
		visited[scene] = "unvisited"
	for scene: String in dep_graph:
		if visited[scene] == "unvisited":
			_dfs_cycle(scene, dep_graph, visited, [], cycles)

	return success({
		"scenes_checked": tscn_files.size(),
		"circular_dependencies": cycles,
		"has_circular": not cycles.is_empty(),
		"dependency_graph": dep_graph,
	})


func _dfs_cycle(node: String, graph: Dictionary, visited: Dictionary, path_stack: Array, cycles: Array) -> void:
	visited[node] = "visiting"
	path_stack.append(node)

	if graph.has(node):
		for dep: String in graph[node]:
			if not visited.has(dep):
				continue
			if visited[dep] == "visiting":
				var cycle_start := path_stack.find(dep)
				var cycle: Array = path_stack.slice(cycle_start)
				cycle.append(dep)
				cycles.append(cycle)
			elif visited[dep] == "unvisited":
				_dfs_cycle(dep, graph, visited, path_stack, cycles)

	path_stack.pop_back()
	visited[node] = "visited"


func _project_statistics(params: Dictionary) -> Dictionary:
	var path := optional_string(params, "path", "res://")
	var include_addons := optional_bool(params, "include_addons", false)

	var file_counts: Dictionary = {}
	_collect_statistics(path, include_addons, file_counts)

	var total_script_lines := int(file_counts.get("_total_script_lines", 0))
	var scene_count := int(file_counts.get("_scene_count", 0))
	var resource_count := int(file_counts.get("_resource_count", 0))
	var total_files := int(file_counts.get("_total_files", 0))
	file_counts.erase("_total_script_lines")
	file_counts.erase("_scene_count")
	file_counts.erase("_resource_count")
	file_counts.erase("_total_files")

	var autoloads: Dictionary = {}
	for prop: Dictionary in ProjectSettings.get_property_list():
		var prop_name: String = prop["name"]
		if prop_name.begins_with("autoload/"):
			autoloads[prop_name.substr(9)] = str(ProjectSettings.get_setting(prop_name))

	var plugins: Array = []
	var addons_root := "res://addons"
	var enabled_plugins: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	var plugin_dir := DirAccess.open(addons_root)
	if plugin_dir != null:
		plugin_dir.list_dir_begin()
		var dir_name := plugin_dir.get_next()
		while not dir_name.is_empty():
			if plugin_dir.current_is_dir() and not dir_name.begins_with("."):
				var cfg_path := addons_root.path_join(dir_name).path_join("plugin.cfg")
				if FileAccess.file_exists(cfg_path):
					plugins.append({"name": dir_name, "enabled": cfg_path in enabled_plugins})
			dir_name = plugin_dir.get_next()
		plugin_dir.list_dir_end()

	return success({
		"file_counts_by_extension": file_counts,
		"total_files": total_files,
		"total_script_lines": total_script_lines,
		"scene_count": scene_count,
		"resource_count": resource_count,
		"autoloads": autoloads,
		"plugins": plugins,
	})


func _collect_statistics(path: String, include_addons: bool, file_counts: Dictionary) -> void:
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
			if file_name == "addons" and not include_addons:
				file_name = dir.get_next()
				continue
			_collect_statistics(full_path, include_addons, file_counts)
		else:
			var ext := file_name.get_extension().to_lower()
			file_counts[ext] = file_counts.get(ext, 0) + 1
			if ext == "gd":
				var content := _read_file_text(full_path)
				var line_count := content.count("\n") + 1 if not content.is_empty() else 0
				file_counts["_total_script_lines"] = file_counts.get("_total_script_lines", 0) + line_count
			if ext == "tscn":
				file_counts["_scene_count"] = file_counts.get("_scene_count", 0) + 1
			if ext in ["tres", "material", "theme", "stylebox", "font"]:
				file_counts["_resource_count"] = file_counts.get("_resource_count", 0) + 1
			file_counts["_total_files"] = file_counts.get("_total_files", 0) + 1
		file_name = dir.get_next()
	dir.list_dir_end()


func _collect_files_by_ext(path: String, extensions: Array, out: Array, include_addons: bool) -> void:
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
			if file_name == "addons" and not include_addons:
				file_name = dir.get_next()
				continue
			_collect_files_by_ext(full_path, extensions, out, include_addons)
		else:
			if file_name.get_extension().to_lower() in extensions:
				out.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()


func _read_file_text(file_path: String) -> String:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func get_command_docs() -> Dictionary:
	return {
		"analysis.unused_resources": {
			"description": "Find resource files under --path that no .tscn/.gd/.tres/.cfg/project file references by res:// path. Heuristic path-string scan; addons/ skipped unless --include-addons.",
			"params": [
				doc_param("path", "String", false, "Root to scan (default res://)."),
				doc_param("include_addons", "bool", false, "Include the addons/ folder (default false)."),
			],
		},
		"analysis.signal_flow": {
			"description": "Map signal connections in the edited scene: for each node, the signals it emits and their targets/methods. Reads the open scene.",
			"params": [],
		},
		"analysis.scene_complexity": {
			"description": "Report a scene's node count, max depth, nodes-by-type, attached scripts, unique-resource count, and complexity warnings. Uses --path or the edited scene.",
			"params": [
				doc_param("path", "String", false, "Scene to analyze; omit to use the currently edited scene."),
			],
		},
		"analysis.script_references": {
			"description": "Grep for a string across project text files (.tscn/.gd/.tres/.cfg/project), returning file/line/content for each match.",
			"params": [
				doc_param("query", "String", true, "Text to search for."),
				doc_param("path", "String", false, "Root to search (default res://)."),
				doc_param("include_addons", "bool", false, "Include the addons/ folder (default false)."),
			],
		},
		"analysis.circular_dependencies": {
			"description": "Build the .tscn-to-.tscn ext_resource dependency graph under --path and report any circular reference chains.",
			"params": [
				doc_param("path", "String", false, "Root to scan (default res://)."),
				doc_param("include_addons", "bool", false, "Include the addons/ folder (default false)."),
			],
		},
		"analysis.project_statistics": {
			"description": "Summarize the project: file counts by extension, total script lines, scene/resource counts, autoloads, and plugins.",
			"params": [
				doc_param("path", "String", false, "Root to scan (default res://)."),
				doc_param("include_addons", "bool", false, "Include the addons/ folder (default false)."),
			],
		},
	}
