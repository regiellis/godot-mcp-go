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
		properties.append({"name": name, "type": type_name(p["type"], p.get("class_name", ""))})

	var methods: Array = []
	for m in ClassDB.class_get_method_list(cls, no_inherit):
		var name: String = m["name"]
		if name.begins_with("_"):
			continue
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		methods.append(method_brief(m))

	var signals: Array = []
	for s in ClassDB.class_get_signal_list(cls, no_inherit):
		var name: String = s["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		var args: Array = []
		for a in s["args"]:
			args.append({"name": a["name"], "type": type_name(a["type"], a.get("class_name", ""))})
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


## Build the fuzzy matcher, or null when the running build has no FuzzySearch.
##
## Reached through ClassDB rather than the `FuzzySearch` identifier on purpose:
## naming the type directly is a parse error on 4.7, which would break the whole
## plugin rather than degrade one command.
func _fuzzy_matcher() -> Object:
	if not ClassDB.class_exists("FuzzySearch"):
		return null
	var fz: Object = ClassDB.instantiate("FuzzySearch")
	if fz == null:
		return null
	fz.set("case_sensitive", false)
	# Without this the matcher accepts almost anything across a 100k-name corpus:
	# an unfiltered "linvel" ranked AccessibilityServer.update_set_list_item_level
	# above linear_velocity.
	fz.set("filter_low_scores", true)
	fz.set("max_results", 400)
	return fz


## Fuzzy sweep of the whole API, ranked by score. Empty when the running build
## has no FuzzySearch.
##
## Deliberately ONE search over every candidate rather than per-class calls: the
## point of fuzzy matching is the ranking, and matching class by class in ClassDB
## order throws it away — the answer becomes alphabetical, so AccessibilityServer
## outranks the class you meant. Names are grouped back onto their owning class in
## score order, so the first entry is the best hit.
func _fuzzy_search_matches(query: String) -> Array:
	var fz := _fuzzy_matcher()
	if fz == null:
		return []

	var targets := PackedStringArray()
	var owners: Array = []
	for cls: String in ClassDB.get_class_list():
		targets.append(cls)
		owners.append({"class": cls, "kind": "class"})
		for p in ClassDB.class_get_property_list(cls, true):
			if p["type"] != TYPE_NIL:
				targets.append(p["name"])
				owners.append({"class": cls, "kind": "property"})
		for m in ClassDB.class_get_method_list(cls, true):
			targets.append(m["name"])
			owners.append({"class": cls, "kind": "method"})
	for e in ProjectSettings.get_global_class_list():
		targets.append(String(e.get("class", "")))
		owners.append({"class": String(e.get("class", "")), "kind": "script", "entry": e})

	var by_class := {}
	var order: Array = []
	for m in fz.call("search_all", query, targets):
		var idx := int(m.get("original_index"))
		if idx < 0 or idx >= owners.size():
			continue
		var owner: Dictionary = owners[idx]
		var cls: String = owner["class"]
		if not by_class.has(cls):
			by_class[cls] = {"class": cls}
			order.append(cls)
			if owner["kind"] == "script":
				var e: Dictionary = owner["entry"]
				by_class[cls]["kind"] = "script"
				by_class[cls]["base"] = e.get("base", "")
				by_class[cls]["script_path"] = e.get("path", "")
		var name := String(m.get("target"))
		match owner["kind"]:
			"property":
				by_class[cls].get_or_add("properties", []).append(name)
			"method":
				by_class[cls].get_or_add("methods", []).append(name)

	var out: Array = []
	for cls in order:
		out.append(by_class[cls])
	return out


## Substring sweep of ClassDB plus the global class list. `query` is lowercased.
func _collect_search_matches(query: String) -> Array:
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
	return matches


func _search(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var query: String = r[0].to_lower()
	var limit := optional_int(params, "limit", 50)

	# Substring first: it is the cheap sweep and it is what most queries want.
	var matches := _collect_search_matches(query)
	var mode := "substring"

	# A query that matches nothing as a substring is usually an abbreviation an
	# agent guessed ("linvel" for linear_velocity, "gpos" for global_position).
	# 4.8's FuzzySearch resolves those; 4.7 has no such class and keeps the empty
	# result. Running it only as a rescue keeps the common path at its old speed
	# and makes the fuzzy pass strictly additive — it can never change a result
	# the substring sweep already found.
	if matches.is_empty():
		var fuzzy := _fuzzy_search_matches(query)
		if not fuzzy.is_empty():
			matches = fuzzy
			mode = "fuzzy"

	var total := matches.size()
	var truncated := limit > 0 and total > limit
	if truncated:
		matches = matches.slice(0, limit)
	return success({
		"query": r[0],
		"matches": matches,
		"count": matches.size(),
		"total_matched": total,
		"truncated": truncated,
		"match_mode": mode,
	})


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

	var payload := script_symbols(script, optional_string(params, "filter", ""))
	payload.merge({
		"class": cls,
		"kind": "script",
		"inherits": entry.get("base", ""),
		"base_type": script.get_instance_base_type(),
		"script_path": entry.get("path", ""),
		"can_instantiate": script.can_instantiate(),
	})
	return success(payload)


func _singletons(_params: Dictionary) -> Dictionary:
	var names := Array(Engine.get_singleton_list())
	names.sort()
	return success({"singletons": names, "count": names.size()})


# --- Helpers ----------------------------------------------------------------

# type_name() and method_brief() live in base_command.gd — script.symbols reports
# the same shapes, and two copies drifted apart is exactly the bug class the
# shared-helper rule exists to prevent.


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
			"description": "Search the live API: ClassDB classes, properties, and methods (plus global class_name scripts) matching --query. Matches by substring first; if that finds nothing and the running build exposes FuzzySearch (Godot 4.8+), it retries fuzzily so an abbreviation like 'linvel' still reaches linear_velocity. `match_mode` in the result says which pass produced the matches ('substring' or 'fuzzy').",
			"params": [
				doc_param("query", "String", true, "Substring to match against class/property/method names; an abbreviation also works on 4.8+."),
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
