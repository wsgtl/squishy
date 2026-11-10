extends Control

@export_range(92.0, 160.0) var row_height := 108.0
@export_range(1.0, 4.0) var visible_rows := 2.5
@export_range(0.0, 40.0) var edge_fade_pixels := 16.0
var host: Node3D
var choices: Array[Button] = []
var description: Label
const Presets = preload("res://scripts/feel_presets.gd")
const FadeShader = preload("res://shaders/home_edge_fade.gdshader")
var _fade: ShaderMaterial
var _scroll_pointer := -2 # -2 idle, -1 mouse, >=0 touch ID
var _scroll_start := Vector2.ZERO
var _scroll_origin := 0
var _scroll_dragging := false
const SCROLL_DRAG_THRESHOLD := 10.0

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or host == null or not host._home_active or $BrandConfirm.visible:
		_scroll_pointer = -2
		return
	# Own the gesture before child Buttons consume it. Real touch events are
	# handled once; their emulated mouse stream must not select a second item.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		if _scroll_pointer >= 0 or $FeelScroll.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if event.pressed and _scroll_pointer == -2:
			_begin_scroll(event.position, event.index)
		elif not event.pressed and _scroll_pointer == event.index:
			_end_scroll(event.position, event.canceled)
	elif event is InputEventScreenDrag and _scroll_pointer == event.index:
		_drag_scroll(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _scroll_pointer == -2:
			_begin_scroll(event.position, -1)
		elif not event.pressed and _scroll_pointer == -1:
			_end_scroll(event.position, false)
	elif event is InputEventMouseMotion and _scroll_pointer == -1:
		_drag_scroll(event.position)

func _begin_scroll(position: Vector2, pointer: int) -> void:
	if not $FeelScroll.get_global_rect().has_point(position):
		return
	_scroll_pointer = pointer
	_scroll_start = position
	_scroll_origin = $FeelScroll.scroll_vertical
	_scroll_dragging = false
	get_viewport().set_input_as_handled()

func _drag_scroll(position: Vector2) -> void:
	if position.distance_to(_scroll_start) > SCROLL_DRAG_THRESHOLD:
		_scroll_dragging = true
	if _scroll_dragging:
		$FeelScroll.scroll_vertical = _scroll_origin + roundi(_scroll_start.y - position.y)
	get_viewport().set_input_as_handled()

func _end_scroll(position: Vector2, canceled: bool) -> void:
	var tapped := not canceled and not _scroll_dragging and position.distance_to(_scroll_start) <= SCROLL_DRAG_THRESHOLD
	_scroll_pointer = -2
	get_viewport().set_input_as_handled()
	if tapped and $FeelScroll.get_global_rect().has_point(position):
		for i in range(choices.size()):
			if choices[i].get_global_rect().has_point(position):
				select(i)
				break

func _open_brand_site() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.location.assign('https://punikko.fun/')")
	else:
		OS.shell_open("https://punikko.fun/")

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_scroll_pointer = -2

func setup(scene: Node3D, font: Font) -> void:
	host = scene
	theme.default_font = font
	description = $Description
	var language: OptionButton = $LanguageSelector
	language.visible = LocaleManager.language_selection_allowed()
	language.select(LocaleManager.OPTIONS.find(LocaleManager.preference))
	language.item_selected.connect(func(index: int): LocaleManager.set_language(LocaleManager.OPTIONS[index]))
	$StartSquishingButton.pressed.connect(host._start_game)
	$Logo.pressed.connect(func(): $BrandConfirm.open("即将离开游戏，前往 PUNIKKO 官网？"))
	$BrandConfirm.confirmed.connect(_open_brand_site)
	$SoundButton.toggled.connect(_set_sound)
	$SoundButton.set_pressed_no_signal(not AudioServer.is_bus_mute(0))
	_fade = ShaderMaterial.new()
	_fade.shader = FadeShader
	for i in range(4):
		var button := $FeelScroll/FeelList.get_node("FeelChoice" + str(i)) as Button
		choices.append(button)
		button.mouse_filter = Control.MOUSE_FILTER_PASS
		button.pressed.connect(func(): select(i))
		for visual in button.get_children():
			visual.material = _fade
	resized.connect(_resize_rows)
	_resize_rows()
	refresh_language()
	select(host._selected_feel)

func _process(_delta: float) -> void:
	if _fade == null or not visible:
		return
	var rect: Rect2 = $FeelScroll.get_global_rect()
	var height := get_viewport_rect().size.y
	_fade.set_shader_parameter("top", rect.position.y / height)
	_fade.set_shader_parameter("bottom", rect.end.y / height)
	_fade.set_shader_parameter("edge", maxf(edge_fade_pixels, 0.01) / height)

func _resize_rows() -> void:
	# 2.5 rows, including two gaps; proportionate to viewport height.
	$FeelScroll.offset_bottom = row_height * visible_rows + 16.0
	for button in choices:
		button.custom_minimum_size.y = row_height

func select(index: int) -> void:
	host._apply_feel(index)
	for i in range(choices.size()):
		choices[i].set_pressed_no_signal(i == index)
		choices[i].get_node("Check").visible = i == index
	refresh_language()

func _set_sound(enabled: bool) -> void:
	AudioServer.set_bus_mute(0, not enabled)
	refresh_language()

func refresh_language() -> void:
	for i in range(choices.size()):
		var type: Dictionary = Presets.TYPES[i]
		choices[i].get_node("Name").text = tr(type.name)
		choices[i].get_node("Rating").text = tr("柔软 %d/5星 · 回弹 %d/5星") % [type.soft, type.bounce]
	var type: Dictionary = Presets.TYPES[host._selected_feel]
	description.text = tr("%s\n对应商品：%s") % [tr(type.description),tr(type.products)]
	$StartSquishingButton/Caption.text = tr("开始捏它")
	$SoundButton/Caption.text = tr("有声音") if $SoundButton.button_pressed else tr("静音")
	$SoundButton/Icon.texture = preload("res://res/ui/home/volume_on.png") if $SoundButton.button_pressed else preload("res://res/ui/home/volume_muted.png")
