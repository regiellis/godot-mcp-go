@tool
extends Node

const SceneCommands := preload("res://addons/swallowtail/commands/scene_commands.gd")

var done: bool = false
var result: Dictionary = {}


func begin(mode: String, target: String, save_path: String) -> void:
	assert(mode in ["switch", "close"], "Save guard probe requires mode 'switch' or 'close'")
	assert(EditorInterface.get_edited_scene_root() != null, "Save guard probe requires an open scene")
	assert(not FileAccess.file_exists(save_path), "Save guard probe output must not already exist")
	if mode == "switch":
		assert(FileAccess.file_exists(target), "Save guard probe switch target must exist")
	var commands := SceneCommands.new()
	add_child(commands)
	# This starts _save through its first await, while this persistent helper stays alive.
	_collect(commands, save_path)
	if mode == "switch":
		EditorInterface.open_scene_from_path(target)
	else:
		EditorInterface.close_scene()


func _collect(commands: SceneCommands, save_path: String) -> void:
	result = await commands._save({"path": save_path})
	done = true
	commands.queue_free()
