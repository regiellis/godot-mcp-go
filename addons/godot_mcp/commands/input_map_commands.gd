@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"input_map.get_actions": _get_actions,
		"input_map.set_action": _set_action,
	}


func _get_actions(params: Dictionary) -> Dictionary:
	var filter := optional_string(params, "filter", "")
	var include_builtin := optional_bool(params, "include_builtin", false)

	var actions: Dictionary = {}
	for action: StringName in InputMap.get_actions():
		var action_str := String(action)
		if not include_builtin and action_str.begins_with("ui_"):
			continue
		if not filter.is_empty() and not action_str.contains(filter):
			continue

		var events: Array = []
		for event: InputEvent in InputMap.action_get_events(action):
			events.append(_serialize_event(event))

		actions[action_str] = {
			"deadzone": InputMap.action_get_deadzone(action),
			"events": events,
		}

	return success({"actions": actions, "count": actions.size()})


func _set_action(params: Dictionary) -> Dictionary:
	var r := require_string(params, "action")
	if r[1] != null:
		return r[1]
	var action_name: String = r[0]

	if not params.has("events") or not params["events"] is Array:
		return error_invalid_params("'events' array is required")
	var event_defs: Array = params["events"]

	var deadzone := float(params.get("deadzone", 0.5))

	var events: Array[InputEvent] = []
	for event_def in event_defs:
		if not event_def is Dictionary:
			continue
		var event := _parse_event(event_def)
		if event != null:
			events.append(event)

	ProjectSettings.set_setting("input/" + action_name, {"deadzone": deadzone, "events": events})
	var err := ProjectSettings.save()
	if err != OK:
		return error_internal("Failed to save project settings: %s" % error_string(err))

	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
	else:
		InputMap.action_set_deadzone(action_name, deadzone)
		InputMap.action_erase_events(action_name)
	for event in events:
		InputMap.action_add_event(action_name, event)

	return success({
		"action": action_name,
		"deadzone": deadzone,
		"events_count": events.size(),
		"saved": true,
	})


func _serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var ke := event as InputEventKey
		var info := {
			"type": "key",
			"keycode": OS.get_keycode_string(ke.keycode) if ke.keycode != KEY_NONE else "",
			"physical_keycode": OS.get_keycode_string(ke.physical_keycode) if ke.physical_keycode != KEY_NONE else "",
		}
		if ke.ctrl_pressed: info["ctrl"] = true
		if ke.shift_pressed: info["shift"] = true
		if ke.alt_pressed: info["alt"] = true
		if ke.meta_pressed: info["meta"] = true
		return info
	if event is InputEventMouseButton:
		return {"type": "mouse_button", "button_index": (event as InputEventMouseButton).button_index}
	if event is InputEventJoypadButton:
		return {"type": "joypad_button", "button_index": (event as InputEventJoypadButton).button_index}
	if event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		return {"type": "joypad_motion", "axis": jm.axis, "axis_value": jm.axis_value}
	return {"type": event.get_class()}


## Accept both "KEY_SPACE" (GlobalScope constant) and "Space" (display name).
func _keycode(s: String) -> int:
	if s.is_empty():
		return KEY_NONE
	if s.begins_with("KEY_"):
		var c := ClassDB.class_get_integer_constant("@GlobalScope", s)
		return c if c != 0 else OS.find_keycode_from_string(s.substr(4))
	return OS.find_keycode_from_string(s)


func _parse_event(def: Dictionary) -> InputEvent:
	match String(def.get("type", "")):
		"key":
			var event := InputEventKey.new()
			event.keycode = _keycode(def.get("keycode", ""))
			event.physical_keycode = _keycode(def.get("physical_keycode", ""))
			event.ctrl_pressed = def.get("ctrl", false)
			event.shift_pressed = def.get("shift", false)
			event.alt_pressed = def.get("alt", false)
			event.meta_pressed = def.get("meta", false)
			return event
		"mouse_button":
			var event := InputEventMouseButton.new()
			event.button_index = int(def.get("button_index", 1))
			return event
		"joypad_button":
			var event := InputEventJoypadButton.new()
			event.button_index = int(def.get("button_index", 0))
			return event
		"joypad_motion":
			var event := InputEventJoypadMotion.new()
			event.axis = int(def.get("axis", 0))
			event.axis_value = float(def.get("axis_value", 1.0))
			return event
	return null


func get_command_docs() -> Dictionary:
	return {
		"input_map.get_actions": {
			"description": "List InputMap actions with their deadzone and serialized events. Skips built-in ui_* actions unless --include-builtin, and narrows to names containing --filter.",
			"params": [
				doc_param("filter", "String", false, "Only actions whose name contains this substring."),
				doc_param("include_builtin", "bool", false, "Include the engine's ui_* actions (default false)."),
			],
		},
		"input_map.set_action": {
			"description": "Create or overwrite an input action's events and deadzone, persisted to project.godot. Replaces the action's existing events. Keys accept both 'KEY_SPACE' and 'Space' forms.",
			"params": [
				doc_param("action", "String", true, "Action name to create or overwrite (e.g. 'jump')."),
				doc_param("events", "Array", true, "JSON array of event objects. Each has 'type' (key, mouse_button, joypad_button, or joypad_motion) plus fields: key uses keycode/physical_keycode (and ctrl/shift/alt/meta); mouse_button and joypad_button use button_index; joypad_motion uses axis and axis_value."),
				doc_param("deadzone", "float", false, "Analog deadzone for the action (default 0.5)."),
			],
		},
	}
