extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func report(label: String, samples: Array[float]) -> void:
	samples.sort()
	print("PERF ", label, " median_ms=", samples[samples.size() / 2], " p95_ms=", samples[int(samples.size() * 0.95)])

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_physics_process(false)
	var blob = main._blob
	blob.set_physics_process(false)
	var point: Vector2 = main._camera.unproject_position(blob._external_mesh_instance.to_global(blob._model_center + Vector3.UP * blob._model_size.y * 0.3))
	var hit: Dictionary = main._raycast_blob(point)
	main._begin_pointer(point, false, MOUSE_BUTTON_LEFT)
	var samples: Array[float] = []
	for i in range(120):
		var start := Time.get_ticks_usec()
		blob._physics_process(1.0 / 60.0)
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	report("press_frame", samples)
	samples.clear()
	for i in range(120):
		var start := Time.get_ticks_usec()
		main._move_pointer(point + Vector2(sin(i * 0.1) * 20.0, 0))
		main._physics_process(1.0 / 60.0)
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	report("drag_input", samples)
	blob.begin_interaction(hit.position, true, hit.rest_point, hit.local_normal)
	blob.update_interaction(hit.position + Vector3.ONE)
	samples.clear()
	for i in range(120):
		var start := Time.get_ticks_usec()
		blob._physics_process(1.0 / 60.0)
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	report("stretch_frame", samples)
	quit()
