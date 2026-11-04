extends Control
signal confirmed

func _ready() -> void:
	$Card/Confirm.pressed.connect(func():
		hide()
		confirmed.emit()
	)
	$Card/Cancel.pressed.connect(hide)
	$Shade.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			hide()
	)

func open() -> void:
	$Card/Message.text = tr("清除全部涂鸦和贴纸？")
	$Card/Confirm/Caption.text = tr("确认")
	$Card/Cancel/Caption.text = tr("取消")
	show()
	move_to_front()
