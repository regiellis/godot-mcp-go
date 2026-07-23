@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"animation.list": _list,
		"animation.create": _create,
		"animation.add_track": _add_track,
		"animation.set_keyframe": _set_keyframe,
		"animation.get_info": _get_info,
		"animation.remove": _remove,
	}


# --- Shared resolution ------------------------------------------------------

## Resolve params.node_path to an AnimationPlayer in the edited scene.
## Returns [player, null] or [null, error_dict].
func _resolve_player(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null:
		return [null, error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")]
	if not node is AnimationPlayer:
		return [null, error_invalid_params("Node '%s' is not an AnimationPlayer (is %s)" % [r[0], node.get_class()])]
	return [node as AnimationPlayer, null]


# --- Handlers ---------------------------------------------------------------

func _list(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var player: AnimationPlayer = ctx[0]

	var animations: Array = []
	for anim_name: StringName in player.get_animation_list():
		var anim := player.get_animation(anim_name)
		animations.append({
			"name": String(anim_name),
			"length": anim.length,
			"loop_mode": anim.loop_mode,
			"track_count": anim.get_track_count(),
		})
	return success({"node_path": params["node_path"], "animations": animations, "count": animations.size()})


func _create(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var player: AnimationPlayer = ctx[0]
	var anim_name: String = rn[0]

	var length := float(params.get("length", 1.0))
	var loop_mode := optional_int(params, "loop_mode", 0)  # 0=none, 1=linear, 2=pingpong

	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = loop_mode as Animation.LoopMode

	# Guard get_animation_library("") with has_animation_library(): calling get on a
	# player with no default library returns null AND logs an engine error
	# (animation_mixer.cpp). An empty library is the normal first-create state.
	var lib: AnimationLibrary = null
	if player.has_animation_library(""):
		lib = player.get_animation_library("")
	var created_library := false
	if lib == null:
		lib = AnimationLibrary.new()
		created_library = true
	elif lib.has_animation(anim_name):
		return error_invalid_params("Animation '%s' already exists" % anim_name)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Create animation %s" % anim_name)
	if created_library:
		undo_redo.add_do_method(player, "add_animation_library", "", lib)
		undo_redo.add_do_reference(lib)
		undo_redo.add_undo_method(player, "remove_animation_library", "")
	undo_redo.add_do_method(lib, "add_animation", anim_name, anim)
	undo_redo.add_do_reference(anim)
	undo_redo.add_undo_method(lib, "remove_animation", anim_name)
	undo_redo.commit_action()

	return success({"name": anim_name, "length": length, "created": true})


func _add_track(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var ra := require_string(params, "animation")
	if ra[1] != null:
		return ra[1]
	var rt := require_string(params, "track_path")
	if rt[1] != null:
		return rt[1]
	var player: AnimationPlayer = ctx[0]
	var anim_name: String = ra[0]
	var track_path: String = rt[0]

	var anim := player.get_animation(anim_name)
	if anim == null:
		return error_not_found("Animation '%s'" % anim_name)

	var track_type_str := optional_string(params, "track_type", "value")
	var track_type: int
	match track_type_str:
		"value": track_type = Animation.TYPE_VALUE
		"position_2d": track_type = Animation.TYPE_POSITION_3D  # Godot uses the 3D type for 2D too
		"rotation_2d": track_type = Animation.TYPE_ROTATION_3D
		"scale_2d": track_type = Animation.TYPE_SCALE_3D
		"method": track_type = Animation.TYPE_METHOD
		"bezier": track_type = Animation.TYPE_BEZIER
		"blend_shape": track_type = Animation.TYPE_BLEND_SHAPE
		_: track_type = Animation.TYPE_VALUE

	var track_idx := anim.get_track_count()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add animation track")
	undo_redo.add_do_method(anim, "add_track", track_type, track_idx)
	undo_redo.add_do_method(anim, "track_set_path", track_idx, NodePath(track_path))

	var update_mode_str := optional_string(params, "update_mode", "")
	if not update_mode_str.is_empty() and track_type == Animation.TYPE_VALUE:
		match update_mode_str:
			"continuous": undo_redo.add_do_method(anim, "value_track_set_update_mode", track_idx, Animation.UPDATE_CONTINUOUS)
			"discrete": undo_redo.add_do_method(anim, "value_track_set_update_mode", track_idx, Animation.UPDATE_DISCRETE)
			"capture": undo_redo.add_do_method(anim, "value_track_set_update_mode", track_idx, Animation.UPDATE_CAPTURE)
	undo_redo.add_undo_method(anim, "remove_track", track_idx)
	undo_redo.commit_action()

	return success({"track_index": track_idx, "track_path": track_path, "track_type": track_type_str})


func _set_keyframe(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var ra := require_string(params, "animation")
	if ra[1] != null:
		return ra[1]
	var player: AnimationPlayer = ctx[0]
	var anim_name: String = ra[0]

	var anim := player.get_animation(anim_name)
	if anim == null:
		return error_not_found("Animation '%s'" % anim_name)

	var track_index := optional_int(params, "track_index", 0)
	if track_index < 0 or track_index >= anim.get_track_count():
		return error_invalid_params("Invalid track_index: %d" % track_index)

	var time := float(params.get("time", 0.0))
	if not params.has("value"):
		return error_invalid_params("Missing required parameter: value")
	var value: Variant = _parse_keyframe_value(params["value"])
	var easing := float(params.get("easing", 1.0))

	var old_key_idx := _find_key_at_time(anim, track_index, time)
	var had_old_key := old_key_idx >= 0
	var old_value: Variant = anim.track_get_key_value(track_index, old_key_idx) if had_old_key else null
	var old_easing: float = anim.track_get_key_transition(track_index, old_key_idx) if had_old_key else 1.0

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set animation keyframe")
	undo_redo.add_do_method(self, "_upsert_key", anim, track_index, time, value, easing)
	undo_redo.add_undo_method(self, "_restore_key", anim, track_index, time, had_old_key, old_value, old_easing)
	undo_redo.commit_action()

	var key_idx := _find_key_at_time(anim, track_index, time)
	return success({
		"track_index": track_index,
		"time": time,
		"key_index": key_idx,
		"easing": anim.track_get_key_transition(track_index, key_idx),
	})


func _get_info(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var ra := require_string(params, "animation")
	if ra[1] != null:
		return ra[1]
	var player: AnimationPlayer = ctx[0]
	var anim_name: String = ra[0]

	var anim := player.get_animation(anim_name)
	if anim == null:
		return error_not_found("Animation '%s'" % anim_name)

	var tracks: Array = []
	for i in anim.get_track_count():
		var keys: Array = []
		for k in anim.track_get_key_count(i):
			keys.append({
				"time": anim.track_get_key_time(i, k),
				"value": PropertyParser.serialize_value(anim.track_get_key_value(i, k)),
				"easing": anim.track_get_key_transition(i, k),
			})
		tracks.append({
			"index": i,
			"path": str(anim.track_get_path(i)),
			"type": anim.track_get_type(i),
			"key_count": anim.track_get_key_count(i),
			"keys": keys,
		})

	return success({
		"name": anim_name,
		"length": anim.length,
		"loop_mode": anim.loop_mode,
		"step": anim.step,
		"tracks": tracks,
	})


func _remove(params: Dictionary) -> Dictionary:
	var ctx := _resolve_player(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var player: AnimationPlayer = ctx[0]
	var anim_name: String = rn[0]

	var lib: AnimationLibrary = null
	if player.has_animation_library(""):
		lib = player.get_animation_library("")
	if lib == null or not lib.has_animation(anim_name):
		return error_not_found("Animation '%s'" % anim_name)

	var anim := lib.get_animation(anim_name)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Remove animation %s" % anim_name)
	undo_redo.add_do_method(lib, "remove_animation", anim_name)
	undo_redo.add_undo_method(lib, "add_animation", anim_name, anim)
	undo_redo.add_undo_reference(anim)
	undo_redo.commit_action()
	return success({"name": anim_name, "removed": true})


# --- Keyframe helpers -------------------------------------------------------

func _parse_keyframe_value(value: Variant) -> Variant:
	if value is String:
		var expr := Expression.new()
		if expr.parse(value as String) == OK:
			var parsed: Variant = expr.execute()
			if not expr.has_execute_failed() and parsed != null:
				return parsed
	return value


func _find_key_at_time(anim: Animation, track_index: int, time: float) -> int:
	for key_index in anim.track_get_key_count(track_index):
		if is_equal_approx(anim.track_get_key_time(track_index, key_index), time):
			return key_index
	return -1


func _upsert_key(anim: Animation, track_index: int, time: float, value: Variant, easing: float) -> void:
	var key_idx := _find_key_at_time(anim, track_index, time)
	if key_idx < 0:
		key_idx = anim.track_insert_key(track_index, time, value)
	else:
		anim.track_set_key_value(track_index, key_idx, value)
	if easing != 1.0:
		anim.track_set_key_transition(track_index, key_idx, easing)


func _restore_key(anim: Animation, track_index: int, time: float, had_old_key: bool, old_value: Variant, old_easing: float) -> void:
	var key_idx := _find_key_at_time(anim, track_index, time)
	if had_old_key:
		if key_idx < 0:
			key_idx = anim.track_insert_key(track_index, time, old_value)
		else:
			anim.track_set_key_value(track_index, key_idx, old_value)
		anim.track_set_key_transition(track_index, key_idx, old_easing)
	elif key_idx >= 0:
		anim.track_remove_key(track_index, key_idx)


func get_command_docs() -> Dictionary:
	return {
		"animation.list": {
			"description": "List an AnimationPlayer's animations with length, loop_mode, and track count.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
			],
		},
		"animation.create": {
			"description": "Create a new empty Animation in the AnimationPlayer's default ('') library (creating the library if needed). Errors if the name already exists. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
				doc_param("name", "String", true, "New animation name."),
				doc_param("length", "float", false, "Animation length in seconds (default 1.0)."),
				doc_param("loop_mode", "int", false, "0 none (default), 1 linear, 2 ping-pong."),
			],
		},
		"animation.add_track": {
			"description": "Add a track to an animation and set its target path. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
				doc_param("animation", "String", true, "Animation to add the track to."),
				doc_param("track_path", "NodePath", true, "Track target as node:property (e.g. 'Sprite2D:position')."),
				doc_param("track_type", "String", false, "value (default), position_2d, rotation_2d, scale_2d, method, bezier, or blend_shape. (2D types use Godot's 3D transform track internally.)"),
				doc_param("update_mode", "String", false, "For value tracks: continuous, discrete, or capture."),
			],
		},
		"animation.set_keyframe": {
			"description": "Insert or update a keyframe at a time on a track (upsert by matching time). --value is Expression-parsed so Godot literals like 'Vector2(1,2)' work. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
				doc_param("animation", "String", true, "Animation to key."),
				doc_param("track_index", "int", false, "Track index to key (default 0)."),
				doc_param("time", "float", false, "Key time in seconds (default 0.0)."),
				doc_param("value", "JSON", true, "Key value (scalar, JSON, or a Godot literal string like 'Vector2(1,2)')."),
				doc_param("easing", "float", false, "Key transition/easing curve (default 1.0)."),
			],
		},
		"animation.get_info": {
			"description": "Read an animation's length, loop_mode, step, and full track/keyframe detail.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
				doc_param("animation", "String", true, "Animation to inspect."),
			],
		},
		"animation.remove": {
			"description": "Remove an animation from the AnimationPlayer's default ('') library. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationPlayer."),
				doc_param("name", "String", true, "Animation to remove."),
			],
		},
	}
