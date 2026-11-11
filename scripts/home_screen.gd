extends Control

var host: Node3D
var choices: Array[Button] = []
const Presets = preload("res://scripts/feel_presets.gd")

func _open_brand_site() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.location.assign('https://punikko.fun/')")
	else:
		OS.shell_open("https://punikko.fun/")

func setup(scene: Node3D, font: Font) -> void:
	host = scene
	theme.default_font = font
	var language: Button = $LanguageSelector
	language.visible = LocaleManager.language_selection_allowed()
	language.pressed.connect(func(): LocaleManager.set_language("zh" if TranslationServer.get_locale().begins_with("ja") else "ja"))
	$StartSquishingButton.pressed.connect(host._start_game)
	$Logo.pressed.connect(func(): $BrandConfirm.open("即将离开游戏，前往 PUNIKKO 官网？"))
	$BrandConfirm.confirmed.connect(_open_brand_site)
	$SoundButton.toggled.connect(_set_sound)
	$SoundButton.set_pressed_no_signal(not AudioServer.is_bus_mute(0))
	for i in range(Presets.TYPES.size()):
		var button := $Cards.get_node("FeelChoice" + str(i)) as Button
		choices.append(button)
		button.pressed.connect(func(): select(i))
	select(host._selected_feel)

func select(index: int) -> void:
	host._apply_feel(index)
	for i in range(choices.size()):
		choices[i].set_pressed_no_signal(i == index)
		choices[i].get_node("Glow").visible = i == index
	refresh_language()

func _set_sound(enabled: bool) -> void:
	AudioServer.set_bus_mute(0, not enabled)
	refresh_language()

func refresh_language() -> void:
	var japanese := TranslationServer.get_locale().begins_with("ja")
	$LanguageSelector.tooltip_text = "切换为中文" if japanese else "日本語に切り替え"
	var names := ["ぷる水感", "とろ泥感", "むぎゅモチ感"] if japanese else ["水润嫩滑", "绵密泥感", "紧实弹韧"]
	for i in range(choices.size()):
		choices[i].get_node("Name").text = names[i]
	$StartSquishingButton/Caption.text = tr("开始捏它")
	$SoundButton.tooltip_text = tr("有声音") if $SoundButton.button_pressed else tr("静音")
	$SoundButton/Icon.texture = preload("res://res/ui/home/sound_on_icon.png") if $SoundButton.button_pressed else preload("res://res/ui/home/volume_muted.png")
