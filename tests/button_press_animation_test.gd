extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var button := Button.new()
	button.size = Vector2(240, 80)
	button.scale = Vector2(0.8, 1.2)
	var animation = load("res://scripts/button_press_animation.gd").new()
	button.add_child(animation)
	root.add_child(button)
	await process_frame
	var initial := button.scale
	button.button_down.emit()
	animation._tween.custom_step(animation.press_duration)
	assert(button.scale.is_equal_approx(initial * 1.05), "Press scales relative to the original nonuniform scale")
	button.button_up.emit()
	animation._tween.custom_step(animation.release_duration)
	assert(button.scale.is_equal_approx(initial), "Release restores original scale")
	button.button_down.emit()
	animation._tween.custom_step(animation.press_duration * 0.5)
	button.button_up.emit()
	animation._tween.custom_step(animation.release_duration)
	assert(button.scale.is_equal_approx(initial), "Quick press/release does not accumulate scale")
	button.button_down.emit()
	animation._tween.custom_step(animation.press_duration)
	button.hide()
	assert(button.scale.is_equal_approx(initial), "Hiding a pressed button resets its scale")
	button.show()
	button.size = Vector2(300, 100)
	assert(button.pivot_offset.is_equal_approx(button.size * 0.5), "Resizing preserves centered scaling")
	button.queue_free()
	print("BUTTON ANIMATION TESTS: PASS")
	quit()
