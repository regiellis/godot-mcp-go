@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Localization — translation CSVs, the project translation list, and locale. Godot imports a
## CSV (keys + one column per locale) into per-locale .translation resources; you register those
## in ProjectSettings 'internationalization/locale/translations'. No prior command touched any of
## this. CSV writing + the settings array + TranslationServer locale, all here.

const SETTING_TRANSLATIONS := "internationalization/locale/translations"
const SETTING_FALLBACK := "internationalization/locale/fallback"


func get_commands() -> Dictionary:
	return {
		"localization.create_csv": _create_csv,
		"localization.list": _list,
		"localization.add_translation": _add_translation,
		"localization.remove_translation": _remove_translation,
		"localization.set_locale": _set_locale,
	}


func _translations_array() -> PackedStringArray:
	var v: Variant = ProjectSettings.get_setting(SETTING_TRANSLATIONS, PackedStringArray())
	if v is PackedStringArray:
		return v
	if v is Array:
		var out := PackedStringArray()
		for e in v:
			out.append(str(e))
		return out
	return PackedStringArray()


# --- create_csv -------------------------------------------------------------

## Write a translation CSV: header `keys,<locale1>,<locale2>,…` then one row per key.
## rows: {"KEY": {"en":"Hello","es":"Hola"}, …}. Godot auto-imports it to .translation files.
func _create_csv(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not path.ends_with(".csv"):
		return error_invalid_params("path must end in .csv")
	var guard := guard_project_path(path)
	if not guard.is_empty():
		return guard

	var locales := []
	var lv: Variant = params.get("locales")
	if lv is String:
		var parsed: Variant = JSON.parse_string(lv)
		if parsed is Array:
			locales = parsed
	elif lv is Array:
		locales = lv
	if locales.is_empty():
		return error_invalid_params("Provide 'locales' (e.g. '[\"en\",\"es\"]')")

	var rr := require_dict(params, "rows")
	if rr[1] != null:
		return rr[1]
	var rows: Dictionary = rr[0]

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return error_internal("Cannot create CSV: %s" % error_string(FileAccess.get_open_error()))
	# Header
	var header := PackedStringArray(["keys"])
	for loc in locales:
		header.append(str(loc))
	f.store_csv_line(header)
	# Rows
	for key in rows:
		var line := PackedStringArray([str(key)])
		var cell: Variant = rows[key]
		for loc in locales:
			line.append(str(cell.get(str(loc), "")) if cell is Dictionary else "")
		f.store_csv_line(line)
	f.close()

	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.get_resource_filesystem().scan()

	return success({"path": path, "locales": locales, "keys": rows.keys(), "note": "Imported to per-locale .translation files; register them with localization.add_translation."})


# --- list -------------------------------------------------------------------

func _list(_params: Dictionary) -> Dictionary:
	var translations := _translations_array()
	return success({
		"translations": translations,
		"locale": TranslationServer.get_locale(),
		"fallback": ProjectSettings.get_setting(SETTING_FALLBACK, "en"),
		"loaded_locales": TranslationServer.get_loaded_locales(),
	})


# --- add / remove translation ----------------------------------------------

func _add_translation(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	if not ResourceLoader.exists(path):
		return error_not_found("Translation '%s'" % path, "Import a CSV/PO first (localization.create_csv), then register the generated .translation")
	var arr := _translations_array()
	if path in arr:
		return success({"path": path, "already_present": true, "translations": arr})
	arr.append(path)
	ProjectSettings.set_setting(SETTING_TRANSLATIONS, arr)
	ProjectSettings.save()
	return success({"path": path, "added": true, "translations": arr})


func _remove_translation(params: Dictionary) -> Dictionary:
	var r := require_string(params, "path")
	if r[1] != null:
		return r[1]
	var path: String = r[0]
	var arr := _translations_array()
	var idx := arr.find(path)
	if idx == -1:
		return success({"path": path, "was_present": false})
	arr.remove_at(idx)
	ProjectSettings.set_setting(SETTING_TRANSLATIONS, arr if not arr.is_empty() else PackedStringArray())
	ProjectSettings.save()
	return success({"path": path, "removed": true, "translations": arr})


# --- set_locale -------------------------------------------------------------

func _set_locale(params: Dictionary) -> Dictionary:
	var r := require_string(params, "locale")
	if r[1] != null:
		return r[1]
	var locale: String = r[0]
	TranslationServer.set_locale(locale)
	var set_default := optional_bool(params, "set_default", false)
	if set_default:
		ProjectSettings.set_setting(SETTING_FALLBACK, locale)
		ProjectSettings.save()
	return success({"locale": TranslationServer.get_locale(), "set_as_project_default": set_default})


func get_command_docs() -> Dictionary:
	return {
		"localization.create_csv": {
			"description": "Write a translation CSV (header 'keys,<locale>,...' then one row per key) and trigger its import to per-locale .translation files. Register those with localization.add_translation. Writes project files.",
			"params": [
				doc_param("path", "String", true, "Output CSV path under the project; must end in .csv."),
				doc_param("locales", "Array", true, "JSON array of locale codes, e.g. '[\"en\",\"es\"]'."),
				doc_param("rows", "Dictionary", true, "{KEY: {locale: text}} map, one entry per translation key."),
			],
		},
		"localization.list": {
			"description": "List the project's registered translations, current locale, fallback locale, and loaded locales.",
			"params": [],
		},
		"localization.add_translation": {
			"description": "Register a .translation resource in the project's translation list (no-op if already present). The resource must exist; import a CSV first.",
			"params": [
				doc_param("path", "String", true, "Path to the .translation resource to register."),
			],
		},
		"localization.remove_translation": {
			"description": "Remove a .translation from the project's registered translation list.",
			"params": [
				doc_param("path", "String", true, "Path of the registered .translation to remove."),
			],
		},
		"localization.set_locale": {
			"description": "Set the TranslationServer's active locale, and optionally make it the project's fallback/default locale.",
			"params": [
				doc_param("locale", "String", true, "Locale code to switch to, e.g. 'es'."),
				doc_param("set_default", "bool", false, "Also write it as the project fallback locale (default false)."),
			],
		},
	}
