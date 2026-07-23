@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Multi-step-authoring helpers (`authoring.*`) — safeguards that make scripted,
## re-run builds robust (ported from mcp-unreal's resolve/ensure/checkpoint tier):
##
## - `resolve`    — fuzzy name -> ranked node/scene/resource paths, flags ambiguity.
## - `ensure`     — idempotent get-or-create of a node by exact name (re-running a
##                  build script converges instead of spawning Node2/Node3/...).
## - `checkpoint` — capture / diff / restore a JSON snapshot of the scene's node
##                  identities + transforms (answers "what did my edits move?").
##
## A general tier, not a spatial appendix: pairs with the `spatial` group (resolve
## a fuzzy name -> anchor -> place -> verify) but applies across every workflow.

const _CHECKPOINT_DIR := "res://.godot/godot_mcp_checkpoints"
const _MOVE_EPSILON := 0.001


func get_commands() -> Dictionary:
	return {
		"authoring.resolve": _resolve,
		"authoring.ensure": _ensure,
		"authoring.checkpoint": _checkpoint,
	}


# --- shared helpers ---------------------------------------------------------

## Fuzzy score of `name` against `query`: exact (ci) = 1.0, substring boosted,
## else Sørensen-Dice bigram similarity.
func _score(query: String, name: String) -> float:
	var q := query.to_lower()
	var n := name.to_lower()
	if q == n:
		return 1.0
	var s := q.similarity(n)
	if n.contains(q):
		s = minf(1.0, maxf(s, 0.6) + 0.2)
	return s


func _all_nodes() -> Array:
	var out: Array = []
	var root := get_edited_root()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## Recursively list project files with one of `exts` (lowercase, no dot), skipping
## hidden dirs and addons/ (same convention as project.grep).
func _walk_files(exts: PackedStringArray) -> Array:
	var out: Array = []
	var stack: Array = ["res://"]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var f := da.get_next()
		while f != "":
			if da.current_is_dir():
				if not f.begins_with(".") and f != "addons":
					stack.append(d.path_join(f))
			elif f.get_extension().to_lower() in exts:
				out.append(d.path_join(f))
			f = da.get_next()
		da.list_dir_end()
	return out


# --- resolve ----------------------------------------------------------------

func _resolve(params: Dictionary) -> Dictionary:
	var rq := require_string(params, "query")
	if rq[1] != null:
		return rq[1]
	var query: String = rq[0]
	var kind := optional_string(params, "kind", "any").to_lower()
	var limit := optional_int(params, "limit", 10)

	var candidates: Array = []
	if kind in ["any", "node"] and get_edited_root() != null:
		var root := get_edited_root()
		for n: Node in _all_nodes():
			candidates.append({
				"kind": "node", "name": String(n.name),
				"path": str(root.get_path_to(n)), "type": n.get_class(),
				"score": _score(query, String(n.name)),
			})
	if kind in ["any", "scene"]:
		for p: String in _walk_files(PackedStringArray(["tscn", "scn"])):
			candidates.append({
				"kind": "scene", "name": p.get_file().get_basename(),
				"path": p, "score": _score(query, p.get_file().get_basename()),
			})
	if kind in ["any", "resource"]:
		for p: String in _walk_files(PackedStringArray(["tres", "res"])):
			candidates.append({
				"kind": "resource", "name": p.get_file().get_basename(),
				"path": p, "score": _score(query, p.get_file().get_basename()),
			})

	var ranked: Array = candidates.filter(func(c): return c["score"] >= 0.2)
	ranked.sort_custom(func(a, b): return a["score"] > b["score"])
	var top: Array = ranked.slice(0, maxi(1, limit))
	# ambiguous: the top two are real and too close to choose between.
	var ambiguous: bool = top.size() >= 2 and top[0]["score"] > 0.3 \
		and (top[0]["score"] - top[1]["score"]) < 0.08
	return success({
		"query": query, "kind": kind, "count": top.size(),
		"ambiguous": ambiguous, "candidates": top,
	})


# --- ensure -----------------------------------------------------------------

func _make_node(type: String) -> Node:
	if ClassDB.class_exists(type):
		if not ClassDB.is_parent_class(type, "Node"):
			return null
		return ClassDB.instantiate(type)
	var script := find_script_class(type)
	if script == null:
		return null
	var base := script.get_instance_base_type()
	if not ClassDB.is_parent_class(base, "Node"):
		return null
	var node: Node = ClassDB.instantiate(base)
	if node != null:
		node.set_script(script)
	return node


func _ensure(params: Dictionary) -> Dictionary:
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var node_name: String = rn[0]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", "."))
	if parent == null:
		return error_not_found("Parent node", "Use scene.tree to see available nodes")

	var existing := parent.get_node_or_null(NodePath(node_name))
	if existing != null:
		var requested := optional_string(params, "type", "")
		var out := {
			"created": false, "node_path": str(root.get_path_to(existing)),
			"type": existing.get_class(), "name": node_name,
		}
		if not requested.is_empty() and existing.get_class() != requested:
			out["type_mismatch"] = "exists as %s, requested %s" % [existing.get_class(), requested]
		return success(out)

	var rt := require_string(params, "type")
	if rt[1] != null:
		return rt[1]
	var type: String = rt[0]
	var node := _make_node(type)
	if node == null:
		return error_invalid_params("Unknown node type '%s' (not in ClassDB or a script class_name)" % type)
	node.name = node_name

	var properties: Dictionary = params.get("properties", {})
	for prop_name: String in properties:
		if prop_name in node:
			node.set(prop_name, PropertyParser.parse_value(properties[prop_name], typeof(node.get(prop_name))))

	add_child_with_undo(parent, node, root, "MCP: Ensure %s" % node_name)
	return success({
		"created": true, "node_path": str(root.get_path_to(node)),
		"type": type, "name": String(node.name),
	})


# --- checkpoint -------------------------------------------------------------

## A transform value to snapshot, as a var_to_str string, or "" if the node has
## no meaningful transform to track (Node3D/Node2D global_transform; Control rect).
func _xform_str(node: Node) -> String:
	if node is Node3D:
		return var_to_str((node as Node3D).global_transform)
	if node is Node2D:
		return var_to_str((node as Node2D).global_transform)
	if node is Control:
		return var_to_str((node as Control).get_global_rect())
	return ""


func _restore_xform(node: Node, t: String) -> bool:
	var v: Variant = str_to_var(t)
	if node is Node3D and v is Transform3D:
		get_undo_redo().add_do_property(node, "global_transform", v)
		get_undo_redo().add_undo_property(node, "global_transform", (node as Node3D).global_transform)
		return true
	if node is Node2D and v is Transform2D:
		get_undo_redo().add_do_property(node, "global_transform", v)
		get_undo_redo().add_undo_property(node, "global_transform", (node as Node2D).global_transform)
		return true
	if node is Control and v is Rect2:
		get_undo_redo().add_do_property(node, "global_position", (v as Rect2).position)
		get_undo_redo().add_undo_property(node, "global_position", (node as Control).global_position)
		return true
	return false


func _checkpoint_path(label: String) -> String:
	return _CHECKPOINT_DIR.path_join(label.validate_filename() + ".json")


func _checkpoint(params: Dictionary) -> Dictionary:
	var action := optional_string(params, "action", "")
	if action.is_empty():
		return error_invalid_params("Missing required parameter: action (capture|diff|restore|list)")
	var label := optional_string(params, "label", "default")

	match action:
		"list":
			var labels: Array = []
			var da := DirAccess.open(_CHECKPOINT_DIR)
			if da != null:
				for f in da.get_files():
					if f.get_extension() == "json":
						labels.append(f.get_basename())
			return success({"checkpoints": labels})

		"capture":
			if get_edited_root() == null:
				return error_no_scene()
			var root := get_edited_root()
			var nodes: Array = []
			for n: Node in _all_nodes():
				nodes.append({"path": str(root.get_path_to(n)), "type": n.get_class(), "t": _xform_str(n)})
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_CHECKPOINT_DIR))
			var file_path := _checkpoint_path(label)
			var fa := FileAccess.open(file_path, FileAccess.WRITE)
			if fa == null:
				return error_internal("Cannot write checkpoint: %s" % error_string(FileAccess.get_open_error()))
			fa.store_string(JSON.stringify({"label": label, "nodes": nodes}))
			fa.close()
			return success({"label": label, "node_count": nodes.size(), "file": file_path})

		"diff", "restore":
			var snap := _load_checkpoint(label)
			if snap[1] != null:
				return snap[1]
			var saved: Dictionary = snap[0]
			var root := get_edited_root()
			if root == null:
				return error_no_scene()
			# index current nodes
			var current := {}
			for n: Node in _all_nodes():
				current[str(root.get_path_to(n))] = n
			var saved_map := {}
			for entry: Dictionary in saved["nodes"]:
				saved_map[entry["path"]] = entry

			var removed: Array = []
			var moved: Array = []
			for path: String in saved_map:
				if not current.has(path):
					removed.append(path)
					continue
				var entry: Dictionary = saved_map[path]
				var t: String = entry["t"]
				if t != "" and _xform_str(current[path]) != t:
					moved.append(path)
			var added: Array = []
			for path: String in current:
				if not saved_map.has(path):
					added.append(path)

			if action == "diff":
				return success({"label": label, "added": added, "removed": removed, "moved": moved,
					"unchanged": current.size() - added.size() - moved.size()})

			# restore: re-apply saved transforms to nodes that still exist
			var dry := optional_bool(params, "dry_run", false)
			if dry:
				return success({"label": label, "would_restore": moved, "missing": removed, "dry_run": true})
			get_undo_redo().create_action("MCP: Restore checkpoint %s" % label)
			var restored: Array = []
			for path: String in moved:
				if _restore_xform(current[path], saved_map[path]["t"]):
					restored.append(path)
			get_undo_redo().commit_action()
			return success({"label": label, "restored": restored, "missing": removed})

		_:
			return error_invalid_params("Unknown action '%s' (capture|diff|restore|list)" % action)


func _load_checkpoint(label: String) -> Array:
	var path := _checkpoint_path(label)
	if not FileAccess.file_exists(path):
		return [null, error_not_found("Checkpoint '%s'" % label, "Use authoring.checkpoint --action list")]
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return [null, error_internal("Cannot read checkpoint: %s" % error_string(FileAccess.get_open_error()))]
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if not parsed is Dictionary or not (parsed as Dictionary).has("nodes"):
		return [null, error_internal("Checkpoint '%s' is malformed" % label)]
	return [parsed, null]


func get_command_docs() -> Dictionary:
	return {
		"authoring.resolve": {
			"description": "Fuzzy-match a name to ranked node/scene/resource paths (Sorensen-Dice + substring boost), flagging ambiguity when the top two are too close. The resolve step before place/verify.",
			"params": [
				doc_param("query", "String", true, "Name to resolve."),
				doc_param("kind", "String", false, "Restrict to any (default), node, scene, or resource."),
				doc_param("limit", "int", false, "Max candidates to return (default 10)."),
			],
		},
		"authoring.ensure": {
			"description": "Idempotent get-or-create of a node by exact name under --parent-path: returns the existing node (flagging a type mismatch) or creates it, so re-running a build script converges. --type is required only when creating. Undoable.",
			"params": [
				doc_param("name", "String", true, "Exact node name to ensure."),
				doc_param("parent_path", "NodePath", false, "Parent to look under / create in (default '.')."),
				doc_param("type", "String", false, "Node class or script class_name to create if absent (required only when creating)."),
				doc_param("properties", "Dictionary", false, "Initial {property: value} when creating."),
			],
		},
		"authoring.checkpoint": {
			"description": "Capture / diff / restore / list JSON snapshots of the scene's node identities + transforms (answers 'what did my edits move?'). restore re-applies saved transforms to still-present nodes.",
			"params": [
				doc_param("action", "String", true, "capture, diff, restore, or list."),
				doc_param("label", "String", false, "Checkpoint name (default 'default')."),
				doc_param("dry_run", "bool", false, "For restore: report what would change without applying (default false)."),
			],
		},
	}
