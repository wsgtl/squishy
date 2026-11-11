extends Control
var host: Node3D

func setup(scene: Node3D) -> void:
	host = scene
	$WaxButton.pressed.connect(host._toggle_wax_mode)
	$ReturnHomeButton.pressed.connect(host._game_back)
	$SquishModeButton.pressed.connect(func(): host._set_doodle_enabled(false))
	$DoodleButton.pressed.connect(func(): host._set_doodle_enabled(true))
	$SoundButton.pressed.connect(func():
		AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
		refresh_language()
	)
	visibility_changed.connect(refresh_language)
	refresh_language()

func refresh_language() -> void:
	if host == null:
		return
	$SoundButton.visible = not host._doodle_enabled
	var wax_active: bool = host._wax_mode != null
	$WaxButton.visible = host.WAX_MODE_ENABLED and not host._doodle_enabled and not wax_active
	for node in [$ModeBackground,$SquishModeButton,$DoodleButton]:
		node.visible = not wax_active
	$WaxButton/Caption.text = tr("碎")
	$Edit.refresh_language()
	$SquishModeButton/Caption.text = tr("捏捏")
	$DoodleButton/Caption.text = tr("涂鸦")
	$SquishModeButton/Caption.add_theme_color_override("font_color", Color("#AC8C82") if host._doodle_enabled else Color.WHITE)
	$DoodleButton/Caption.add_theme_color_override("font_color", Color.WHITE if host._doodle_enabled else Color("#AC8C82"))
	$FeelName.text = tr(host.FeelPresets.TYPES[host._selected_feel].name)
	_update_feel_badge_width()
	var audible := not AudioServer.is_bus_mute(0)
	$SoundButton/Caption.text = tr("有声音") if audible else tr("静音")
	$SoundButton/Caption.add_theme_color_override("font_color", Color("#ad641f"))
	$SoundButton/Caption.add_theme_font_size_override("font_size", 26)
	$SoundButton/Caption.offset_left = 42
	$SoundButton/Icon.texture = preload("res://res/ui/home/volume_on.png") if audible else preload("res://res/ui/home/volume_muted.png")
	$SquishModeButton/Background.visible = not host._doodle_enabled
	$DoodleButton/Background.visible = host._doodle_enabled
	$SquishModeButton/Icon.texture = preload("res://res/ui/game/switch_squish_0.png") if host._doodle_enabled else preload("res://res/ui/game/switch_squish_1.png")
	$DoodleButton/Icon.texture = preload("res://res/ui/game/switch_draw_1.png") if host._doodle_enabled else preload("res://res/ui/game/switch_draw_0.png")


func _update_feel_badge_width() -> void:
	var caption: Label = $FeelName
	var font: Font = caption.get_theme_font("font")
	var font_size: int = caption.get_theme_font_size("font_size")
	var text_width: float = font.get_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	# Keep the original width for short names; reserve 16 pixels on either side.
	var badge_width: float = maxf(218.0, ceilf(text_width) + 32.0)
	$FeelBadge.offset_right = badge_width
	caption.offset_right = badge_width
