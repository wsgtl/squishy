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
	resized.connect(_layout_feel_cards)
	_layout_feel_cards()
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
	$SoundButton.set_pressed_no_signal(not AudioServer.is_bus_mute(0))
	var japanese := TranslationServer.get_locale().begins_with("ja")
	$LanguageSelector.tooltip_text = ""
	var names := ["ぷる水感", "とろ泥感", "むぎゅモチ感"] if japanese else ["水润嫩滑", "绵密泥感", "紧实弹韧"]
	for i in range(choices.size()):
		choices[i].get_node("Name").text = names[i]
	$StartSquishingButton/Caption.text = tr("开始捏它")
	$SoundButton.tooltip_text = tr("有声音") if $SoundButton.button_pressed else tr("静音")
	$SoundButton/Icon.texture = preload("res://res/ui/home/sound_on_icon.png") if $SoundButton.button_pressed else preload("res://res/ui/home/volume_muted.png")


func _layout_feel_cards() -> void:
	# Fit the entire row to one aspect ratio, independent of viewport height.
	var gap: float = 18.0
	var available_width: float = size.x * 0.90 - 24.0
	var available_height: float = size.y * 0.22
	var card_width: float = minf((available_width - gap * 2.0) / 3.0, available_height * 288.0 / 430.0)
	var row_size := Vector2(card_width * 3.0 + gap * 2.0, card_width * 430.0 / 288.0)
	$Cards.set_anchors_preset(Control.PRESET_TOP_LEFT)
	$Cards.size = row_size
	$Cards.position = Vector2((size.x - row_size.x) * 0.5, size.y * 0.755 - row_size.y * 0.5)
	$Cards.add_theme_constant_override("separation", int(gap))
