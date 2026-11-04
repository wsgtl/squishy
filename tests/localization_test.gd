extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var manager := root.get_node("LocaleManager")
	for locale in ["ja", "ja-JP", "JA_jp", "en-US", "fr-FR", ""]:
		check(manager.resolve_locale(locale) == "ja", "Japanese locale resolution: " + locale)
	for locale in ["zh", "zh-CN", "zh-TW"]:
		check(manager.resolve_locale(locale) == "zh", "Chinese/fallback locale resolution: " + locale)
	var original_system: String = manager.system_language
	manager.system_language = "zh"
	for locale in ["zh", "ja"]:
		TranslationServer.set_locale(locale)
		root.size = Vector2i(720, 1280)
		var main = load("res://scenes/main.tscn").instantiate()
		root.add_child(main)
		await process_frame
		var scroll: ScrollContainer = main._home.get_node("FeelScroll")
		var scroll_point := scroll.get_global_rect().get_center()
		var before_feel: int = main._selected_feel
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.position = scroll_point
		touch.pressed = true
		main._home._input(touch)
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = scroll_point - Vector2(0, 140)
		main._home._input(drag)
		touch.pressed = false
		touch.position = drag.position
		main._home._input(touch)
		check(scroll.scroll_vertical > 100 and main._selected_feel == before_feel, "Touch drag scrolls without selecting a different feel")
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.position = scroll_point
		mouse.pressed = true
		main._home._input(mouse)
		var motion := InputEventMouseMotion.new()
		motion.position = scroll_point + Vector2(0, 140)
		main._home._input(motion)
		mouse.pressed = false
		mouse.position = motion.position
		main._home._input(mouse)
		check(scroll.scroll_vertical == 0 and main._selected_feel == before_feel, "Mouse drag scrolls back without changing selection")
		var first_point: Vector2 = main._home.choices[1].get_global_rect().get_center()
		touch.pressed = true
		touch.position = first_point
		main._home._input(touch)
		touch.pressed = false
		main._home._input(touch)
		check(main._selected_feel == 1, "A stationary touch still selects the tapped feel")
		check(main._home.find_child("StartSquishingButton", true, false).get_node("Caption").text == tr("开始捏它"), "Localized home start button")
		for index in range(4):
			main._home.select(index)
			check(main._active_model_path == main.FeelPresets.model_path(index), "Feel switches to its own model")
			check(main._blob._external_mesh_instance != null and not main._raycast_blob(main._camera.unproject_position(main._look_at_target)).is_empty(), "Switched model remains pickable")
			var checked := 0
			for choice in main._home.choices:
				checked += int(choice.get_node("Check").visible)
			check(checked == 1 and main._home.choices[index].get_node("Check").visible, "Only the selected feel shows a checkmark")
			var type: Dictionary = main.FeelPresets.TYPES[index]
			check(main._home.choices[index].get_node("Name").text == tr(type.name), "Localized feel title")
			check(main._home.description.text == tr("%s\n对应商品：%s") % [tr(type.description), tr(type.products)], "Localized feel description and products")
		check(main._cjk_font.resource_path == manager.font_path(), "Locale selects matching CJK font")
		check(is_equal_approx(main._home.get_node("FeelScroll").size.y, main._home.row_height * 2.5 + 16.0 + 40.0), "Scroll window shows two and a half rows plus top breathing room")
		main._start_game()
		check(main._hud_root.get_node("FeelName").text == tr(main.FeelPresets.TYPES[main._selected_feel].name), "Game badge displays the selected feel")
		main._hud_root.get_node("DoodleButton").pressed.emit()
		check(main._doodle_enabled and not main._grip_button.visible and not main._twist_button.visible, "Bottom drawing tab hides squeeze actions")
		main._hud_root.get_node("SquishModeButton").pressed.emit()
		check(not main._doodle_enabled and main._grip_button.visible and main._twist_button.visible, "Bottom squish tab restores squeeze actions")
		for button_name in ["ReturnHomeButton", "SceneCaptureButton", "SoundButton"]:
			check(main._hud_root.get_node(button_name).has_node("PressAnimation"), "Game button has reusable press animation: " + button_name)
		main._set_doodle_enabled(true)
		check(main._hud_root.get_node("DoodleButton/Caption").text == tr("涂鸦") and main._doodle_enabled, "Dynamic doodle button text")
		var eraser = main.find_child("DoodleEraserSwitch", true, false)
		check(eraser != null and eraser.text == tr("橡皮擦"), "Localized eraser button")
		check(main._scene_capture.find_child("CloseSceneCaptureButton", true, false).get_node("Caption").text == tr("取消"), "Localized photo cancel caption")
		for source in manager.JAPANESE:
			check(tr(source) == (manager.JAPANESE[source] if locale == "ja" else source), "Catalog translation: " + source)
		var brush_radius: float = main._doodle.radius
		var selected_feel: int = main._selected_feel
		var camera_transform: Transform3D = main._camera.transform
		var selection: String = manager.preference
		for requested in ["ja", "zh"]:
			manager.set_language(requested, false)
			check(TranslationServer.get_locale() == requested, "Manual language selection")
			check(main._home.find_child("StartSquishingButton", true, false).get_node("Caption").text == tr("开始捏它"), "Home refreshes immediately")
			check(main._grip_button.get_node("Caption").text == tr("挤压"), "Game UI refreshes immediately")
			check(main._hud_root.get_node("DoodleButton/Caption").text == tr("涂鸦") and main._doodle_enabled, "Drawing UI remains in drawing mode after language change")
			check(main._cjk_font.resource_path == manager.font_path(), "Switching updates fonts")
			check(main._doodle.radius == brush_radius and main._selected_feel == selected_feel and main._camera.transform.is_equal_approx(camera_transform), "Language switching preserves tuning and camera")
			for selector in [main._home.find_child("LanguageSelector", true, false), main._param_panel.find_child("LanguageSelector", true, false)]:
				check(selector.item_count == 2 and selector.get_item_text(0) == "中文" and selector.get_item_text(1) == "日本語", "Language selector contains only Chinese and Japanese")
				check(selector != null and selector.selected == manager.OPTIONS.find(requested), "Home and settings language selectors stay synchronized")
		manager.preference = selection
		TranslationServer.set_locale(locale)
		main._refresh_language()
		if "--capture" in OS.get_cmdline_user_args():
			main._set_doodle_enabled(false)
			main._physics_process(main.PAGE_CAMERA_DURATION)
			main._process(main.CAMERA_RETURN_DURATION)
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-game-" + locale + ".png")
			main._return_home()
			main._physics_process(main.PAGE_CAMERA_DURATION)
			await process_frame
			main._home.get_node("FeelScroll").ensure_control_visible(main._home.choices[main._selected_feel])
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-home-" + locale + ".png")
		main.queue_free()
		await process_frame
	manager.system_language = "ja"
	manager.set_language("zh", false)
	check(TranslationServer.get_locale() == "ja", "Non-Chinese environments always use Japanese even with a previous Chinese choice")
	var japanese_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(japanese_main)
	await process_frame
	check(not japanese_main._home.get_node("LanguageSelector").visible, "Non-Chinese home hides language selection")
	check(not japanese_main._param_panel.find_child("LanguageSelector", true, false).visible, "Non-Chinese settings hide language selection")
	check(is_equal_approx(japanese_main._home.get_node("Logo").get_rect().get_center().y, japanese_main._home.get_node("SoundButton").get_rect().get_center().y), "Logo and sound button share a horizontal center line")
	japanese_main.queue_free()
	await process_frame
	manager.system_language = original_system
	print("LOCALIZATION TESTS: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(0 if failures == 0 else 1)
