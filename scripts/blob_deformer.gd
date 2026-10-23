extends Node3D
class_name BlobDeformer

@export var radius: float = 0.92
@export_range(8, 48, 1) var latitude_segments: int = 24
@export_range(12, 96, 1) var longitude_segments: int = 48

@export_range(0.3, 4.0, 0.1) var rebound_duration: float = 1.6
@export_range(0.2, 1.6, 0.05) var softness: float = 0.9
@export_range(0.1, 0.5, 0.01) var press_depth_limit: float = 0.32
@export_range(0.12, 0.36, 0.01) var finger_width: float = 0.23
@export_range(0.0, 1.0, 0.05) var jelly_amount: float = 0.55
@export_range(0.0, 0.6, 0.02) var springback_amount: float = 0.24
@export_range(0.3, 2.5, 0.1) var stretch_sensitivity: float = 1.3
@export_range(0.8, 3.6, 0.1) var max_stretch: float = 2.4
@export_range(0.0, 1.5, 0.1) var camera_zoom_back: float = 1.0
@export_range(0.0, 0.5, 0.05) var vibration_strength: float = 0.2

var spring_stiffness: float = 76.0
var spring_damping: float = 15.0
var neighbor_stiffness: float = 5.5

const MODE_PRESS: int = 0
const MODE_STRETCH: int = 1
const MAX_VERTEX_OFFSET: float = 3.0

var _mesh_instance: MeshInstance3D
var _collision_body: StaticBody3D
var _array_mesh: ArrayMesh
var _material: Material
var _external_mesh: Mesh

var _rest_positions := PackedVector3Array()
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _colors := PackedColorArray()
var _rest_normals := PackedVector3Array()
var _neighbors: Array = []

var _interaction_mode: int = -1
var _anchor_point := Vector3.ZERO
var _anchor_normal := Vector3.ZERO
var _last_drag_point := Vector3.ZERO
var _pull_offset := Vector3.ZERO
var _strength: float = 1.0
var _mesh_center := Vector3.ZERO
var _model_radius := 1.0
var _using_external_mesh := false
var _jelly_velocity := Vector3.ZERO
var _springback_velocity := Vector3.ZERO


func _ready() -> void:
	if _using_external_mesh:
		_extract_external_mesh_data()
	else:
		_build_mesh_data()
	_apply_spring_params()
	_build_nodes()
	_rebuild_surface()


func set_external_mesh(mesh_instance: MeshInstance3D) -> void:
	_mesh_instance = mesh_instance
	_external_mesh = mesh_instance.mesh
	_using_external_mesh = true


func get_collision_body() -> StaticBody3D:
	return _collision_body


func set_strength(value: float) -> void:
	_strength = clampf(value, 0.35, 1.8)


func set_param(name: String, value: float) -> void:
	match name:
		"rebound_duration":
			rebound_duration = value
		"softness":
			softness = value
		"press_depth_limit":
			press_depth_limit = value
		"finger_width":
			finger_width = value
		"jelly_amount":
			jelly_amount = value
		"springback_amount":
			springback_amount = value
		"stretch_sensitivity":
			stretch_sensitivity = value
		"max_stretch":
			max_stretch = value
		"camera_zoom_back":
			camera_zoom_back = value
		"vibration_strength":
			vibration_strength = value
	_apply_spring_params()


func _apply_spring_params() -> void:
	spring_stiffness = (2.0 * PI) / maxf(rebound_duration, 0.3)
	spring_stiffness *= spring_stiffness
	spring_damping = 2.0 * sqrt(spring_stiffness) * 0.65
	neighbor_stiffness = 5.5 * softness


func begin_interaction(world_point: Vector3, stretch: bool) -> void:
	var local_point := _to_mesh_local(world_point)
	_anchor_point = local_point
	_anchor_normal = _surface_normal_at(local_point)
	_last_drag_point = local_point
	_pull_offset = Vector3.ZERO
	_jelly_velocity = Vector3.ZERO
	_springback_velocity = Vector3.ZERO
	_interaction_mode = MODE_STRETCH if stretch else MODE_PRESS


func update_interaction(world_point: Vector3) -> void:
	if _interaction_mode < 0:
		return
	var local_point := _to_mesh_local(world_point)
	if _interaction_mode == MODE_PRESS:
		_anchor_point = local_point
		_anchor_normal = _surface_normal_at(local_point)
	else:
		var drag_delta := local_point - _last_drag_point
		drag_delta.y = 0.0
		_pull_offset += drag_delta * stretch_sensitivity
		_pull_offset.y = 0.0
		var max_allowed := _model_radius * max_stretch
		if _pull_offset.length() > max_allowed:
			_pull_offset = _pull_offset.normalized() * max_allowed
	_last_drag_point = local_point


func update_stretch_by_screen(screen_delta: Vector2, camera: Camera3D) -> void:
	if _interaction_mode != MODE_STRETCH:
		return
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var fov_rad := deg_to_rad(camera.fov)
	var aspect := viewport_size.x / viewport_size.y
	var mesh_origin := _mesh_instance.global_position if _mesh_instance != null else global_position
	var dist_to_model := camera.global_position.distance_to(mesh_origin)
	var world_per_pixel_y := 2.0 * tan(fov_rad * 0.5) * dist_to_model / viewport_size.y
	var world_per_pixel_x := world_per_pixel_y * aspect
	var cam_basis := camera.global_transform.basis
	var world_delta := cam_basis.x * screen_delta.x * world_per_pixel_x
	world_delta += cam_basis.y * screen_delta.y * world_per_pixel_y
	world_delta.y = 0.0
	var world_target := mesh_origin + world_delta
	var local_target := _to_mesh_local(world_target)
	var local_origin := _to_mesh_local(mesh_origin)
	var local_delta := local_target - local_origin
	local_delta.y = 0.0
	_pull_offset += local_delta * stretch_sensitivity
	_pull_offset.y = 0.0
	var max_allowed := _model_radius * max_stretch
	if _pull_offset.length() > max_allowed:
		_pull_offset = _pull_offset.normalized() * max_allowed


func _to_mesh_local(world_point: Vector3) -> Vector3:
	if _mesh_instance != null:
		return _mesh_instance.to_local(world_point)
	return to_local(world_point)


func end_interaction() -> void:
	if _interaction_mode >= 0:
		var was_press := _interaction_mode == MODE_PRESS
		_interaction_mode = -1
		var velocity_bonus := _pull_offset * springback_amount
		_springback_velocity = velocity_bonus
		if was_press:
			var wiggle := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
			_jelly_velocity = wiggle * jelly_amount * _model_radius * 0.15
		else:
			_jelly_velocity = Vector3.ZERO
		_apply_jelly_to_vertices()
	_pull_offset = Vector3.ZERO


func reset_deformation() -> void:
	end_interaction()
	_positions = _rest_positions.duplicate()
	_velocities.resize(_rest_positions.size())
	for i in range(_velocities.size()):
		_velocities[i] = Vector3.ZERO
	_jelly_velocity = Vector3.ZERO
	_springback_velocity = Vector3.ZERO
	_rebuild_surface()


func _surface_normal_at(point: Vector3) -> Vector3:
	if _rest_normals.is_empty():
		return (point - _mesh_center).normalized()
	var best_idx := -1
	var best_dist := INF
	for i in range(_rest_positions.size()):
		var d := _rest_positions[i].distance_squared_to(point)
		if d < best_dist:
			best_dist = d
			best_idx = i
	if best_idx >= 0 and best_idx < _rest_normals.size():
		var n: Vector3 = _rest_normals[best_idx]
		if n.length_squared() > 0.0001:
			return n.normalized()
	return (point - _mesh_center).normalized()


func _apply_jelly_to_vertices() -> void:
	var count := _positions.size()
	var jelly_sigma := _model_radius * softness * 0.6
	for i in range(count):
		var rest: Vector3 = _rest_positions[i]
		var dist := rest.distance_to(_anchor_point)
		var falloff := exp(-(dist * dist) / (2.0 * jelly_sigma * jelly_sigma))
		if _springback_velocity.length_squared() > 0.0001:
			_velocities[i] += _springback_velocity * falloff
		if _jelly_velocity.length_squared() > 0.0001:
			_velocities[i] += _jelly_velocity * falloff * (1.0 + randf() * 0.3)


func _physics_process(delta: float) -> void:
	if _rest_positions.is_empty():
		return
	var still_moving := _interaction_mode >= 0
	var vertex_count := _positions.size()
	var next_positions := PackedVector3Array()
	next_positions.resize(vertex_count)

	for i in range(vertex_count):
		var rest_position: Vector3 = _rest_positions[i]
		var target_offset := _target_offset_for(rest_position)
		var current_position: Vector3 = _positions[i]
		var current_offset := current_position - rest_position
		var laplacian := Vector3.ZERO
		var rest_laplacian := Vector3.ZERO
		var adjacent: Array = _neighbors[i]
		for neighbor_index: int in adjacent:
			laplacian += _positions[neighbor_index] - current_position
			rest_laplacian += _rest_positions[neighbor_index] - rest_position
		if not adjacent.is_empty():
			laplacian /= float(adjacent.size())
			rest_laplacian /= float(adjacent.size())
		laplacian -= rest_laplacian

		var acceleration := (target_offset - current_offset) * spring_stiffness
		acceleration += laplacian * neighbor_stiffness
		acceleration -= _velocities[i] * spring_damping
		var velocity: Vector3 = _velocities[i] + acceleration * delta
		var next_position := current_position + velocity * delta
		var offset := next_position - rest_position
		if offset.length() > MAX_VERTEX_OFFSET:
			next_position = rest_position + offset.normalized() * MAX_VERTEX_OFFSET
			velocity *= 0.25
		_velocities[i] = velocity
		next_positions[i] = next_position
		if (next_position - rest_position).length_squared() > 0.0000005 or velocity.length_squared() > 0.000025:
			still_moving = true

	_positions = next_positions
	if _interaction_mode < 0 and not still_moving:
		for i in range(vertex_count):
			_positions[i] = _rest_positions[i]
			_velocities[i] = Vector3.ZERO
		return
	_rebuild_surface()


func _target_offset_for(rest_position: Vector3) -> Vector3:
	if _interaction_mode < 0:
		return Vector3.ZERO

	if _interaction_mode == MODE_PRESS:
		var dist := rest_position.distance_to(_anchor_point)
		var sigma := finger_width * _model_radius
		var finger_gaussian := exp(-(dist * dist) / (2.0 * sigma * sigma))
		var inward := -_anchor_normal * press_depth_limit * _model_radius * _strength * finger_gaussian
		var ring_center := finger_width * _model_radius * 2.0
		var ring_dist := dist - ring_center
		var ring := exp(-(ring_dist * ring_dist) / (2.0 * sigma * sigma * 2.5))
		var bulge := _anchor_normal * press_depth_limit * _model_radius * 0.35 * _strength * ring
		var soft_sigma := softness * _model_radius * 0.5
		var soft_falloff := exp(-(dist * dist) / (2.0 * soft_sigma * soft_sigma))
		return (inward + bulge) * soft_falloff

	var pull_len := _pull_offset.length()
	if pull_len < 0.0001:
		return Vector3.ZERO
	var pull_dir := _pull_offset.normalized()
	var stretch_amount := pull_len / _model_radius
	var rel := rest_position - _mesh_center
	var along := rel.dot(pull_dir)
	var along_vec := pull_dir * along
	var perp_vec := rel - along_vec
	var stretch_factor := 1.0 + stretch_amount * 0.6
	var thin_factor := 1.0 / sqrt(maxf(stretch_factor, 0.01))
	var new_rel := along_vec * stretch_factor + perp_vec * thin_factor
	var volume_offset := new_rel - rel
	var local_dist := rest_position.distance_to(_anchor_point)
	var local_sigma := _model_radius * softness * 0.8
	var local_falloff := exp(-(local_dist * local_dist) / (2.0 * local_sigma * local_sigma))
	var local_offset := _pull_offset * _strength * local_falloff * 0.3
	return volume_offset + local_offset


func _build_nodes() -> void:
	if not _using_external_mesh:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "DeformableMesh"
		add_child(_mesh_instance)

	_array_mesh = ArrayMesh.new()
	if _using_external_mesh and _material != null:
		_array_mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = _array_mesh

	if not _using_external_mesh:
		_material = StandardMaterial3D.new()
		var mat: StandardMaterial3D = _material
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.35
		mat.metallic = 0.0
		_mesh_instance.material_override = mat

	_collision_body = StaticBody3D.new()
	_collision_body.name = "PickingCollider"
	_collision_body.collision_layer = 1
	_collision_body.collision_mask = 0
	add_child(_collision_body)
	var collision_shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	var mesh_aabb: AABB
	if _using_external_mesh and _external_mesh != null:
		mesh_aabb = _external_mesh.get_aabb()
	else:
		mesh_aabb = AABB(Vector3(-radius, -radius, -radius), Vector3(radius * 2.0, radius * 2.0, radius * 2.0))
	sphere_shape.radius = mesh_aabb.get_longest_axis_size() * 0.5
	collision_shape.shape = sphere_shape
	collision_shape.position = mesh_aabb.position + mesh_aabb.size * 0.5
	_collision_body.add_child(collision_shape)


func _extract_external_mesh_data() -> void:
	_rest_positions.clear()
	_uvs.clear()
	_indices.clear()
	_colors.clear()
	_rest_normals.clear()
	_neighbors.clear()

	if _external_mesh == null:
		return

	var min_pos := Vector3(INF, INF, INF)
	var max_pos := Vector3(-INF, -INF, -INF)
	var vertex_offset := 0
	for surface_idx in range(_external_mesh.get_surface_count()):
		var arrays: Array = _external_mesh.surface_get_arrays(surface_idx)
		var vertices_var: Variant = arrays[Mesh.ARRAY_VERTEX]
		var indices_var: Variant = arrays[Mesh.ARRAY_INDEX]
		var uvs_var: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var normals_var: Variant = arrays[Mesh.ARRAY_NORMAL]
		var colors_var: Variant = arrays[Mesh.ARRAY_COLOR]

		if vertices_var == null or not (vertices_var is PackedVector3Array):
			continue
		var vertices: PackedVector3Array = vertices_var

		for v in vertices:
			_rest_positions.append(v)
			if v.x < min_pos.x: min_pos.x = v.x
			if v.y < min_pos.y: min_pos.y = v.y
			if v.z < min_pos.z: min_pos.z = v.z
			if v.x > max_pos.x: max_pos.x = v.x
			if v.y > max_pos.y: max_pos.y = v.y
			if v.z > max_pos.z: max_pos.z = v.z
		if uvs_var != null and uvs_var is PackedVector2Array:
			var uvs: PackedVector2Array = uvs_var
			for u in uvs:
				_uvs.append(u)
		else:
			for i in range(vertices.size()):
				_uvs.append(Vector2.ZERO)
		if normals_var != null and normals_var is PackedVector3Array:
			var normals: PackedVector3Array = normals_var
			for n in normals:
				_rest_normals.append(n)
		if colors_var != null and colors_var is PackedColorArray:
			var colors: PackedColorArray = colors_var
			for c in colors:
				_colors.append(c)
		if indices_var != null and indices_var is PackedInt32Array:
			var indices: PackedInt32Array = indices_var
			for idx in indices:
				_indices.append(idx + vertex_offset)
		vertex_offset += vertices.size()

	_mesh_center = (min_pos + max_pos) * 0.5
	var model_size := max_pos - min_pos
	_model_radius = model_size.length() * 0.5

	if _colors.is_empty():
		for i in range(_rest_positions.size()):
			_colors.append(Color.WHITE)

	if _rest_normals.size() < _rest_positions.size():
		_rest_normals.resize(_rest_positions.size())
		for i in range(_rest_normals.size()):
			_rest_normals[i] = Vector3.ZERO
		for index in range(0, _indices.size(), 3):
			var a: int = _indices[index]
			var b: int = _indices[index + 1]
			var c: int = _indices[index + 2]
			var face_normal := (_rest_positions[b] - _rest_positions[a]).cross(_rest_positions[c] - _rest_positions[a])
			_rest_normals[a] += face_normal
			_rest_normals[b] += face_normal
			_rest_normals[c] += face_normal
		for i in range(_rest_normals.size()):
			if _rest_normals[i].length_squared() > 0.0001:
				_rest_normals[i] = _rest_normals[i].normalized()
			else:
				_rest_normals[i] = (_rest_positions[i] - _mesh_center).normalized()

	_positions = _rest_positions.duplicate()
	_velocities.resize(_rest_positions.size())
	for i in range(_rest_positions.size()):
		_neighbors.append([])
	for index in range(0, _indices.size(), 3):
		var a: int = _indices[index]
		var b: int = _indices[index + 1]
		var c: int = _indices[index + 2]
		_add_neighbor(a, b)
		_add_neighbor(b, c)
		_add_neighbor(c, a)

	if _mesh_instance != null and _mesh_instance.mesh != null:
		var mat: Material = _mesh_instance.mesh.surface_get_material(0)
		if mat != null:
			_material = mat
		elif _mesh_instance.material_override != null:
			_material = _mesh_instance.material_override


func _build_mesh_data() -> void:
	_rest_positions.clear()
	_uvs.clear()
	_indices.clear()
	_colors.clear()
	_rest_normals.clear()
	_neighbors.clear()
	_mesh_center = Vector3.ZERO
	_model_radius = radius

	var height_ratio := 0.55
	var top_radius := radius
	var side_height := radius * height_ratio

	_rest_positions.append(Vector3(0.0, side_height * 0.82, 0.0))
	_uvs.append(Vector2(0.5, 0.0))

	for latitude in range(1, latitude_segments):
		var t := float(latitude) / float(latitude_segments)
		var theta := PI * t
		for longitude in range(longitude_segments):
			var phi: float = TAU * float(longitude) / float(longitude_segments)
			var base_y: float = cos(theta)
			var horizontal_scale: float = sin(theta)
			var y_pos: float = base_y * side_height
			var flatten_factor: float = 1.0 - absf(base_y) * 0.08
			var x_pos: float = horizontal_scale * cos(phi) * top_radius * flatten_factor
			var z_pos: float = horizontal_scale * sin(phi) * top_radius * flatten_factor
			var vertex_pos := Vector3(x_pos, y_pos, z_pos)
			_rest_positions.append(vertex_pos)
			_uvs.append(Vector2(float(longitude) / float(longitude_segments), t))

	var bottom_index := _rest_positions.size()
	_rest_positions.append(Vector3(0.0, -side_height * 0.88, 0.0))
	_uvs.append(Vector2(0.5, 1.0))

	var top_color := Color("#d4956a")
	var side_color := Color("#fff8e7")
	var center_color := Color("#8b4513")
	for i in range(_rest_positions.size()):
		var pos: Vector3 = _rest_positions[i]
		var normalized_y := (pos.y + side_height) / (2.0 * side_height)
		var final_color: Color
		if normalized_y > 0.52:
			var center_pattern := _calculate_center_pattern(pos.x, pos.z, top_radius)
			if center_pattern > 0.5:
				var blend := (center_pattern - 0.5) * 2.0
				final_color = top_color.lerp(center_color, blend * 0.85)
			else:
				final_color = top_color
		else:
			var side_blend := clampf(normalized_y / 0.52, 0.0, 1.0)
			final_color = side_color.lerp(top_color, side_blend * 0.3)
		_colors.append(final_color)

	var first_ring := 1
	for longitude in range(longitude_segments):
		var next_longitude := (longitude + 1) % longitude_segments
		_indices.append_array(PackedInt32Array([0, first_ring + next_longitude, first_ring + longitude]))

	for latitude in range(latitude_segments - 2):
		var upper_ring := 1 + latitude * longitude_segments
		var lower_ring := upper_ring + longitude_segments
		for longitude in range(longitude_segments):
			var next_longitude := (longitude + 1) % longitude_segments
			var a := upper_ring + longitude
			var b := lower_ring + longitude
			var c := upper_ring + next_longitude
			var d := lower_ring + next_longitude
			_indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

	var last_ring := 1 + (latitude_segments - 2) * longitude_segments
	for longitude in range(longitude_segments):
		var next_longitude := (longitude + 1) % longitude_segments
		_indices.append_array(PackedInt32Array([bottom_index, last_ring + longitude, last_ring + next_longitude]))

	_rest_normals.resize(_rest_positions.size())
	for i in range(_rest_normals.size()):
		_rest_normals[i] = Vector3.ZERO
	for index in range(0, _indices.size(), 3):
		var a: int = _indices[index]
		var b: int = _indices[index + 1]
		var c: int = _indices[index + 2]
		var face_normal := (_rest_positions[b] - _rest_positions[a]).cross(_rest_positions[c] - _rest_positions[a])
		_rest_normals[a] += face_normal
		_rest_normals[b] += face_normal
		_rest_normals[c] += face_normal
	for i in range(_rest_normals.size()):
		if _rest_normals[i].length_squared() > 0.0001:
			_rest_normals[i] = _rest_normals[i].normalized()
		else:
			_rest_normals[i] = (_rest_positions[i] - _mesh_center).normalized()

	_positions = _rest_positions.duplicate()
	_velocities.resize(_rest_positions.size())
	for i in range(_rest_positions.size()):
		_neighbors.append([])
	for index in range(0, _indices.size(), 3):
		var a: int = _indices[index]
		var b: int = _indices[index + 1]
		var c: int = _indices[index + 2]
		_add_neighbor(a, b)
		_add_neighbor(b, c)
		_add_neighbor(c, a)
	for latitude in range(1, latitude_segments):
		var ring_start := 1 + (latitude - 1) * longitude_segments
		_add_neighbor(ring_start, ring_start + longitude_segments - 1)


func _add_neighbor(a: int, b: int) -> void:
	if a == b:
		return
	var a_neighbors: Array = _neighbors[a]
	if not a_neighbors.has(b):
		a_neighbors.append(b)
	var b_neighbors: Array = _neighbors[b]
	if not b_neighbors.has(a):
		b_neighbors.append(a)


func _calculate_center_pattern(x: float, z: float, max_radius: float) -> float:
	var dist_from_center := sqrt(x * x + z * z) / max_radius
	if dist_from_center > 0.75:
		return 0.0
	var pattern_value := 0.0
	var blob1_x := 0.12
	var blob1_z := -0.08
	var dist1 := sqrt((x/max_radius - blob1_x) * (x/max_radius - blob1_x) + (z/max_radius - blob1_z) * (z/max_radius - blob1_z))
	if dist1 < 0.38:
		pattern_value = maxf(pattern_value, 1.0 - (dist1 / 0.38))
	var blob2_x := -0.18
	var blob2_z := 0.15
	var dist2 := sqrt((x/max_radius - blob2_x) * (x/max_radius - blob2_x) + (z/max_radius - blob2_z) * (z/max_radius - blob2_z))
	if dist2 < 0.32:
		pattern_value = maxf(pattern_value, 1.0 - (dist2 / 0.32))
	var blob3_x := -0.05
	var blob3_z := 0.25
	var dist3 := sqrt((x/max_radius - blob3_x) * (x/max_radius - blob3_x) + (z/max_radius - blob3_z) * (z/max_radius - blob3_z))
	if dist3 < 0.28:
		pattern_value = maxf(pattern_value, 1.0 - (dist3 / 0.28))
	var main_blob_dist := dist_from_center
	if main_blob_dist < 0.45:
		var main_strength := 1.0 - (main_blob_dist / 0.45)
		pattern_value = maxf(pattern_value, main_strength * 0.9)
	var noise := sin(x * 15.0) * cos(z * 12.0) * 0.08
	pattern_value += noise
	return clampf(pattern_value, 0.0, 1.0)


func _rebuild_surface() -> void:
	var normals := PackedVector3Array()
	normals.resize(_positions.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	for index in range(0, _indices.size(), 3):
		var a: int = _indices[index]
		var b: int = _indices[index + 1]
		var c: int = _indices[index + 2]
		var face_normal := (_positions[b] - _positions[a]).cross(_positions[c] - _positions[a])
		normals[a] += face_normal
		normals[b] += face_normal
		normals[c] += face_normal
	for i in range(normals.size()):
		if normals[i].length_squared() > 0.000001:
			normals[i] = normals[i].normalized()
		elif i < _rest_normals.size() and _rest_normals[i].length_squared() > 0.000001:
			normals[i] = _rest_normals[i]
		else:
			normals[i] = (_rest_positions[i] - _mesh_center).normalized()

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	if not _colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.clear_surfaces()
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _material != null:
		_array_mesh.surface_set_material(0, _material)