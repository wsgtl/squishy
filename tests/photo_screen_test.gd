extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(720,1280)
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._start_game()
	main._physics_process(main.PAGE_CAMERA_DURATION)
	var photo = main._scene_capture
	if "--capture" in OS.get_cmdline_user_args():
		await photo.capture_scene()
		check(not photo.jpeg.is_empty() and photo.preview.texture != null, "Captures JPEG with preview")
	else:
		photo.overlay.show()
	await process_frame
	await process_frame
	var scroll: ScrollContainer = photo.overlay.get_node("Card/ShareFrame/ShareScroll")
	var buttons = scroll.get_node("Platforms").get_children()
	check(buttons.size() == 5 and buttons[0].name == "XShareButton" and buttons[1].name == "LINEShareButton" and buttons[4].name == "KakaoShareButton", "Platform order")
	var point := scroll.get_global_rect().get_center()
	var touch := InputEventScreenTouch.new()
	touch.position = point
	touch.index = 0
	touch.pressed = true
	photo.overlay._input(touch)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = point - Vector2(200,0)
	photo.overlay._input(drag)
	touch.pressed = false
	touch.position = drag.position
	photo.overlay._input(touch)
	check(scroll.scroll_horizontal > 0, "Touch scrolls platforms")
	scroll.scroll_horizontal = 0
	if "--capture" in OS.get_cmdline_user_args():
		await process_frame
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("/tmp/nienie-photo.png")
	photo.close()
	check(not photo.is_open() and photo.jpeg.is_empty(), "Closing clears image")
	main.queue_free()
	await process_frame
	print("PHOTO TESTS: ", failures)
	quit(1 if failures else 0)
