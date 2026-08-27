@tool
class_name StylizedTree
extends Node3D

## A stylized tree built in script rather than imported: a tapered trunk and a
## cluster of canopy blobs, shaded by ghibli_tree.gdshader so it steps at the
## same terminator as the grass and the soil.
##
## It exists because the meadow this ships with originally stood three imported
## trees, and those could not be published. Generating them keeps the scene
## self-contained: no mesh files, no licence surface, and a seed instead of an
## asset. Vary `seed_value` per instance and no two trees repeat.
##
## Conventions follow meadow.gd: exported groups, a seeded RNG, and a `rebuild`
## checkbox that regenerates in the editor viewport.

@export_group("Trunk")
@export_range(0.5, 8.0, 0.05) var trunk_height := 2.4:
	set(v): trunk_height = v; _queue()
@export_range(0.02, 0.8, 0.01) var trunk_radius := 0.20:
	set(v): trunk_radius = v; _queue()
## Top radius as a fraction of the base, so the trunk narrows as it rises.
@export_range(0.1, 1.0, 0.01) var trunk_taper := 0.55:
	set(v): trunk_taper = v; _queue()
## Sideways drift of the trunk top. A little keeps it from reading as a pole.
@export_range(0.0, 1.5, 0.01) var trunk_lean := 0.18:
	set(v): trunk_lean = v; _queue()

@export_group("Canopy")
@export_range(1, 9, 1) var blob_count := 5:
	set(v): blob_count = v; _queue()
@export_range(0.3, 4.0, 0.05) var canopy_radius := 1.5:
	set(v): canopy_radius = v; _queue()
## How far blobs scatter from the crown centre, as a fraction of the radius.
@export_range(0.0, 1.5, 0.01) var canopy_spread := 0.62:
	set(v): canopy_spread = v; _queue()
## Vertical squash of the crown. Below 1.0 gives the broad Totoro silhouette.
@export_range(0.3, 1.5, 0.01) var canopy_squash := 0.78:
	set(v): canopy_squash = v; _queue()
@export_range(0.0, 1.0, 0.01) var blob_size_variance := 0.35:
	set(v): blob_size_variance = v; _queue()

@export_group("Wiring")
@export var seed_value := 3:
	set(v): seed_value = v; _queue()
@export var bark_material: Material:
	set(v): bark_material = v; _queue()
@export var leaf_material: Material:
	set(v): leaf_material = v; _queue()
## Ticking this rebuilds now. It never stays on.
@export var rebuild := false:
	set(_v):
		rebuild = false
		_build()

const _TRUNK_SIDES := 7
const _BLOB_RINGS := 8
const _BLOB_SEGMENTS := 12

var _dirty := false


func _ready() -> void:
	if get_child_count() == 0:
		_build()


## Coalesces the many setters above into one rebuild per frame, so dragging a
## slider in the inspector does not rebuild the meshes on every increment.
func _queue() -> void:
	if _dirty or not is_inside_tree():
		return
	_dirty = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_dirty = false
	_build()


func _build() -> void:
	for child in get_children():
		child.queue_free()
		remove_child(child)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var lean := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
	lean = (lean.normalized() if lean.length() > 0.001 else Vector3.RIGHT) * trunk_lean

	_add_mesh("Trunk", _build_trunk(lean), bark_material, Vector3.ZERO)

	# The crown sits on the trunk top and follows its lean, so a leaning tree
	# carries its canopy with it instead of balancing it on nothing.
	var crown := Vector3(lean.x, trunk_height, lean.z)
	for i in blob_count:
		var offset := Vector3.ZERO
		if i > 0:
			# Blob 0 anchors the crown centre; the rest ring around it, angled
			# by index so they distribute rather than clump on one side.
			var angle := TAU * (float(i - 1) / float(maxi(blob_count - 1, 1))) \
				+ rng.randf_range(-0.4, 0.4)
			var dist := canopy_radius * canopy_spread * rng.randf_range(0.55, 1.0)
			offset = Vector3(cos(angle) * dist,
				rng.randf_range(-0.15, 0.45) * canopy_radius,
				sin(angle) * dist)
		var scale_f := 1.0 - rng.randf() * blob_size_variance
		if i == 0:
			scale_f = 1.0
		_add_mesh("Canopy%d" % i, _build_blob(canopy_radius * scale_f), leaf_material,
			crown + offset)


func _add_mesh(node_name: String, mesh: Mesh, mat: Material, at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = at
	if mat != null:
		mi.material_override = mat
	add_child(mi)
	# Without an owner the generated nodes vanish the moment the scene is saved.
	if Engine.is_editor_hint() and owner != null:
		mi.owner = owner


## A tapered prism. Seven sides reads as round at meadow distance and keeps the
## silhouette faceted, which suits the flat toon shading better than a cylinder.
func _build_trunk(lean: Vector3) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var top_r := trunk_radius * trunk_taper
	for i in _TRUNK_SIDES:
		var a0 := TAU * float(i) / float(_TRUNK_SIDES)
		var a1 := TAU * float(i + 1) / float(_TRUNK_SIDES)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		var b0 := d0 * trunk_radius
		var b1 := d1 * trunk_radius
		var t0 := d0 * top_r + Vector3(lean.x, trunk_height, lean.z)
		var t1 := d1 * top_r + Vector3(lean.x, trunk_height, lean.z)
		var n := ((d0 + d1) * 0.5).normalized()
		for v in [b0, t0, t1, b0, t1, b1]:
			verts.append(v)
			normals.append(n)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A squashed UV sphere. Squash is applied to the geometry rather than the node
## scale so the normals stay correct and the toon step does not skew.
func _build_blob(radius: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()

	var point := func(ring: int, seg: int) -> Vector3:
		var phi := PI * float(ring) / float(_BLOB_RINGS)
		var theta := TAU * float(seg) / float(_BLOB_SEGMENTS)
		return Vector3(sin(phi) * cos(theta), cos(phi) * canopy_squash, sin(phi) * sin(theta))

	for ring in _BLOB_RINGS:
		for seg in _BLOB_SEGMENTS:
			var a: Vector3 = point.call(ring, seg)
			var b: Vector3 = point.call(ring + 1, seg)
			var c: Vector3 = point.call(ring + 1, seg + 1)
			var d: Vector3 = point.call(ring, seg + 1)
			for v in [a, b, c, a, c, d]:
				verts.append(v * radius)
				normals.append(v.normalized())

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
