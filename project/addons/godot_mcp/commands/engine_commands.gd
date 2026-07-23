@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Introspect the running engine via ClassDB so the agent can discover the real
## API surface of THIS Godot build (e.g. 4.7-only members) instead of relying on
## possibly-stale training knowledge.


func get_commands() -> Dictionary:
	return {
		"engine.version": _version,
		"engine.classes": _classes,
		"engine.class_info": _class_info,
		"engine.defaults": _defaults,
		"engine.search": _search,
		"engine.singletons": _singletons,
		"engine.script_classes": _script_classes,
		"engine.commands": _list_commands,
	}


func _version(_params: Dictionary) -> Dictionary:
	return success({"version": Engine.get_version_info(), "platform": OS.get_name()})


## The MCP's own tool surface: every registered dotted method, plus a
## group -> [command] map so consumers get the catalog by category without
## splitting prefixes. Backs the CLI's nested help (godot-mcp <group> --help,
## godot-mcp help all). --group narrows both to one group.
func _list_commands(params: Dictionary) -> Dictionary:
	var group := optional_string(params, "group", "")
	var want_docs := optional_bool(params, "docs", false)
	var router := get_parent()
	if router == null or not router.has_method("get_available_methods"):
		return error_internal("Command router unavailable")
	var methods: Array = router.get_available_methods()
	methods.sort()
	var groups: Dictionary = {}  # sorted methods -> insertion-ordered (sorted) keys
	for m: String in methods:
		var g := m.get_slice(".", 0)
		if not groups.has(g):
			groups[g] = []
		(groups[g] as Array).append(m.get_slice(".", 1))
	if not group.is_empty():
		if not groups.has(group):
			var names: Array = groups.keys()
			return error_not_found("Group '%s'" % group, "Groups: %s" % ", ".join(names))
		var filtered: Array = []
		for m: String in methods:
			if m.get_slice(".", 0) == group:
				filtered.append(m)
		methods = filtered
		groups = {group: groups[group]}
		want_docs = true  # --group always attaches that group's param docs
	var result := {"methods": methods, "count": methods.size(), "groups": groups}
	# The unfiltered catalog stays lean by default; --group or --docs adds the
	# per-command param metadata for the methods in view that have it.
	if want_docs and router.has_method("get_command_docs"):
		var all_docs: Dictionary = router.get_command_docs()
		var docs_out: Dictionary = {}
		for m: String in methods:
			if all_docs.has(m):
				docs_out[m] = all_docs[m]
		result["docs"] = docs_out
	return success(result)


func _classes(params: Dictionary) -> Dictionary:
	var inherits := optional_string(params, "inherits", "")
	var filter := optional_string(params, "filter", "").to_lower()
	var instantiable_only := optional_bool(params, "instantiable_only", false)
	var limit := optional_int(params, "limit", 200)

	var source: PackedStringArray
	if not inherits.is_empty():
		if not ClassDB.class_exists(inherits):
			return error_not_found("Class '%s'" % inherits)
		source = ClassDB.get_inheriters_from_class(inherits)
	else:
		source = ClassDB.get_class_list()

	var names: Array = []
	for c: String in source:
		if not filter.is_empty() and not c.to_lower().contains(filter):
			continue
		if instantiable_only and not ClassDB.can_instantiate(c):
			continue
		names.append(c)
	names.sort()

	var total := names.size()
	var truncated := limit > 0 and total > limit
	if truncated:
		names = names.slice(0, limit)
	return success({"classes": names, "count": names.size(), "total_matched": total, "truncated": truncated})


func _class_info(params: Dictionary) -> Dictionary:
	var r := require_string(params, "class")
	if r[1] != null:
		return r[1]
	var cls: String = r[0]
	if ClassDB.class_exists(cls):
		return _classdb_info(cls, params)
	# Not a built-in/GDExtension class — try a global class_name script (addons).
	var entry := _global_class_entry(cls)
	if not entry.is_empty():
		return _script_class_info(cls, entry, params)
	return error_not_found("Class '%s'" % cls, "Use engine.classes / engine.script_classes to list available classes")


func _classdb_info(cls: String, params: Dictionary) -> Dictionary:
	# Default to this class's OWN members — that's where version-new API lives.
	var no_inherit := not optional_bool(params, "inherited", false)
	var filter := optional_string(params, "filter", "").to_lower()

	var properties: Array = []
	for p in ClassDB.class_get_property_list(cls, no_inherit):
		if p["type"] == TYPE_NIL:  # group/category separators
			continue
		var name: String = p["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		properties.append({"name": name, "type": _type_name(p["type"], p.get("class_name", ""))})

	var methods: Array = []
	for m in ClassDB.class_get_method_list(cls, no_inherit):
		var name: String = m["name"]
		if name.begins_with("_"):
			continue
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		methods.append(_method_brief(m))

	var signals: Array = []
	for s in ClassDB.class_get_signal_list(cls, no_inherit):
		var name: String = s["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		var args: Array = []
		for a in s["args"]:
			args.append({"name": a["name"], "type": _type_name(a["type"], a.get("class_name", ""))})
		signals.append({"name": name, "args": args})

	return success({
		"class": cls,
		"inherits": ClassDB.get_parent_class(cls),
		"can_instantiate": ClassDB.can_instantiate(cls),
		"own_members_only": no_inherit,
		"properties": properties,
		"methods": methods,
		"signals": signals,
		"property_count": properties.size(),
		"method_count": methods.size(),
		"signal_count": signals.size(),
	})


## Read a class's property DEFAULT values without instantiating it (answers "what
## would I get if I added this node / created this resource") — ClassDB classes only.
func _defaults(params: Dictionary) -> Dictionary:
	var r := require_string(params, "class")
	if r[1] != null:
		return r[1]
	var cls: String = r[0]
	if not ClassDB.class_exists(cls):
		return error_not_found("Class '%s'" % cls, "engine.defaults reads ClassDB classes; for class_name scripts use engine.class_info")
	var no_inherit := not optional_bool(params, "inherited", false)
	var filter := optional_string(params, "filter", "").to_lower()

	var defaults: Dictionary = {}
	for p in ClassDB.class_get_property_list(cls, no_inherit):
		if p["type"] == TYPE_NIL:  # group/category separators
			continue
		var name: String = p["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		var dv: Variant = ClassDB.class_get_property_default_value(cls, name)
		defaults[name] = PropertyParser.serialize_value(dv)

	return success({
		"class": cls,
		"own_members_only": no_inherit,
		"defaults": defaults,
		"count": defaults.size(),
	})


func _search(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var query: String = r[0].to_lower()
	var limit := optional_int(params, "limit", 50)

	var matches: Array = []
	for cls: String in ClassDB.get_class_list():
		var props: Array = []
		for p in ClassDB.class_get_property_list(cls, true):
			if p["type"] != TYPE_NIL and String(p["name"]).to_lower().contains(query):
				props.append(p["name"])
		var meths: Array = []
		for m in ClassDB.class_get_method_list(cls, true):
			if String(m["name"]).to_lower().contains(query):
				meths.append(m["name"])
		var class_hit := cls.to_lower().contains(query)
		if class_hit or not props.is_empty() or not meths.is_empty():
			var entry := {"class": cls}
			if not props.is_empty():
				entry["properties"] = props
			if not meths.is_empty():
				entry["methods"] = meths
			matches.append(entry)

	# Also match global class_name scripts (addon nodes/resources) by name.
	for e in ProjectSettings.get_global_class_list():
		var name: String = e.get("class", "")
		if name.to_lower().contains(query):
			matches.append({"class": name, "kind": "script", "base": e.get("base", ""), "script_path": e.get("path", "")})

	var total := matches.size()
	var truncated := limit > 0 and total > limit
	if truncated:
		matches = matches.slice(0, limit)
	return success({"query": r[0], "matches": matches, "count": matches.size(), "total_matched": total, "truncated": truncated})


## List global class_name scripts (those provided by addons and the project).
func _script_classes(params: Dictionary) -> Dictionary:
	var filter := optional_string(params, "filter", "").to_lower()
	var inherits := optional_string(params, "inherits", "")
	var out: Array = []
	for e in ProjectSettings.get_global_class_list():
		var name: String = e.get("class", "")
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		if not inherits.is_empty() and String(e.get("base", "")) != inherits:
			continue
		out.append({"class": name, "base": e.get("base", ""), "path": e.get("path", ""), "language": e.get("language", "")})
	out.sort_custom(func(a, b): return a["class"] < b["class"])
	return success({"classes": out, "count": out.size()})


func _global_class_entry(name: String) -> Dictionary:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) == name:
			return e
	return {}


func _script_class_info(cls: String, entry: Dictionary, params: Dictionary) -> Dictionary:
	var script := load(entry.get("path", "")) as Script
	if script == null:
		return error_internal("Could not load script for '%s'" % cls)
	var filter := optional_string(params, "filter", "").to_lower()

	var properties: Array = []
	for p in script.get_script_property_list():
		if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) or p["type"] == TYPE_NIL:
			continue
		var name: String = p["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		properties.append({"name": name, "type": _type_name(p["type"], p.get("class_name", ""))})

	var methods: Array = []
	for m in script.get_script_method_list():
		var name: String = m["name"]
		if name.begins_with("_"):
			continue
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		methods.append(_method_brief(m))

	var signals: Array = []
	for s in script.get_script_signal_list():
		var name: String = s["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		var args: Array = []
		for a in s["args"]:
			args.append({"name": a["name"], "type": _type_name(a["type"], a.get("class_name", ""))})
		signals.append({"name": name, "args": args})

	# Constants include enums (an enum is a constant whose value is a Dictionary).
	var constants: Dictionary = {}
	var cmap: Dictionary = script.get_script_constant_map()
	for k in cmap:
		constants[String(k)] = PropertyParser.serialize_value(cmap[k])

	return success({
		"class": cls,
		"kind": "script",
		"inherits": entry.get("base", ""),
		"base_type": script.get_instance_base_type(),
		"script_path": entry.get("path", ""),
		"can_instantiate": script.can_instantiate(),
		"properties": properties,
		"methods": methods,
		"signals": signals,
		"constants": constants,
		"property_count": properties.size(),
		"method_count": methods.size(),
		"signal_count": signals.size(),
	})


func _singletons(_params: Dictionary) -> Dictionary:
	var names := Array(Engine.get_singleton_list())
	names.sort()
	return success({"singletons": names, "count": names.size()})


# --- Helpers ----------------------------------------------------------------

func _type_name(t: int, hint_class: String = "") -> String:
	if t == TYPE_OBJECT and not hint_class.is_empty():
		return hint_class
	return type_string(t)


func _method_brief(m: Dictionary) -> Dictionary:
	var args: Array = []
	for a in m["args"]:
		args.append({"name": a["name"], "type": _type_name(a["type"], a.get("class_name", ""))})
	var ret: Dictionary = m.get("return", {})
	return {
		"name": m["name"],
		"return": _type_name(ret.get("type", TYPE_NIL), ret.get("class_name", "")),
		"args": args,
	}


func get_command_docs() -> Dictionary:
	return {
		"engine.version": {
			"description": "Report the running engine's version info and platform.",
		},
		"engine.classes": {
			"description": "List ClassDB classes, optionally filtered by --inherits (base class), --filter (substring), and --instantiable-only.",
			"params": [
				doc_param("inherits", "String", false, "Only classes deriving from this base class."),
				doc_param("filter", "String", false, "Case-insensitive substring over class names."),
				doc_param("instantiable_only", "bool", false, "Only classes ClassDB can instantiate."),
				doc_param("limit", "int", false, "Max classes returned (default 200; 0 = no cap)."),
			],
		},
		"engine.class_info": {
			"description": "Introspect a class's properties, methods, and signals from the live build. Defaults to the class's OWN members (where version-new API lives). Works for ClassDB classes and global class_name scripts.",
			"params": [
				doc_param("class", "String", true, "Class or script class_name to inspect."),
				doc_param("inherited", "bool", false, "Include inherited members too (default own-members-only)."),
				doc_param("filter", "String", false, "Case-insensitive substring over member names."),
			],
		},
		"engine.defaults": {
			"description": "Read a ClassDB class's property default values without instantiating it (what you'd get by adding the node / creating the resource).",
			"params": [
				doc_param("class", "String", true, "ClassDB class name."),
				doc_param("inherited", "bool", false, "Include inherited properties (default own-only)."),
				doc_param("filter", "String", false, "Substring over property names."),
			],
		},
		"engine.search": {
			"description": "Search the live API: ClassDB classes, properties, and methods (plus global class_name scripts) matching --query.",
			"params": [
				doc_param("query", "String", true, "Substring to match against class/property/method names."),
				doc_param("limit", "int", false, "Max matches (default 50)."),
			],
		},
		"engine.singletons": {
			"description": "List the engine's registered singletons (Engine.get_singleton_list).",
		},
		"engine.script_classes": {
			"description": "List global class_name scripts (addon/project classes), optionally filtered by --filter or --inherits base.",
			"params": [
				doc_param("filter", "String", false, "Substring over class names."),
				doc_param("inherits", "String", false, "Only classes whose base is exactly this."),
			],
		},
		"engine.commands": {
			"description": "List the MCP's own registered commands: a flat method list plus a group->commands map. --group narrows to one group (and attaches that group's per-command param docs); --docs includes docs for the full catalog.",
			"params": [
				doc_param("group", "String", false, "Narrow to one command group (also attaches that group's param docs)."),
				doc_param("docs", "bool", false, "Include per-command param docs in the unfiltered catalog too."),
			],
		},
	}
