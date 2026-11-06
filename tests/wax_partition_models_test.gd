extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	for feel in range(4):
		main._apply_feel(feel)
		main._start_game()
		main._toggle_wax_mode()
		var wax = main._wax_mode
		wax._set_depth(1.0)
		wax.finish_dip()
		var original_area: float = wax.patches[0].area
		wax.drag_id = 0
		wax.gesture_serial = 1
		main._blob.wax_anchor = main._blob._model_center
		main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius,0.0)
		var growth = wax.crack_growth
		for frame in range(30000):
			growth.step()
			if growth.ready: break
		assert(growth.ready,"Every model finishes its partition")
		assert(growth.regions.size()>=50 and growth.regions.size()<=80,"Every model has 50-80 pieces")
		var area := 0.0
		for patch: Dictionary in growth.regions: area += patch.area
		assert(absf(area-original_area)/original_area<0.02,"Partition keeps the coated surface")
		print("MODEL ",feel," PIECES=",growth.regions.size())
		main._toggle_wax_mode()
		main._game_back()
	main.queue_free()
	await process_frame
	print("ALL MODELS PASS")
	quit()
