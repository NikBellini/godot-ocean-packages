@tool
extends MeshInstance3D
## Boat system pontoon and force visualization for the editor and runtime.

const SPHERE_SEGMENTS := 32
const ARROW_SEGMENTS := 8
const DRY_COLOR := Color(1.0, 0.55, 0.1)
const WET_COLOR := Color(0.1, 0.8, 1.0)
const FORCE_COLOR := Color(0.3, 1.0, 0.2)
const OFFSET_COLOR := Color(0.85, 0.85, 0.85)

var _mesh := ImmediateMesh.new()
var _material := StandardMaterial3D.new()


func _init() -> void:
	mesh = _mesh
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Draw after transparent water as well as opaque hulls.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = Material.RENDER_PRIORITY_MAX
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ignore_occlusion_culling = true


func _ready() -> void:
	# Physics force vectors and vertices are in world axes, even on a rotated body.
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	global_transform = Transform3D.IDENTITY


func clear_debug() -> void:
	visible = false
	if _mesh.get_surface_count() > 0:
		_mesh.clear_surfaces()


func draw_debug(positions: PackedVector3Array, forces: PackedVector3Array,
		depths: PackedFloat32Array, radius: float, force_scale: float,
		through_objects: bool, water_height_offset: float = 0.0) -> void:
	clear_debug()
	if positions.is_empty() or radius <= 0.0:
		return
	visible = true
	_material.no_depth_test = through_objects
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for index in range(positions.size()):
		var wet := index < depths.size() and depths[index] > 0.0
		_mesh.surface_set_color(WET_COLOR if wet else DRY_COLOR)
		# Adding offset to water height is equivalent to lowering the sphere center.
		var center := positions[index] - Vector3.UP * water_height_offset
		_draw_sphere(center, radius)
		if not is_zero_approx(water_height_offset):
			_mesh.surface_set_color(OFFSET_COLOR)
			_mesh.surface_add_vertex(positions[index])
			_mesh.surface_add_vertex(center)
			# Mark the original point where vertical lift is applied.
			var marker_size := minf(radius * 0.15, 0.075)
			for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
				_mesh.surface_add_vertex(positions[index] - axis * marker_size)
				_mesh.surface_add_vertex(positions[index] + axis * marker_size)
	_mesh.surface_end()

	# Do not begin an empty surface: zero lift should display no arrow.
	var arrow_indices: Array[int] = []
	for index in range(mini(positions.size(), forces.size())):
		if forces[index].is_finite() and forces[index].length() * force_scale > 0.0001:
			arrow_indices.append(index)
	if arrow_indices.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_mesh.surface_set_color(FORCE_COLOR)
	for index in arrow_indices:
		_draw_arrow(positions[index], forces[index] * force_scale)
	_mesh.surface_end()


func _draw_sphere(center: Vector3, radius: float) -> void:
	# Three great circles show the shared pontoon radius without hiding the hull.
	for plane in range(3):
		for segment in range(SPHERE_SEGMENTS):
			var angle_a := TAU * segment / SPHERE_SEGMENTS
			var angle_b := TAU * (segment + 1) / SPHERE_SEGMENTS
			var a := Vector2(cos(angle_a), sin(angle_a)) * radius
			var b := Vector2(cos(angle_b), sin(angle_b)) * radius
			match plane:
				0:
					_mesh.surface_add_vertex(center + Vector3(a.x, a.y, 0.0))
					_mesh.surface_add_vertex(center + Vector3(b.x, b.y, 0.0))
				1:
					_mesh.surface_add_vertex(center + Vector3(a.x, 0.0, a.y))
					_mesh.surface_add_vertex(center + Vector3(b.x, 0.0, b.y))
				2:
					_mesh.surface_add_vertex(center + Vector3(0.0, a.x, a.y))
					_mesh.surface_add_vertex(center + Vector3(0.0, b.x, b.y))


func _draw_arrow(start: Vector3, vector: Vector3) -> void:
	var length := vector.length()
	var direction := vector / length
	var reference := Vector3.RIGHT if absf(direction.y) > 0.95 else Vector3.UP
	var side := direction.cross(reference).normalized()
	var perpendicular := direction.cross(side).normalized()
	var head_length := minf(length * 0.3, 0.25)
	var shaft_radius := minf(length * 0.025, 0.02)
	var head_radius := head_length * 0.45
	var tip := start + vector
	var neck := tip - direction * head_length
	for segment in range(ARROW_SEGMENTS):
		var angle_a := TAU * segment / ARROW_SEGMENTS
		var angle_b := TAU * (segment + 1) / ARROW_SEGMENTS
		var radial_a := side * cos(angle_a) + perpendicular * sin(angle_a)
		var radial_b := side * cos(angle_b) + perpendicular * sin(angle_b)
		var base_a := start + radial_a * shaft_radius
		var base_b := start + radial_b * shaft_radius
		var neck_a := neck + radial_a * shaft_radius
		var neck_b := neck + radial_b * shaft_radius
		_triangle(base_a, base_b, neck_a)
		_triangle(base_b, neck_b, neck_a)
		_triangle(neck + radial_a * head_radius, neck + radial_b * head_radius, tip)


func _triangle(a: Vector3, b: Vector3, c: Vector3) -> void:
	_mesh.surface_add_vertex(a)
	_mesh.surface_add_vertex(b)
	_mesh.surface_add_vertex(c)
