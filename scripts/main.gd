extends Node3D

const MODEL_PATH := "res://glb/sfl.glb"
const MODEL_WIDTH := 2.0

const BlobScript = preload("res://scripts/blob_deformer.gd")

var _camera: Camera3D
var _blob: BlobDeformer
var _model_root: Node3D
var _dragging := false
var _stretching := false
var _active_button := MOUSE_BUTTON_LEFT
var _pointer_position := Vector2.ZERO
var _active_touch_id := -1
var _touches: Dictionary = {}
var _pinch_start_distance := 0.0
var _press_pointer_dirty := false
var _drag_plane := Plane()
var _drag_camera_transform := Transform3D.IDENTITY

# 相机控制
var _camera_target_dist: float = 4.5
var _camera_target_y: float = 2.8
var _camera_current_dist: float = 4.5
var _camera_current_y: float = 2.8
var _camera_azimuth: float = PI * 0.5
var _camera_polar: float = 0.85
var _is_rotating := false
var _last_mouse_pos := Vector2.ZERO

# 参数面板
var _param_panel: Control
var _param_button: Button
var _param_visible := false

# 镜头后退程度 (0-1.5, 默认1)
var _camera_retract: float = 1.0
var _base_camera_dist: float = 4.5
var _base_camera_y: float = 2.8
var _look_at_target := Vector3(0.0, 1.0, 0.0)
var _board: MeshInstance3D

# 字体
var _cjk_font: FontFile

func _ready() -> void:
	_load_font()
	_build_environment()
	_build_stage()
	_build_blob()
	_build_hud()

func _load_font() -> void:
	_cjk_font = load("res://fonts/NotoSansSC-Regular.ttf")
	if _cjk_font == null:
		_cjk_font = FontFile.new()
		_cjk_font.font_path = "res://fonts/NotoSansSC-Regular.ttf"

# Capture an already-owned gesture before GUI dispatch so releasing over the
# parameter panel cannot leave the model stuck. New gestures still respect UI.
func _input(event: InputEvent) -> void:
	if not _dragging and not _is_rotating and _active_touch_id < 0:
		return
	if event is InputEventMouseButton and _active_touch_id < 0:
		if not event.pressed and event.button_index == _active_button:
			_finish_gesture()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _active_touch_id < 0:
		if _dragging and _stretching != event.shift_pressed:
			_switch_mouse_mode(event.shift_pressed)
		_move_pointer(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_SHIFT and _active_touch_id < 0 and _dragging:
		_switch_mouse_mode(event.pressed)
	elif event is InputEventScreenTouch and _touches.has(event.index):
		if not event.pressed:
			_touches.erase(event.index)
			if _touches.is_empty():
				_finish_gesture()
			else:
				# Either finger can lift first. The survivor resumes pressing.
				_active_touch_id = int(_touches.keys()[0])
				if _dragging:
					_end_pointer()
				_is_rotating = false
				_begin_pointer(_touches[_active_touch_id], false, MOUSE_BUTTON_LEFT)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _touches.has(event.index):
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_move_pointer(event.position)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	# A second finger must start on the model and outside GUI controls.
	if event is InputEventScreenTouch and event.pressed and _touches.size() == 1 and _dragging:
		if not _raycast_blob(event.position).is_empty() and not _raycast_blob(_touches[_active_touch_id]).is_empty():
			_touches[event.index] = event.position
			_begin_pointer(_touches[_active_touch_id], true, MOUSE_BUTTON_LEFT)
			_pinch_start_distance = _touch_separation().length()
		return
	if _dragging or _is_rotating or _active_touch_id >= 0:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_active_button = event.button_index
			_begin_pointer(event.position, event.shift_pressed, event.button_index)
			if not _dragging:
				_is_rotating = true
				_last_mouse_pos = event.position
	elif event is InputEventScreenTouch and event.pressed:
		_active_touch_id = event.index
		_touches[event.index] = event.position
		_begin_pointer(event.position, false, MOUSE_BUTTON_LEFT)
		if not _dragging:
			_is_rotating = true
			_last_mouse_pos = event.position

func _switch_mouse_mode(stretch: bool) -> void:
	var point := _pointer_position
	_end_pointer()
	_begin_pointer(point, stretch, MOUSE_BUTTON_LEFT)

func _move_pointer(screen_position: Vector2) -> void:
	if _is_rotating:
		_rotate_model(screen_position - _last_mouse_pos)
		_last_mouse_pos = screen_position
		return
	_pointer_position = screen_position
	if not _dragging and _touches.size() == 1:
		_begin_pointer(screen_position, false, MOUSE_BUTTON_LEFT)
	if _dragging and not _stretching:
		_press_pointer_dirty = true

func _finish_gesture() -> void:
	if _dragging:
		_end_pointer()
	_is_rotating = false
	_active_touch_id = -1
	_touches.clear()

func _plane_point(screen_position: Vector2) -> Variant:
	var correction := _drag_camera_transform * _camera.global_transform.affine_inverse()
	var origin := correction * _camera.project_ray_origin(screen_position)
	var direction := correction.basis * _camera.project_ray_normal(screen_position)
	return _drag_plane.intersects_ray(origin, direction)

func _touch_separation() -> Vector3:
	var ids := _touches.keys()
	if ids.size() != 2:
		return Vector3.ZERO
	var a: Variant = _plane_point(_touches[ids[0]])
	var b: Variant = _plane_point(_touches[ids[1]])
	return b - a if a != null and b != null else Vector3.ZERO

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_finish_gesture()

func _physics_process(delta: float) -> void:
	_camera_current_dist = lerpf(_camera_current_dist, _camera_target_dist, minf(delta * 4.0, 1.0))
	_camera_current_y = lerpf(_camera_current_y, _camera_target_y, minf(delta * 4.0, 1.0))
	_update_camera_position()
	if not _dragging:
		return
	if not _stretching:
		if _press_pointer_dirty:
			_press_pointer_dirty = false
			# Rest-surface BVH avoids chasing the moving dent. Coalesce all OS
			# pointer events into at most one native query per physics frame.
			var hit := _raycast_blob(_pointer_position, true)
			if not hit.is_empty():
				_blob.update_press(hit.rest_point, hit.local_normal)
		return
	# Frozen projection prevents camera retreat from changing gesture distance.
	if _touches.size() == 2:
		var separation := _touch_separation()
		var extension := maxf(0.0, separation.length() - _pinch_start_distance)
		_blob.update_stretch_vector(separation.normalized() * extension)
	else:
		var point: Variant = _plane_point(_pointer_position)
		if point != null:
			_blob.update_interaction(point)
	var amount := _blob.get_stretch_amount()
	_camera_target_dist = _base_camera_dist * (1.0 + _camera_retract * amount * 0.5)
	_camera_target_y = _look_at_target.y + _camera_target_dist * sin(_camera_polar)

func _update_camera_position() -> void:
	if _camera == null:
		return
	var x := _camera_current_dist * cos(_camera_polar) * cos(_camera_azimuth)
	var z := _camera_current_dist * cos(_camera_polar) * sin(_camera_azimuth)
	var y := _camera_current_y
	_camera.position = Vector3(_look_at_target.x + x, y, _look_at_target.z + z)
	_camera.look_at(_look_at_target, Vector3.UP)

func _rotate_model(delta: Vector2) -> void:
	if _model_root == null:
		return
	_model_root.rotate_y(delta.x * 0.008)

func _begin_pointer(screen_position: Vector2, stretch: bool, button: int) -> void:
	var hit := _raycast_blob(screen_position)
	if hit.is_empty():
		return
	_dragging = true
	_stretching = stretch
	_active_button = button
	_pointer_position = screen_position
	_press_pointer_dirty = false
	_drag_camera_transform = _camera.global_transform
	_drag_plane = Plane(Vector3.UP, hit.position)
	_blob.begin_interaction(hit.position, stretch, hit.rest_point, hit.local_normal)
	
	if stretch:
		_camera_target_dist = _base_camera_dist * (1.0 + _camera_retract * 0.12)

func _end_pointer() -> void:
	_dragging = false
	_stretching = false
	_blob.end_interaction()
	_camera_target_dist = _base_camera_dist
	_camera_target_y = _base_camera_y

func _raycast_blob(screen_position: Vector2, stable_surface: bool = false) -> Dictionary:
	if _camera == null or _blob == null:
		return {}
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if stable_surface and _dragging:
		var correction := _drag_camera_transform * _camera.global_transform.affine_inverse()
		origin = correction * origin
		direction = correction.basis * direction
	return _blob.pick_ray(origin, direction, stable_surface)

func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#8b6f47")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#7a5c3a")
	environment.ambient_light_energy = 0.25
	world_environment.environment = environment
	add_child(world_environment)

	_camera = Camera3D.new()
	_camera.name = "MainCamera"
	_camera.position = Vector3(0.0, 2.8, 4.5)
	_camera.fov = 50.0
	_camera.current = true
	add_child(_camera)
	_camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)

	# 主光源 - 降低强度
	var key_light := DirectionalLight3D.new()
	key_light.name = "WarmKeyLight"
	key_light.rotation_degrees = Vector3(-55.0, -20.0, 0.0)
	key_light.light_color = Color("#ffe8c8")
	key_light.light_energy = 0.8
	key_light.shadow_enabled = true
	add_child(key_light)

	# 补光 - 减少阴影
	var fill_light := DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.rotation_degrees = Vector3(-30.0, 45.0, 0.0)
	fill_light.light_color = Color("#fff5e6")
	fill_light.light_energy = 0.4
	fill_light.shadow_enabled = false
	add_child(fill_light)

	# 前部柔光
	var front_light := DirectionalLight3D.new()
	front_light.name = "FrontLight"
	front_light.rotation_degrees = Vector3(-10.0, 0.0, 0.0)
	front_light.light_color = Color("#ffffff")
	front_light.light_energy = 0.3
	front_light.shadow_enabled = false
	add_child(front_light)

func _build_stage() -> void:
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(200.0, 200.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("#c9a87c")
	ground_material.roughness = 0.92
	ground.material_override = ground_material
	ground.position.y = -0.035
	add_child(ground)

	# 底座 - 占满竖屏宽度再超出20%
	_board = MeshInstance3D.new()
	var board_mesh := CylinderMesh.new()
	board_mesh.height = 0.26
	board_mesh.radial_segments = 64
	_board.mesh = board_mesh
	var board_material := StandardMaterial3D.new()
	board_material.albedo_color = Color("#d4a76a")
	board_material.roughness = 0.68
	_board.material_override = board_material
	_board.position.y = 0.12
	add_child(_board)
	_resize_board()

func _resize_board() -> void:
	if _board == null or _camera == null:
		return
	var board_y := _board.position.y
	var screen_width_world := _calculate_screen_width_at_y(board_y)
	var board_radius := screen_width_world * 0.6
	var board_mesh := _board.mesh as CylinderMesh
	if board_mesh != null:
		board_mesh.top_radius = board_radius
		board_mesh.bottom_radius = board_radius

func _calculate_screen_width_at_y(y: float) -> float:
	if _camera == null:
		return 3.0
	var dist := absf(_camera.position.y - y)
	var half_fov_rad := deg_to_rad(_camera.fov * 0.5)
	var aspect := _camera.get_viewport().get_visible_rect().size.x / _camera.get_viewport().get_visible_rect().size.y
	# 竖屏时水平视野更窄
	return dist * tan(half_fov_rad) * 2.0 * aspect

func _build_blob() -> void:
	var glb_scene := load(MODEL_PATH)
	if glb_scene != null:
		var instance = glb_scene.instantiate()
		add_child(instance)
		_model_root = instance
		var imported_mesh := _find_first_mesh_instance(instance)
		if imported_mesh != null:
			_bake_model_transform(imported_mesh)
		var original_bounds := _get_model_aabb(instance)
		var model_scale := MODEL_WIDTH / maxf(original_bounds.size.x, maxf(original_bounds.size.y, original_bounds.size.z))
		instance.scale = Vector3.ONE * model_scale
		
		# 计算模型 AABB 来确定正确位置
		var aabb := _get_model_aabb(instance)
		var model_bottom_y := aabb.position.y
		var board_top_y := 0.12 + 0.13  # 底座位置 + 半高
		instance.position = Vector3(0.0, board_top_y + MODEL_WIDTH * 0.0015 - model_bottom_y, 0.0)
		
		_auto_focus_camera(instance)
		_update_camera_position()
		_resize_board()
		
		var mesh_instance := _find_first_mesh_instance(instance)
		if mesh_instance != null:
			_blob = BlobScript.new() as BlobDeformer
			_blob.name = "SoftBlob"
			_blob.position = instance.position
			_blob.set_external_mesh(mesh_instance)
			add_child(_blob)
			return
	
	_blob = BlobScript.new() as BlobDeformer
	_blob.name = "SoftBlob"
	_blob.position = Vector3(0.0, 1.08, 0.0)
	add_child(_blob)

# GLB node transforms may rotate the author's Z axis into world Y. Bake these
# once so deformation, base constraints and picking all use the same upright axes.
func _bake_model_transform(mesh_instance: MeshInstance3D) -> void:
	var transform := mesh_instance.global_transform
	# Preserve the authored origin; only bake the imported coordinate transform.
	var normal_basis := transform.basis.inverse().transposed()
	var mesh := ArrayMesh.new()
	for surface in range(mesh_instance.mesh.get_surface_count()):
		var arrays := mesh_instance.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(vertices.size()):
			vertices[i] = transform * vertices[i]
			if not normals.is_empty():
				normals[i] = (normal_basis * normals[i]).normalized()
			if not tangents.is_empty():
				var tangent := (transform.basis * Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])).normalized()
				tangents[i * 4] = tangent.x
				tangents[i * 4 + 1] = tangent.y
				tangents[i * 4 + 2] = tangent.z
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TANGENT] = tangents
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface, mesh_instance.get_active_material(surface))
	mesh_instance.mesh = mesh
	mesh_instance.global_transform = Transform3D.IDENTITY

func _get_model_aabb(model_root: Node) -> AABB:
	var aabb := AABB()
	var first := true
	var nodes: Array[Node] = [model_root]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is MeshInstance3D:
			var mesh_aabb: AABB = node.global_transform * node.get_aabb()
			if first:
				aabb = mesh_aabb
				first = false
			else:
				aabb = aabb.merge(mesh_aabb)
		nodes.append_array(node.get_children())
	return aabb

func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var result := _find_first_mesh_instance(child)
		if result != null:
			return result
	return null

func _auto_focus_camera(model_root: Node) -> void:
	var aabb := AABB()
	var first := true
	
	var nodes: Array[Node] = [model_root]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is MeshInstance3D:
			var mesh_aabb: AABB = node.global_transform * node.get_aabb()
			if first:
				aabb = mesh_aabb
				first = false
			else:
				aabb = aabb.merge(mesh_aabb)
		nodes.append_array(node.get_children())
	
	if first:
		return
	
	var center := aabb.get_center()
	var size := aabb.size
	
	var fov_rad := deg_to_rad(_camera.fov)
	var tan_half_fov := tan(fov_rad * 0.5)
	var aspect := _camera.get_viewport().get_visible_rect().size.x / _camera.get_viewport().get_visible_rect().size.y
	
	# 竖屏时水平视野更窄，需要根据宽度计算距离
	var dist_by_height := (maxf(size.y, size.z) * 0.8) / tan_half_fov
	var dist_by_width := (maxf(size.x, size.z) * 0.8) / (tan_half_fov * aspect)
	var dist := maxf(dist_by_height, dist_by_width)
	dist = maxf(dist, 0.5)
	dist = minf(dist, 30.0)
	
	_camera_target_dist = dist
	_camera_current_dist = dist
	_camera_target_y = center.y + dist * sin(_camera_polar)
	_camera_current_y = _camera_target_y
	_base_camera_dist = dist
	_base_camera_y = _camera_target_y
	_look_at_target = center

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	_param_button = Button.new()
	_param_button.text = "参数"
	_param_button.position = Vector2(24.0, 24.0)
	_param_button.custom_minimum_size = Vector2(80.0, 40.0)
	_param_button.add_theme_font_size_override("font_size", 16)
	_param_button.add_theme_font_override("font", _cjk_font)
	_param_button.pressed.connect(_toggle_param_panel)
	_param_button.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_param_button)

	_param_panel = PanelContainer.new()
	_param_panel.position = Vector2(24.0, 72.0)
	_param_panel.custom_minimum_size = Vector2(330.0, 0.0)
	_param_panel.visible = false
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.24, 0.16, 0.1, 0.84)
	panel_style.set_corner_radius_all(14)
	panel_style.content_margin_left = 18.0
	panel_style.content_margin_right = 18.0
	panel_style.content_margin_top = 14.0
	panel_style.content_margin_bottom = 14.0
	_param_panel.add_theme_stylebox_override("panel", panel_style)
	root.add_child(_param_panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	_param_panel.add_child(content)
	
	var title_label := _make_label("捏捏实验室", 24, Color("#fff2dc"))
	content.add_child(title_label)
	
	var desc_label := _make_label("软胶形变 · Web 原型", 14, Color("#e6c8a1"))
	content.add_child(desc_label)
	
	var help_label := _make_label("左键拖动：按压 / 推揉\nShift + 左键拖动：拉伸\n拖动空白处：旋转模型\n触屏：单指按压，双指分开拉伸", 14, Color("#fff7eb"))
	content.add_child(help_label)

	# 回弹时长
	var recovery_row := HBoxContainer.new()
	recovery_row.add_theme_constant_override("separation", 10)
	content.add_child(recovery_row)
	recovery_row.add_child(_make_label("回弹时长", 14, Color("#fff2dc")))
	var recovery_slider := HSlider.new()
	recovery_slider.min_value = 0.3
	recovery_slider.max_value = 4.0
	recovery_slider.step = 0.1
	recovery_slider.value = 1.6
	recovery_slider.custom_minimum_size = Vector2(190.0, 24.0)
	recovery_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recovery_slider.value_changed.connect(_on_recovery_changed)
	recovery_row.add_child(recovery_slider)

	# 柔软度
	var softness_row := HBoxContainer.new()
	softness_row.add_theme_constant_override("separation", 10)
	content.add_child(softness_row)
	softness_row.add_child(_make_label("柔软度", 14, Color("#fff2dc")))
	var softness_slider := HSlider.new()
	softness_slider.min_value = 0.2
	softness_slider.max_value = 1.6
	softness_slider.step = 0.1
	softness_slider.value = 0.9
	softness_slider.custom_minimum_size = Vector2(190.0, 24.0)
	softness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	softness_slider.value_changed.connect(_on_softness_changed)
	softness_row.add_child(softness_slider)

	# 按压深度
	var depth_row := HBoxContainer.new()
	depth_row.add_theme_constant_override("separation", 10)
	content.add_child(depth_row)
	depth_row.add_child(_make_label("按压深度", 14, Color("#fff2dc")))
	var depth_slider := HSlider.new()
	depth_slider.min_value = 0.1
	depth_slider.max_value = 0.5
	depth_slider.step = 0.01
	depth_slider.value = 0.32
	depth_slider.custom_minimum_size = Vector2(190.0, 24.0)
	depth_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depth_slider.value_changed.connect(_on_depth_changed)
	depth_row.add_child(depth_slider)

	# 手指宽度
	var finger_row := HBoxContainer.new()
	finger_row.add_theme_constant_override("separation", 10)
	content.add_child(finger_row)
	finger_row.add_child(_make_label("手指宽度", 14, Color("#fff2dc")))
	var finger_slider := HSlider.new()
	finger_slider.min_value = 0.072
	finger_slider.max_value = 0.216
	finger_slider.step = 0.001
	finger_slider.value = _blob.finger_width
	finger_slider.custom_minimum_size = Vector2(190.0, 24.0)
	finger_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	finger_slider.value_changed.connect(_on_finger_changed)
	finger_row.add_child(finger_slider)

	# 弹性抖动
	var elastic_row := HBoxContainer.new()
	elastic_row.add_theme_constant_override("separation", 10)
	content.add_child(elastic_row)
	elastic_row.add_child(_make_label("弹性抖动", 14, Color("#fff2dc")))
	var elastic_slider := HSlider.new()
	elastic_slider.min_value = 0.0
	elastic_slider.max_value = 1.0
	elastic_slider.step = 0.05
	elastic_slider.value = 0.55
	elastic_slider.custom_minimum_size = Vector2(190.0, 24.0)
	elastic_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	elastic_slider.value_changed.connect(_on_elastic_changed)
	elastic_row.add_child(elastic_slider)

	# 初始回弹
	var bounce_row := HBoxContainer.new()
	bounce_row.add_theme_constant_override("separation", 10)
	content.add_child(bounce_row)
	bounce_row.add_child(_make_label("初始回弹", 14, Color("#fff2dc")))
	var bounce_slider := HSlider.new()
	bounce_slider.min_value = 0.0
	bounce_slider.max_value = 0.6
	bounce_slider.step = 0.05
	bounce_slider.value = 0.24
	bounce_slider.custom_minimum_size = Vector2(190.0, 24.0)
	bounce_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bounce_slider.value_changed.connect(_on_bounce_changed)
	bounce_row.add_child(bounce_slider)

	# 拉伸灵敏度
	var sensitivity_row := HBoxContainer.new()
	sensitivity_row.add_theme_constant_override("separation", 10)
	content.add_child(sensitivity_row)
	sensitivity_row.add_child(_make_label("拉伸灵敏度", 14, Color("#fff2dc")))
	var sensitivity_slider := HSlider.new()
	sensitivity_slider.min_value = 0.3
	sensitivity_slider.max_value = 2.5
	sensitivity_slider.step = 0.1
	sensitivity_slider.value = 1.3
	sensitivity_slider.custom_minimum_size = Vector2(190.0, 24.0)
	sensitivity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	sensitivity_row.add_child(sensitivity_slider)

	# 最大拉伸
	var max_stretch_row := HBoxContainer.new()
	max_stretch_row.add_theme_constant_override("separation", 10)
	content.add_child(max_stretch_row)
	max_stretch_row.add_child(_make_label("最大拉伸", 14, Color("#fff2dc")))
	var max_stretch_slider := HSlider.new()
	max_stretch_slider.min_value = 0.8
	max_stretch_slider.max_value = 3.6
	max_stretch_slider.step = 0.1
	max_stretch_slider.value = 2.4
	max_stretch_slider.custom_minimum_size = Vector2(190.0, 24.0)
	max_stretch_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_stretch_slider.value_changed.connect(_on_max_stretch_changed)
	max_stretch_row.add_child(max_stretch_slider)

	# 镜头后退
	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override("separation", 10)
	content.add_child(camera_row)
	camera_row.add_child(_make_label("镜头后退", 14, Color("#fff2dc")))
	var camera_slider := HSlider.new()
	camera_slider.min_value = 0.0
	camera_slider.max_value = 1.5
	camera_slider.step = 0.1
	camera_slider.value = 1.0
	camera_slider.custom_minimum_size = Vector2(190.0, 24.0)
	camera_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camera_slider.value_changed.connect(_on_camera_changed)
	camera_row.add_child(camera_slider)

	# 回弹震动
	var vibration_row := HBoxContainer.new()
	vibration_row.add_theme_constant_override("separation", 10)
	content.add_child(vibration_row)
	vibration_row.add_child(_make_label("回弹震动", 14, Color("#fff2dc")))
	var vibration_slider := HSlider.new()
	vibration_slider.min_value = 0.0
	vibration_slider.max_value = 0.5
	vibration_slider.step = 0.05
	vibration_slider.value = 0.2
	vibration_slider.custom_minimum_size = Vector2(190.0, 24.0)
	vibration_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vibration_slider.value_changed.connect(_on_vibration_changed)
	vibration_row.add_child(vibration_slider)

	var footer := Label.new()
	footer.text = "单指 / 左键按压 · 双指 / Shift 拉伸"
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 0.0
	footer.offset_top = -42.0
	footer.offset_right = 0.0
	footer.offset_bottom = -16.0
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 13)
	footer.add_theme_color_override("font_color", Color("#735d46"))
	footer.add_theme_font_override("font", _cjk_font)
	root.add_child(footer)

func _toggle_param_panel() -> void:
	_param_visible = not _param_visible
	_param_panel.visible = _param_visible

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_override("font", _cjk_font)
	return label

func _on_recovery_changed(value: float) -> void:
	if _blob != null:
		_blob.recovery_time = value

func _on_softness_changed(value: float) -> void:
	if _blob != null:
		_blob.softness = value

func _on_depth_changed(value: float) -> void:
	if _blob != null:
		_blob.min_depth = value

func _on_finger_changed(value: float) -> void:
	if _blob != null:
		_blob.finger_width = value

func _on_elastic_changed(value: float) -> void:
	if _blob != null:
		_blob.elasticity = value

func _on_bounce_changed(value: float) -> void:
	if _blob != null:
		_blob.initial_bounce = value

func _on_sensitivity_changed(value: float) -> void:
	if _blob != null:
		_blob.stretch_sensitivity = value

func _on_max_stretch_changed(value: float) -> void:
	if _blob != null:
		_blob.max_stretch = value

func _on_camera_changed(value: float) -> void:
	_camera_retract = value

func _on_vibration_changed(value: float) -> void:
	if _blob != null:
		_blob.rebound_vibration = value
