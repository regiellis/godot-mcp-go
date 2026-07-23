@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Example project-local command group.
##
## Drop files like this into res://mcp_commands/ and the addon registers them
## alongside the built-ins on plugin enable — no fork needed (the Unity
## [CliCommand] equivalent). A file just has to instantiate to a Node and expose
## get_commands() -> {"group.command": Callable}. Extending base_command gives you
## success()/error()/require_string() and the rest of the helper set; a plain
## `extends Node` works too if you'd rather build the result dicts by hand
## ({"result": {...}} on success, {"error": {"code": int, "message": String}} on
## failure). A name that collides with a built-in is skipped — built-ins win.
##
## Editing this file needs a FULL editor restart to recompile; editor.reload_plugin
## re-runs registration but does not re-parse changed GDScript from disk.

func get_commands() -> Dictionary:
	return {
		"custom.ping": _ping,
		"custom.echo": _echo,
	}


## Optional param metadata for engine.commands --group custom (the [CliArg]
## equivalent). Map each "group.command" to {description, params:[...]}; each param
## is {name, type, required, desc}. Omit "params" for a command that takes none.
## Written with plain dict literals here so it copies cleanly even into a group that
## `extends Node` (base_command offers a doc_param() helper if you extend it).
func get_command_docs() -> Dictionary:
	return {
		"custom.ping": {
			"description": "Health check: returns {pong: true}.",
		},
		"custom.echo": {
			"description": "Echo --message back to the caller.",
			"params": [
				{"name": "message", "type": "String", "required": true, "desc": "Text to echo back."},
			],
		},
	}


func _ping(_params: Dictionary) -> Dictionary:
	return success({"pong": true})


func _echo(params: Dictionary) -> Dictionary:
	var r := require_string(params, "message")
	if r[1] != null:
		return r[1]  # invalid-params error naming the missing "message"
	return success({"message": r[0]})
