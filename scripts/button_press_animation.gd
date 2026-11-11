extends Node
class_name ButtonPressAnimation

## Add as a child of any BaseButton. Scale is relative to its authored scale.
@export_range(1.0, 1.5, 0.01) var pressed_multiplier := 1.05
@export_range(0.0, 0.5, 0.01) var press_duration := 0.08
@export_range(0.0, 0.5, 0.01) var release_duration := 0.12

@export var pressed_texture: Texture2D
@export_node_path("TextureRect") var background_path: NodePath = NodePath("../Background")

var _background: TextureRect
var _normal_texture: Texture2D
var _button: BaseButton
var _initial_scale := Vector2.ONE
var _tween: Tween

func _ready() -> void:
	_button = get_parent() as BaseButton
	if _button == null:
		push_warning("ButtonPressAnimation must be a child of a BaseButton.")
		return
	_background = get_node_or_null(background_path) as TextureRect
	if _background != null:
		_normal_texture = _background.texture
	_initial_scale = _button.scale
	_center_pivot()
	_button.resized.connect(_center_pivot)
	_button.button_down.connect(func(): _animate(pressed_multiplier, press_duration))
	_button.button_up.connect(func(): _animate(1.0, release_duration))
	_button.visibility_changed.connect(func():
		if not _button.is_visible_in_tree():
			reset()
	)

func _center_pivot() -> void:
	_button.pivot_offset = _button.size * 0.5

func _animate(multiplier: float, duration: float) -> void:
	if _background != null and pressed_texture != null:
		_background.texture = pressed_texture if multiplier > 1.0 else _normal_texture
	if _tween != null:
		_tween.kill()
	if not _button.is_visible_in_tree() or duration <= 0.0:
		_button.scale = _initial_scale * multiplier
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_button, "scale", _initial_scale * multiplier, duration)

func reset() -> void:
	if _button == null:
		return
	if _tween != null:
		_tween.kill()
	_button.scale = _initial_scale
	if _background != null and pressed_texture != null:
		_background.texture = _normal_texture

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		reset()
