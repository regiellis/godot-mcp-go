extends RefCounted
## Turns the errors a Logger captured around an ad-hoc exec (editor.run_script,
## runtime.eval) into a result the caller can act on. Shared by both processes,
## so static only, and it must parse at the 4.3 floor.
##
## A GDScript runtime error (an invalid call, a null dereference) aborts the
## function it happens in and hands back null: the wrapper's run() ends early,
## `output` holds whatever was emitted before the fault, and nothing else says
## so. The engine prints the error to the Output panel, which is not the reply.
## Lines in a pathless throwaway come back against gdscript://<id>.gd, so they
## are rebased onto the caller's own code by subtracting the wrapper preamble.


## The path the engine reports for a script with no resource_path
## (GDScript::_get_gdscript_path, verified 4.7: "gdscript://%d.gd" of the
## instance id).
static func script_file(script: Script) -> String:
	return "gdscript://%d.gd" % script.get_instance_id()


## Compact the captured entries: `aborted` is true when a script-kind error was
## raised inside the snippet itself, which is the one case run() did not finish.
## A push_error, an engine ERR_FAIL inside a called method, or a warning is
## reported without failing the call, since the snippet ran to its end.
static func classify(entries: Array, script_path: String, preamble_lines: int) -> Dictionary:
	var errors: Array = []
	var aborted := false
	var abort_line := 0
	var abort_message := ""
	for e in entries:
		if not e is Dictionary:
			continue
		var kind := String(e.get("kind", "error"))
		var file := String(e.get("file", ""))
		var line := int(e.get("line", 0))
		var item := {"kind": kind, "message": String(e.get("message", "")), "file": file, "line": line}
		var in_snippet := file == script_path
		if not in_snippet:
			# push_error reports the engine's own C++ file; the snippet's line is
			# the first backtrace frame when the call came from the snippet.
			var frames: Variant = e.get("backtrace", [])
			if frames is Array and not frames.is_empty() and frames[0] is Dictionary and String(frames[0].get("file", "")) == script_path:
				in_snippet = true
				line = int(frames[0].get("line", 0))
		if in_snippet:
			item["file"] = "<your code>"
			item["line"] = line - preamble_lines
		if in_snippet and kind == "script" and not aborted:
			aborted = true
			abort_line = line - preamble_lines
			abort_message = item["message"]
		errors.append(item)
	return {"aborted": aborted, "errors": errors, "abort_line": abort_line, "abort_message": abort_message}


## One line for the error envelope: the reason plus the caller's own line.
static func abort_text(classified: Dictionary) -> String:
	var text := "Script aborted"
	if int(classified.get("abort_line", 0)) > 0:
		text += " at line %d of your code" % int(classified["abort_line"])
	var message := String(classified.get("abort_message", ""))
	if not message.is_empty():
		text += ": " + message
	return text
