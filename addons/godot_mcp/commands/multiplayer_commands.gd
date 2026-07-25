@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## High-level multiplayer scaffolding — an entire subsystem with no prior coverage.
## MultiplayerSpawner (replicate spawned scenes) and MultiplayerSynchronizer (replicate node
## properties via a SceneReplicationConfig). The NodePaths these use (spawn_path, root_path, and
## per-property "Node:property" paths) are awkward to wire through node.set; this does it.
## Grounded on the live API (add_spawnable_scene / SceneReplicationConfig.property_set_*).


func get_commands() -> Dictionary:
	return {
		"multiplayer.add_spawner": _add_spawner,
		"multiplayer.add_synchronizer": _add_synchronizer,
		"multiplayer.add_sync_property": _add_sync_property,
		"multiplayer.info": _info,
	}


func _str_array(params: Dictionary, key: String) -> Array:
	if not params.has(key):
		return []
	var v: Variant = params[key]
	if v is String:
		var parsed: Variant = JSON.parse_string(v)
		if parsed is Array:
			return parsed
	if v is Array:
		return v
	return []


# --- add_spawner ------------------------------------------------------------

func _add_spawner(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var spawner := MultiplayerSpawner.new()
	spawner.name = optional_string(params, "name", "MultiplayerSpawner")
	if params.has("spawn_limit"):
		spawner.spawn_limit = optional_int(params, "spawn_limit", 0)

	var scenes := _str_array(params, "scenes")
	var added_scenes: Array = []
	var missing: Array = []
	for s: Variant in scenes:
		if ResourceLoader.exists(str(s)):
			spawner.add_spawnable_scene(str(s))
			added_scenes.append(str(s))
		else:
			missing.append(str(s))

	add_child_with_undo(parent, spawner, root, "MCP: Add MultiplayerSpawner")

	# spawn_path is relative to the spawner; resolve after it's in the tree.
	var spawn_path_str := ""
	if params.has("spawn_path"):
		var target := find_node_by_path(str(params["spawn_path"]))
		if target == null:
			return error_not_found("spawn_path node '%s'" % params["spawn_path"])
		var np: NodePath = spawner.get_path_to(target)
		spawner.spawn_path = np
		spawn_path_str = str(np)

	return success({
		"node_path": str(root.get_path_to(spawner)),
		"spawn_path": spawn_path_str,
		"spawnable_scenes": added_scenes,
		"missing_scenes": missing,
	})


# --- add_synchronizer -------------------------------------------------------

func _add_synchronizer(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var sync := MultiplayerSynchronizer.new()
	sync.name = optional_string(params, "name", "MultiplayerSynchronizer")
	if params.has("replication_interval"):
		sync.replication_interval = float(params["replication_interval"])
	if params.has("delta_interval"):
		sync.delta_interval = float(params["delta_interval"])

	var cfg := SceneReplicationConfig.new()
	var props := _str_array(params, "properties")
	var added: Array = []
	for p: Variant in props:
		var rec := _add_prop_to_config(cfg, p)
		added.append(rec)
	sync.replication_config = cfg

	add_child_with_undo(parent, sync, root, "MCP: Add MultiplayerSynchronizer")

	var root_path_str := ""
	if params.has("root"):
		var target := find_node_by_path(str(params["root"]))
		if target == null:
			return error_not_found("root node '%s'" % params["root"])
		var np: NodePath = sync.get_path_to(target)
		sync.root_path = np
		root_path_str = str(np)

	return success({
		"node_path": str(root.get_path_to(sync)),
		"root_path": root_path_str,
		"properties": added,
	})


## Accept a property as a string "Node:prop" (defaults spawn+sync) or an object
## {"path":..., "spawn":bool, "sync":bool, "watch":bool}.
func _add_prop_to_config(cfg: SceneReplicationConfig, p: Variant) -> Dictionary:
	var path_str := ""
	var spawn := true
	var sync := true
	var watch := false
	if p is String:
		path_str = p
	elif p is Dictionary:
		path_str = str(p.get("path", ""))
		spawn = bool(p.get("spawn", true))
		sync = bool(p.get("sync", true))
		watch = bool(p.get("watch", false))
	if path_str.is_empty():
		return {"error": "empty path"}
	var np := NodePath(path_str)
	if not cfg.has_property(np):
		cfg.add_property(np)
	cfg.property_set_spawn(np, spawn)
	cfg.property_set_sync(np, sync)
	cfg.property_set_watch(np, watch)
	return {"path": path_str, "spawn": spawn, "sync": sync, "watch": watch}


# --- add_sync_property ------------------------------------------------------

func _add_sync_property(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null or not node is MultiplayerSynchronizer:
		return error_invalid_params("node_path '%s' is not a MultiplayerSynchronizer" % rn[0])
	var sync := node as MultiplayerSynchronizer
	if sync.replication_config == null:
		sync.replication_config = SceneReplicationConfig.new()

	var rp := require_string(params, "property")
	if rp[1] != null:
		return rp[1]
	var rec := _add_prop_to_config(sync.replication_config, {
		"path": rp[0],
		"spawn": optional_bool(params, "spawn", true),
		"sync": optional_bool(params, "sync", true),
		"watch": optional_bool(params, "watch", false),
	})
	# Force the inspector/scene to register the config change.
	sync.replication_config.emit_changed()
	return success({"node_path": rn[0], "added": rec})


# --- info -------------------------------------------------------------------

func _info(params: Dictionary) -> Dictionary:
	if get_edited_root() == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])

	if node is MultiplayerSpawner:
		var sp := node as MultiplayerSpawner
		var scenes: Array = []
		for i in sp.get_spawnable_scene_count():
			scenes.append(sp.get_spawnable_scene(i))
		return success({"node_path": rn[0], "type": "MultiplayerSpawner", "spawn_path": str(sp.spawn_path), "spawn_limit": sp.spawn_limit, "spawnable_scenes": scenes})

	if node is MultiplayerSynchronizer:
		var sy := node as MultiplayerSynchronizer
		var props: Array = []
		if sy.replication_config != null:
			for np: NodePath in sy.replication_config.get_properties():
				props.append({
					"path": str(np),
					"spawn": sy.replication_config.property_get_spawn(np),
					"sync": sy.replication_config.property_get_sync(np),
					"watch": sy.replication_config.property_get_watch(np),
				})
		return success({"node_path": rn[0], "type": "MultiplayerSynchronizer", "root_path": str(sy.root_path), "replication_interval": sy.replication_interval, "properties": props})

	return error_invalid_params("Node '%s' (%s) is not a multiplayer node" % [rn[0], node.get_class()])


func get_command_docs() -> Dictionary:
	return {
		"multiplayer.add_spawner": {
			"description": "Add a MultiplayerSpawner that replicates spawned scenes. Registers each --scenes path as a spawnable scene (missing paths reported, not fatal) and wires --spawn-path. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.', the root). --parent is an alias."),
				doc_param("name", "String", false, "Node name (default 'MultiplayerSpawner')."),
				doc_param("spawn_limit", "int", false, "Max concurrent spawns (0 = unlimited)."),
				doc_param("scenes", "Array", false, "List of scene paths to register as spawnable (JSON array of res:// paths)."),
				doc_param("spawn_path", "NodePath", false, "Node whose children the spawner replicates (stored relative to the spawner)."),
			],
		},
		"multiplayer.add_synchronizer": {
			"description": "Add a MultiplayerSynchronizer with a SceneReplicationConfig built from --properties. Undoable.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.'). --parent is an alias."),
				doc_param("name", "String", false, "Node name (default 'MultiplayerSynchronizer')."),
				doc_param("replication_interval", "float", false, "Seconds between full sync updates."),
				doc_param("delta_interval", "float", false, "Seconds between delta sync updates."),
				doc_param("properties", "Array", false, "Replicated properties: JSON array of 'Node:property' strings, or objects {path, spawn, sync, watch} (spawn/sync default true, watch false)."),
				doc_param("root", "NodePath", false, "Node the synchronizer's paths are relative to (sets root_path, stored relative to the synchronizer)."),
			],
		},
		"multiplayer.add_sync_property": {
			"description": "Add one replicated property to an existing MultiplayerSynchronizer's config. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MultiplayerSynchronizer."),
				doc_param("property", "String", true, "Property path in 'Node:property' form (e.g. '.:position')."),
				doc_param("spawn", "bool", false, "Replicate on spawn (default true)."),
				doc_param("sync", "bool", false, "Replicate on sync (default true)."),
				doc_param("watch", "bool", false, "Watch for changes / delta-replicate (default false)."),
			],
		},
		"multiplayer.info": {
			"description": "Report a MultiplayerSpawner's spawnable scenes/spawn_path/limit, or a MultiplayerSynchronizer's root_path/interval/replicated properties.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target MultiplayerSpawner or MultiplayerSynchronizer."),
			],
		},
	}
