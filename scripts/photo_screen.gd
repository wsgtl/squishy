extends Control

var _scroll_pointer := -2 # -2 idle, -1 mouse, >=0 touch ID
var _scroll_start := Vector2.ZERO
var _scroll_origin := 0
var _scroll_dragging := false
const SCROLL_DRAG_THRESHOLD := 10.0

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() :
		_scroll_pointer = -2
		return
	# Own the gesture before child Buttons consume it. Real touch events are
	# handled once; their emulated mouse stream must not select a second item.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		if _scroll_pointer >= 0 or $Card/ShareFrame/ShareScroll.get_global_rect().has_point(event.position):
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
	if not $Card/ShareFrame/ShareScroll.get_global_rect().has_point(position):
		return
	_scroll_pointer = pointer
	_scroll_start = position
	_scroll_origin = $Card/ShareFrame/ShareScroll.scroll_horizontal
	_scroll_dragging = false
	get_viewport().set_input_as_handled()

func _drag_scroll(position: Vector2) -> void:
	if position.distance_to(_scroll_start) > SCROLL_DRAG_THRESHOLD:
		_scroll_dragging = true
	if _scroll_dragging:
		$Card/ShareFrame/ShareScroll.scroll_horizontal = _scroll_origin + roundi(_scroll_start.x - position.x)
	get_viewport().set_input_as_handled()

func _end_scroll(position: Vector2, canceled: bool) -> void:
	var tapped := not canceled and not _scroll_dragging and position.distance_to(_scroll_start) <= SCROLL_DRAG_THRESHOLD
	_scroll_pointer = -2
	get_viewport().set_input_as_handled()
	if tapped and $Card/ShareFrame/ShareScroll.get_global_rect().has_point(position):
		for button in $Card/ShareFrame/ShareScroll/Platforms.get_children():
			if button.get_global_rect().has_point(position) and not button.disabled:
				button.pressed.emit()
				break

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_scroll_pointer = -2


func _ready() -> void:
	visibility_changed.connect(func(): _scroll_pointer = -2)
	$Card/PreviewFrame/SceneCapturePreview.resized.connect(_update_preview_mask)
	_update_preview_mask()



func _update_preview_mask() -> void:
	var preview: TextureRect = $Card/PreviewFrame/SceneCapturePreview
	var mask := preview.material as ShaderMaterial
	mask.set_shader_parameter("preview_size", preview.size)
