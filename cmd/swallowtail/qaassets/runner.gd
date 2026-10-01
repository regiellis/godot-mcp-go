extends SceneTree
## External source-test runner. Never included in a player export.
var output: String
var scenario_path: String
var checks: Array = []
var screenshots: Array = []
var frames: Array = []
var phase_name := "startup"
var previous_usec := 0
var checkpoint_usec := 0
var checkpoint_id := 0
var frame_file: FileAccess
var frame_chunks: Array[Dictionary] = []
var hashed_frame_bytes := 0
var checkpoint_failed := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	output = args[0]
	scenario_path = args[1]
	previous_usec = Time.get_ticks_usec()
	checkpoint_usec = previous_usec
	frame_file = FileAccess.open(output.path_join("frames.csv"), FileAccess.WRITE)
	if frame_file == null:
		_checkpoint_error("Cannot open frames.csv: " + error_string(FileAccess.get_open_error()))
		return
	frame_file.store_csv_line(PackedStringArray(["time_us", "frame_ms", "phase"]))
	if not _checkpoint():
		return
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if checkpoint_failed:
		return false
	var now := Time.get_ticks_usec()
	var elapsed_ms: float = (now - previous_usec) / 1000.0
	frames.append([now, elapsed_ms, phase_name])
	frame_file.store_csv_line(PackedStringArray([str(now), str(elapsed_ms), phase_name]))
	previous_usec = now
	if now - checkpoint_usec >= 1000000:
		_checkpoint()
	return false


func phase(label: String) -> void:
	phase_name = label
	_checkpoint()


func check(condition: bool, label: String) -> void:
	checks.append({"name": label, "status": "pass" if condition else "fail"})
	_checkpoint()


func wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func screenshot(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		checks.append(
			{"name": "screenshot: " + label, "status": "skip", "detail": "headless renderer"}
		)
		_checkpoint()
		return
	# Captures stall the render thread; label them separately from performance phases.
	var prior := phase_name
	phase("screenshot")
	await RenderingServer.frame_post_draw
	var filename := "screenshot-%02d.png" % screenshots.size()
	var destination := output.path_join(filename)
	var error := root.get_texture().get_image().save_png(destination + ".tmp")
	if error == OK:
		error = DirAccess.rename_absolute(destination + ".tmp", destination)
	checks.append(
		{
			"name": "screenshot: " + label,
			"status": "pass" if error == OK else "fail",
			"detail": error_string(error)
		}
	)
	if error == OK:
		screenshots.append(
			{"path": filename, "caption": label, "sha256": FileAccess.get_sha256(destination)}
		)
	# Publish the assertion and its completed capture together, never a half-pair.
	_checkpoint()
	await process_frame
	phase(prior)


func _run() -> void:
	var script: Variant = load(scenario_path)
	if script == null or not script.can_instantiate():
		push_error("QA scenario failed to compile")
		quit(2)
		return
	var scenario: Variant = script.new()
	if not (scenario is RefCounted) or not scenario.has_method("run"):
		push_error("QA scenario must extend RefCounted and expose run(qa)")
		quit(2)
		return
	await scenario.run(self)
	if checkpoint_failed:
		return
	phase("shutdown")
	# Stop test-owned playback while the tree still owns the players. Otherwise
	# the audio mixer can retain a stream until after ResourceCache is destroyed.
	for tween in get_processed_tweens():
		tween.kill()
	_drain_audio(root)
	if current_scene != null:
		current_scene.queue_free()
		current_scene = null
	await process_frame
	# Drain audio/scene teardown before the process log is evaluated.
	await create_timer(0.15).timeout
	if not _checkpoint(true):
		return
	frame_file.close()
	quit()


func _checkpoint(complete: bool = false) -> bool:
	if checkpoint_failed:
		return false
	# CSV is an append log. The atomic receipt commits only a flushed prefix;
	# bytes appended after it are retained as raw evidence, not completed samples.
	frame_file.flush()
	if frame_file.get_error() != OK:
		return _checkpoint_error("Cannot flush frames.csv: " + error_string(frame_file.get_error()))
	var frame_bytes: int = frame_file.get_position()
	if frame_bytes > hashed_frame_bytes and not _hash_new_frames(frame_bytes):
		return false
	checkpoint_id += 1
	var receipt := {
		"schema": 2,
		"complete": complete,
		"checks": checks,
		"screenshots": screenshots,
		"checkpoint": checkpoint_id,
		"frames":
		{
			"path": "frames.csv",
			"samples": frames.size(),
			"bytes": frame_bytes,
			"chunks": frame_chunks
		},
		"engine": Engine.get_version_info().string,
		"renderer": RenderingServer.get_current_rendering_method(),
		"device": RenderingServer.get_video_adapter_name(),
		"viewport": str(root.size),
		"texture_bytes": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	}
	var published: bool = _publish_receipt(receipt)
	if published:
		checkpoint_usec = Time.get_ticks_usec()
	return published


func _publish_receipt(receipt: Dictionary) -> bool:
	var destination := output.path_join("scenario.json")
	var file := FileAccess.open(destination + ".tmp", FileAccess.WRITE)
	if file == null:
		return _checkpoint_error(
			"Cannot open scenario checkpoint: " + error_string(FileAccess.get_open_error())
		)
	file.store_string(JSON.stringify(receipt, "  "))
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		return _checkpoint_error("Cannot write scenario checkpoint: " + error_string(write_error))
	var rename_error: Error = DirAccess.rename_absolute(destination + ".tmp", destination)
	if rename_error != OK:
		return _checkpoint_error(
			"Cannot publish scenario checkpoint: " + error_string(rename_error)
		)
	return true


func _hash_new_frames(frame_bytes: int) -> bool:
	# Hash only appended bytes; rereading the full history each second would skew
	# long performance runs. The manifest authenticates every committed segment.
	var reader := FileAccess.open(output.path_join("frames.csv"), FileAccess.READ)
	if reader == null:
		return _checkpoint_error(
			"Cannot read flushed frame samples: " + error_string(FileAccess.get_open_error())
		)
	reader.seek(hashed_frame_bytes)
	var length: int = frame_bytes - hashed_frame_bytes
	var data: PackedByteArray = reader.get_buffer(length)
	var read_error: Error = reader.get_error()
	reader.close()
	if data.size() != length or read_error != OK:
		return _checkpoint_error(
			"Cannot read complete flushed frame segment: " + error_string(read_error)
		)
	var context := HashingContext.new()
	var hash_error: Error = context.start(HashingContext.HASH_SHA256)
	if hash_error != OK:
		return _checkpoint_error("Cannot start frame checksum: " + error_string(hash_error))
	hash_error = context.update(data)
	if hash_error != OK:
		return _checkpoint_error("Cannot update frame checksum: " + error_string(hash_error))
	var hash_bytes: PackedByteArray = context.finish()
	if hash_bytes.size() != 32:
		return _checkpoint_error("Frame checksum did not produce a SHA-256 digest")
	frame_chunks.append(
		{"offset": hashed_frame_bytes, "bytes": length, "sha256": hash_bytes.hex_encode()}
	)
	hashed_frame_bytes = frame_bytes
	return true


func _checkpoint_error(message: String) -> bool:
	checkpoint_failed = true
	push_error("QA progress checkpoint failed: " + message)
	quit(2)
	return false


func _drain_audio(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		node.stop()
		node.stream = null
	for child in node.get_children():
		_drain_audio(child)
