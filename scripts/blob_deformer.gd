extends Node3D
class_name BlobDeformer

## 捏捏形变器 - 基于顶点弹簧的软体形变系统
@export var radius: float = 0.92
@export_range(8, 48, 1) var latitude_segments: int = 24
@export_range(12, 96, 1) var longitude_segments: int = 48

# ===== 可调参数 =====
# 回弹时长 (0.3-4s, 默认1.6) - 凹陷恢复速度
@export var recovery_time: float = 1.6
# 柔软度 (0.2-1.6, 默认0.9) - 形变扩散范围
@export var softness: float = 0.9
# 下限深度 (0.1-0.5, 默认0.32) - 按压最大深度
@export var min_depth: float = 0.32
# 手指宽度 (0.12-0.36, 默认0.23) - 接触区域大小
@export var finger_width: float = 0.23
# 弹性抖动 (0-1, 默认0.55) - 松手后的果冻感
@export var elasticity: float = 0.55
# 初始回弹 (0-0.6, 默认0.24) - 松手后的回弹力度
@export var initial_bounce: float = 0.24
# 拉伸灵敏度 (0.3-2.5, 默认1.3) - 拉动转化为形变的倍率
@export var stretch_sensitivity: float = 1.3
# 最大拉伸 (0.8-3.6, 默认2.4) - 最大形变限制
@export var max_stretch: float = 2.4
# 回弹震动 (0-0.5, 默认0.2) - 点触回弹时手机震动的力度
@export var rebound_vibration: float = 0.2

const MODE_PRESS: int = 0
const MODE_STRETCH: int = 1
const MAX_VERTEX_OFFSET: float = 3.0

var _mesh_instance: MeshInstance3D
var _collision_body: StaticBody3D
var _array_mesh: ArrayMesh
var _material: StandardMaterial3D

var _rest_positions := PackedVector3Array()
var _rest_normals := PackedVector3Array()
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _neighbors: Array = []

var _interaction_mode: int = -1
var _anchor_normal := Vector3.UP
var _anchor_point := Vector3.ZERO
var _last_drag_point := Vector3.ZERO
var _pull_offset := Vector3.ZERO

# 外部模型支持
var _external_mesh_instance: MeshInstance3D = null
var _model_center: Vector3 = Vector3.ZERO
var _model_radius: float = 1.0
var _model_size: Vector3 = Vector3.ONE

# 回弹状态
var _is_recovering := false
var _recover_timer := 0.0

func _ready() -> void:
	if _mesh_instance == null:
		_build_nodes()
	if _external_mesh_instance != null:
		_configure_collision_body()
	else:
		_build_mesh_data()
		_rebuild_surface()

func _configure_collision_body() -> void:
	if _collision_body == null or _external_mesh_instance == null:
		return
	var collision_shape := _collision_body.get_child(0) as CollisionShape3D
	if collision_shape != null:
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3(
			_model_size.x * 1.1,
			_model_size.y * 1.1,
			_model_size.z * 1.1
		)
		collision_shape.shape = box_shape
	_collision_body.reparent(_external_mesh_instance)
	_collision_body.position = _model_center

func set_external_mesh(mesh_instance: MeshInstance3D) -> void:
	if _collision_body == null:
		_build_nodes()
	_external_mesh_instance = mesh_instance
	_extract_external_mesh_data()
	if _mesh_instance != null:
		_mesh_instance.visible = false
	if is_inside_tree():
		_configure_collision_body()

func _extract_external_mesh_data() -> void:
	if _external_mesh_instance == null:
		return
	var mesh := _external_mesh_instance.mesh
	if mesh == null:
		return
	var arrays = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return
	
	var vertex_array: Variant = arrays[Mesh.ARRAY_VERTEX]
	if vertex_array is PackedVector3Array:
		_rest_positions = vertex_array
	else:
		return
	
	var index_array: Variant = arrays[Mesh.ARRAY_INDEX]
	if index_array is PackedInt32Array:
		_indices = index_array
	else:
		return
	
	var uv_array: Variant = arrays[Mesh.ARRAY_TEX_UV]
	if uv_array != null and uv_array is PackedVector2Array:
		_uvs = uv_array
	else:
		_uvs.resize(_rest_positions.size())
		for i in range(_rest_positions.size()):
			_uvs[i] = Vector2.ZERO
	
	var min_pos := Vector3.ONE * 999999.0
	var max_pos := Vector3.ONE * -999999.0
	for pos in _rest_positions:
		min_pos = min_pos.min(pos)
		max_pos = max_pos.max(pos)
	_model_center = (min_pos + max_pos) * 0.5
	var size := max_pos - min_pos
	_model_size = size
	_model_radius = maxf(size.x, maxf(size.y, size.z)) * 0.5
	
	_positions = _rest_positions.duplicate()
	_velocities.resize(_rest_positions.size())
	for i in range(_velocities.size()):
		_velocities[i] = Vector3.ZERO
	
	# 计算静止法线
	_rest_normals = PackedVector3Array()
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
		if _rest_normals[i].length_squared() > 0.000001:
			_rest_normals[i] = _rest_normals[i].normalized()
		else:
			_rest_normals[i] = Vector3.UP
	
	_neighbors.clear()
	for i in range(_rest_positions.size()):
		_neighbors.append([])
	for index in range(0, _indices.size(), 3):
		var a: int = _indices[index]
		var b: int = _indices[index + 1]
		var c: int = _indices[index + 2]
		_add_neighbor(a, b)
		_add_neighbor(b, c)
		_add_neighbor(c, a)

func get_collision_body() -> StaticBody3D:
	return _collision_body

func begin_interaction(world_point: Vector3, stretch: bool) -> void:
	var local_point := _to_mesh_local(world_point)
	_anchor_point = local_point
	_anchor_normal = (local_point - _model_center).normalized()
	_last_drag_point = local_point
	_pull_offset = Vector3.ZERO
	_interaction_mode = MODE_STRETCH if stretch else MODE_PRESS
	_is_recovering = false

func update_interaction(world_point: Vector3) -> void:
	if _interaction_mode < 0:
		return
	var local_point := _to_mesh_local(world_point)
	if _interaction_mode == MODE_PRESS:
		_anchor_point = local_point
		_anchor_normal = (local_point - _model_center).normalized()
	else:
		var drag_delta := local_point - _last_drag_point
		drag_delta.y = 0.0
		_pull_offset += drag_delta * stretch_sensitivity
		_pull_offset.y = 0.0
		if _pull_offset.length() > max_stretch:
			_pull_offset = _pull_offset.normalized() * max_stretch
	_last_drag_point = local_point

func end_interaction() -> void:
	_interaction_mode = -1
	_pull_offset = Vector3.ZERO
	_is_recovering = true
	_recover_timer = 0.0
	
	# 触发回弹震动
	_trigger_vibration()

func _trigger_vibration() -> void:
	if OS.has_feature("web"):
		# Web 平台使用 JavaScript 震动
		var vibration_strength = rebound_vibration * (1.0 + initial_bounce)
		vibration_strength = minf(vibration_strength, 1.0)
		if vibration_strength > 0.05:
			JavaScriptBridge.eval("if(navigator.vibrate) navigator.vibrate(" + str(int(vibration_strength * 200)) + ")")
	else:
		# 移动端原生震动
		var vibration_strength = rebound_vibration * (1.0 + initial_bounce)
		vibration_strength = minf(vibration_strength, 1.0)
		if vibration_strength > 0.05:
			Input.start_joy_vibration(0, vibration_strength, vibration_strength, vibration_strength * 0.2)

func reset_deformation() -> void:
	end_interaction()
	_positions = _rest_positions.duplicate()
	_velocities.resize(_rest_positions.size())
	for i in range(_velocities.size()):
		_velocities[i] = Vector3.ZERO
	_rebuild_surface()

func _to_mesh_local(world_point: Vector3) -> Vector3:
	if _external_mesh_instance != null:
		return _external_mesh_instance.to_local(world_point)
	return to_local(world_point)

func _physics_process(delta: float) -> void:
	if _rest_positions.is_empty():
		return
	
	var still_moving := _interaction_mode >= 0
	var vertex_count := _positions.size()
	var next_positions := PackedVector3Array()
	next_positions.resize(vertex_count)
	
	# 计算弹簧系数（基于回弹时长）
	var stiffness := 150.0 / (recovery_time * recovery_time)
	var damping := 12.0 / recovery_time
	
	# 弹性抖动系数
	var jitter := elasticity * 0.3
	
	for i in range(vertex_count):
		var rest_position: Vector3 = _rest_positions[i]
		var surface_normal: Vector3 = _rest_normals[i]
		var target_offset := _target_offset_for(rest_position, surface_normal)
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
		
		# 基础弹簧力
		var acceleration := (target_offset - current_offset) * stiffness
		acceleration += laplacian * softness * 8.0
		
		# 弹性抖动（果冻感）
		if _is_recovering and jitter > 0.0:
			var jitter_force := sin(_recover_timer * 15.0 + i * 0.1) * jitter * exp(-_recover_timer * 3.0)
			acceleration += surface_normal * jitter_force * 0.5
		
		acceleration -= _velocities[i] * damping
		
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
	
	if _is_recovering:
		_recover_timer += delta
		# 初始回弹力度
		if _recover_timer < 0.1 and initial_bounce > 0.0:
			var bounce_force := initial_bounce * 2.0 * (1.0 - _recover_timer * 10.0)
			for i in range(vertex_count):
				_velocities[i] += _rest_normals[i] * bounce_force * delta
		
		if _recover_timer > recovery_time * 2.0 and not still_moving:
			_is_recovering = false
			for i in range(vertex_count):
				_positions[i] = _rest_positions[i]
				_velocities[i] = Vector3.ZERO
			return
	
	if _interaction_mode < 0 and not still_moving:
		for i in range(vertex_count):
			_positions[i] = _rest_positions[i]
			_velocities[i] = Vector3.ZERO
		return
	
	_rebuild_surface()

func _target_offset_for(rest_position: Vector3, surface_normal: Vector3) -> Vector3:
	if _interaction_mode < 0:
		return Vector3.ZERO
	
	var local_dist := rest_position.distance_to(_anchor_point)
	var soft_sigma := finger_width * _model_radius * 0.8
	var soft_falloff := exp(-(local_dist * local_dist) / (2.0 * soft_sigma * soft_sigma))
	
	if _interaction_mode == MODE_PRESS:
		# 按压凹陷效果 - 沿表面法线向内凹陷
		if local_dist > soft_sigma * 3.0:
			return Vector3.ZERO
		
		# 中心深坑 - 沿表面法线向内凹陷
		var dent_depth := min_depth * _model_radius * 1.2
		var dent := -surface_normal * dent_depth * soft_falloff
		
		# 环形隆起 - 在凹陷边缘沿法线向外微微鼓起
		var ring_distance := local_dist - soft_sigma * 1.5
		var ring_sigma := soft_sigma * 0.6
		var ring := exp(-(ring_distance * ring_distance) / (2.0 * ring_sigma * ring_sigma))
		var bulge_height := min_depth * _model_radius * 0.4
		var soft_bulge := surface_normal * bulge_height * ring
		
		var offset := dent + soft_bulge
		# 限制最大偏移量，防止面片撕裂
		if offset.length() > _model_radius * 0.5:
			offset = offset.normalized() * _model_radius * 0.5
		return offset
	
	# 拉伸模式：体积守恒变换 - 只允许横向拉伸（XZ平面）
	var stretch_dir := _pull_offset.normalized()
	if stretch_dir.length_squared() < 0.0001:
		return Vector3.ZERO
	
	# 强制拉伸方向在XZ平面（横向），忽略Y分量
	stretch_dir.y = 0.0
	stretch_dir = stretch_dir.normalized()
	if stretch_dir.length_squared() < 0.0001:
		stretch_dir = Vector3.RIGHT
	
	var stretch_amount := _pull_offset.length()
	var stretch_factor := 1.0 + stretch_amount * 0.6
	var thin_factor := 1.0 / sqrt(stretch_factor)
	
	# 以模型中心为基准进行体积守恒变换
	var centered_rest := rest_position - _model_center
	var rest_xz := Vector3(centered_rest.x, 0.0, centered_rest.z)
	var parallel_xz := rest_xz.dot(stretch_dir)
	var perpendicular_xz := rest_xz - stretch_dir * parallel_xz
	
	# 横向拉伸 + 纵向压缩（体积守恒）- 让模型变长变薄
	var stretched_xz := stretch_dir * parallel_xz * stretch_factor + perpendicular_xz * thin_factor
	var final_centered := Vector3(stretched_xz.x, centered_rest.y * thin_factor, stretched_xz.z)
	var final_pos := final_centered + _model_center
	
	# 局部拉动效果
	var local_pull := Vector3(_pull_offset.x, 0.0, _pull_offset.z) * soft_falloff * 0.3
	
	return (final_pos - rest_position) + local_pull

func _build_nodes() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "DeformableMesh"
	add_child(_mesh_instance)

	_array_mesh = ArrayMesh.new()
	_mesh_instance.mesh = _array_mesh
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color("#b95b30")
	_material.roughness = 0.3
	_material.metallic = 0.0
	_mesh_instance.material_override = _material

	_collision_body = StaticBody3D.new()
	_collision_body.name = "PickingCollider"
	_collision_body.collision_layer = 1
	_collision_body.collision_mask = 0
	add_child(_collision_body)
	var collision_shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = radius
	collision_shape.shape = sphere_shape
	_collision_body.add_child(collision_shape)

func _build_mesh_data() -> void:
	_rest_positions.clear()
	_uvs.clear()
	_indices.clear()
	_neighbors.clear()
	_rest_positions.append(Vector3.UP * radius)
	_uvs.append(Vector2(0.5, 0.0))

	for latitude in range(1, latitude_segments):
		var theta := PI * float(latitude) / float(latitude_segments)
		for longitude in range(longitude_segments):
			var phi := TAU * float(longitude) / float(longitude_segments)
			var position := Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * radius
			_rest_positions.append(position)
			_uvs.append(Vector2(float(longitude) / float(longitude_segments), float(latitude) / float(latitude_segments)))

	var bottom_index := _rest_positions.size()
	_rest_positions.append(Vector3.DOWN * radius)
	_uvs.append(Vector2(0.5, 1.0))
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
	
	# 计算静止法线
	_rest_normals = PackedVector3Array()
	_rest_normals.resize(_rest_positions.size())
	for i in range(_rest_normals.size()):
		_rest_normals[i] = _rest_positions[i].normalized() if _rest_positions[i].length_squared() > 0.0001 else Vector3.UP

func _add_neighbor(a: int, b: int) -> void:
	if a == b:
		return
	var a_neighbors: Array = _neighbors[a]
	if not a_neighbors.has(b):
		a_neighbors.append(b)
	var b_neighbors: Array = _neighbors[b]
	if not b_neighbors.has(a):
		b_neighbors.append(a)

func _rebuild_surface() -> void:
	if _external_mesh_instance != null:
		_rebuild_external_mesh()
		return
	
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
		else:
			normals[i] = _rest_normals[i]

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.clear_surfaces()
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_array_mesh.surface_set_material(0, _material)

func _rebuild_external_mesh() -> void:
	if _external_mesh_instance == null:
		return
	
	var mesh := _external_mesh_instance.mesh
	if mesh == null:
		return
	
	var new_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	
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
		else:
			normals[i] = _rest_normals[i]
	
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var surface_count := mesh.get_surface_count()
	if surface_count > 0:
		var mat := mesh.surface_get_material(0)
		if mat != null:
			new_mesh.surface_set_material(0, mat)
	
	_external_mesh_instance.mesh = new_mesh