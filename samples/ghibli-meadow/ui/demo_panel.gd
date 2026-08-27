extends CanvasLayer
## Reusable in-game tuning panel for demo scenes. Builds a "material" tab live
## from a ShaderMaterial's uniform list (hint_range floats become sliders,
## source_color colors pickers, bools checkboxes, vectors per-component
## spinboxes, group_uniforms headers). The target is the first GeometryInstance3D in
## `material_group` whose material_override is a ShaderMaterial. If the target
## node's script has get_presets() -> {name: {uniform: value}}, those appear in
## a preset picker beside the always-present "Demo Default" startup snapshot.
## Tab toggles the panel; an FPS counter stays on either way.

const SKIPPED_PARAMS: Array[String] = ["wave_time"]
const PANEL_WIDTH := 440.0

@export var panel_title := "Demo"
@export var hint_text := "Tab: panel  |  RMB: look  WASD: fly"
@export var material_tab_title := "Material"
@export var material_group := "water"

var _material: ShaderMaterial
var _target: GeometryInstance3D
var _tabs: TabContainer
var _root_control: Control
var _fps_label: Label
var _fps_accum := 0.0
var _material_list: VBoxContainer
var _default_preset := {}


func _ready() -> void:
	layer = 10
	_fps_label = Label.new()
	_fps_label.position = Vector2(16, 12)
	_fps_label.add_theme_font_size_override("font_size", 16)
	_fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps_label.add_theme_constant_override("outline_size", 4)
	add_child(_fps_label)
	await get_tree().process_frame
	_build_ui()


func _process(delta: float) -> void:
	_fps_accum -= delta
	if _fps_accum <= 0.0:
		_fps_accum = 0.25
		var fps := Engine.get_frames_per_second()
		_fps_label.text = "FPS %d" % fps
		_fps_label.add_theme_color_override("font_color",
			Color(0.55, 0.95, 0.55) if fps >= 60 else Color(0.95, 0.85, 0.4) if fps >= 30 else Color(0.95, 0.45, 0.4))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_root_control.visible = not _root_control.visible


func _build_ui() -> void:
	_root_control = MarginContainer.new()
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_root_control.offset_left = -PANEL_WIDTH
	for m in ["margin_top", "margin_bottom", "margin_right"]:
		_root_control.add_theme_constant_override(m, 12)
	add_child(_root_control)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.1, 0.13, 0.82)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	_root_control.add_child(panel)

	var box := VBoxContainer.new()
	panel.add_child(box)

	var title := Label.new()
	title.text = panel_title
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var hint := Label.new()
	hint.text = hint_text
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	box.add_child(hint)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_tabs)

	_build_material_tab()
	_build_field_tab()


func _tab_scroll(tab_title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return list


# --- Material tab (shader uniforms) -----------------------------------------

func _build_material_tab() -> void:
	var list := _tab_scroll(material_tab_title)
	for node in get_tree().get_nodes_in_group(material_group):
		if node is GeometryInstance3D and node.material_override is ShaderMaterial:
			_target = node
			break
	if _target == null:
		list.add_child(_note("No ShaderMaterial found in group \"%s\"." % material_group))
		return
	_material = _target.material_override
	_default_preset = _snapshot_preset()

	var presets := {}
	if _target.get_script() != null and _target.has_method("get_presets"):
		presets = _target.get_presets()

	var preset_row := HBoxContainer.new()
	var preset_label := Label.new()
	preset_label.text = "Preset"
	preset_label.add_theme_font_size_override("font_size", 13)
	preset_row.add_child(preset_label)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_item("Demo Default")
	for preset_name in presets:
		picker.add_item(preset_name)
	picker.item_selected.connect(func(index: int) -> void:
		var chosen: Dictionary = _default_preset if index == 0 else presets[picker.get_item_text(index)]
		_apply_preset(chosen))
	preset_row.add_child(picker)
	list.add_child(preset_row)

	_material_list = VBoxContainer.new()
	_material_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_child(_material_list)
	_populate_material()


func _snapshot_preset() -> Dictionary:
	var out := {}
	for u in _material.shader.get_shader_uniform_list(true):
		var uname: String = u["name"]
		if u["usage"] & PROPERTY_USAGE_GROUP or uname in SKIPPED_PARAMS or u["type"] == TYPE_OBJECT:
			continue
		var value: Variant = _material.get_shader_parameter(uname)
		if value == null:
			value = RenderingServer.shader_get_parameter_default(_material.shader.get_rid(), uname)
		out[uname] = value
	return out


func _apply_preset(preset: Dictionary) -> void:
	for uname in preset:
		_material.set_shader_parameter(uname, preset[uname])
	_populate_material()


func _populate_material() -> void:
	for child in _material_list.get_children():
		child.queue_free()
	for u in _material.shader.get_shader_uniform_list(true):
		var uname: String = u["name"]
		if u["usage"] & PROPERTY_USAGE_GROUP:
			if not uname.is_empty():
				_add_header(_material_list, uname.capitalize())
			continue
		if uname in SKIPPED_PARAMS or u["type"] == TYPE_OBJECT:
			continue
		var value: Variant = _material.get_shader_parameter(uname)
		if value == null:
			value = RenderingServer.shader_get_parameter_default(_material.shader.get_rid(), uname)
		var setter := func(v: Variant) -> void: _material.set_shader_parameter(uname, v)
		var getter := func() -> Variant: return _material.get_shader_parameter(uname)
		_add_control(_material_list, uname, u, value, setter, getter)


# --- Field tab (the target node's own script exports) ------------------------

## Reflects the target's exported script properties (builder params like
## density and blade shape) with a Rebuild button that pokes its `rebuild`
## export. Skipped entirely when the target has no script exports.
func _build_field_tab() -> void:
	if _target == null or _target.get_script() == null:
		return
	# Group entries carry only PROPERTY_USAGE_GROUP, native categories included,
	# so a group header is kept only once a script export actually follows it.
	var entries: Array[Dictionary] = []
	var pending_group := ""
	for p in _target.get_property_list():
		if p["usage"] & PROPERTY_USAGE_GROUP:
			pending_group = p["name"]
			continue
		if not (p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and p["usage"] & PROPERTY_USAGE_EDITOR):
			continue
		if p["name"] == "rebuild" or p["type"] in [TYPE_OBJECT, TYPE_RID, TYPE_NODE_PATH]:
			continue
		if not pending_group.is_empty():
			entries.append({"group": pending_group})
			pending_group = ""
		entries.append(p)
	if entries.is_empty():
		return
	var list := _tab_scroll("Field")

	if "rebuild" in _target:
		var rebuild := Button.new()
		rebuild.text = "Rebuild"
		rebuild.pressed.connect(func() -> void: _target.set("rebuild", true))
		list.add_child(rebuild)

	for e in entries:
		if e.has("group"):
			_add_header(list, str(e["group"]))
			continue
		var pname: String = e["name"]
		var setter := func(v: Variant) -> void: _target.set(pname, v)
		var getter := func() -> Variant: return _target.get(pname)
		_add_control(list, pname, e, _target.get(pname), setter, getter)


# --- Shared control builders ------------------------------------------------

func _add_control(list: VBoxContainer, pname: String, info: Dictionary, value: Variant, setter: Callable, getter: Callable) -> void:
	match info["type"]:
		TYPE_FLOAT:
			if info["hint"] == PROPERTY_HINT_RANGE:
				_add_slider(list, pname, info["hint_string"], value, setter, false)
			else:
				_add_spinbox(list, pname, value, setter, false)
		TYPE_INT:
			if info["hint"] == PROPERTY_HINT_RANGE:
				_add_slider(list, pname, info["hint_string"], value, setter, true)
			else:
				_add_spinbox(list, pname, value, setter, true)
		TYPE_BOOL:
			_add_checkbox(list, pname, value, setter)
		TYPE_COLOR:
			_add_color(list, pname, value, setter)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			_add_vector(list, pname, value, setter, getter)


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _add_header(list: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.4))
	list.add_child(label)


func _param_row(list: VBoxContainer, pname: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = pname.capitalize()
	label.custom_minimum_size = Vector2(140, 0)
	label.add_theme_font_size_override("font_size", 13)
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	row.add_child(label)
	list.add_child(row)
	return row


func _add_slider(list: VBoxContainer, pname: String, hint_string: String, value: Variant, setter: Callable, integer: bool) -> void:
	var parts := hint_string.split(",")
	var row := _param_row(list, pname)
	var slider := HSlider.new()
	slider.min_value = parts[0].to_float() if parts.size() > 0 else 0.0
	slider.max_value = parts[1].to_float() if parts.size() > 1 else 1.0
	slider.step = parts[2].to_float() if parts.size() > 2 else (1.0 if integer else 0.001)
	slider.value = value if value != null else slider.min_value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var readout := Label.new()
	readout.text = ("%d" if integer else "%.3f") % slider.value
	readout.custom_minimum_size = Vector2(52, 0)
	readout.add_theme_font_size_override("font_size", 12)
	slider.value_changed.connect(func(v: float) -> void:
		readout.text = ("%d" if integer else "%.3f") % v
		setter.call(int(v) if integer else v))
	row.add_child(slider)
	row.add_child(readout)


func _add_spinbox(list: VBoxContainer, pname: String, value: Variant, setter: Callable, integer: bool) -> void:
	var row := _param_row(list, pname)
	var spin := SpinBox.new()
	spin.min_value = -1e6
	spin.max_value = 1e6
	spin.step = 1.0 if integer else 0.01
	spin.value = value if value != null else 0.0
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(v: float) -> void: setter.call(int(v) if integer else v))
	row.add_child(spin)


func _add_checkbox(list: VBoxContainer, pname: String, value: Variant, setter: Callable) -> void:
	var row := _param_row(list, pname)
	var check := CheckBox.new()
	check.button_pressed = bool(value)
	check.toggled.connect(func(on: bool) -> void: setter.call(on))
	row.add_child(check)


func _add_color(list: VBoxContainer, pname: String, value: Variant, setter: Callable) -> void:
	var row := _param_row(list, pname)
	var picker := ColorPickerButton.new()
	picker.edit_alpha = true
	picker.custom_minimum_size = Vector2(70, 28)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var color: Color
	if value is Color:
		color = value
	elif value is Vector4:
		color = Color(value.x, value.y, value.z, value.w)
	picker.color = color
	picker.color_changed.connect(func(c: Color) -> void: setter.call(c))
	row.add_child(picker)


func _add_vector(list: VBoxContainer, pname: String, value: Variant, setter: Callable, getter: Callable) -> void:
	var row := _param_row(list, pname)
	var count := 2 if value is Vector2 else 3 if value is Vector3 else 4
	for i in count:
		var spin := SpinBox.new()
		spin.min_value = -1e6
		spin.max_value = 1e6
		spin.step = 0.01
		spin.value = value[i] if value != null else 0.0
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(func(v: float) -> void:
			var current: Variant = getter.call()
			if current == null:
				current = value
			current[i] = v
			setter.call(current))
		row.add_child(spin)
