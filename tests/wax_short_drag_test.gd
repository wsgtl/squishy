extends SceneTree
func _initialize():
 call_deferred("run")
func run():
 var main = load("res://scenes/main.tscn").instantiate()
 root.add_child(main)
 await process_frame
 main._apply_feel(1)
 main._start_game()
 main._toggle_wax_mode()
 var wax = main._wax_mode
 assert(wax.seeds.size()==1,"Dipping must not prepartition fragments")
 wax._set_depth(1.0)
 wax.finish_dip()
 assert(wax.patches.size()==1,"Dipping produces one continuous shell")
 var growth= wax.crack_growth
 assert(not growth.started,"Partition waits for first pull")
 wax.drag_id=0
 main._blob.wax_anchor=main._blob._model_center
 main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius,0.0)
 for gesture in range(20):
  wax.drag_id=0
  wax.gesture_serial+=1
  main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius*0.5,0.0)
  for frame in range(30): growth.step()
  wax.drag_id=-2
  main._blob.set_wax_drag(Vector3.ZERO,0.0)
  for frame in range(30): growth.step()
  assert(growth.segments_a.size()<=growth.MAX_CRACK_LINES,"Display budget remains bounded")
 for frame in range(20000):
  growth.step()
  if growth.ready: break
 assert(growth.ready,"Short pulls still complete the first partition")
 assert(growth.regions.size()>=50 and growth.regions.size()<=80,"Short pulls retain 50-80 pieces")
 for gesture in range(20,28):
  wax.drag_id=0
  wax.gesture_serial+=1
  main._blob.set_wax_drag(Vector3.RIGHT*main._blob._model_radius*0.5,0.0)
  growth.step()
  wax.drag_id=-2
  main._blob.set_wax_drag(Vector3.ZERO,0.0)
 print("VISIBLE=",wax.debris.size())
 assert(wax.debris.size()>=2,"Short grabs must create multiple visible fragments")
 print("REGIONS=",growth.regions.size()," FRAGMENTS=",growth.fragment_count)
 assert(growth.fragment_count>0,"Repeated loading detaches generated regions")
 assert(wax.debris.size()==growth.fragment_count,"All detached pieces remain visible")
 var mesh_before = wax.shell.mesh
 wax.edge_visual_dirty = false
 growth.dirty = false
 wax._process(0.001)
 assert(wax.shell.mesh==mesh_before,"GPU deformation does not rebuild the mesh each frame")
 wax.reset_dip()
 assert(wax.crack_growth==null,"Reset clears crack graph")
 assert(wax.attached_material.get_shader_parameter("crack_count")==0,"Reset removes crack rendering")
 for frame in range(5): await process_frame
 if not DisplayServer.get_name()=="headless":
  await RenderingServer.frame_post_draw
 main._toggle_wax_mode()
 main.queue_free()
 await process_frame
 print("DYNAMIC CRACKS PASS")
 quit()
