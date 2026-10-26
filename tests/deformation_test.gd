extends SceneTree

# Desktop hardware events must not alter synthetic Shift/touch sequences.
class SyntheticInputFilter extends Node:
	func _input(event: InputEvent) -> void:
		if event.device != 42:
			get_viewport().set_input_as_handled()

var main: Node3D
var blob: BlobDeformer
var failures: int = 0
var capture := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures += 1
		push_error("FAIL: " + message)

func advance(seconds: float) -> void:
	for frame in range(ceili(seconds * 60.0)):
		main._physics_process(1.0 / 60.0)
		blob._physics_process(1.0 / 60.0)

func feed_input(event: InputEvent) -> void:
	event.device = 42
	Input.parse_input_event(event)

func mouse_button(position: Vector2, pressed: bool, button: int = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.shift_pressed = shift
	event.button_index = button
	event.pressed = pressed
	feed_input(event)

func motion(position: Vector2, shift: bool = false) -> void:
	var event := InputEventMouseMotion.new()
	event.shift_pressed = shift
	event.position = position
	feed_input(event)

func screen_point() -> Vector2:
	var mesh_node: Node3D = blob._external_mesh_instance if blob._external_mesh_instance != null else blob
	return main._camera.unproject_position(mesh_node.to_global(blob._model_center + Vector3.UP * blob._model_size.y * 0.3))

func max_offset() -> float:
	var result := 0.0
	for i in range(blob._positions.size()):
		result = maxf(result, blob._positions[i].distance_to(blob._rest_positions[i]))
	return result / blob._model_radius

func section_width(along: float) -> float:
	var center := blob._model_center + Vector3.RIGHT * along * blob._model_size.x * 0.5
	var a := center + Vector3.BACK * blob._model_radius * 0.2
	var b := center - Vector3.BACK * blob._model_radius * 0.2
	return (a + blob._target_offset_for(a)).z - (b + blob._target_offset_for(b)).z

func check_neck_profile() -> void:
	blob.reset_deformation()
	blob._anchor_point = blob._model_center
	blob._smooth_pull = Vector3.RIGHT * blob._model_radius * 0.4
	check(section_width(0.0) / section_width(0.75) > 0.9, "Small pulls do not pinch the waist")
	blob._smooth_pull = Vector3.RIGHT * blob._model_radius * 3.6
	check(section_width(0.0) / section_width(0.75) < 0.4, "Long pulls create a narrow waist and full ends")
	check(section_width(0.0) > blob._model_radius * 0.05, "Maximum stretch keeps a nonzero connecting neck")
	var monotonic := true
	var previous := -INF
	for i in range(101):
		var point := blob._model_center + Vector3.RIGHT * blob._model_size.x * (float(i) / 100.0 - 0.5)
		var deformed := point + blob._target_offset_for(point)
		monotonic = monotonic and deformed.x > previous
		previous = deformed.x
	check(monotonic, "Neck stretch does not fold back along its axis")
	blob.reset_deformation()

func check_press_feel() -> void:
	main._finish_gesture()
	blob.reset_deformation()
	var center := screen_point()
	var original_mesh: Mesh = blob._external_mesh_instance.mesh
	var stable_hit: Dictionary = main._raycast_blob(center, true)
	main._begin_pointer(center, false, MOUSE_BUTTON_LEFT)
	advance(0.15)
	var shallow := max_offset()
	advance(0.55)
	var medium := max_offset()
	advance(1.0)
	var deep := max_offset()
	check(medium > shallow * 1.2 and deep > medium * 1.2, "Holding progressively deepens the dent")
	await screenshot("long-press")
	advance(2.0)
	check(absf(max_offset() - deep) < 0.005, "Long hold saturates at bounded depth")
	var far_point := blob._model_center + Vector3(blob._model_radius * 0.9, blob._model_size.y * 0.4, 0.0)
	var far_offset := blob._target_offset_for(far_point)
	check(far_offset.y < -blob._model_size.y * 0.02 and far_offset.x > 0.0, "Press also flattens and widens the whole body")
	var hit_after: Dictionary = main._raycast_blob(center, true)
	check(hit_after.rest_point.distance_to(stable_hit.rest_point) < blob._model_radius * 0.0001, "Drag reference stays fixed as the dent deepens")
	var old_anchor: Vector3 = blob._anchor_point
	main._move_pointer(center + Vector2(45, 0))
	main._physics_process(1.0 / 60.0)
	var target: Vector3 = blob._anchor_target
	check(blob._anchor_point.distance_to(old_anchor) < 0.000001, "Pointer input does not snap the rendered dent")
	blob._physics_process(1.0 / 60.0)
	check(blob._anchor_point.distance_to(target) < old_anchor.distance_to(target) and blob._anchor_point.distance_to(target) > 0.000001, "Dent follows drag with smooth convergence")
	check(blob._press_elapsed > 3.0, "Dragging does not restart hold duration")
	check(blob._external_mesh_instance.mesh == original_mesh and blob._cpu_dirty, "Rendering keeps static mesh and defers CPU vertex work")
	main._finish_gesture()
	advance(5.0)
	check(max_offset() < 0.001, "Dent and global squash both recover")

func measure_rebound(strength: float, save_images: bool = false) -> Dictionary:
	blob.reset_deformation()
	var mesh_node: Node3D = blob._external_mesh_instance
	var rest: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.4
	blob.begin_interaction(mesh_node.to_global(rest), true, rest, Vector3.UP)
	blob.update_stretch_vector(mesh_node.global_basis * Vector3.RIGHT * blob._model_radius * strength / blob.stretch_sensitivity)
	advance(0.8)
	blob.end_interaction()
	var peaks: Array[float] = []
	var previous: float = blob._signed_stretch() / blob._model_radius
	var falling := true
	var shortened := false
	var thickened := false
	for frame in range(720):
		blob._physics_process(1.0 / 120.0)
		var amount: float = blob._signed_stretch() / blob._model_radius
		if falling and amount > previous and previous < -0.005:
			peaks.append(-previous)
			if peaks.size() == 1:
				var left: Vector3 = blob._model_center - Vector3.RIGHT * blob._model_radius
				var right: Vector3 = blob._model_center + Vector3.RIGHT * blob._model_radius
				var span: float = (right + blob._target_offset_for(right)).x - (left + blob._target_offset_for(left)).x
				shortened = span < blob._model_radius * 1.9
				thickened = section_width(0.0) > blob._model_radius * 0.42
			if save_images and peaks.size() <= 3:
				await screenshot("rebound-" + str(peaks.size()))
		falling = amount < previous
		previous = amount
	return {"peaks": peaks, "shortened": shortened, "thickened": thickened}

func check_rebound() -> void:
	var short_pull: Dictionary = await measure_rebound(0.8)
	var long_pull: Dictionary = await measure_rebound(2.4, true)
	var peaks: Array = long_pull.peaks
	check(peaks.size() >= 3, "Stretch release produces at least three compression rebounds")
	if peaks.size() >= 3:
		check(peaks[0] > peaks[1] and peaks[1] > peaks[2] and peaks[2] > 0.04, "Three visible rebound peaks progressively decay")
		check(not short_pull.peaks.is_empty() and peaks[0] > short_pull.peaks[0] * 2.5, "Longer stretch produces proportionally stronger rebound")
	check(long_pull.shortened and long_pull.thickened, "Rebound overshoots into shorter and thicker than rest")
	check(max_offset() < 0.001, "Multiple rebounds eventually settle at original shape")

func screenshot(label: String) -> void:
	if not capture:
		return
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	await process_frame
	RenderingServer.force_draw(false)
	get_root().get_texture().get_image().save_png("/tmp/nienie-" + label + ".png")
	main.set_process_input(true)
	main.set_process_unhandled_input(true)

func _run() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	root.size = Vector2i(720, 1280)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	if capture:
		root.add_child(SyntheticInputFilter.new())
	await process_frame
	await process_frame
	if capture:
		await create_timer(0.5).timeout
	main.set_physics_process(false)
	blob = main._blob
	blob.set_physics_process(false)
	blob.rebound_vibration = 0.0
	main._physics_process(0.016)
	var center := screen_point()
	check(blob._positions.size() == 5925, "Production mooncake mesh is deformable")
	check(not main._raycast_blob(center).is_empty(), "Screen ray hits real visible surface")
	var mesh_node: Node3D = blob._external_mesh_instance
	var pivot_center := mesh_node.to_global(blob._model_center)
	var rotation_centered := true
	var rotation_pickable := true
	var original_rotation: Vector3 = main._model_root.rotation
	for angle in [0.5, 1.1, 1.7, 3.14, 4.7, 6.28]:
		main._model_root.rotation.y = angle
		rotation_centered = rotation_centered and mesh_node.to_global(blob._model_center).distance_to(pivot_center) < 0.0001
		rotation_pickable = rotation_pickable and not main._raycast_blob(screen_point()).is_empty()
	main._model_root.rotation = original_rotation
	check(rotation_centered, "Rotation keeps mooncake center fixed on board")
	check(rotation_pickable, "Rotated mooncake remains pickable")
	await screenshot("rest")
	mouse_button(center, true)
	await process_frame
	check(main._dragging and not main._stretching, "Left press reaches scene through HUD")
	advance(0.35)
	check(max_offset() > 0.12, "Press produces visible indentation")
	await screenshot("press")
	var outside := center + Vector2(380.0, 0.0)
	check(main._raycast_blob(outside).is_empty(), "Drag target lies outside model")
	motion(center + Vector2(30, 0))
	await process_frame
	advance(0.2)
	check(not main._stretching and blob.get_stretch_amount() == 0.0, "Left drag stays in press mode")
	motion(outside)
	await process_frame
	advance(0.2)
	check(not main._stretching and blob.get_stretch_amount() == 0.0, "Left drag outside silhouette cannot stretch")
	mouse_button(outside, false)
	await process_frame
	blob.reset_deformation()
	mouse_button(center, true, MOUSE_BUTTON_RIGHT)
	await process_frame
	check(not main._dragging, "Right click does not enable stretch")
	mouse_button(center, false, MOUSE_BUTTON_RIGHT)
	mouse_button(center, true, MOUSE_BUTTON_LEFT, true)
	motion(outside, true)
	await process_frame
	advance(0.4)
	check(main._stretching and blob._pull_offset.length() > blob._model_radius * 0.5, "Shift plus left drag stretches beyond silhouette")
	check(max_offset() > 0.4, "Broad stretch produces visible displacement")
	await screenshot("stretch")
	var frozen_pull := blob._pull_offset
	advance(0.5)
	check(blob._pull_offset.distance_to(frozen_pull) < blob._model_radius * 0.001, "Camera retraction does not manufacture pointer movement")
	mouse_button(Vector2(35, 35), false, MOUSE_BUTTON_RIGHT)
	await process_frame
	check(main._dragging, "Unrelated button release does not cancel drag")
	mouse_button(Vector2(35, 35), false)
	await process_frame
	check(not main._dragging, "Release over GUI ends captured gesture")
	advance(5.0)
	check(max_offset() < 0.001, "Release recovers original shape")
	await screenshot("recovered")
	center = screen_point()
	mouse_button(center, true, MOUSE_BUTTON_LEFT, true)
	motion(center + Vector2(0, -240), true)
	await process_frame
	advance(0.3)
	check(absf(blob._pull_offset.y) > blob._model_radius * 0.1, "Vertical stretch retains Y displacement")
	var shift_release := InputEventKey.new()
	shift_release.keycode = KEY_SHIFT
	shift_release.pressed = false
	feed_input(shift_release)
	await process_frame
	check(not main._stretching, "Releasing Shift ends mouse stretch immediately")
	main._finish_gesture()
	blob.reset_deformation()
	main._param_panel.visible = true
	mouse_button(Vector2(80, 120), true)
	await process_frame
	check(not main._dragging and not main._is_rotating, "Parameter panel blocks new scene gestures")
	mouse_button(Vector2(80, 120), false)
	main._param_panel.visible = false
	center = screen_point()
	var touch := InputEventScreenTouch.new()
	touch.index = 2
	touch.position = center
	touch.pressed = true
	feed_input(touch)
	await process_frame
	check(main._dragging, "Touch starts press")
	var drag := InputEventScreenDrag.new()
	drag.index = 2
	drag.position = center + Vector2(25, 0)
	feed_input(drag)
	await process_frame
	advance(0.3)
	check(not main._stretching and blob.get_stretch_amount() == 0.0, "Single finger drag only presses")
	# Add a second contact on the visible surface, then spread both contacts.
	var second := InputEventScreenTouch.new()
	second.index = 7
	second.position = center - Vector2(25, 0)
	second.pressed = true
	feed_input(second)
	await process_frame
	advance(0.1)
	check(main._stretching and blob.get_stretch_amount() < 0.001, "Second finger starts stretch without a jump")
	var second_drag := InputEventScreenDrag.new()
	second_drag.index = 7
	second_drag.position = second.position + Vector2(0, 30)
	drag.position += Vector2(0, 30)
	feed_input(drag)
	feed_input(second_drag)
	await process_frame
	advance(0.2)
	check(blob.get_stretch_amount() < 0.001, "Moving two fingers together does not stretch")
	drag.position += Vector2(180, 0)
	second_drag.position -= Vector2(180, 0)
	feed_input(drag)
	feed_input(second_drag)
	await process_frame
	advance(0.3)
	check(main._stretching and blob.get_stretch_amount() > 0.5, "Spreading two fingers stretches beyond silhouette")
	# Bring both contacts back over the surface before testing either lift order.
	drag.position = center + Vector2(25, 0)
	second_drag.position = center - Vector2(25, 0)
	feed_input(drag)
	feed_input(second_drag)
	await process_frame
	advance(0.5)
	touch.pressed = false
	feed_input(touch)
	await process_frame
	check(not main._stretching and main._active_touch_id == 7, "Lifting first finger leaves second in press mode")
	second.pressed = false
	feed_input(second)
	await process_frame
	check(not main._dragging and main._active_touch_id == -1, "Final touch release clears capture")
	blob.reset_deformation()
	touch.pressed = true
	feed_input(touch)
	second.pressed = true
	feed_input(second)
	await process_frame
	second.pressed = false
	feed_input(second)
	await process_frame
	check(not main._stretching and main._active_touch_id == 2, "Lifting second finger leaves first in press mode")
	touch.pressed = false
	feed_input(touch)
	await process_frame
	await check_press_feel()
	check_neck_profile()
	await check_rebound()
	for recovery in [0.3, 4.0]:
		blob.recovery_time = recovery
		blob.elasticity = 1.0
		blob.initial_bounce = 0.6
		blob.max_stretch = 3.6
		blob.reset_deformation()
		var hit: Dictionary = main._raycast_blob(screen_point())
		blob.begin_interaction(hit.position, true, hit.rest_point, hit.local_normal)
		blob.update_interaction(hit.position + Vector3(10, 10, 0))
		advance(0.4)
		blob.end_interaction()
		advance(recovery * 8.0)
		check(max_offset() < 0.001, "Recovery stable at extreme parameters: " + str(recovery))
	print("DEFORMATION TESTS: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(0 if failures == 0 else 1)
