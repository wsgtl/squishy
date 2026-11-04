extends Control
var host: Node3D
var tool := 0
var selected_color := 0
const COLORS = ["#ed6667", "#f7cf62", "#75bd84", "#6daee1", "#ae87cb", "#976b50", "#ffffff", "#f5c8ae"]

var _scroll_pointer := -2 # -2 idle, -1 mouse, >=0 touch ID
var _scroll_start := Vector2.ZERO
var _scroll_origin := 0
var _scroll_dragging := false
const SCROLL_DRAG_THRESHOLD := 10.0

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or host == null or tool != 1 or $Confirm.visible or host._drawing or (host._scene_capture != null and host._scene_capture.is_open()):
		_scroll_pointer = -2
		return
	# Own the gesture before child Buttons consume it. Real touch events are
	# handled once; their emulated mouse stream must not select a second item.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		if _scroll_pointer >= 0 or $Tools/Stickers.get_global_rect().has_point(event.position):
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
	if not $Tools/Stickers.get_global_rect().has_point(position):
		return
	_scroll_pointer = pointer
	_scroll_start = position
	_scroll_origin = $Tools/Stickers.scroll_vertical
	_scroll_dragging = false
	get_viewport().set_input_as_handled()

func _drag_scroll(position: Vector2) -> void:
	if position.distance_to(_scroll_start) > SCROLL_DRAG_THRESHOLD:
		_scroll_dragging = true
	if _scroll_dragging:
		$Tools/Stickers.scroll_vertical = _scroll_origin + roundi(_scroll_start.y - position.y)
	get_viewport().set_input_as_handled()

func _end_scroll(position: Vector2, canceled: bool) -> void:
	var tapped := not canceled and not _scroll_dragging and position.distance_to(_scroll_start) <= SCROLL_DRAG_THRESHOLD
	_scroll_pointer = -2
	get_viewport().set_input_as_handled()
	if tapped and $Tools/Stickers.get_global_rect().has_point(position):
		for button in $Tools/Stickers/Grid.get_children():
			if button.get_global_rect().has_point(position):
				button.pressed.emit()
				break

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_scroll_pointer = -2

func setup(scene: Node3D) -> void:
	host = scene
	visibility_changed.connect(func(): _scroll_pointer = -2)
	host._doodle.color = Color(COLORS[selected_color])
	$Tools/Brush.pressed.connect(func(): select_tool(0))
	$Tools/Sticker.pressed.connect(func(): select_tool(1))
	$Tools/Eraser.pressed.connect(func(): select_tool(2))
	for i in range(3):
		get_node("Tools/Sizes/Size%d" % i).pressed.connect(func():
			host._finish_gesture()
			host._doodle.radius = [5.0, 15.0, 24.0][i]
		)
	for i in range(8):
		get_node("Tools/Colors/Color%d" % i).pressed.connect(func():
			host._finish_gesture()
			selected_color = i
			host._doodle.color = Color(COLORS[i])
		)
	for button in $Tools/Stickers/Grid.get_children():
		button.pressed.connect(func():
			host._finish_gesture()
			host._cancel_sticker()
			host._sticker_image = button.texture_normal.get_image()
			host._sticker_angle = 0.0
			$StickerActions/Rotation.value = 0
			for item in $Tools/Stickers/Grid.get_children():
				item.get_node("Selection").visible = item == button
		)
	$Undo.pressed.connect(func(): history_step(false))
	$Redo.pressed.connect(func(): history_step(true))
	$Tools/Clear.pressed.connect(func():
		host._finish_gesture()
		$Confirm.open()
	)
	$Confirm.confirmed.connect(func():
		host._cancel_sticker()
		host._sticker_last.clear()
		host._sticker_undo = null
		host._doodle.clear()
	)
	$StickerActions/Apply.pressed.connect(host._confirm_sticker)
	$StickerActions/Size.value_changed.connect(func(value: float):
		host._sticker_width = int(value)
		host._sticker_preview_dirty = host._sticker_pending
	)
	$StickerActions/Rotation.value_changed.connect(func(value: float):
		host._sticker_angle = deg_to_rad(value)
		host._sticker_preview_dirty = host._sticker_pending
	)
	select_tool(0)

func history_step(forward: bool) -> void:
	host._finish_gesture()
	if host._sticker_pending:
		host._cancel_sticker()
	else:
		if forward:
			host._doodle.redo()
		else:
			host._doodle.undo()
	host._sticker_last.clear()
	host._sticker_undo = null

func select_tool(value: int) -> void:
	host._finish_gesture()
	host._cancel_sticker()
	_scroll_pointer = -2
	tool = value
	host._sticker_enabled = value == 1
	host._doodle.erasing = value == 2
	if value == 1 and host._sticker_image == null:
		host._sticker_image = $Tools/Stickers/Grid/Sticker0.texture_normal.get_image()
	for i in range(3):
		var names = ["Brush", "Sticker", "Eraser"]
		var icons = ["brush", "sticker", "eraser"]
		get_node("Tools/" + names[i] + "/Background").texture = load("res://res/ui/edit/tool_switch_button_%s.png" % ("selected" if tool == i else "unselected"))
		get_node("Tools/" + names[i] + "/Icon").texture = load("res://res/ui/edit/tool_%s_%d.png" % [icons[i], int(tool == i)])

	refresh_language()

func refresh_language() -> void:
	$Tools/Sizes/Label.text = tr("笔刷")
	for i in range(3):
		get_node("Tools/Sizes/Size%d/Caption" % i).text = tr(["小", "中", "大"][i])
	for pair in [["Brush", "涂鸦"], ["Sticker", "贴纸"], ["Eraser", "橡皮擦"], ["Clear", "清空"]]:
		get_node("Tools/" + pair[0] + "/Caption").text = tr(pair[1])
	$StickerActions/Apply.text = tr("确认")
	$StickerActions/SizeLabel.text = tr("缩放")
	$StickerActions/RotationLabel.text = tr("角度")
	$Undo.tooltip_text = tr("撤销")
	$Redo.tooltip_text = tr("重做")

func _process(_delta: float) -> void:
	if host == null or not is_visible_in_tree():
		return
	$Undo.disabled = not host._sticker_pending and host._doodle.undo_steps.is_empty()
	$Redo.disabled = host._sticker_pending or host._doodle.redo_steps.is_empty()
	for button in [$Undo, $Redo]:
		button.modulate = Color(0.6, 0.6, 0.6, 0.45) if button.disabled else Color.WHITE
	$Tools/Sizes.visible = tool != 1
	$Tools/Colors.visible = tool == 0
	$Tools/Clear.visible = tool == 2
	$Tools/Stickers.visible = tool == 1
	$StickerActions.visible = tool == 1 and host._sticker_pending
	for i in range(3):
		var selected: bool = absf(host._doodle.radius - [5.0, 15.0, 24.0][i]) < 0.1
		get_node("Tools/Sizes/Size%d/Background" % i).visible = selected
		get_node("Tools/Sizes/Size%d/Dot" % i).modulate = Color("#ec8394") if selected else Color.WHITE
		get_node("Tools/Sizes/Size%d/Caption" % i).add_theme_color_override("font_color", Color("#ec8394") if selected else Color("#e0bdc2"))
	for i in range(8):
		get_node("Tools/Colors/Color%d/Ring" % i).visible = i == selected_color

func covers(point: Vector2) -> bool:
	if not is_visible_in_tree():
		return false
	if $Confirm.visible:
		return true
	for child in get_children():
		if child is Control and child.visible and child.mouse_filter != Control.MOUSE_FILTER_IGNORE and child.get_global_rect().has_point(point):
			return true
	return false
