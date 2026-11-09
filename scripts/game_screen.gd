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
	$WaxButton.visible = not host._doodle_enabled and not wax_active
	for node in [$ModeBackground,$SquishModeButton,$DoodleButton,$Divider]:
		node.visible = not wax_active
	$WaxButton/Caption.text = tr("碎")
	$SceneCaptureButton.offset_top = -65.0 if host._doodle_enabled else 0.0
	$SceneCaptureButton.offset_bottom = 31.0 if host._doodle_enabled else 96.0
	$Edit.refresh_language()
	$SquishModeButton/Caption.text = tr("捏捏")
	$DoodleButton/Caption.text = tr("涂鸦")
	$SquishModeButton/Caption.modulate = Color("#d9bfc3") if host._doodle_enabled else Color("#ec8394")
	$DoodleButton/Caption.modulate = Color("#ec8394") if host._doodle_enabled else Color("#d9bfc3")
	$FeelName.text = tr(host.FeelPresets.TYPES[host._selected_feel].name)
	$GripButton/Caption.text = tr("挤压")
	$TwistButton/Caption.text = tr("扭转")
	$FlattenButton/Caption.text = tr("压扁")
	var audible := not AudioServer.is_bus_mute(0)
	$SoundButton/Caption.text = tr("有声音") if audible else tr("静音")
	$SoundButton/Caption.add_theme_color_override("font_color", Color("#ad641f"))
	$SoundButton/Caption.add_theme_font_size_override("font_size", 26)
	$SoundButton/Caption.offset_left = 42
	$SoundButton/Icon.texture = preload("res://res/ui/home/volume_on.png") if audible else preload("res://res/ui/home/volume_muted.png")
	$SquishModeButton/Background.texture = preload("res://res/ui/game/switch_squish_0.png") if host._doodle_enabled else preload("res://res/ui/game/switch_squish_1.png")
	$DoodleButton/Background.texture = preload("res://res/ui/game/switch_draw_1.png") if host._doodle_enabled else preload("res://res/ui/game/switch_draw_0.png")
