extends Node

signal language_changed

const JAPANESE: Dictionary = preload("res://locales/ja.json").data
const FONT_ZH = preload("res://fonts/NotoSansSC-Regular.ttf")
const FONT_JA = preload("res://fonts/NotoSansJP-Regular.ttf")
const SETTINGS_PATH := "user://language.cfg"
const OPTIONS := ["zh", "ja"]
var preference := "zh"
var system_language := "zh"

func _enter_tree() -> void:
	for locale in ["zh", "ja"]:
		var translation := Translation.new()
		translation.locale = locale
		for source in JAPANESE:
			translation.add_message(source, JAPANESE[source] if locale == "ja" else source)
		TranslationServer.add_translation(translation)
	var system_locale := OS.get_locale()
	if OS.has_feature("web"):
		var browser_locale = JavaScriptBridge.eval("navigator.language || (navigator.languages && navigator.languages[0]) || ''")
		if browser_locale is String and not browser_locale.is_empty():
			system_locale = browser_locale
	system_language = resolve_locale(system_locale)
	preference = system_language
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		var saved := str(settings.get_value("language", "selection", "auto"))
		if saved in OPTIONS:
			preference = saved
	TranslationServer.set_locale(preference)

func set_language(selection: String, persist := true) -> void:
	if selection not in OPTIONS:
		return
	preference = selection
	if persist:
		var settings := ConfigFile.new()
		settings.set_value("language", "selection", preference)
		settings.save(SETTINGS_PATH)
	TranslationServer.set_locale(preference)
	language_changed.emit()

func make_selector(font: Font) -> OptionButton:
	var button := OptionButton.new()
	button.name = "LanguageSelector"
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 24)
	button.get_popup().add_theme_font_override("font", font)
	button.get_popup().add_theme_font_size_override("font_size", 24)
	button.custom_minimum_size = Vector2(210, 64)
	button.add_item("中文")
	button.add_item("日本語")
	button.select(OPTIONS.find(preference))
	button.item_selected.connect(func(index: int): set_language(OPTIONS[index]))
	return button

func refresh_controls(root: Node, font: Font) -> void:
	# Translate existing controls in place so drawing, camera and tuning survive.
	var reverse := {}
	for source in JAPANESE:
		reverse[JAPANESE[source]] = source
	var nodes: Array[Node] = [root]
	while not nodes.is_empty():
		var node := nodes.pop_back() as Node
		if node is Label or node is Button:
			var source: String = reverse.get(node.text, node.text)
			node.text = tr(source)
		if node is OptionButton and node.name == "LanguageSelector":
			node.select(OPTIONS.find(preference))
			node.get_popup().add_theme_font_override("font", font)
		if node is Control:
			node.tooltip_text = tr(reverse.get(node.tooltip_text, node.tooltip_text))
			if node.has_theme_font_override("font"):
				node.add_theme_font_override("font", font)
			if node.theme != null:
				if node.theme.default_font is FontVariation:
					node.theme.default_font.base_font = font
				else:
					node.theme.default_font = font
		nodes.append_array(node.get_children(true))

func resolve_locale(system_locale: String) -> String:
	return "ja" if system_locale.replace("-", "_").to_lower().get_slice("_", 0) == "ja" else "zh"

func font_path() -> String:
	return "res://fonts/NotoSansJP-Regular.ttf" if TranslationServer.get_locale().begins_with("ja") else "res://fonts/NotoSansSC-Regular.ttf"
