@tool
extends RefCounted

const PropertyParser := preload("res://addons/godot_mcp/utils/property_parser.gd")

## Reparent owners so a code-added/duplicated/moved subtree is saved with the
## scene. Each child becomes owned by `owner`, but recursion STOPS at instanced
## sub-scenes (nodes with a scene_file_path): their internals belong to the
## instance, and re-owning them would flatten the instance into duplicated local
## nodes that clash on reload.
static func set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		if child.scene_file_path.is_empty():
			set_owner_recursive(child, owner)


## Build a serializable tree for a subtree. `path` is relative to `root` (".",
## "Player", "UI/Score") so it can be passed straight back as a node_path.
## When root is null, node is treated as the root.
static func get_node_tree(node: Node, root: Node = null, max_depth: int = -1, depth: int = 0) -> Dictionary:
	if root == null:
		root = node
	var result := {
		"name": String(node.name),
		"type": node.get_class(),
		"path": "." if node == root else str(root.get_path_to(node)),
	}
	var script: Script = node.get_script()
	if script != null:
		result["script"] = script.resource_path
	if max_depth == -1 or depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(get_node_tree(child, root, max_depth, depth + 1))
		if not children.is_empty():
			result["children"] = children
	return result


## Editor-visible properties of a node as a JSON-safe dictionary.
static func get_node_properties_dict(node: Node) -> Dictionary:
	var result: Dictionary = {}
	for prop_info in node.get_property_list():
		var prop_name: String = prop_info["name"]
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name.begins_with("_"):
			continue
		if prop_name == "script":
			# Report the script as its resource path (the raw value is a Script
			# object). Skipping it entirely hid attached scripts from node.get.
			var scr: Script = node.get_script()
			result["script"] = scr.resource_path if scr != null else null
			continue
		result[prop_name] = PropertyParser.serialize_value(node.get(prop_name))
	return result
