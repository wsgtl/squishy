extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var canvas = load("res://scripts/doodle_canvas.gd").new()
	canvas.begin_stroke()
	canvas.stamp(Vector2(0.5, 0.5))
	canvas.end_stroke()
	var drawn: PackedByteArray = canvas.image.get_data()
	check(canvas.undo_steps.size() == 1, "One stroke is one undo step")
	canvas.undo()
	check(canvas.image.get_pixel(512,512).a == 0, "Undo restores transparent canvas")
	canvas.redo()
	check(canvas.image.get_data() == drawn, "Redo is lossless")
	canvas.clear()
	canvas.undo()
	check(canvas.image.get_data() == drawn, "Clear can be undone")
	canvas.undo()
	canvas.begin_stroke()
	canvas.stamp(Vector2(0.2, 0.2))
	canvas.end_stroke()
	check(canvas.redo_steps.is_empty(), "New stroke removes redo branch")
	root.size = Vector2i(720,1280)
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var home_camera_offset: float = main._camera.v_offset
	main._start_game()
	main._physics_process(main.PAGE_CAMERA_DURATION)
	main._set_doodle_enabled(true)
	check(main._camera.v_offset < home_camera_offset, "Game camera frames the model higher to clear editor UI")
	var edit = main._hud_root.get_node("Edit")
	await process_frame
	check(edit.visible and not main._hud_root.get_node("SoundButton").visible, "Edit replaces sound with history buttons")
	check(not main._doodle_panel.visible, "Legacy toolbar remains hidden")
	check(main._hud_root.get_node("DoodleButton").visible, "Bottom switch retained")
	edit.select_tool(2)
	edit.get_node("Tools/Sizes/Size2").pressed.emit()
	edit.select_tool(0)
	check(main._doodle.radius == 5, "Brush size independent of eraser")
	edit.select_tool(2)
	check(main._doodle.radius == 24, "Eraser remembers size")
	edit.get_node("Tools/Clear").pressed.emit()
	check(edit.get_node("Confirm").visible, "Clear opens confirmation")
	edit.get_node("Confirm/Card/Cancel").pressed.emit()
	check(not edit.get_node("Confirm").visible, "Cancel closes confirmation")
	edit.select_tool(1)
	await process_frame
	await process_frame
	var scroll: ScrollContainer = edit.get_node("Tools/Stickers")
	var position := scroll.get_global_rect().get_center()
	var selected_before: Image = main._sticker_image
	var touch := InputEventScreenTouch.new()
	touch.device = 42
	touch.index = 0
	touch.pressed = true
	touch.position = position
	Input.parse_input_event(touch)
	await process_frame
	var drag := InputEventScreenDrag.new()
	drag.device = 42
	drag.index = 0
	drag.position = position - Vector2(0, 120)
	drag.relative = Vector2(0, -120)
	Input.parse_input_event(drag)
	await process_frame
	touch = touch.duplicate()
	touch.pressed = false
	touch.position = drag.position
	Input.parse_input_event(touch)
	await process_frame
	check(scroll.scroll_vertical >= 110, "Touch drags sticker list")
	check(main._sticker_image == selected_before and not main._drawing and not main._is_rotating, "Scroll does not select or manipulate model")
	var mouse := InputEventMouseButton.new()
	mouse.device = 42
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	mouse.position = position
	Input.parse_input_event(mouse)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.device = 42
	motion.position = position + Vector2(0, 120)
	Input.parse_input_event(motion)
	await process_frame
	mouse = mouse.duplicate()
	mouse.pressed = false
	mouse.position = motion.position
	Input.parse_input_event(mouse)
	await process_frame
	check(scroll.scroll_vertical == 0, "Mouse drag scrolls sticker list back")
	check(main._sticker_image == selected_before, "Mouse drag does not select sticker")
	var sticker: TextureButton = edit.get_node("Tools/Stickers/Grid/Sticker1")
	touch = touch.duplicate()
	touch.position = sticker.get_global_rect().get_center()
	touch.pressed = true
	Input.parse_input_event(touch)
	await process_frame
	touch = touch.duplicate()
	touch.pressed = false
	Input.parse_input_event(touch)
	await process_frame
	check(sticker.get_node("Selection").visible, "Stationary tap still selects sticker")
	main._sticker_base = main._doodle.image.duplicate()
	main._sticker_cancel_image = main._sticker_base
	main._sticker_pending = true
	main._sticker_uv = Vector2(0.5,0.5)
	main._sticker_preview_dirty = true
	main._refresh_sticker_preview()
	check(main._doodle.undo_steps.is_empty(), "Sticker preview does not record history")
	main._confirm_sticker()
	check(main._doodle.undo_steps.size() == 1, "Sticker confirmation commits history")
	edit.history_step(false)
	check(not main._doodle.redo_steps.is_empty(), "Sticker can be undone")
	for mode in range(3):
		edit.select_tool(mode)
		await process_frame
		if "--capture" in OS.get_cmdline_user_args():
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-edit-%d.png" % mode)
	if "--capture" in OS.get_cmdline_user_args():
		edit.get_node("Tools/Clear").pressed.emit()
		await process_frame
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("/tmp/nienie-edit-confirm.png")
	main._set_doodle_enabled(false)
	check(not edit.visible and main._hud_root.get_node("SoundButton").visible, "Exit restores game UI")
	main.queue_free()
	await process_frame
	print("Editor test failures: ", failures)
	quit(1 if failures else 0)
