@tool
extends "res://addons/swallowtail/commands/base_command.gd"

## Record a playtest session in the RUNNING game: frame times every frame,
## engine counters every N frames, and every input.* event, game event,
## checkpoint, and runtime error with a timestamp. The recorder lives in the game
## (services/playtest_recorder.gd under MCPGameInspector), so these commands cross
## the same game hop as runtime.* and reach a standalone game over --game too.
## playtest.stop writes one JSON file under the game's user://swallowtail-playtests/,
## and `swallowtail playtest report` turns it into numbers on the CLI side.


func get_commands() -> Dictionary:
	return {
		"playtest.start": _start,
		"playtest.mark": _mark,
		"playtest.event": _event,
		"playtest.status": _status,
		"playtest.stop": _stop,
	}


func _start(params: Dictionary) -> Dictionary:
	var cmd := {}
	if params.has("name"):
		cmd["name"] = str(params["name"])
	if params.has("sample_every"):
		cmd["sample_every"] = params["sample_every"]
	return await send_game_command("playtest_start", cmd)


func _mark(params: Dictionary) -> Dictionary:
	var r := require_string(params, "label")
	if r[1] != null:
		return r[1]
	return await send_game_command("playtest_mark", {"label": r[0]})


func _event(params: Dictionary) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var d := optional_dict(params, "data")
	if d[1] != null:
		return d[1]
	return await send_game_command("playtest_event", {"name": r[0], "data": d[0]})


func _status(_params: Dictionary) -> Dictionary:
	return await send_game_command("playtest_status", {})


## Writing a long session (an hour of frames is a few MB of JSON) takes the game
## a moment, so the wait is longer than the hop's default.
func _stop(_params: Dictionary) -> Dictionary:
	return await send_game_command("playtest_stop", {}, 20.0)


func get_command_docs() -> Dictionary:
	return {
		"playtest.start": {
			"description": "Start recording a playtest session in the running game: wall-clock frame time every frame, engine counters (FPS, process and physics time, static/video/texture memory, object/node/orphan counts, draw calls, primitives) every --sample-every frames and on each spike frame, plus every input.* event, game event, checkpoint, and runtime error with a timestamp. Refuses while a session is already recording. Requires scene.play (or --game).",
			"params": [
				doc_param("name", "String", false, "Session name, used in the file name; letters, digits, '-' and '_' are kept, anything else becomes '-' (default 'session')."),
				doc_param("sample_every", "int", false, "Frames between full counter samples, 1 to 3600 (default 30)."),
			],
		},
		"playtest.mark": {
			"description": "Mark a checkpoint in the recording session. Each mark starts a report section (time, events, inputs, and frame times per section); a label used twice counts as a second visit. Requires a recording session.",
			"params": [
				doc_param("label", "String", true, "Checkpoint label, e.g. 'wave 3'."),
			],
		},
		"playtest.event": {
			"description": "Record a game fact (death, damage, pickup) in the recording session from the CLI. Game code records the same thing with MCPGameInspector.playtest_event(name, data). Requires a recording session.",
			"params": [
				doc_param("name", "String", true, "Event name; the report counts events per name and per section."),
				doc_param("data", "Dictionary", false, "JSON object stored with the event (at most 4 KiB serialized)."),
			],
		},
		"playtest.status": {
			"description": "Read the recording session's live counters: elapsed time, frame and sample counts, events, inputs, marks, errors, the current section, the last 120 frames' average and worst frame time, and the latest counter sample. Answers recording:false when no session runs.",
		},
		"playtest.stop": {
			"description": "Stop the recording session and write it as one JSON file under the game's user://swallowtail-playtests/. Returns a summary (frame percentiles, counts, truncation) plus the file's user:// path and absolute path; feed it to `swallowtail playtest report`. Stop before scene.stop: an editor-stopped game is killed and its session is lost.",
		},
	}
