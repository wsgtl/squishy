extends Node3D

# Prototype: one batched shell mesh, local strain sampled per patch, no rigid bodies.
const PATCH_COUNT := 72
const MAX_CRACKS_PER_GESTURE := 3
# Preserve fracture progression after reducing visible displacement from 1.5 radii.
const FRACTURE_STRAIN_GAIN := 1.5 / 0.66
var crack_edges: Dictionary = {}
var gesture_edges: Dictionary = {}
var crack_gesture := -1
const WAX_THICKNESS_RATIO := 0.0
const WAX_SURFACE_GAP_RATIO := 0.018
const MAX_DEBRIS := 64
var debris: Array[Dictionary] = []
const MAX_SPECKS := 240
var specks: Array[Dictionary] = []
var speck_visual: MultiMeshInstance3D
var speck_clock := 0
var avoidance_bounds := AABB()
const WAX_COLORS := [Color("f2ead2"), Color("f58cb2"), Color("85c7ef"), Color("ffdf66")]
const WAX_NAMES := ["Clear", "Pink", "Sky", "Yellow"]
const WAX_OPACITY := 0.28
const WAX_STRESSED_OPACITY := 0.96
const WAX_STRESS_COLOR := Color("e9e9e5")
var selected_color := 0
var crack_growth
var attached_material: ShaderMaterial
var shell_material: StandardMaterial3D
var liquid_material: StandardMaterial3D
var color_row: HBoxContainer
var color_buttons: Array[Button] = []
var host: Node3D
var dipping := true
var shell: MeshInstance3D
var cup: Node3D
var panel: VBoxContainer
var depth_slider: HSlider
var status: Label
var fracture_hud: HBoxContainer
var fracture_bar: ProgressBar
var fracture_label: Label
var phase_button: Button
var origin: Vector3
var liquid_y := 0.0
var dip_distance := 1.0
var lift := 0.0
var coating_height := -INF
var patches: Array = []
var elapsed := 0.0
var accumulator := 0.0
var coating_dirty := false
var broken_count := 0
var rng := RandomNumberGenerator.new()
static var partition_cache: Dictionary = {}
var partition_polygons: Array = []
var partition_groups: PackedInt32Array
var cell_planes: Array = []
const EDGE_WORK_BUDGET_US := 700
const EDGE_VERTICES_PER_FRAME := 64
var edge_queue: Array[Dictionary] = []
var edge_visual_dirty := false
var dip_patch_cache: Dictionary = {}
var seeds: PackedVector3Array
var triangle_groups: PackedInt32Array
var mesh_node: MeshInstance3D
var radius := 1.0
var last_shape_hash := 0
var drag_id := -2
var last_drag_y := 0.0
var gesture_serial := 0
var drag_start := Vector2.ZERO
var pull_plane := Plane()
var pull_start := Vector3.ZERO
var pull_initial := Vector3.ZERO
var bend_target := Vector3.ZERO
var twist_target := 0.0
var last_drag_position := Vector2.ZERO
var rotating := false
var original_rotation := Quaternion.IDENTITY
var rotation_offset := Vector3.ZERO
var wet_groups: Array = []
var dry_polygons: Array = []
var pending_planes: Array[Plane] = []
var pending_colors: Array[int] = []
var colored_polygons: Array = []
var clip_plane := Plane(Vector3.UP,0.0)

func _record_liquid_plane() -> void:
	var normal := mesh_node.global_basis.transposed()*Vector3.UP
	var plane := Plane(normal.normalized(),(liquid_y-mesh_node.global_position.y)/normal.length())
	if not pending_planes.is_empty() and pending_colors[-1] == selected_color and pending_planes[-1].normal.is_equal_approx(plane.normal):
		pending_planes[-1].d = maxf(pending_planes[-1].d,plane.d)
	else:
		pending_planes.append(plane)
		pending_colors.append(selected_color)
	coating_dirty = true

func rotate_model(delta: Vector2) -> void:
	var before := mesh_node.to_global(host._blob._model_center)
	host._model_root.global_rotate(Vector3.UP, delta.x*0.008)
	host._model_root.global_rotate(host._camera.global_basis.x.normalized(), delta.y*0.008)
	var correction := before - mesh_node.to_global(host._blob._model_center)
	host._model_root.global_position += correction
	rotation_offset += correction
	if dipping:
		_record_liquid_plane()

func _drag_to(point: Vector2) -> void:
	if rotating:
		rotate_model(point-last_drag_position)
	elif dipping:
		depth_slider.value += (point.y-last_drag_y)/500.0
	else:
		var camera: Camera3D = host._camera
		var world_point: Variant = pull_plane.intersects_ray(camera.project_ray_origin(point),camera.project_ray_normal(point))
		if world_point != null:
			bend_target = (pull_initial + mesh_node.global_basis.inverse()*(world_point-pull_start)).limit_length(radius*host._blob.WAX_MAX_DRAG_RADIUS_RATIO)
			twist_target = 0.0
	last_drag_position = point
	last_drag_y = point.y

func _input(event: InputEvent) -> void:
	if drag_id == -2:
		return
	if event is InputEventMouseMotion and drag_id == -1:
		_drag_to(event.position)
	elif event is InputEventScreenDrag and event.index == drag_id:
		_drag_to(event.position)
	elif (event is InputEventMouseButton and drag_id == -1 and not event.pressed) or (event is InputEventScreenTouch and event.index == drag_id and not event.pressed):
		drag_id = -2
		bend_target = Vector3.ZERO
		twist_target = 0.0
	else:
		return
	get_viewport().set_input_as_handled()

func _begin_surface_drag(point: Vector2) -> bool:
	var hit: Dictionary = host._raycast_blob(point,dipping)
	if hit.is_empty():
		return false
	if not dipping:
		gesture_serial += 1
		# Freeze the grabbed rest point and screen-facing drag plane for this gesture.
		pull_initial = host._blob._wax_offset(hit.rest_point)
		host._blob.wax_anchor = hit.rest_point
		host._blob.set_wax_drag(pull_initial,0.0)
		bend_target = pull_initial
		pull_plane = Plane(host._camera.global_basis.z.normalized(),hit.position)
		var start: Variant = pull_plane.intersects_ray(host._camera.project_ray_origin(point),host._camera.project_ray_normal(point))
		pull_start = start if start != null else hit.position
	return true

func _unhandled_input(event: InputEvent) -> void:
	if drag_id != -2:
		return
	if event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		rotating = not _begin_surface_drag(event.position)
		drag_id = -1
		last_drag_y = event.position.y
		last_drag_position = event.position
		drag_start = event.position
	elif event is InputEventScreenTouch and event.pressed:
		rotating = not _begin_surface_drag(event.position)
		drag_id = event.index
		last_drag_y = event.position.y
		last_drag_position = event.position
		drag_start = event.position
	if drag_id != -2:
		get_viewport().set_input_as_handled()

func setup(scene: Node3D) -> void:
	host = scene
	mesh_node = host._blob._external_mesh_instance
	origin = host._model_root.position
	original_rotation = host._model_root.quaternion
	radius = host._blob._model_radius
	rng.seed = 53712
	var bounds: AABB = mesh_node.mesh.get_aabb()
	var bottom := mesh_node.to_global(bounds.position).y
	var width := maxf(bounds.size.x, bounds.size.z) * mesh_node.global_basis.x.length()
	lift = maxf(width * 0.65, 0.8) + 0.15
	liquid_y = bottom + lift - 0.12
	host._model_root.position.y += lift
	dip_distance = bounds.size.y * mesh_node.global_basis.y.length() + 0.3
	_build_continuous_surface()
	shell = MeshInstance3D.new()
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_node.add_child(shell)
	var mat := StandardMaterial3D.new()
	shell_material = mat
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.42
	mat.metallic_specular = 0.38
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	attached_material = ShaderMaterial.new()
	attached_material.shader = preload("res://shaders/wax_shell.gdshader")
	attached_material.set_shader_parameter("model_radius",radius)
	attached_material.set_shader_parameter("opacity",WAX_OPACITY)
	attached_material.set_shader_parameter("stress_opacity",WAX_STRESSED_OPACITY)
	attached_material.set_shader_parameter("stress_color",WAX_STRESS_COLOR)
	attached_material.set_shader_parameter("strain_gain",FRACTURE_STRAIN_GAIN)
	shell.material_override = attached_material
	shell.extra_cull_margin = radius*3.0
	_build_cup(bounds)
	_build_ui()
	host._board.hide()

func _build_cup(bounds: AABB) -> void:
	cup = Node3D.new()
	add_child(cup)
	var width := maxf(bounds.size.x, bounds.size.z) * mesh_node.global_basis.x.length()
	var r := width * 0.63
	var h := maxf(width * 0.65, 0.8)
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.85, 0.93, 1.0, 0.12)
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Open wall: a solid cylinder would put an opaque lid over the product.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(64):
		var a := Vector3(cos(TAU*i/64.0)*r,0,sin(TAU*i/64.0)*r)
		var b := Vector3(cos(TAU*(i+1)/64.0)*r,0,sin(TAU*(i+1)/64.0)*r)
		for v in [a,b,a+Vector3.UP*h,b,b+Vector3.UP*h,a+Vector3.UP*h]:
			st.add_vertex(v)
	st.generate_normals()
	var wall := MeshInstance3D.new()
	wall.mesh = st.commit()
	wall.material_override = glass
	wall.position.y = liquid_y - h + 0.12
	wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cup.add_child(wall)
	var wax := StandardMaterial3D.new()
	liquid_material = wax
	wax.albedo_color = WAX_COLORS[selected_color]
	wax.roughness = 0.5
	var fluid := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = r * 0.985
	cylinder.bottom_radius = r * 0.985
	cylinder.height = h - 0.12
	cylinder.radial_segments = 64
	fluid.mesh = cylinder
	fluid.material_override = wax
	fluid.position.y = liquid_y - cylinder.height * 0.5
	cup.add_child(fluid)
	for y in [liquid_y+0.12, liquid_y-h+0.12]:
		var rim := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = r-0.012
		torus.outer_radius = r+0.012
		rim.mesh = torus
		var rim_material := StandardMaterial3D.new()
		rim_material.albedo_color = Color("eee9df")
		rim.material_override = rim_material
		rim.position.y = y
		cup.add_child(rim)

func _build_ui() -> void:
	panel = VBoxContainer.new()
	panel.name = "WaxControls"
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 40
	panel.offset_right = -40
	panel.offset_top = -390
	panel.offset_bottom = -180
	panel.add_theme_constant_override("separation", 12)
	host._hud_root.add_child(panel)
	status = Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 22)
	panel.add_child(status)
	status.hide()
	fracture_hud = HBoxContainer.new()
	fracture_hud.name = "WaxFractureProgress"
	fracture_hud.anchor_left = 0.22
	fracture_hud.anchor_right = 0.78
	fracture_hud.anchor_top = 0.17
	fracture_hud.anchor_bottom = 0.17
	fracture_hud.offset_bottom = 40
	fracture_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fracture_hud.add_theme_constant_override("separation", 14)
	host._hud_root.add_child(fracture_hud)
	fracture_bar = ProgressBar.new()
	fracture_bar.show_percentage = false
	fracture_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fracture_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fracture_bar.custom_minimum_size.y = 12
	fracture_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for entry in [["background",Color("cda9b5")],["fill",Color("f45e9f")]]:
		var style := StyleBoxFlat.new()
		style.bg_color = entry[1]
		style.set_corner_radius_all(6)
		fracture_bar.add_theme_stylebox_override(entry[0],style)
	fracture_hud.add_child(fracture_bar)
	fracture_label = Label.new()
	fracture_label.custom_minimum_size.x = 78
	fracture_label.add_theme_font_size_override("font_size",26)
	fracture_label.add_theme_color_override("font_color",Color.WHITE)
	fracture_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fracture_hud.add_child(fracture_label)
	depth_slider = HSlider.new()
	depth_slider.name = "WaxDipDepth"
	depth_slider.min_value = 0
	depth_slider.max_value = 1
	depth_slider.step = 0.005
	depth_slider.custom_minimum_size.y = 64
	depth_slider.add_theme_stylebox_override("slider", _track(Color("f6c1ce")))
	depth_slider.add_theme_stylebox_override("grabber_area", _track(Color("d56b94")))
	depth_slider.value_changed.connect(_set_depth)
	panel.add_child(depth_slider)
	depth_slider.hide()
	color_row = HBoxContainer.new()
	color_row.name = "WaxColors"
	color_row.add_theme_constant_override("separation", 10)
	panel.add_child(color_row)
	for index in range(WAX_COLORS.size()):
		var button := Button.new()
		button.text = WAX_NAMES[index]
		button.custom_minimum_size.y = 58
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 22)
		button.add_theme_color_override("font_color",Color("493943"))
		button.add_theme_color_override("font_hover_color",Color("493943"))
		button.add_theme_color_override("font_pressed_color",Color("493943"))
		button.pressed.connect(func(): _select_color(index))
		color_row.add_child(button)
		color_buttons.append(button)
	_select_color(selected_color)
	phase_button = Button.new()
	phase_button.custom_minimum_size.y = 62
	phase_button.text = tr("提出并开始捏碎")
	phase_button.add_theme_stylebox_override("normal", _track(Color("f3b6c5")))
	phase_button.add_theme_stylebox_override("hover", _track(Color("f8c5d1")))
	phase_button.add_theme_stylebox_override("pressed", _track(Color("dd90a8")))
	phase_button.add_theme_color_override("font_color",Color("964c68"))
	phase_button.pressed.connect(func():
		if dipping:
			finish_dip()
		else:
			reset_dip()
	)
	panel.add_child(phase_button)
	_update_status()

func _track(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

func _select_color(index: int) -> void:
	selected_color = clampi(index,0,WAX_COLORS.size()-1)
	liquid_material.albedo_color = WAX_COLORS[selected_color]
	for i in range(color_buttons.size()):
		var style := _track(WAX_COLORS[i])
		style.border_color = Color.WHITE
		style.set_border_width_all(4 if i == selected_color else 0)
		for state in ["normal","hover","pressed"]:
			color_buttons[i].add_theme_stylebox_override(state,style)

func _set_depth(value: float) -> void:
	host._model_root.position.y = origin.y + rotation_offset.y + lift - value * dip_distance
	var local_height := mesh_node.to_local(Vector3(0, liquid_y, 0)).y
	if local_height > coating_height:
		coating_height = local_height
	_record_liquid_plane()
	_update_status()

func _update_status() -> void:
	status.hide()
	color_row.visible = dipping
	fracture_hud.visible = not dipping
	var total := 0.0
	var broken := 0.0
	var complete := not patches.is_empty()
	for patch: Dictionary in patches:
		total += patch.area
		if patch.broken:
			broken += patch.area
		elif patch.area > radius*radius*0.000001:
			complete = false
	var percent := 100 if complete else mini(99, floori(100.0*broken/maxf(total,0.000001)))
	fracture_bar.value = percent
	fracture_label.text = "%d%%" % percent

func finish_dip() -> void:
	if coating_dirty:
		_build_coating()
	if patches.is_empty():
		status.text = tr("请先向下浸入蜡液")
		status.show()
		return
	crack_growth = preload("res://scripts/wax_crack_growth.gd").new()
	crack_growth.setup(self,patches[0])
	dipping = false
	drag_id = -2
	host._model_root.position = origin + rotation_offset
	cup.hide()
	depth_slider.hide()
	phase_button.text = tr("重新蘸蜡")
	_update_status()

func reset_dip() -> void:
	bend_target = Vector3.ZERO
	twist_target = 0.0
	host._blob.set_wax_drag(Vector3.ZERO,0.0)
	_clear_debris()
	host._finish_gesture()
	host._blob.reset_deformation()
	host._model_root.position = origin + Vector3.UP * lift
	host._model_root.quaternion = original_rotation
	rotation_offset = Vector3.ZERO
	wet_groups.clear()
	dry_polygons.clear()
	crack_growth = null
	attached_material.set_shader_parameter("cell_count",0)
	colored_polygons.clear()
	dip_patch_cache.clear()
	edge_queue.clear()
	crack_edges.clear()
	gesture_edges.clear()
	edge_visual_dirty = false
	pending_colors.clear()
	pending_planes.clear()
	coating_height = -INF
	patches.clear()
	shell.mesh = null
	broken_count = 0
	dipping = true
	cup.show()
	depth_slider.set_value_no_signal(0)
	phase_button.text = tr("提出并开始捏碎")
	_update_status()

func _clip_height(poly: Array, below := true) -> Array:
	var out: Array = []
	if poly.is_empty():
		return out
	var previous: Vector3 = poly.back()
	var previous_distance := -clip_plane.distance_to(previous)
	for point: Vector3 in poly:
		var distance := -clip_plane.distance_to(point)
		if (distance >= 0.0) != (previous_distance >= 0.0):
			out.append(previous.lerp(point,previous_distance/(previous_distance-distance)))
		if (distance >= 0.0) == below:
			out.append(point)
		previous = point
		previous_distance = distance
	return out

func _build_coating() -> void:
	coating_dirty = false
	patches.clear()
	var p: PackedVector3Array = host._blob._rest_positions
	var n: PackedVector3Array = host._blob._rest_normals
	var ix: PackedInt32Array = host._blob._indices
	if colored_polygons.is_empty():
		colored_polygons.resize(partition_polygons.size())
		for t in range(partition_polygons.size()):
			colored_polygons[t] = [{"poly":partition_polygons[t],"color":-1}]
	# Partition each original triangle into disjoint colored polygons. Re-dipping
	# replaces only the submerged part; there is never a second coincident layer.
	for event in range(pending_planes.size()):
		clip_plane = pending_planes[event]
		var color_index: int = pending_colors[event]
		for t in range(colored_polygons.size()):
			var next: Array = []
			for region: Dictionary in colored_polygons[t]:
				if region.color == color_index:
					next.append(region)
					continue
				var wet := _clip_height(region.poly)
				var dry := _clip_height(region.poly,false)
				if wet.size() >= 3:
					next.append({"poly":wet,"color":color_index})
				if dry.size() >= 3:
					next.append({"poly":dry,"color":region.color})
			colored_polygons[t] = next
	pending_planes.clear()
	pending_colors.clear()
	wet_groups.clear()
	var group_colors: Array = []
	for i in range(seeds.size()):
		wet_groups.append([])
		group_colors.append([])
	for t in range(colored_polygons.size()):
		for region: Dictionary in colored_polygons[t]:
			if region.color < 0:
				continue
			var poly: Array = region.poly
			for j in range(1,poly.size()-1):
				wet_groups[partition_groups[t]].append_array([poly[0],poly[j],poly[j+1]])
				group_colors[partition_groups[t]].append_array([region.color,region.color,region.color])
	for group_index in range(wet_groups.size()):
		var vertices: Array = wet_groups[group_index]
		if vertices.is_empty():
			continue
		var signature := hash([vertices,group_colors[group_index]])
		if dip_patch_cache.has(group_index) and dip_patch_cache[group_index].signature == signature:
			patches.append(dip_patch_cache[group_index].patch)
			continue
		var center := Vector3.ZERO
		for v: Vector3 in vertices:
			center += v
		center /= vertices.size()
		var unique := PackedVector3Array()
		var colors := PackedColorArray()
		var smooth_normals := PackedVector3Array()
		var patch_indices := PackedInt32Array()
		var lookup := {}
		var area := 0.0
		for t in range(vertices.size()/3):
			var face_normal: Vector3 = (vertices[t*3+1]-vertices[t*3]).cross(vertices[t*3+2]-vertices[t*3]) * host._blob._normal_sign
			area += face_normal.length()*0.5
			for k in range(3):
				var v: Vector3 = vertices[t*3+k]
				var color_index: int = group_colors[group_index][t*3+k]
				var key := Vector4i(Vector3i((v/maxf(radius*0.000001,0.00000001)).round()).x, Vector3i((v/maxf(radius*0.000001,0.00000001)).round()).y, Vector3i((v/maxf(radius*0.000001,0.00000001)).round()).z, color_index)
				if not lookup.has(key):
					lookup[key] = unique.size()
					unique.append(v)
					var wax_color: Color = WAX_COLORS[color_index]
					wax_color.a = WAX_OPACITY
					colors.append(wax_color)
					smooth_normals.append(Vector3.ZERO)
				var index: int = lookup[key]
				smooth_normals[index] += face_normal
				patch_indices.append(index)
		patches.append({"group":group_index,"damage":0.0,"peak":0.0,"cycle_damage":0.0,"gesture":-1,"strain":0.0,"colors":colors,"area":area,"vertices":unique,"normals":smooth_normals,"indices":patch_indices,"center":center,"threshold":rng.randf_range(0.13,0.28),"broken":false,"time":0.0,"velocity":Vector3.ZERO,"spin":Vector3.ZERO,"basis":Basis.IDENTITY,"anchor":center})
		patches.back().raw_normals = smooth_normals.duplicate()
		dip_patch_cache[group_index] = {"signature":signature,"patch":patches.back()}
	# Share lighting normals across fracture partitions and color boundaries.
	# Intact film is a single thin surface; no internal sidewalls to show seams.
	var shared_normals := {}
	for patch: Dictionary in patches:
		for i in range(patch.vertices.size()):
			var key := Vector3i((patch.vertices[i]/(radius*0.000001)).round())
			shared_normals[key] = shared_normals.get(key,Vector3.ZERO)+patch.raw_normals[i]
	for patch: Dictionary in patches:
		for i in range(patch.vertices.size()):
			var key := Vector3i((patch.vertices[i]/(radius*0.000001)).round())
			patch.normals[i] = shared_normals[key].normalized()
	_render_shell(0.0)

func _process(delta: float) -> void:
	if not dipping:
		var blend := 1.0-exp(-delta*(36.0 if drag_id != -2 else 7.0))
		host._blob.set_wax_drag(host._blob.wax_bend.lerp(bend_target,blend),lerpf(host._blob.wax_twist,twist_target,blend))
	if not dipping and crack_growth != null:
		crack_growth.step(delta)
		if crack_growth.dirty:
			crack_growth.dirty = false
			var cell_seeds := PackedVector3Array()
			var cell_damage := PackedFloat32Array()
			var cell_curl := PackedFloat32Array()
			for region: Dictionary in crack_growth.regions:
				cell_seeds.append(region.center)
				cell_curl.append(region.get("curl",0.0))
				cell_damage.append(0.0 if region.broken else region.get("network_progress",0.0))
			attached_material.set_shader_parameter("cell_count",cell_seeds.size())
			cell_seeds.resize(64)
			cell_damage.resize(64)
			cell_curl.resize(64)
			attached_material.set_shader_parameter("cell_curl",cell_curl)
			attached_material.set_shader_parameter("cell_seeds",cell_seeds)
			attached_material.set_shader_parameter("cell_damage",cell_damage)
			attached_material.set_shader_parameter("partition_axis",crack_growth.pull_axis)
			if crack_growth.topology_dirty:
				crack_growth.topology_dirty = false
				patches[0] = crack_growth.attached_patch()
				edge_visual_dirty = true
	_sync_shell_deformation()
	_step_debris(minf(delta,0.05))
	elapsed += delta
	accumulator += delta
	if accumulator < (1.0/12.0 if dipping else 1.0/24.0):
		return
	var step := accumulator
	accumulator = 0.0
	if dipping:
		if coating_dirty:
			_build_coating()
	elif not patches.is_empty():
		var b = host._blob
		var shape_hash := hash([b.wax_anchor,b.wax_bend,b.wax_twist,b._smooth_pull,b._press_amount,b._squash_amount,b._anchor_point,b._anchor_normal,b._trail_amounts,b._trail_retire_times,b._grab_pressure])
		if edge_visual_dirty or (crack_growth == null and shape_hash != last_shape_hash):
			edge_visual_dirty = false
			_render_shell(step)
			last_shape_hash = shape_hash

func _sync_shell_deformation() -> void:
	# These uniforms use exactly the state just submitted by set_wax_drag().
	attached_material.set_shader_parameter("model_center",host._blob._model_center)
	attached_material.set_shader_parameter("wax_anchor",host._blob.wax_anchor)
	attached_material.set_shader_parameter("wax_bend",host._blob.wax_bend if not dipping else Vector3.ZERO)

func _render_shell(delta: float) -> void:
	var colors := PackedColorArray()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	_sync_shell_deformation()
	var deformer = host._blob
	var eps := radius * 0.08

	for patch: Dictionary in patches:
		var center: Vector3 = patch.center
		var basis := Basis.IDENTITY
		var anchor := center
		if patch.broken or patch.indices.is_empty():
			continue
		elif not dipping:
			anchor = center + deformer._target_offset_for(center)
			var columns: Array[Vector3] = []
			for axis in [Vector3.RIGHT,Vector3.UP,Vector3.BACK]:
				var sample: Vector3 = center + axis*eps
				columns.append((sample+deformer._target_offset_for(sample)-anchor)/eps)
			basis = Basis(columns[0],columns[1],columns[2])
			var strain := maxf(absf(columns[0].length()-1.0),maxf(absf(columns[1].length()-1.0),absf(columns[2].length()-1.0)))
			strain *= FRACTURE_STRAIN_GAIN
			patch.strain = strain

		var points: PackedVector3Array = patch.vertices
		var base := vertices.size()
		var normal_basis := basis.inverse().transposed() if absf(basis.determinant()) > 0.000001 else Basis.IDENTITY
		for i in range(points.size()):
			if dipping:
				vertices.append(points[i])
			else:
				# Exact shared displacement keeps unbroken boundaries welded.
				var opening := 0.0
				vertices.append(points[i]+(center-points[i])*opening*0.045)
			colors.append(patch.colors[i] if dipping else _edge_color(patch,i))
			normals.append(patch.normals[i])
		for index: int in patch.indices:
			indices.append(base+index)
	if vertices.is_empty():
		shell.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	shell.mesh = mesh

func adjust_camera(camera: Camera3D) -> void:
	if not dipping:
		return
	var target: Vector3 = host._look_at_target
	target.y = liquid_y - 0.15
	var offset: Vector3 = camera.position-host._look_at_target
	var horizontal := Vector3(offset.x,0,offset.z).normalized()
	camera.v_offset = -offset.length()*0.12
	camera.position = target + (horizontal*cos(deg_to_rad(28.0))+Vector3.UP*sin(deg_to_rad(28.0))) * offset.length() * 1.45
	camera.look_at(target,Vector3.UP)

func close() -> void:
	host._blob.set_wax_drag(Vector3.ZERO,0.0)
	_clear_debris()
	if is_instance_valid(fracture_hud):
		fracture_hud.queue_free()
	host._model_root.position = origin
	host._model_root.quaternion = original_rotation
	host._board.show()
	if is_instance_valid(shell):
		shell.queue_free()
	if is_instance_valid(panel):
		panel.queue_free()
	queue_free()

func _clear_debris() -> void:
	for fragment: Dictionary in debris:
		if is_instance_valid(fragment.node):
			fragment.node.queue_free()
	debris.clear()
	specks.clear()
	if is_instance_valid(speck_visual):
		speck_visual.multimesh.visible_instance_count = 0

func _step_debris(delta: float) -> void:
	var moving := false
	for fragment: Dictionary in debris:
		moving = moving or not fragment.resting
	for item: Dictionary in specks:
		moving = moving or not item.resting
	if not moving:
		return
	_update_avoidance_bounds()
	_step_specks(delta)
	for i in range(debris.size()-1,-1,-1):
		var fragment: Dictionary = debris[i]
		fragment.age += delta
		var node: Node3D = fragment.node
		if not fragment.resting:
			var flight: float = clampf(fragment.age/fragment.flight_duration,0.0,1.0)
			if not fragment.get("settling",false):
				# Continuous launch-to-landing arc; no instantaneous collision projection.
				node.global_position = fragment.launch.lerp(fragment.landing,flight)
				node.global_position.y += 4.0*fragment.arc_height*flight*(1.0-flight)
			if fragment.get("settling",false):
				fragment.settle_time += delta
				var blend := smoothstep(0.0,0.32,fragment.settle_time)
				var rotation: Quaternion = fragment.settle_rotation.slerp(fragment.flat_rotation,blend)
				node.global_basis = Basis(rotation).scaled(Vector3(1.0,lerpf(1.0,0.12,blend),1.0))
			else:
				node.rotate_x(fragment.spin.x*delta)
				node.rotate_y(fragment.spin.y*delta)
				node.rotate_z(fragment.spin.z*delta)
			# Exact vertex support avoids a rotated AABB suspending curved shards.
			var lowest := INF
			for point: Vector3 in fragment.points:
				lowest = minf(lowest,(node.global_basis*point).y)
			if not fragment.get("settling",false):
				# Blend to the current rotated support height, avoiding a snap on touchdown.
				node.global_position.y += (-0.033-lowest-fragment.landing.y)*smoothstep(0.65,1.0,flight)
			if flight>=1.0 or fragment.get("settling",false):
				node.global_position.y = -0.033-lowest
				fragment.velocity = Vector3.ZERO
				if not fragment.get("settling",false):
					fragment.settling = true
					fragment.settle_time = 0.0
					fragment.settle_rotation = node.global_basis.get_rotation_quaternion()
				if fragment.settle_time>=0.32:
					fragment.resting = true

func _spawn_fragment(patch: Dictionary, anchor: Vector3, basis: Basis) -> void:
	_update_avoidance_bounds()
	var launch := mesh_node.to_global(anchor)
	_spawn_specks(launch)
	# Skip additional visuals before allocating/uploading meshes in a mass break.
	if debris.size() >= MAX_DEBRIS:
		return
	var world_basis := mesh_node.global_basis*basis
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var normal_basis := world_basis.inverse().transposed()
	for i in range(patch.vertices.size()):
		var local: Vector3 = patch.vertices[i]-patch.center
		if patch.get("dynamic_fragment",false):
			local += host._blob._wax_offset(patch.vertices[i])-host._blob._wax_offset(patch.center)
			var relative: Vector3 = patch.vertices[i]-patch.center
			var extent := maxf(radius*0.24,0.00001)
			var edge := clampf(relative.length()/extent,0.0,1.0)
			local += patch.normals[i]*radius*0.055*edge*edge*patch.get("curl",0.0)
		points.append(world_basis*local)
		normals.append((normal_basis*patch.normals[i]).normalized())
	var average_normal := Vector3.ZERO
	for normal: Vector3 in normals: average_normal += normal
	if average_normal.length_squared()<0.000001: average_normal = Vector3.UP
	var flat_rotation := Quaternion(average_normal.normalized(),Vector3.UP)
	var clearance := 0.0
	for point: Vector3 in points: clearance = maxf(clearance,point.length())
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = _fragment_colors(patch)
	arrays[Mesh.ARRAY_INDEX] = patch.indices
	var fragment_mesh := ArrayMesh.new()
	fragment_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var visual := MeshInstance3D.new()
	visual.mesh = fragment_mesh
	visual.material_override = shell_material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
	visual.global_position = launch
	var outward := _launch_direction(launch)
	var horizontal_box := avoidance_bounds.grow(clearance+0.04)
	var half := horizontal_box.size*0.5
	var edge_distance := minf(half.x/maxf(absf(outward.x),0.00001),half.z/maxf(absf(outward.z),0.00001))
	var landing := horizontal_box.get_center()+outward*(edge_distance+0.04)
	var lowest := INF
	for point: Vector3 in points: lowest = minf(lowest,point.y)
	landing.y = -0.035-lowest
	var flight_duration := rng.randf_range(0.5,0.7)
	var arc_height := maxf(0.16,avoidance_bounds.size.y*0.35+(launch.y-landing.y)*0.30)
	debris.append({"node":visual,"bounds":fragment_mesh.get_aabb(),"age":0.0,"resting":false,"bounces":0,
		"points":points,"clearance":clearance,"flat_rotation":flat_rotation,
		"launch":launch,"landing":landing,"flight_duration":flight_duration,"arc_height":arc_height,
		"velocity":outward*rng.randf_range(0.12,0.22)+Vector3.UP*rng.randf_range(0.15,0.28),
		"spin":Vector3(rng.randf_range(-2,2),rng.randf_range(-2,2),rng.randf_range(-2,2))})

func _update_avoidance_bounds() -> void:
	# Conservative world box around sampled deformation; avoids expensive mesh collision.
	var box: AABB = mesh_node.mesh.get_aabb()
	var first := true
	for x in range(3):
		for y in range(3):
			for z in range(3):
				var p := box.position+box.size*Vector3(x,y,z)*0.5
				var world := mesh_node.to_global(p+host._blob._target_offset_for(p))
				if first:
					avoidance_bounds = AABB(world,Vector3.ZERO)
					first = false
				else:
					avoidance_bounds = avoidance_bounds.expand(world)
	avoidance_bounds = avoidance_bounds.grow(0.025)

func _launch_direction(point: Vector3) -> Vector3:
	var direction := point-avoidance_bounds.get_center()
	direction.y = 0
	return direction.normalized() if direction.length_squared()>0.00001 else Vector3.RIGHT

func _outside_model(point: Vector3, padding: float) -> Vector3:
	var box := avoidance_bounds.grow(padding)
	if not box.has_point(point):
		return point
	var direction := _launch_direction(point)
	var half := box.size*0.5
	var distance := minf(half.x/maxf(absf(direction.x),0.00001),half.z/maxf(absf(direction.z),0.00001))+0.002
	var result := box.get_center()+direction*distance
	result.y = point.y
	return result

func _ensure_speck_pool() -> void:
	if is_instance_valid(speck_visual):
		return
	speck_visual = MultiMeshInstance3D.new()
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	var dot := BoxMesh.new()
	dot.size = Vector3.ONE
	batch.mesh = dot
	batch.instance_count = MAX_SPECKS
	batch.visible_instance_count = 0
	speck_visual.multimesh = batch
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("fff9ed")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	speck_visual.material_override = material
	speck_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(speck_visual)

func _spawn_specks(point: Vector3) -> void:
	_ensure_speck_pool()
	for i in range(8):
		var slot := specks.size()
		if slot >= MAX_SPECKS:
			slot = 0
			for j in range(specks.size()):
				if (specks[j].resting and not specks[slot].resting) or (specks[j].resting == specks[slot].resting and specks[j].serial < specks[slot].serial):
					slot = j
		var start := _outside_model(point,0.015)
		var direction := _launch_direction(start).rotated(Vector3.UP,rng.randf_range(-0.35,0.35))
		speck_clock += 1
		var item := {"position":start,"velocity":direction*rng.randf_range(0.5,1.4)+Vector3.UP*rng.randf_range(0.5,1.5),"resting":false,"serial":speck_clock,"size":rng.randf_range(0.006,0.012)}
		if slot == specks.size():
			specks.append(item)
		else:
			specks[slot] = item
	speck_visual.multimesh.visible_instance_count = specks.size()
	_step_specks(0.0)

func _step_specks(delta: float) -> void:
	if specks.is_empty():
		return
	for i in range(specks.size()):
		var item: Dictionary = specks[i]
		if item.resting:
			continue
		if not item.resting:
			item.velocity.y -= 9.8*delta
			item.position += item.velocity*delta
			item.position = _outside_model(item.position,item.size)
			if item.position.y <= -0.035+item.size*0.5:
				item.position.y = -0.035+item.size*0.5
				item.resting = true
		var pose := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*item.size),item.position)
		speck_visual.multimesh.set_instance_transform(i,pose)

func _edge_color(patch: Dictionary, index: int) -> Color:
	return patch.colors[index]

func _stressed_color(patch: Dictionary, index: int) -> Color:
	# Bake the same continuous field into detached fragments at release time.
	var point: Vector3 = patch.vertices[index]
	
	var sigma := maxf(radius*0.65,0.00001)
	var distance: float = point.distance_to(host._blob.wax_anchor)
	var strain: float = host._blob.wax_bend.length()*distance*exp(-distance*distance/(2.0*sigma*sigma))/(sigma*sigma)
	var whitening := smoothstep(0.0,0.75,clampf(strain*FRACTURE_STRAIN_GAIN*0.65,0.0,0.45))
	var edge_color := _edge_color(patch,index)
	var color := edge_color.lerp(WAX_STRESS_COLOR,whitening)
	color.a = lerpf(edge_color.a,WAX_STRESSED_OPACITY,whitening)
	return color

func _fragment_colors(patch: Dictionary) -> PackedColorArray:
	var result := PackedColorArray()
	for i in range(patch.colors.size()):
		result.append(_stressed_color(patch,i))
	return result

# Only affected patches enter the queue. A complete weight set fades in together,
# so incremental calculation never appears as a moving line of white vertices.
func _build_continuous_surface() -> void:
	# Only the original continuous surface is built while dipping: no seeds/cells.
	seeds = PackedVector3Array([Vector3.ZERO])
	var blob = host._blob
	for t in range(blob._indices.size()/3):
		var poly: Array = []
		for k in range(3):
			var index: int = blob._indices[t*3+k]
			poly.append(blob._rest_positions[index]+blob._rest_normals[index]*radius*WAX_SURFACE_GAP_RATIO)
		partition_polygons.append(poly)
		partition_groups.append(0)

func _dynamic_detach(patch: Dictionary) -> void:
	var center: Vector3 = patch.center
	var blob = host._blob
	var anchor: Vector3 = center+blob._wax_offset(center)
	_spawn_fragment(patch,anchor,Basis.IDENTITY)
	patches.append(patch)
	broken_count += 1
	patches[0].area = maxf(0.0,patches[0].area-patch.area)
	_update_status()
