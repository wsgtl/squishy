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
	for locale in ["ja", "ja-JP", "JA_jp"]:
		check(manager.resolve_locale(locale) == "ja", "Japanese locale resolution: " + locale)
	for locale in ["zh", "zh-CN", "zh-TW", "en-US", ""]:
		check(manager.resolve_locale(locale) == "zh", "Chinese/fallback locale resolution: " + locale)
	for locale in ["zh", "ja"]:
		TranslationServer.set_locale(locale)
		root.size = Vector2i(720, 1280)
		var main = load("res://scenes/main.tscn").instantiate()
		root.add_child(main)
		await process_frame
		check(main._home.find_child("StartSquishingButton", true, false).text == tr("开始捏它"), "Localized home start button")
		for index in range(4):
			main._home.select(index)
			var type: Dictionary = main.FeelPresets.TYPES[index]
			check(main._home.choices[index].text.begins_with(tr(type.name)), "Localized feel title")
			check(main._home.description.text == tr("%s\n对应商品：%s") % [tr(type.description), tr(type.products)], "Localized feel description and products")
		check(main._cjk_font.resource_path == manager.font_path(), "Locale selects matching CJK font")
		main._start_game()
		main._set_doodle_enabled(true)
		check(main._doodle_button.text == tr("退出涂鸦"), "Dynamic doodle button text")
		var eraser = main.find_child("DoodleEraserSwitch", true, false)
		check(eraser != null and eraser.text == tr("橡皮擦"), "Localized eraser button")
		check(main._scene_capture.find_child("SystemShareButton", true, false).text == tr("系统分享"), "Localized sharing button with stable internal identity")
		for source in manager.JAPANESE:
			check(tr(source) == (manager.JAPANESE[source] if locale == "ja" else source), "Catalog translation: " + source)
		var brush_radius: float = main._doodle.radius
		var selected_feel: int = main._selected_feel
		var camera_transform: Transform3D = main._camera.transform
		var selection: String = manager.preference
		for requested in ["ja", "zh"]:
			manager.set_language(requested, false)
			check(TranslationServer.get_locale() == requested, "Manual language selection")
			check(main._home.find_child("StartSquishingButton", true, false).text == tr("开始捏它"), "Home refreshes immediately")
			check(main._grip_button.text == tr("按住挤压"), "Game UI refreshes immediately")
			check(main._doodle_button.text == tr("退出涂鸦"), "Drawing UI remains in drawing mode after language change")
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
			main._return_home()
			main._physics_process(main.PAGE_CAMERA_DURATION)
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-home-" + locale + ".png")
		main.queue_free()
		await process_frame
	print("LOCALIZATION TESTS: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(0 if failures == 0 else 1)
