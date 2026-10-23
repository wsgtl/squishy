extends Node3D

const BlobScript = preload("res://scripts/blob_deformer.gd")

var _camera: Camera3D
var _blob: Node3D
var _dragging := false
var _stretching := false
var _rotating := false
var _active_button := MOUSE_BUTTON_LEFT
var _pointer_position := Vector2.ZERO
var _last_rotation_x := 0.0
var _active_touch_id := -1
var _touch_origin := Vector2.ZERO
var _touch_anchor := Vector3.ZERO
var _last_screen_pos := Vector2.ZERO
var _base_camera_dist := 0.0
var _base_camera_y := 0.0
var _camera_target_dist := 0.0
var _camera_target_y := 0.0
var _param_panel: PanelContainer
var _cjk_font: SystemFont


func _ready() -> void:
	_build_environment()
	_build_stage()
	_build_blob_from_glb()
	_build_hud()
	_auto_focus_camera.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_begin_pointer(event.position, event.button_index == MOUSE_BUTTON_RIGHT or Input.is_key_pressed(KEY_SHIFT), event.button_index)
			elif (_dragging or _rotating) and event.button_index == _active_button:
				_end_pointer()
	elif event is InputEventMouseMotion and (_dragging or _rotating):
		_pointer_position = event.position
	elif event is InputEventScreenTouch:
		if event.pressed and _active_touch_id < 0:
			_active_touch_id = event.index
			_touch_origin = event.position
			_begin_pointer(event.position, false, MOUSE_BUTTON_LEFT)
			var hit := _raycast_blob(event.position)
			if not hit.is_empty():
				_touch_anchor = hit.position
		elif not event.pressed and event.index == _active_touch_id:
			_end_pointer()
			_active_touch_id = -1
	elif event is InputEventScreenDrag and event.index == _active_touch_id:
		_pointer_position = event.position
		if not _stretching and not _rotating and event.position.distance_to(_touch_origin) > 22.0:
			_stretching = true
			if _blob is BlobDeformer:
				(_blob as BlobDeformer).begin_interaction(_touch_anchor, true)


func _physics_process(delta: float) -> void:
	if _rotating:
		var delta_x: float = _pointer_position.x - _last_rotation_x
		_last_rotation_x = _pointer_position.x
		if _blob != null:
			_blob.rotate_y(-delta_x * 0.01)
		_update_camera_follow(delta)
		return
	if not _dragging:
		_update_camera_follow(delta)
		return
	if not (_blob is BlobDeformer):
		return
	if _stretching:
		var screen_delta := _pointer_position - _last_screen_pos
		_last_screen_pos = _pointer_position
		var bd: BlobDeformer = _blob as BlobDeformer
		bd.update_stretch_by_screen(screen_delta, _camera)
		var stretch_ratio := bd._pull_offset.length() / maxf(bd._model_radius, 0.001)
		var zoom_extra := bd.camera_zoom_back * stretch_ratio * 0.15
		_camera_target_dist = _base_camera_dist * (1.0 + zoom_extra)
		_camera_target_y = _base_camera_y * (1.0 + zoom_extra * 0.3)
	else:
		var hit := _raycast_blob(_pointer_position)
		if not hit.is_empty():
			(_blob as BlobDeformer).update_interaction(hit.position)
		_camera_target_dist = _base_camera_dist
		_camera_target_y = _base_camera_y
	_update_camera_follow(delta)


func _update_camera_follow(delta: float) -> void:
	if _camera == null or _blob == null:
		return
	var blob_pos: Vector3 = _blob.position
	var cur_dist := _camera.position.z - blob_pos.z
	var cur_y := _camera.position.y
	var new_dist := lerpf(cur_dist, _camera_target_dist, clampf(delta * 4.0, 0.0, 1.0))
	var new_y := lerpf(cur_y, _camera_target_y, clampf(delta * 4.0, 0.0, 1.0))
	_camera.position = Vector3(blob_pos.x, new_y, blob_pos.z + new_dist)
	_camera.look_at(blob_pos + Vector3(0.0, 0.35, 0.0), Vector3.UP)


func _begin_pointer(screen_position: Vector2, stretch: bool, button: int) -> void:
	var hit := _raycast_blob(screen_position)
	if hit.is_empty():
		_rotating = true
		_active_button = button
		_pointer_position = screen_position
		_last_rotation_x = screen_position.x
		return
	_dragging = true
	_stretching = stretch
	_active_button = button
	_pointer_position = screen_position
	_last_screen_pos = screen_position
	if _blob is BlobDeformer:
		(_blob as BlobDeformer).begin_interaction(hit.position, stretch)


func _end_pointer() -> void:
	_dragging = false
	_stretching = false
	_rotating = false
	_camera_target_dist = _base_camera_dist
	_camera_target_y = _base_camera_y
	if _blob is BlobDeformer:
		var bd: BlobDeformer = _blob as BlobDeformer
		bd.end_interaction()
		var vib := bd.vibration_strength
		if vib > 0.01:
			Input.vibrate_handheld(vib * 0.4)


func _raycast_blob(screen_position: Vector2) -> Dictionary:
	if _camera == null or _blob == null:
		return {}
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0)
	query.collision_mask = 1
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	return hit


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#d4b896")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#f5e6d3")
	environment.ambient_light_energy = 0.15
	world_environment.environment = environment
	add_child(world_environment)

	_camera = Camera3D.new()
	_camera.name = "MainCamera"
	_camera.position = Vector3(0.0, 1.8, 3.5)
	_camera.fov = 45.0
	_camera.near = 0.05
	_camera.far = 100.0
	_camera.current = true
	add_child(_camera)
	_camera.look_at(Vector3(0.0, 0.35, 0.0), Vector3.UP)

	var key_light := DirectionalLight3D.new()
	key_light.name = "WarmKeyLight"
	key_light.rotation_degrees = Vector3(-65.0, -25.0, 0.0)
	key_light.light_color = Color("#fff5e6")
	key_light.light_energy = 0.35
	key_light.shadow_enabled = true
	key_light.shadow_bias = 0.05
	add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.name = "FrontFillLight"
	fill_light.rotation_degrees = Vector3(-30.0, 10.0, 0.0)
	fill_light.light_color = Color("#ffffff")
	fill_light.light_energy = 0.15
	fill_light.shadow_enabled = false
	add_child(fill_light)

	var top_light := DirectionalLight3D.new()
	top_light.name = "TopLight"
	top_light.rotation_degrees = Vector3(-85.0, 0.0, 0.0)
	top_light.light_color = Color("#fffaf0")
	top_light.light_energy = 0.08
	top_light.shadow_enabled = false
	add_child(top_light)


func _build_stage() -> void:
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(50.0, 50.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("#d4b896")
	ground_material.roughness = 0.92
	ground.material_override = ground_material
	ground.position.y = -0.65
	add_child(ground)

	var board := MeshInstance3D.new()
	var board_mesh := CylinderMesh.new()
	board_mesh.top_radius = 1.6
	board_mesh.bottom_radius = 1.6
	board_mesh.height = 0.12
	board_mesh.radial_segments = 64
	board.mesh = board_mesh
	var board_material := StandardMaterial3D.new()
	board_material.albedo_color = Color("#e8d4b8")
	board_material.roughness = 0.75
	board.material_override = board_material
	board.position.y = -0.57
	add_child(board)


func _build_blob_from_glb() -> void:
	var glb_scene = load("res://glb/ss.glb")
	if glb_scene == null:
		push_error("无法加载 GLB 模型: res://glb/ss.glb")
		return
	_blob = glb_scene.instantiate() as Node3D
	_blob.name = "SoftBlobGLB"
	_blob.scale = Vector3(14.0, 14.0, 14.0)
	_blob.position = Vector3(0.0, -0.35, 0.0)
	_reduce_material_emission(_blob)

	var mesh_instance := _find_first_mesh_instance(_blob)
	if mesh_instance != null:
		var blob_script := load("res://scripts/blob_deformer.gd")
		_blob.set_script(blob_script)
		(_blob as BlobDeformer).set_external_mesh(mesh_instance)
	add_child(_blob)


func _auto_focus_camera() -> void:
	if _blob == null or _camera == null:
		return
	await get_tree().process_frame
	var aabb: AABB = _get_model_aabb(_blob)
	if aabb.size == Vector3.ZERO:
		push_error("无法计算模型 AABB，使用默认相机位置")
		_camera.position = Vector3(0.0, 2.0, 4.0)
		_camera.look_at(Vector3.ZERO, Vector3.UP)
		return
	var model_center: Vector3 = aabb.position + aabb.size * 0.5
	var board_radius := 1.6
	var board_width := board_radius * 2.0
	var width_fraction := 1.5
	var fov_rad: float = deg_to_rad(_camera.fov)
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var aspect_ratio: float = viewport_size.x / viewport_size.y
	var tan_hfov_half := tan(fov_rad * 0.5) * aspect_ratio
	var required_depth := (board_width * 0.5) / (tan_hfov_half * width_fraction)
	var height_ratio := 0.7
	var sqrt_term := sqrt(height_ratio * height_ratio + 1.0)
	var board_y := -0.57
	var distance_needed := required_depth / sqrt_term - (model_center.y - board_y) / height_ratio
	distance_needed = maxf(distance_needed, 1.5)
	distance_needed = clampf(distance_needed, 1.5, 12.0)
	var zoom_factor := 1.0
	if _blob is BlobDeformer:
		zoom_factor = 1.0 + (_blob as BlobDeformer).camera_zoom_back * 0.5
	distance_needed *= zoom_factor
	var camera_y_offset: float = distance_needed * height_ratio
	var camera_y: float = model_center.y + camera_y_offset
	_camera.position = Vector3(model_center.x, camera_y, model_center.z + distance_needed)
	_camera.look_at(model_center, Vector3.UP)
	_base_camera_dist = distance_needed
	_base_camera_y = camera_y
	_camera_target_dist = distance_needed
	_camera_target_y = camera_y
	print("自动对焦完成: 中心=", model_center, " 模型尺寸=", aabb.size, " 距离=", distance_needed)


func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var result := _find_first_mesh_instance(child)
		if result != null:
			return result
	return null


func _reduce_material_emission(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.material_override is StandardMaterial3D:
			var mat: StandardMaterial3D = mi.material_override
			mat.emission_energy = 0.0
		if mi.mesh != null:
			for i in range(mi.mesh.get_surface_count()):
				var surf_mat: Material = mi.mesh.surface_get_material(i)
				if surf_mat is StandardMaterial3D:
					(surf_mat as StandardMaterial3D).emission_energy = 0.0
	for child in node.get_children():
		_reduce_material_emission(child)


func _get_model_aabb(node: Node3D) -> AABB:
	var combined_aabb: AABB
	var has_valid_aabb: bool = false
	if node is MeshInstance3D:
		var mesh_instance: MeshInstance3D = node as MeshInstance3D
		if mesh_instance.mesh != null:
			var mesh_aabb: AABB = mesh_instance.mesh.get_aabb()
			var global_xform: Transform3D = mesh_instance.global_transform
			var transformed_aabb: AABB = global_xform * mesh_aabb
			if not has_valid_aabb:
				combined_aabb = transformed_aabb
				has_valid_aabb = true
			else:
				combined_aabb = combined_aabb.merge(transformed_aabb)
	for child in node.get_children():
		if child is Node3D:
			var child_aabb: AABB = _get_model_aabb(child as Node3D)
			if child_aabb.size != Vector3.ZERO:
				if not has_valid_aabb:
					combined_aabb = child_aabb
					has_valid_aabb = true
				else:
					combined_aabb = combined_aabb.merge(child_aabb)
	return combined_aabb


func _build_hud() -> void:
	_cjk_font = SystemFont.new()
	_cjk_font.font_names = PackedStringArray([
		"PingFang SC", "Heiti SC", "Microsoft YaHei",
		"SimHei", "Noto Sans CJK SC", "WenQuanYi Hei",
		"sans-serif"
	])

	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	layer.add_child(root)

	var toggle_button := Button.new()
	toggle_button.text = "参数"
	toggle_button.position = Vector2(24.0, 24.0)
	toggle_button.custom_minimum_size = Vector2(90.0, 40.0)
	toggle_button.add_theme_font_override("font", _cjk_font)
	toggle_button.add_theme_font_size_override("font_size", 15)
	toggle_button.pressed.connect(_on_toggle_params)
	root.add_child(toggle_button)

	_param_panel = PanelContainer.new()
	_param_panel.position = Vector2(24.0, 72.0)
	_param_panel.custom_minimum_size = Vector2(340.0, 0.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.24, 0.16, 0.1, 0.84)
	panel_style.set_corner_radius_all(14)
	panel_style.content_margin_left = 18.0
	panel_style.content_margin_right = 18.0
	panel_style.content_margin_top = 14.0
	panel_style.content_margin_bottom = 14.0
	_param_panel.add_theme_stylebox_override("panel", panel_style)
	_param_panel.visible = false
	root.add_child(_param_panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	_param_panel.add_child(content)
	content.add_child(_make_label("捏捏实验室", 22, Color("#fff2dc")))
	content.add_child(_make_label("按住模型：按压 / 推揉\nShift + 拖动或右键拖动：拉伸\n拖动空白处：左右旋转", 13, Color("#fff7eb")))

	content.add_child(_make_param_slider("回弹时长", "rebound_duration", 0.3, 4.0, 0.1, 1.6))
	content.add_child(_make_param_slider("柔软度", "softness", 0.2, 1.6, 0.05, 0.9))
	content.add_child(_make_param_slider("下限深度", "press_depth_limit", 0.1, 0.5, 0.01, 0.32))
	content.add_child(_make_param_slider("手指宽度", "finger_width", 0.12, 0.36, 0.01, 0.23))
	content.add_child(_make_param_slider("弹性抖动", "jelly_amount", 0.0, 1.0, 0.05, 0.55))
	content.add_child(_make_param_slider("初始回弹", "springback_amount", 0.0, 0.6, 0.02, 0.24))
	content.add_child(_make_param_slider("拉伸灵敏度", "stretch_sensitivity", 0.3, 2.5, 0.1, 1.3))
	content.add_child(_make_param_slider("最大拉伸", "max_stretch", 0.8, 3.6, 0.1, 2.4))
	content.add_child(_make_param_slider("镜头后退", "camera_zoom_back", 0.0, 1.5, 0.1, 1.0))
	content.add_child(_make_param_slider("回弹震动", "vibration_strength", 0.0, 0.5, 0.05, 0.2))

	var reset_button := Button.new()
	reset_button.text = "恢复形状"
	reset_button.custom_minimum_size = Vector2(280.0, 38.0)
	reset_button.add_theme_font_override("font", _cjk_font)
	reset_button.add_theme_font_size_override("font_size", 15)
	reset_button.pressed.connect(_on_reset_pressed)
	content.add_child(reset_button)

	var footer := Label.new()
	footer.text = "软体原型 · 顶点弹簧 · 松手后自动回弹"
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 0.0
	footer.offset_top = -42.0
	footer.offset_right = 0.0
	footer.offset_bottom = -16.0
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_override("font", _cjk_font)
	footer.add_theme_font_size_override("font_size", 13)
	footer.add_theme_color_override("font_color", Color("#735d46"))
	root.add_child(footer)


func _on_toggle_params() -> void:
	if _param_panel != null:
		_param_panel.visible = not _param_panel.visible


func _make_param_slider(label_text: String, param_name: String, min_val: float, max_val: float, step: float, default_val: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var label := _make_label(label_text, 13, Color("#e6c8a1"))
	box.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = default_val
	slider.custom_minimum_size = Vector2(280.0, 22.0)
	slider.value_changed.connect(func(v): _on_param_changed(param_name, v))
	box.add_child(slider)
	return box


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _cjk_font != null:
		label.add_theme_font_override("font", _cjk_font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _on_param_changed(param_name: String, value: float) -> void:
	if _blob != null and _blob is BlobDeformer:
		(_blob as BlobDeformer).set_param(param_name, value)
		if param_name == "camera_zoom_back":
			_auto_focus_camera.call_deferred()


func _on_reset_pressed() -> void:
	if _blob != null and _blob is BlobDeformer:
		_dragging = false
		(_blob as BlobDeformer).reset_deformation()