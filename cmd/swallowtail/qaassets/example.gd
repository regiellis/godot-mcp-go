extends RefCounted
## Replace this smoke scenario with the game's real navigation and gameplay.
func run(qa) -> void:
	qa.phase("boot")
	var scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	qa.check(not scene.is_empty(), "main scene configured")
	if scene.is_empty():
		return
	qa.check(qa.change_scene_to_file(scene) == OK, "main scene loaded")
	await qa.wait(5.0)
	qa.check(qa.current_scene != null, "scene remains alive")
	qa.phase("idle")
	await qa.wait(5.0)
	await qa.screenshot("Main scene after ten seconds; visual review required")
