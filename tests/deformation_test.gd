extends SceneTree

# Desktop hardware events must not alter synthetic Shift/touch sequences.
class SyntheticInputFilter extends Node:
	func _input(event: InputEvent) -> void:
		if event.device != 42 and event.device != InputEvent.DEVICE_ID_EMULATION:
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
	if blob.raised_rim_press:
		check(medium > shallow * 1.2 and deep >= medium and blob._press_amount > 0.99, "Gathering press deepens quickly and saturates at full pressure")
	else:
		check(medium > shallow * 1.2 and deep > medium * 1.2, "Holding progressively deepens the dent")
	await screenshot("long-press")
	advance(2.0)
	check(absf(max_offset() - deep) < 0.005, "Long hold saturates at bounded depth")
	var far_point := blob._model_center + Vector3(blob._model_radius * 0.9, blob._model_size.y * 0.4, 0.0)
	var far_offset := blob._target_offset_for(far_point)
	if blob.raised_rim_press:
		check(far_offset.x < 0.0, "Gathering press pulls the outer body toward the contact")
	else:
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
	var raised := false
	var base_fixed := false
	var domed := false
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
				var top := blob._model_center + Vector3.UP * blob._model_size.y * 0.5
				var bottom := blob._model_center - Vector3.UP * blob._model_size.y * 0.5
				raised = blob._target_offset_for(top).y > blob._model_size.y * 0.15
				var center_rise: float = blob._target_offset_for(top).y
				domed = true
				for horizontal in [Vector3.RIGHT, Vector3.FORWARD]:
					var extent: float = blob._model_size.x * 0.5 if horizontal == Vector3.RIGHT else blob._model_size.z * 0.5
					var middle_rise: float = blob._target_offset_for(top + horizontal * extent * 0.5).y
					var edge_rise: float = blob._target_offset_for(top + horizontal * extent).y
					domed = domed and center_rise > middle_rise and middle_rise > edge_rise and absf(edge_rise) < 0.000001
				base_fixed = absf(blob._target_offset_for(bottom).y) < 0.000001
			if save_images and peaks.size() <= 3:
				await screenshot("rebound-" + str(peaks.size()))
		falling = amount < previous
		previous = amount
	return {"peaks": peaks, "shortened": shortened, "thickened": thickened, "raised": raised, "base_fixed": base_fixed, "domed": domed}

func check_rebound() -> void:
	var short_pull: Dictionary = await measure_rebound(0.8)
	var long_pull: Dictionary = await measure_rebound(2.4, true)
	var peaks: Array = long_pull.peaks
	check(peaks.size() >= 3, "Stretch release produces at least three compression rebounds")
	if peaks.size() >= 3:
		check(peaks[0] > peaks[1] and peaks[1] > peaks[2] and peaks[2] > 0.04, "Three visible rebound peaks progressively decay")
		check(not short_pull.peaks.is_empty() and peaks[0] > short_pull.peaks[0] * 2.5, "Longer stretch produces proportionally stronger rebound")
	check(long_pull.shortened and long_pull.thickened, "Rebound overshoots into shorter and thicker than rest")
	check(long_pull.domed, "Recoil height peaks at center and tapers smoothly to both horizontal rims")
	check(long_pull.raised and long_pull.base_fixed, "Recoil thickens upward while the bottom height stays fixed")
	check(max_offset() < 0.001, "Multiple rebounds eventually settle at original shape")

func check_press_directional_rebound() -> void:
	var peaks: Array[float] = []
	for mode in [false, true]:
		blob.set_raised_rim_press(mode)
		for hold in [0.12, 1.8]:
			blob.reset_deformation()
			var point: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.45
			blob.begin_interaction(blob._external_mesh_instance.to_global(point), false, point, Vector3.UP)
			blob.update_press(point + Vector3.FORWARD * blob._model_radius * 0.1, Vector3.UP)
			advance(hold)
			var before: Vector3 = blob._smooth_pull
			blob.end_interaction()
			check(blob._smooth_pull.distance_to(before) < 0.000001, "Press release starts rebound without a displacement jump")
			var compression := 0.0
			var expansion := 0.0
			for frame in range(240):
				blob._physics_process(1.0 / 120.0)
				var amount: float = blob._signed_stretch() / blob._model_radius
				compression = maxf(compression, -amount)
				expansion = maxf(expansion, amount)
			check(compression > 0.005 and compression < 0.13 and expansion > 0.001 and expansion < compression, "Press produces small compression and weaker opposite rebound in both modes")
			check(blob._rebound_axis.dot(Vector3.FORWARD) > 0.99, "Press rebound follows the last drag direction")
			peaks.append(compression)
			advance(6.0)
			check(max_offset() < 0.001, "Directional press rebound settles fully")
	check(peaks[1] > peaks[0] and peaks[3] > peaks[2], "Deeper presses produce stronger directional rebound")
	blob.set_raised_rim_press(true)
	blob.reset_deformation()

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
	check(world_floor > main._get_model_aabb(main._board).end.y + 0.001, "Model and board retain a small depth separation")
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
	await check_reset_then_stretch()
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
	var feel_switch := main.find_child("RaisedRimPressSwitch", true, false) as CheckButton
	check(feel_switch != null and feel_switch.button_pressed, "Parameter panel exposes the new press feel switch")
	var feel_center: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.45
	var sigma: float = blob._model_radius * blob.finger_width * (0.85 + blob.softness * 0.25)
	var surrounding: Vector3 = blob._dent_at(feel_center + Vector3.RIGHT * sigma * 2.0, feel_center, Vector3.UP, 1.0)
	var outer: Vector3 = blob._dent_at(feel_center + Vector3.RIGHT * blob._model_size.x * 0.45, feel_center, Vector3.UP, 1.0)
	var base_point: Vector3 = blob._model_center - Vector3.UP * blob._model_size.y * 0.5
	check(blob._dent_at(feel_center, feel_center, Vector3.UP, 1.0).y < 0.0 and surrounding.x < 0.0, "New press gathers surrounding material toward the depressed contact")
	check(outer.y > 0.0 and outer.x < 0.0, "Outer side curls upward while gathering inward")
	check(blob._dent_at(base_point, feel_center, Vector3.UP, 1.0).length() < 0.000001, "Gathering and curling leave the bottom fixed")
	feel_switch.button_pressed = false
	var old_rise: float = blob._dent_at(feel_center + Vector3.RIGHT * sigma * 2.0, feel_center, Vector3.UP, 1.0).y
	check(not blob.raised_rim_press and old_rise < 0.0, "Disabling switch restores the original bowl profile")
	await check_press_feel()
	feel_switch.button_pressed = true
	await check_press_feel()
	check_neck_profile()
	await check_rebound()
	check_press_directional_rebound()
	await check_floor_safety()
	await check_press_trail()
	blob.reset_deformation()
	var grab_top: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.5
	var grab_a := grab_top - Vector3.RIGHT * blob._model_radius * 0.4
	var grab_b := grab_top + Vector3.RIGHT * blob._model_radius * 0.4
	blob.begin_interaction(blob._external_mesh_instance.to_global(grab_a), true, grab_a, Vector3.UP)
	blob.set_stretch_contacts(grab_a, Vector3.UP, grab_b, Vector3.UP)
	advance(0.3)
	check(blob._target_offset_for(grab_a).y < -blob._model_radius * 0.03 and blob._target_offset_for(grab_b).y < -blob._model_radius * 0.03, "Both stretch contacts visibly indent the surface")
	blob.end_interaction()
	advance(0.5)
	check(blob._grab_pressure < 0.001, "Stretch contact dents fade smoothly after release")
	blob.reset_deformation()
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
	await check_grip()
	await check_modals()
	await check_touch_ui()
	await check_doodle()
	await check_scene_capture()
	print("DEFORMATION TESTS: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(0 if failures == 0 else 1)

func check_doodle_opacity() -> void:
	var canvas = load("res://scripts/doodle_canvas.gd").new()
	var uv := Vector2(0.5, 0.5)
	var pixel := Vector2i(511, 511)
	for opacity in [0.2, 0.5, 0.8]:
		canvas.clear()
		canvas.color = Color(0.8, 0.1, 0.2, opacity)
		canvas.begin_stroke()
		for i in range(30):
			canvas.stamp(uv + Vector2(float(i % 3) / 1024.0, 0.0))
		check(absf(canvas.image.get_pixelv(pixel).a - opacity) < 0.005, "Overlapping samples preserve stroke opacity: " + str(opacity))
		canvas.end_stroke()
		canvas.begin_stroke()
		canvas.stamp(uv)
		canvas.end_stroke()
		check(absf(canvas.image.get_pixelv(pixel).a - (1.0 - pow(1.0 - opacity, 2))) < 0.01, "Separate strokes still layer opacity: " + str(opacity))
	canvas.begin_stroke()
	canvas.stamp(uv)
	canvas.clear()
	check(canvas.image.get_pixelv(pixel).a == 0.0 and canvas._stroke_base.is_empty(), "Clear discards active stroke coverage")

func check_stickers() -> void:
	main._set_doodle_enabled(true)
	main._doodle.clear()
	var blank: PackedByteArray = main._doodle.image.get_data()
	var button := main.find_child("DoodleStickerButton", true, false) as Button
	var slider := main.find_child("DoodleSizeSlider", true, false) as VSlider
	var eraser := main.find_child("DoodleEraserSwitch", true, false) as CheckButton
	eraser.button_pressed = true
	button.button_pressed = true
	check(main._sticker_enabled and not main._doodle.erasing and slider.value == 220, "Sticker selection exits eraser and exposes independent size")
	slider.value = 180
	var center := screen_point()
	mouse_button(center, true)
	await process_frame
	main._refresh_sticker_preview()
	var before: PackedByteArray = main._doodle.image.get_data()
	check(main._drawing and not main._dragging and before != blank, "Click on model places bundled PNG without deformation")
	motion(center + Vector2(50, 0))
	mouse_button(center + Vector2(50, 0), false)
	await process_frame
	main._refresh_sticker_preview()
	check(main._sticker_pending and main._doodle.image.get_data() != before, "Dragging moves the pending sticker without baking trails")
	var moved: PackedByteArray = main._doodle.image.get_data()
	var rotation := main.find_child("StickerRotationSlider", true, false) as HSlider
	rotation.value = 45
	main._refresh_sticker_preview()
	check(main._doodle.image.get_data() != moved, "Rotation slider transforms the pending sticker")
	slider.value = 240
	main._refresh_sticker_preview()
	var edited: PackedByteArray = main._doodle.image.get_data()
	main._confirm_sticker()
	check(not main._sticker_pending and main._sticker_undo != null, "Confirm commits an editable sticker and records undo")
	main._edit_last_sticker()
	rotation.value = 90
	main._refresh_sticker_preview()
	main._cancel_sticker()
	check(main._doodle.image.get_data() == edited, "Cancel re-edit restores the confirmed sticker exactly")
	main._edit_last_sticker()
	rotation.value = -30
	main._refresh_sticker_preview()
	main._confirm_sticker()
	check(main._doodle.image.get_data() != edited, "Confirmed sticker can be re-edited without duplicating it")
	main._undo_sticker()
	check(main._doodle.image.get_data() == blank, "Undo restores the exact canvas before the sticker")
	main._begin_drawing(center, -1)
	main._refresh_sticker_preview()
	main._finish_gesture()
	main._cancel_sticker()
	check(main._doodle.image.get_data() == blank, "Cancel pending placement leaves no ink")
	slider.value = 180
	main._begin_drawing(center, -1)
	main._refresh_sticker_preview()
	main._finish_gesture()
	await screenshot("doodle-sticker")
	button.button_pressed = false
	check(slider.max_value == 48 and main._doodle.radius * 2.0 == slider.value, "Returning to brush restores its width range")
	button.button_pressed = true
	check(slider.value == 180, "Sticker width is remembered independently")
	eraser.button_pressed = true
	check(not main._sticker_enabled and main._doodle.erasing, "Eraser exits sticker mode")
	eraser.button_pressed = false
	main._doodle.clear()
	main._set_doodle_enabled(false)
	main._process(main.CAMERA_RETURN_DURATION)
	var canvas = load("res://scripts/doodle_canvas.gd").new()
	var source := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	source.fill(Color(1, 0, 0, 0.5))
	canvas.place_sticker(Vector2(0.5, 0.5), source, 32)
	check(absf(canvas.image.get_pixel(512, 512).a - 0.5) < 0.01, "Sticker keeps source opacity independently of brush color")
	check(canvas.image.get_pixel(512, 525).a == 0.0, "Sticker preserves aspect ratio and untouched surroundings")
	canvas.place_sticker(Vector2.ZERO, source, 32)
	canvas.place_sticker(Vector2.ONE, source, 32)
	check(canvas.dirty, "Sticker placements clip safely at texture edges")

func check_doodle() -> void:
	await check_stickers()
	check_doodle_opacity()
	main._set_doodle_enabled(true)
	var center := screen_point()
	var hit: Dictionary = main._raycast_blob(center, true)
	check(hit.has("uv"), "Surface picking exposes interpolated UV for painting")
	mouse_button(center, true)
	await process_frame
	check(main._drawing and not main._dragging, "Doodle mouse down paints without pressing")
	motion(center + Vector2(65, 0))
	await process_frame
	mouse_button(center + Vector2(65, 0), false)
	await process_frame
	var uv: Vector2 = hit.uv
	var pixel := Vector2i(uv * float(main._doodle.SIZE - 1))
	check(main._doodle.image.get_pixelv(pixel).a > 0.9, "Black ink reaches the picked surface UV")
	check(not main._drawing and max_offset() < 0.00001, "Doodle release leaves the model undeformed")
	var touch := InputEventScreenTouch.new()
	touch.index = 7
	touch.position = center + Vector2(-40, -30)
	touch.pressed = true
	feed_input(touch)
	await process_frame
	check(main._drawing and main._drawing_touch == 7, "Finger starts a doodle stroke")
	var drag := InputEventScreenDrag.new()
	drag.index = 7
	drag.position = center + Vector2(-40, 30)
	feed_input(drag)
	await process_frame
	touch.position = drag.position
	touch.pressed = false
	feed_input(touch)
	await process_frame
	check(not main._drawing and not main._stretching, "Finger drawing releases without triggering stretch")
	await screenshot("doodle")
	main._set_doodle_enabled(false)
	mouse_button(center, true, MOUSE_BUTTON_LEFT, true)
	await process_frame
	motion(center + Vector2(160, 0), true)
	await process_frame
	advance(0.3)
	check(main._stretching and max_offset() > 0.01, "Exiting doodle restores stretch interaction")
	check(main._doodle.image.get_pixelv(pixel).a > 0.9, "Ink persists during deformation")
	await screenshot("doodle-stretch")
	mouse_button(center + Vector2(160, 0), false)
	await process_frame
	main._doodle.clear()
	main._doodle.flush()
	check(main._doodle.image.get_pixelv(pixel).a == 0.0, "Clear removes ink without changing model material")
	var slider := main.find_child("DoodleSizeSlider", true, false) as VSlider
	var picker := main.find_child("DoodleColorPicker", true, false) as ColorPickerButton
	slider.value = 32
	picker.color = Color.RED
	picker.color_changed.emit(Color.RED)
	main._doodle.stamp(Vector2(0.5, 0.5))
	check(main._doodle.radius == 16.0 and main._doodle.image.get_pixel(525, 511).a > 0.9, "Brush size slider changes painted footprint")
	check(main._doodle.image.get_pixel(511, 511).r > 0.99, "Color picker changes painted ink")
	var simple_picker := picker.get_picker()
	check(simple_picker.edit_alpha and not simple_picker.sampler_visible and not simple_picker.color_modes_visible and not simple_picker.hex_visible and not simple_picker.presets_visible, "Mobile picker shows square and RGBA without advanced controls")
	picker.color_changed.emit(Color.BLUE)
	main._doodle.stamp(Vector2(0.5, 0.5))
	check(main._doodle.image.get_pixel(511, 511).b > 0.99 and main._doodle.image.get_pixel(511, 511).r < 0.01, "New brush color paints over existing opaque ink")
	var eraser := main.find_child("DoodleEraserSwitch", true, false) as CheckButton
	eraser.button_pressed = true
	check(slider.value == 30 and main._doodle.radius == 15.0, "Eraser defaults to size 30 independently of brush")
	slider.value = 10
	main._doodle.stamp(Vector2(0.5, 0.5))
	check(main._doodle.image.get_pixel(511, 511).a == 0.0, "Eraser removes ink coverage to reveal the original material")
	check(main._doodle.image.get_pixel(525, 511).a > 0.9, "Eraser preserves ink outside its selected radius")
	eraser.button_pressed = false
	check(slider.value == 32 and main._doodle.radius == 16.0, "Returning to brush restores its previous size")
	eraser.button_pressed = true
	check(slider.value == 10 and main._doodle.radius == 5.0, "Returning to eraser restores its adjusted size")
	eraser.button_pressed = false
	main._doodle.stamp(Vector2(0.5, 0.5))
	check(main._doodle.image.get_pixel(511, 511).b > 0.99 and main._doodle.image.get_pixel(511, 511).a > 0.99, "Switching back to brush restores the selected color")
	main._doodle.clear()
	picker.color_changed.emit(Color(1, 0, 0, 0.25))
	main._doodle.stamp(Vector2(0.5, 0.5))
	check(absf(main._doodle.image.get_pixel(511, 511).a - 0.25) < 0.01, "Brush uses the selected opacity")
	main._doodle.clear()
	slider.value = 10
	picker.color_changed.emit(Color.BLACK)
	blob.reset_deformation()

func check_modals() -> void:
	main._toggle_param_panel()
	await process_frame
	await process_frame
	check(main._param_panel.size == Vector2(root.size), "Parameter modal covers the entire viewport")
	await screenshot("parameter-modal")
	mouse_button(Vector2(10, 110), true)
	await process_frame
	mouse_button(Vector2(10, 110), false)
	await process_frame
	check(not main._param_panel.visible and not main._dragging and not main._is_rotating, "Backdrop dismisses parameters without starting a model gesture")
	main._set_doodle_enabled(true)
	await process_frame
	await process_frame
	check(main._doodle_panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Doodle toolbars leave the model available for drawing")
	await screenshot("doodle-toolbar")
	var color_button := main.find_child("DoodleColorPicker", true, false) as ColorPickerButton
	color_button.get_popup().popup_centered()
	await process_frame
	await screenshot("doodle-color-picker")
	color_button.get_popup().hide()
	var zoom := main.find_child("DoodleZoomSlider", true, false) as VSlider
	var mode := main.find_child("DoodleViewModeButton", true, false) as Button
	var initial_camera: float = main._camera.position.distance_to(main._look_at_target)
	zoom.value = 2.0
	check(absf(main._camera.position.distance_to(main._look_at_target) * 2 - initial_camera) < 0.0001, "Zoom slider doubles model display size by halving camera distance")
	var zoom_hit: Dictionary = main._raycast_blob(screen_point(), true)
	check(not zoom_hit.is_empty() and main._begin_drawing(screen_point(), -1), "Zoomed model remains paintable at the picked UV")
	main._finish_gesture()
	main._doodle.clear()
	zoom.value = 1.0
	check(main.find_child("DoodleRotationSlider", true, false) == null, "Bottom rotation slider is removed")
	mode.button_pressed = true
	check(zoom.min_value == 0 and zoom.max_value == 90, "View mode covers level to top-down")
	zoom.value = 0
	check(absf(main._camera.position.y - main._look_at_target.y) < 0.0001, "View slider reaches level view")
	zoom.value = 90
	check(main._camera.global_basis.is_finite() and (main._camera.position - main._look_at_target).normalized().dot(Vector3.UP) > 0.999, "Top-down camera stays valid at ninety degrees")
	await screenshot("doodle-top-view")
	mode.button_pressed = false
	check(zoom.value == 1 and is_equal_approx(main._doodle_elevation, PI * 0.5), "Switching to zoom preserves angle and previous zoom")
	mode.button_pressed = true
	check(zoom.value == 90, "Switching back restores previous angle")
	zoom.value = rad_to_deg(main._camera_polar)
	mode.button_pressed = false
	var eye := main.find_child("DoodleVisibilityButton", true, false) as Button
	eye.button_pressed = true
	check(is_equal_approx(main.find_child("LeftDoodleToolbar", true, false).modulate.a, 0.2) and eye.modulate.a == 1, "Eye button dims tools while keeping itself visible")
	check(mode.mouse_filter == Control.MOUSE_FILTER_IGNORE and not zoom.editable and zoom.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Faded sliders ignore input and cannot be dragged")
	check(not main._over_doodle_controls(zoom.get_global_rect().get_center()), "Faded tool areas allow painting through them")
	await screenshot("doodle-toolbar-dimmed")
	eye.button_pressed = false
	check(mode.mouse_filter != Control.MOUSE_FILTER_IGNORE and zoom.editable, "Eye button restores slider interaction")
	var card := main.find_child("LeftDoodleToolbar", true, false) as Control
	mouse_button(card.get_global_rect().position + Vector2(5, 5), true)
	await process_frame
	check(not main._drawing and not main._dragging and not main._is_rotating, "Toolbar background blocks model gestures")
	mouse_button(card.get_global_rect().position + Vector2(5, 5), false)
	await process_frame
	zoom.value = 1.8
	mode.button_pressed = true
	zoom.value = 10
	var exit_position: Vector3 = main._camera.position
	main._set_doodle_enabled(false)
	check(main._camera.position.distance_to(exit_position) < 0.0001 and main._camera_returning, "Exiting doodle starts camera return without jumping")
	main._process(main.CAMERA_RETURN_DURATION * 0.5)
	check(main._camera_returning and main._camera.position.distance_to(exit_position) > 0.01, "Camera angle and distance interpolate during return")
	main._process(main.CAMERA_RETURN_DURATION)
	check(zoom.value == 1 and main._doodle_zoom == 1 and absf(main._camera.position.distance_to(main._look_at_target) - initial_camera) < 0.0001, "Exiting doodle restores the normal camera size and zoom control")

func touch_event_at(point: Vector2, pressed: bool) -> void:
	var touch := InputEventScreenTouch.new()
	touch.index = 0
	touch.position = point
	touch.pressed = pressed
	feed_input(touch)

func touch_drag_to(point: Vector2, relative: Vector2) -> void:
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = point
	drag.relative = relative
	feed_input(drag)

func check_touch_ui() -> void:
	main._toggle_param_panel()
	await process_frame
	await process_frame
	var content: ScrollContainer = main._param_panel.get_meta("content")
	var parameter_slider := content.find_children("*", "HSlider", true, false)[0] as HSlider
	var parameter_rect := parameter_slider.get_global_rect()
	var first := Vector2(parameter_rect.position.x + parameter_rect.size.x * 0.3, parameter_rect.get_center().y)
	var last := Vector2(parameter_rect.position.x + parameter_rect.size.x * 0.7, first.y)
	var old_parameter := parameter_slider.value
	touch_event_at(first, true)
	await process_frame
	var first_value := parameter_slider.value
	touch_drag_to(last, last - first)
	await process_frame
	touch_event_at(last, false)
	await process_frame
	check(parameter_slider.value > first_value and not main._dragging and not main._is_rotating, "Real touch drags parameter slider without rotating the model")
	parameter_slider.value = old_parameter
	main._close_param_panel()
	main._set_doodle_enabled(true)
	await process_frame
	await process_frame
	var slider := main.find_child("DoodleSizeSlider", true, false) as VSlider
	var rect := slider.get_global_rect()
	var start := Vector2(rect.get_center().x, rect.position.y + rect.size.y * 0.7)
	var finish := Vector2(start.x, rect.position.y + rect.size.y * 0.25)
	touch_event_at(start, true)
	await process_frame
	var previous := slider.value
	touch_drag_to(finish, finish - start)
	await process_frame
	touch_event_at(finish, false)
	await process_frame
	check(slider.value > previous + 5 and not main._drawing and not main._dragging, "Real touch drags the brush slider without painting or pressing")
	slider.value = 10
	var button := main.find_child("DoodleColorPicker", true, false) as ColorPickerButton
	var center := button.get_global_rect().get_center()
	touch_event_at(center, true)
	await process_frame
	touch_event_at(center, false)
	await process_frame
	await process_frame
	check(button.get_popup().visible, "Real touch opens the color picker")
	var picker := button.get_picker()
	var nodes: Array[Node] = [picker]
	var channel: HSlider
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is HSlider and node.is_visible_in_tree():
			channel = node
			break
		nodes.append_array(node.get_children(true))
	check(channel != null, "Color picker exposes a visible RGBA slider for input verification")
	if channel != null:
		var before := channel.value
		var channel_rect := channel.get_global_rect()
		var local_point := Vector2(channel_rect.position.x + channel_rect.size.x * 0.35, channel_rect.get_center().y)
		# Embedded popup controls belong to their own viewport.
		var event := InputEventMouseButton.new()
		event.device = InputEvent.DEVICE_ID_EMULATION
		event.position = local_point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = true
		button.get_popup().push_input(event)
		event = event.duplicate()
		event.pressed = false
		button.get_popup().push_input(event)
		await process_frame
		check(channel.value != before, "Color picker channel responds to touch-emulated mouse input")
	button.get_popup().hide()
	button.color = Color.BLACK
	button.color_changed.emit(Color.BLACK)
	main._set_doodle_enabled(false)
	main._process(main.CAMERA_RETURN_DURATION)

func check_grip() -> void:
	blob.reset_deformation()
	var button := main.find_child("GripButton", true, false) as Button
	check(button != null and button.visible, "Grip button is available outside doodle mode")
	var point := button.get_global_rect().get_center()
	mouse_button(point, true)
	await process_frame
	advance(0.08)
	var initial := blob.grip_amount
	check(initial > 0 and initial < 0.3 and blob._grip_shake == 0.0, "Grip starts smoothly without an immediate full squeeze")
	advance(0.8)
	check(blob.grip_amount > 0.98 and blob._interaction_mode == -1, "Holding the button reaches full grip without regular press interaction")
	var top := blob._model_center + Vector3.UP * blob._model_size.y * 0.5
	var side := top + Vector3.RIGHT * blob._model_size.x * 0.4
	check(blob._target_offset_for(side).x < -blob._model_size.x * 0.14, "Grip compresses the entire middle across its width")
	var bottom := blob._model_center - Vector3.UP * blob._model_size.y * 0.5
	var lower_side := bottom + Vector3.RIGHT * blob._model_size.x * 0.4
	check(blob._target_offset_for(lower_side).x < -blob._model_size.x * 0.14 and blob._target_offset_for(bottom).y > blob._model_radius * 0.5, "Grip lifts and compresses the lower half as well as the upper half")
	var end := blob._model_center + Vector3(0, blob._model_size.y * 0.5, blob._model_size.z * 0.48)
	var middle_thickness := (top + blob._target_offset_for(top)).y - (bottom + blob._target_offset_for(bottom)).y
	check(middle_thickness < blob._model_size.y * 0.75 and blob._target_offset_for(end).y > blob._target_offset_for(top).y, "Grip pinches middle thickness and bulges both ends")
	main._update_camera_position()
	check(is_equal_approx(main._camera.global_basis.z.dot(Vector3.UP), sin(deg_to_rad(75.0))), "Grip camera transitions to an overhead view of the lifted model")
	var held_rotation: Vector3 = main._model_root.rotation
	var blocked := InputEventMouseButton.new()
	blocked.button_index = MOUSE_BUTTON_LEFT
	blocked.pressed = true
	blocked.position = Vector2(500, 200)
	main._unhandled_input(blocked)
	main._rotate_model(Vector2(100, 0))
	blocked.position = screen_point()
	blocked.shift_pressed = true
	main._unhandled_input(blocked)
	main._begin_pointer(screen_point(), false, MOUSE_BUTTON_LEFT)
	check(main._model_root.rotation.is_equal_approx(held_rotation) and not main._dragging and not main._is_rotating and blob._interaction_mode == -1, "Grip blocks rotation, ordinary press, and Shift stretching")
	var axis: Vector3 = blob._grip_axis
	var along: Vector3 = axis.cross(Vector3.UP)
	var left_point: Vector3 = blob._model_center - axis * blob._grip_width * 0.75
	var right_point: Vector3 = blob._model_center + axis * blob._grip_width * 0.75
	check(blob._grip_offset(left_point).dot(axis) > -blob._grip_offset(right_point).dot(axis) * 1.15, "Right-hand grip compresses the screen-left side more strongly")
	var four_prints := true
	for i in range(4):
		var z := -0.72 + float(i) * 0.48
		four_prints = four_prints and blob._grip_finger_profile(z) > 0.99 and blob._grip_finger_profile(z + 0.24) < 0.3
	check(four_prints, "Four rounded finger pads have separated smooth profiles")
	var top_prints := true
	for i in range(4):
		var pad_z: float = (-0.72 + float(i) * 0.48) * blob._grip_hand_half_width()
		var pad: Vector3 = blob._model_center + Vector3.UP * blob._model_size.y * 0.5 + along * pad_z
		var left_pad: Vector3 = pad - axis * blob._grip_width * 0.55 - along * blob._grip_hand_half_width() * 0.28 * 0.55
		var right_pad: Vector3 = pad + axis * blob._grip_width * 0.55 + along * blob._grip_hand_half_width() * 0.28 * 0.55
		top_prints = top_prints and grip_unrolled_height(left_pad) < blob._model_size.y * 0.40
	check(top_prints, "All four finger pads visibly indent the upper-left surface")
	var end_left: Vector3 = blob._model_center + axis * blob._grip_width * 0.5 + along * blob._grip_extent * 0.9
	var end_other: Vector3 = end_left - axis * blob._grip_width
	check((blob._grip_offset(end_left) - blob._grip_offset(end_other)).dot(axis) > blob._grip_width * 0.05, "Extruded ends widen despite the diagonal palm shear")
	var thumb_point: Vector3 = top + axis * blob._grip_width * 0.48 - along * blob._grip_hand_half_width() * 1.10
	check(grip_unrolled_height(thumb_point) < blob._model_size.y * 0.30, "Upper-right thumb deeply indents the top beyond the four-finger hand span")
	var upper: Vector3 = top + along * blob._grip_extent * 0.9
	var lower: Vector3 = top - along * blob._grip_extent * 0.9
	check((blob._grip_offset(upper) - blob._grip_offset(lower)).dot(axis) < -blob._grip_width * 0.25, "Opposing ends skew to different sides during grip")
	var vertical_peak := 0.0
	var shake_peak := 0.0
	var shake_min := 0.0
	var shake_max := 0.0
	for i in range(90):
		advance(1.0 / 60.0)
		vertical_peak = maxf(vertical_peak, absf(blob._grip_shake_vertical))
		shake_peak = maxf(shake_peak, absf(blob._grip_shake))
		shake_min = minf(shake_min, blob._grip_shake)
		shake_max = maxf(shake_max, blob._grip_shake)
	check(shake_min < 0.0 and shake_max > 0.0 and shake_peak <= blob._model_radius * 0.022, "Full grip produces bounded left/right shake")
	check(vertical_peak > 0.0 and vertical_peak <= blob._model_radius * 0.022 * 0.35, "Grip adds bounded smaller screen-vertical shake")
	var second_pose: Vector4 = blob._grip_pose_parameters(0.5)
	check(second_pose.x > second_pose.y * 2.0 and second_pose.w < second_pose.z * 0.5, "Medium grip compresses before major extrusion and torsion")
	var pose_continuous := true
	for knot in [0.25, 0.5, 0.75, 1.0]:
		pose_continuous = pose_continuous and (blob._grip_pose_parameters(knot - 0.0001) - blob._grip_pose_parameters(knot + 0.0001)).length() < 0.002
	check(pose_continuous, "All four grip stages blend continuously")
	var saved_amount: float = blob.grip_amount
	var saved_shake: float = blob._grip_shake
	for stage_index in range(1, 5):
		blob.grip_amount = stage_index * 0.25
		blob._grip_shake = 0.0
		blob._sync_gpu()
		await screenshot("grip-stage-" + str(stage_index))
	blob.grip_amount = saved_amount
	blob._grip_shake = saved_shake
	blob._sync_gpu()
	await screenshot("grip-tight")
	mouse_button(point, false)
	await process_frame
	check(not blob._grip_haptic_active, "Release immediately stops grip vibration")
	var at_release := blob.grip_amount
	advance(0.03)
	check(blob.grip_amount > 0.7 and blob.grip_amount <= at_release, "Release begins recovery continuously")
	var overshoot := false
	var grip_floor_safe := true
	for i in range(120):
		advance(1.0 / 60.0)
		overshoot = overshoot or blob.grip_amount < -0.01
		grip_floor_safe = grip_floor_safe and blob._target_offset_for(bottom).y > -blob._model_radius * 0.001
	check(grip_floor_safe, "Lifted grip lands without crossing the base during recoil")
	check(overshoot and not blob.is_gripping() and absf(blob._grip_shake) + absf(blob._grip_shake_vertical) < blob._model_radius * 0.00001, "Grip release has a decaying rebound and settles")
	var original_rotation: Vector3 = main._model_root.rotation
	var hand_span: float = blob._grip_hand_half_width()
	var mesh: Node3D = blob._external_mesh_instance
	for degrees in [0.0, 45.0, 90.0, 135.0]:
		main._model_root.rotation.y = deg_to_rad(degrees)
		blob.set_grip_axis(main._camera.global_basis.x)
		check(is_equal_approx(blob._grip_hand_half_width(), hand_span), "Hand span stays fixed after model rotation: " + str(degrees))
		blob.grip_amount = 1.0
		var local_point: Vector3 = blob._model_center + blob._grip_axis * blob._model_radius * 0.4
		var world_offset: Vector3 = mesh.global_basis * blob._grip_offset(local_point)
		check(world_offset.dot(main._camera.global_basis.x) < -0.01, "Grip stays screen-horizontal after model rotation: " + str(degrees))
		blob.cancel_grip()
	main._model_root.rotation = original_rotation
	var twist_button := main.find_child("TwistButton", true, false) as Button
	check(twist_button != null and twist_button.visible, "Twist button is available beside grip")
	mouse_button(twist_button.get_global_rect().get_center(), true)
	await process_frame
	advance(1.2)
	check(blob._twist_mode and blob.grip_amount > 0.98 and blob._grip_haptic_active, "Held twist reaches its limit and activates shake haptics")
	var twist_axis: Vector3 = blob._twist_axis
	var expected_twist_axis := Vector3.RIGHT if blob._model_size.x >= blob._model_size.z else Vector3.FORWARD
	check(absf(twist_axis.dot(expected_twist_axis)) > 0.999, "Twist turns the two short ends around the model long axis")
	var radial: Vector3 = Vector3.UP * blob._model_size.y * 0.4
	var a: Vector3 = blob._model_center + twist_axis * blob._twist_extent * 0.8 + radial
	var b: Vector3 = blob._model_center - twist_axis * blob._twist_extent * 0.8 + radial
	var twist_side: Vector3 = twist_axis.cross(Vector3.UP)
	check((blob._grip_offset(a) - blob._grip_offset(b)).dot(twist_side) * blob._twist_direction > 0.01, "Twist rotates the two ends in opposing directions")
	main._model_root.rotate_y(0.7)
	check(blob._twist_axis.is_equal_approx(twist_axis), "Twist axis remains bound to model coordinates")
	main._model_root.rotation = original_rotation
	await screenshot("twist-tight")
	mouse_button(twist_button.get_global_rect().get_center(), false)
	await process_frame
	check(not blob._grip_haptic_active and not blob._grip_held, "Twist release immediately stops vibration")
	advance(2.2)
	check(not blob.is_gripping(), "Twist settles after release")
	main._set_doodle_enabled(true)
	check(not button.visible and not twist_button.visible and not blob._grip_held, "Doodle mode hides and cancels grip")
	main._set_doodle_enabled(false)
	main._process(main.CAMERA_RETURN_DURATION)

# Remove the known palm roll/shear to measure the actual contact dents.
func grip_unrolled_height(p: Vector3) -> float:
	var c: Vector3 = p - blob._model_center
	var along: Vector3 = blob._grip_axis.cross(Vector3.UP)
	var z: float = c.dot(along)
	var pose: Vector4 = blob._grip_pose_parameters(blob.grip_amount)
	var roll: float = 0.24 * clampf(z / blob._grip_hand_half_width(), -1.0, 1.0) * pose.w
	var d: Vector3 = c + blob._grip_offset(p)
	var x: float = d.dot(blob._grip_axis) - blob._grip_shake + blob._grip_width * 0.20 * z / blob._grip_extent * pose.w
	var y: float = d.y - blob._model_radius * 1.8 * smoothstep(0.0, 1.0, blob.grip_stage)
	return -sin(roll) * x + cos(roll) * y

func check_reset_then_stretch() -> void:
	for after_doodle in [false, true]:
		if after_doodle:
			main._set_doodle_enabled(true)
			main._set_doodle_enabled(false)
			main._process(main.CAMERA_RETURN_DURATION)
		blob.reset_deformation()
		check(blob._shader_material.get_shader_parameter("stretch_axis").is_equal_approx(Vector3.RIGHT), "Reset uploads a valid nonzero stretch axis")
		var hit: Dictionary = main._raycast_blob(screen_point(), true)
		blob.begin_interaction(hit.position, true, hit.rest_point, hit.local_normal)
		check(blob._shader_material.get_shader_parameter("anchor_point").is_equal_approx(hit.rest_point), "Stretch contact reaches GPU immediately after reset")
		blob.update_stretch_vector(Vector3.RIGHT * 0.6)
		advance(0.3)
		var finite := true
		for p in blob._rest_positions:
			finite = finite and blob._target_offset_for(p).is_finite()
		check(finite and blob._press_amount == 0.0, "Direct stretch works without prior press; after doodle: " + str(after_doodle))
		await screenshot("reset-stretch-" + str(after_doodle))
		blob.reset_deformation()

func check_scene_capture() -> void:
	var photo = main._scene_capture
	check(main.find_child("SceneCaptureButton", true, false) != null, "Scene capture button is available")
	check(photo.capture_size(Vector2i(1170, 2532)) == Vector2i(1170, 2532), "Photo preserves phone pixel dimensions")
	var large: Vector2i = photo.capture_size(Vector2i(7680, 4320))
	check(large == Vector2i(4096, 2304), "Photo bounds large resolutions without changing aspect ratio")
	if not capture:
		return # Actual viewport readback requires a graphics renderer.
	await photo.capture_scene()
	check(photo.is_open() and not photo.jpeg.is_empty(), "Scene capture produces JPEG and preview modal")
	if photo.jpeg.is_empty():
		photo.close()
		return
	var decoded := Image.new()
	check(decoded.load_jpg_from_buffer(photo.jpeg) == OK and decoded.get_size() == photo.captured.get_size(), "JPEG decodes at the requested output size")
	var corner := decoded.get_pixel(roundi(decoded.get_width() * 0.06), roundi(decoded.get_height() * 0.04))
	check(corner.r > 0.7 and corner.g > 0.5, "Scene photo excludes top-left parameter button and modal UI")
	photo.captured.save_png("/tmp/nienie-scene-only.png")
	photo._save_to_path("/tmp/nienie-scene-capture-test.jpg")
	check(FileAccess.get_file_as_bytes("/tmp/nienie-scene-capture-test.jpg") == photo.jpeg, "Desktop save writes the exact JPEG bytes")
	var point := screen_point()
	mouse_button(point, true)
	await process_frame
	check(not main._dragging and not main._drawing, "Preview modal blocks model interaction")
	mouse_button(point, false)
	await process_frame
	await screenshot("scene-capture-modal")
	photo.close()
	check(not photo.is_open() and photo.jpeg.is_empty(), "Closing capture releases the image and restores scene input")
