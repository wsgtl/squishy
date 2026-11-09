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
	wax.drag_id = 0
	wax.gesture_serial = 1
	main._blob.wax_anchor = main._blob._model_center
	main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius*0.5,0.0)
	growth.step(0.05)
	assert(not growth.regions.is_empty(),"First pull exposes final cell IDs before clipping completes")
	var tiers := [0,0,0]
	for patch: Dictionary in growth.regions:
		tiers[patch.fatigue_tier] += 1
		assert(patch.toughness==growth.FATIGUE_THRESHOLDS[patch.fatigue_tier])
	assert(absi(tiers[0]-tiers[2])<=1,"Three fatigue tiers have equal quotas")
	var seeds_before: PackedVector3Array = growth.seeds.duplicate()
	var initial: float = growth.regions[0].network_progress
	for i in range(12): growth.step(0.05)
	assert(growth.regions[0].network_progress>initial,"Same gesture accumulates damage during the hold")
	assert(growth.fragment_count==0,"Early visible cracking precedes detachment")
	wax.drag_id = -2
	main._blob.set_wax_drag(Vector3.ZERO,0.0)
	growth.sampled_bend = Vector3.ZERO
	var stopped: float = growth.regions[0].network_progress
	for i in range(20000):
		growth.step(0.016)
		if growth.ready: break
	assert(growth.ready,"Bounded partition completes")
	assert(growth.seeds==seeds_before,"Displayed and detached cells retain identical seeds")
	assert(is_equal_approx(growth.regions[0].network_progress,stopped),"Rest and background work do not accumulate fatigue")
	# Equal travel produces more motion damage when performed faster.
	assert(growth._speed_damage_rate(2.0)*0.5>growth._speed_damage_rate(1.0))
	var recovering_patch: Dictionary = growth.regions[0]
	recovering_patch.network_progress = 0.0
	main._blob.wax_anchor = recovering_patch.center
	growth.sampled_bend = Vector3.RIGHT*main._blob._model_radius*0.4
	main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius*0.2,0.0)
	growth.step(0.05)
	assert(recovering_patch.network_progress>0.0,"Actual rebound still adds fatigue")
	main._blob.set_wax_drag(Vector3.ZERO,0.0)
	growth.sampled_bend = Vector3.ZERO
	# Deterministic timeout path: no new gesture or extra fatigue is required.
	var target: Dictionary = {}
	for patch: Dictionary in growth.regions:
		if not patch.indices.is_empty():
			target = patch
			break
	assert(not target.is_empty())
	target.network_progress = growth.CRACK_COMPLETE
	target.curl_age = 0.0
	var before: int = growth.fragment_count
	for i in range(30): growth.step(0.05)
	assert(not target.broken,"Resting state cannot drain queued fragments")
	assert(is_zero_approx(target.curl_age),"Resting state pauses fracture progression")
	wax.drag_id = 0
	main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius*0.2,0.0)
	for i in range(10): growth.step(0.05)
	assert(target.broken,"Completed fragment resumes curl and release during an actual pull")
	assert(is_equal_approx(target.curl,1.0),"Curl completes before release")
	assert(growth.fragment_count>before)
	# A backlog may release only one piece until the global cooldown expires.
	var queued := 0
	for patch: Dictionary in growth.regions:
		if not patch.broken and not patch.indices.is_empty():
			patch.release_delay = 0.0
			queued += 1
	assert(queued>=2)
	growth.release_clock = 0.0
	before = growth.fragment_count
	growth._release_rebound_fragments(0.016)
	assert(growth.fragment_count==before+1,"Backlog releases only one piece")
	growth._release_rebound_fragments(0.016)
	assert(growth.fragment_count==before+1,"Consecutive frames cannot drain backlog")
	main.queue_free()
	await process_frame
	print("CONTINUOUS LOAD PASS")
	quit()
