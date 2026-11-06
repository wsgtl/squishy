extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
 print("PASS: " if ok else "FAIL: ",message)
 if not ok:
  failures += 1
func _initialize() -> void:
 call_deferred("run")
func run() -> void:
 var main = load("res://scenes/main.tscn").instantiate()
 root.add_child(main)
 await process_frame
 main._apply_feel(3)
 main._start_game()
 main._physics_process(1.0)
 main._toggle_wax_mode()
 var wax = main._wax_mode
 check(wax.dipping and wax.cup.visible and not main._board.visible,"Mode creates open cup and hides base")
 check(not wax.depth_slider.visible,"Dip slider stays hidden")
 check(wax.color_buttons.size() == 4,"Four wax color choices")
 for i in range(4):
  wax.color_buttons[i].pressed.emit()
  check(wax.liquid_material.albedo_color.is_equal_approx(wax.WAX_COLORS[i]),"Liquid adopts selected color")
  check(is_equal_approx(wax.shell_material.albedo_color.a,0.55),"Wax shell keeps translucent opacity")
 wax._select_color(0)
 check(not wax.status.visible and not wax.fracture_hud.visible,"Dipping hides status text and fracture progress")
 for item in ["WaxButton","ModeBackground","SquishModeButton","DoodleButton","Divider"]:
  check(not main._hud_root.get_node(item).visible,"Wax mode hides " + item)
 wax.finish_dip()
 check(wax.dipping,"An empty dip cannot enter fracture stage")
 wax._set_depth(0.45)
 wax._build_coating()
 check(not wax.patches.is_empty(),"Partial dip generates actual shell geometry")
 var partial := 0
 for patch: Dictionary in wax.patches:
  partial += patch.vertices.size()
  for v: Vector3 in patch.vertices:
   check_height(v.y <= wax.coating_height+wax.radius*wax.WAX_THICKNESS_RATIO+0.0001)
 var covered_height: float = wax.coating_height
 wax._set_depth(0.0)
 check(wax.coating_height == covered_height,"Raising model preserves maximum wet coverage")
 wax._set_depth(1.0)
 wax._build_coating()
 var full := 0
 for patch: Dictionary in wax.patches:
  full += patch.vertices.size()
 check(full > partial,"Deeper immersion covers more surface")
 var original_area := 0.0
 for patch: Dictionary in wax.patches:
  original_area += patch.area
 wax._set_depth(0.0)
 wax._build_coating()
 var old_mesh = wax.shell.mesh
 wax._select_color(1)
 check(wax.shell.mesh == old_mesh,"Selecting liquid color leaves formed coating untouched")
 wax._set_depth(0.5)
 wax._build_coating()
 var colors_seen := {}
 var recolored_area := 0.0
 for patch: Dictionary in wax.patches:
  recolored_area += patch.area
  for color: Color in patch.colors:
   colors_seen[color] = true
 check(colors_seen.has(wax.WAX_COLORS[0]) and colors_seen.has(wax.WAX_COLORS[1]),"Partial redip preserves original and new colors together")
 check(absf(original_area-recolored_area)<original_area*0.001,"Recoloring replaces coverage without overlapping extra area")
 wax._set_depth(1.0)
 wax._build_coating()
 var all_pink := true
 for patch: Dictionary in wax.patches:
  for color: Color in patch.colors:
   all_pink = all_pink and color.is_equal_approx(wax.WAX_COLORS[1])
 check(all_pink,"Full redip replaces all old coating color")
 wax.finish_dip()
 check(not wax.dipping and not wax.cup.visible and main._model_root.position.is_equal_approx(wax.origin),"Lifted model returns to playable position")
 wax._render_shell(0.05)
 check(wax.fracture_hud.visible and wax.fracture_label.text == "0%" and not wax.status.visible,"Fracture stage displays only upper progress")
 check(wax.broken_count == 0,"Rest state does not fracture")
 for sign_value in [-1.0,1.0]:
  var end: Vector3 = main._blob._model_center+Vector3.RIGHT*main._blob._model_size.x*0.5*sign_value
  main._blob.wax_anchor = end
  var pull: Vector3 = Vector3(sign_value,0.4,0)*main._blob._model_radius*0.3
  main._blob.set_wax_drag(pull,0.0)
  check(main._blob._wax_offset(end).dot(pull)>0.0,"Grabbed endpoint follows drag direction")
  check(main._blob._wax_offset(end-Vector3.RIGHT*main._blob._model_size.x*sign_value).length()<pull.length(),"Pull influence fades toward opposite end")
 main._blob.set_wax_drag(Vector3.ZERO,0.0)

 main._model_root.rotate_y(0.5)
 wax._render_shell(0.05)
 check(wax.broken_count == 0,"Rigid model rotation does not fracture wax")
 var started := Time.get_ticks_usec()
 main._blob._smooth_pull = Vector3.RIGHT*main._blob._model_radius*2.0
 wax._render_shell(0.05)
 print("WAX UPDATE ms=",(Time.get_ticks_usec()-started)/1000.0," unique shell vertices=", full)
 check(wax.broken_count > 0,"Local stretch breaks wax into separate patches")
 check(not wax.debris.is_empty() and wax.debris.size()<=wax.MAX_DEBRIS,"Lightweight fragment count is capped")
 var fragment: Dictionary = wax.debris[0]
 var body: Node3D = fragment.node
 check(not body is PhysicsBody3D,"Fragments use no physics body")
 var previous_position := body.global_position
 main._model_root.rotate_x(1.5)
 check(body.global_position.is_equal_approx(previous_position),"Detached debris does not rotate with model")
 body.global_position = Vector3(0,2,0)
 fragment.velocity = Vector3.ZERO
 for frame in range(12):
  wax._step_debris(1.0/60.0)
 check(body.global_position.y < 2.0 and fragment.velocity.y < 0.0,"Lightweight fragments fall along world gravity")
 for frame in range(150):
  wax._step_debris(1.0/60.0)
 check(body.global_position.y > -0.1 and fragment.resting,"Ground bounce settles debris without physics")
 for frame in range(360):
  wax._step_debris(1.0/60.0)
 check(is_instance_valid(body) and body.scale.is_equal_approx(Vector3.ONE),"Landed large fragments persist beyond four seconds")
 for burst in range(40):
  wax._spawn_specks(Vector3(0,1,0))
 check(wax.specks.size() == 240 and wax.speck_visual.multimesh.visible_instance_count == 240,"White speck pool is capped at 240")
 for frame in range(180):
  wax._step_debris(1.0/60.0)
 var landed := 0
 for item: Dictionary in wax.specks:
  landed += int(item.resting)
 check(landed == 240,"White specks remain visible on ground")
 var oldest := 0
 for i in range(wax.specks.size()):
  if wax.specks[i].serial < wax.specks[oldest].serial:
   oldest = i
 var old_serial: int = wax.specks[oldest].serial
 wax._spawn_specks(Vector3(0,1,0))
 check(wax.specks.size() == 240 and wax.specks[oldest].serial > old_serial,"Pool reuses oldest landed specks")

 main._blob._smooth_pull = Vector3.ZERO
 var count: int = wax.broken_count
 wax._render_shell(0.1)
 check(wax.broken_count >= count,"Broken wax remains broken after recovery")
 if "--capture" in OS.get_cmdline_user_args():
  main._blob._sync_gpu()
  await process_frame
  await process_frame
  RenderingServer.force_draw(false)
  root.get_texture().get_image().save_png("/tmp/wax-fracture.png")
  wax.reset_dip()
  wax.depth_slider.value = 0.45
  wax._build_coating()
  main._physics_process(1.0)
  await process_frame
  await process_frame
  RenderingServer.force_draw(false)
  root.get_texture().get_image().save_png("/tmp/wax-dip.png")
 var saved_patches: Array = wax.patches
 wax.patches = [{"area":1.0,"broken":true},{"area":3.0,"broken":false}]
 wax._update_status()
 check(wax.fracture_label.text == "25%","Progress uses coated area rather than fragment count")
 wax.patches[1].broken = true
 wax._update_status()
 check(wax.fracture_label.text == "100%","All broken coating reaches 100 percent")
 wax.patches = saved_patches
 main._hud_root.get_node("ReturnHomeButton").pressed.emit()
 await process_frame
 check(main._wax_mode == null and main._board.visible and not main._home_active,"Back returns to squish rather than home")
 check(main._hud_root.get_node("WaxButton").visible and main._hud_root.get_node("SquishModeButton").visible,"Back restores ordinary game controls")
 for model in [0,1,2]:
  main._apply_feel(model)
  main._toggle_wax_mode()
  var other = main._wax_mode
  other.depth_slider.value = 1.0
  other.finish_dip()
  check(not other.patches.is_empty(),"Generated shell supports product %d" % model)
  other._render_shell(0.05)
  check(other.broken_count == 0,"Product %d starts intact" % model)
  main._blob._anchor_point = main._blob._model_center + Vector3.UP * main._blob._model_size.y * 0.5
  main._blob._anchor_normal = Vector3.UP
  main._blob._press_amount = 1.0
  other._render_shell(0.05)
  check(other.broken_count > 0,"Local press fractures product %d coating" % model)
  main._toggle_wax_mode()
  await process_frame
 main._toggle_wax_mode()
 var flip = main._wax_mode
 main._physics_process(1.0)
 var center_before: Vector3 = flip.mesh_node.to_global(main._blob._model_center)
 var rotation_before: Quaternion = main._model_root.quaternion
 var touch := InputEventScreenTouch.new()
 touch.index = 0
 touch.position = Vector2(8,250)
 touch.pressed = true
 flip._unhandled_input(touch)
 check(flip.rotating,"Blank touch starts a rotation gesture during dip")
 var drag := InputEventScreenDrag.new()
 drag.index = 0
 drag.position = Vector2(48,370)
 flip._input(drag)
 touch.pressed = false
 flip._input(touch)
 check(not main._model_root.quaternion.is_equal_approx(rotation_before),"Vertical blank drag flips model")
 check(flip.depth_slider.value == 0.0,"Blank drag does not adjust dip slider")
 check(flip.mesh_node.to_global(main._blob._model_center).distance_to(center_before)<0.0001,"Flip keeps model center fixed")
 var planes: Array = flip.pending_planes.duplicate()
 flip._build_coating()
 var covered_ok := true
 for patch: Dictionary in flip.patches:
  for v: Vector3 in patch.vertices:
   var wet := false
   for plane: Plane in planes:
    wet = wet or plane.distance_to(v)<flip.radius*flip.WAX_THICKNESS_RATIO+0.0001
   covered_ok = covered_ok and wet
 check(covered_ok,"Tilted dip clips coating to actual horizontal liquid plane")
 main._toggle_wax_mode()
 await process_frame
 check(main._model_root.quaternion.is_equal_approx(rotation_before),"Leaving mode restores original model rotation")
 main.queue_free()
 await process_frame
 print("WAX TEST failures=",failures)
 quit(1 if failures else 0)
func check_height(ok: bool) -> void:
 if not ok:
  failures += 1
  push_error("Coverage extends above recorded liquid boundary")
