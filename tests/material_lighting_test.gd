extends SceneTree

const Profiles = preload("res://scripts/model_profiles.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(720, 1280)
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var lights: Array[Light3D] = []
	var shadow_count := 0
	for child in main.get_children():
		if child is Light3D:
			lights.append(child)
			if child.shadow_enabled:
				shadow_count += 1
	check(lights.size() == 2 and shadow_count == 1, "Two shared lights, one shadow caster")
	for index in [1, 2, 3, 0, 1]:
		main._apply_feel(index)
		await process_frame
		var blob = main._blob
		var source: StandardMaterial3D = blob._source_material
		var shader: ShaderMaterial = blob._shader_material
		var profile: Dictionary = Profiles.material_for(main._active_model_path)
		check(shader.get_shader_parameter("albedo_texture") == source.albedo_texture, "Imported albedo preserved")
		check(shader.get_shader_parameter("base_color") == source.albedo_color, "Imported base color preserved")
		check(is_equal_approx(source.roughness, 1.0) and is_equal_approx(source.metallic_specular, 0.5), "Shared source material not mutated")
		check(is_equal_approx(shader.get_shader_parameter("material_specular"), profile.get("material_specular", source.metallic_specular)), "Per-model specular without profile leaks")
		for parameter in profile:
			check(is_equal_approx(shader.get_shader_parameter(parameter), profile[parameter]), "Profile applied: " + parameter)
		check(is_equal_approx(lights[0].light_energy, 0.42) and is_equal_approx(lights[1].light_energy, 0.12), "Switching models preserves lighting")
		if "--capture" in OS.get_cmdline_user_args() and index != 0:
			main._start_game()
			main._physics_process(1.0)
			await process_frame
			await process_frame
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-material-%d.png" % index)
			blob.set_grip_axis(Vector3.RIGHT)
			blob.set_grip_held(true)
			for frame in range(90):
				blob._physics_process(1.0 / 60.0)
				main._physics_process(1.0 / 60.0)
			await process_frame
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-material-grip-%d.png" % index)
			blob.cancel_grip()
	main.queue_free()
	await process_frame
	print("MATERIAL LIGHTING TESTS: ", failures)
	quit(1 if failures else 0)
