@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Activity stats for the opt-in dashboard. The data lives in the command_router
## (which is this node's parent — command groups are added as its children).


func get_commands() -> Dictionary:
	return {
		"stats.snapshot": _snapshot,
		"stats.reset": _reset,
	}


func _snapshot(_params: Dictionary) -> Dictionary:
	var router := get_parent()
	if router != null and router.has_method("stats_snapshot"):
		return success(router.stats_snapshot())
	return error_internal("Stats unavailable")


func _reset(_params: Dictionary) -> Dictionary:
	var router := get_parent()
	if router != null and router.has_method("reset_stats"):
		router.reset_stats()
		return success({"reset": true})
	return error_internal("Stats unavailable")


func get_command_docs() -> Dictionary:
	return {
		"stats.snapshot": {
			"description": "Return the command router's activity stats for the opt-in dashboard (per-command call counts, timings, and the like).",
			"params": [],
		},
		"stats.reset": {
			"description": "Clear the accumulated command-activity stats.",
			"params": [],
		},
	}
