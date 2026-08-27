@tool
class_name GhibliMeadow
extends MultiMeshInstance3D
## Procedural Ghibli-meadow driver: builds the rolling ground heightfield and
## the grass-blade MultiMesh (the Blender tutorial's hair particle system as a
## scatter — parent points with clumped children, height variance, lean, yaw),
## owns the wrapped wind clock, and mirrors the shared color/toon uniforms
## onto the ground material every frame so panel edits hit both. Group
## "grass"; the demo panel finds this node and reads get_presets().

# Same wrap as the water drivers: float32 shader math degrades after hours of
# accumulated uniform time (see the shervheim clock note). Hourly pop accepted.
const TIME_WRAP := 3600.0

# Uniforms the ground shader shares with the grass shader, mirrored per frame.
const MIRRORED_UNIFORMS := [
	"tone_shadowed", "tone_lit", "patch_scale", "patch_brightness",
	"patch_contrast", "toon_edge", "toon_softness", "shadow_tint",
	"terminator_band",
]

@export_group("Field")
@export_range(20.0, 200.0, 1.0) var field_size := 70.0
@export_range(0, 9999, 1) var seed_value := 7
@export_range(100, 10000, 50) var parent_count := 700
@export_range(2, 80, 1) var children_per_parent := 22
@export_range(0.1, 3.0, 0.05) var clump_radius := 0.9

@export_group("Blades")
@export_range(0.2, 2.5, 0.01) var blade_height := 0.85
@export_range(0.0, 1.0, 0.01) var blade_height_variance := 0.5
@export_range(0.02, 0.25, 0.005) var blade_width := 0.06
@export_range(1, 6, 1) var blade_segments := 3
@export_range(0.0, 0.8, 0.01) var blade_bow := 0.22
@export_range(0.0, 30.0, 0.5) var lean_degrees := 9.0

@export_group("Wiring")
@export var ground_path: NodePath = ^"../Ground"
@export var ground_subdivisions := 96
@export var rebuild := false:
	set(_v):
		_rebuild()

var _time := 0.0


func _ready() -> void:
	add_to_group("grass")
	if multimesh == null or multimesh.instance_count == 0:
		_rebuild()


func _process(delta: float) -> void:
	_time = fposmod(_time + delta, TIME_WRAP)
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("wave_time", _time)
	var ground := get_node_or_null(ground_path) as MeshInstance3D
	if ground == null:
		return
	var gmat := ground.material_override as ShaderMaterial
	if gmat == null:
		return
	for uniform in MIRRORED_UNIFORMS:
		gmat.set_shader_parameter(uniform, mat.get_shader_parameter(uniform))


## Wind-and-look presets for the demo panel (values are grass-shader uniforms).
func get_presets() -> Dictionary:
	return {
		"Gentle Breeze": {
			"wind_strength": 0.28, "wind_speed": 1.1, "gust_scale": 0.015,
			"flutter": 0.18, "wind_sheen": 0.28,
		},
		"Rolling Gusts": {
			"wind_strength": 0.6, "wind_speed": 2.0, "gust_scale": 0.011,
			"flutter": 0.32, "wind_sheen": 0.45,
		},
		"Storm Front": {
			"wind_strength": 1.15, "wind_speed": 3.6, "gust_scale": 0.019,
			"flutter": 0.6, "wind_sheen": 0.5,
			"tone_shadowed": Color(0.08, 0.26, 0.24), "tone_lit": Color(0.45, 0.62, 0.24),
		},
		"Golden Field": {
			"wind_strength": 0.4, "wind_speed": 1.4, "gust_scale": 0.013,
			"flutter": 0.22, "wind_sheen": 0.55,
			"tone_shadowed": Color(0.30, 0.30, 0.12), "tone_lit": Color(0.92, 0.78, 0.30),
			"shadow_tint": Color(0.52, 0.46, 0.55),
		},
		"Cool Morning": {
			"wind_strength": 0.2, "wind_speed": 0.8, "gust_scale": 0.017,
			"flutter": 0.12, "wind_sheen": 0.2,
			"tone_shadowed": Color(0.10, 0.28, 0.32), "tone_lit": Color(0.44, 0.68, 0.40),
			"shadow_tint": Color(0.42, 0.52, 0.72),
		},
	}


## Rolling-meadow height: a few overlapping low-frequency waves, smooth and
## analytic so blades and ground sample the identical surface.
func terrain_height(x: float, z: float) -> float:
	return sin(x * 0.061) * 1.1 + cos(z * 0.043) * 0.9 \
		+ sin((x + z) * 0.021 + 1.7) * 1.4 + sin(x * 0.013 - z * 0.017) * 0.8


func terrain_normal(x: float, z: float) -> Vector3:
	var e := 0.35
	var dx := terrain_height(x + e, z) - terrain_height(x - e, z)
	var dz := terrain_height(x, z + e) - terrain_height(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func _rebuild() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_build_ground()

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _build_blade_mesh()
	mm.instance_count = parent_count * children_per_parent

	var half := field_size * 0.5
	var index := 0
	for p in parent_count:
		var px := rng.randf_range(-half, half)
		var pz := rng.randf_range(-half, half)
		var parent_scale := rng.randf_range(0.8, 1.25)
		for c in children_per_parent:
			var angle := rng.randf() * TAU
			var dist := sqrt(rng.randf()) * clump_radius
			var x := px + cos(angle) * dist
			var z := pz + sin(angle) * dist
			var y := terrain_height(x, z)
			var n := terrain_normal(x, z)

			var height_scale := parent_scale * (1.0 + rng.randf_range(-blade_height_variance, blade_height_variance))
			var basis := Basis(Vector3.UP, rng.randf() * TAU)
			var lean_axis := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)).normalized()
			basis = Basis(lean_axis, deg_to_rad(rng.randf_range(0.0, lean_degrees))) * basis
			basis = basis.scaled(Vector3(1.0, height_scale, 1.0))

			mm.set_instance_transform(index, Transform3D(basis, Vector3(x, y, z)))
			mm.set_instance_custom_data(index, Color(rng.randf(), n.x, n.z, 0.0))
			index += 1

	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_ground() -> void:
	var ground := get_node_or_null(ground_path) as MeshInstance3D
	if ground == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := ground_subdivisions
	var step := field_size * 1.4 / float(n) # ground extends past the grass
	var origin := -field_size * 0.7
	for iz in n:
		for ix in n:
			var x0 := origin + float(ix) * step
			var z0 := origin + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var p00 := Vector3(x0, terrain_height(x0, z0), z0)
			var p10 := Vector3(x1, terrain_height(x1, z0), z0)
			var p01 := Vector3(x0, terrain_height(x0, z1), z1)
			var p11 := Vector3(x1, terrain_height(x1, z1), z1)
			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
	st.generate_normals()
	ground.mesh = st.commit()


## One tapered, slightly bowed blade strip. UV.y runs 0 (root) to 1 (tip) —
## the shader's wind weight and root/tip gradient both key off it.
func _build_blade_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows: Array[PackedVector3Array] = []
	var ts: Array[float] = []
	for i in blade_segments + 1:
		var t := float(i) / float(blade_segments)
		ts.append(t)
		var w := blade_width * pow(1.0 - t, 1.15) * 0.5
		var y := t * blade_height
		var bow := blade_bow * t * t
		if i == blade_segments:
			rows.append(PackedVector3Array([Vector3(0.0, y, bow)]))
		else:
			rows.append(PackedVector3Array([Vector3(-w, y, bow), Vector3(w, y, bow)]))
	for i in blade_segments:
		var t0 := ts[i]
		var t1 := ts[i + 1]
		var below := rows[i]
		var above := rows[i + 1]
		if above.size() == 1:
			st.set_uv(Vector2(0.0, t0)); st.add_vertex(below[0])
			st.set_uv(Vector2(1.0, t0)); st.add_vertex(below[1])
			st.set_uv(Vector2(0.5, t1)); st.add_vertex(above[0])
		else:
			st.set_uv(Vector2(0.0, t0)); st.add_vertex(below[0])
			st.set_uv(Vector2(1.0, t0)); st.add_vertex(below[1])
			st.set_uv(Vector2(1.0, t1)); st.add_vertex(above[1])
			st.set_uv(Vector2(0.0, t0)); st.add_vertex(below[0])
			st.set_uv(Vector2(1.0, t1)); st.add_vertex(above[1])
			st.set_uv(Vector2(0.0, t1)); st.add_vertex(above[0])
	st.generate_normals()
	return st.commit()
