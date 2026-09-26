extends SceneTree
## External source-test runner. Never included in a player export.
var output: String
var scenario_path: String
var checks: Array = []
var screenshots: Array = []
var frames: Array = []
var phase_name := "startup"
var previous_usec := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	output = args[0]
	scenario_path = args[1]
	previous_usec = Time.get_ticks_usec()
	_run.call_deferred()

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	frames.append([now, (now - previous_usec) / 1000.0, phase_name])
	previous_usec = now
	return false

func phase(label: String) -> void:
	phase_name = label

func check(condition: bool, label: String) -> void:
	checks.append({"name": label, "status": "pass" if condition else "fail"})

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func screenshot(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		checks.append({"name": "screenshot: " + label, "status": "skip", "detail": "headless renderer"})
		return
	# Captures stall the render thread; label them separately from performance phases.
	var prior := phase_name
	phase("screenshot")
	await RenderingServer.frame_post_draw
	var filename := "screenshot-%02d.png" % screenshots.size()
	var error := root.get_texture().get_image().save_png(output.path_join(filename))
	check(error == OK, "screenshot: " + label)
	if error == OK:
		screenshots.append({"path": filename, "caption": label})
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
	var file := FileAccess.open(output.path_join("frames.csv"), FileAccess.WRITE)
	file.store_csv_line(PackedStringArray(["time_us", "frame_ms", "phase"]))
	for row in frames:
		file.store_csv_line(PackedStringArray([str(row[0]), str(row[1]), row[2]]))
	file.close()
	var receipt := {"schema": 1, "complete": true, "checks": checks, "screenshots": screenshots,
		"engine": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(),
		"device": RenderingServer.get_video_adapter_name(), "viewport": str(root.size),
		"texture_bytes": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)}
	file = FileAccess.open(output.path_join("scenario.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	quit()

func _drain_audio(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		node.stop()
		node.stream = null
	for child in node.get_children():
		_drain_audio(child)
