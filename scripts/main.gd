extends Node3D

const MODEL_PATH := "res://glb/sfl.glb"
const MODEL_WIDTH := 2.0
const SceneCapture = preload("res://scripts/scene_capture.gd")
var _scene_capture: CanvasLayer
const FeelPresets = preload("res://scripts/feel_presets.gd")
const HomeScreen = preload("res://scripts/home_screen.gd")
var _home_active := true
var _selected_feel := 0
var _hud_root: Control
var _home: Control
var _feel_sliders: Dictionary = {}

const BlobScript = preload("res://scripts/blob_deformer.gd")

const DoodleCanvas = preload("res://scripts/doodle_canvas.gd")
var _doodle := DoodleCanvas.new()
var _doodle_enabled := false
var _sticker_enabled := false
var _sticker_width := 220
var _sticker_image: Image
var _sticker_cancel_image: Image
var _sticker_base: Image
var _sticker_undo: Image
var _sticker_uv := Vector2.ZERO
var _sticker_angle := 0.0
var _sticker_pending := false
var _sticker_preview_dirty := false
var _sticker_edit_tools: VBoxContainer
var _sticker_last: Dictionary = {}
var _sticker_actions: Dictionary = {}
var _drawing := false
var _drawing_touch := -1
var _drawing_last := Vector2.ZERO
var _doodle_panel: Control
var _doodle_button: Button
var _doodle_zoom := 1.0
var _doodle_ui_dimmed := false
var _doodle_elevation := 1.05
var _doodle_angle_mode := false
const CAMERA_RETURN_DURATION := 0.55
const PAGE_CAMERA_DURATION := 0.3
var _page_camera_elapsed := PAGE_CAMERA_DURATION
var _page_camera_start_dist := 4.5
var _page_camera_start_y := 2.8
var _page_camera_start_transform := Transform3D.IDENTITY
var _page_restoring_pose := false
var _page_model_start := Quaternion.IDENTITY
var _default_model_rotation := Quaternion.IDENTITY
var _camera_returning := false
var _camera_return_elapsed := 0.0

var _twist_button: Button
var _grip_button: Button

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
var _camera_polar: float = 1.05
var _is_rotating := false
var _last_mouse_pos := Vector2.ZERO

# 参数面板
var _param_panel: Control
var _param_button: Button
var _param_visible := false

# 镜头后退程度 (0-1.5, 默认1)
var _camera_retract: float = 1.0
const GAME_VIEW_SCALE := 1.2
var _home_camera_dist: float = 4.5
var _base_camera_dist: float = 4.5
var _base_camera_y: float = 2.8
var _look_at_target := Vector3(0.0, 1.0, 0.0)
var _backdrop_material: ShaderMaterial
var _board: Node3D
var _board_source_size := Vector3(1.349289, 0.075418, 1.349289)

# 字体
var _cjk_font: FontFile

func _ready() -> void:
	_load_font()
	_build_environment()
	_build_stage()
	_build_blob()
	_default_model_rotation = _model_root.quaternion
	_build_hud()
	_blob.set_doodle_texture(_doodle.texture)
	var layer := CanvasLayer.new()
	add_child(layer)
	_home = HomeScreen.new()
	layer.add_child(_home)
	_home.setup(self, _cjk_font)
	_hud_root.hide()
	LocaleManager.language_changed.connect(_refresh_language)

func _refresh_language() -> void:
	_load_font()
	LocaleManager.refresh_controls(self, _cjk_font)
	_home.refresh_language()
	var size_slider := find_child("DoodleSizeSlider", true, false) as VSlider
	var size_label := find_child("DoodleSizeLabel", true, false) as Label
	size_label.text = tr("贴纸 %d") % int(size_slider.value) if _sticker_enabled else (tr("擦宽 %d") if _doodle.erasing else tr("笔宽 %d")) % int(size_slider.value)
	var help := find_child("StickerHelpLabel", true, false) as Label
	help.text = tr("旋转 %d° · 拖动位置 · 左侧调大小") % int(rad_to_deg(_sticker_angle))
	_scene_capture.dialog.filters = PackedStringArray([tr("*.jpg, *.jpeg ; JPEG 图片")])
	for platform in ["X", "LINE"]:
		var share := _scene_capture.find_child(platform + "ShareButton", true, false) as Button
		share.tooltip_text = tr("在 %s 分享文字和游戏链接") % platform

func _apply_feel(index: int) -> void:
	_selected_feel = clampi(index, 0, FeelPresets.TYPES.size() - 1)
	_finish_gesture()
	_blob.cancel_grip()
	_blob.reset_deformation()
	var parameters := FeelPresets.parameters(_selected_feel)
	for key in parameters:
		_blob.set(key, parameters[key])
		if _feel_sliders.has(key):
			(_feel_sliders[key] as Range).set_value_no_signal(parameters[key])
	_blob._sync_gpu()

func _return_home() -> void:
	var current_view := _camera.transform
	if _scene_capture != null and _scene_capture.is_open():
		_scene_capture.close()
	if _doodle_enabled:
		_set_doodle_enabled(false)
	_close_param_panel()
	_finish_gesture()
	_blob.cancel_grip()
	_blob.reset_deformation()
	_home_active = true
	_set_page_camera(true)
	# Capture the visible view before cancelling lifted/doodle camera states.
	_page_camera_start_transform = current_view
	_update_camera_position()
	_hud_root.hide()
	_home.show()

func _start_game() -> void:
	_finish_gesture()
	_blob.reset_deformation()
	_home_active = false
	_set_page_camera(true)
	_home.hide()
	_hud_root.show()

func _set_page_camera(animated := false) -> void:
	_page_camera_start_transform = _camera.transform
	_page_restoring_pose = animated and (_home_active or _page_restoring_pose)
	_page_model_start = _model_root.quaternion
	# Always derive from the original home distance; repeated page changes do
	# not compound zoom. All gesture cameras use these shared base values.
	_base_camera_dist = _home_camera_dist / (1.0 if _home_active else GAME_VIEW_SCALE)
	_base_camera_y = _look_at_target.y + _base_camera_dist * sin(_camera_polar)
	_camera_target_dist = _base_camera_dist
	_camera_target_y = _base_camera_y
	_page_camera_start_dist = _camera_current_dist
	_page_camera_start_y = _camera_current_y
	_page_camera_elapsed = 0.0 if animated else PAGE_CAMERA_DURATION
	if not animated:
		_camera_current_dist = _base_camera_dist
		_camera_current_y = _base_camera_y
	_camera_returning = false
	_doodle_zoom = 1.0
	_doodle_elevation = _camera_polar
	_update_camera_position()

func _load_font() -> void:
	_cjk_font = load(LocaleManager.font_path())
	if _cjk_font == null:
		_cjk_font = FontFile.new()
		_cjk_font.font_path = LocaleManager.font_path()

# Capture an already-owned gesture before GUI dispatch so releasing over the
# parameter panel cannot leave the model stuck. New gestures still respect UI.
func _input(event: InputEvent) -> void:
	if _home_active:
		return
	if _scene_capture != null and _scene_capture.is_open():
		return
	if _blob.is_gripping():
		# Leave GUI events available, but discard any old model gesture ownership.
		if _dragging or _is_rotating or _active_touch_id >= 0:
			_finish_gesture()
		return
	# Native GUI sliders and ColorPicker need touch-generated mouse events.
	# The model uses real touch IDs, so never process that second event stream.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if _drawing:
		if event is InputEventMouseMotion and _drawing_touch == -1:
			_draw_to(event.position)
		elif event is InputEventMouseButton and _drawing_touch == -1 and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_draw_to(event.position)
			_doodle.end_stroke()
			_drawing = false
		elif event is InputEventScreenDrag and event.index == _drawing_touch:
			_draw_to(event.position)
		elif event is InputEventScreenTouch and event.index == _drawing_touch and not event.pressed:
			_draw_to(event.position)
			_doodle.end_stroke()
			_drawing = false
		# An owned stroke never becomes a press, stretch, or UI click.
		get_viewport().set_input_as_handled()
		return
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
	if _home_active:
		return
	if _scene_capture != null and _scene_capture.is_open():
		return
	if _blob.is_gripping():
		return
	# Native GUI sliders and ColorPicker need touch-generated mouse events.
	# The model uses real touch IDs, so never process that second event stream.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if _doodle_enabled and not _is_rotating and _active_touch_id < 0:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _begin_drawing(event.position, -1):
				get_viewport().set_input_as_handled()
				return
		elif event is InputEventScreenTouch and event.pressed:
			if _begin_drawing(event.position, event.index):
				get_viewport().set_input_as_handled()
				return
	# A second finger must start on the model and outside GUI controls.
	if event is InputEventScreenTouch and event.pressed and _touches.size() == 1 and _dragging:
		var second_hit := _raycast_blob(event.position, true)
		var first_hit := _raycast_blob(_touches[_active_touch_id], true)
		if not second_hit.is_empty() and not first_hit.is_empty():
			_touches[event.index] = event.position
			_begin_pointer(_touches[_active_touch_id], true, MOUSE_BUTTON_LEFT)
			_blob.set_stretch_contacts(first_hit.rest_point, first_hit.local_normal, second_hit.rest_point, second_hit.local_normal)
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
	_doodle.end_stroke()
	_drawing = false
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
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(_blob):
		_finish_gesture()
		_blob.set_grip_held(false)

func _physics_process(delta: float) -> void:
	if _page_camera_elapsed < PAGE_CAMERA_DURATION:
		_page_camera_elapsed = minf(_page_camera_elapsed + delta, PAGE_CAMERA_DURATION)
		var blend := smoothstep(0.0, 1.0, _page_camera_elapsed / PAGE_CAMERA_DURATION)
		_camera_current_dist = lerpf(_page_camera_start_dist, _camera_target_dist, blend)
		_camera_current_y = lerpf(_page_camera_start_y, _camera_target_y, blend)
		if _page_restoring_pose:
			_model_root.quaternion = _page_model_start.slerp(_default_model_rotation, blend)
	else:
		_camera_current_dist = lerpf(_camera_current_dist, _camera_target_dist, minf(delta * 4.0, 1.0))
		_camera_current_y = lerpf(_camera_current_y, _camera_target_y, minf(delta * 4.0, 1.0))
	_update_camera_position()
	if _page_camera_elapsed >= PAGE_CAMERA_DURATION:
		_page_restoring_pose = false
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
	# Zoom changes only viewing distance, never mesh scale or brush coordinates.
	_camera.position = _look_at_target + Vector3(x, y - _look_at_target.y, z) / _doodle_zoom
	if _doodle_enabled or _camera_returning:
		var horizontal := Vector3(cos(_camera_azimuth), 0, sin(_camera_azimuth))
		var elevation := _doodle_elevation
		var distance := _camera_current_dist / _doodle_zoom
		if _camera_returning:
			var blend := smoothstep(0.0, 1.0, _camera_return_elapsed / CAMERA_RETURN_DURATION)
			var default_offset := Vector3(x, y - _look_at_target.y, z)
			elevation = lerpf(elevation, atan2(default_offset.y, Vector2(x, z).length()), blend)
			distance = lerpf(distance, default_offset.length(), blend)
		_camera.position = _look_at_target + (horizontal * cos(elevation) + Vector3.UP * sin(elevation)) * distance
		# An orbit-aligned up vector stays valid even at exactly top-down.
		_camera.look_at(_look_at_target, Vector3.UP * cos(elevation) - horizontal * sin(elevation))
	else:
		_camera.look_at(_look_at_target, Vector3.UP)

	if _blob != null and _blob.grip_stage > 0.0 and not _doodle_enabled:
		var stage := smoothstep(0.0, 1.0, _blob.grip_stage)
		var mesh_node: Node3D = _blob._external_mesh_instance
		var lift := _blob._model_radius * 1.8 * mesh_node.global_basis.y.length() * stage
		var target := _look_at_target + Vector3.UP * lift
		var offset := _camera.position - _look_at_target
		var angle := lerpf(atan2(offset.y, Vector2(offset.x, offset.z).length()), deg_to_rad(75.0), stage)
		var horizontal := Vector3(cos(_camera_azimuth), 0.0, sin(_camera_azimuth))
		_camera.position = target + (horizontal * cos(angle) + Vector3.UP * sin(angle)) * offset.length()
		_camera.look_at(target, Vector3.UP * cos(angle) - horizontal * sin(angle))
	if _page_restoring_pose and _page_camera_elapsed < PAGE_CAMERA_DURATION:
		var blend := smoothstep(0.0, 1.0, _page_camera_elapsed / PAGE_CAMERA_DURATION)
		_camera.transform = _page_camera_start_transform.interpolate_with(_camera.transform, blend)

func _rotate_model(delta: Vector2) -> void:
	if _model_root == null or _blob.is_gripping():
		return
	_model_root.rotate_y(delta.x * 0.008)

func _begin_pointer(screen_position: Vector2, stretch: bool, button: int) -> void:
	if _doodle_enabled or _blob.is_gripping():
		return
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
	environment.background_color = Color("#f8c5cc")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#fff1e4")
	environment.ambient_light_energy = 0.32
	world_environment.environment = environment
	add_child(world_environment)

	_camera = Camera3D.new()
	_camera.name = "MainCamera"
	_camera.position = Vector3(0.0, 2.8, 4.5)
	_camera.fov = 50.0
	_camera.current = true
	add_child(_camera)
	_camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)

	# Upper-left key; its shadow falls toward the lower right.
	var key_light := DirectionalLight3D.new()
	key_light.name = "WarmKeyLight"
	key_light.rotation_degrees = Vector3(-52.0, -142.0, 0.0)
	key_light.light_color = Color("#fff4e8")
	key_light.light_energy = 0.6 #主光线
	key_light.shadow_enabled = true
	key_light.shadow_opacity = 0.55
	add_child(key_light)

	# 补光 - 减少阴影
	var fill_light := DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.rotation_degrees = Vector3(-30.0, 45.0, 0.0)
	fill_light.light_color = Color("#fff5e6")
	fill_light.light_energy = 0.12
	fill_light.shadow_enabled = false
	add_child(fill_light)

	# Broad shadow-free frontal fill lifts the face without another cast shadow.
	var front_light := DirectionalLight3D.new()
	front_light.name = "FrontLight"
	front_light.rotation_degrees = Vector3(-22.0, 0.0, 0.0)
	front_light.light_color = Color("#ffffff")
	front_light.light_energy = 0.1  #补光
	front_light.shadow_enabled = false
	add_child(front_light)

func _build_stage() -> void:
	# Large ground carries the pink studio backdrop and analytic contact shadow.
	# Keep it separate from the authored wood base.
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(200.0, 200.0)
	ground.mesh = ground_mesh
	_backdrop_material = ShaderMaterial.new()
	_backdrop_material.shader = preload("res://shaders/pink_backdrop.gdshader")
	ground.material_override = _backdrop_material
	ground.position.y = -0.035
	add_child(ground)

	# Use the authored bottom model instead of generating a primitive cylinder.
	var bottom_scene := load("res://glb/bottom.glb")
	if bottom_scene != null:
		_board = bottom_scene.instantiate() as Node3D
		if _board != null:
			_board.name = "Bottom"
			_board.position.y = 0.2123
			add_child(_board)
			_resize_board()
			return
	# Fallback for projects where the authored asset is unavailable.
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
	var target_diameter := screen_width_world * 1.2
	if _backdrop_material != null:
		_backdrop_material.set_shader_parameter("board_radius", target_diameter * 0.5)
	if _board is MeshInstance3D:
		var board_mesh := _board.mesh as CylinderMesh
		if board_mesh != null:
			board_mesh.top_radius = target_diameter * 0.5
			board_mesh.bottom_radius = target_diameter * 0.5
		return
	# The imported base keeps its authored proportions; only scale uniformly to
	# match the same screen coverage as the old generated cylinder.
	var authored_diameter := maxf(_board_source_size.x, _board_source_size.z)
	_board.scale = Vector3.ONE * (target_diameter / authored_diameter)
	_board.position.y = 0.25 - _board_source_size.y * _board.scale.y * 0.5

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
	_home_camera_dist = dist
	_base_camera_dist = dist
	_base_camera_y = _camera_target_y
	_look_at_target = center

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	_hud_root = root
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	_param_button = Button.new()
	_param_button.text = tr("参数")
	_param_button.position = Vector2(24.0, 24.0)
	_param_button.custom_minimum_size = Vector2(160.0, 80.0)
	_param_button.add_theme_font_size_override("font_size", 24)
	_param_button.add_theme_font_override("font", _cjk_font)
	_param_button.pressed.connect(_toggle_param_panel)
	_param_button.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_param_button)
	_build_doodle_panel(root)
	var home_button := Button.new()
	home_button.name = "ReturnHomeButton"
	home_button.text = tr("首页")
	home_button.position = Vector2(452, 24)
	home_button.custom_minimum_size = Vector2(110, 80)
	home_button.add_theme_font_override("font", _cjk_font)
	home_button.add_theme_font_size_override("font_size",24)
	home_button.pressed.connect(_return_home)
	root.add_child(home_button)

	_param_panel = _build_modal(root, tr("参数设置"), _close_param_panel)
	_param_panel.name = "ParameterModal"
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(_param_panel.get_meta("content") as ScrollContainer).add_child(content)
	content.add_child(LocaleManager.make_selector(_cjk_font))

	var press_feel_switch := CheckButton.new()
	press_feel_switch.name = "RaisedRimPressSwitch"
	press_feel_switch.text = tr("按压收拢与翘边")
	press_feel_switch.button_pressed = _blob.raised_rim_press
	press_feel_switch.add_theme_font_override("font", _cjk_font)
	press_feel_switch.add_theme_font_size_override("font_size", 26)
	press_feel_switch.tooltip_text = tr("开启：四周向按压点收拢、侧缘圆弧翘起；关闭：原版按压手感")
	press_feel_switch.toggled.connect(func(enabled: bool):
		_finish_gesture()
		_blob.set_raised_rim_press(enabled)
	)
	content.add_child(press_feel_switch)

	# 回弹时长
	var recovery_row := HBoxContainer.new()
	recovery_row.add_theme_constant_override("separation", 20)
	content.add_child(recovery_row)
	recovery_row.add_child(_make_label(tr("回弹时长"), 26, Color("#fff2dc")))
	var recovery_slider := HSlider.new()
	recovery_slider.min_value = 0.3
	recovery_slider.max_value = 4.0
	recovery_slider.step = 0.1
	recovery_slider.value = 1.6
	recovery_slider.custom_minimum_size = Vector2(190.0, 56.0)
	recovery_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recovery_slider.value_changed.connect(_on_recovery_changed)
	recovery_row.add_child(recovery_slider)
	_feel_sliders["recovery_time"] = recovery_slider

	# 柔软度
	var softness_row := HBoxContainer.new()
	softness_row.add_theme_constant_override("separation", 20)
	content.add_child(softness_row)
	softness_row.add_child(_make_label(tr("柔软度"), 26, Color("#fff2dc")))
	var softness_slider := HSlider.new()
	softness_slider.min_value = 0.2
	softness_slider.max_value = 1.6
	softness_slider.step = 0.1
	softness_slider.value = 0.9
	softness_slider.custom_minimum_size = Vector2(190.0, 56.0)
	softness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	softness_slider.value_changed.connect(_on_softness_changed)
	softness_row.add_child(softness_slider)
	_feel_sliders["softness"] = softness_slider

	# 按压深度
	var depth_row := HBoxContainer.new()
	depth_row.add_theme_constant_override("separation", 20)
	content.add_child(depth_row)
	depth_row.add_child(_make_label(tr("按压深度"), 26, Color("#fff2dc")))
	var depth_slider := HSlider.new()
	depth_slider.min_value = 0.1
	depth_slider.max_value = 0.5
	depth_slider.step = 0.01
	depth_slider.value = 0.32
	depth_slider.custom_minimum_size = Vector2(190.0, 56.0)
	depth_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depth_slider.value_changed.connect(_on_depth_changed)
	depth_row.add_child(depth_slider)
	_feel_sliders["min_depth"] = depth_slider

	# 手指宽度
	var finger_row := HBoxContainer.new()
	finger_row.add_theme_constant_override("separation", 20)
	content.add_child(finger_row)
	finger_row.add_child(_make_label(tr("手指宽度"), 26, Color("#fff2dc")))
	var finger_slider := HSlider.new()
	finger_slider.min_value = 0.072
	finger_slider.max_value = 0.216
	finger_slider.step = 0.001
	finger_slider.value = _blob.finger_width
	finger_slider.custom_minimum_size = Vector2(190.0, 56.0)
	finger_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	finger_slider.value_changed.connect(_on_finger_changed)
	finger_row.add_child(finger_slider)

	# 弹性抖动
	var elastic_row := HBoxContainer.new()
	elastic_row.add_theme_constant_override("separation", 20)
	content.add_child(elastic_row)
	elastic_row.add_child(_make_label(tr("弹性抖动"), 26, Color("#fff2dc")))
	var elastic_slider := HSlider.new()
	elastic_slider.min_value = 0.0
	elastic_slider.max_value = 1.0
	elastic_slider.step = 0.05
	elastic_slider.value = 0.55
	elastic_slider.custom_minimum_size = Vector2(190.0, 56.0)
	elastic_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	elastic_slider.value_changed.connect(_on_elastic_changed)
	elastic_row.add_child(elastic_slider)
	_feel_sliders["elasticity"] = elastic_slider

	# 初始回弹
	var bounce_row := HBoxContainer.new()
	bounce_row.add_theme_constant_override("separation", 20)
	content.add_child(bounce_row)
	bounce_row.add_child(_make_label(tr("初始回弹"), 26, Color("#fff2dc")))
	var bounce_slider := HSlider.new()
	bounce_slider.min_value = 0.0
	bounce_slider.max_value = 0.6
	bounce_slider.step = 0.05
	bounce_slider.value = 0.24
	bounce_slider.custom_minimum_size = Vector2(190.0, 56.0)
	bounce_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bounce_slider.value_changed.connect(_on_bounce_changed)
	bounce_row.add_child(bounce_slider)
	_feel_sliders["initial_bounce"] = bounce_slider

	# 拉伸灵敏度
	var sensitivity_row := HBoxContainer.new()
	sensitivity_row.add_theme_constant_override("separation", 20)
	content.add_child(sensitivity_row)
	sensitivity_row.add_child(_make_label(tr("拉伸灵敏度"), 26, Color("#fff2dc")))
	var sensitivity_slider := HSlider.new()
	sensitivity_slider.min_value = 0.3
	sensitivity_slider.max_value = 2.5
	sensitivity_slider.step = 0.1
	sensitivity_slider.value = 1.3
	sensitivity_slider.custom_minimum_size = Vector2(190.0, 56.0)
	sensitivity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	sensitivity_row.add_child(sensitivity_slider)
	_feel_sliders["stretch_sensitivity"] = sensitivity_slider

	# 最大拉伸
	var max_stretch_row := HBoxContainer.new()
	max_stretch_row.add_theme_constant_override("separation", 20)
	content.add_child(max_stretch_row)
	max_stretch_row.add_child(_make_label(tr("最大拉伸"), 26, Color("#fff2dc")))
	var max_stretch_slider := HSlider.new()
	max_stretch_slider.min_value = 0.8
	max_stretch_slider.max_value = 3.6
	max_stretch_slider.step = 0.1
	max_stretch_slider.value = 2.4
	max_stretch_slider.custom_minimum_size = Vector2(190.0, 56.0)
	max_stretch_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_stretch_slider.value_changed.connect(_on_max_stretch_changed)
	max_stretch_row.add_child(max_stretch_slider)
	_feel_sliders["max_stretch"] = max_stretch_slider

	# 镜头后退
	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override("separation", 20)
	content.add_child(camera_row)
	camera_row.add_child(_make_label(tr("镜头后退"), 26, Color("#fff2dc")))
	var camera_slider := HSlider.new()
	camera_slider.min_value = 0.0
	camera_slider.max_value = 1.5
	camera_slider.step = 0.1
	camera_slider.value = 1.0
	camera_slider.custom_minimum_size = Vector2(190.0, 56.0)
	camera_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camera_slider.value_changed.connect(_on_camera_changed)
	camera_row.add_child(camera_slider)

	# 回弹震动
	var vibration_row := HBoxContainer.new()
	vibration_row.add_theme_constant_override("separation", 20)
	content.add_child(vibration_row)
	vibration_row.add_child(_make_label(tr("回弹震动"), 26, Color("#fff2dc")))
	var vibration_slider := HSlider.new()
	vibration_slider.min_value = 0.0
	vibration_slider.max_value = 0.5
	vibration_slider.step = 0.05
	vibration_slider.value = 0.2
	vibration_slider.custom_minimum_size = Vector2(190.0, 56.0)
	vibration_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vibration_slider.value_changed.connect(_on_vibration_changed)
	vibration_row.add_child(vibration_slider)
	_feel_sliders["rebound_vibration"] = vibration_slider

	_grip_button = Button.new()
	_grip_button.name = "GripButton"
	_grip_button.text = tr("按住挤压")
	root.add_child(_grip_button)
	_grip_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_grip_button.offset_left = -250
	_grip_button.offset_right = -10
	_grip_button.offset_top = -150
	_grip_button.offset_bottom = -62
	_grip_button.add_theme_font_override("font", _cjk_font)
	_grip_button.add_theme_font_size_override("font_size", 28)
	_grip_button.focus_mode = Control.FOCUS_NONE
	_grip_button.button_down.connect(func():
		if not _home_active and not _doodle_enabled and not _blob.is_gripping():
			_finish_gesture()
			_blob.set_grip_axis(_camera.global_basis.x)
			_blob.set_grip_held(true)
	)
	_grip_button.button_up.connect(func():
		if not _blob._twist_mode:
			_blob.set_grip_held(false)
	)
	_twist_button = Button.new()
	_twist_button.name = "TwistButton"
	_twist_button.text = tr("按住扭转")
	root.add_child(_twist_button)
	_twist_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_twist_button.offset_left = 10
	_twist_button.offset_right = 250
	_twist_button.offset_top = -150
	_twist_button.offset_bottom = -62
	_twist_button.add_theme_font_override("font", _cjk_font)
	_twist_button.add_theme_font_size_override("font_size", 28)
	_twist_button.focus_mode = Control.FOCUS_NONE
	_twist_button.button_down.connect(func():
		if not _home_active and not _doodle_enabled and not _blob.is_gripping():
			_finish_gesture()
			_blob.set_grip_axis(_camera.global_basis.x)
			_blob.begin_twist()
	)
	_twist_button.button_up.connect(func():
		if _blob._twist_mode:
			_blob.set_grip_held(false)
	)
	_style_parameter_controls(content)

	var footer := Label.new()
	footer.name = "InteractionHint"
	footer.text = tr("单指 / 左键按压 · 双指 / Shift 拉伸")
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
	_scene_capture = SceneCapture.new()
	add_child(_scene_capture)
	_scene_capture.setup(self, root, _cjk_font)

func _toggle_param_panel() -> void:
	if _param_visible:
		_close_param_panel()
		return
	_finish_gesture()
	if _doodle_enabled:
		_set_doodle_enabled(false)
	_param_visible = true
	_param_panel.show()
	_param_panel.move_to_front()

func _close_param_panel() -> void:
	_param_visible = false
	_param_panel.hide()

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

func _process(delta: float) -> void:
	_refresh_sticker_preview()
	if _sticker_enabled and not _sticker_actions.is_empty():
		_sticker_actions["ConfirmStickerButton"].disabled = not _sticker_pending
		_sticker_actions["CancelStickerButton"].disabled = not _sticker_pending
		_sticker_actions["UndoStickerButton"].disabled = _sticker_undo == null
		_sticker_actions["EditStickerButton"].disabled = _sticker_pending or _sticker_last.is_empty()
	_doodle.flush()
	if _camera_returning:
		_camera_return_elapsed = minf(_camera_return_elapsed + delta, CAMERA_RETURN_DURATION)
		if _camera_return_elapsed >= CAMERA_RETURN_DURATION:
			_camera_returning = false
			_doodle_zoom = 1.0
			_doodle_elevation = _camera_polar
		_update_camera_position()

func _begin_drawing(point: Vector2, touch_id: int) -> bool:
	var hit := _raycast_blob(point, true)
	if hit.is_empty():
		return false
	_drawing = true
	_drawing_touch = touch_id
	_drawing_last = point
	if _sticker_enabled:
		if _sticker_image == null:
			_sticker_image = (load("res://res/common/pic/p_1.png") as Texture2D).get_image()
		if not _sticker_pending:
			_sticker_base = _doodle.image.duplicate() as Image
			_sticker_cancel_image = _sticker_base
			_sticker_pending = true
		_sticker_uv = hit.uv
		_sticker_preview_dirty = true
	else:
		_sticker_undo = null
		_sticker_last.clear()
		_doodle.begin_stroke()
		_doodle.stamp(hit.uv)
	return true

func _draw_to(point: Vector2) -> void:
	if _sticker_enabled:
		if _sticker_pending and not _over_doodle_controls(point):
			var hit := _raycast_blob(point, true)
			if not hit.is_empty():
				_sticker_uv = hit.uv
				_sticker_preview_dirty = true
		return
	# Sample the screen path, NOT a UV line: UV seams must never create a
	# spurious black slash through unrelated texture islands or the back face.
	var count := maxi(1, ceili(_drawing_last.distance_to(point) / 2.0))
	for i in range(1, count + 1):
		var sample_point := _drawing_last.lerp(point, float(i) / float(count))
		# Drawing across a UI panel breaks the visible stroke.
		if _over_doodle_controls(sample_point) or (_param_panel.visible and _param_panel.get_global_rect().has_point(sample_point)):
			continue
		var hit := _raycast_blob(sample_point, true)
		if not hit.is_empty():
			_doodle.stamp(hit.uv)
	_drawing_last = point

func _refresh_sticker_preview() -> void:
	if not _sticker_pending or not _sticker_preview_dirty:
		return
	_doodle.image = _sticker_base.duplicate() as Image
	_doodle.place_sticker(_sticker_uv, _sticker_image, _sticker_width, _sticker_angle)
	_sticker_preview_dirty = false

func _confirm_sticker() -> void:
	if not _sticker_pending:
		return
	_refresh_sticker_preview()
	_sticker_undo = _sticker_base
	_sticker_last = {"uv": _sticker_uv, "width": _sticker_width, "angle": _sticker_angle}
	_sticker_base = null
	_sticker_cancel_image = null
	_sticker_pending = false
	_sticker_preview_dirty = false

func _cancel_sticker() -> void:
	if _sticker_pending:
		_doodle.image = _sticker_cancel_image
		_doodle.dirty = true
	_sticker_base = null
	_sticker_cancel_image = null
	_sticker_pending = false
	_sticker_preview_dirty = false

func _undo_sticker() -> void:
	_cancel_sticker()
	if _sticker_undo != null:
		_doodle.image = _sticker_undo
		_doodle.dirty = true
		_sticker_undo = null
		_sticker_last.clear()

func _edit_last_sticker() -> void:
	if _sticker_pending or _sticker_undo == null or _sticker_last.is_empty():
		return
	_sticker_cancel_image = _doodle.image.duplicate() as Image
	_sticker_base = _sticker_undo.duplicate() as Image
	_sticker_uv = _sticker_last.uv
	_sticker_width = _sticker_last.width
	_sticker_angle = _sticker_last.angle
	_sticker_pending = true
	_sticker_preview_dirty = true
	var size_slider := find_child("DoodleSizeSlider", true, false) as VSlider
	size_slider.value = _sticker_width
	var rotation := find_child("StickerRotationSlider", true, false) as HSlider
	rotation.value = rad_to_deg(_sticker_angle)

func _set_doodle_enabled(enabled: bool) -> void:
	if not enabled:
		_cancel_sticker()
	_finish_gesture()
	_doodle_enabled = enabled
	_grip_button.visible = not enabled
	_twist_button.visible = not enabled
	if enabled:
		_blob.cancel_grip()
	if enabled:
		_blob.reset_deformation()
		_close_param_panel()
		var offset := _camera.position - _look_at_target
		_doodle_elevation = atan2(offset.y, Vector2(offset.x, offset.z).length())
		_doodle_zoom = _camera_current_dist / maxf(offset.length(), 0.001)
		_camera_returning = false
		var zoom := find_child("DoodleZoomSlider", true, false) as VSlider
		zoom.set_value_no_signal(_doodle_zoom)
	if not enabled:
		var mode := find_child("DoodleViewModeButton", true, false) as Button
		mode.button_pressed = false
		var zoom := find_child("DoodleZoomSlider", true, false) as VSlider
		zoom.set_value_no_signal(1.0)
		_camera_return_elapsed = 0.0
		_camera_returning = true
		var eye := find_child("DoodleVisibilityButton", true, false) as Button
		eye.button_pressed = false
	_doodle_panel.visible = enabled
	_update_camera_position()
	var hint := find_child("InteractionHint", true, false) as Label
	if hint != null:
		hint.text = tr("在模型上绘制 · 拖动空白处旋转") if enabled else tr("单指 / 左键按压 · 双指 / Shift 拉伸")
	_doodle_button.text = tr("退出涂鸦") if enabled else tr("涂鸦")
	if enabled:
		_doodle_panel.move_to_front()

func _over_doodle_controls(point: Vector2) -> bool:
	if not _doodle_panel.visible:
		return false
	for child in _doodle_panel.get_children():
		if child is Control and child.visible and child.mouse_filter != Control.MOUSE_FILTER_IGNORE and child.get_global_rect().has_point(point):
			return true
	return false

func _build_doodle_panel(root: Control) -> void:
	_doodle_button = Button.new()
	_doodle_button.name = "DoodleButton"
	_doodle_button.text = tr("涂鸦")
	_doodle_button.position = Vector2(208, 24)
	_doodle_button.custom_minimum_size = Vector2(220, 80)
	_doodle_button.add_theme_font_size_override("font_size", 24)
	_doodle_button.add_theme_font_override("font", _cjk_font)
	_doodle_button.pressed.connect(func(): _set_doodle_enabled(not _doodle_enabled))
	root.add_child(_doodle_button)
	_doodle_panel = Control.new()
	_doodle_panel.name = "DoodleTools"
	root.add_child(_doodle_panel)
	_doodle_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_doodle_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_doodle_panel.hide()

	var left := _doodle_tool_card()
	left.name = "LeftDoodleToolbar"
	_doodle_panel.add_child(left)
	left.anchor_top = 0.29
	left.anchor_bottom = 0.66
	left.offset_left = 4
	left.offset_right = 104
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	left.add_child(box)
	var eraser := CheckButton.new()
	eraser.name = "DoodleEraserSwitch"
	eraser.text = tr("橡皮擦")
	eraser.custom_minimum_size = Vector2(140, 72)
	eraser.add_theme_font_override("font", _cjk_font)
	eraser.add_theme_font_size_override("font_size", 20)
	for state in ["checked", "unchecked"]:
		var image := _parameter_control_icon(true, state == "checked").get_image()
		image.resize(60, 34, Image.INTERPOLATE_LANCZOS)
		eraser.add_theme_icon_override(state, ImageTexture.create_from_image(image))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		eraser.add_theme_color_override(state, Color("#735d46"))
	_doodle_panel.add_child(eraser)
	eraser.anchor_top = 0.21
	eraser.anchor_bottom = 0.21
	eraser.offset_left = 4
	eraser.offset_right = 144
	eraser.offset_bottom = 72
	var size_label := _make_label(tr("笔宽 10"), 20, Color("#735d46"))
	size_label.name = "DoodleSizeLabel"
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(size_label)
	var size_slider := VSlider.new()
	size_slider.name = "DoodleSizeSlider"
	size_slider.min_value = 2
	size_slider.max_value = 48
	size_slider.step = 1
	size_slider.value = _doodle.radius * 2.0
	size_slider.custom_minimum_size = Vector2(56, 180)
	size_slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_slider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_doodle_slider(size_slider, true)
	box.add_child(size_slider)
	var color_tools := VBoxContainer.new()
	color_tools.name = "DoodleColorTools"
	_doodle_panel.add_child(color_tools)
	color_tools.anchor_top = 0.70
	color_tools.offset_left = 4
	color_tools.offset_right = 88
	color_tools.add_theme_constant_override("separation", 12)
	var color_picker := ColorPickerButton.new()
	color_picker.name = "DoodleColorPicker"
	color_picker.color = _doodle.color
	color_picker.edit_alpha = true
	_configure_doodle_color_picker(color_picker)
	color_picker.custom_minimum_size = Vector2(80, 56)
	color_picker.tooltip_text = tr("选择画笔颜色")
	color_tools.add_child(_make_label(tr("颜色"), 20, Color("#735d46")))
	color_tools.add_child(color_picker)
	var sticker_button := Button.new()
	sticker_button.name = "DoodleStickerButton"
	sticker_button.text = tr("贴纸")
	sticker_button.toggle_mode = true
	sticker_button.icon = load("res://res/common/pic/p_1.png") as Texture2D
	sticker_button.expand_icon = true
	sticker_button.add_theme_constant_override("icon_max_width", 48)
	sticker_button.add_theme_font_override("font", _cjk_font)
	sticker_button.custom_minimum_size = Vector2(80, 64)
	color_tools.add_child(sticker_button)
	sticker_button.toggled.connect(func(enabled: bool):
		_finish_gesture()
		if not enabled:
			_cancel_sticker()
		_sticker_enabled = enabled
		_sticker_edit_tools.visible = enabled
		if enabled:
			eraser.set_pressed_no_signal(false)
			_doodle.erasing = false
		# Switching ranges must not overwrite the remembered brush/sticker sizes.
		size_slider.set_block_signals(true)
		size_slider.max_value = 384 if enabled else 48
		size_slider.min_value = 32 if enabled else 2
		size_slider.value = _sticker_width if enabled else _doodle.radius * 2.0
		size_slider.set_block_signals(false)
		size_label.text = (tr("贴纸 %d") if enabled else tr("笔宽 %d")) % int(size_slider.value)
		color_picker.disabled = enabled or _doodle.erasing
	)
	size_slider.value_changed.connect(func(value: float):
		if _sticker_enabled:
			_sticker_width = int(value)
			_sticker_preview_dirty = _sticker_pending
			size_label.text = tr("贴纸 %d") % int(value)
			return
		_doodle.radius = value * 0.5
		size_label.text = (tr("擦宽 %d") if _doodle.erasing else tr("笔宽 %d")) % int(value)
	)
	color_picker.color_changed.connect(func(value: Color):
		_doodle.color = value
	)
	eraser.toggled.connect(func(enabled: bool):
		if enabled:
			sticker_button.button_pressed = false
		_doodle.erasing = enabled
		size_slider.value = _doodle.radius * 2.0
		size_label.text = (tr("擦宽 %d") if enabled else tr("笔宽 %d")) % int(size_slider.value)
		color_picker.disabled = enabled or _sticker_enabled
	)
	var clear_button := Button.new()
	clear_button.name = "ClearDoodleButton"
	clear_button.text = tr("清空")
	clear_button.custom_minimum_size.y = 48
	clear_button.add_theme_font_override("font", _cjk_font)
	clear_button.pressed.connect(func():
		_cancel_sticker()
		_sticker_undo = null
		_sticker_last.clear()
		_doodle.clear()
	)
	color_tools.add_child(clear_button)

	_sticker_edit_tools = VBoxContainer.new()
	_sticker_edit_tools.name = "StickerEditTools"
	_doodle_panel.add_child(_sticker_edit_tools)
	_sticker_edit_tools.anchor_left = 0.18
	_sticker_edit_tools.anchor_right = 0.82
	_sticker_edit_tools.anchor_top = 1.0
	_sticker_edit_tools.anchor_bottom = 1.0
	_sticker_edit_tools.offset_top = -220
	_sticker_edit_tools.offset_bottom = -36
	_sticker_edit_tools.hide()
	var help := _make_label(tr("拖动贴纸位置 · 左侧调大小"), 20, Color("#735d46"))
	help.name = "StickerHelpLabel"
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sticker_edit_tools.add_child(help)
	var rotation := HSlider.new()
	rotation.name = "StickerRotationSlider"
	rotation.min_value = -180
	rotation.max_value = 180
	rotation.step = 1
	rotation.custom_minimum_size.y = 48
	_style_doodle_slider(rotation, false)
	rotation.value_changed.connect(func(value: float):
		_sticker_angle = deg_to_rad(value)
		_sticker_preview_dirty = _sticker_pending
		help.text = tr("旋转 %d° · 拖动位置 · 左侧调大小") % int(value)
	)
	_sticker_edit_tools.add_child(rotation)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	_sticker_edit_tools.add_child(actions)
	for entry in [[tr("确认"), "ConfirmStickerButton", _confirm_sticker], [tr("取消"), "CancelStickerButton", _cancel_sticker], [tr("撤销"), "UndoStickerButton", _undo_sticker], [tr("编辑"), "EditStickerButton", _edit_last_sticker]]:
		var action := Button.new()
		action.text = entry[0]
		action.name = entry[1]
		_sticker_actions[entry[1]] = action
		action.add_theme_font_override("font", _cjk_font)
		action.custom_minimum_size = Vector2(96, 56)
		action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action.pressed.connect(entry[2])
		actions.add_child(action)

	var right := _doodle_tool_card()
	right.name = "DoodleZoomToolbar"
	_doodle_panel.add_child(right)
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.anchor_top = 0.30
	right.anchor_bottom = 0.74
	right.offset_left = -76
	right.offset_right = -4
	var zoom_box := VBoxContainer.new()
	zoom_box.add_theme_constant_override("separation", 12)
	right.add_child(zoom_box)
	var zoom_label := _make_label("100%", 18, Color("#735d46"))
	zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var magnifier := Control.new()
	magnifier.custom_minimum_size.y = 36
	magnifier.mouse_filter = Control.MOUSE_FILTER_IGNORE
	magnifier.draw.connect(func():
		var center := Vector2(magnifier.size.x * 0.5 - 4, 14)
		magnifier.draw_arc(center, 9, 0, TAU, 32, Color("#735d46"), 3, true)
		magnifier.draw_line(center + Vector2(7, 7), center + Vector2(16, 16), Color("#735d46"), 3, true)
	)
	zoom_box.add_child(magnifier)
	var mode := Button.new()
	mode.name = "DoodleViewModeButton"
	mode.text = tr("缩放")
	mode.toggle_mode = true
	mode.custom_minimum_size.y = 52
	mode.add_theme_font_override("font", _cjk_font)
	mode.add_theme_font_size_override("font_size", 20)
	mode.tooltip_text = tr("切换缩放 / 俯视角度")
	zoom_box.add_child(mode)
	var upper_label := _make_label(tr("放大 +"), 18, Color("#735d46"))
	zoom_box.add_child(upper_label)
	zoom_box.add_child(zoom_label)
	var zoom := VSlider.new()
	zoom.name = "DoodleZoomSlider"
	zoom.min_value = 0.6
	zoom.max_value = 2.0
	zoom.step = 0.01
	zoom.value = _doodle_zoom
	zoom.custom_minimum_size = Vector2(56, 160)
	zoom.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	zoom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_doodle_slider(zoom, true)
	zoom_box.add_child(zoom)
	var lower_label := _make_label(tr("缩小 −"), 18, Color("#735d46"))
	zoom_box.add_child(lower_label)
	zoom.value_changed.connect(func(value: float):
		if _doodle_angle_mode:
			_doodle_elevation = deg_to_rad(value)
			zoom_label.text = "%d°" % roundi(value)
		else:
			_doodle_zoom = value
			zoom_label.text = "%d%%" % roundi(value * 100)
		_update_camera_position()
	)
	mode.toggled.connect(func(angle_mode: bool):
		_doodle_angle_mode = angle_mode
		mode.text = tr("视角") if angle_mode else tr("缩放")
		upper_label.text = tr("俯视") if angle_mode else tr("放大 +")
		lower_label.text = tr("平视") if angle_mode else tr("缩小 −")
		zoom.set_block_signals(true)
		zoom.min_value = 0.0 if angle_mode else 0.6
		zoom.max_value = 90.0 if angle_mode else 2.0
		zoom.step = 0.5 if angle_mode else 0.01
		zoom.value = rad_to_deg(_doodle_elevation) if angle_mode else _doodle_zoom
		zoom.set_block_signals(false)
		zoom_label.text = ("%d°" % roundi(rad_to_deg(_doodle_elevation))) if angle_mode else ("%d%%" % roundi(_doodle_zoom * 100))
	)

	var eye := Button.new()
	eye.name = "DoodleVisibilityButton"
	eye.toggle_mode = true
	eye.tooltip_text = tr("淡化 / 恢复涂鸦工具栏")
	_doodle_panel.add_child(eye)
	eye.anchor_left = 1
	eye.anchor_right = 1
	eye.offset_left = -104
	eye.offset_right = -24
	eye.offset_top = 24
	eye.offset_bottom = 104
	var icon := Control.new()
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eye.add_child(icon)
	icon.draw.connect(func():
		var center := icon.size * 0.5
		var outline := PackedVector2Array()
		for i in range(33):
			var t := float(i) / 32.0
			outline.append(center + Vector2(48.0 * t - 24.0, -sin(t * PI) * 14.0))
		for i in range(33):
			var t := float(i) / 32.0
			outline.append(center + Vector2(24.0 - 48.0 * t, sin(t * PI) * 14.0))
		icon.draw_polyline(outline, Color("#fff2dc"), 3.0, true)
		icon.draw_circle(center, 7, Color("#fff2dc"), true, -1.0, true)
		if eye.button_pressed:
			icon.draw_line(center + Vector2(-24, 20), center + Vector2(24, -20), Color("#fff2dc"), 3.0, true)
	)
	eye.toggled.connect(func(dimmed: bool):
		_doodle_ui_dimmed = dimmed
		for child in _doodle_panel.get_children():
			if child is Control and child != eye:
				child.modulate.a = 0.2 if dimmed else 1.0
				_set_doodle_control_input(child, not dimmed)
		icon.queue_redraw()
	)

func _doodle_tool_card() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxEmpty.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	return panel

func _style_doodle_slider(slider: Slider, vertical: bool) -> void:
	var type := "VSlider" if vertical else "HSlider"
	var track := StyleBoxFlat.new()
	track.bg_color = Color("#d7c0b7")
	track.set_corner_radius_all(6)
	if vertical:
		track.content_margin_left = 6
		track.content_margin_right = 6
	else:
		track.content_margin_top = 6
		track.content_margin_bottom = 6
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = Color("#9e7367")
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	slider.add_theme_icon_override("grabber", _parameter_control_icon(false, true))
	slider.add_theme_icon_override("grabber_highlight", _parameter_control_icon(false, true))

# Full-screen input shield with a translucent dismiss area and scrollable card.
func _build_modal(root: Control, title: String, close: Callable) -> Control:
	var overlay := Control.new()
	root.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.hide()
	var backdrop := Button.new()
	backdrop.name = "DismissBackdrop"
	overlay.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := StyleBoxFlat.new()
	shade.bg_color = Color(0.08, 0.04, 0.05, 0.42)
	for state in ["normal", "hover", "pressed", "focus"]:
		backdrop.add_theme_stylebox_override(state, shade)
	backdrop.focus_mode = Control.FOCUS_NONE
	backdrop.pressed.connect(close)
	var card := PanelContainer.new()
	card.name = "ModalCard"
	overlay.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.anchor_left = 0.06
	card.anchor_right = 0.94
	card.anchor_top = 0.12
	card.anchor_bottom = 0.90
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.24, 0.16, 0.14, 0.96)
	style.set_corner_radius_all(20)
	style.set_content_margin_all(24)
	card.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 20)
	card.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	var heading := _make_label(title, 28, Color("#fff2dc"))
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	var close_button := Button.new()
	close_button.name = "CloseModalButton"
	close_button.text = tr("关闭 ×")
	close_button.custom_minimum_size = Vector2(112, 56)
	close_button.add_theme_font_override("font", _cjk_font)
	close_button.add_theme_font_size_override("font_size", 20)
	close_button.pressed.connect(close)
	header.add_child(close_button)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	overlay.set_meta("content", scroll)
	return overlay

func _style_parameter_controls(content: Control) -> void:
	var theme := Theme.new()
	var bold := FontVariation.new()
	bold.base_font = _cjk_font
	bold.variation_embolden = 0.7
	theme.default_font = bold
	theme.default_font_size = 26
	var track := StyleBoxFlat.new()
	track.bg_color = Color("#201614")
	track.set_corner_radius_all(6)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = Color("#d4b4a7")
	theme.set_stylebox("slider", "HSlider", track)
	theme.set_stylebox("grabber_area", "HSlider", fill)
	theme.set_stylebox("grabber_area_highlight", "HSlider", fill)
	theme.set_icon("grabber", "HSlider", _parameter_control_icon(false, true))
	theme.set_icon("grabber_highlight", "HSlider", _parameter_control_icon(false, true))
	theme.set_icon("checked", "CheckButton", _parameter_control_icon(true, true))
	theme.set_icon("unchecked", "CheckButton", _parameter_control_icon(true, false))
	content.theme = theme
	var nodes: Array[Node] = [content]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is Label or node is CheckButton:
			node.remove_theme_font_override("font")
		if node is CheckButton:
			node.custom_minimum_size.y = 64
		nodes.append_array(node.get_children())

func _parameter_control_icon(toggle: bool, enabled: bool) -> ImageTexture:
	var size := Vector2i(80, 44) if toggle else Vector2i(32, 32)
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(size.y):
		for x in range(size.x):
			var point := Vector2(x + 0.5, y + 0.5)
			if toggle:
				var center := Vector2(clampf(point.x, 22.0, 58.0), 22.0)
				var coverage := clampf(22.0 - point.distance_to(center), 0.0, 1.0)
				var color := Color("#d4ad9c") if enabled else Color("#79655f")
				color.a = coverage
				var knob := Vector2(58, 22) if enabled else Vector2(22, 22)
				var knob_alpha := clampf(17.0 - point.distance_to(knob), 0.0, 1.0)
				image.set_pixel(x, y, color.blend(Color(1.0, 0.96, 0.92, knob_alpha)))
			else:
				image.set_pixel(x, y, Color(1.0, 0.94, 0.88, clampf(16.0 - point.distance_to(Vector2(16, 16)), 0.0, 1.0)))
	return ImageTexture.create_from_image(image)

# Disable the whole subtree and let gestures reach the model beneath faded tools.
func _set_doodle_control_input(control: Control, enabled: bool) -> void:
	if enabled:
		control.mouse_filter = control.get_meta("doodle_mouse_filter", control.mouse_filter)
		control.focus_mode = control.get_meta("doodle_focus_mode", control.focus_mode)
	else:
		control.set_meta("doodle_mouse_filter", control.mouse_filter)
		control.set_meta("doodle_focus_mode", control.focus_mode)
		control.release_focus()
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_NONE
	if control is Slider:
		control.editable = enabled
	if control is ColorPickerButton and not enabled:
		control.get_popup().hide()
	for child in control.get_children():
		if child is Control:
			_set_doodle_control_input(child, enabled)

func _configure_doodle_color_picker(button: ColorPickerButton) -> void:
	var picker := button.get_picker()
	picker.edit_alpha = true
	picker.edit_intensity = false
	picker.color_mode = ColorPicker.MODE_RGB
	picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	picker.sampler_visible = false
	picker.color_modes_visible = false
	picker.hex_visible = false
	picker.presets_visible = false
	picker.sliders_visible = true
	var theme := Theme.new()
	theme.default_font = _cjk_font
	theme.default_font_size = 22
	picker.theme = theme
	picker.add_theme_constant_override("h_width", 36)
	picker.add_theme_constant_override("label_width", 30)
	picker.add_theme_constant_override("margin", 16)
	var nodes: Array[Node] = [picker]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is HSlider:
			node.custom_minimum_size.y = 48
			_style_doodle_slider(node, false)
		elif node is SpinBox:
			node.custom_minimum_size = Vector2(92, 48)
		nodes.append_array(node.get_children(true))
	button.get_popup().about_to_popup.connect(func():
		# Size against the logical viewport so portrait mobile gets a large square.
		var viewport_size := get_viewport().get_visible_rect().size
		var square := int(clampf(minf(viewport_size.x * 0.55, viewport_size.y * 0.42), 120, 380))
		picker.add_theme_constant_override("sv_width", square)
		picker.add_theme_constant_override("sv_height", square)
		button.get_popup().reset_size()
	)
