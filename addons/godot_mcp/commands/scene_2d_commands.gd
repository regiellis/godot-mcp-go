@tool
extends "res://addons/godot_mcp/commands/base_command.gd"

## 2D scene-assembly helpers — the canvas-side counterpart to scene3d, for the 2D
## workflows that are tedious through raw node.add: a Sprite2D with its texture, a
## configured Camera2D, and (the biggest win) a physics body with its CollisionShape2D
## and shape resource wired in one call. scene3d has no body/collision helper either,
## so add_body has no 3D twin yet. All commands require a non-Node3D (canvas) scene root.

const _BODY_TYPES := ["StaticBody2D", "CharacterBody2D", "RigidBody2D", "Area2D"]
const _SHAPES := ["rectangle", "circle", "capsule"]


func get_commands() -> Dictionary:
	return {
		"scene2d.add_sprite": _add_sprite,
		"scene2d.add_camera": _add_camera,
		"scene2d.add_body": _add_body,
		"scene2d.add_animated_sprite": _add_animated_sprite,
	}


func _v2(params: Dictionary, key: String, default: Vector2) -> Vector2:
	return vec2_param(params, key, default)


## 2D assembly needs a canvas (non-3D) scene. Returns [root, error_or_null].
func _root_2d() -> Array:
	var root := get_edited_root()
	if root == null:
		return [null, error_no_scene()]
	if root is Node3D:
		return [null, error_invalid_params("2D assembly needs a 2D scene (root is a Node3D)")]
	return [root, null]


func _parent(params: Dictionary, root: Node) -> Node:
	return find_node_by_path(optional_string(params, "parent_path", optional_string(params, "parent", ".")))


# --- add_animated_sprite ----------------------------------------------------

## AnimatedSprite2D + SpriteFrames authored from a spritesheet grid in one call.
## --hframes/--vframes slice the sheet; --animations maps names to grid frame
## indices (row-major): '{"walk":{"frames":[0,1,2,3],"fps":8,"loop":true}}'.
## Without --animations, every frame lands in one looping "default" animation.
func _add_animated_sprite(params: Dictionary) -> Dictionary:
	var rr := _root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := _parent(params, root)
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))
	var rt := require_string(params, "texture")
	if rt[1] != null:
		return rt[1]
	var tex_path: String = rt[0]
	if not ResourceLoader.exists(tex_path, "Texture2D"):
		return error_not_found("Texture '%s'" % tex_path)

	var hframes := maxi(1, optional_int(params, "hframes", 1))
	var vframes := maxi(1, optional_int(params, "vframes", 1))
	var sheet: Texture2D = load(tex_path)
	var frame_size := Vector2(sheet.get_width() / float(hframes), sheet.get_height() / float(vframes))
	var frame_count := hframes * vframes

	# One AtlasTexture per grid cell, row-major, reused across animations.
	var atlases: Array[AtlasTexture] = []
	for i in frame_count:
		var at := AtlasTexture.new()
		at.atlas = sheet
		@warning_ignore("integer_division")
		at.region = Rect2(Vector2(i % hframes, i / hframes) * frame_size, frame_size)
		atlases.append(at)

	var frames := SpriteFrames.new()
	var anims: Dictionary = params.get("animations", {})
	if anims.is_empty():
		anims = {"default": {"frames": range(frame_count), "fps": 8.0, "loop": true}}
	var built: Array = []
	for anim_name: String in anims:
		var spec: Dictionary = anims[anim_name]
		var fr := require_array(spec, "frames")
		if fr[1] != null:
			return error_invalid_params("animation '%s' needs a frames array of grid indices" % anim_name)
		if not frames.has_animation(StringName(anim_name)):
			frames.add_animation(StringName(anim_name))
		frames.set_animation_speed(StringName(anim_name), float(spec.get("fps", 8.0)))
		frames.set_animation_loop(StringName(anim_name), bool(spec.get("loop", true)))
		for idx in fr[0]:
			var i := int(idx)
			if i < 0 or i >= frame_count:
				return error_invalid_params("animation '%s': frame index %d out of range (sheet has %d frames)" % [anim_name, i, frame_count])
			frames.add_frame(StringName(anim_name), atlases[i])
		built.append({"name": anim_name, "frames": (fr[0] as Array).size()})
	# A fresh SpriteFrames carries an empty built-in "default" animation; drop it
	# when the caller authored their own set that doesn't use the name.
	if not anims.has("default") and frames.has_animation(&"default"):
		frames.remove_animation(&"default")

	# Param dicts arrive orderless over the wire, so "first animation" is
	# nondeterministic — pick deterministically: "default", else alphabetical.
	var anim_names: Array = anims.keys()
	anim_names.sort()
	var start_anim: String = "default" if anims.has("default") else String(anim_names[0])

	var node := AnimatedSprite2D.new()
	node.name = optional_string(params, "name", "AnimatedSprite2D")
	node.sprite_frames = frames
	node.animation = StringName(start_anim)
	# --autoplay accepts a bare flag (start animation) or an animation name.
	var autoplay := str(params.get("autoplay", ""))
	if autoplay == "true":
		node.autoplay = start_anim
	elif not autoplay.is_empty() and autoplay != "false":
		if not frames.has_animation(StringName(autoplay)):
			return error_invalid_params("autoplay animation '%s' does not exist" % autoplay)
		node.autoplay = autoplay
		node.animation = StringName(autoplay)
	node.position = _v2(params, "position", Vector2.ZERO)

	add_child_with_undo(parent, node, root, "MCP: Add AnimatedSprite2D")
	return success({
		"node_path": str(root.get_path_to(node)),
		"name": String(node.name),
		"frame_size": [frame_size.x, frame_size.y],
		"sheet_frames": frame_count,
		"animations": built,
	})


# --- add_sprite -------------------------------------------------------------

func _add_sprite(params: Dictionary) -> Dictionary:
	var rr := _root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := _parent(params, root)
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var node := Sprite2D.new()
	node.name = optional_string(params, "name", "Sprite2D")
	var tex_note := ""
	var tex_path := optional_string(params, "texture", "")
	if not tex_path.is_empty():
		if not tex_path.begins_with("res://"):
			return error_invalid_params("--texture must be a res:// path")
		if not ResourceLoader.exists(tex_path):
			tex_note = "texture '%s' not found; sprite created without one" % tex_path
		else:
			var tex := load(tex_path)
			if tex is Texture2D:
				node.texture = tex
			else:
				tex_note = "'%s' is not a Texture2D; sprite created without one" % tex_path
	if params.has("centered"):
		node.centered = optional_bool(params, "centered", true)
	node.position = _v2(params, "position", Vector2.ZERO)
	add_child_with_undo(parent, node, root, "MCP: Add Sprite2D")
	var out := {"node_path": str(root.get_path_to(node)), "name": String(node.name), "has_texture": node.texture != null}
	if not tex_note.is_empty():
		out["note"] = tex_note
	return success(out)


# --- add_camera -------------------------------------------------------------

func _add_camera(params: Dictionary) -> Dictionary:
	var rr := _root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := _parent(params, root)
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var node := Camera2D.new()
	node.name = optional_string(params, "name", "Camera2D")
	if params.has("zoom"):
		# Accept a scalar (uniform) or a Vector2.
		var z: Variant = params["zoom"]
		if (z is float or z is int) or (z is String and not str(z).begins_with("Vector2")):
			var s := float(z)
			node.zoom = Vector2(s, s)
		else:
			node.zoom = _v2(params, "zoom", Vector2.ONE)
	# In Godot 4 a Camera2D is active when enabled; default to making this one current.
	node.enabled = optional_bool(params, "current", true)
	node.position = _v2(params, "position", Vector2.ZERO)
	add_child_with_undo(parent, node, root, "MCP: Add Camera2D")
	return success({
		"node_path": str(root.get_path_to(node)), "name": String(node.name),
		"zoom": PropertyParser.serialize_value(node.zoom), "current": node.enabled,
	})


# --- add_body ---------------------------------------------------------------

## A physics body with its CollisionShape2D + shape resource, wired in one call.
func _add_body(params: Dictionary) -> Dictionary:
	var rr := _root_2d()
	if rr[1] != null:
		return rr[1]
	var root: Node = rr[0]
	var parent := _parent(params, root)
	if parent == null:
		return error_not_found("Parent node '%s'" % optional_string(params, "parent_path", "."))

	var type := optional_string(params, "type", "StaticBody2D")
	if type not in _BODY_TYPES:
		return error_invalid_params("type must be one of %s" % [_BODY_TYPES])
	var shape_kind := optional_string(params, "shape", "rectangle").to_lower()
	if shape_kind not in _SHAPES:
		return error_invalid_params("shape must be one of %s" % [_SHAPES])

	var shape: Shape2D = null
	match shape_kind:
		"rectangle":
			var rect := RectangleShape2D.new()
			rect.size = _v2(params, "size", Vector2(32, 32))
			shape = rect
		"circle":
			var circ := CircleShape2D.new()
			circ.radius = float(params.get("radius", 16.0))
			shape = circ
		"capsule":
			var cap := CapsuleShape2D.new()
			cap.radius = float(params.get("radius", 16.0))
			cap.height = float(params.get("height", 32.0))
			shape = cap

	var body: Node2D = ClassDB.instantiate(type)
	body.name = optional_string(params, "name", type)
	body.position = _v2(params, "position", Vector2.ZERO)
	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	col.shape = shape

	# Two committed actions: body under parent, then its collision child — both owned
	# by root so they persist in the saved scene.
	add_child_with_undo(parent, body, root, "MCP: Add %s" % type)
	add_child_with_undo(body, col, root, "MCP: Add CollisionShape2D")
	return success({
		"node_path": str(root.get_path_to(body)), "name": String(body.name), "type": type,
		"collision_path": str(root.get_path_to(col)), "shape": shape_kind,
	})


## Every scene2d.* command requires a non-Node3D (canvas) scene root and is undoable.
func get_command_docs() -> Dictionary:
	return {
		"scene2d.add_sprite": {
			"description": "Add a Sprite2D (optionally with a --texture) under --parent-path in a 2D scene.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.'; --parent alias)."),
				doc_param("name", "String", false, "Node name (default 'Sprite2D')."),
				doc_param("texture", "String", false, "res:// path to a Texture2D."),
				doc_param("centered", "bool", false, "Center the texture on the node origin."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
		"scene2d.add_camera": {
			"description": "Add a Camera2D under --parent-path in a 2D scene, current by default.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("name", "String", false, "Node name (default 'Camera2D')."),
				doc_param("zoom", "Vector2", false, "Zoom: a scalar (uniform) or a Vector2."),
				doc_param("current", "bool", false, "Make this the active camera (default true)."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
		"scene2d.add_body": {
			"description": "Add a 2D physics body with its CollisionShape2D and shape resource wired in one call.",
			"params": [
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("name", "String", false, "Body node name (default the type)."),
				doc_param("type", "String", false, "StaticBody2D (default), CharacterBody2D, RigidBody2D, or Area2D."),
				doc_param("shape", "String", false, "rectangle (default), circle, or capsule."),
				doc_param("size", "Vector2", false, "Rectangle size (default 32x32)."),
				doc_param("radius", "float", false, "Circle/capsule radius (default 16)."),
				doc_param("height", "float", false, "Capsule height (default 32)."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
		"scene2d.add_animated_sprite": {
			"description": "Add an AnimatedSprite2D with a SpriteFrames authored from a spritesheet grid. --hframes/--vframes slice the sheet; --animations maps names to row-major frame indices.",
			"params": [
				doc_param("texture", "String", true, "res:// path to the spritesheet Texture2D."),
				doc_param("parent_path", "NodePath", false, "Parent to add under (default '.')."),
				doc_param("name", "String", false, "Node name (default 'AnimatedSprite2D')."),
				doc_param("hframes", "int", false, "Horizontal grid cells (default 1)."),
				doc_param("vframes", "int", false, "Vertical grid cells (default 1)."),
				doc_param("animations", "Dictionary", false, "{name: {frames:[...], fps, loop}} over grid indices; default one looping 'default'."),
				doc_param("autoplay", "String", false, "Animation to autoplay (a bare flag = the start animation)."),
				doc_param("position", "Vector2", false, "Local position."),
			],
		},
	}
