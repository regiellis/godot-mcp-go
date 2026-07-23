@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

const NodeUtils := preload("res://addons/godot_mcp/utils/node_utils.gd")


func get_commands() -> Dictionary:
	return {
		"node.add": _add,
		"node.delete": _delete,
		"node.rename": _rename,
		"node.duplicate": _duplicate,
		"node.move": _move,
		"node.set": _set_property,
		"node.get": _get_properties,
		"node.add_resource": _add_resource,
		"node.set_anchor": _set_anchor,
		"node.connect": _connect_signal,
		"node.disconnect": _disconnect_signal,
		"node.get_groups": _get_groups,
		"node.set_groups": _set_groups,
		"node.find_in_group": _find_in_group,
		"node.set_meta": _set_meta,
		"node.get_meta": _get_meta,
	}


func _find_script_by_class_name(name: String) -> Script:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == name:
			var path: String = entry.get("path", "")
			if not path.is_empty():
				return load(path) as Script
	return null


func _add(params: Dictionary) -> Dictionary:
	var r := require_string(params, "type")
	if r[1] != null:
		return r[1]
	var type: String = r[0]

	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	# Accept `parent` as an alias for `parent_path`: a silently-ignored `--parent`
	# (vs `--parent-path`) otherwise drops the node at the scene root with no error.
	var parent_path := optional_string(params, "parent_path", optional_string(params, "parent", "."))
	var parent := find_node_by_path(parent_path)
	if parent == null:
		return error_not_found("Parent node", "Use scene.tree to see available nodes")

	var node: Node
	if ClassDB.class_exists(type):
		node = ClassDB.instantiate(type)
	else:
		var script := _find_script_by_class_name(type)
		if script == null:
			return error_invalid_params("Unknown node type '%s' (not in ClassDB or a script class_name)" % type)
		var base_type := script.get_instance_base_type()
		if not ClassDB.class_exists(base_type):
			return error_invalid_params("Script '%s' extends invalid type '%s'" % [type, base_type])
		node = ClassDB.instantiate(base_type)
		node.set_script(script)

	var node_name := optional_string(params, "name", "")
	if not node_name.is_empty():
		node.name = node_name

	var properties: Dictionary = params.get("properties", {})
	for prop_name: String in properties:
		if prop_name in node:
			node.set(prop_name, PropertyParser.parse_value(properties[prop_name], typeof(node.get(prop_name))))

	add_child_with_undo(parent, node, root, "MCP: Add %s" % type)
	return success({"node_path": str(root.get_path_to(node)), "type": type, "name": String(node.name)})


func _delete(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var root := get_edited_root()
	if node == root:
		return error_invalid_params("Cannot delete the root node")

	var parent := node.get_parent()
	var node_name := String(node.name)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Delete %s" % node_name)
	undo_redo.add_do_method(parent, "remove_child", node)
	undo_redo.add_undo_method(parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", root)
	undo_redo.add_undo_reference(node)
	undo_redo.commit_action()
	return success({"deleted": node_name})


func _rename(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var r := require_string(params, "new_name")
	if r[1] != null:
		return r[1]
	var node: Node = ctx[0]
	var old_name := String(node.name)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Rename %s" % old_name)
	undo_redo.add_do_property(node, "name", r[0])
	undo_redo.add_undo_property(node, "name", old_name)
	undo_redo.commit_action()
	return success({"old_name": old_name, "new_name": String(node.name), "node_path": str(get_edited_root().get_path_to(node))})


func _duplicate(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var root := get_edited_root()
	var new_name := optional_string(params, "name", "")
	if new_name.is_empty():
		new_name = String(node.name) + "_copy"
	var dup := node.duplicate()
	dup.name = new_name
	add_child_with_undo(node.get_parent(), dup, root, "MCP: Duplicate %s" % node.name)
	NodeUtils.set_owner_recursive(dup, root)
	return success({"original": str(root.get_path_to(node)), "duplicate": str(root.get_path_to(dup)), "name": String(dup.name)})


func _move(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var r := require_string(params, "new_parent_path")
	if r[1] != null:
		return r[1]
	var node: Node = ctx[0]
	var root := get_edited_root()
	if node == root:
		return error_invalid_params("Cannot move the root node")
	var new_parent := find_node_by_path(r[0])
	if new_parent == null:
		return error_not_found("Target parent '%s'" % r[0], "Use scene.tree to see available nodes")
	if new_parent == node or node.is_ancestor_of(new_parent):
		return error_invalid_params("Cannot move a node into its own subtree")

	var old_parent := node.get_parent()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Move %s" % node.name)
	undo_redo.add_do_method(old_parent, "remove_child", node)
	undo_redo.add_do_method(new_parent, "add_child", node)
	undo_redo.add_do_method(node, "set_owner", root)
	undo_redo.add_undo_method(new_parent, "remove_child", node)
	undo_redo.add_undo_method(old_parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", root)
	undo_redo.commit_action()
	NodeUtils.set_owner_recursive(node, root)
	return success({"node": String(node.name), "new_parent": str(root.get_path_to(new_parent)), "new_path": str(root.get_path_to(node))})


func _set_property(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var root := get_edited_root()

	# Two forms: a `properties` dict (batch, mirrors node.add) OR singular `property`+`value`.
	var to_set := {}
	if params.has("properties"):
		if not params["properties"] is Dictionary or (params["properties"] as Dictionary).is_empty():
			return error_invalid_params("'properties' must be a non-empty object")
		to_set = params["properties"]
	else:
		var r := require_string(params, "property")
		if r[1] != null:
			return r[1]
		if not params.has("value"):
			return error_invalid_params("Missing required parameter: value (or pass a 'properties' object)")
		to_set = {r[0]: params["value"]}

	# Validate every property up front so a bad name fails the whole batch (no partial writes).
	for property: String in to_set:
		if not property in node:
			var available: Array = []
			for prop in node.get_property_list():
				if prop["usage"] & PROPERTY_USAGE_EDITOR:
					available.append(prop["name"])
			return error_not_found("Property '%s' on %s" % [property, node.get_class()], "Available: %s" % str(available.slice(0, 20)))

	var label: String = str(to_set.keys()[0]) if to_set.size() == 1 else "%d properties" % to_set.size()
	# Resolve every value BEFORE opening the undo action: a mid-loop resolution
	# failure must not leave a dangling uncommitted action on the UndoRedo manager.
	var resolved := {}
	var old_values := {}
	for property: String in to_set:
		var old_value: Variant = node.get(property)
		var parsed := _resolve_prop_value(node, root, property, to_set[property], old_value)
		if parsed[1] != null:
			return parsed[1]
		old_values[property] = PropertyParser.serialize_value(old_value)
		resolved[property] = parsed[0]
	set_properties_with_undo(node, resolved, "MCP: Set %s on %s" % [label, node.name])

	var new_values := {}
	for property: String in to_set:
		new_values[property] = PropertyParser.serialize_value(node.get(property))

	var out := {"node": str(root.get_path_to(node)), "properties": new_values}
	if to_set.size() == 1: # preserve the original single-set response shape for back-compat
		var only: String = str(to_set.keys()[0])
		out["property"] = only
		out["old_value"] = old_values[only]
		out["new_value"] = new_values[only]
	return success(out)


## Parse a raw param value for `property` on `node`, resolving @export node-path
## references (PROPERTY_HINT_NODE_TYPE) to the actual Node. Returns [value, err].
func _resolve_prop_value(node: Node, root: Node, property: String, raw: Variant, old_value: Variant) -> Array:
	var parsed: Variant = PropertyParser.parse_value(raw, typeof(old_value))
	if raw is String:
		for prop in node.get_property_list():
			if prop["name"] == property and prop["hint"] == PROPERTY_HINT_NODE_TYPE:
				var target: Node = node.get_node_or_null(NodePath(raw))
				if target == null:
					target = root.get_node_or_null(NodePath(raw))
				if target == null:
					return [null, error_not_found("Node '%s'" % raw, "Could not resolve node reference for '%s'" % property)]
				return [target, null]
	return [parsed, null]


func _get_properties(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var base := {"node_path": str(get_edited_root().get_path_to(node)), "type": node.get_class()}

	# Explicit `properties` list: fetch exactly those by name (any property, not
	# just the editor-visible set), `script` as its resource path. Names that don't
	# resolve are reported under `missing` instead of being silently dropped.
	if params.has("properties") and params["properties"] is Array:
		var picked: Dictionary = {}
		var missing: Array = []
		for entry in params["properties"]:
			var key := String(entry)
			if key == "script":
				var scr: Script = node.get_script()
				picked["script"] = scr.resource_path if scr != null else null
			elif key in node:
				picked[key] = PropertyParser.serialize_value(node.get(key))
			else:
				missing.append(key)
		base["properties"] = picked
		if not missing.is_empty():
			base["missing"] = missing
		return success(base)

	var props := NodeUtils.get_node_properties_dict(node)
	var category := optional_string(params, "category", "")
	if not category.is_empty():
		var filtered: Dictionary = {}
		for key: String in props:
			if key.begins_with(category):
				filtered[key] = props[key]
		props = filtered
	base["properties"] = props
	return success(base)


func _add_resource(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var rp := require_string(params, "property")
	if rp[1] != null:
		return rp[1]
	var rt := require_string(params, "resource_type")
	if rt[1] != null:
		return rt[1]
	var node: Node = ctx[0]
	var property: String = rp[0]
	var resource_type: String = rt[0]

	var resource: Resource = make_resource(resource_type)
	if resource == null:
		return error_invalid_params("'%s' is not a valid Resource type (a ClassDB class or a class_name Resource script)" % resource_type)

	var resource_props: Dictionary = params.get("resource_properties", {})
	for prop_name: String in resource_props:
		if prop_name in resource:
			resource.set(prop_name, PropertyParser.parse_value(resource_props[prop_name], typeof(resource.get(prop_name))))

	var old_value: Variant = node.get(property) if property in node else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add %s to %s" % [resource_type, node.name])
	undo_redo.add_do_property(node, property, resource)
	undo_redo.add_do_reference(resource)
	undo_redo.add_undo_property(node, property, old_value)
	undo_redo.commit_action()
	return success({"node_path": str(get_edited_root().get_path_to(node)), "property": property, "resource_type": resource_type})


const _ANCHOR_PRESETS := {
	"top_left": Control.PRESET_TOP_LEFT, "top_right": Control.PRESET_TOP_RIGHT,
	"bottom_left": Control.PRESET_BOTTOM_LEFT, "bottom_right": Control.PRESET_BOTTOM_RIGHT,
	"center_left": Control.PRESET_CENTER_LEFT, "center_top": Control.PRESET_CENTER_TOP,
	"center_right": Control.PRESET_CENTER_RIGHT, "center_bottom": Control.PRESET_CENTER_BOTTOM,
	"center": Control.PRESET_CENTER, "left_wide": Control.PRESET_LEFT_WIDE,
	"top_wide": Control.PRESET_TOP_WIDE, "right_wide": Control.PRESET_RIGHT_WIDE,
	"bottom_wide": Control.PRESET_BOTTOM_WIDE, "vcenter_wide": Control.PRESET_VCENTER_WIDE,
	"hcenter_wide": Control.PRESET_HCENTER_WIDE, "full_rect": Control.PRESET_FULL_RECT,
}

func _set_anchor(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var r := require_string(params, "preset")
	if r[1] != null:
		return r[1]
	var node: Node = ctx[0]
	if not node is Control:
		return error_invalid_params("Node is not a Control (is %s)" % node.get_class())
	var preset_name: String = r[0]
	if not _ANCHOR_PRESETS.has(preset_name):
		return error_invalid_params("Unknown preset '%s'. Available: %s" % [preset_name, _ANCHOR_PRESETS.keys()])
	var control: Control = node
	var keep := optional_bool(params, "keep_offsets", false)

	var props := ["anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
		"offset_left", "offset_top", "offset_right", "offset_bottom"]
	var old_values := {}
	for p: String in props:
		old_values[p] = control.get(p)

	var target := control.duplicate() as Control
	target.set_anchors_and_offsets_preset(_ANCHOR_PRESETS[preset_name],
		Control.PRESET_MODE_KEEP_SIZE if keep else Control.PRESET_MODE_MINSIZE)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set anchor preset on %s" % node.name)
	for p: String in props:
		undo_redo.add_do_property(control, p, target.get(p))
		undo_redo.add_undo_property(control, p, old_values[p])
	target.free()
	undo_redo.commit_action()
	return success({"node_path": str(get_edited_root().get_path_to(control)), "preset": preset_name})


func _connect_signal(params: Dictionary) -> Dictionary:
	var pair := _signal_pair(params)
	if pair[2] != null:
		return pair[2]
	var source: Node = pair[0]
	var target: Node = pair[1]
	var signal_name := optional_string(params, "signal_name")
	var method_name := optional_string(params, "method_name")
	if not source.has_signal(signal_name):
		return error_invalid_params("Signal '%s' not found on %s" % [signal_name, source.get_class()])
	var callable := Callable(target, method_name)
	if source.is_connected(signal_name, callable):
		return success({"already_connected": true, "signal": signal_name})
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Connect signal")
	undo_redo.add_do_method(source, "connect", signal_name, callable)
	undo_redo.add_undo_method(source, "disconnect", signal_name, callable)
	undo_redo.commit_action()
	return success({"signal": signal_name, "method": method_name, "connected": true})


func _disconnect_signal(params: Dictionary) -> Dictionary:
	var pair := _signal_pair(params)
	if pair[2] != null:
		return pair[2]
	var source: Node = pair[0]
	var target: Node = pair[1]
	var signal_name := optional_string(params, "signal_name")
	var method_name := optional_string(params, "method_name")
	var callable := Callable(target, method_name)
	if not source.is_connected(signal_name, callable):
		return success({"was_connected": false})
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Disconnect signal")
	undo_redo.add_do_method(source, "disconnect", signal_name, callable)
	undo_redo.add_undo_method(source, "connect", signal_name, callable)
	undo_redo.commit_action()
	return success({"signal": signal_name, "method": method_name, "disconnected": true})


func _get_groups(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var groups: Array = []
	for group: StringName in node.get_groups():
		var g := String(group)
		if not g.begins_with("_"):
			groups.append(g)
	return success({"node_path": str(get_edited_root().get_path_to(node)), "groups": groups, "count": groups.size()})


func _set_groups(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	if not params.has("groups") or not params["groups"] is Array:
		return error_invalid_params("'groups' array is required")
	var node: Node = ctx[0]
	var desired: Array = params["groups"]
	var current: Array = []
	for group: StringName in node.get_groups():
		var g := String(group)
		if not g.begins_with("_"):
			current.append(g)

	var added: Array = []
	var removed: Array = []
	for g: String in current:
		if g not in desired:
			removed.append(g)
	for g in desired:
		if String(g) not in current:
			added.append(String(g))

	if not added.is_empty() or not removed.is_empty():
		var undo_redo := get_undo_redo()
		undo_redo.create_action("MCP: Set node groups")
		for g: String in removed:
			undo_redo.add_do_method(node, "remove_from_group", g)
			undo_redo.add_undo_method(node, "add_to_group", g, true)
		for g: String in added:
			undo_redo.add_do_method(node, "add_to_group", g, true)
			undo_redo.add_undo_method(node, "remove_from_group", g)
		undo_redo.commit_action()
	return success({"node_path": str(get_edited_root().get_path_to(node)), "groups": desired, "added": added, "removed": removed})


func _find_in_group(params: Dictionary) -> Dictionary:
	var r := require_string(params, "group")
	if r[1] != null:
		return r[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var matches: Array = []
	_collect_in_group(root, root, r[0], matches)
	return success({"group": r[0], "nodes": matches, "count": matches.size()})


func _collect_in_group(node: Node, root: Node, group: String, matches: Array) -> void:
	if node.is_in_group(group):
		matches.append({"name": String(node.name), "path": str(root.get_path_to(node)), "type": node.get_class()})
	for child in node.get_children():
		_collect_in_group(child, root, group, matches)


# --- Shared resolution ------------------------------------------------------

## Resolve params.node_path against the edited scene. Returns [node, null] or
## [null, error_dict].
func _resolve_node(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null:
		return [null, error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")]
	return [node, null]


## Resolve source_path + target_path. Returns [source, target, null] or [..., error].
func _signal_pair(params: Dictionary) -> Array:
	var sp := require_string(params, "source_path")
	if sp[1] != null:
		return [null, null, sp[1]]
	var tp := require_string(params, "target_path")
	if tp[1] != null:
		return [null, null, tp[1]]
	if require_string(params, "signal_name")[1] != null:
		return [null, null, error_invalid_params("Missing required parameter: signal_name")]
	if require_string(params, "method_name")[1] != null:
		return [null, null, error_invalid_params("Missing required parameter: method_name")]
	if get_edited_root() == null:
		return [null, null, error_no_scene()]
	var source := find_node_by_path(sp[0])
	if source == null:
		return [null, null, error_not_found("Source node '%s'" % sp[0])]
	var target := find_node_by_path(tp[0])
	if target == null:
		return [null, null, error_not_found("Target node '%s'" % tp[0])]
	return [source, target, null]


## Set arbitrary node metadata (node.set_meta) — the general-purpose store that
## node.set (properties only) can't reach; drives many Godot patterns and our own
## doc.note. Undoable; --value is auto-parsed (JSON / Godot literal / scalar).
func _set_meta(params: Dictionary) -> Dictionary:
	var nr := resolve_node_param(params)
	if nr[1] != null:
		return nr[1]
	var node: Node = nr[0]
	var kr := require_string(params, "key")
	if kr[1] != null:
		return kr[1]
	var key: String = kr[0]
	if not params.has("value"):
		return error_invalid_params("Missing required parameter: value")
	var new_value: Variant = PropertyParser.parse_value(params["value"], TYPE_NIL)
	var had := node.has_meta(key)
	var old_value: Variant = node.get_meta(key) if had else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Set metadata '%s' on %s" % [key, node.name])
	undo_redo.add_do_method(node, "set_meta", key, new_value)
	if had:
		undo_redo.add_undo_method(node, "set_meta", key, old_value)
	else:
		undo_redo.add_undo_method(node, "remove_meta", key)
	undo_redo.commit_action()
	return success({
		"path": params.get("node_path"), "key": key,
		"value": PropertyParser.serialize_value(new_value), "created": not had,
	})


## Read node metadata (node.get_meta). With --key, returns that value; without,
## returns every metadata key on the node.
func _get_meta(params: Dictionary) -> Dictionary:
	var nr := resolve_node_param(params)
	if nr[1] != null:
		return nr[1]
	var node: Node = nr[0]
	var key := optional_string(params, "key")
	if key.is_empty():
		var all := {}
		for k in node.get_meta_list():
			all[k] = PropertyParser.serialize_value(node.get_meta(k))
		return success({"path": params.get("node_path"), "meta": all})
	if not node.has_meta(key):
		return error_not_found("Metadata key '%s'" % key, "Call node.get_meta without --key to list all keys")
	return success({
		"path": params.get("node_path"), "key": key,
		"value": PropertyParser.serialize_value(node.get_meta(key)),
	})


func get_command_docs() -> Dictionary:
	return {
		"node.add": {
			"description": "Instantiate a node of --type (a ClassDB class or a registered script class_name) under --parent-path and add it to the edited scene. Undoable.",
			"params": [
				doc_param("type", "String", true, "Node class (e.g. 'Sprite2D') or a global script class_name."),
				doc_param("parent_path", "NodePath", false, "Parent to add under, relative to the scene root (default '.', the root). --parent is an accepted alias."),
				doc_param("name", "String", false, "Name for the new node (defaults to the type name)."),
				doc_param("properties", "Dictionary", false, "Initial {property: value} map, each value coerced toward the property's type."),
			],
		},
		"node.delete": {
			"description": "Delete a node and its subtree from the edited scene (refuses the root node). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to delete, relative to the scene root; 'selected' uses the editor selection."),
			],
		},
		"node.rename": {
			"description": "Rename a node. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to rename."),
				doc_param("new_name", "String", true, "The new node name."),
			],
		},
		"node.duplicate": {
			"description": "Duplicate a node and its subtree under the same parent. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to duplicate."),
				doc_param("name", "String", false, "Name for the copy (defaults to '<name>_copy')."),
			],
		},
		"node.move": {
			"description": "Reparent a node under --new-parent-path (rejects moving into its own subtree). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to move."),
				doc_param("new_parent_path", "NodePath", true, "New parent, relative to the scene root."),
			],
		},
		"node.set": {
			"description": "Set node properties. Two forms: singular --property + --value, OR a batch --properties object; the batch validates all names up front and writes atomically in one undo action.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("property", "String", false, "Property name (singular form; pair with --value). Omit when using --properties."),
				doc_param("value", "JSON", false, "Value for --property (scalar, Godot literal string, or JSON), coerced toward the property's type; an @export node-path property resolves a path to the node. Required with --property."),
				doc_param("properties", "Dictionary", false, "Batch form: {property: value}, written atomically. Use instead of --property/--value."),
			],
		},
		"node.get": {
			"description": "Read a node's properties. With --properties (a name list) fetch exactly those (any property, plus 'script' as its path); otherwise the editor-visible set, optionally narrowed by --category prefix.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("properties", "Array", false, "Explicit list of property names to fetch; names that don't resolve come back under 'missing'."),
				doc_param("category", "String", false, "Prefix filter over the default property set (e.g. 'transform')."),
			],
		},
		"node.add_resource": {
			"description": "Create a Resource of --resource-type and assign it to the node's --property (a shape, material, curve, ...). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("property", "String", true, "Property to assign the new resource to."),
				doc_param("resource_type", "String", true, "Resource class (ClassDB) or a class_name Resource script."),
				doc_param("resource_properties", "Dictionary", false, "Initial values on the new resource."),
			],
		},
		"node.set_anchor": {
			"description": "Apply a Control anchor+offset preset (top_left, center, full_rect, ...) to a Control node. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target Control node."),
				doc_param("preset", "String", true, "One of: top_left, top_right, bottom_left, bottom_right, center_left, center_top, center_right, center_bottom, center, left_wide, top_wide, right_wide, bottom_wide, vcenter_wide, hcenter_wide, full_rect."),
				doc_param("keep_offsets", "bool", false, "Keep current size (PRESET_MODE_KEEP_SIZE) instead of the min-size default."),
			],
		},
		"node.connect": {
			"description": "Connect --source-path's --signal-name to --target-path's --method-name. Undoable; a no-op if already connected.",
			"params": [
				doc_param("source_path", "NodePath", true, "Node emitting the signal."),
				doc_param("target_path", "NodePath", true, "Node receiving the call."),
				doc_param("signal_name", "String", true, "Signal on the source node."),
				doc_param("method_name", "String", true, "Method on the target node."),
			],
		},
		"node.disconnect": {
			"description": "Disconnect a previously connected signal (same four params as node.connect). Undoable.",
			"params": [
				doc_param("source_path", "NodePath", true, "Node emitting the signal."),
				doc_param("target_path", "NodePath", true, "Node receiving the call."),
				doc_param("signal_name", "String", true, "Signal on the source node."),
				doc_param("method_name", "String", true, "Method on the target node."),
			],
		},
		"node.get_groups": {
			"description": "List the scene groups a node belongs to (internal '_' groups omitted).",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
			],
		},
		"node.set_groups": {
			"description": "Set a node's group membership to exactly --groups, adding/removing to match. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("groups", "Array", true, "The desired group names (the node ends up in exactly these)."),
			],
		},
		"node.find_in_group": {
			"description": "Find every node in the edited scene that belongs to --group.",
			"params": [
				doc_param("group", "String", true, "Group name to search for."),
			],
		},
		"node.set_meta": {
			"description": "Set arbitrary node metadata (--key to --value) — the general store node.set can't reach. --value is auto-parsed (JSON / Godot literal / scalar). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("key", "String", true, "Metadata key."),
				doc_param("value", "JSON", true, "Metadata value (auto-parsed)."),
			],
		},
		"node.get_meta": {
			"description": "Read node metadata. With --key returns that value; without, lists every metadata key on the node.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("key", "String", false, "Metadata key to read; omit to list all keys."),
			],
		},
	}
