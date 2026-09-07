@tool
extends Node

## Buffers EDITOR activity (selection changes, scene switches, saves, undo/redo
## history bumps) into a bounded ring polled by editor.activity, so an agent
## sharing the editor with a human is not blind to what the human just did.
## Pull, not push: same cursor contract as services/game_error_log.gd.
##
## Honesty note: "edit" events come from EditorUndoRedoManager.version_changed,
## which also fires for actions the MCP's own commands commit, so an agent
## should expect its own mutations in the stream. Selection and save events are
## almost always the human.

const MAX_ENTRIES := 200

var _entries: Array = []  # ring buffer of event dicts, each tagged with a seq
var _seq: int = 0         # monotonic id handed to each entry; the poll cursor
var _last_edit_frame: int = -1  # same-frame dedupe for the two history signals


## Connect the editor signals. Called by plugin.gd after add_child; the plugin
## reference is needed for the EditorPlugin signals and the undo/redo manager.
func setup(plugin: EditorPlugin) -> void:
	plugin.scene_changed.connect(_on_scene_changed)
	plugin.scene_closed.connect(_on_scene_closed)
	plugin.scene_saved.connect(_on_scene_saved)
	plugin.resource_saved.connect(_on_resource_saved)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# Both history signals feed one "edit" event type: history_changed fires on
	# commit_action (version_changed does NOT, verified live on 4.7.2), and
	# version_changed covers undo/redo. Same-frame dedupe below collapses any
	# commit where both fire.
	plugin.get_undo_redo().history_changed.connect(_on_history_activity)
	plugin.get_undo_redo().version_changed.connect(_on_history_activity)


func _on_scene_changed(root: Node) -> void:
	var path := "" if root == null else root.scene_file_path
	_record("scene_changed", {"path": path})


func _on_scene_closed(path: String) -> void:
	_record("scene_closed", {"path": path})


func _on_scene_saved(path: String) -> void:
	_record("scene_saved", {"path": path})


func _on_resource_saved(res: Resource) -> void:
	# Scene saves already arrive as scene_saved; skip the PackedScene duplicate
	# so one Ctrl+S is one event.
	if res == null or res is PackedScene:
		return
	_record("resource_saved", {"path": res.resource_path})


func _on_selection_changed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var paths: Array = []
	if root != null:
		for n: Node in EditorInterface.get_selection().get_selected_nodes():
			if n == root:
				paths.append(".")
			elif root.is_ancestor_of(n):
				paths.append(str(root.get_path_to(n)))
	# Selection churn is the noisiest signal; drop an event identical to the
	# previous selection event (clicking the same node twice).
	if not _entries.is_empty():
		var last: Dictionary = _entries[-1]
		if last["type"] == "selection" and last["nodes"] == paths:
			return
	_record("selection", {"nodes": paths, "count": paths.size()})


func _on_history_activity() -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_edit_frame:
		return
	_last_edit_frame = frame
	_record("edit", {})


func _record(type: String, data: Dictionary) -> void:
	var entry := {
		"seq": _seq,
		"at": int(Time.get_unix_time_from_system()),
		"type": type,
	}
	entry.merge(data)
	_entries.append(entry)
	_seq += 1
	while _entries.size() > MAX_ENTRIES:
		_entries.pop_front()


## Return buffered events with seq >= since_seq, oldest first, capped to the
## NEWEST `limit` entries. next_seq is the cursor for the following poll; clear
## empties the buffer after reading.
func poll(since_seq: int, limit: int, clear: bool) -> Dictionary:
	var out: Array = []
	for e in _entries:
		if int(e["seq"]) >= since_seq:
			out.append(e)
	var truncated := 0
	if limit > 0 and out.size() > limit:
		truncated = out.size() - limit
		out = out.slice(out.size() - limit)
	var next_seq := _seq
	if clear:
		_entries.clear()
	var result := {"events": out, "count": out.size(), "next_seq": next_seq, "buffered": _entries.size()}
	if truncated > 0:
		result["truncated"] = truncated
	return result
