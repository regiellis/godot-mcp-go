@tool
extends RefCounted

## Converts loosely-typed wire values (usually strings from the CLI) into Godot
## types, and serializes Godot types back into JSON-safe values. Strings like
## "Vector2(10, 20)", "#ff0000", "true" are recognized.

## Parse `value` toward `target_type` (the type of the property being set).
## TYPE_NIL means "infer from the string".
static func parse_value(value: Variant, target_type: int = TYPE_NIL) -> Variant:
	if value == null:
		return null
	if target_type == TYPE_NIL:
		return _auto_parse(value)

	match target_type:
		TYPE_BOOL:
			if value is bool: return value
			if value is String: return (value as String).to_lower() in ["true", "1", "yes"]
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			return _vec(value, 2)
		TYPE_VECTOR2I:
			var v: Vector2 = _vec(value, 2)
			return Vector2i(int(v.x), int(v.y))
		TYPE_VECTOR3:
			return _vec3(value)
		TYPE_VECTOR3I:
			var v: Vector3 = _vec3(value)
			return Vector3i(int(v.x), int(v.y), int(v.z))
		TYPE_RECT2:
			return _rect2(value)
		TYPE_COLOR:
			return _color(value)
		TYPE_NODE_PATH:
			return NodePath(str(value))
		TYPE_ARRAY:
			return value if value is Array else [value]
		TYPE_DICTIONARY:
			return value if value is Dictionary else {}
		TYPE_PACKED_VECTOR2_ARRAY:
			var v2out := PackedVector2Array()
			for item in _as_array(value):
				v2out.append(_vec(item, 2))
			return v2out
		TYPE_PACKED_VECTOR3_ARRAY:
			var v3out := PackedVector3Array()
			for item in _as_array(value):
				v3out.append(_vec3(item))
			return v3out
		TYPE_PACKED_COLOR_ARRAY:
			var cout := PackedColorArray()
			for item in _as_array(value):
				cout.append(_color(item))
			return cout
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var fout: Array[float] = []
			for item in _as_array(value):
				fout.append(float(item))
			return PackedFloat64Array(fout) if target_type == TYPE_PACKED_FLOAT64_ARRAY else PackedFloat32Array(fout)
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			var iout: Array[int] = []
			for item in _as_array(value):
				iout.append(int(item))
			return PackedInt64Array(iout) if target_type == TYPE_PACKED_INT64_ARRAY else PackedInt32Array(iout)
		TYPE_PACKED_STRING_ARRAY:
			var sout := PackedStringArray()
			for item in _as_array(value):
				sout.append(str(item))
			return sout
		_:
			return value


static func _as_array(value: Variant) -> Array:
	return value if value is Array else [value]


static func _auto_parse(value: Variant) -> Variant:
	if not value is String:
		return value
	var s: String = value
	if s == "true": return true
	if s == "false": return false
	if s.is_valid_int(): return s.to_int()
	if s.is_valid_float(): return s.to_float()
	if s.begins_with("Vector2(") or s.begins_with("Vector2i("): return _vec(s, 2)
	if s.begins_with("Vector3(") or s.begins_with("Vector3i("): return _vec3(s)
	if s.begins_with("Rect2("): return _rect2(s)
	if s.begins_with("Color(") or s.begins_with("#"): return _color(s)
	return s


static func _numbers(s: String) -> PackedFloat64Array:
	var cleaned := s
	for prefix in ["Vector4i(", "Vector4(", "Vector3i(", "Vector3(", "Vector2i(", "Vector2(", "Rect2i(", "Rect2(", "Color(", "Quaternion(", "(", "["]:
		if cleaned.begins_with(prefix):
			cleaned = cleaned.substr(prefix.length())
			break
	# Trim both bracket styles: a JSON array reached this path as "[28, 28]", and
	# leaving the '[' made "[28".to_float() == 0.0, i.e. Vector2(0, 28).
	cleaned = cleaned.trim_suffix(")").trim_suffix("]").strip_edges()
	var out: PackedFloat64Array = []
	for part in cleaned.split(",", false):
		out.append(part.strip_edges().to_float())
	return out


## Arrays are handled element-wise, never stringified: `str([28, 28])` is
## "[28, 28]", which the number scanner used to read as (0, 28).
static func _vec(value: Variant, _dim: int) -> Vector2:
	if value is Vector2: return value
	if value is Vector2i: return Vector2(value)
	if value is Array:
		var a: Array = value
		return Vector2(float(a[0]), float(a[1])) if a.size() >= 2 else Vector2.ZERO
	if value is Dictionary:
		return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
	var n := _numbers(str(value))
	return Vector2(n[0], n[1]) if n.size() >= 2 else Vector2.ZERO


static func _vec3(value: Variant) -> Vector3:
	if value is Vector3: return value
	if value is Vector3i: return Vector3(value)
	if value is Array:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector3.ZERO
	if value is Dictionary:
		return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
	var n := _numbers(str(value))
	return Vector3(n[0], n[1], n[2]) if n.size() >= 3 else Vector3.ZERO


static func _rect2(value: Variant) -> Rect2:
	if value is Rect2: return value
	if value is Array:
		var a: Array = value
		return Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3])) if a.size() >= 4 else Rect2()
	var n := _numbers(str(value))
	return Rect2(n[0], n[1], n[2], n[3]) if n.size() >= 4 else Rect2()


static func _color(value: Variant) -> Color:
	if value is Color: return value
	if value is Array:
		var a: Array = value
		if a.size() >= 4: return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		if a.size() >= 3: return Color(float(a[0]), float(a[1]), float(a[2]))
		return Color.WHITE
	if value is Dictionary:
		return Color(float(value.get("r", 0)), float(value.get("g", 0)), float(value.get("b", 0)), float(value.get("a", 1)))
	var s := str(value)
	if s.begins_with("#"): return Color.html(s)
	if s.begins_with("Color("):
		var n := _numbers(s)
		if n.size() == 4: return Color(n[0], n[1], n[2], n[3])
		if n.size() == 3: return Color(n[0], n[1], n[2])
	if Color.html_is_valid(s): return Color.html(s)
	return Color.WHITE


## Resolve the DECLARED type of `property` on `obj`, which is what a value has to
## coerce to. Callers used to pass `typeof(obj.get(prop))`, which reads the CURRENT
## value and lies twice: a null Resource property reports TYPE_NIL (so a res:// path
## was passed through as a String and silently rejected on assign), and a property
## already holding Vector2(0,0) is indistinguishable from one holding an int.
## Returns {found, type, class_name}; class_name is set for Object properties.
## The method entry from an object's own method list, or {} when absent.
static func method_info(obj: Object, method: String) -> Dictionary:
	if obj == null:
		return {}
	for m: Dictionary in obj.get_method_list():
		if String(m["name"]) == method:
			return m
	return {}


## Coerce positional arguments toward a method's declared parameter types.
## Returns {ok, args, reason}.
##
## Shared by node.call (editor) and the inspector's call_node_method (game), which
## must agree: a caller sends JSON either way, so "Vector3(1,2,3)" arrives as a
## String and would be passed straight through as one. A TYPE_NIL parameter is an
## untyped Variant and takes its value unchanged.
static func coerce_call_args(info: Dictionary, raw: Array, method: String) -> Dictionary:
	var expected: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var required := expected.size() - defaults.size()
	if raw.size() < required or raw.size() > expected.size():
		var shape := "%d" % expected.size() if defaults.is_empty() else "%d-%d" % [required, expected.size()]
		return {
			"ok": false,
			"args": [],
			"reason": "%s() takes %s argument(s), got %d" % [method, shape, raw.size()],
		}

	var out: Array = []
	for i in range(raw.size()):
		var want: Dictionary = expected[i]
		var want_type := int(want["type"])
		if want_type == TYPE_NIL:
			out.append(raw[i])
			continue
		var parsed := parse_checked(raw[i], want_type, String(want.get("class_name", "")))
		if not parsed["ok"]:
			return {
				"ok": false,
				"args": [],
				"reason": "argument %d ('%s'): %s" % [i + 1, want["name"], parsed["reason"]],
			}
		out.append(parsed["value"])
	return {"ok": true, "args": out, "reason": ""}


static func declared_type(obj: Object, property: String) -> Dictionary:
	if obj == null:
		return {"found": false, "type": TYPE_NIL, "class_name": ""}
	for p in obj.get_property_list():
		if String(p.get("name", "")) != property:
			continue
		var cls := String(p.get("class_name", ""))
		if cls.is_empty():
			cls = String(p.get("hint_string", ""))
		return {"found": true, "type": int(p.get("type", TYPE_NIL)), "class_name": cls}
	return {"found": false, "type": TYPE_NIL, "class_name": ""}


## Strict counterpart to parse_value: returns {ok, value, reason} and REFUSES a
## coercion it cannot perform, instead of substituting a zero or a default. That is
## the difference between `area_size = 34` quietly becoming Vector2(0, 0) with a
## success envelope and an error naming the literal the property wanted. Also loads
## res:// / uid:// strings into real Resource references, which a bare assignment
## drops on the floor.
##
## Use this on every write path. parse_value stays for read/convenience callers.
static func parse_checked(value: Variant, target_type: int, expected_class: String = "") -> Dictionary:
	if value == null:
		return {"ok": true, "value": null, "reason": ""}

	# Resource / Object properties: a path has to be LOADED, never assigned as text.
	if target_type == TYPE_OBJECT:
		if value is Object:
			return {"ok": true, "value": value, "reason": ""}
		var s := str(value).strip_edges()
		if s.is_empty():
			return {"ok": true, "value": null, "reason": ""}
		if s.begins_with("res://") or s.begins_with("uid://"):
			var res: Resource = ResourceLoader.load(s)
			if res == null:
				return {"ok": false, "value": null, "reason": "could not load resource '%s'" % s}
			if not expected_class.is_empty() and not _is_a(res, expected_class):
				return {"ok": false, "value": null, "reason": "'%s' is a %s but the property expects %s" % [s, res.get_class(), expected_class]}
			return {"ok": true, "value": res, "reason": ""}
		var want := expected_class if not expected_class.is_empty() else "Object"
		return {"ok": false, "value": null, "reason": "expected a res:// or uid:// path for the %s property, got '%s'" % [want, s]}

	# Composite numeric types: the lenient path pads with zeros when the input is
	# short, which is how a scalar became Vector2(0, 0).
	var needed := _components_needed(target_type)
	if needed > 0 and not _has_components(value, target_type, needed):
		return {"ok": false, "value": null, "reason": "expected %d numbers for %s (e.g. \"%s\"), got '%s'" % [needed, _type_label(target_type), _literal_example(target_type), str(value)]}

	return {"ok": true, "value": parse_value(value, target_type), "reason": ""}


static func _is_a(res: Object, cls: String) -> bool:
	# hint_string can carry a comma list ("Texture2D,-AtlasTexture,...") or a
	# script class_name that ClassDB has never heard of; accept either.
	for part in cls.split(","):
		var want := part.strip_edges()
		if want.is_empty() or want.begins_with("-"):
			continue
		if res.is_class(want):
			return true
		if ClassDB.class_exists(want) and ClassDB.is_parent_class(res.get_class(), want):
			return true
		var scr := res.get_script()
		if scr != null and scr is Script:
			var gname := String((scr as Script).get_global_name())
			if gname == want:
				return true
	return false


static func _components_needed(target_type: int) -> int:
	match target_type:
		TYPE_VECTOR2, TYPE_VECTOR2I: return 2
		TYPE_VECTOR3, TYPE_VECTOR3I: return 3
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION: return 4
		TYPE_RECT2, TYPE_RECT2I: return 4
		TYPE_COLOR: return 3
		_: return 0


static func _has_components(value: Variant, target_type: int, needed: int) -> bool:
	if typeof(value) == target_type:
		return true
	if value is Dictionary:
		var keys := ["x", "y", "z", "w"] if target_type != TYPE_COLOR else ["r", "g", "b"]
		var have := 0
		for k in keys:
			if (value as Dictionary).has(k):
				have += 1
		return have >= needed
	if value is Array:
		return (value as Array).size() >= needed
	if target_type == TYPE_COLOR:
		var cs := str(value).strip_edges()
		if cs.begins_with("#") or Color.html_is_valid(cs):
			return true
	return _numbers(str(value)).size() >= needed


static func _type_label(target_type: int) -> String:
	match target_type:
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_RECT2: return "Rect2"
		TYPE_RECT2I: return "Rect2i"
		TYPE_COLOR: return "Color"
		_: return "value"


static func _literal_example(target_type: int) -> String:
	match target_type:
		TYPE_VECTOR2, TYPE_VECTOR2I: return "Vector2(34, 34)"
		TYPE_VECTOR3, TYPE_VECTOR3I: return "Vector3(1, 2, 3)"
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION: return "Vector4(0, 0, 0, 1)"
		TYPE_RECT2, TYPE_RECT2I: return "Rect2(0, 0, 10, 10)"
		TYPE_COLOR: return "Color(1, 0, 0, 1)"
		_: return ""


## Serialize a Variant into a JSON-safe value for the response.
static func serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_RECT2, TYPE_RECT2I:
			return {"x": value.position.x, "y": value.position.y, "width": value.size.x, "height": value.size.y}
		TYPE_COLOR:
			var c: Color = value
			return {"r": c.r, "g": c.g, "b": c.b, "a": c.a, "html": "#" + c.to_html()}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_OBJECT:
			if value is Resource:
				var res: Resource = value
				return {"type": res.get_class(), "path": res.resource_path}
			return str(value)
		TYPE_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, \
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for key in value:
				d[str(key)] = serialize_value(value[key])
			return d
		_:
			return value
