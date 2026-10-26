extends Node3D
class_name BlobDeformer

## GPU 连续形变场；CPU 仅更新交互状态，按需计算拾取数据。
@export var radius: float = 0.92
@export_range(8, 48, 1) var latitude_segments: int = 24
@export_range(12, 96, 1) var longitude_segments: int = 48

# ===== 可调参数 =====
# 回弹时长 (0.3-4s, 默认1.6) - 凹陷恢复速度
@export var recovery_time: float = 1.6
# 柔软度 (0.2-1.6, 默认0.9) - 形变扩散范围
@export var softness: float = 0.9
# 按压深度 (0.1-0.5, 默认0.32) - 按压最大深度
@export var min_depth: float = 0.32
# 手指宽度 (0.072-0.216, 默认0.138，较原版缩小40%) - 接触区域大小
@export var finger_width: float = 0.138
# 弹性抖动 (0-1, 默认0.55) - 松手后的果冻感
@export var elasticity: float = 0.55
# 初始回弹 (0-0.6, 默认0.24) - 松手后的回弹力度
@export var initial_bounce: float = 0.24
# 拉伸灵敏度 (0.3-2.5, 默认1.3) - 拉动转化为形变的倍率
@export var stretch_sensitivity: float = 1.3
# 最大拉伸 (0.8-3.6, 默认2.4) - 以模型半径为单位
@export var max_stretch: float = 2.4
# 回弹震动 (0-0.5, 默认0.2) - 点触回弹时手机震动的力度
@export var rebound_vibration: float = 0.2

const DeformShader = preload("res://shaders/soft_deformation.gdshader")

@export var press_duration: float = 1.5
@export var squash_strength: float = 0.10

const MODE_PRESS: int = 0
const MODE_STRETCH: int = 1


var _mesh_instance: MeshInstance3D
var _collision_body: StaticBody3D
var _array_mesh: ArrayMesh
var _material: StandardMaterial3D

var _rest_positions := PackedVector3Array()
var _rest_normals := PackedVector3Array()
var _cpu_positions := PackedVector3Array()
# Lazy CPU mirror for picking and regression measurements, never for rendering.
var _positions: PackedVector3Array:
	get:
		_ensure_cpu_positions()
		return _cpu_positions
var _cpu_dirty := false
var _pick_dirty := false
var _rest_picker: TriangleMesh
var _deformed_picker: TriangleMesh
var _shader_material: ShaderMaterial
var _anchor_target := Vector3.ZERO
var _normal_target := Vector3.UP
var _press_elapsed := 0.0
const MAX_TRAILS := 8
var _trail_points := PackedVector3Array()
var _trail_ends := PackedVector3Array()
var _trail_end_amounts := PackedFloat32Array()
var _stroke_has_segment := false
var _trail_normals := PackedVector3Array()
var _trail_amounts := PackedFloat32Array()
var _last_trail_point := Vector3.ZERO
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()

var _interaction_mode: int = -1
var _anchor_normal := Vector3.UP
var _anchor_point := Vector3.ZERO
var _drag_origin := Vector3.ZERO
var _squash_amount := 0.0
var _press_amount := 0.0
var _press_velocity := 0.0
var _smooth_pull := Vector3.ZERO
var _pull_velocity := Vector3.ZERO
var _stretch_recovering := false
var _rebound_axis := Vector3.RIGHT
var _source_arrays: Array = []
var _source_material: Material
var _normal_sign := -1.0
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
	_setup_gpu()

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
	_collision_body.reparent(_external_mesh_instance, false)
	_collision_body.scale = Vector3.ONE
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
	_source_arrays = arrays.duplicate(true)
	_source_material = mesh.surface_get_material(0)
	
	if arrays.is_empty() or not (arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array):
		var faces := mesh.get_faces()
		if faces.is_empty():
			return
		_rest_positions = faces
		_indices = PackedInt32Array()
		for i in range(faces.size()):
			_indices.append(i)
	else:
		_rest_positions = arrays[Mesh.ARRAY_VERTEX]
		var index_array: Variant = arrays[Mesh.ARRAY_INDEX]
		if index_array is PackedInt32Array:
			_indices = index_array
		else:
			_indices = PackedInt32Array()
			for i in range(_rest_positions.size()):
				_indices.append(i)
	
	var uv_array: Variant = arrays[Mesh.ARRAY_TEX_UV] if not arrays.is_empty() else null
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
	
	_cpu_positions = _rest_positions.duplicate()
	
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
		if _rest_normals[i].length_squared() > 1.0e-20:
			_rest_normals[i] = _rest_normals[i].normalized()
		else:
			_rest_normals[i] = Vector3.UP
	
	var imported_normals: Variant = arrays[Mesh.ARRAY_NORMAL] if not arrays.is_empty() else null
	if imported_normals is PackedVector3Array and imported_normals.size() == _rest_positions.size():
		var orientation := 0.0
		for i in range(_rest_positions.size()):
			orientation += _rest_normals[i].dot(imported_normals[i])
		_normal_sign = 1.0 if orientation >= 0.0 else -1.0
		_rest_normals = imported_normals.duplicate()

func get_collision_body() -> StaticBody3D:
	return _collision_body

func _make_picker(positions: PackedVector3Array) -> TriangleMesh:
	var faces := PackedVector3Array()
	faces.resize(_indices.size())
	for i in range(_indices.size()):
		faces[i] = (positions[_indices[i]] - _model_center) / _model_radius
	var picker := TriangleMesh.new()
	picker.create_from_faces(faces)
	return picker

func _ensure_cpu_positions() -> void:
	if not _cpu_dirty:
		return
	for i in range(_rest_positions.size()):
		_cpu_positions[i] = _rest_positions[i] + _target_offset_for(_rest_positions[i])
	_cpu_dirty = false

func pick_ray(world_origin: Vector3, world_direction: Vector3, stable_surface: bool = false) -> Dictionary:
	var mesh_node: Node3D = _external_mesh_instance if _external_mesh_instance != null else self
	var origin := (mesh_node.to_local(world_origin) - _model_center) / _model_radius
	var direction := (mesh_node.global_basis.inverse() * world_direction).normalized()
	var picker := _rest_picker
	if not stable_surface and _pick_dirty:
		_ensure_cpu_positions()
		_deformed_picker = _make_picker(_cpu_positions)
		_pick_dirty = false
	if not stable_surface and _deformed_picker != null:
		picker = _deformed_picker
	var hit := picker.intersect_ray(origin, direction)
	if hit.is_empty():
		return {}
	var index: int = hit.face_index * 3
	var ia := _indices[index]
	var ib := _indices[index + 1]
	var ic := _indices[index + 2]
	var points := _rest_positions if stable_surface else _cpu_positions
	var local_point: Vector3 = hit.position * _model_radius + _model_center
	var weights := Geometry3D.get_triangle_barycentric_coords(local_point, points[ia], points[ib], points[ic])
	var rest_point := _rest_positions[ia] * weights.x + _rest_positions[ib] * weights.y + _rest_positions[ic] * weights.z
	var normal := (_rest_normals[ia] * weights.x + _rest_normals[ib] * weights.y + _rest_normals[ic] * weights.z).normalized()
	return {"position": mesh_node.to_global(local_point), "rest_point": rest_point, "local_normal": normal}

func begin_interaction(world_point: Vector3, stretch: bool, rest_point: Vector3 = Vector3.INF, local_normal: Vector3 = Vector3.UP) -> void:
	_press_elapsed = 0.0
	_stroke_has_segment = false
	_drag_origin = _to_mesh_local(world_point)
	_anchor_target = _drag_origin if rest_point == Vector3.INF else rest_point
	_normal_target = local_normal.normalized()
	_anchor_point = _anchor_target
	_anchor_normal = _normal_target
	_last_trail_point = _anchor_point
	if not stretch:
		_press_amount = maxf(_press_amount, 0.20)
	_pull_offset = Vector3.ZERO
	_interaction_mode = MODE_STRETCH if stretch else MODE_PRESS
	_is_recovering = false

func get_stretch_amount() -> float:
	return _pull_offset.length() / _model_radius

func update_press(rest_point: Vector3, local_normal: Vector3) -> void:
	if _interaction_mode == MODE_PRESS:
		_anchor_target = rest_point
		# Keep the contact direction established on touch-down. Triangle normals
		# change abruptly at the top/side seam; they must not flip the whole dent.

func update_stretch_vector(world_offset: Vector3) -> void:
	if _interaction_mode != MODE_STRETCH:
		return
	var mesh_node: Node3D = _external_mesh_instance if _external_mesh_instance != null else self
	world_offset.y = 0.0
	_pull_offset = (mesh_node.global_basis.inverse() * world_offset * stretch_sensitivity).limit_length(max_stretch * _model_radius)
	if _pull_offset.length() > _model_radius * 0.00001:
		_stretch_recovering = false

func update_interaction(world_point: Vector3) -> void:
	if _interaction_mode == MODE_STRETCH:
		var mesh_node: Node3D = _external_mesh_instance if _external_mesh_instance != null else self
		update_stretch_vector(world_point - mesh_node.to_global(_drag_origin))
		if _pull_offset.length() > _model_radius * 0.00001:
			_stretch_recovering = false

func end_interaction() -> void:
	if _interaction_mode < 0:
		return
	if _interaction_mode == MODE_STRETCH and _smooth_pull.length() > _model_radius * 0.00001 and not _stretch_recovering:
		_rebound_axis = _smooth_pull.normalized()
		_stretch_recovering = true
	_interaction_mode = -1
	_pull_offset = Vector3.ZERO
	_is_recovering = true
	_recover_timer = 0.0
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
	_trail_ends.clear()
	_trail_end_amounts.clear()
	_stroke_has_segment = false
	_trail_points.clear()
	_trail_normals.clear()
	_trail_amounts.clear()
	_stretch_recovering = false
	_press_elapsed = 0.0
	_interaction_mode = -1
	_is_recovering = false
	_squash_amount = 0.0
	_press_amount = 0.0
	_press_velocity = 0.0
	_pull_offset = Vector3.ZERO
	_smooth_pull = Vector3.ZERO
	_pull_velocity = Vector3.ZERO
	_cpu_positions = _rest_positions.duplicate()
	_cpu_dirty = false
	_pick_dirty = false
	_deformed_picker = null
	_sync_gpu()

func _to_mesh_local(world_point: Vector3) -> Vector3:
	if _external_mesh_instance != null:
		return _external_mesh_instance.to_local(world_point)
	return to_local(world_point)

func _physics_process(delta: float) -> void:
	if _rest_positions.is_empty() or (_interaction_mode < 0 and not _is_recovering):
		return
	# Spring the deformation field instead of independent seam vertices. Identical
	# positions receive identical displacement, even across disconnected UV seams.
	var active := _interaction_mode >= 0
	var omega := 24.0 if active else 8.0 / maxf(recovery_time, 0.3)
	var damping_ratio := 0.9 if active else clampf(1.0 - elasticity * 0.55 - initial_bounce * 0.2, 0.35, 1.0)
	# Three oscillation periods per recovery_time, with a decaying envelope.
	# Press recovery keeps its softer response; only released stretch rings.
	var pull_omega := TAU * 3.0 / maxf(recovery_time, 0.3) if not active and _stretch_recovering else omega
	var pull_damping := clampf(0.23 - elasticity * 0.09 - initial_bounce * 0.02, 0.12, 0.23) if not active and _stretch_recovering else damping_ratio
	var follow := 1.0 - exp(-22.0 * minf(delta, 0.1))
	# Position follows the latest stable-surface hit within this frame. Only
	# pressure depth and departed material recover over time, never the pointer.
	_anchor_point = _anchor_target
	for i in range(_trail_amounts.size()):
		var decay := exp(-3.0 * minf(delta, 0.1) / maxf(recovery_time, 0.3))
		_trail_amounts[i] *= decay
		_trail_end_amounts[i] *= decay
	if _interaction_mode == MODE_PRESS and _anchor_point.distance_squared_to(_last_trail_point) > _model_radius * _model_radius * 0.00000001:
		_add_press_trail(_last_trail_point, _anchor_point, _anchor_normal, maxf(_press_amount, 0.0))
		_last_trail_point = _anchor_point
	var next_normal := _anchor_normal.lerp(_normal_target, follow)
	if next_normal.length_squared() > 0.00001:
		_anchor_normal = next_normal.normalized()
	if _interaction_mode == MODE_PRESS:
		_press_elapsed += minf(delta, 0.1)
	var progress := smoothstep(0.0, 1.0, clampf(_press_elapsed / maxf(press_duration, 0.1), 0.0, 1.0))
	var press_target := (0.20 + 0.80 * progress) if _interaction_mode == MODE_PRESS else 0.0
	var pull_target := _pull_offset if _interaction_mode == MODE_STRETCH else Vector3.ZERO
	var steps := maxi(1, ceili(minf(delta, 0.1) / (1.0 / 120.0)))
	var dt := minf(delta, 0.1) / steps
	for step in range(steps):
		_press_velocity += (omega * omega * (press_target - _press_amount) - 2.0 * damping_ratio * omega * _press_velocity) * dt
		_press_amount += _press_velocity * dt
		_pull_velocity += (pull_omega * pull_omega * (pull_target - _smooth_pull) - 2.0 * pull_damping * pull_omega * _pull_velocity) * dt
		_smooth_pull += _pull_velocity * dt
	# Local contact responds immediately, while whole-body compression eases in.
	_press_amount = clampf(_press_amount, -0.1, 1.0)
	_squash_amount = lerpf(_squash_amount, maxf(_press_amount, 0.0), 1.0 - exp(-minf(delta, 0.1) / 0.25))
	if not active:
		_recover_timer += delta
		if _squash_amount < 0.0005 and _trail_peak() < 0.0005 and absf(_press_amount) + absf(_press_velocity) < 0.0005 and (_smooth_pull.length() + _pull_velocity.length()) / _model_radius < 0.0005:
			reset_deformation()
			return
	_cpu_dirty = true
	_pick_dirty = true
	_sync_gpu()

func _deformation_axis() -> Vector3:
	return _rebound_axis if _stretch_recovering else _smooth_pull.normalized()

func _signed_stretch() -> float:
	return _smooth_pull.dot(_deformation_axis())

func _trail_peak() -> float:
	var peak := 0.0
	for i in range(_trail_amounts.size()):
		peak = maxf(peak, maxf(_trail_amounts[i], _trail_end_amounts[i]))
	return peak

func _add_press_trail(start: Vector3, end: Vector3, normal: Vector3, amount: float) -> void:
	if amount < 0.001:
		return
	var last := _trail_points.size() - 1
	# Extend straight runs instead of stamping separate round pits. Keep both
	# endpoint strengths so recovery varies continuously along the swept path.
	if _stroke_has_segment and last >= 0:
		var previous := (_trail_ends[last] - _trail_points[last]).normalized()
		var direction := (end - start).normalized()
		if previous.dot(direction) > 0.985:
			_trail_ends[last] = end
			_trail_end_amounts[last] = amount
			return
	if _trail_points.size() == MAX_TRAILS:
		_trail_points.remove_at(0)
		_trail_ends.remove_at(0)
		_trail_normals.remove_at(0)
		_trail_amounts.remove_at(0)
		_trail_end_amounts.remove_at(0)
	_trail_points.append(start)
	_trail_ends.append(end)
	_trail_normals.append(normal)
	_trail_amounts.append(amount)
	_trail_end_amounts.append(amount)
	_stroke_has_segment = true

func _trail_offset_at(position: Vector3, index: int) -> Vector3:
	var normal := _trail_normals[index]
	var segment := _trail_ends[index] - _trail_points[index]
	var tangent := segment - normal * segment.dot(normal)
	var relative := position - _trail_points[index]
	var weight := clampf(relative.dot(tangent) / maxf(tangent.length_squared(), 0.00000001), 0.0, 1.0)
	return _dent_at(position, _trail_points[index].lerp(_trail_ends[index], weight), normal, lerpf(_trail_amounts[index], _trail_end_amounts[index], weight))

func _dent_at(position: Vector3, point: Vector3, normal: Vector3, amount: float) -> Vector3:
	var relative := position - point
	var axial := relative.dot(normal)
	var tangent := relative - normal * axial
	var sigma := _model_radius * finger_width * (0.85 + softness * 0.25)
	var radial_sq := tangent.length_squared() / (sigma * sigma)
	var depth_mask := exp(-pow(axial / (_model_radius * 0.42), 2.0))
	var dent := exp(-radial_sq * 0.5)
	var rim := radial_sq * dent * 0.06
	# Bound by both object thickness and contact width, even after long holds.
	var depth := minf(min_depth * _model_radius * 1.5, minf(_model_size.dot(normal.abs()) * 0.45, sigma * 1.5))
	return normal * (rim - dent) * depth * clampf(amount, -0.1, 1.0) * depth_mask

func _target_offset_for(rest_position: Vector3) -> Vector3:
	var relative := rest_position - _anchor_point
	var offset := _dent_at(rest_position, _anchor_point, _anchor_normal, _press_amount)
	var weight := pow(offset.length_squared(), 2.0)
	var weighted_offset := offset * weight
	var total_weight := weight
	for i in range(_trail_points.size()):
		if maxf(_trail_amounts[i], _trail_end_amounts[i]) < 0.0005:
			continue
		var trail := _trail_offset_at(rest_position, i)
		# A normalized blend is continuous where trails meet, and cannot deepen
		# by repeatedly crossing the same place (a convex combination).
		var trail_weight := pow(trail.length_squared(), 2.0)
		weighted_offset += trail * trail_weight
		total_weight += trail_weight
	offset = weighted_offset / maxf(total_weight, 0.000000000001)
	var bottom := _model_center.y - _model_size.y * 0.5
	var squash := clampf(_squash_amount * squash_strength, -0.04, 0.18)
	var spread := 1.0 / sqrt(1.0 - squash) - 1.0
	offset += Vector3((rest_position.x - _model_center.x) * spread, -(rest_position.y - bottom) * squash, (rest_position.z - _model_center.z) * spread)
	var pull_length := _signed_stretch()
	if absf(pull_length) > _model_radius * 0.00001:
		var direction := _deformation_axis()
		var centered := rest_position - _model_center
		# Long pulls concentrate strain in a smooth central neck. The ends retain
		# their volume, and a positive cross-section keeps the neck connected.
		var strain := pull_length / (_model_radius * 2.0)
		# Negative strain compresses along the original axis and expands across
		# it. Exponential compression remains positive even after a long pull.
		var factor := 1.0 + strain if strain >= 0.0 else maxf(0.35, exp(strain))
		var neck_strength := smoothstep(0.65, 2.6, pull_length / _model_radius)
		var half_extent := maxf(direction.abs().dot(_model_size * 0.5), _model_radius * 0.01)
		var along := centered.dot(direction)
		var axis_position := along / half_extent
		var neck_weight := exp(-0.5 * pow(axis_position / 0.36, 2.0))
		var thin := lerpf(1.0 / sqrt(factor), 1.0, neck_strength * (1.0 - neck_weight))
		thin = maxf(0.16, thin * (1.0 - 0.82 * neck_strength * neck_weight))
		# This monotonic mapping lengthens the waist without reversing triangles
		# along the pulling axis. Small pulls keep the previous uniform stretch.
		var strain_profile := lerpf(axis_position, tanh(axis_position * 2.2) / tanh(2.2), neck_strength * 0.8)
		var stretched_along := along + (factor - 1.0) * half_extent * strain_profile
		var parallel := direction * along
		var stretched := direction * stretched_along + (centered - parallel) * thin
		# Scale thickness about the base, so narrowing and recoil never push
		# the opposite end through the table.
		stretched.y = bottom - _model_center.y + (rest_position.y - bottom) * thin
		var grab_sigma := _model_radius * (0.75 + softness * 0.25)
		var grab := exp(-relative.length_squared() / (2.0 * grab_sigma * grab_sigma))
		offset += stretched - centered + _smooth_pull * (0.10 + grab * 0.15)
	# Smoothly resist compression while preserving at least 15% of each
	# vertex's original height. Unlike a floor clamp, this cannot flatten
	# both sides of the cake into the same coplanar sheet.
	if offset.y < 0.0:
		var height := maxf(rest_position.y - bottom, 0.0)
		var compressible := maxf(height * 0.85, _model_radius * 0.000001)
		offset.y = -height * 0.85 * (1.0 - exp(offset.y / compressible))
	return offset

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
	_model_radius = radius
	_model_center = Vector3.ZERO
	_model_size = Vector3.ONE * radius * 2.0
	_rest_positions.clear()
	_uvs.clear()
	_indices.clear()
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

	_cpu_positions = _rest_positions.duplicate()
	# 计算静止法线
	_rest_normals = PackedVector3Array()
	_rest_normals.resize(_rest_positions.size())
	for i in range(_rest_normals.size()):
		_rest_normals[i] = _rest_positions[i].normalized() if _rest_positions[i].length_squared() > 0.0001 else Vector3.UP

func _rebuild_surface() -> void:
	var normals := PackedVector3Array()
	normals.resize(_positions.size())
	for index in range(0, _indices.size(), 3):
		var a := _indices[index]
		var b := _indices[index + 1]
		var c := _indices[index + 2]
		var face_normal := (_positions[b] - _positions[a]).cross(_positions[c] - _positions[a]) * _normal_sign
		normals[a] += face_normal
		normals[b] += face_normal
		normals[c] += face_normal
	for i in range(normals.size()):
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 1.0e-20 else _rest_normals[i]
	var arrays: Array = _source_arrays.duplicate() if not _source_arrays.is_empty() else []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.clear_surfaces()
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _external_mesh_instance != null:
		_array_mesh.surface_set_material(0, _source_material)
		_external_mesh_instance.mesh = _array_mesh
	else:
		_array_mesh.surface_set_material(0, _material)

func _setup_gpu() -> void:
	var instance := _external_mesh_instance if _external_mesh_instance != null else _mesh_instance
	var source := _source_material if _external_mesh_instance != null else _material
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = DeformShader
	if source is StandardMaterial3D:
		_shader_material.set_shader_parameter("base_color", source.albedo_color)
		_shader_material.set_shader_parameter("material_roughness", source.roughness)
		_shader_material.set_shader_parameter("material_metallic", source.metallic)
		if source.normal_enabled and source.normal_texture != null:
			_shader_material.set_shader_parameter("normal_texture", source.normal_texture)
			_shader_material.set_shader_parameter("has_normal_texture", true)
			_shader_material.set_shader_parameter("normal_strength", source.normal_scale)
		if source.albedo_texture != null:
			_shader_material.set_shader_parameter("albedo_texture", source.albedo_texture)
			_shader_material.set_shader_parameter("has_albedo_texture", true)
	instance.material_override = _shader_material
	# Shader displacement is invisible to the engine's static bounds.
	instance.custom_aabb = AABB(_model_center - Vector3.ONE * _model_radius * 6.0, Vector3.ONE * _model_radius * 12.0)
	_rest_picker = _make_picker(_rest_positions)
	_sync_gpu()

func _sync_gpu() -> void:
	if _shader_material == null:
		return
	_shader_material.set_shader_parameter("model_center", _model_center)
	_shader_material.set_shader_parameter("model_size", _model_size)
	_shader_material.set_shader_parameter("model_radius", _model_radius)
	_shader_material.set_shader_parameter("anchor_point", _anchor_point)
	_shader_material.set_shader_parameter("anchor_normal", _anchor_normal)
	_shader_material.set_shader_parameter("press_amount", _press_amount)
	_shader_material.set_shader_parameter("squash_amount", _squash_amount)
	_shader_material.set_shader_parameter("press_depth", min_depth)
	_shader_material.set_shader_parameter("finger_width", finger_width)
	_shader_material.set_shader_parameter("softness", softness)
	_shader_material.set_shader_parameter("squash_strength", squash_strength)
	var points := _trail_points.duplicate()
	var ends := _trail_ends.duplicate()
	var end_amounts := _trail_end_amounts.duplicate()
	ends.resize(MAX_TRAILS)
	end_amounts.resize(MAX_TRAILS)
	_shader_material.set_shader_parameter("trail_ends", ends)
	_shader_material.set_shader_parameter("trail_end_amounts", end_amounts)
	var normals := _trail_normals.duplicate()
	var amounts := _trail_amounts.duplicate()
	points.resize(MAX_TRAILS)
	normals.resize(MAX_TRAILS)
	amounts.resize(MAX_TRAILS)
	_shader_material.set_shader_parameter("trail_count", _trail_points.size())
	_shader_material.set_shader_parameter("trail_points", points)
	_shader_material.set_shader_parameter("trail_normals", normals)
	_shader_material.set_shader_parameter("trail_amounts", amounts)
	_shader_material.set_shader_parameter("pull", _smooth_pull)
	_shader_material.set_shader_parameter("stretch_axis", _deformation_axis())
	_shader_material.set_shader_parameter("stretch_amount", _signed_stretch())
