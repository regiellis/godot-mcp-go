@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## In-game documentation — "Gyms, Zoos, and Museums: your documentation should be in-game"
## (the workflow-design talk). Document the game *in* the game, spatially and contextually close
## to the content, so you maintain one thing instead of two. For a solo/small team the "game of
## telephone" is with your future self — these make the level itself the single source of truth.
##
##   doc.note    — spatial notes: Marker3D / existing-node markers carrying metadata (todo/bug/art…)
##   doc.metric  — a labeled, colour-coded metric station (gap/height/slope/distance) — gym primitive
##   doc.gym     — a metrics test level (jump gaps, step heights, slopes) for character-controller truth
##   doc.zoo     — lay out a folder of assets in a labeled grid with scale refs + lighting
##   doc.museum  — labeled exhibit pads for demonstrating systems, with links to API docs

const NOTE_META := "_doc_note"      # Dictionary of note fields
const OWNED_META := "_doc_owned"    # true on nodes this group created (safe to delete on resolve)

const DIFFICULTY_COLOR := {
	"easy": Color(0.20, 0.78, 0.28),
	"hard": Color(0.93, 0.56, 0.13),
	"impossible": Color(0.86, 0.21, 0.21),
	"info": Color(0.31, 0.52, 0.90),
}


func get_commands() -> Dictionary:
	return {
		"doc.note": _note,
		"doc.metric": _metric,
		"doc.gym": _gym,
		"doc.zoo": _zoo,
		"doc.museum": _museum,
	}


const ASSET_EXTS := ["tscn", "scn", "glb", "gltf", "res", "mesh", "obj", "fbx", "blend"]


# --- shared node-building helpers --------------------------------------------

func _difficulty_color(d: String) -> Color:
	return DIFFICULTY_COLOR.get(d, DIFFICULTY_COLOR["info"])


func _make_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _v3(params: Dictionary, key: String, default: Vector3) -> Vector3:
	return vec3_param(params, key, default)


## Resolve a --parent param to a node (default the edited scene root).
func _resolve_parent(params: Dictionary) -> Node:
	var root := get_edited_root()
	if root == null:
		return null
	if params.has("parent"):
		var p := find_node_by_path(str(params["parent"]))
		if p != null:
			return p
	return root


## Create a Node3D, add it under `parent` as one undoable action, return it. Children added
## afterward ride along (undo removes the whole subtree), matching the scaffolding use.
func _spawn_container(parent: Node, name: String, action: String) -> Node3D:
	var root := get_edited_root()
	var container := Node3D.new()
	container.name = name
	container.set_meta(OWNED_META, true)
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action)
	undo_redo.add_do_method(parent, "add_child", container)
	undo_redo.add_do_method(container, "set_owner", root)
	undo_redo.add_do_reference(container)
	undo_redo.add_undo_method(parent, "remove_child", container)
	undo_redo.commit_action()
	return container


## Build a configured (but not-yet-parented) billboard label. Callers either add it
## raw (scaffold builders, via _add_label) or through an UndoRedo action (doc.note).
func _build_label(text: String, local_pos: Vector3, font_size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = font_size
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = false
	label.outline_size = maxi(1, int(font_size / 8.0))
	label.outline_modulate = Color(0, 0, 0, 0.8)
	label.position = local_pos
	return label


func _add_label(parent: Node3D, text: String, local_pos: Vector3, font_size: int, color: Color) -> Label3D:
	var label := _build_label(text, local_pos, font_size, color)
	parent.add_child(label)
	label.owner = get_edited_root()
	return label


func _add_box(parent: Node3D, name: String, size: Vector3, local_pos: Vector3, color: Color) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.name = name
	box.size = size
	box.material = _make_material(color)
	parent.add_child(box)
	box.owner = get_edited_root()
	box.position = local_pos
	return box


# --- doc.note ----------------------------------------------------------------

## Place a spatial note: either attach metadata to an existing --node-path, or drop a new Marker3D
## at --at "Vector3(...)". Notes carry category/text/screenshot/link/author/created so the level
## itself records what to do, where. Adds a billboard Label3D so it's visible in the viewport.
## Multi-mode like authoring.checkpoint: --action add|list|resolve (default list, a safe read).
func _note(params: Dictionary) -> Dictionary:
	var action := optional_string(params, "action", "list")
	match action:
		"add": return _note_add(params)
		"list": return _note_list(params)
		"resolve": return _note_resolve(params)
	return error_invalid_params("doc.note --action must be add|list|resolve (got '%s')" % action)


func _note_add(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var rt := require_string(params, "text")
	if rt[1] != null:
		return rt[1]
	var text: String = rt[0]
	var category := optional_string(params, "category", "note")
	var note := {
		"category": category,
		"text": text,
		"screenshot": optional_string(params, "screenshot", ""),
		"link": optional_string(params, "link", ""),
		"author": optional_string(params, "author", ""),
		"created": Time.get_datetime_string_from_system(),
		"resolved": false,
	}

	var label_text := "[%s] %s" % [category.to_upper(), text]
	var color := _difficulty_color("info")

	if params.has("at"):
		# new standalone Marker3D note
		var parent := _resolve_parent(params)
		var marker := Marker3D.new()
		marker.name = optional_string(params, "name", "Note_%s" % category.capitalize())
		marker.set_meta(NOTE_META, note)
		marker.set_meta(OWNED_META, true)
		var undo_redo := get_undo_redo()
		undo_redo.create_action("MCP: Add spatial note")
		undo_redo.add_do_method(parent, "add_child", marker)
		undo_redo.add_do_method(marker, "set_owner", root)
		undo_redo.add_do_reference(marker)
		undo_redo.add_undo_method(parent, "remove_child", marker)
		undo_redo.commit_action()
		marker.position = _v3(params, "at", Vector3.ZERO)
		if optional_bool(params, "label", true):
			_add_label(marker, label_text, Vector3(0, 0.4, 0), 24, color)
		return success({"node_path": str(root.get_path_to(marker)), "created": true, "note": note})

	# attach to an existing node
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return error_invalid_params("Provide --node-path (attach to a node) or --at \"Vector3(…)\" (new marker)")
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	var undo_redo := get_undo_redo()
	var old: Variant = node.get_meta(NOTE_META) if node.has_meta(NOTE_META) else null
	undo_redo.create_action("MCP: Note on %s" % node.name)
	undo_redo.add_do_method(node, "set_meta", NOTE_META, note)
	if old == null:
		undo_redo.add_undo_method(node, "remove_meta", NOTE_META)
	else:
		undo_redo.add_undo_method(node, "set_meta", NOTE_META, old)
	# Fold the billboard label into the SAME action so undo removes it too (no orphan).
	if optional_bool(params, "label", true) and node is Node3D:
		var label := _build_label(label_text, Vector3(0, 0.4, 0), 24, color)
		undo_redo.add_do_method(node, "add_child", label)
		undo_redo.add_do_method(label, "set_owner", root)
		undo_redo.add_do_reference(label)
		undo_redo.add_undo_method(node, "remove_child", label)
	undo_redo.commit_action()
	return success({"node_path": rn[0], "created": false, "attached": true, "note": note})


func _note_list(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var cat_filter := optional_string(params, "category", "")
	var include_resolved := optional_bool(params, "include_resolved", false)
	var notes: Array = []
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n.has_meta(NOTE_META):
			var note: Dictionary = n.get_meta(NOTE_META)
			var ok := true
			if cat_filter != "" and String(note.get("category", "")) != cat_filter:
				ok = false
			if not include_resolved and bool(note.get("resolved", false)):
				ok = false
			if ok:
				notes.append({"node_path": str(root.get_path_to(n)), "category": note.get("category", ""), "text": note.get("text", ""), "resolved": note.get("resolved", false), "created": note.get("created", ""), "link": note.get("link", "")})
		for c in n.get_children():
			queue.append(c)
	return success({"count": notes.size(), "notes": notes})


func _note_resolve(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	var rn := require_string(params, "node_path")
	if rn[1] != null:
		return rn[1]
	var node := find_node_by_path(rn[0])
	if node == null:
		return error_not_found("Node at '%s'" % rn[0])
	if not node.has_meta(NOTE_META):
		return error_invalid_params("Node '%s' has no doc note" % rn[0])

	var undo_redo := get_undo_redo()
	# delete the whole marker if we own it and --delete given
	if optional_bool(params, "delete", false):
		if node.has_meta(OWNED_META):
			var parent := node.get_parent()
			undo_redo.create_action("MCP: Delete note %s" % node.name)
			undo_redo.add_do_method(parent, "remove_child", node)
			undo_redo.add_undo_method(parent, "add_child", node)
			undo_redo.add_undo_method(node, "set_owner", root)
			undo_redo.add_undo_reference(node)
			undo_redo.commit_action()
			return success({"node_path": rn[0], "deleted": true})
		# attached note: just strip the meta
		var old: Dictionary = node.get_meta(NOTE_META)
		undo_redo.create_action("MCP: Remove note from %s" % node.name)
		undo_redo.add_do_method(node, "remove_meta", NOTE_META)
		undo_redo.add_undo_method(node, "set_meta", NOTE_META, old)
		undo_redo.commit_action()
		return success({"node_path": rn[0], "removed": true})

	var note: Dictionary = (node.get_meta(NOTE_META) as Dictionary).duplicate()
	var resolved := not optional_bool(params, "unresolve", false)
	note["resolved"] = resolved
	undo_redo.create_action("MCP: Resolve note on %s" % node.name)
	undo_redo.add_do_method(node, "set_meta", NOTE_META, note)
	undo_redo.add_undo_method(node, "set_meta", NOTE_META, node.get_meta(NOTE_META))
	undo_redo.commit_action()
	return success({"node_path": rn[0], "resolved": resolved})


# --- doc.metric --------------------------------------------------------------

## A labeled, colour-coded metric station — the gym building block. Visualizes one character-
## controller metric as geometry you can run at: gap (jump distance), height (step/vault),
## slope (max walk angle), distance (a pure measuring stick).
func _metric(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("doc.metric needs a 3D scene")
	var mtype := optional_string(params, "type", "distance")
	if mtype not in ["gap", "height", "slope", "distance"]:
		return error_invalid_params("type must be gap|height|slope|distance")
	var value := float(params.get("value", 1.0))
	var difficulty := optional_string(params, "difficulty", "info")
	var color := _difficulty_color(difficulty)
	var width := float(params.get("width", 1.0))
	var at := _v3(params, "at", Vector3.ZERO)
	var label_text := optional_string(params, "label", "%s %.2fm" % [mtype, value])
	if difficulty in DIFFICULTY_COLOR and difficulty != "info":
		label_text += "  (%s)" % difficulty

	var parent := _resolve_parent(params)
	var name := optional_string(params, "name", "Metric_%s" % mtype.capitalize())
	var c := _spawn_container(parent, name, "MCP: Add %s metric" % mtype)
	c.position = at

	var info := _build_metric(c, mtype, value, color, width)
	_add_label(c, label_text, Vector3(0, maxf(value, 1.0) + 0.5, 0), 28, color)
	return success({"node_path": str(root.get_path_to(c)), "type": mtype, "value": value, "difficulty": difficulty, "info": info})


## Build one metric's geometry into container `c` (no label, no own container). Shared by
## doc.metric and doc.gym. Returns the info dict.
func _build_metric(c: Node3D, mtype: String, value: float, color: Color, width: float) -> Dictionary:
	match mtype:
		"gap":
			var pad := Vector3(1.0, 0.3, width)
			_add_box(c, "PadA", pad, Vector3(-value * 0.5 - 0.5, -0.15, 0), color)
			_add_box(c, "PadB", pad, Vector3(value * 0.5 + 0.5, -0.15, 0), color)
			return {"gap_m": value}
		"height":
			_add_box(c, "Base", Vector3(1.0, 0.3, width), Vector3(-0.75, -0.15, 0), color)
			_add_box(c, "Step", Vector3(1.0, value, width), Vector3(0.25, value * 0.5, 0), color)
			return {"height_m": value}
		"slope":
			var ramp := _add_box(c, "Ramp", Vector3(3.0, 0.2, width), Vector3.ZERO, color)
			ramp.rotation = Vector3(0, 0, deg_to_rad(-value))
			return {"slope_deg": value}
		"distance":
			_add_box(c, "Bar", Vector3(value, 0.08, 0.08), Vector3(value * 0.5, 0, 0), color)
			_add_box(c, "CapA", Vector3(0.08, 0.4, 0.4), Vector3(0, 0, 0), color)
			_add_box(c, "CapB", Vector3(0.08, 0.4, 0.4), Vector3(value, 0, 0), color)
			return {"length_m": value}
	return {}


# --- doc.zoo -----------------------------------------------------------------

## First VisualInstance3D descendant's world-ish local AABB (for sizing + the dims label).
func _instance_aabb(node: Node) -> AABB:
	var queue: Array[Node] = [node]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is VisualInstance3D:
			return (n as VisualInstance3D).get_aabb()
		for c in n.get_children():
			queue.append(c)
	return AABB()


func _walk_assets(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.get_extension().to_lower() in ASSET_EXTS:
			out.append(dir_path.path_join(f))
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _build_scale_ref(zoo: Node3D, at: Vector3) -> void:
	var ref := Node3D.new()
	ref.name = "ScaleRef"
	zoo.add_child(ref)
	ref.owner = get_edited_root()
	ref.position = at
	# 1m and 2m reference cubes
	_add_box(ref, "Cube1m", Vector3.ONE, Vector3(0, 0.5, 0), Color(0.20, 0.78, 0.28))
	_add_label(ref, "1m", Vector3(0, 1.3, 0), 22, Color(0.20, 0.78, 0.28))
	_add_box(ref, "Cube2m", Vector3(2, 2, 2), Vector3(2.5, 1.0, 0), Color(0.31, 0.52, 0.90))
	_add_label(ref, "2m", Vector3(2.5, 2.3, 0), 22, Color(0.31, 0.52, 0.90))
	# ~1.8m character-height capsule
	var cap := MeshInstance3D.new()
	cap.name = "CharRef"
	var cm := CapsuleMesh.new()
	cm.radius = 0.3
	cm.height = 1.8
	cap.mesh = cm
	ref.add_child(cap)
	cap.owner = get_edited_root()
	cap.position = Vector3(5.0, 0.9, 0)
	_add_label(ref, "1.8m char", Vector3(5.0, 2.1, 0), 22, Color(0.86, 0.21, 0.21))


## Lay out a folder (or explicit list) of assets in a labeled grid, with scale references and
## lighting — the "Generate Zoo". See all assets' scale/look at a glance, no name lookup needed.
func _zoo(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("doc.zoo needs a 3D scene")

	# collect asset paths: explicit --scenes, or walk --from dir
	var assets: Array = []
	if params.has("scenes"):
		var sv: Variant = params["scenes"]
		if sv is String:
			sv = JSON.parse_string(sv)
		if sv is Array:
			for e in sv:
				assets.append(String(e))
	elif params.has("from"):
		assets = _walk_assets(String(params["from"]))
	else:
		return error_invalid_params("Provide --from <dir> or --scenes '[res://a.tscn,…]'")
	if assets.is_empty():
		return error(-32000, "No instantiable assets found")

	var spacing := float(params.get("spacing", 3.0))
	var cols := optional_int(params, "cols", int(ceil(sqrt(float(assets.size())))))
	cols = maxi(1, cols)
	var parent := _resolve_parent(params)
	var zoo := _spawn_container(parent, optional_string(params, "name", "Zoo"), "MCP: Generate zoo")
	zoo.position = _v3(params, "at", Vector3.ZERO)

	# optional ground + lighting
	var rows := int(ceil(float(assets.size()) / float(cols)))
	if optional_bool(params, "ground", true):
		_add_box(zoo, "Ground", Vector3(cols * spacing + 4, 0.2, rows * spacing + 4), Vector3((cols - 1) * spacing * 0.5, -0.11, (rows - 1) * spacing * 0.5), Color(0.22, 0.22, 0.25))
	if optional_bool(params, "lighting", true):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		zoo.add_child(sun)
		sun.owner = root
		sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(-40), 0)

	var placed: Array = []
	var skipped: Array = []
	for i in assets.size():
		var path: String = assets[i]
		if not ResourceLoader.exists(path):
			skipped.append({"path": path, "reason": "not found"})
			continue
		var res: Resource = load(path)
		if res == null:
			skipped.append({"path": path, "reason": "failed to load"})
			continue
		var instance: Node = null
		if res is PackedScene:
			instance = (res as PackedScene).instantiate()
		elif res is Mesh:
			instance = MeshInstance3D.new()
			(instance as MeshInstance3D).mesh = res
		else:
			skipped.append({"path": path, "reason": "not a PackedScene/Mesh (%s)" % res.get_class()})
			continue

		var base := path.get_file().get_basename()
		var col := i % cols
		var row := i / cols
		var cell := Node3D.new()
		cell.name = base
		zoo.add_child(cell)
		cell.owner = root
		cell.position = Vector3(col * spacing, 0, row * spacing)
		cell.add_child(instance)
		instance.owner = root

		var aabb := _instance_aabb(instance)
		var top := aabb.position.y + aabb.size.y if aabb.size != Vector3.ZERO else 1.0
		var dims := "  (%.1f×%.1f×%.1f)" % [aabb.size.x, aabb.size.y, aabb.size.z] if aabb.size != Vector3.ZERO else ""
		_add_label(cell, base + dims, Vector3(0, top + 0.4, 0), 22, Color(0.92, 0.92, 0.95))
		placed.append({"name": base, "path": path, "size": str(aabb.size)})

	if optional_bool(params, "scale_ref", true):
		_build_scale_ref(zoo, Vector3(-spacing * 1.5, 0, 0))

	return success({
		"node_path": str(root.get_path_to(zoo)),
		"placed": placed.size(),
		"skipped": skipped.size(),
		"cols": cols,
		"rows": rows,
		"assets": placed,
		"skipped_detail": skipped,
	})


# --- doc.museum --------------------------------------------------------------

## Scaffold a museum: a row of labeled exhibit pads for demonstrating systems, each carrying a
## doc-note (with a link to API docs) so it shows up in doc.note list. You drop the live demo
## onto each pad — the museum gives the layout, labels, and the "read more" links.
##   --exhibits '["Cloth", {"name":"Destruction","link":"https://…","text":"how it shatters"}]'
func _museum(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("doc.museum needs a 3D scene")

	if not params.has("exhibits"):
		return error_invalid_params("Provide --exhibits '[\"Name\", {\"name\":…,\"link\":…,\"text\":…}]'")
	var ev: Variant = params["exhibits"]
	if ev is String:
		ev = JSON.parse_string(ev)
	if not ev is Array or (ev as Array).is_empty():
		return error_invalid_params("--exhibits must be a non-empty JSON array")

	var spacing := float(params.get("spacing", 5.0))
	var parent := _resolve_parent(params)
	var museum := _spawn_container(parent, optional_string(params, "name", "Museum"), "MCP: Build museum")
	museum.position = _v3(params, "at", Vector3.ZERO)

	var exhibits: Array = []
	for i in (ev as Array).size():
		var raw: Variant = ev[i]
		var ex := {"name": "", "link": "", "text": ""}
		if raw is String:
			ex["name"] = String(raw)
		elif raw is Dictionary:
			ex["name"] = String((raw as Dictionary).get("name", "Exhibit %d" % i))
			ex["link"] = String((raw as Dictionary).get("link", ""))
			ex["text"] = String((raw as Dictionary).get("text", ""))
		else:
			continue

		var pad := Node3D.new()
		pad.name = "Exhibit_%s" % String(ex["name"]).validate_filename()
		museum.add_child(pad)
		pad.owner = root
		pad.position = Vector3(i * spacing, 0, 0)
		# the exhibit platform (drop the live demo here)
		_add_box(pad, "Pad", Vector3(3.0, 0.2, 3.0), Vector3(0, -0.1, 0), Color(0.28, 0.28, 0.32))
		_add_label(pad, String(ex["name"]), Vector3(0, 2.4, 0), 30, Color(0.92, 0.92, 0.95))
		# an info marker carrying a doc-note (so doc.note list surfaces the museum's links)
		var info := Marker3D.new()
		info.name = "Info"
		info.set_meta(NOTE_META, {
			"category": "info",
			"text": ex["text"] if String(ex["text"]) != "" else "Exhibit: %s" % ex["name"],
			"screenshot": "",
			"link": ex["link"],
			"author": "",
			"created": Time.get_datetime_string_from_system(),
			"resolved": false,
		})
		info.set_meta(OWNED_META, true)
		pad.add_child(info)
		info.owner = root
		info.position = Vector3(1.2, 0.6, 1.2)
		if String(ex["link"]) != "":
			_add_label(info, "? docs", Vector3(0, 0.5, 0), 20, _difficulty_color("info"))
		exhibits.append(ex)

	return success({
		"node_path": str(root.get_path_to(museum)),
		"exhibits": exhibits.size(),
		"names": exhibits.map(func(e): return e["name"]),
	})


# --- doc.gym -----------------------------------------------------------------

## index/total → difficulty: first third easy (green), middle hard (orange), last impossible (red).
func _grade(index: int, total: int) -> String:
	if total <= 1:
		return "easy"
	var t := float(index) / float(total - 1)
	if t < 0.34:
		return "easy"
	if t < 0.67:
		return "hard"
	return "impossible"


func _parse_floats(params: Dictionary, key: String, default: Array) -> Array:
	if not params.has(key):
		return default
	var v: Variant = params[key]
	if v is String:
		v = JSON.parse_string(v)
	var out: Array = []
	if v is Array:
		for e in v:
			out.append(float(e))
	return out if not out.is_empty() else default


## Scaffold a metrics gym: rows of jump gaps, step heights, and slope ramps at increasing values,
## colour-graded green→orange→red, all labeled — the single source of truth for character-controller
## metrics ("how far can a player jump?" → run the gym). Composes doc.metric.
func _gym(params: Dictionary) -> Dictionary:
	var root := get_edited_root()
	if root == null:
		return error_no_scene()
	if not root is Node3D:
		return error_invalid_params("doc.gym needs a 3D scene")

	var gaps := _parse_floats(params, "gaps", [1.0, 2.0, 3.0, 4.0, 5.0])
	var heights := _parse_floats(params, "heights", [0.3, 0.6, 1.0, 1.5])
	var slopes := _parse_floats(params, "slopes", [20.0, 30.0, 40.0, 50.0])
	var spacing := float(params.get("spacing", 3.0))

	var parent := _resolve_parent(params)
	var gym := _spawn_container(parent, optional_string(params, "name", "Gym"), "MCP: Build gym")
	gym.position = _v3(params, "at", Vector3.ZERO)

	# optional ground plane
	if optional_bool(params, "ground", true):
		var extent := maxf(gaps.size(), maxf(heights.size(), slopes.size())) * spacing + 6.0
		_add_box(gym, "Ground", Vector3(20.0, 0.2, extent), Vector3(6.0, -0.35, extent * 0.5 - spacing), Color(0.25, 0.25, 0.28))

	var rows := [["gap", gaps, 0.0], ["height", heights, 6.0], ["slope", slopes, 12.0]]
	for row: Array in rows:
		var mtype: String = row[0]
		var values: Array = row[1]
		var xoff: float = row[2]
		for i in values.size():
			var diff := _grade(i, values.size())
			var color := _difficulty_color(diff)
			var sub := Node3D.new()
			sub.name = "%s_%d" % [mtype.capitalize(), i]
			gym.add_child(sub)
			sub.owner = root
			sub.position = Vector3(xoff, 0, i * spacing)
			_build_metric(sub, mtype, float(values[i]), color, 1.0)
			_add_label(sub, "%s %.2f (%s)" % [mtype, float(values[i]), diff], Vector3(0, maxf(float(values[i]), 1.0) + 0.5, 0), 24, color)

	return success({
		"node_path": str(root.get_path_to(gym)),
		"gaps": gaps.size(),
		"heights": heights.size(),
		"slopes": slopes.size(),
		"stations": gaps.size() + heights.size() + slopes.size(),
	})


func get_command_docs() -> Dictionary:
	return {
		"doc.note": {
			"description": "Spatial in-game notes. --action add attaches metadata (+ a billboard Label3D) to --node-path OR drops a new Marker3D at --at; list (default) reads notes; resolve marks/deletes one. 3D scene.",
			"params": [
				doc_param("action", "String", false, "add, list (default), or resolve."),
				doc_param("text", "String", false, "Note body (required for add)."),
				doc_param("category", "String", false, "Note category e.g. todo/bug/art (add); also filters list."),
				doc_param("at", "Vector3", false, "World position for a NEW marker note (add). Provide --at or --node-path."),
				doc_param("node_path", "NodePath", false, "Existing node to attach to (add), or the note to resolve/delete (resolve)."),
				doc_param("name", "String", false, "Name for a new marker (add)."),
				doc_param("label", "bool", false, "Add a billboard label (add; default true)."),
				doc_param("screenshot", "String", false, "Screenshot path stored on the note (add)."),
				doc_param("link", "String", false, "Reference URL stored on the note (add)."),
				doc_param("author", "String", false, "Author stored on the note (add)."),
				doc_param("include_resolved", "bool", false, "Include resolved notes (list; default false)."),
				doc_param("delete", "bool", false, "Delete the marker/note instead of marking resolved (resolve)."),
				doc_param("unresolve", "bool", false, "Mark unresolved instead of resolved (resolve)."),
			],
		},
		"doc.metric": {
			"description": "Add a labeled, colour-coded metric station (gap/height/slope/distance) as runnable geometry, the gym building block. 3D scene. Undoable.",
			"params": [
				doc_param("type", "String", false, "gap, height, slope, or distance (default distance)."),
				doc_param("value", "float", false, "The metric value in meters (or degrees for slope; default 1.0)."),
				doc_param("difficulty", "String", false, "easy, hard, impossible, or info (colour; default info)."),
				doc_param("width", "float", false, "Pad/bar width (default 1.0)."),
				doc_param("at", "Vector3", false, "Local position of the station."),
				doc_param("label", "String", false, "Override the auto label text."),
				doc_param("name", "String", false, "Container node name."),
				doc_param("parent", "NodePath", false, "Parent node (default the scene root)."),
			],
		},
		"doc.gym": {
			"description": "Scaffold a metrics gym: rows of jump gaps, step heights, and slope ramps at increasing values, colour-graded easy to impossible and labeled, the source of truth for character-controller metrics. 3D scene. Undoable.",
			"params": [
				doc_param("gaps", "Array", false, "JSON array of gap distances (default [1,2,3,4,5])."),
				doc_param("heights", "Array", false, "JSON array of step heights (default [0.3,0.6,1.0,1.5])."),
				doc_param("slopes", "Array", false, "JSON array of slope angles in degrees (default [20,30,40,50])."),
				doc_param("spacing", "float", false, "Spacing between stations (default 3.0)."),
				doc_param("ground", "bool", false, "Add a ground plane (default true)."),
				doc_param("at", "Vector3", false, "Local position of the gym."),
				doc_param("name", "String", false, "Container node name (default 'Gym')."),
				doc_param("parent", "NodePath", false, "Parent node (default the scene root)."),
			],
		},
		"doc.zoo": {
			"description": "Lay out a folder (--from) or explicit list (--scenes) of assets in a labeled grid with scale references and lighting, to see every asset's scale/look at a glance. 3D scene. Undoable.",
			"params": [
				doc_param("from", "String", false, "Directory of assets to lay out. Provide --from or --scenes."),
				doc_param("scenes", "Array", false, "JSON array of asset paths. Provide --from or --scenes."),
				doc_param("spacing", "float", false, "Grid cell spacing (default 3.0)."),
				doc_param("cols", "int", false, "Grid columns (default ~sqrt of count)."),
				doc_param("ground", "bool", false, "Add a ground plane (default true)."),
				doc_param("lighting", "bool", false, "Add a DirectionalLight3D (default true)."),
				doc_param("scale_ref", "bool", false, "Add 1m/2m/1.8m scale references (default true)."),
				doc_param("at", "Vector3", false, "Local position of the zoo."),
				doc_param("name", "String", false, "Container node name (default 'Zoo')."),
				doc_param("parent", "NodePath", false, "Parent node (default the scene root)."),
			],
		},
		"doc.museum": {
			"description": "Scaffold a row of labeled exhibit pads, each carrying a doc-note (with an API-docs link), to drop a live demo onto each pad. 3D scene. Undoable.",
			"params": [
				doc_param("exhibits", "Array", true, "JSON array of exhibit names or {name, link, text} objects."),
				doc_param("spacing", "float", false, "Spacing between pads (default 5.0)."),
				doc_param("at", "Vector3", false, "Local position of the museum."),
				doc_param("name", "String", false, "Container node name (default 'Museum')."),
				doc_param("parent", "NodePath", false, "Parent node (default the scene root)."),
			],
		},
	}
