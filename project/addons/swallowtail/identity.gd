extends RefCounted

static func env(name: String) -> String:
	var value := OS.get_environment(name)
	if not value.is_empty():
		return value
	return OS.get_environment(name.replace("SWALLOWTAIL_", "GODOT_MCP_"))

static func setting(name: String, fallback: Variant) -> Variant:
	if ProjectSettings.has_setting(name):
		return ProjectSettings.get_setting(name)
	return ProjectSettings.get_setting(name.replace("swallowtail/", "godot_mcp/"), fallback)
