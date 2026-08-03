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
		"node.call": _call_method,
	}


## Closest method name to `method`, for a did-you-mean on a miss. Empty below the
## similarity floor, so a wild guess suggests nothing rather than something absurd.
func _suggest_method(obj: Object, method: String) -> String:
	var best := ""
	var best_score := 0.6
	for m: Dictionary in obj.get_method_list():
		var name := String(m["name"])
		var score := method.similarity(name)
		if score > best_score:
			best_score = score
			best = name
	return best


## Call a method on a node in the edited scene.
##
## This closes the callable half of the design principle the property commands
## already serve: node.set/node.get reach anything the running binary exposes as a
## property, but a method needed editor.run_script — arbitrary code execution to
## invoke one named call. Several existing commands (lighting.bake, csg.bake,
## navigation.bake_mesh) are single-method wrappers that exist only because this
## did not.
##
## Audited, and deliberately NOT undoable: a call is not a property write, and
## UndoRedo cannot reverse arbitrary side effects. The result says so rather than
## letting a caller assume Ctrl+Z covers it.
func _call_method(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]

	var mr := require_string(params, "method")
	if mr[1] != null:
		return mr[1]
	var method: String = mr[0]

	if not node.has_method(method):
		var suggestion := _suggest_method(node, method)
		var hint := "Use engine class-info --class %s to list its methods." % node.get_class()
		if not suggestion.is_empty():
			hint = "Did you mean '%s'? %s" % [suggestion, hint]
		return error_not_found("Method '%s' on %s" % [method, node.get_class()], hint)

	var raw: Array = []
	if params.has("args"):
		var ar := require_array(params, "args")
		if ar[1] != null:
			return ar[1]
		raw = ar[0]

	var coerced := PropertyParser.coerce_call_args(
		PropertyParser.method_info(node, method), raw, method
	)
	if not coerced["ok"]:
		return error_invalid_params(String(coerced["reason"]))
	var args: Array = coerced["args"]

	audit_exec("node.call", "%s(%s).%s(%s)" % [node.name, node.get_class(), method, str(args)])
	var returned: Variant = node.callv(method, args)

	return success({
		"node_path": str(get_edited_root().get_path_to(node)),
		"method": method,
		"result": PropertyParser.serialize_value(returned),
		"undoable": false,
	})


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

	var pd := optional_dict(params, "properties")
	if pd[1] != null:
		node.free()
		return pd[1]
	var props := apply_initial_properties(node, pd[0])
	if not props["failures"].is_empty():
		node.free()  # never entered the tree, so drop it rather than leak an orphan
		return error_property_failures(props)

	# Seat it among its siblings when asked: sibling order is draw order in 2D, so
	# "insert a background behind existing content" is an index, not a reparent.
	var index := -1
	if params.has("index"):
		index = clampi(_wrap_index(optional_int(params, "index", -1), parent.get_child_count() + 1), 0, parent.get_child_count())

	add_child_with_undo(parent, node, root, "MCP: Add %s" % type, index)
	var out := {"node_path": str(root.get_path_to(node)), "type": type, "name": String(node.name), "index": node.get_index()}
	if not props["applied"].is_empty():
		out["properties_set"] = props["applied"]
	if not props["ignored"].is_empty():
		out["properties_ignored"] = props["ignored"]
	return success(out)


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


## Reparent a node, reorder it among its siblings, or both. Sibling order is draw
## order in 2D, so seating a node relative to its siblings is as common an edit as
## reparenting; `new_parent_path` is therefore optional when an ordering param is
## given. Ordering takes `index` (0-based, negative counts from the end) or
## `before`/`after` naming a sibling to seat against.
func _move(params: Dictionary) -> Dictionary:
	var ctx := _resolve_node(params)
	if ctx[1] != null:
		return ctx[1]
	var node: Node = ctx[0]
	var root := get_edited_root()
	if node == root:
		return error_invalid_params("Cannot move the root node")

	var old_parent := node.get_parent()
	var new_parent := old_parent
	var parent_path := optional_string(params, "new_parent_path", "")
	if not parent_path.is_empty():
		new_parent = find_node_by_path(parent_path)
		if new_parent == null:
			return error_not_found("Target parent '%s'" % parent_path, "Use scene.tree to see available nodes")
		if new_parent == node or node.is_ancestor_of(new_parent):
			return error_invalid_params("Cannot move a node into its own subtree")

	var reparenting := new_parent != old_parent
	var idx := _resolve_sibling_index(params, new_parent, node, reparenting)
	if idx[1] != null:
		return idx[1]
	var index: int = idx[0]
	if not reparenting and index < 0:
		return error_invalid_params("Nothing to move: pass 'new_parent_path' to reparent, or 'index'/'before'/'after' to reorder among siblings")

	var old_index := node.get_index()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Move %s" % node.name)
	if reparenting:
		undo_redo.add_do_method(old_parent, "remove_child", node)
		undo_redo.add_do_method(new_parent, "add_child", node)
		undo_redo.add_do_method(node, "set_owner", root)
	if index >= 0:
		undo_redo.add_do_method(new_parent, "move_child", node, index)
	if reparenting:
		undo_redo.add_undo_method(new_parent, "remove_child", node)
		undo_redo.add_undo_method(old_parent, "add_child", node)
		undo_redo.add_undo_method(node, "set_owner", root)
	undo_redo.add_undo_method(old_parent, "move_child", node, old_index)
	undo_redo.commit_action()
	NodeUtils.set_owner_recursive(node, root)
	return success({
		"node": String(node.name),
		"new_parent": str(root.get_path_to(new_parent)),
		"new_path": str(root.get_path_to(node)),
		"old_index": old_index,
		"index": node.get_index(),
	})


## Godot's negative-index convention: -1 is the last slot in a list of `count`.
func _wrap_index(index: int, count: int) -> int:
	return count + index if index < 0 else index


## Resolve the requested sibling position for `node` under `parent` into a final
## 0-based index for move_child, or -1 when no ordering param was passed.
## Returns [index, err].
func _resolve_sibling_index(params: Dictionary, parent: Node, node: Node, reparenting: bool) -> Array:
	# The count the parent will have once the move lands; an append puts the node
	# last, so this is what bounds every target index.
	var final_count := parent.get_child_count() + (1 if reparenting else 0)

	if params.has("index"):
		return [clampi(_wrap_index(optional_int(params, "index", 0), final_count), 0, final_count - 1), null]

	var relation := "before" if params.has("before") else ("after" if params.has("after") else "")
	if relation.is_empty():
		return [-1, null]

	var anchor_path := optional_string(params, relation, "")
	var anchor := find_node_by_path(anchor_path)
	if anchor == null:
		return [-1, error_not_found("Sibling '%s'" % anchor_path, "Use scene.tree to see available nodes")]
	if anchor == node:
		return [-1, error_invalid_params("Cannot seat '%s' relative to itself" % node.name)]
	if anchor.get_parent() != parent:
		return [-1, error_invalid_params("'%s' is not a child of '%s', so it can't anchor the new position" % [anchor.name, parent.name])]

	# move_child takes the index in the RESULTING order. When the node already sits
	# ahead of the anchor it vacates a slot on the way past, so everything at or
	# after the anchor shifts down by one and the target has to follow.
	var target := anchor.get_index() + (0 if relation == "before" else 1)
	if not reparenting and node.get_index() < target:
		target -= 1
	return [clampi(target, 0, final_count - 1), null]


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
	# @export node references resolve against the tree, not the type system, so they
	# must be handled before the strict parse (an Object property would otherwise
	# demand a res:// path).
	if raw is String:
		for prop in node.get_property_list():
			if prop["name"] == property and prop["hint"] == PROPERTY_HINT_NODE_TYPE:
				var target: Node = node.get_node_or_null(NodePath(raw))
				if target == null:
					target = root.get_node_or_null(NodePath(raw))
				if target == null:
					return [null, error_not_found("Node '%s'" % raw, "Could not resolve node reference for '%s'" % property)]
				return [target, null]

	# Coerce against the DECLARED type, not the current value's type, and refuse a
	# coercion that cannot be performed rather than writing a zeroed default.
	var decl := PropertyParser.declared_type(node, property)
	var target_type: int = int(decl["type"]) if decl["found"] else typeof(old_value)
	var res := PropertyParser.parse_checked(raw, target_type, String(decl["class_name"]))
	if not bool(res["ok"]):
		return [null, error_invalid_params("Cannot set '%s': %s" % [property, String(res["reason"])])]
	return [res["value"], null]


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

	# Atomic: refuse the whole call rather than assigning the resource with some
	# properties silently missing. --properties is an accepted alias: the map
	# rides beside the --property slot argument, so the longer canonical name
	# stays, but reaching for the sibling commands' flag should still land.
	var rpd := optional_dict(params, "resource_properties")
	if rpd[1] != null:
		return rpd[1]
	if (rpd[0] as Dictionary).is_empty() and params.has("properties"):
		rpd = optional_dict(params, "properties")
		if rpd[1] != null:
			return rpd[1]
	var props := apply_initial_properties(resource, rpd[0])
	if not props["failures"].is_empty():
		return error_property_failures(props)

	var old_value: Variant = node.get(property) if property in node else null
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add %s to %s" % [resource_type, node.name])
	undo_redo.add_do_property(node, property, resource)
	undo_redo.add_do_reference(resource)
	undo_redo.add_undo_property(node, property, old_value)
	undo_redo.commit_action()
	# Report what actually landed: a caller has no other way to read an embedded
	# sub-resource's properties back.
	return success({
		"node_path": str(get_edited_root().get_path_to(node)),
		"property": property,
		"resource_type": resource_type,
		"properties_set": props["applied"],
		"properties_ignored": props["ignored"],
	})


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
				doc_param("properties", "Dictionary", false, "Initial {property: value} map. Each value is coerced against the property's declared type and a res:// or uid:// path is loaded into the real resource; a coercion that can't be made errors instead of writing a default. Names the type lacks come back under properties_ignored."),
				doc_param("index", "int", false, "Seat the node at this sibling position instead of appending (0-based; negative counts from the end). Sibling order is draw order in 2D."),
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
			"description": "Reparent a node under --new-parent-path, reorder it among its siblings with --index/--before/--after, or both. Rejects moving into its own subtree. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Node to move."),
				doc_param("new_parent_path", "NodePath", false, "New parent, relative to the scene root. Omit to reorder in place, in which case one of --index/--before/--after is required."),
				doc_param("index", "int", false, "Final sibling position, 0-based; negative counts from the end (-1 is last). Sibling order is draw order in 2D."),
				doc_param("before", "NodePath", false, "Seat the node immediately before this sibling of the target parent."),
				doc_param("after", "NodePath", false, "Seat the node immediately after this sibling of the target parent."),
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
				doc_param("resource_properties", "Dictionary", false, "Initial values on the new resource (--properties is an accepted alias)."),
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
		"node.call": {
			"description": "Call a method on a node in the edited scene and return its result. The callable counterpart to node.set/node.get: anything the running build exposes as a method is reachable without editor.run_script. Arguments coerce toward the method's declared parameter types, so '\"Vector3(1,2,3)\"' arrives as a Vector3; list a class's methods with engine class-info. Audited. NOT undoable — a call is not a property write, so Ctrl+Z will not reverse its side effects.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target node."),
				doc_param("method", "String", true, "Method name; an unknown one errors with a did-you-mean."),
				doc_param("args", "JSON", false, "JSON array of positional arguments, e.g. '[\"Vector3(0,1,0)\", 2.5]'."),
			],
		},
	}
