extends Node

## Persistent player preferences, stats, and the live application of both.
##
## Autoload `Settings`. Registered first, because every other service reads it
## on boot. Every setter applies the value to the running game and flushes the
## config file in the same call: a game killed from the taskbar never gets a
## chance to save on exit, so there is no "save on quit" to rely on.

signal changed(key: String, value: Variant)

const CONFIG_PATH := "user://reversi.cfg"

## Key is "section/name", matching the ConfigFile layout it round-trips through.
const DEFAULTS: Dictionary = {
	"audio/master": 0.8,
	"audio/music": 0.7,
	"audio/sfx": 0.9,
	"video/fullscreen": false,
	"a11y/reduced_motion": false,
	"a11y/high_contrast": false,
	"game/juice": true,
	"game/show_hints": true,
	"game/difficulty": 1,
	"game/seen_intro": false,
	"stats/wins": 0,
	"stats/losses": 0,
	"stats/draws": 0,
}

const STAT_KEYS: PackedStringArray = ["stats/wins", "stats/losses", "stats/draws"]

var _values: Dictionary = {}

## True while the config file is being restored. Applying a restored value must
## not flush it straight back out, and must not fire `changed` per key.
var _loading := false


func _ready() -> void:
	_loading = true
	_load()
	_loading = false
	# Only the display is applied here. Audio and Juice do not exist yet at this
	# point in the autoload order, so each pulls its own values on its _ready.
	_apply_fullscreen(bool(get_value("video/fullscreen", false)))


func get_value(key: String, fallback: Variant) -> Variant:
	if not _values.has(key):
		return fallback
	return _values[key]


func set_value(key: String, value: Variant) -> void:
	if _values.has(key) and _values[key] == value:
		return
	_values[key] = value
	_apply(key, value)
	if _loading:
		return
	save_now()
	changed.emit(key, value)


func save_now() -> void:
	var config := ConfigFile.new()
	for key: String in _values:
		var parts := key.split("/", false, 1)
		if parts.size() != 2:
			continue
		config.set_value(parts[0], parts[1], _values[key])
	var err := config.save(CONFIG_PATH)
	if err != OK:
		push_warning("Settings could not write %s (error %d)." % [CONFIG_PATH, err])


func reset_stats() -> void:
	for key: String in STAT_KEYS:
		set_value(key, 0)


func bump_stat(key: String) -> void:
	if not DEFAULTS.has(key):
		push_warning("Settings.bump_stat called with unknown key '%s'." % key)
		return
	set_value(key, int(get_value(key, 0)) + 1)


func _load() -> void:
	_values = DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		# No file yet, or an unreadable one. Defaults stand and the first setter
		# writes a fresh file.
		return
	for key: String in DEFAULTS:
		var parts := key.split("/", false, 1)
		if parts.size() != 2:
			continue
		if not config.has_section_key(parts[0], parts[1]):
			continue
		var stored: Variant = config.get_value(parts[0], parts[1])
		# A hand-edited file can hold the wrong type. Keep the default rather
		# than letting a String reach DisplayServer or a bus volume.
		if typeof(stored) != typeof(DEFAULTS[key]):
			continue
		_values[key] = stored


func _apply(key: String, value: Variant) -> void:
	match key:
		"audio/master", "audio/music", "audio/sfx":
			_apply_audio()
		"video/fullscreen":
			_apply_fullscreen(bool(value))
		"game/juice", "a11y/reduced_motion":
			_apply_juice()


func _apply_audio() -> void:
	var audio := get_node_or_null(^"/root/Audio")
	if audio == null:
		return
	audio.set_linear(&"Master", float(get_value("audio/master", 0.8)))
	audio.set_linear(&"Music", float(get_value("audio/music", 0.7)))
	audio.set_linear(&"SFX", float(get_value("audio/sfx", 0.9)))
	audio.set_linear(&"UI", float(get_value("audio/sfx", 0.9)))


func _apply_fullscreen(on: bool) -> void:
	var mode := (
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
	)
	DisplayServer.window_set_mode(mode)


func _apply_juice() -> void:
	var juice := get_node_or_null(^"/root/Juice")
	if juice == null:
		return
	var wanted := (
		bool(get_value("game/juice", true))
		and not bool(get_value("a11y/reduced_motion", false))
	)
	juice.enabled = wanted
