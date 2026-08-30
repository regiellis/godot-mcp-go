extends Node

## Buses, sound banks, and the one-shot player pool.
##
## Autoload `Audio`. One-shot players are children of this node rather than of
## the calling scene, so a click that also changes scenes does not free its own
## sound halfway through playback.

const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"
const UI_BUS := &"UI"
const MASTER_BUS := &"Master"

## Buses this director owns, each created sending into Master when absent.
const CHILD_BUSES: Array[StringName] = [MUSIC_BUS, SFX_BUS, UI_BUS]

## Bank source files, spelled out rather than discovered. A directory scan finds
## these in the editor and finds nothing in an exported build.
const BANK_PATHS: Dictionary = {
	&"click": [
		"res://assets/audio/sfx/click/click_001.ogg",
		"res://assets/audio/sfx/click/click_002.ogg",
		"res://assets/audio/sfx/click/click_003.ogg",
		"res://assets/audio/sfx/click/click_004.ogg",
	],
	&"confirm": [
		"res://assets/audio/sfx/confirm/confirmation_001.ogg",
		"res://assets/audio/sfx/confirm/confirmation_002.ogg",
		"res://assets/audio/sfx/confirm/confirmation_003.ogg",
	],
	&"error": [
		"res://assets/audio/sfx/error/error_001.ogg",
		"res://assets/audio/sfx/error/error_002.ogg",
		"res://assets/audio/sfx/error/error_003.ogg",
	],
	&"flip": [
		"res://assets/audio/sfx/pickup/pluck_001.ogg",
		"res://assets/audio/sfx/pickup/pluck_002.ogg",
	],
	&"pass": [
		"res://assets/audio/sfx/hit_light/impactGeneric_light_000.ogg",
		"res://assets/audio/sfx/hit_light/impactGeneric_light_001.ogg",
		"res://assets/audio/sfx/hit_light/impactGeneric_light_002.ogg",
		"res://assets/audio/sfx/hit_light/impactGeneric_light_003.ogg",
	],
	&"win": [
		"res://assets/audio/sfx/confirm/confirmation_001.ogg",
		"res://assets/audio/sfx/confirm/confirmation_002.ogg",
		"res://assets/audio/sfx/confirm/confirmation_003.ogg",
	],
	&"lose": [
		"res://assets/audio/sfx/error/error_001.ogg",
		"res://assets/audio/sfx/error/error_002.ogg",
		"res://assets/audio/sfx/error/error_003.ogg",
	],
	&"start": [
		"res://assets/audio/sfx/hit_heavy/impactPunch_heavy_000.ogg",
		"res://assets/audio/sfx/hit_heavy/impactPunch_heavy_001.ogg",
		"res://assets/audio/sfx/hit_heavy/impactPunch_heavy_002.ogg",
		"res://assets/audio/sfx/hit_heavy/impactPunch_heavy_003.ogg",
	],
}

## Chrome sounds sit on UI so a player can pull game volume without going mute.
const BANK_BUS: Dictionary = {
	&"click": UI_BUS,
	&"confirm": UI_BUS,
	&"error": UI_BUS,
	&"flip": SFX_BUS,
	&"pass": SFX_BUS,
	&"win": SFX_BUS,
	&"lose": SFX_BUS,
	&"start": SFX_BUS,
}

## No music has been authored for the sample yet. music() stays a no-op until a
## path lands here, rather than erroring on every screen entry.
const MUSIC_PATHS: Dictionary = {}

const MAX_PLAYERS := 24
const PITCH_MIN := 0.92
const PITCH_MAX := 1.08

## Two copies of one sample starting on the same frame sum to double amplitude
## and clip, so a bank refuses a retrigger inside this window.
const DEDUPE_MS := 25

## Below this the bus is muted outright. linear_to_db of a very small linear
## value is a large negative number, not -inf, and still mixes.
const MUTE_BELOW := 0.001

var _banks: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _last_played: Dictionary = {}
var _music_player: AudioStreamPlayer = null
var _music_id: StringName = &""
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# The pause menu runs on a paused tree. Without this the whole autoload
	# pauses with it and every hover and press in that menu is silent.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_ensure_buses()
	_build_banks()
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "MusicPlayer"
	_music_player.bus = String(MUSIC_BUS)
	add_child(_music_player)
	_pull_settings()


## Plays one shot from `bank`, jittered in pitch so a repeat does not read as a
## loop. An unknown or empty bank is silent, never an error.
func play(bank: StringName, volume_offset_db: float = 0.0) -> void:
	_fire(bank, _rng.randf_range(PITCH_MIN, PITCH_MAX), volume_offset_db)


func play_pitched(bank: StringName, pitch: float) -> void:
	_fire(bank, maxf(pitch, 0.01), 0.0)


## Asking for the track already playing is a no-op, so re-entering a screen does
## not restart its music from the top.
func music(id: StringName, fade: float = 0.9) -> void:
	if id == _music_id:
		return
	if not MUSIC_PATHS.has(id):
		return
	var path: String = MUSIC_PATHS[id]
	if not ResourceLoader.exists(path):
		push_warning("Audio.music: %s is missing at %s." % [String(id), path])
		return
	var stream: Resource = load(path)
	if not (stream is AudioStream):
		return
	_music_id = id
	_music_player.stop()
	_music_player.stream = stream
	_music_player.volume_db = -60.0
	_music_player.play()
	var tween := create_tween()
	tween.tween_property(_music_player, "volume_db", 0.0, maxf(fade, 0.01))


func stop_music(fade: float = 0.6) -> void:
	_music_id = &""
	if _music_player == null or not _music_player.playing:
		return
	var tween := create_tween()
	tween.tween_property(_music_player, "volume_db", -60.0, maxf(fade, 0.01))
	tween.tween_callback(_music_player.stop)


## `linear` is 0..1. Volume is decibels everywhere below this line.
func set_linear(bus: StringName, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var value := clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_mute(index, value < MUTE_BELOW)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, MUTE_BELOW)))


func _ensure_buses() -> void:
	for bus: StringName in CHILD_BUSES:
		if AudioServer.get_bus_index(bus) >= 0:
			continue
		var index := AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, String(bus))
		AudioServer.set_bus_send(index, String(MASTER_BUS))


func _build_banks() -> void:
	for bank: StringName in BANK_PATHS:
		var randomizer := AudioStreamRandomizer.new()
		# No-repeats is the anti-immediate-repeat rule. Pitch is jittered on the
		# player instead, because the randomizer's random_pitch is a symmetric
		# multiplier and the design asks for a plain 0.92..1.08 range.
		randomizer.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
		randomizer.random_pitch = 1.0
		var paths: Array = BANK_PATHS[bank]
		for path: String in paths:
			if not ResourceLoader.exists(path):
				continue
			var stream: Resource = load(path)
			if stream is AudioStream:
				randomizer.add_stream(-1, stream)
		if randomizer.streams_count == 0:
			push_warning("Audio bank %s has no files yet and stays silent." % String(bank))
			continue
		_banks[bank] = randomizer


func _pull_settings() -> void:
	var settings := get_node_or_null(^"/root/Settings")
	if settings == null:
		return
	set_linear(MASTER_BUS, float(settings.get_value("audio/master", 0.8)))
	set_linear(MUSIC_BUS, float(settings.get_value("audio/music", 0.7)))
	set_linear(SFX_BUS, float(settings.get_value("audio/sfx", 0.9)))
	set_linear(UI_BUS, float(settings.get_value("audio/sfx", 0.9)))


func _fire(bank: StringName, pitch: float, volume_offset_db: float) -> void:
	if not _banks.has(bank):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_played.get(bank, -DEDUPE_MS)) < DEDUPE_MS:
		return
	_last_played[bank] = now
	var player := _claim_player(_banks[bank], bank)
	player.pitch_scale = pitch
	player.volume_db = volume_offset_db
	player.play()


## `_players` is held in start order, so the head is the oldest sound and the
## right one to steal when the pool is full.
func _claim_player(stream: AudioStream, bank: StringName) -> AudioStreamPlayer:
	var chosen: AudioStreamPlayer = null
	for player in _players:
		if not player.playing:
			chosen = player
			break
	if chosen == null:
		if _players.size() < MAX_PLAYERS:
			chosen = AudioStreamPlayer.new()
			chosen.name = "Shot%d" % _players.size()
			add_child(chosen)
			_players.append(chosen)
		else:
			chosen = _players[0]
			chosen.stop()
	_players.erase(chosen)
	_players.append(chosen)
	chosen.bus = String(BANK_BUS.get(bank, SFX_BUS))
	chosen.stream = stream
	return chosen
