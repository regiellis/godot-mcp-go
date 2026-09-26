@tool
extends Control
## Playback and editor seeking only. All artwork and motion live in scene nodes/tracks.

@export_range(0.0, 469.433, 0.1) var preview_time := 0.0:
	set(value):
		preview_time = value
		if Engine.is_editor_hint() and is_node_ready():
			_seek_preview()
@export var autoplay := true
@export var quit_at_end := true

@onready var timeline: AnimationPlayer = $Timeline
var reviewing := false


func _ready() -> void:
	if Engine.is_editor_hint():
		_seek_preview.call_deferred()
		return
	var stamps: Array[float] = []
	var start := 0.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--review="):
			for value in argument.trim_prefix("--review=").split(","):
				stamps.append(float(value))
		if argument.begins_with("--start="):
			start = float(argument.trim_prefix("--start="))
	if not stamps.is_empty():
		reviewing = true
		_review.call_deferred(stamps)
		return
	timeline.animation_finished.connect(_finished)
	if autoplay:
		timeline.play("Film")
		timeline.seek(start, true)


func _seek_preview() -> void:
	if not is_instance_valid(timeline):
		return
	timeline.assigned_animation = "Film"
	timeline.seek(preview_time, true)
	# Inspector scrubbing is silent; Animation panel playback can audition audio.
	$Audio/Voiceover.stop()
	$Audio/Music.stop()


func _finished(_animation: StringName) -> void:
	if quit_at_end and not reviewing:
		get_tree().quit()


func _review(stamps: Array[float]) -> void:
	timeline.assigned_animation = "Film"
	for stamp in stamps:
		timeline.seek(stamp, true)
		$Audio/Voiceover.stop()
		$Audio/Music.stop()
		for frame in 5:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "res://out/nodes_%03d.png" % int(stamp)
		get_viewport().get_texture().get_image().save_png(path)
		print("REVIEW ", stamp, " ", path)
	get_tree().quit()
