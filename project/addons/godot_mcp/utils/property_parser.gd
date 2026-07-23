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
	for prefix in ["Vector3i(", "Vector3(", "Vector2i(", "Vector2(", "Rect2(", "Color(", "("]:
		if cleaned.begins_with(prefix):
			cleaned = cleaned.substr(prefix.length())
			break
	cleaned = cleaned.trim_suffix(")").strip_edges()
	var out: PackedFloat64Array = []
	for part in cleaned.split(",", false):
		out.append(part.strip_edges().to_float())
	return out


static func _vec(value: Variant, _dim: int) -> Vector2:
	if value is Vector2: return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
	var n := _numbers(str(value))
	return Vector2(n[0], n[1]) if n.size() >= 2 else Vector2.ZERO


static func _vec3(value: Variant) -> Vector3:
	if value is Vector3: return value
	if value is Dictionary:
		return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
	var n := _numbers(str(value))
	return Vector3(n[0], n[1], n[2]) if n.size() >= 3 else Vector3.ZERO


static func _rect2(value: Variant) -> Rect2:
	if value is Rect2: return value
	var n := _numbers(str(value))
	return Rect2(n[0], n[1], n[2], n[3]) if n.size() >= 4 else Rect2()


static func _color(value: Variant) -> Color:
	if value is Color: return value
	var s := str(value)
	if s.begins_with("#"): return Color.html(s)
	if s.begins_with("Color("):
		var n := _numbers(s)
		if n.size() == 4: return Color(n[0], n[1], n[2], n[3])
		if n.size() == 3: return Color(n[0], n[1], n[2])
	if Color.html_is_valid(s): return Color.html(s)
	return Color.WHITE


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
