extends RefCounted
## Camera-centered mesh for close views. Adjacent rings share vertices, including
## the half-step vertices that stitch each coarse ring to its finer neighbor.

const GRID_UNIT := 0.0625
static var _cached_mesh: ArrayMesh

var _vertices := PackedVector3Array()
var _indices := PackedInt32Array()
var _vertex_indices: Dictionary[Vector2i, int] = {}


static func get_mesh() -> ArrayMesh:
	if _cached_mesh == null:
		var builder := new()
		_cached_mesh = builder._build()
	return _cached_mesh


func _build() -> ArrayMesh:
	# 12.5 cm spacing within 16 m, then 25 cm, 50 cm, 1 m and 2 m.
	# All rings have 256 cells per side; only the first ring fills its center.
	for ring_index in range(5):
		var step_units := 2 << ring_index
		var inner_units := 0 if ring_index == 0 else 64 * step_units
		for z in range(-128, 128):
			for x in range(-128, 128):
				if inner_units > 0 and x >= -64 and x < 64 and z >= -64 and z < 64:
					continue
				_add_cell(Vector2i(x, z) * step_units, step_units, inner_units)

	var normals := PackedVector3Array()
	normals.resize(_vertices.size())
	normals.fill(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = _indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func _vertex(point: Vector2i) -> int:
	if _vertex_indices.has(point):
		return _vertex_indices[point]
	var index := _vertices.size()
	_vertex_indices[point] = index
	_vertices.append(Vector3(point.x * GRID_UNIT, 0.0, point.y * GRID_UNIT))
	return index


func _add_cell(origin: Vector2i, step_units: int, inner_units: int) -> void:
	var corners: Array[Vector2i] = [
		origin, origin + Vector2i(step_units, 0),
		origin + Vector2i(step_units, step_units), origin + Vector2i(0, step_units),
	]
	var a := _vertex(corners[0])
	var b := _vertex(corners[1])
	var c := _vertex(corners[2])
	var d := _vertex(corners[3])
	var split_edge := -1
	if inner_units > 0:
		if origin.x >= -inner_units and origin.x < inner_units:
			if origin.y == inner_units:
				split_edge = 0
			elif origin.y + step_units == -inner_units:
				split_edge = 2
		elif origin.y >= -inner_units and origin.y < inner_units:
			if origin.x + step_units == -inner_units:
				split_edge = 1
			elif origin.x == inner_units:
				split_edge = 3
	if split_edge < 0:
		_indices.append_array(PackedInt32Array([a, b, c, a, c, d]))
		return

	# A fan includes the fine ring's edge midpoint: no T-junctions or cracks
	# when wave displacement moves the shared seam vertices vertically.
	var center := _vertex(origin + Vector2i(step_units >> 1, step_units >> 1))
	for edge_index in range(4):
		var start := corners[edge_index]
		var end := corners[(edge_index + 1) % 4]
		if edge_index == split_edge:
			# Ring edges span even grid units, so halving each component is exact.
			var edge_delta := end - start
			var midpoint := _vertex(start + Vector2i(edge_delta.x >> 1, edge_delta.y >> 1))
			_indices.append_array(PackedInt32Array([center, _vertex(start), midpoint, center, midpoint, _vertex(end)]))
		else:
			_indices.append_array(PackedInt32Array([center, _vertex(start), _vertex(end)]))
