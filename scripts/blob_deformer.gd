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

const DEFAULT_RAISED_RIM_PRESS := true
const GATHER_TRAIL_RECOVERY_SCALE := 0.3
var raised_rim_press := DEFAULT_RAISED_RIM_PRESS

func set_raised_rim_press(enabled: bool) -> void:
	if raised_rim_press == enabled:
		return
	# Reset the old field before switching its profile to avoid stale dents
	# changing shape abruptly underneath an active gesture.
	reset_deformation()
	raised_rim_press = enabled
	_sync_gpu()

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
var _grab_point_a := Vector3.ZERO
var _grab_point_b := Vector3.ZERO
var _grab_normal_a := Vector3.UP
var _grab_normal_b := Vector3.UP
var _grab_pressure := 0.0
const ACTIVE_TRAILS := 12
const MAX_TRAILS := 20
var _trail_retire_times := PackedFloat32Array()
var _trail_sample_elapsed := 1.0
var _trail_points := PackedVector3Array()
var _trail_ends := PackedVector3Array()
var _trail_end_amounts := PackedFloat32Array()
var _stroke_has_segment := false
var _trail_normals := PackedVector3Array()
var _trail_amounts := PackedFloat32Array()
var _last_trail_point := Vector3.ZERO
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()

# Fixed hand span, calibrated against the rest model, never projected length.
const GRIP_HAND_SPAN_RATIO := 0.54

var grip_amount := 0.0
var grip_stage := 0.0
var _grip_axis := Vector3.RIGHT
var _grip_extent := 0.0
var _grip_width := 0.0
var _grip_velocity := 0.0
var _grip_held := false
var _grip_shake := 0.0
var _grip_shake_vertical := 0.0
var _grip_shake_vertical_ratio := 0.25
var _grip_shake_vertical_phase := 0.0
var _grip_shake_time := 0.0
var _grip_shake_duration := 0.0
var _grip_shake_amplitude := 0.0
var _grip_haptic_active := false
var _grip_rng := RandomNumberGenerator.new()

var _interaction_mode: int = -1
var _anchor_normal := Vector3.UP
var _anchor_point := Vector3.ZERO
var _drag_origin := Vector3.ZERO
var _squash_amount := 0.0
var _press_amount := 0.0
var _press_velocity := 0.0
var _smooth_pull := Vector3.ZERO
var _pull_velocity := Vector3.ZERO
var _press_rebounding := false
var _press_rebound_direction := Vector3.RIGHT
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
	return {"position": mesh_node.to_global(local_point), "rest_point": rest_point, "local_normal": normal, "uv": _uvs[ia] * weights.x + _uvs[ib] * weights.y + _uvs[ic] * weights.z}

func set_doodle_texture(texture: Texture2D) -> void:
	_shader_material.set_shader_parameter("doodle_texture", texture)
	_shader_material.set_shader_parameter("has_doodle_texture", texture != null)

func begin_interaction(world_point: Vector3, stretch: bool, rest_point: Vector3 = Vector3.INF, local_normal: Vector3 = Vector3.UP) -> void:
	_press_elapsed = 0.0
	_press_rebounding = false
	_press_rebound_direction = Vector3.RIGHT
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
	if stretch:
		_grab_point_a = _anchor_point
		_grab_normal_a = _anchor_normal
		_grab_point_b = Vector3(2.0 * _model_center.x - _anchor_point.x, _anchor_point.y, 2.0 * _model_center.z - _anchor_point.z)
		_grab_normal_b = Vector3(-_anchor_normal.x, _anchor_normal.y, -_anchor_normal.z)

func set_stretch_contacts(point_a: Vector3, normal_a: Vector3, point_b: Vector3, normal_b: Vector3) -> void:
	_grab_point_a = point_a
	_grab_normal_a = normal_a.normalized()
	_grab_point_b = point_b
	_grab_normal_b = normal_b.normalized()

func get_stretch_amount() -> float:
	return _pull_offset.length() / _model_radius

func update_press(rest_point: Vector3, local_normal: Vector3) -> void:
	if _interaction_mode == MODE_PRESS:
		var motion := rest_point - _anchor_target
		motion.y = 0.0
		if motion.length_squared() > _model_radius * _model_radius * 0.000001:
			_press_rebound_direction = motion.normalized()
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
	if _interaction_mode == MODE_PRESS:
		# Start with velocity, not a displacement jump. A small negative impulse
		# briefly shortens and thickens the body along the last press-drag axis.
		var strength := clampf(_press_amount, 0.0, 1.0)
		if strength > 0.01:
			_rebound_axis = _press_rebound_direction
			_press_rebounding = true
			_stretch_recovering = true
			_smooth_pull = Vector3.ZERO
			var frequency := TAU * 2.5 / maxf(recovery_time, 0.3)
			_pull_velocity = -_rebound_axis * _model_radius * 0.12 * strength * frequency
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
	_trail_retire_times.clear()
	_trail_sample_elapsed = 1.0
	_trail_ends.clear()
	_trail_end_amounts.clear()
	_stroke_has_segment = false
	_trail_points.clear()
	_trail_normals.clear()
	_trail_amounts.clear()
	_stretch_recovering = false
	_press_rebounding = false
	_grab_pressure = 0.0
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
	_cpu_dirty = is_gripping()
	_pick_dirty = is_gripping()
	_deformed_picker = null
	_sync_gpu()

func _to_mesh_local(world_point: Vector3) -> Vector3:
	if _external_mesh_instance != null:
		return _external_mesh_instance.to_local(world_point)
	return to_local(world_point)

func set_grip_axis(world_right: Vector3) -> void:
	if is_gripping():
		return
	var mesh_node: Node3D = _external_mesh_instance if _external_mesh_instance != null else self
	_grip_axis = mesh_node.global_basis.inverse() * world_right
	_grip_axis.y = 0.0
	_grip_axis = _grip_axis.normalized()
	var along := _grip_axis.cross(Vector3.UP)
	_grip_extent = 0.0
	_grip_width = 0.0
	for p in _rest_positions:
		_grip_extent = maxf(_grip_extent, absf((p - _model_center).dot(along)))
		_grip_width = maxf(_grip_width, absf((p - _model_center).dot(_grip_axis)))

func set_grip_held(held: bool) -> void:
	_grip_held = held
	if not held:
		_stop_grip_haptic()

func cancel_grip() -> void:
	_stop_grip_haptic()
	_grip_shake = 0.0
	_grip_shake_vertical = 0.0
	_grip_shake_time = 0.0
	_grip_shake_duration = 0.0
	_grip_held = false
	grip_amount = 0.0
	grip_stage = 0.0
	_grip_velocity = 0.0
	_cpu_dirty = true
	_pick_dirty = true
	_sync_gpu()

func is_gripping() -> bool:
	return _grip_held or grip_stage > 0.0001 or absf(grip_amount) + absf(_grip_velocity) > 0.0001

func _step_grip(delta: float) -> void:
	if not is_gripping():
		return
	grip_stage = move_toward(grip_stage, 1.0 if _grip_held else 0.0, minf(delta, 0.1) / (0.65 if _grip_held else 1.0))
	var steps := maxi(1, ceili(minf(delta, 0.1) * 120.0))
	var dt := minf(delta, 0.1) / steps
	var omega := 8.0 if _grip_held else 16.0
	var damping := 1.0 if _grip_held else 0.4
	for i in range(steps):
		_grip_velocity += (omega * omega * ((1.0 if _grip_held else 0.0) - grip_amount) - 2.0 * damping * omega * _grip_velocity) * dt
		grip_amount += _grip_velocity * dt
	if not _grip_held and absf(grip_amount) + absf(_grip_velocity) < 0.0001:
		grip_amount = 0.0
		_grip_velocity = 0.0
	_step_grip_shake(minf(delta, 0.1))
	_cpu_dirty = true
	_pick_dirty = true
	_sync_gpu()

# One random, smooth left/right pulse per cycle; only a scalar is sent to the GPU.
func _step_grip_shake(delta: float) -> void:
	if not _grip_held or grip_amount < 0.94:
		_grip_shake *= exp(-30.0 * delta)
		_grip_shake_vertical *= exp(-30.0 * delta)
		if absf(_grip_shake_vertical) < _model_radius * 0.000001:
			_grip_shake_vertical = 0.0
		if absf(_grip_shake) < _model_radius * 0.000001:
			_grip_shake = 0.0
		_grip_shake_duration = 0.0
		_stop_grip_haptic()
		return
	if _grip_shake_duration <= 0.0 or _grip_shake_time >= _grip_shake_duration:
		_grip_shake_time = 0.0
		_grip_shake_duration = _grip_rng.randf_range(0.10, 0.18)
		_grip_shake_amplitude = _grip_rng.randf_range(0.008, 0.022) * _model_radius
		_grip_shake_vertical_ratio = _grip_rng.randf_range(0.20, 0.35)
		_grip_shake_vertical_phase = _grip_rng.randf_range(-PI, PI)
		if _grip_rng.randf() < 0.5:
			_grip_shake_amplitude *= -1.0
		var strength := absf(_grip_shake_amplitude) / (_model_radius * 0.022) * smoothstep(0.94, 1.0, grip_amount)
		_grip_haptic(strength, _grip_shake_duration)
	_grip_shake_time = minf(_grip_shake_time + delta, _grip_shake_duration)
	var phase := _grip_shake_time / _grip_shake_duration
	var envelope := pow(sin(PI * phase), 2.0) * smoothstep(0.94, 1.0, grip_amount)
	_grip_shake = _grip_shake_amplitude * sin(TAU * phase) * envelope
	_grip_shake_vertical = _grip_shake_amplitude * _grip_shake_vertical_ratio * sin(TAU * phase + _grip_shake_vertical_phase) * envelope

func _grip_haptic(strength: float, duration: float) -> void:
	_grip_haptic_active = true
	var milliseconds := maxi(1, roundi(duration * 1000.0))
	if OS.has_feature("web"):
		# Browsers expose duration only; pulse duty follows visual shake strength.
		var on := maxi(1, roundi(milliseconds * 0.5 * strength))
		var gap := maxi(1, milliseconds - on * 2)
		JavaScriptBridge.eval("try { if (navigator.vibrate) navigator.vibrate([%d,%d,%d]); } catch (e) {}" % [on, gap, on])
	elif OS.get_name() == "Android" or OS.get_name() == "iOS":
		Input.vibrate_handheld(milliseconds, strength)

func _stop_grip_haptic() -> void:
	if not _grip_haptic_active:
		return
	_grip_haptic_active = false
	if OS.has_feature("web"):
		JavaScriptBridge.eval("try { if (navigator.vibrate) navigator.vibrate(0); } catch (e) {}")
	elif OS.get_name() == "Android" or OS.get_name() == "iOS":
		Input.vibrate_handheld(0)

func _grip_hand_half_width() -> float:
	return minf(_model_size.x, _model_size.z) * GRIP_HAND_SPAN_RATIO * 0.5

func _grip_finger_profile(z: float) -> float:
	var profile := 0.0
	for i in range(4):
		var center := -0.72 + float(i) * 0.48
		var t := (z - center) / 0.30
		var bump := maxf(1.0 - t * t, 0.0)
		profile += bump * bump
	return profile

# Four photographed grip stages: squeeze, extrusion, contact, torsion.
# Each channel has its own progression instead of scaling one final shape.
func _grip_pose_parameters(amount: float) -> Vector4:
	if amount <= 0.0:
		return Vector4(amount, amount, 0.0, amount * 0.35)
	var keys := [Vector4.ZERO, Vector4(0.32, 0.10, 0.18, 0.02), Vector4(0.57, 0.25, 0.36, 0.12), Vector4(0.84, 0.63, 0.78, 0.60), Vector4.ONE]
	var phase := clampf(amount, 0.0, 1.0) * 4.0
	var index := mini(int(phase), 3)
	return keys[index].lerp(keys[index + 1], smoothstep(0.0, 1.0, phase - index))

func _grip_offset(p: Vector3) -> Vector3:
	var pose := _grip_pose_parameters(grip_amount)
	var centered := p - _model_center
	var along := _grip_axis.cross(Vector3.UP)
	var c := Vector3(centered.dot(_grip_axis), centered.y, centered.dot(along))
	var extent := _grip_extent if _grip_extent > 0.0 else _model_size.z * 0.5
	var width := _grip_width if _grip_width > 0.0 else _model_size.x * 0.5
	var hand := maxf(_grip_hand_half_width(), 0.000001)
	var nx := c.x / maxf(width, 0.000001)
	var z := c.z / maxf(extent, 0.000001)
	var nz := clampf(absf(z), 0.0, 1.0)
	var y := c.y / maxf(_model_size.y * 0.5, 0.000001)
	# Oblique contact frame: four fingers rise toward the inside of the palm.
	var hand_z := c.z / hand - (0.10 + 0.18 * pose.w) * nx
	var waist := 1.0 - smoothstep(0.50, 1.50, absf(hand_z))
	var ends := 1.0 - waist
	var pressure := pose.z
	var left := 1.0 - smoothstep(-0.35, 0.35, nx)
	var finger_side := 1.0 - smoothstep(-0.70, 0.10, nx)
	var fingers := _grip_finger_profile(hand_z) * finger_side * smoothstep(-0.9, -0.2, y) * pressure
	# Broad, rounded thumb pad, diagonally crossing the upper-right surface.
	var dx := (c.x - width * (0.54 - 0.06 * pose.w)) / hand
	var dz := c.z / hand + (1.20 - 0.10 * pose.w)
	var thumb_angle := lerpf(0.26, 0.61, maxf(pose.w, 0.0))
	var u := (cos(thumb_angle) * dx + sin(thumb_angle) * dz) / 1.02
	var v := (-sin(thumb_angle) * dx + cos(thumb_angle) * dz) / 0.48
	var thumb_bump := maxf(1.0 - u * u - v * v, 0.0)
	var thumb := thumb_bump * thumb_bump * smoothstep(-0.5, 0.55, y) * pressure
	var round_end := ends * (1.0 - 0.30 * nz * nz)
	var cap := 1.0 - pow(clampf(nx, -1.0, 1.0), 2.0)
	var fold := sin(hand_z * PI * 3.0 + y * 1.4) * 0.008 * waist * pressure
	var offset := Vector3(c.x * (-(0.406 + 0.112 * left) * waist * pose.x + 0.24 * round_end * pose.y) + c.x * fold + width * (0.12 * fingers - 0.16 * thumb),
		c.y * (-0.336 * waist * pose.x + 0.60 * round_end * (0.65 + 0.35 * cap) * pose.y) + c.y * fold - _model_size.y * (0.16 * fingers * smoothstep(-0.1, 0.65, y) + 0.46 * thumb),
		c.z * smoothstep(1.0, 1.5, absf(hand_z)) * (0.12 + 0.12 * (1.0 - nz * nz) + 0.12 * cap) * pose.y - hand * 0.07 * thumb)
	# Opposing end roll and palm shear produce a twisted grip, not a rigid rotation.
	var deformed := c + offset
	var roll := 0.24 * clampf(c.z / hand, -1.0, 1.0) * pose.w
	var rolled_x := cos(roll) * deformed.x - sin(roll) * deformed.y
	var rolled_y := sin(roll) * deformed.x + cos(roll) * deformed.y
	offset.x = rolled_x - c.x - width * 0.20 * z * pose.w
	offset.y = rolled_y - c.y
	offset.z += hand * 0.08 * nx * waist * pose.w
	offset.y += _model_radius * 1.8 * smoothstep(0.0, 1.0, grip_stage)
	return _grip_axis * (offset.x + _grip_shake) + Vector3.UP * offset.y + along * (offset.z + _grip_shake_vertical)

func _physics_process(delta: float) -> void:
	_step_grip(delta)
	if _rest_positions.is_empty() or (_interaction_mode < 0 and not _is_recovering):
		return
	# Spring the deformation field instead of independent seam vertices. Identical
	# positions receive identical displacement, even across disconnected UV seams.
	_grab_pressure = lerpf(_grab_pressure, 1.0 if _interaction_mode == MODE_STRETCH else 0.0, 1.0 - exp(-minf(delta, 0.1) * 16.0))
	var active := _interaction_mode >= 0
	var omega := 24.0 if active else 8.0 / maxf(recovery_time, 0.3)
	if not active and raised_rim_press and (not _stretch_recovering or _press_rebounding):
		omega /= 0.55
	var damping_ratio := 0.9 if active else clampf(1.0 - elasticity * 0.55 - initial_bounce * 0.2, 0.35, 1.0)
	# Three oscillation periods per recovery_time, with a decaying envelope.
	# Press recovery keeps its softer response; only released stretch rings.
	var pull_omega := TAU * 3.0 / maxf(recovery_time, 0.3) if not active and _stretch_recovering else omega
	var pull_damping := clampf(0.23 - elasticity * 0.09 - initial_bounce * 0.02, 0.12, 0.23) if not active and _stretch_recovering else damping_ratio
	if not active and _press_rebounding:
		pull_omega = TAU * 2.5 / maxf(recovery_time, 0.3)
		pull_damping = 0.25
	var follow := 1.0 - exp(-22.0 * minf(delta, 0.1))
	# Position follows the latest stable-surface hit within this frame. Only
	# pressure depth and departed material recover over time, never the pointer.
	_anchor_point = _anchor_target
	_trail_sample_elapsed += minf(delta, 0.1)
	for i in range(_trail_amounts.size() - 1, -1, -1):
		if _trail_retire_times[i] >= 0.0:
			_trail_retire_times[i] += minf(delta, 0.1)
			if _trail_retire_times[i] >= _trail_retire_duration():
				_remove_press_trail(i)
				continue
		var trail_recovery := maxf(recovery_time, 0.3) * (GATHER_TRAIL_RECOVERY_SCALE if raised_rim_press else 1.0)
		var decay := exp(-3.0 * minf(delta, 0.1) / trail_recovery)
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
	var effective_duration := press_duration * 0.5 if raised_rim_press else press_duration
	var progress := smoothstep(0.0, 1.0, clampf(_press_elapsed / maxf(effective_duration, 0.1), 0.0, 1.0))
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
		if _squash_amount < 0.00001 and _trail_peak() < 0.00001 and absf(_press_amount) + absf(_press_velocity) < 0.00001 and (_smooth_pull.length() + _pull_velocity.length()) / _model_radius < 0.0005:
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
		peak = maxf(peak, maxf(_trail_amounts[i], _trail_end_amounts[i]) * _trail_visibility(i))
	return peak

func _trail_retire_duration() -> float:
	return maxf(recovery_time, 0.3) * 0.35

func _trail_visibility(index: int) -> float:
	if _trail_retire_times[index] < 0.0:
		return 1.0
	return 1.0 - smoothstep(0.0, _trail_retire_duration(), _trail_retire_times[index])

func _remove_press_trail(index: int) -> void:
	_trail_points.remove_at(index)
	_trail_ends.remove_at(index)
	_trail_normals.remove_at(index)
	_trail_amounts.remove_at(index)
	_trail_end_amounts.remove_at(index)
	_trail_retire_times.remove_at(index)

func _add_press_trail(start: Vector3, end: Vector3, normal: Vector3, amount: float) -> void:
	if amount < 0.001:
		return
	var last := _trail_points.size() - 1
	# Extend straight runs instead of stamping separate round pits. Keep both
	# endpoint strengths so recovery varies continuously along the swept path.
	if _stroke_has_segment and last >= 0:
		var previous := (_trail_ends[last] - _trail_points[last]).normalized()
		var direction := (end - start).normalized()
		if previous.dot(direction) > 0.985 or _trail_sample_elapsed < maxf(recovery_time, 0.3) / 16.0:
			_trail_ends[last] = end
			_trail_end_amounts[last] = amount
			return
	# Bound admission frequency so retiring slots finish their fade before
	# reuse. Never delete a still-visible segment to accommodate new input.
	if _trail_points.size() >= MAX_TRAILS or (_trail_points.size() >= ACTIVE_TRAILS and _trail_sample_elapsed < maxf(recovery_time, 0.3) / 16.0):
		return
	_trail_sample_elapsed = 0.0
	var active_count := 0
	for time in _trail_retire_times:
		if time < 0.0:
			active_count += 1
	if active_count >= ACTIVE_TRAILS:
		for i in range(_trail_retire_times.size()):
			if _trail_retire_times[i] < 0.0:
				_trail_retire_times[i] = 0.0
				break
	_trail_retire_times.append(-1.0)
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
	return _dent_at(position, _trail_points[index].lerp(_trail_ends[index], weight), normal, lerpf(_trail_amounts[index], _trail_end_amounts[index], weight) * _trail_visibility(index))

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
	if not raised_rim_press:
		return normal * (rim - dent) * depth * clampf(amount, -0.1, 1.0) * depth_mask
	depth = minf(min_depth * _model_radius * 2.1, minf(_model_size.dot(normal.abs()) * 0.63, sigma * 2.1))
	# Pull a broad patch toward the contact. Its outer silhouette curls upward
	# instead of forming a raised ring around the finger.
	var bottom := _model_center.y - _model_size.y * 0.5
	var height := clampf((position.y - bottom) / maxf(_model_size.y, 0.000001), 0.0, 1.0)
	var base_mask := smoothstep(0.0, 0.65, height)
	var gather_radius := _model_radius * 0.85
	var broad := exp(-tangent.length_squared() / (2.0 * gather_radius * gather_radius))
	var centered := position - _model_center
	var nx := centered.x / maxf(_model_size.x * 0.5, 0.000001)
	var nz := centered.z / maxf(_model_size.z * 0.5, 0.000001)
	var edge := smoothstep(0.50, 0.95, sqrt(nx * nx + nz * nz))
	var pressure := clampf(amount, 0.0, 1.0)
	var inward := -tangent * 0.24 * broad * pressure * base_mask
	var curl := Vector3.UP * (depth / 1.4) * 0.70 * edge * broad * pressure * base_mask * absf(normal.y)
	return -normal * dent * depth * pressure * depth_mask * base_mask + inward + curl

func _grab_dent(position: Vector3, point: Vector3, normal: Vector3) -> Vector3:
	var relative := position - point
	var axial := relative.dot(normal)
	var tangent := relative - normal * axial
	var sigma := _model_radius * finger_width
	var mask := exp(-tangent.length_squared() / (2.0 * sigma * sigma) - pow(axial / (_model_radius * 0.32), 2.0))
	var depth := minf(sigma * 0.7, _model_size.dot(normal.abs()) * 0.2)
	return -normal * depth * mask * _grab_pressure

func _target_offset_for(rest_position: Vector3) -> Vector3:
	var relative := rest_position - _anchor_point
	var offset := _dent_at(rest_position, _anchor_point, _anchor_normal, _press_amount)
	# Rescale per evaluated vertex, not by the strongest contact elsewhere.
	# The largest local weight is always one, even at the fading trail's rim.
	# This preserves a linear fade without dividing by tiny absolute weights.
	var max_squared := offset.length_squared()
	var total_weight := 1.0 if max_squared > 0.0 else 0.0
	var weighted_offset := offset * total_weight
	for i in range(_trail_points.size()):
		var trail := _trail_offset_at(rest_position, i)
		var squared := trail.length_squared()
		if squared > max_squared:
			var ratio := max_squared / squared
			weighted_offset *= ratio * ratio
			total_weight *= ratio * ratio
			max_squared = squared
		if max_squared > 0.0:
			var ratio := squared / max_squared
			var weight := ratio * ratio
			weighted_offset += trail * weight
			total_weight += weight
	offset = weighted_offset / maxf(total_weight, 1.0)
	var grab_a := _grab_dent(rest_position, _grab_point_a, _grab_normal_a)
	var grab_b := _grab_dent(rest_position, _grab_point_b, _grab_normal_b)
	offset += grab_a if grab_a.length_squared() >= grab_b.length_squared() else grab_b
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
		var height_scale := thin
		if strain < 0.0:
			# A cosine-squared dome peaks in the middle and meets the rim with
			# zero slope. Both horizontal axes participate, regardless of pull axis.
			var nx := clampf(absf(centered.x) / maxf(_model_size.x * 0.5, _model_radius * 0.01), 0.0, 1.0)
			var nz := clampf(absf(centered.z) / maxf(_model_size.z * 0.5, _model_radius * 0.01), 0.0, 1.0)
			var dome := pow(cos(nx * PI * 0.5) * cos(nz * PI * 0.5), 2.0)
			height_scale = 1.0 + (thin - 1.0) * 1.75 * dome
		stretched.y = bottom - _model_center.y + (rest_position.y - bottom) * height_scale
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
	return offset * (1.0 - clampf(grip_amount * 1.5, 0.0, 1.0)) + _grip_offset(rest_position)

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
	_shader_material.set_shader_parameter("grip_amount", grip_amount)
	_shader_material.set_shader_parameter("grip_pose", _grip_pose_parameters(grip_amount))
	_shader_material.set_shader_parameter("grip_stage", grip_stage)
	_shader_material.set_shader_parameter("grip_shake", _grip_shake)
	_shader_material.set_shader_parameter("grip_shake_vertical", _grip_shake_vertical)
	_shader_material.set_shader_parameter("grip_axis", _grip_axis)
	_shader_material.set_shader_parameter("grip_hand_half_width", _grip_hand_half_width())
	_shader_material.set_shader_parameter("grip_width", _grip_width if _grip_width > 0.0 else _model_size.x * 0.5)
	_shader_material.set_shader_parameter("grip_extent", _grip_extent if _grip_extent > 0.0 else _model_size.z * 0.5)
	_shader_material.set_shader_parameter("grab_point_a", _grab_point_a)
	_shader_material.set_shader_parameter("grab_point_b", _grab_point_b)
	_shader_material.set_shader_parameter("grab_normal_a", _grab_normal_a)
	_shader_material.set_shader_parameter("grab_normal_b", _grab_normal_b)
	_shader_material.set_shader_parameter("grab_pressure", _grab_pressure)
	_shader_material.set_shader_parameter("model_center", _model_center)
	_shader_material.set_shader_parameter("model_size", _model_size)
	_shader_material.set_shader_parameter("model_radius", _model_radius)
	_shader_material.set_shader_parameter("anchor_point", _anchor_point)
	_shader_material.set_shader_parameter("anchor_normal", _anchor_normal)
	_shader_material.set_shader_parameter("raised_rim_press", raised_rim_press)
	_shader_material.set_shader_parameter("press_amount", _press_amount)
	_shader_material.set_shader_parameter("squash_amount", _squash_amount)
	_shader_material.set_shader_parameter("press_depth", min_depth)
	_shader_material.set_shader_parameter("finger_width", finger_width)
	_shader_material.set_shader_parameter("softness", softness)
	_shader_material.set_shader_parameter("squash_strength", squash_strength)
	var points := _trail_points.duplicate()
	var ends := _trail_ends.duplicate()
	var end_amounts := _trail_end_amounts.duplicate()
	for i in range(end_amounts.size()):
		end_amounts[i] *= _trail_visibility(i)
	ends.resize(MAX_TRAILS)
	end_amounts.resize(MAX_TRAILS)
	_shader_material.set_shader_parameter("trail_ends", ends)
	_shader_material.set_shader_parameter("trail_end_amounts", end_amounts)
	var normals := _trail_normals.duplicate()
	var amounts := _trail_amounts.duplicate()
	for i in range(amounts.size()):
		amounts[i] *= _trail_visibility(i)
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
	# These depend only on the spring state, not on vertices or normal samples.
	var signed_pull := _signed_stretch()
	var strain := signed_pull / (_model_radius * 2.0)
	var factor := 1.0 + strain if strain >= 0.0 else maxf(0.35, exp(strain))
	var neck := smoothstep(0.65, 2.6, signed_pull / _model_radius)
	var extent := maxf(_deformation_axis().abs().dot(_model_size * 0.5), _model_radius * 0.01)
	_shader_material.set_shader_parameter("stretch_shape", Vector4(factor, neck, extent, 1.0 / sqrt(factor)))
