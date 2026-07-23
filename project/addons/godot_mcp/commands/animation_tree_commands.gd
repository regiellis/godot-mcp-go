@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"anim_tree.create": _create,
		"anim_tree.get_structure": _get_structure,
		"anim_tree.add_state": _add_state,
		"anim_tree.remove_state": _remove_state,
		"anim_tree.add_transition": _add_transition,
		"anim_tree.remove_transition": _remove_transition,
		"anim_tree.set_blend_tree_node": _set_blend_tree_node,
		"anim_tree.set_blend_point": _set_blend_point,
		"anim_tree.remove_blend_point": _remove_blend_point,
		"anim_tree.set_parameter": _set_parameter,
	}


# --- Resolution helpers -----------------------------------------------------

## Resolve params.node_path to an AnimationTree. Returns [tree, null] or [null, error].
func _resolve_tree(params: Dictionary) -> Array:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return [null, r[1]]
	if get_edited_root() == null:
		return [null, error_no_scene()]
	var node := find_node_by_path(r[0])
	if node == null:
		return [null, error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")]
	if not node is AnimationTree:
		return [null, error_invalid_params("Node '%s' is not an AnimationTree (is %s)" % [r[0], node.get_class()])]
	return [node as AnimationTree, null]


## Navigate to a nested state machine by slash-separated path (e.g. "Run/SubState").
## Returns [state_machine, error_or_null].
func _resolve_state_machine(tree: AnimationTree, sm_path: String) -> Array:
	var root := tree.tree_root
	if not root is AnimationNodeStateMachine:
		return [null, error_invalid_params("AnimationTree root is not an AnimationNodeStateMachine")]

	var current := root as AnimationNodeStateMachine
	if sm_path.is_empty() or sm_path == ".":
		return [current, null]

	for part in sm_path.split("/"):
		if not current.has_node(StringName(part)):
			return [null, error_not_found("State machine node '%s' in path '%s'" % [part, sm_path])]
		var child := current.get_node(StringName(part))
		if not child is AnimationNodeStateMachine:
			return [null, error_invalid_params("Node '%s' is not a StateMachine" % part)]
		current = child as AnimationNodeStateMachine
	return [current, null]


## Resolve a BlendTree named bt_name inside the state machine at sm_path.
## Returns [blend_tree, error_or_null].
func _resolve_blend_tree(tree: AnimationTree, sm_path: String, bt_name: String) -> Array:
	var sm_result := _resolve_state_machine(tree, sm_path)
	if sm_result[1] != null:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result[0]
	if not sm.has_node(StringName(bt_name)):
		return [null, error_not_found("BlendTree node '%s'" % bt_name)]
	var node := sm.get_node(StringName(bt_name))
	if not node is AnimationNodeBlendTree:
		return [null, error_invalid_params("Node '%s' is not an AnimationNodeBlendTree" % bt_name)]
	return [node as AnimationNodeBlendTree, null]


## Resolve the blend space these params target: the tree root when
## params.blend_space_state is empty, else a state of that name in the state
## machine at params.state_machine_path. Returns [blend_space, error_or_null].
func _resolve_blend_space(tree: AnimationTree, params: Dictionary) -> Array:
	var state := optional_string(params, "blend_space_state", "")
	if state.is_empty() or state == ".":
		var root := tree.tree_root
		if root is AnimationNodeBlendSpace1D or root is AnimationNodeBlendSpace2D:
			return [root, null]
		var root_class := root.get_class() if root != null else "null"
		return [null, error_invalid_params("AnimationTree root is not a blend space (is %s). Create with --root-type blend_space_2d, or pass --blend-space-state to target a nested blend-space state." % root_class)]

	var sm_result := _resolve_state_machine(tree, optional_string(params, "state_machine_path", ""))
	if sm_result[1] != null:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result[0]
	if not sm.has_node(StringName(state)):
		return [null, error_not_found("Blend-space state '%s'" % state)]
	var node := sm.get_node(StringName(state))
	if node is AnimationNodeBlendSpace1D or node is AnimationNodeBlendSpace2D:
		return [node, null]
	return [null, error_invalid_params("State '%s' is not a blend space (is %s)" % [state, node.get_class()])]


## Build a configured blend space. kind is "1d" or "2d". Reads optional
## min_space/max_space/snap (float for 1d, Vector2 for 2d), sync, labels, and
## (2d) auto_triangles from params, leaving the engine defaults otherwise.
func _build_blend_space(params: Dictionary, kind: String) -> AnimationNode:
	if kind == "1d":
		var bs := AnimationNodeBlendSpace1D.new()
		if params.has("min_space"): bs.min_space = float(params["min_space"])
		if params.has("max_space"): bs.max_space = float(params["max_space"])
		if params.has("snap"): bs.snap = float(params["snap"])
		bs.sync = optional_bool(params, "sync", bs.sync)
		var vl := optional_string(params, "value_label", "")
		if not vl.is_empty(): bs.value_label = vl
		return bs
	var bs2 := AnimationNodeBlendSpace2D.new()
	if params.has("min_space"): bs2.min_space = vec2_param(params, "min_space", bs2.min_space)
	if params.has("max_space"): bs2.max_space = vec2_param(params, "max_space", bs2.max_space)
	if params.has("snap"): bs2.snap = vec2_param(params, "snap", bs2.snap)
	bs2.sync = optional_bool(params, "sync", bs2.sync)
	bs2.auto_triangles = optional_bool(params, "auto_triangles", bs2.auto_triangles)
	var xl := optional_string(params, "x_label", "")
	if not xl.is_empty(): bs2.x_label = xl
	var yl := optional_string(params, "y_label", "")
	if not yl.is_empty(): bs2.y_label = yl
	return bs2


# --- Handlers ---------------------------------------------------------------

func _create(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(r[0])
	if parent == null:
		return error_not_found("Node '%s'" % r[0], "Use scene.tree to see available nodes")

	var anim_player_path := optional_string(params, "anim_player", "")
	var tree_name := optional_string(params, "name", "AnimationTree")
	var root_type := optional_string(params, "root_type", "state_machine")

	var root_node: AnimationNode
	match root_type:
		"state_machine": root_node = AnimationNodeStateMachine.new()
		"blend_space_1d": root_node = _build_blend_space(params, "1d")
		"blend_space_2d": root_node = _build_blend_space(params, "2d")
		"blend_tree": root_node = AnimationNodeBlendTree.new()
		_:
			return error_invalid_params("Unknown root_type: '%s'. Use 'state_machine', 'blend_space_1d', 'blend_space_2d', or 'blend_tree'" % root_type)

	var tree := AnimationTree.new()
	tree.name = tree_name
	tree.tree_root = root_node
	if not anim_player_path.is_empty():
		tree.anim_player = NodePath(anim_player_path)

	add_child_with_undo(parent, tree, root, "MCP: Create AnimationTree")

	return success({
		"name": String(tree.name),
		"node_path": str(root.get_path_to(tree)),
		"root_type": root_node.get_class(),
		"anim_player": anim_player_path,
		"created": true,
	})


func _get_structure(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var tree: AnimationTree = ctx[0]

	var root := tree.tree_root
	if root == null:
		return success({"node_path": params["node_path"], "root": null})

	var structure := _read_node_structure(root)
	structure["active"] = tree.active
	structure["anim_player"] = str(tree.anim_player)
	structure["node_path"] = params["node_path"]
	return success(structure)


func _read_node_structure(node: AnimationNode) -> Dictionary:
	if node is AnimationNodeStateMachine:
		return _read_state_machine_structure(node as AnimationNodeStateMachine)
	elif node is AnimationNodeBlendTree:
		return _read_blend_tree_structure(node as AnimationNodeBlendTree)
	elif node is AnimationNodeBlendSpace1D:
		return _read_blend_space_structure(node, 1)
	elif node is AnimationNodeBlendSpace2D:
		return _read_blend_space_structure(node, 2)
	elif node is AnimationNodeAnimation:
		return {"type": "AnimationNodeAnimation", "animation": str((node as AnimationNodeAnimation).animation)}
	return {"type": node.get_class()}


func _read_blend_space_structure(bs, dims: int) -> Dictionary:
	var points: Array = []
	for i in bs.get_blend_point_count():
		var child: AnimationNode = bs.get_blend_point_node(i)
		var pos: Variant = bs.get_blend_point_position(i)
		var pinfo := {"index": i}
		pinfo["pos"] = pos if dims == 1 else {"x": pos.x, "y": pos.y}
		if child is AnimationNodeAnimation:
			pinfo["animation"] = str((child as AnimationNodeAnimation).animation)
		else:
			pinfo["node_type"] = child.get_class()
		points.append(pinfo)

	var info := {"type": bs.get_class(), "sync": bs.sync, "blend_points": points}
	if dims == 1:
		info["min_space"] = bs.min_space
		info["max_space"] = bs.max_space
	else:
		info["min_space"] = {"x": bs.min_space.x, "y": bs.min_space.y}
		info["max_space"] = {"x": bs.max_space.x, "y": bs.max_space.y}
		info["auto_triangles"] = bs.auto_triangles
	return info


func _read_state_machine_structure(sm: AnimationNodeStateMachine) -> Dictionary:
	var states: Array = []
	for state_name in _state_machine_node_names(sm):
		var child := sm.get_node(StringName(state_name))
		var pos := sm.get_node_position(StringName(state_name))
		var state_info := {
			"name": state_name,
			"position": {"x": pos.x, "y": pos.y},
		}
		state_info.merge(_read_node_structure(child))
		states.append(state_info)

	var transitions: Array = []
	for i in sm.get_transition_count():
		var trans := sm.get_transition(i)
		var trans_info := {
			"from": str(sm.get_transition_from(i)),
			"to": str(sm.get_transition_to(i)),
			"switch_mode": trans.switch_mode,
			"advance_mode": trans.advance_mode,
		}
		if not trans.advance_expression.is_empty():
			trans_info["advance_expression"] = trans.advance_expression
		if trans.advance_mode == AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO:
			trans_info["auto"] = true
		transitions.append(trans_info)

	return {
		"type": "AnimationNodeStateMachine",
		"states": states,
		"transitions": transitions,
	}


## State machines have no public node-list accessor, so derive names from the
## serialized "states/<name>/node" property keys (excluding Start/End).
func _state_machine_node_names(sm: AnimationNodeStateMachine) -> Array:
	var names: Array = []
	for prop in sm.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("states/") and pname.ends_with("/node"):
			var state_name := pname.get_slice("/", 1)
			if state_name != "Start" and state_name != "End":
				names.append(state_name)
	return names


func _read_blend_tree_structure(bt: AnimationNodeBlendTree) -> Dictionary:
	var nodes_info: Array = []
	for prop in bt.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("nodes/") and pname.ends_with("/node"):
			var n := pname.get_slice("/", 1)
			if n == "output":
				continue
			var child := bt.get_node(StringName(n))
			var pos := bt.get_node_position(StringName(n))
			var node_info := {
				"name": n,
				"type": child.get_class(),
				"position": {"x": pos.x, "y": pos.y},
			}
			if child is AnimationNodeAnimation:
				node_info["animation"] = str((child as AnimationNodeAnimation).animation)
			nodes_info.append(node_info)

	return {
		"type": "AnimationNodeBlendTree",
		"nodes": nodes_info,
	}


func _add_state(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "state_name")
	if rn[1] != null:
		return rn[1]
	var tree: AnimationTree = ctx[0]
	var state_name: String = rn[0]

	var sm_result := _resolve_state_machine(tree, optional_string(params, "state_machine_path", ""))
	if sm_result[1] != null:
		return sm_result[1]
	var sm: AnimationNodeStateMachine = sm_result[0]

	if sm.has_node(StringName(state_name)):
		return error_invalid_params("State '%s' already exists" % state_name)

	var state_type := optional_string(params, "state_type", "animation")
	var position := Vector2(float(params.get("position_x", 0.0)), float(params.get("position_y", 0.0)))

	var node: AnimationNode
	match state_type:
		"animation":
			var anim_node := AnimationNodeAnimation.new()
			var anim_name := optional_string(params, "animation", "")
			if not anim_name.is_empty():
				anim_node.animation = StringName(anim_name)
			node = anim_node
		"blend_tree":
			node = AnimationNodeBlendTree.new()
		"state_machine":
			node = AnimationNodeStateMachine.new()
		"blend_space_1d":
			node = _build_blend_space(params, "1d")
		"blend_space_2d":
			node = _build_blend_space(params, "2d")
		_:
			return error_invalid_params("Unknown state_type: '%s'. Use 'animation', 'blend_tree', 'state_machine', 'blend_space_1d', or 'blend_space_2d'" % state_type)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add state machine state")
	undo_redo.add_do_method(sm, "add_node", StringName(state_name), node, position)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(sm, "remove_node", StringName(state_name))
	undo_redo.commit_action()

	return success({
		"state_name": state_name,
		"state_type": state_type,
		"position": {"x": position.x, "y": position.y},
		"added": true,
	})


func _remove_state(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rn := require_string(params, "state_name")
	if rn[1] != null:
		return rn[1]
	var tree: AnimationTree = ctx[0]
	var state_name: String = rn[0]

	var sm_result := _resolve_state_machine(tree, optional_string(params, "state_machine_path", ""))
	if sm_result[1] != null:
		return sm_result[1]
	var sm: AnimationNodeStateMachine = sm_result[0]

	if not sm.has_node(StringName(state_name)):
		return error_not_found("State '%s'" % state_name)

	var old_node := sm.get_node(StringName(state_name))
	var old_position := sm.get_node_position(StringName(state_name))
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Remove state machine state")
	undo_redo.add_do_method(sm, "remove_node", StringName(state_name))
	undo_redo.add_undo_method(sm, "add_node", StringName(state_name), old_node, old_position)
	undo_redo.add_undo_reference(old_node)
	undo_redo.commit_action()

	return success({"state_name": state_name, "removed": true})


func _add_transition(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rf := require_string(params, "from_state")
	if rf[1] != null:
		return rf[1]
	var rto := require_string(params, "to_state")
	if rto[1] != null:
		return rto[1]
	var tree: AnimationTree = ctx[0]
	var from_state: String = rf[0]
	var to_state: String = rto[0]

	var sm_result := _resolve_state_machine(tree, optional_string(params, "state_machine_path", ""))
	if sm_result[1] != null:
		return sm_result[1]
	var sm: AnimationNodeStateMachine = sm_result[0]

	# Start and End are built-in pseudo-states and need no existence check.
	if from_state != "Start" and from_state != "End" and not sm.has_node(StringName(from_state)):
		return error_not_found("State '%s'" % from_state)
	if to_state != "Start" and to_state != "End" and not sm.has_node(StringName(to_state)):
		return error_not_found("State '%s'" % to_state)

	var transition := AnimationNodeStateMachineTransition.new()

	var switch_mode_str := optional_string(params, "switch_mode", "immediate")
	match switch_mode_str:
		"at_end": transition.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		"immediate": transition.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		"sync": transition.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
		_: transition.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE

	var advance_mode_str := optional_string(params, "advance_mode", "enabled")
	match advance_mode_str:
		"disabled": transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED
		"enabled": transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
		"auto": transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		_: transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED

	var expression := optional_string(params, "advance_expression", "")
	if not expression.is_empty():
		transition.advance_expression = expression

	if params.has("xfade_time"):
		transition.xfade_time = float(params["xfade_time"])

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add state machine transition")
	undo_redo.add_do_method(sm, "add_transition", StringName(from_state), StringName(to_state), transition)
	undo_redo.add_do_reference(transition)
	undo_redo.add_undo_method(sm, "remove_transition", StringName(from_state), StringName(to_state))
	undo_redo.commit_action()

	return success({
		"from": from_state,
		"to": to_state,
		"switch_mode": switch_mode_str,
		"advance_mode": advance_mode_str,
		"advance_expression": expression,
		"added": true,
	})


func _remove_transition(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rf := require_string(params, "from_state")
	if rf[1] != null:
		return rf[1]
	var rto := require_string(params, "to_state")
	if rto[1] != null:
		return rto[1]
	var tree: AnimationTree = ctx[0]
	var from_state: String = rf[0]
	var to_state: String = rto[0]

	var sm_result := _resolve_state_machine(tree, optional_string(params, "state_machine_path", ""))
	if sm_result[1] != null:
		return sm_result[1]
	var sm: AnimationNodeStateMachine = sm_result[0]

	var transition: AnimationNodeStateMachineTransition = null
	for i in sm.get_transition_count():
		if str(sm.get_transition_from(i)) == from_state and str(sm.get_transition_to(i)) == to_state:
			transition = sm.get_transition(i)
			break

	if transition == null:
		return error_not_found("Transition from '%s' to '%s'" % [from_state, to_state])

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Remove state machine transition")
	undo_redo.add_do_method(sm, "remove_transition", StringName(from_state), StringName(to_state))
	undo_redo.add_undo_method(sm, "add_transition", StringName(from_state), StringName(to_state), transition)
	undo_redo.add_undo_reference(transition)
	undo_redo.commit_action()

	return success({"from": from_state, "to": to_state, "removed": true})


func _set_blend_tree_node(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rs := require_string(params, "blend_tree_state")
	if rs[1] != null:
		return rs[1]
	var rn := require_string(params, "bt_node_name")
	if rn[1] != null:
		return rn[1]
	var rt := require_string(params, "bt_node_type")
	if rt[1] != null:
		return rt[1]
	var tree: AnimationTree = ctx[0]
	var bt_state: String = rs[0]
	var bt_node_name: String = rn[0]
	var bt_node_type: String = rt[0]

	var bt_result := _resolve_blend_tree(tree, optional_string(params, "state_machine_path", ""), bt_state)
	if bt_result[1] != null:
		return bt_result[1]
	var bt: AnimationNodeBlendTree = bt_result[0]

	var position := Vector2(float(params.get("position_x", 0.0)), float(params.get("position_y", 0.0)))

	var had_old_node := bt.has_node(StringName(bt_node_name))
	var old_node: AnimationNode = bt.get_node(StringName(bt_node_name)) if had_old_node else null
	var old_position: Vector2 = bt.get_node_position(StringName(bt_node_name)) if had_old_node else Vector2.ZERO

	var node: AnimationNode
	match bt_node_type:
		"Animation":
			var anim_node := AnimationNodeAnimation.new()
			var anim_name := optional_string(params, "animation", "")
			if not anim_name.is_empty():
				anim_node.animation = StringName(anim_name)
			node = anim_node
		"Add2": node = AnimationNodeAdd2.new()
		"Blend2": node = AnimationNodeBlend2.new()
		"Add3": node = AnimationNodeAdd3.new()
		"Blend3": node = AnimationNodeBlend3.new()
		"TimeScale": node = AnimationNodeTimeScale.new()
		"TimeSeek": node = AnimationNodeTimeSeek.new()
		"Transition": node = AnimationNodeTransition.new()
		"OneShot": node = AnimationNodeOneShot.new()
		"Sub2": node = AnimationNodeSub2.new()
		_:
			return error_invalid_params("Unknown bt_node_type: '%s'. Use: Animation, Add2, Blend2, Add3, Blend3, TimeScale, TimeSeek, Transition, OneShot, Sub2" % bt_node_type)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set blend tree node")
	if had_old_node:
		undo_redo.add_do_method(bt, "remove_node", StringName(bt_node_name))
		undo_redo.add_undo_method(bt, "add_node", StringName(bt_node_name), old_node, old_position)
		undo_redo.add_undo_reference(old_node)
	undo_redo.add_do_method(bt, "add_node", StringName(bt_node_name), node, position)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(bt, "remove_node", StringName(bt_node_name))

	var connect_to := optional_string(params, "connect_to", "")
	var connect_port := optional_int(params, "connect_port", 0)
	if not connect_to.is_empty():
		undo_redo.add_do_method(bt, "connect_node", StringName(connect_to), connect_port, StringName(bt_node_name))
	undo_redo.commit_action()

	return success({
		"blend_tree_state": bt_state,
		"bt_node_name": bt_node_name,
		"bt_node_type": bt_node_type,
		"position": {"x": position.x, "y": position.y},
		"connected_to": connect_to if not connect_to.is_empty() else null,
		"added": true,
	})


func _set_blend_point(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var tree: AnimationTree = ctx[0]

	var bs_result := _resolve_blend_space(tree, params)
	if bs_result[1] != null:
		return bs_result[1]
	var bs = bs_result[0]

	var ra := require_string(params, "animation")
	if ra[1] != null:
		return ra[1]

	var anim_node := AnimationNodeAnimation.new()
	anim_node.animation = StringName(ra[0])

	var is_1d := bs is AnimationNodeBlendSpace1D
	var pos_1d := float(params.get("pos", 0.0))
	var pos_2d := vec2_param(params, "position", Vector2(float(params.get("pos_x", 0.0)), float(params.get("pos_y", 0.0))))

	# A fresh point appends, so the index it will occupy is the current count.
	var new_index: int = bs.get_blend_point_count()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Add blend point")
	if is_1d:
		undo_redo.add_do_method(bs, "add_blend_point", anim_node, pos_1d)
	else:
		undo_redo.add_do_method(bs, "add_blend_point", anim_node, pos_2d)
	undo_redo.add_do_reference(anim_node)
	undo_redo.add_undo_method(bs, "remove_blend_point", new_index)
	undo_redo.commit_action()

	var pos_out: Variant = pos_1d if is_1d else {"x": pos_2d.x, "y": pos_2d.y}
	return success({
		"blend_space_state": optional_string(params, "blend_space_state", ""),
		"blend_space_type": bs.get_class(),
		"index": new_index,
		"animation": ra[0],
		"position": pos_out,
		"blend_point_count": bs.get_blend_point_count(),
		"added": true,
	})


func _remove_blend_point(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var tree: AnimationTree = ctx[0]

	var bs_result := _resolve_blend_space(tree, params)
	if bs_result[1] != null:
		return bs_result[1]
	var bs = bs_result[0]

	if not params.has("index"):
		return error_invalid_params("Missing required parameter: index")
	var index := int(params["index"])
	var count: int = bs.get_blend_point_count()
	if index < 0 or index >= count:
		return error_invalid_params("Blend point index %d out of range (0..%d)" % [index, count - 1])

	var old_node: AnimationNode = bs.get_blend_point_node(index)
	var old_pos: Variant = bs.get_blend_point_position(index)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Remove blend point")
	undo_redo.add_do_method(bs, "remove_blend_point", index)
	undo_redo.add_undo_method(bs, "add_blend_point", old_node, old_pos, index)
	undo_redo.add_undo_reference(old_node)
	undo_redo.commit_action()

	return success({
		"blend_space_type": bs.get_class(),
		"index": index,
		"blend_point_count": bs.get_blend_point_count(),
		"removed": true,
	})


func _set_parameter(params: Dictionary) -> Dictionary:
	var ctx := _resolve_tree(params)
	if ctx[1] != null:
		return ctx[1]
	var rp := require_string(params, "parameter")
	if rp[1] != null:
		return rp[1]
	var tree: AnimationTree = ctx[0]
	var parameter: String = rp[0]

	if not params.has("value"):
		return error_invalid_params("Missing required parameter: value")

	if not parameter.begins_with("parameters/"):
		parameter = "parameters/" + parameter

	var old_value: Variant = tree.get(parameter)
	var value: Variant = PropertyParser.parse_value(params["value"], typeof(old_value))

	var undo_redo := get_undo_redo()
	undo_redo.create_action("MCP: Set AnimationTree parameter")
	undo_redo.add_do_property(tree, parameter, value)
	undo_redo.add_undo_property(tree, parameter, old_value)
	undo_redo.commit_action()

	return success({
		"parameter": parameter,
		"value": PropertyParser.serialize_value(tree.get(parameter)),
		"set": true,
	})


func get_command_docs() -> Dictionary:
	return {
		"anim_tree.create": {
			"description": "Create an AnimationTree node UNDER --node-path (which is the PARENT here, unlike the other anim_tree commands where --node-path IS the tree). --root-type picks the tree root. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Parent node to add the AnimationTree under."),
				doc_param("name", "String", false, "Name for the AnimationTree (default 'AnimationTree')."),
				doc_param("root_type", "String", false, "Tree root: state_machine (default), blend_space_1d, blend_space_2d, or blend_tree."),
				doc_param("anim_player", "NodePath", false, "Path to the AnimationPlayer the tree drives."),
				doc_param("min_space", "Vector2", false, "Blend-space lower bound (float for 1d, Vector2 for 2d)."),
				doc_param("max_space", "Vector2", false, "Blend-space upper bound (float for 1d, Vector2 for 2d)."),
				doc_param("snap", "Vector2", false, "Blend-space snap step (float for 1d, Vector2 for 2d)."),
				doc_param("sync", "bool", false, "Blend-space sync playback."),
				doc_param("auto_triangles", "bool", false, "2D blend space: auto-generate triangles."),
				doc_param("value_label", "String", false, "1D blend space axis label."),
				doc_param("x_label", "String", false, "2D blend space X axis label."),
				doc_param("y_label", "String", false, "2D blend space Y axis label."),
			],
		},
		"anim_tree.get_structure": {
			"description": "Read an AnimationTree's structure: state-machine states/transitions, blend-tree nodes, or blend-space points, plus active/anim_player.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
			],
		},
		"anim_tree.add_state": {
			"description": "Add a state to a state machine (root, or the nested one at --state-machine-path). --state-type picks the state's node. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("state_name", "String", true, "New state name."),
				doc_param("state_machine_path", "String", false, "Slash path to a nested state machine (default the root)."),
				doc_param("state_type", "String", false, "animation (default), blend_tree, state_machine, blend_space_1d, or blend_space_2d."),
				doc_param("animation", "String", false, "Clip name for an 'animation' state."),
				doc_param("position_x", "float", false, "State graph X position (editor canvas)."),
				doc_param("position_y", "float", false, "State graph Y position."),
				doc_param("min_space", "Vector2", false, "Blend-space lower bound (blend_space_* types)."),
				doc_param("max_space", "Vector2", false, "Blend-space upper bound (blend_space_* types)."),
				doc_param("snap", "Vector2", false, "Blend-space snap step (blend_space_* types)."),
				doc_param("sync", "bool", false, "Blend-space sync playback (blend_space_* types)."),
				doc_param("auto_triangles", "bool", false, "2D blend space auto-triangles."),
			],
		},
		"anim_tree.remove_state": {
			"description": "Remove a state from a state machine. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("state_name", "String", true, "State to remove."),
				doc_param("state_machine_path", "String", false, "Slash path to a nested state machine (default the root)."),
			],
		},
		"anim_tree.add_transition": {
			"description": "Add a transition between two states (Start/End are built-in pseudo-states). For --advance-mode auto with an expression, set advance_expression_base_node on the tree via node.set. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("from_state", "String", true, "Source state (or 'Start')."),
				doc_param("to_state", "String", true, "Destination state (or 'End')."),
				doc_param("state_machine_path", "String", false, "Slash path to a nested state machine (default the root)."),
				doc_param("switch_mode", "String", false, "immediate (default), at_end, or sync."),
				doc_param("advance_mode", "String", false, "enabled (default), disabled, or auto."),
				doc_param("advance_expression", "String", false, "Boolean expression that triggers an auto transition."),
				doc_param("xfade_time", "float", false, "Cross-fade time in seconds."),
			],
		},
		"anim_tree.remove_transition": {
			"description": "Remove the transition between two states. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("from_state", "String", true, "Source state."),
				doc_param("to_state", "String", true, "Destination state."),
				doc_param("state_machine_path", "String", false, "Slash path to a nested state machine (default the root)."),
			],
		},
		"anim_tree.set_blend_tree_node": {
			"description": "Add or replace a node inside a BlendTree state, optionally wiring its output into another node's input port. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("blend_tree_state", "String", true, "Name of the BlendTree state to edit."),
				doc_param("bt_node_name", "String", true, "Name of the node to add/replace inside the blend tree."),
				doc_param("bt_node_type", "String", true, "Animation, Add2, Blend2, Add3, Blend3, TimeScale, TimeSeek, Transition, OneShot, or Sub2."),
				doc_param("state_machine_path", "String", false, "Slash path to a nested state machine holding the blend tree (default the root)."),
				doc_param("animation", "String", false, "Clip name for an 'Animation' blend-tree node."),
				doc_param("position_x", "float", false, "Node graph X position."),
				doc_param("position_y", "float", false, "Node graph Y position."),
				doc_param("connect_to", "String", false, "Existing node name to feed this node's output into."),
				doc_param("connect_port", "int", false, "Input port index on connect_to (default 0)."),
			],
		},
		"anim_tree.set_blend_point": {
			"description": "Add a blend point wrapping an animation clip in a blend space, the tree root or the nested blend-space state named by --blend-space-state. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("animation", "String", true, "Animation clip to place at the point."),
				doc_param("blend_space_state", "String", false, "Nested blend-space state name; omit to target the tree root."),
				doc_param("state_machine_path", "String", false, "Slash path to the state machine holding blend_space_state."),
				doc_param("pos", "float", false, "Position on a 1D blend space."),
				doc_param("position", "Vector2", false, "Position on a 2D blend space (or --pos-x/--pos-y)."),
			],
		},
		"anim_tree.remove_blend_point": {
			"description": "Remove a blend point by index from a blend space (tree root or --blend-space-state). Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("index", "int", true, "Blend point index to remove."),
				doc_param("blend_space_state", "String", false, "Nested blend-space state name; omit for the tree root."),
				doc_param("state_machine_path", "String", false, "Slash path to the state machine holding blend_space_state."),
			],
		},
		"anim_tree.set_parameter": {
			"description": "Set a live AnimationTree parameter (a 'parameters/...' path; the prefix is added if omitted), e.g. a blend_position or a condition. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Target AnimationTree."),
				doc_param("parameter", "String", true, "Parameter path, e.g. 'parameters/blend_position' (the 'parameters/' prefix is auto-added)."),
				doc_param("value", "JSON", true, "New value, coerced toward the parameter's current type."),
			],
		},
	}
