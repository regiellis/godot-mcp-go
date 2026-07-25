@tool
extends "res://addons/godot_mcp/commands/base_command.gd"


func get_commands() -> Dictionary:
	return {
		"audio.get_bus_layout": _get_bus_layout,
		"audio.add_bus": _add_bus,
		"audio.set_bus": _set_bus,
		"audio.add_bus_effect": _add_bus_effect,
		"audio.add_player": _add_player,
		"audio.get_info": _get_info,
	}


func _get_bus_layout(_params: Dictionary) -> Dictionary:
	var buses: Array[Dictionary] = []
	for i in range(AudioServer.bus_count):
		var effects: Array[Dictionary] = []
		for j in range(AudioServer.get_bus_effect_count(i)):
			var effect := AudioServer.get_bus_effect(i, j)
			effects.append({
				"index": j,
				"type": effect.get_class(),
				"enabled": AudioServer.is_bus_effect_enabled(i, j),
				"params": _effect_params(effect),
			})
		buses.append({
			"index": i,
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"solo": AudioServer.is_bus_solo(i),
			"mute": AudioServer.is_bus_mute(i),
			"bypass_effects": AudioServer.is_bus_bypassing_effects(i),
			"send": AudioServer.get_bus_send(i),
			"effects": effects,
		})
	return success({"bus_count": AudioServer.bus_count, "buses": buses})


func _effect_params(effect: AudioEffect) -> Dictionary:
	if effect is AudioEffectReverb:
		var rev := effect as AudioEffectReverb
		return {"room_size": rev.room_size, "damping": rev.damping, "wet": rev.wet, "dry": rev.dry, "spread": rev.spread}
	if effect is AudioEffectDelay:
		var d := effect as AudioEffectDelay
		return {"tap1_active": d.tap1_active, "tap1_delay_ms": d.tap1_delay_ms, "tap1_level_db": d.tap1_level_db, "tap2_active": d.tap2_active, "tap2_delay_ms": d.tap2_delay_ms, "tap2_level_db": d.tap2_level_db}
	if effect is AudioEffectCompressor:
		var c := effect as AudioEffectCompressor
		return {"threshold": c.threshold, "ratio": c.ratio, "attack_us": c.attack_us, "release_ms": c.release_ms, "gain": c.gain, "mix": c.mix, "sidechain": c.sidechain}
	if effect is AudioEffectLimiter:
		var l := effect as AudioEffectLimiter
		return {"ceiling_db": l.ceiling_db, "threshold_db": l.threshold_db, "soft_clip_db": l.soft_clip_db, "soft_clip_ratio": l.soft_clip_ratio}
	if effect is AudioEffectDistortion:
		var dist := effect as AudioEffectDistortion
		return {"mode": dist.mode, "pre_gain": dist.pre_gain, "post_gain": dist.post_gain, "keep_hf_hz": dist.keep_hf_hz, "drive": dist.drive}
	if effect is AudioEffectChorus:
		var ch := effect as AudioEffectChorus
		return {"voice_count": ch.voice_count, "dry": ch.dry, "wet": ch.wet}
	if effect is AudioEffectPhaser:
		var ph := effect as AudioEffectPhaser
		return {"range_min_hz": ph.range_min_hz, "range_max_hz": ph.range_max_hz, "rate_hz": ph.rate_hz, "feedback": ph.feedback, "depth": ph.depth}
	if effect is AudioEffectFilter:
		var f := effect as AudioEffectFilter
		return {"cutoff_hz": f.cutoff_hz, "resonance": f.resonance, "gain": f.gain, "db": f.db}
	if effect is AudioEffectAmplify:
		var a := effect as AudioEffectAmplify
		return {"volume_db": a.volume_db}
	return {}


func _add_bus(params: Dictionary) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var bus_name: String = r[0]

	for i in range(AudioServer.bus_count):
		if AudioServer.get_bus_name(i) == bus_name:
			return error_invalid_params("Audio bus '%s' already exists at index %d" % [bus_name, i])

	var at_position := optional_int(params, "at_position", -1)
	AudioServer.add_bus(at_position)
	var idx := AudioServer.bus_count - 1 if at_position < 0 else at_position
	AudioServer.set_bus_name(idx, bus_name)

	if params.has("volume_db"):
		AudioServer.set_bus_volume_db(idx, float(params["volume_db"]))
	var send := optional_string(params, "send", "")
	if not send.is_empty():
		AudioServer.set_bus_send(idx, send)
	if params.has("solo"):
		AudioServer.set_bus_solo(idx, bool(params["solo"]))
	if params.has("mute"):
		AudioServer.set_bus_mute(idx, bool(params["mute"]))

	return success({"name": bus_name, "index": idx, "bus_count": AudioServer.bus_count})


func _set_bus(params: Dictionary) -> Dictionary:
	var r := require_string(params, "name")
	if r[1] != null:
		return r[1]
	var bus_name: String = r[0]

	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return error_not_found("Audio bus '%s'" % bus_name)

	var changes := 0
	if params.has("volume_db"):
		AudioServer.set_bus_volume_db(idx, float(params["volume_db"]))
		changes += 1
	if params.has("solo"):
		AudioServer.set_bus_solo(idx, bool(params["solo"]))
		changes += 1
	if params.has("mute"):
		AudioServer.set_bus_mute(idx, bool(params["mute"]))
		changes += 1
	if params.has("bypass_effects"):
		AudioServer.set_bus_bypass_effects(idx, bool(params["bypass_effects"]))
		changes += 1
	var send := optional_string(params, "send", "")
	if not send.is_empty():
		AudioServer.set_bus_send(idx, send)
		changes += 1
	if params.has("rename"):
		var new_name := str(params["rename"])
		AudioServer.set_bus_name(idx, new_name)
		bus_name = new_name
		changes += 1

	return success({"name": bus_name, "index": idx, "changes": changes})


func _add_bus_effect(params: Dictionary) -> Dictionary:
	var rb := require_string(params, "bus")
	if rb[1] != null:
		return rb[1]
	var bus_name: String = rb[0]

	var re := require_string(params, "effect_type")
	if re[1] != null:
		return re[1]
	var effect_type: String = re[0]

	var bus_idx := AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		return error_not_found("Audio bus '%s'" % bus_name)

	var ep: Dictionary = params.get("params", {})
	var effect: AudioEffect = null

	match effect_type.to_lower():
		"reverb":
			var e := AudioEffectReverb.new()
			if ep.has("room_size"): e.room_size = float(ep["room_size"])
			if ep.has("damping"): e.damping = float(ep["damping"])
			if ep.has("wet"): e.wet = float(ep["wet"])
			if ep.has("dry"): e.dry = float(ep["dry"])
			if ep.has("spread"): e.spread = float(ep["spread"])
			effect = e
		"chorus":
			var e := AudioEffectChorus.new()
			if ep.has("voice_count"): e.voice_count = int(ep["voice_count"])
			if ep.has("dry"): e.dry = float(ep["dry"])
			if ep.has("wet"): e.wet = float(ep["wet"])
			effect = e
		"delay":
			var e := AudioEffectDelay.new()
			if ep.has("tap1_active"): e.tap1_active = bool(ep["tap1_active"])
			if ep.has("tap1_delay_ms"): e.tap1_delay_ms = float(ep["tap1_delay_ms"])
			if ep.has("tap1_level_db"): e.tap1_level_db = float(ep["tap1_level_db"])
			if ep.has("tap2_active"): e.tap2_active = bool(ep["tap2_active"])
			if ep.has("tap2_delay_ms"): e.tap2_delay_ms = float(ep["tap2_delay_ms"])
			if ep.has("tap2_level_db"): e.tap2_level_db = float(ep["tap2_level_db"])
			effect = e
		"compressor":
			var e := AudioEffectCompressor.new()
			if ep.has("threshold"): e.threshold = float(ep["threshold"])
			if ep.has("ratio"): e.ratio = float(ep["ratio"])
			if ep.has("attack_us"): e.attack_us = float(ep["attack_us"])
			if ep.has("release_ms"): e.release_ms = float(ep["release_ms"])
			if ep.has("gain"): e.gain = float(ep["gain"])
			if ep.has("mix"): e.mix = float(ep["mix"])
			if ep.has("sidechain"): e.sidechain = str(ep["sidechain"])
			effect = e
		"limiter":
			var e := AudioEffectLimiter.new()
			if ep.has("ceiling_db"): e.ceiling_db = float(ep["ceiling_db"])
			if ep.has("threshold_db"): e.threshold_db = float(ep["threshold_db"])
			if ep.has("soft_clip_db"): e.soft_clip_db = float(ep["soft_clip_db"])
			if ep.has("soft_clip_ratio"): e.soft_clip_ratio = float(ep["soft_clip_ratio"])
			effect = e
		"phaser":
			var e := AudioEffectPhaser.new()
			if ep.has("range_min_hz"): e.range_min_hz = float(ep["range_min_hz"])
			if ep.has("range_max_hz"): e.range_max_hz = float(ep["range_max_hz"])
			if ep.has("rate_hz"): e.rate_hz = float(ep["rate_hz"])
			if ep.has("feedback"): e.feedback = float(ep["feedback"])
			if ep.has("depth"): e.depth = float(ep["depth"])
			effect = e
		"distortion":
			var e := AudioEffectDistortion.new()
			if ep.has("mode"): e.mode = int(ep["mode"]) as AudioEffectDistortion.Mode
			if ep.has("pre_gain"): e.pre_gain = float(ep["pre_gain"])
			if ep.has("post_gain"): e.post_gain = float(ep["post_gain"])
			if ep.has("keep_hf_hz"): e.keep_hf_hz = float(ep["keep_hf_hz"])
			if ep.has("drive"): e.drive = float(ep["drive"])
			effect = e
		"lowpassfilter", "lowpass":
			var e := AudioEffectLowPassFilter.new()
			if ep.has("cutoff_hz"): e.cutoff_hz = float(ep["cutoff_hz"])
			if ep.has("resonance"): e.resonance = float(ep["resonance"])
			effect = e
		"highpassfilter", "highpass":
			var e := AudioEffectHighPassFilter.new()
			if ep.has("cutoff_hz"): e.cutoff_hz = float(ep["cutoff_hz"])
			if ep.has("resonance"): e.resonance = float(ep["resonance"])
			effect = e
		"bandpassfilter", "bandpass":
			var e := AudioEffectBandPassFilter.new()
			if ep.has("cutoff_hz"): e.cutoff_hz = float(ep["cutoff_hz"])
			if ep.has("resonance"): e.resonance = float(ep["resonance"])
			effect = e
		"amplify":
			var e := AudioEffectAmplify.new()
			if ep.has("volume_db"): e.volume_db = float(ep["volume_db"])
			effect = e
		"eq":
			effect = AudioEffectEQ.new()
		"pitchshift":
			var e := AudioEffectPitchShift.new()
			if ep.has("pitch_scale"): e.pitch_scale = float(ep["pitch_scale"])
			if ep.has("oversampling"): e.oversampling = int(ep["oversampling"])
			effect = e
		"hardlimiter":
			var e := AudioEffectHardLimiter.new()
			if ep.has("pre_gain_db"): e.pre_gain_db = float(ep["pre_gain_db"])
			if ep.has("ceiling_db"): e.ceiling_db = float(ep["ceiling_db"])
			if ep.has("release"): e.release = float(ep["release"])
			effect = e
		"spectrum", "spectrumanalyzer":
			var e := AudioEffectSpectrumAnalyzer.new()
			if ep.has("buffer_length"): e.buffer_length = float(ep["buffer_length"])
			if ep.has("fft_size"): e.fft_size = int(ep["fft_size"]) as AudioEffectSpectrumAnalyzer.FFTSize
			effect = e
		"record":
			effect = AudioEffectRecord.new()
		"capture":
			var e := AudioEffectCapture.new()
			if ep.has("buffer_length"): e.buffer_length = float(ep["buffer_length"])
			effect = e
		_:
			return error_invalid_params("Unknown effect type: '%s'. Valid types: reverb, chorus, delay, compressor, limiter, phaser, distortion, lowpassfilter, highpassfilter, bandpassfilter, amplify, eq, pitchshift, hardlimiter, spectrum, record, capture" % effect_type)

	var at_position := optional_int(params, "at_position", -1)
	AudioServer.add_bus_effect(bus_idx, effect, at_position)
	var effect_idx := AudioServer.get_bus_effect_count(bus_idx) - 1 if at_position < 0 else at_position
	return success({"bus": bus_name, "bus_index": bus_idx, "effect_type": effect.get_class(), "effect_index": effect_idx})


func _add_player(params: Dictionary) -> Dictionary:
	var rp := require_string(params, "node_path")
	if rp[1] != null:
		return rp[1]
	var node_path: String = rp[0]

	var rn := require_string(params, "name")
	if rn[1] != null:
		return rn[1]
	var player_name: String = rn[0]

	var player_type := optional_string(params, "type", "AudioStreamPlayer")
	var valid_types := ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]
	if player_type not in valid_types:
		return error_invalid_params("Invalid player type '%s'. Valid: %s" % [player_type, ", ".join(valid_types)])

	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var parent := find_node_by_path(node_path)
	if parent == null:
		return error_not_found("Node at '%s'" % node_path)

	var player: Node = null
	match player_type:
		"AudioStreamPlayer":
			player = AudioStreamPlayer.new()
		"AudioStreamPlayer2D":
			player = AudioStreamPlayer2D.new()
		"AudioStreamPlayer3D":
			player = AudioStreamPlayer3D.new()
	player.name = player_name

	var stream_path := optional_string(params, "stream", "")
	if not stream_path.is_empty():
		if not ResourceLoader.exists(stream_path):
			player.queue_free()
			return error_not_found("Audio stream at '%s'" % stream_path)
		var stream := ResourceLoader.load(stream_path)
		if not stream is AudioStream:
			player.queue_free()
			return error_invalid_params("Resource at '%s' is not an AudioStream" % stream_path)
		player.set("stream", stream)

	if params.has("volume_db"):
		player.set("volume_db", float(params["volume_db"]))
	var bus := optional_string(params, "bus", "")
	if not bus.is_empty():
		player.set("bus", bus)
	if params.has("autoplay"):
		player.set("autoplay", bool(params["autoplay"]))

	if player is AudioStreamPlayer2D:
		var p2 := player as AudioStreamPlayer2D
		if params.has("max_distance"):
			p2.max_distance = float(params["max_distance"])
		if params.has("attenuation"):
			p2.attenuation = float(params["attenuation"])
	elif player is AudioStreamPlayer3D:
		var p3 := player as AudioStreamPlayer3D
		if params.has("max_distance"):
			p3.max_distance = float(params["max_distance"])
		if params.has("attenuation_model"):
			p3.attenuation_model = int(params["attenuation_model"]) as AudioStreamPlayer3D.AttenuationModel
		if params.has("unit_size"):
			p3.unit_size = float(params["unit_size"])

	add_child_with_undo(parent, player, root, "MCP: Add audio player")

	return success({
		"name": player_name,
		"type": player_type,
		"parent": node_path,
		"stream": stream_path,
		"bus": player.get("bus"),
		"volume_db": player.get("volume_db"),
		"autoplay": player.get("autoplay"),
	})


func _get_info(params: Dictionary) -> Dictionary:
	var r := require_string(params, "node_path")
	if r[1] != null:
		return r[1]
	var node_path: String = r[0]

	var node := find_node_by_path(node_path)
	if node == null:
		return error_not_found("Node at '%s'" % node_path)

	var players: Array[Dictionary] = []
	_collect_players(node, players)
	return success({"node_path": node_path, "audio_player_count": players.size(), "players": players})


func _collect_players(node: Node, result: Array[Dictionary]) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		var info := {
			"name": String(node.name),
			"path": str(get_edited_root().get_path_to(node)),
			"type": node.get_class(),
			"volume_db": node.get("volume_db"),
			"bus": node.get("bus"),
			"autoplay": node.get("autoplay"),
			"playing": node.get("playing"),
			"stream": "",
		}
		var stream = node.get("stream")
		if stream != null and stream is AudioStream:
			info["stream"] = (stream as AudioStream).resource_path
		if node is AudioStreamPlayer2D:
			info["max_distance"] = (node as AudioStreamPlayer2D).max_distance
			info["attenuation"] = (node as AudioStreamPlayer2D).attenuation
		elif node is AudioStreamPlayer3D:
			info["max_distance"] = (node as AudioStreamPlayer3D).max_distance
			info["attenuation_model"] = (node as AudioStreamPlayer3D).attenuation_model
			info["unit_size"] = (node as AudioStreamPlayer3D).unit_size
		result.append(info)

	for child in node.get_children():
		_collect_players(child, result)


func get_command_docs() -> Dictionary:
	return {
		"audio.get_bus_layout": {
			"description": "Report the full AudioServer bus layout: each bus's name, volume, solo/mute/bypass, send, and effect chain with per-effect params.",
			"params": [],
		},
		"audio.add_bus": {
			"description": "Add an audio bus (persists default_bus_layout.tres). Errors if the name already exists.",
			"params": [
				doc_param("name", "String", true, "New bus name."),
				doc_param("at_position", "int", false, "Insert index (default -1 = append)."),
				doc_param("volume_db", "float", false, "Initial bus volume in dB."),
				doc_param("send", "String", false, "Bus this bus sends to."),
				doc_param("solo", "bool", false, "Solo the bus."),
				doc_param("mute", "bool", false, "Mute the bus."),
			],
		},
		"audio.set_bus": {
			"description": "Change an existing bus's volume, solo/mute/bypass, send, or name.",
			"params": [
				doc_param("name", "String", true, "Bus to change (by current name)."),
				doc_param("volume_db", "float", false, "New volume in dB."),
				doc_param("solo", "bool", false, "Solo state."),
				doc_param("mute", "bool", false, "Mute state."),
				doc_param("bypass_effects", "bool", false, "Bypass the bus's effects."),
				doc_param("send", "String", false, "Bus to send to."),
				doc_param("rename", "String", false, "New name for the bus."),
			],
		},
		"audio.add_bus_effect": {
			"description": "Add an effect to a bus. Effect-specific settings go in --params (keys depend on the type).",
			"params": [
				doc_param("bus", "String", true, "Bus to add the effect to (by name)."),
				doc_param("effect_type", "String", true, "reverb, chorus, delay, compressor, limiter, phaser, distortion, lowpassfilter, highpassfilter, bandpassfilter, amplify, eq, pitchshift, hardlimiter, spectrum, record, or capture."),
				doc_param("params", "Dictionary", false, "Effect-specific settings (e.g. reverb {room_size, damping, wet, dry, spread})."),
				doc_param("at_position", "int", false, "Insert index in the effect chain (default -1 = append)."),
			],
		},
		"audio.add_player": {
			"description": "Add an AudioStreamPlayer / 2D / 3D under --node-path (the parent), optionally with a stream and playback settings. Undoable.",
			"params": [
				doc_param("node_path", "NodePath", true, "Parent node to add the player under."),
				doc_param("name", "String", true, "Name for the new player."),
				doc_param("type", "String", false, "AudioStreamPlayer (default), AudioStreamPlayer2D, or AudioStreamPlayer3D."),
				doc_param("stream", "String", false, "AudioStream resource path to assign."),
				doc_param("volume_db", "float", false, "Player volume in dB."),
				doc_param("bus", "String", false, "Output bus name."),
				doc_param("autoplay", "bool", false, "Autoplay on ready."),
				doc_param("max_distance", "float", false, "Max audible distance (2D/3D)."),
				doc_param("attenuation", "float", false, "Distance attenuation (2D)."),
				doc_param("attenuation_model", "int", false, "Attenuation model enum (3D)."),
				doc_param("unit_size", "float", false, "Unit size (3D)."),
			],
		},
		"audio.get_info": {
			"description": "List the audio players in a node's subtree with their stream, bus, volume, autoplay, and playing state.",
			"params": [
				doc_param("node_path", "NodePath", true, "Root node to search under."),
			],
		},
	}
