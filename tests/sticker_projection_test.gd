extends SceneTree

const Projector = preload("res://scripts/sticker_projector.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if ok:
		print("PASS: ", message)
	else:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var source := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	source.fill(Color.RED)
	source.fill_rect(Rect2i(16, 0, 16, 32), Color.GREEN)
	source.fill_rect(Rect2i(0, 0, 32, 8), Color.BLUE)
	var positions := PackedVector3Array([Vector3(-1,-1,0), Vector3(1,-1,0), Vector3(1,1,0), Vector3(-1,1,0)])
	var normals := PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	var indices := PackedInt32Array([0,1,2,0,2,3])
	var pose := {"center": Vector3.ZERO, "normal": Vector3.BACK, "up": Vector3.UP}
	for layout in [PackedVector2Array([Vector2(0,1),Vector2(1,1),Vector2(1,0),Vector2(0,0)]), PackedVector2Array([Vector2(0,0),Vector2(0,1),Vector2(1,1),Vector2(1,0)]), PackedVector2Array([Vector2(1,1),Vector2(0,1),Vector2(0,0),Vector2(1,0)])]:
		var projector = Projector.new()
		projector.build(positions, normals, layout, indices, Vector3(2,2,0))
		var base := Image.create(128,128,false,Image.FORMAT_RGBA8)
		base.fill(Color.TRANSPARENT)
		var canvas := base.duplicate() as Image
		var rects: Array = projector.bake(canvas, base, source, pose, 1.0, 0.0, [])
		# Sample the physical left/right/top, independent of the UV layout.
		for sample in [[Vector2(-0.25,0),Color.RED], [Vector2(0.25,0),Color.GREEN], [Vector2(0,0.4),Color.BLUE]]:
			var s: Vector2 = (sample[0] + Vector2.ONE) * 0.5
			var uv: Vector2 = layout[0] + (layout[1]-layout[0])*s.x + (layout[3]-layout[0])*s.y
			check(canvas.get_pixelv(Vector2i((uv * 127.0).round())).is_equal_approx(sample[1]), "Surface direction and aspect independent of rotated/mirrored UV")
		var rotated := base.duplicate() as Image
		projector.bake(rotated,base,source,pose,1.0,PI*0.5,[])
		var right_uv: Vector2 = layout[0] + (layout[1]-layout[0])*0.7 + (layout[3]-layout[0])*0.5
		check(rotated.get_pixelv(Vector2i((right_uv*127.0).round())).is_equal_approx(Color.BLUE), "Angle control rotates relative to the surface frame")
		var moved: Dictionary = pose.duplicate()
		moved.center = Vector3(0.65,0,0)
		projector.bake(canvas,base,source,moved,0.3,0.0,rects)
		check(canvas.get_pixel(64,64).a == 0.0, "Moving preview restores old footprint")
		var back_pose := {"center": Vector3.ZERO,"normal":Vector3.FORWARD,"up":Vector3.UP}
		canvas = base.duplicate()
		projector.bake(canvas,base,source,back_pose,1.0,0.0,[])
		check(canvas.get_used_rect().size == Vector2i.ZERO, "Back-facing faces are not painted")
		var translucent := source.duplicate() as Image
		translucent.fill(Color(1,0,0,0.25))
		canvas = base.duplicate()
		rects = projector.bake(canvas,base,translucent,pose,1.0,0.0,[])
		projector.bake(canvas,base,translucent,pose,1.0,0.0,rects)
		check(absf(canvas.get_pixel(64,64).a-0.25)<0.005,"Repeated previews and shared triangle edges preserve opacity")
	root.size = Vector2i(720,1280)
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._start_game()
	main._set_doodle_enabled(true)
	main._sticker_enabled = true
	for model in [3,1,2]:
		main._apply_feel(model)
		main._physics_process(1.0)
		await process_frame
		var point := Vector2(360,480)
		var hit: Dictionary = main._raycast_blob(point,true)
		check(not hit.is_empty(), "Actual product surface is pickable")
		if hit.is_empty():
			continue
		# Dragging around a curved surface must not accumulate roll. The same
		# destination must match a fresh placement, regardless of the route.
		main._sticker_pose.clear()
		main._update_sticker_pose(hit)
		var initial_up: Vector3 = main._sticker_pose.up
		var camera_basis: Basis = main._blob._external_mesh_instance.global_basis.inverse() * main._camera.global_basis
		for direction in [Vector3(0.65,0.0,1.0), Vector3(0.55,0.6,1.0), Vector3(-0.3,0.5,1.0), Vector3(0.0,0.0,1.0)]:
			var normal: Vector3 = (camera_basis * direction.normalized()).normalized()
			main._update_sticker_pose({"rest_point": hit.rest_point, "local_normal": normal})
			var expected := Projector.surface_up(normal, camera_basis.y.normalized(), camera_basis.x.normalized())
			check(main._sticker_pose.up.is_equal_approx(expected), "Moving across curved normals keeps camera alignment")
		main._update_sticker_pose(hit)
		check(main._sticker_pose.up.is_equal_approx(initial_up), "Returning to initial point restores exact initial orientation")
		main._sticker_pose.clear()
		main._sticker_image = source
		var started := Time.get_ticks_usec()
		main._begin_drawing(point,-1)
		var cache_us := Time.get_ticks_usec()-started
		main._drawing = false
		started = Time.get_ticks_usec()
		main._refresh_sticker_preview(true)
		print("MODEL ", model," cache_ms=", cache_us/1000.0," bake_ms=", (Time.get_ticks_usec()-started)/1000.0," triangles=",main._sticker_projector.last_triangles," pixels=",main._sticker_projector.last_pixels)
		check(main._sticker_projector.last_pixels > 0,"Actual product accepts surface projection")
		var before: PackedByteArray = main._sticker_base.get_data()
		main._confirm_sticker()
		var after: PackedByteArray = main._doodle.image.get_data()
		check(before != after,"Confirm bakes projection")
		main._doodle.undo()
		check(main._doodle.image.get_data() == before,"Undo restores exact pre-projection image")
		main._doodle.redo()
		check(main._doodle.image.get_data() == after,"Redo restores baked projection")
		if model == 3:
			main._cancel_sticker()
			check(main._begin_drawing(Vector2(360,625),-1),"Side surface supports placement")
			main._drawing = false
			main._refresh_sticker_preview(true)
			check(main._sticker_projector.last_pixels>0,"Side UV island accepts projection")
			main._draw_to(Vector2(360,480))
			check(main._sticker_pose.normal.is_finite() and main._sticker_pose.up.is_finite() and absf(main._sticker_pose.up.dot(main._sticker_pose.normal))<0.001,"Dragging across an edge keeps a valid surface frame")
			main._cancel_sticker()
		if "--capture" in OS.get_cmdline_user_args():
			main._doodle.clear()
			main._hud_root.get_node("Edit").select_tool(1)
			main._sticker_image = load("res://res/ui/edit/stickers/28_sticker_kiwi_slice.png").get_image()
			main._begin_drawing(point,-1)
			main._drawing = false
			main._refresh_sticker_preview(true)
			main._doodle.flush()
			await process_frame
			await process_frame
			RenderingServer.force_draw(false)
			root.get_texture().get_image().save_png("/tmp/nienie-projection-%d.png" % model)
			if model == 3:
				main._draw_to(Vector2(410,465))
				main._refresh_sticker_preview(true)
				main._doodle.flush()
				await process_frame
				await process_frame
				RenderingServer.force_draw(false)
				root.get_texture().get_image().save_png("/tmp/nienie-projection-moved.png")
				main._draw_to(Vector2(360,625))
				main._refresh_sticker_preview(true)
				main._doodle.flush()
				await process_frame
				await process_frame
				RenderingServer.force_draw(false)
				root.get_texture().get_image().save_png("/tmp/nienie-projection-side.png")
			main._cancel_sticker()
	main.queue_free()
	await process_frame
	print("STICKER PROJECTION TESTS: ", failures)
	quit(1 if failures else 0)
