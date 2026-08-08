@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## Introspect the running engine via ClassDB so the agent can discover the real
## API surface of THIS Godot build (e.g. 4.7-only members) instead of relying on
## possibly-stale training knowledge. engine.docs / engine.doc_search add the
## PROSE half from the editor's own documentation cache.

## The doc-cache sections holding named members, mapped to the `kind` a hit
## reports. Insertion order is the order hits are collected in.
const MEMBER_SECTIONS := {
	"methods": "method",
	"properties": "property",
	"signals": "signal",
	"constants": "constant",
	"annotations": "annotation",
	"constructors": "constructor",
	"operators": "operator",
	"theme_properties": "theme_property",
}

## doc_search weights: a query word in the entry's own name beats one in the
## owning class name, which beats prose, so exact terminology surfaces first.
const SCORE_NAME := 4
const SCORE_CLASS := 2
const SCORE_BRIEF := 2
const SCORE_PROSE := 1
const SCORE_EXACT_NAME := 8

## Filler words a conversational query carries ("how do I make text wrap"):
## requiring them would empty every result.
const DOC_STOPWORDS := [
	"how", "do", "does", "i", "a", "an", "the", "to", "in", "on", "of", "is", "it",
	"my", "me", "you", "can", "what", "when", "with", "make", "use",
]

const DOC_SUGGESTION_CAP := 12
const DOC_ENUM_VALUES_CAP := 40
const DOC_SNIPPET_CHARS := 160

## The editor's parsed doc cache, keyed by lower-cased page name, plus the
## canonical names for suggestions. Loaded once per editor session on first use
## (the docs cannot change while this build runs) and held here because the
## router keeps this node for the plugin's lifetime.
var _doc_pages: Dictionary = {}
var _doc_names := PackedStringArray()


func get_commands() -> Dictionary:
	return {
		"engine.version": _version,
		"engine.classes": _classes,
		"engine.class_info": _class_info,
		"engine.defaults": _defaults,
		"engine.search": _search,
		"engine.docs": _docs,
		"engine.doc_search": _doc_search,
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


# --- Engine documentation ---------------------------------------------------

## Documentation prose for one doc page, or one of its members, read from the
## editor's own documentation cache: the per-user, per-version file the editor
## maintains and rebuilds on a version change, so the text is this build's Help
## panel prose rather than recalled knowledge. The cache also covers pages
## ClassDB has no entry for (@GlobalScope, @GDScript, the Variant types).
## engine.class_info stays the structural view; this is the meaning.
func _docs(params: Dictionary) -> Dictionary:
	var r := require_string(params, "class")
	if r[1] != null:
		return r[1]
	var load_err := _ensure_docs_loaded()
	if not load_err.is_empty():
		return load_err
	var cls: String = (r[0] as String).strip_edges()
	var page: Dictionary = _doc_pages.get(cls.to_lower(), {})
	if page.is_empty():
		return _unknown_doc_page(cls)
	var member := optional_string(params, "member", "").strip_edges()
	if member.is_empty():
		return success(_doc_page_payload(page))
	return _doc_member_payload(page, member)


## Full-text search over every doc page's names and prose: the discovery step for
## when the caller knows the concept ("wrap text") but not the term
## (autowrap_mode), with engine.docs as the follow-up read.
func _doc_search(params: Dictionary) -> Dictionary:
	var r := require_string(params, "query")
	if r[1] != null:
		return r[1]
	var load_err := _ensure_docs_loaded()
	if not load_err.is_empty():
		return load_err
	var words := _doc_content_words(r[0])
	if words.is_empty():
		return error_invalid_params("Query has no searchable words: name the concept, e.g. 'wrap text'")
	var max_results := optional_int(params, "max_results", 20)

	var best: Dictionary = {}  # label -> hit, so same-name overloads collapse
	for key: String in _doc_pages:
		_collect_doc_hits(_doc_pages[key], words, best)
	var hits: Array = best.values()
	hits.sort_custom(_doc_hit_before)

	var total := hits.size()
	var truncated := max_results > 0 and total > max_results
	if truncated:
		hits = hits.slice(0, max_results)
	return success({
		"query": r[0],
		"hits": hits,
		"total_hits": total,
		"truncated": truncated,
	})


## Load and index the doc cache on first use. Returns {} when the pages are
## ready, else an error dict to return as-is. Nothing is cached on failure, so a
## later call retries: a missing file is transient (the editor rebuilds the cache
## shortly after startup).
func _ensure_docs_loaded() -> Dictionary:
	if not _doc_pages.is_empty():
		return {}
	var path := _doc_cache_path()
	if not FileAccess.file_exists(path):
		return error_not_found(
			"Editor documentation cache '%s'" % path,
			"The editor rebuilds the doc cache shortly after startup; retry in a moment."
		)
	# CACHE_MODE_IGNORE keeps the multi-megabyte resource out of the global
	# resource cache: the pages are copied out and the resource is dropped.
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res == null or not res.has_meta("classes"):
		return _doc_cache_unreadable(path)
	var pages: Dictionary = {}
	var names := PackedStringArray()
	for entry in res.get_meta("classes"):
		if entry is Dictionary and (entry as Dictionary).has("name"):
			var page_name := String((entry as Dictionary)["name"])
			pages[page_name.to_lower()] = entry
			names.append(page_name)
	if pages.is_empty():
		return _doc_cache_unreadable(path)
	_doc_pages = pages
	_doc_names = names
	return {}


func _doc_cache_unreadable(path: String) -> Dictionary:
	return error_internal(
		("documentation cache '%s' could not be read; its internal format may have changed in "
		+ "this Godot build. engine.class_info still gives the structural API.") % path
	)


## The doc cache path for the running build. The editor names the file by
## major.minor in its per-user cache dir, which is what makes a version swap pick
## up the matching docs. EditorPaths also resolves self-contained installs, and
## this addon only ever runs in-editor, so it needs no OS fallback.
func _doc_cache_path() -> String:
	var v := Engine.get_version_info()
	var dir: String = EditorInterface.get_editor_paths().get_cache_dir()
	return dir.path_join("editor_doc_cache-%d.%d.res" % [v.major, v.minor])


## The class-level page: meaning, not structure. Member lists stay with
## engine.class_info.
func _doc_page_payload(page: Dictionary) -> Dictionary:
	var tutorials: Array = []
	for t in page.get("tutorials", []):
		if t is Dictionary:
			var tut: Dictionary = t
			tutorials.append({
				"title": String(tut.get("title", "")),
				"link": _substitute_docs_url(String(tut.get("link", ""))),
			})
	var out := {
		"class": String(page.get("name", "")),
		"inherits": String(page.get("inherits", "")),
		"brief": _clean_doc_prose(String(page.get("brief_description", ""))),
		"description": _clean_doc_prose(String(page.get("description", ""))),
		"tutorials": tutorials,
	}
	# Present only when the docs mark the page; the value is the explanation.
	for key: String in ["deprecated", "experimental"]:
		if page.has(key):
			out[key] = _clean_doc_prose(String(page[key]))
	return out


## One member's prose, matched across every section and up the inheritance
## chain, so overloads and an ancestor's declaration all land. A name that only
## matches as an enum's type falls back to that enum's values.
func _doc_member_payload(page: Dictionary, member: String) -> Dictionary:
	# The leading "@" is stripped from both sides so "export" finds "@export".
	var target := member.to_lower().trim_prefix("@")
	var matches: Array = []
	var enum_matches: Array = []
	var current := page
	while not current.is_empty():
		var declaring := String(current.get("name", ""))
		for section: String in MEMBER_SECTIONS:
			if not (current.get(section) is Array):
				continue
			for raw in current[section]:
				if not (raw is Dictionary):
					continue
				var item: Dictionary = raw
				if String(item.get("name", "")).to_lower().trim_prefix("@") == target:
					matches.append({"owner": declaring, "section": section, "item": item})
				elif section == "constants" and _enum_short_name(String(item.get("enumeration", ""))) == target:
					enum_matches.append({"owner": declaring, "section": section, "item": item})
		current = _doc_pages.get(String(current.get("inherits", "")).to_lower(), {})

	var values_truncated := 0
	var from_enum := matches.is_empty() and not enum_matches.is_empty()
	if from_enum:
		# @GlobalScope's Key enum carries ~193 values, so an enum-name hit is capped.
		values_truncated = maxi(0, enum_matches.size() - DOC_ENUM_VALUES_CAP)
		matches = enum_matches.slice(0, DOC_ENUM_VALUES_CAP)
	if matches.is_empty():
		return _unknown_doc_member(page, member)

	var hits: Array = []
	for m in matches:
		var match_entry: Dictionary = m
		var item: Dictionary = match_entry["item"]
		var section := String(match_entry["section"])
		hits.append({
			"kind": String(MEMBER_SECTIONS[section]),
			"owner": String(match_entry["owner"]),
			"signature": _doc_signature(section, item),
			"description": _clean_doc_prose(String(item.get("description", ""))),
		})
	var first: Dictionary = matches[0]
	var first_item: Dictionary = first["item"]
	# An enum-name hit reports the enum, not whichever value happened to be first.
	var canonical_key := "enumeration" if from_enum else "name"
	var canonical := String(first_item.get(canonical_key, ""))

	var out := {"class": String(page.get("name", "")), "member": canonical, "hits": hits}
	if values_truncated > 0:
		out["values_truncated"] = values_truncated
	return success(out)


## One member's signature line, in the shape its section calls for.
func _doc_signature(section: String, item: Dictionary) -> String:
	if section == "properties" or section == "theme_properties":
		var prop := "%s: %s" % [item.get("name", ""), item.get("type", "Variant")]
		if item.has("default_value"):
			prop += " [default: %s]" % item["default_value"]
		return prop
	if section == "constants":
		var constant := "%s = %s" % [item.get("name", ""), item.get("value", "")]
		if not String(item.get("enumeration", "")).is_empty():
			constant += " (enum %s)" % item["enumeration"]
		return constant
	return _doc_callable_signature(item)


## "name(arg: Type = default, ...) -> Return qualifiers" for a method, signal,
## annotation, constructor, or operator. Sections without a return type or
## qualifiers omit them.
func _doc_callable_signature(item: Dictionary) -> String:
	var parts := PackedStringArray()
	for raw in item.get("arguments", []):
		if not (raw is Dictionary):
			continue
		var arg: Dictionary = raw
		var part := "%s: %s" % [arg.get("name", ""), arg.get("type", "Variant")]
		if arg.has("default_value"):
			part += " = %s" % arg["default_value"]
		parts.append(part)
	var sig := "%s(%s)" % [item.get("name", ""), ", ".join(parts)]
	if not String(item.get("return_type", "")).is_empty():
		sig += " -> %s" % item["return_type"]
	if not String(item.get("qualifiers", "")).is_empty():
		sig += " %s" % item["qualifiers"]
	return sig


## An enum's unqualified lower-case name ("Node.ProcessMode" gives "processmode").
func _enum_short_name(enumeration: String) -> String:
	if enumeration.is_empty():
		return ""
	return enumeration.get_slice(".", enumeration.get_slice_count(".") - 1).to_lower()


## Doc prose arrives with the XML source's leading-tab indentation baked in.
## Strip the COMMON indent so a [codeblock]'s internal indent survives, and
## resolve the $DOCS_URL placeholder. The doc markup itself ([code], [member x])
## is left verbatim: it is ground truth.
func _clean_doc_prose(raw: String) -> String:
	var lines := raw.split("\n")
	var min_tabs := -1
	for line in lines:
		if line.strip_edges().is_empty():
			continue
		var tabs := 0
		while tabs < line.length() and line[tabs] == "\t":
			tabs += 1
		min_tabs = tabs if min_tabs == -1 else mini(min_tabs, tabs)
	if min_tabs > 0:
		for i in lines.size():
			lines[i] = lines[i].substr(min_tabs)
	return _substitute_docs_url("\n".join(lines).strip_edges())


## Doc links carry a $DOCS_URL placeholder; point it at this build's manual.
func _substitute_docs_url(text: String) -> String:
	var v := Engine.get_version_info()
	return text.replace("$DOCS_URL", "https://docs.godotengine.org/en/%d.%d" % [v.major, v.minor])


func _unknown_doc_page(requested: String) -> Dictionary:
	var lowered := requested.to_lower()
	var suggestions: Array[String] = []
	for n in _doc_names:
		if n.to_lower().contains(lowered):
			suggestions.append(n)
	if suggestions.is_empty():
		return error_not_found(
			"Doc page '%s'" % requested,
			("The engine docs cover engine classes and built-in pages (@GDScript, @GlobalScope, "
			+ "the Variant types), not this project's own scripts. Use script.symbols or "
			+ "script.read for those. Names match case-insensitively but must otherwise be exact.")
		)
	_sort_by_similarity(suggestions, lowered)
	return error_not_found(
		"Doc page '%s'" % requested,
		"Did you mean: %s" % _doc_suggestion_list(suggestions)
	)


## Near-miss member names gathered along the inheritance chain, matching in both
## directions so a name longer OR shorter than the request still surfaces.
func _unknown_doc_member(page: Dictionary, member: String) -> Dictionary:
	var target := member.to_lower().trim_prefix("@")
	var suggestions: Array[String] = []
	var current := page
	while not current.is_empty():
		for section: String in MEMBER_SECTIONS:
			if not (current.get(section) is Array):
				continue
			for raw in current[section]:
				if not (raw is Dictionary):
					continue
				var member_name := String((raw as Dictionary).get("name", ""))
				var lowered := member_name.to_lower().trim_prefix("@")
				if lowered.is_empty() or suggestions.has(member_name):
					continue
				if lowered.contains(target) or target.contains(lowered):
					suggestions.append(member_name)
		current = _doc_pages.get(String(current.get("inherits", "")).to_lower(), {})
	var cls := String(page.get("name", ""))
	if suggestions.is_empty():
		return error_not_found(
			"Member '%s' on %s (or its ancestors)" % [member, cls],
			"Use engine.class_info --class %s to browse what it actually has." % cls
		)
	_sort_by_similarity(suggestions, target)
	return error_not_found(
		"Member '%s' on %s (or its ancestors)" % [member, cls],
		"Did you mean: %s" % _doc_suggestion_list(suggestions)
	)


## Closest name first, the router's did-you-mean idiom. An alphabetical sort put
## a dozen TEXTURE_ constants ahead of "texture" for "textur" and capped it away.
func _sort_by_similarity(suggestions: Array[String], target: String) -> void:
	suggestions.sort_custom(func(a: String, b: String) -> bool:
		var sim_a := a.to_lower().similarity(target)
		var sim_b := b.to_lower().similarity(target)
		if sim_a != sim_b:
			return sim_a > sim_b
		return a < b)


func _doc_suggestion_list(suggestions: Array[String]) -> String:
	if suggestions.size() <= DOC_SUGGESTION_CAP:
		return ", ".join(suggestions)
	var shown := suggestions.slice(0, DOC_SUGGESTION_CAP)
	return "%s (and %d more)" % [", ".join(shown), suggestions.size() - DOC_SUGGESTION_CAP]


## Drop the filler words; if that empties the query, the original words stand.
func _doc_content_words(query: String) -> PackedStringArray:
	var words := query.strip_edges().to_lower().split(" ", false)
	var kept := PackedStringArray()
	for word in words:
		if not DOC_STOPWORDS.has(word):
			kept.append(word)
	return kept if not kept.is_empty() else words


## Score one page and each of its members, folding results into `best` by label.
func _collect_doc_hits(page: Dictionary, words: PackedStringArray, best: Dictionary) -> void:
	var cls := String(page.get("name", ""))
	var brief := String(page.get("brief_description", ""))
	var desc := String(page.get("description", ""))
	var page_score := _doc_score(words, cls, "", brief, desc)
	if page_score > 0:
		_record_doc_hit(best, cls, "class", page_score, _doc_snippet(words, brief, desc))
	for section: String in MEMBER_SECTIONS:
		if not (page.get(section) is Array):
			continue
		for raw in page[section]:
			if not (raw is Dictionary):
				continue
			var item: Dictionary = raw
			var member_name := String(item.get("name", ""))
			var member_desc := String(item.get("description", ""))
			var score := _doc_score(words, member_name, cls, "", member_desc)
			if score > 0:
				_record_doc_hit(
					best,
					"%s.%s" % [cls, member_name],
					String(MEMBER_SECTIONS[section]),
					score,
					_doc_snippet(words, "", member_desc)
				)


func _record_doc_hit(
	best: Dictionary, label: String, kind: String, score: int, snippet: String
) -> void:
	if best.has(label) and int((best[label] as Dictionary)["score"]) >= score:
		return
	best[label] = {"label": label, "kind": kind, "score": score, "snippet": snippet}


## An entry's relevance: 0 unless EVERY query word appears somewhere in it, else
## weighted per-word hits, plus a bonus when a lone word IS the name.
func _doc_score(
	words: PackedStringArray, entry_name: String, cls: String, brief: String, desc: String
) -> int:
	var total := 0
	for word in words:
		var word_score := 0
		if entry_name.findn(word) != -1:
			word_score += SCORE_NAME
		if not cls.is_empty() and cls.findn(word) != -1:
			word_score += SCORE_CLASS
		if not brief.is_empty() and brief.findn(word) != -1:
			word_score += SCORE_BRIEF
		if not desc.is_empty() and desc.findn(word) != -1:
			word_score += SCORE_PROSE
		if word_score == 0:
			return 0
		total += word_score
	if words.size() == 1 and entry_name.to_lower().trim_prefix("@") == words[0].trim_prefix("@"):
		total += SCORE_EXACT_NAME
	return total


## The one line of context shown with a hit: the brief description when there is
## one, else a window around the first matched word, flattened and clipped.
func _doc_snippet(words: PackedStringArray, brief: String, desc: String) -> String:
	var source := brief if not brief.strip_edges().is_empty() else desc
	if source.strip_edges().is_empty():
		return ""
	var pos := -1
	for word in words:
		pos = source.findn(word)
		if pos != -1:
			break
	var start := maxi(0, pos - 40)
	var window := _flatten_doc_prose(source.substr(start, DOC_SNIPPET_CHARS))
	if start > 0:
		window = "..." + window
	if start + DOC_SNIPPET_CHARS < source.length():
		window += "..."
	return window


## Prose collapsed to one plain line: markup newlines and tabs become spaces and
## runs of spaces collapse.
func _flatten_doc_prose(text: String) -> String:
	var flat := text.replace("\n", " ").replace("\t", " ").strip_edges()
	while flat.contains("  "):
		flat = flat.replace("  ", " ")
	return flat


func _doc_hit_before(a: Dictionary, b: Dictionary) -> bool:
	if int(a["score"]) != int(b["score"]):
		return int(a["score"]) > int(b["score"])
	return String(a["label"]) < String(b["label"])


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
		"engine.docs": {
			"description": "Read the engine's documentation prose for a class page, or for one member of it, from the editor's own doc cache. Covers pages ClassDB has no entry for (@GlobalScope, @GDScript, Variant types like Array or Vector2). A member is matched across every section and up the inheritance chain, so overloads and an ancestor's declaration all come back; an enum name with no direct member hit returns that enum's values instead. engine.class_info gives the structure, this gives the meaning.",
			"params": [
				doc_param("class", "String", true, "Doc page to read: a class name, or a built-in page such as @GDScript."),
				doc_param("member", "String", false, "One member of that page (method, property, signal, constant, annotation, constructor, operator, theme property, or an enum name). A leading @ is optional."),
			],
		},
		"engine.doc_search": {
			"description": "Search the engine documentation full-text: every class page and member whose name or prose carries all of the query's words, ranked with name matches above prose matches. Finds the term behind a concept ('wrap text' reaches autowrap_mode); read the hit with engine.docs.",
			"params": [
				doc_param("query", "String", true, "Words naming the concept. Filler words are dropped and every remaining word must appear in a single entry."),
				doc_param("max_results", "int", false, "Max hits returned (default 20; 0 = no cap)."),
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
