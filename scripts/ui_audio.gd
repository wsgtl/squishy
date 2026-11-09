extends Node

## Persistent players keep clicks audible when a button's page is hidden.
const CLICK = preload("res://sound/btn.mp3")
const SHUTTER = preload("res://sound/camera_shutter.wav")
var _click: AudioStreamPlayer
var _shutter: AudioStreamPlayer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_click = AudioStreamPlayer.new()
	var clip: AudioStreamMP3 = CLICK.duplicate()
	clip.loop = false
	_click.stream = clip
	_click.volume_db = -8.0
	add_child(_click)
	_shutter = AudioStreamPlayer.new()
	_shutter.stream = SHUTTER
	_shutter.volume_db = -6.0
	add_child(_shutter)
	get_tree().node_added.connect(_bind_button)
	_bind_tree(get_tree().root)

func _bind_tree(node: Node) -> void:
	_bind_button(node)
	for child in node.get_children():
		_bind_tree(child)

func _bind_button(node: Node) -> void:
	if node is BaseButton:
		var button := node as BaseButton
		var callback: Callable = _play_click.bind(button)
		if not button.pressed.is_connected(callback):
			button.pressed.connect(callback)

func _play_click(button: BaseButton) -> void:
	# Capture and deformation actions have their own sound effects.
	if button.name in ["SceneCaptureButton", "GripButton", "TwistButton", "FlattenButton"]:
		return
	_click.play()

func play_shutter() -> void:
	_shutter.play()
