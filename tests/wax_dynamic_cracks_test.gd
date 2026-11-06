extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._apply_feel(1)
	main._start_game()
	main._toggle_wax_mode()
	var wax = main._wax_mode
	wax._set_depth(1.0)
	wax.finish_dip()
	var growth = wax.crack_growth
	assert(not growth.started and growth.regions.is_empty(),"Dipping leaves one continuous film")
	var original_area: float = wax.patches[0].area
	wax.drag_id = 0
	wax.gesture_serial = 1
	main._blob.wax_anchor = main._blob._model_center
	main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius,0.0)
	growth.step()
	assert(growth.started,"First pull starts the immutable partition")
	assert(growth.segments_a.is_empty(),"No unrelated preview cracks before partition is ready")
	for frame in range(20000):
		growth.step()
		if growth.ready: break
	assert(growth.ready,"First pull partitions in bounded steps")
	assert(growth.regions.size()>=50 and growth.regions.size()<=80,"Whole film has 50-80 pieces")
	var total_area := 0.0
	for patch: Dictionary in growth.regions: total_area += patch.area
	assert(absf(total_area-original_area)/original_area<0.01,"Partition conserves coated area")
	assert(growth.fragment_count==0,"First pull creates pieces without dropping them")
	assert(growth.segments_a.is_empty(),"Cracks use cell boundaries rather than independent lines")
	assert(growth.fragment_count==0,"Visible cracks precede any falling fragment")
	var visible_regions := 0
	for patch: Dictionary in growth.regions:
		if patch.has("first_visible_gesture"):
			visible_regions += 1
			assert(not patch.boundary.is_empty(),"Visible cracks use actual shell boundaries")
	assert(visible_regions>0 and visible_regions<growth.regions.size(),"First pull reveals a bounded group, not the whole film")
	assert(growth.segments_extent.size()==growth.segments_a.size(),"Every cut has a bounded influence radius")
	for gesture in range(2,9):
		wax.gesture_serial = gesture
		growth.step()
		assert(growth.segments_a.size()<=growth.MAX_CRACK_LINES,"Crack display is bounded")
		if gesture<growth.MIN_LOADED_GESTURES:
			assert(growth.fragment_count==0,"Fragments wait for multiple visible crack stages")
	assert(growth.fragment_count>0,"Repeated pulls release pieces")
	assert(wax.debris.size()==growth.fragment_count,"Each released piece has a visual")
	print("PIECES=",growth.regions.size()," FRAGMENTS=",growth.fragment_count)
	wax.reset_dip()
	assert(wax.crack_growth==null,"Reset clears generated pieces")
	wax._set_depth(1.0)
	wax.finish_dip()
	growth = wax.crack_growth
	wax.drag_id = 0
	wax.gesture_serial = 1
	main._blob.wax_anchor = main._blob._model_center
	main._blob.set_wax_drag(Vector3.UP*main._blob._model_radius,0.0)
	for frame in range(20000):
		growth.step()
		if growth.ready: break
	assert(growth.ready and growth.regions.size()>=50,"Vertical pull partitions the film")
	wax.reset_dip()
	main._toggle_wax_mode()
	main.queue_free()
	await process_frame
	print("DYNAMIC CRACKS PASS")
	quit()
