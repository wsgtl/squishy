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
	check(blob._anchor_point.distance_to(target) < 0.000001, "Dent reaches latest pointer position in one frame")
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

func check_floor_safety() -> void:
	main._finish_gesture()
	blob.reset_deformation()
	var floor_y: float = blob._model_center.y - blob._model_size.y * 0.5
	var safe := true
	var retained := true
	for direction in [Vector3.RIGHT, Vector3.FORWARD, Vector3(1, 0, -1).normalized()]:
		for strength in [1.2, 2.4, 3.6, -1.2]:
			blob._smooth_pull = direction * blob._model_radius * strength
			blob._stretch_recovering = true
			blob._rebound_axis = direction
			for point in blob._rest_positions:
				var deformed: Vector3 = point + blob._target_offset_for(point)
				safe = safe and deformed.y >= floor_y - 0.000001
				if point.y > blob._model_center.y:
					retained = retained and deformed.y - floor_y >= (point.y - floor_y) * 0.149
	check(safe, "Forward, sideways, diagonal stretch and recoil stay above the base")
	check(retained, "Upper surface retains thickness instead of collapsing onto the floor")
	var world_floor: float = blob._external_mesh_instance.to_global(Vector3(0, floor_y, 0)).y
	check(world_floor > main._board.position.y + main._board.mesh.height * 0.5 + 0.001, "Model and board retain a small depth separation")
	blob.reset_deformation()
	var point := screen_point()
	main._begin_pointer(point, true, MOUSE_BUTTON_LEFT)
	main._move_pointer(point + Vector2(0, 280))
	advance(0.5)
	check(absf(blob._pull_offset.y) < 0.000001 and absf(blob._pull_offset.z) > blob._model_radius * 0.1, "Forward mouse gesture stays in table plane")
	await screenshot("forward-stretch")
	main._finish_gesture()
	advance(5.0)

func check_press_trail() -> void:
	blob.reset_deformation()
	var node: Node3D = blob._external_mesh_instance
	var top: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.45
	var start := top - Vector3.RIGHT * blob._model_radius * 0.4
	blob.begin_interaction(node.to_global(start), false, start, Vector3.UP)
	advance(1.7)
	var original_normal: Vector3 = blob._normal_target
	for i in range(36):
		var target := start + Vector3.RIGHT * blob._model_radius * (float(i) / 35.0) * 0.8
		blob.update_press(target, Vector3.RIGHT if i > 18 else Vector3.UP)
		blob._physics_process(1.0 / 60.0)
	check(blob._normal_target.dot(original_normal) > 0.999, "Crossing edge normals does not flip press direction")
	check(blob._trail_points.size() > 0 and blob._trail_points.size() <= blob.MAX_TRAILS, "Drag retains bounded continuous segments")
	var old_point: Vector3 = blob._trail_points[0]
	var remaining := blob._target_offset_for(old_point).length()
	check(remaining > blob._model_radius * 0.04, "Departed press positions retain visible deformation")
	# A straight stroke has one capsule, so even between former stamp positions
	# there are no alternating shallow gaps. Disable global squash to isolate it.
	var previous_squash: float = blob.squash_strength
	blob.squash_strength = 0.0
	var previous_depth := -blob._trail_offset_at(start, 0).y
	var continuous := true
	for sample in range(1, 41):
		var point := start.lerp(blob._anchor_point, sample / 40.0)
		var depth := -blob._trail_offset_at(point, 0).y
		continuous = continuous and depth >= previous_depth - 0.00001
		previous_depth = depth
	check(continuous and blob._trail_points.size() == 1, "Straight drag forms a continuous trough without scalloped gaps")
	blob.squash_strength = previous_squash
	await screenshot("press-trail")
	blob.end_interaction()
	var initial_peak: float = blob._trail_peak()
	advance(0.4)
	check(blob._trail_peak() > 0.01 and blob._trail_peak() < initial_peak, "Released trail recovers gradually rather than snapping")
	advance(6.0)
	check(blob._trail_points.is_empty() and max_offset() < 0.001, "Press trails completely recover and go idle")
	# Isolate a fading trail, including its rim: passing the former denominator
	# and trail-culling thresholds must not change the decay rate or erase it.
	blob._add_press_trail(start, top, Vector3.UP, 1.0)
	var probes := [start, start.lerp(top, 0.5), start + Vector3.FORWARD * blob._model_radius * blob.finger_width * 2.0]
	var reference: Array[Vector3] = []
	for point in probes:
		reference.append(blob._target_offset_for(point))
	var proportional := true
	for strength in [0.1, 0.01, 0.001, 0.00051, 0.00049, 0.0001, 0.00001]:
		blob._trail_amounts[0] = strength
		blob._trail_end_amounts[0] = strength
		for i in range(probes.size()):
			var actual: Vector3 = blob._target_offset_for(probes[i])
			# Floor resistance is nonlinear at full depth, so compare raw input
			# recovered from that mapping for the vertical component.
			var height: float = probes[i].y - (blob._model_center.y - blob._model_size.y * 0.5)
			var raw := actual.y
			var base := reference[i].y
			if base < 0.0:
				raw = height * 0.85 * log(1.0 + raw / (height * 0.85))
				base = height * 0.85 * log(1.0 + base / (height * 0.85))
			proportional = proportional and absf(raw / strength - base) < blob._model_radius * 0.001
	check(proportional, "Trail center and rim fade proportionally through former cutoff thresholds")
	blob.reset_deformation()
	# Large per-frame motion must be swept all the way to the latest contact.
	blob.begin_interaction(node.to_global(start), false, start, Vector3.UP)
	check(blob._press_amount >= 0.2, "Touch-down has immediate visible pressure")
	check(blob._squash_amount == 0.0, "Touch-down does not instantly compress the whole model")
	blob._physics_process(1.0 / 60.0)
	check(blob._squash_amount > 0.0 and blob._squash_amount < blob._press_amount * 0.1, "Body compression eases in gradually from the first frame")
	advance(1.7)
	var finish := start + Vector3.RIGHT * blob._model_radius * 1.1
	blob.update_press(finish, Vector3.UP)
	blob._physics_process(1.0 / 60.0)
	check(blob._anchor_point.distance_to(finish) < 0.000001, "Fast drag has no radius-dependent tracking lag")
	check(-blob._trail_offset_at(start.lerp(finish, 0.5), 0).y > blob._model_radius * 0.1, "Fast drag fills the full swept segment")
	blob.end_interaction()
	var old_count: int = blob._trail_points.size()
	var new_start := top + Vector3.FORWARD * blob._model_radius * 0.5
	blob.begin_interaction(node.to_global(new_start), false, new_start, Vector3.UP)
	blob.update_press(new_start + Vector3.RIGHT * 0.05, Vector3.UP)
	blob._physics_process(1.0 / 60.0)
	check(blob._trail_points.size() == old_count + 1 and blob._trail_points[old_count].distance_to(new_start) < 0.000001, "Separate presses never bridge unrelated strokes")
	blob.reset_deformation()
	# Capacity rollover must retain the oldest segment at full visibility on
	# entry, then retire it continuously instead of dropping it in one frame.
	for segment in range(blob.ACTIVE_TRAILS):
		blob._stroke_has_segment = false
		blob._trail_sample_elapsed = 1.0
		var point := start + Vector3.FORWARD * segment * blob._model_radius * 0.1
		blob._add_press_trail(point, point + Vector3.RIGHT * 0.05, Vector3.UP, 1.0)
	var oldest: Vector3 = blob._trail_points[0]
	var before: Vector3 = blob._trail_offset_at(oldest, 0)
	blob._stroke_has_segment = false
	blob._trail_sample_elapsed = 1.0
	blob._add_press_trail(top, top + Vector3.RIGHT * 0.05, Vector3.UP, 1.0)
	check(blob._trail_points.size() == blob.ACTIVE_TRAILS + 1 and blob._trail_points[0] == oldest and blob._trail_offset_at(oldest, 0).distance_to(before) < 0.000001, "Capacity rollover preserves the visible oldest trail without a jump")
	var smooth_retirement := true
	var previous_visibility := 1.0
	for step in range(1, 61):
		blob._trail_retire_times[0] = blob._trail_retire_duration() * step / 60.0
		var visibility: float = blob._trail_visibility(0)
		smooth_retirement = smooth_retirement and visibility <= previous_visibility and previous_visibility - visibility < 0.026
		previous_visibility = visibility
	check(smooth_retirement and previous_visibility < 0.000001, "Retired trail fades continuously to zero before deletion")
	blob.reset_deformation()
	# Repeated circular strokes on one face must stay bounded and finite.
	blob.begin_interaction(node.to_global(top), false, top, Vector3.UP)
	var no_visible_eviction := true
	for frame in range(720):
		var old_points: PackedVector3Array = blob._trail_points.duplicate()
		var old_visibility: Array[float] = []
		for index in range(old_points.size()):
			old_visibility.append(blob._trail_visibility(index))
		var angle := frame * TAU / 60.0
		blob.update_press(top + Vector3(cos(angle), 0.0, sin(angle)) * blob._model_radius * 0.18, Vector3.UP)
		blob._physics_process(1.0 / 60.0)
		for index in range(old_points.size()):
			if not blob._trail_points.has(old_points[index]):
				no_visible_eviction = no_visible_eviction and old_visibility[index] < 0.01
	check(no_visible_eviction and blob._trail_points.size() <= blob.MAX_TRAILS, "Continuous circles only remove fully faded history within the slot budget")
	var bounded := true
	var smooth_field := true
	var epsilon: float = blob._model_radius * 0.0001
	for sample in range(121):
		var point := top + Vector3.RIGHT * blob._model_radius * (sample / 120.0 - 0.5)
		var offset: Vector3 = blob._target_offset_for(point)
		bounded = bounded and offset.is_finite() and -offset.y <= blob._model_size.y * 0.55
		var neighbor: Vector3 = blob._target_offset_for(point + Vector3.RIGHT * epsilon)
		smooth_field = smooth_field and offset.distance_to(neighbor) < epsilon * 5.0
	check(bounded and blob._press_amount <= 1.0, "Twelve circular strokes cannot accumulate excessive depth")
	check(smooth_field, "Overlapping trails have no displacement jumps that spike normals")
	await screenshot("circular-press")
	blob.reset_deformation()
	check(absf(blob.finger_width - 0.23 * 0.6) < 0.00001, "Default finger radius is reduced by 40 percent")

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
		rotation_centered = rotation_centered and mesh_node.to_global(blob._model_center).distance_to(pivot_center) < main.MODEL_WIDTH * 0.001
		rotation_pickable = rotation_pickable and not main._raycast_blob(screen_point()).is_empty()
	main._model_root.rotation = original_rotation
	check(rotation_centered, "Authored pivot keeps rotation drift below 0.1 percent of model width")
	check(rotation_pickable, "Rotated mooncake remains pickable")
	await screenshot("rest")
	mouse_button(center, true)
	await process_frame
	check(main._dragging and not main._stretching, "Left press reaches scene through HUD")
	advance(0.35)
	check(max_offset() > blob._model_radius * 0.035, "Press produces visible indentation")
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
	check(absf(blob._pull_offset.z) > blob._model_radius * 0.1 and absf(blob._pull_offset.y) < 0.00001, "Screen forward drag stretches along table without downward displacement")
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
	await check_floor_safety()
	await check_press_trail()
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
