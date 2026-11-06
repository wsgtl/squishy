extends RefCounted

# First pull fixes a directional 64-cell partition. Both platforms use the
# same bounded seed search and clipping work; fragments remain attached until
# their own damage reaches the release threshold.
const FRAGILE_RATIO := 0.30
const CRACK_SPEED_MULTIPLIER := 1.5
const CRACK_COMPLETE := 0.83 # Shader reveal maximum: 0.65 + 0.18
const TARGET_PIECES := 64
const MAX_FRAGMENTS := TARGET_PIECES
const MAX_CRACK_LINES := 96
const WORK_US := 1100
const WORK_ITEMS := 96
const MIN_LOADED_GESTURES := 5
const CRACKS_PER_GESTURE := 8
const MAX_RELEASES_PER_GESTURE := 3

var owner_mode
var source: Dictionary
var started := false
var ready := false
var dirty := false
var topology_dirty := false
var fragment_count := 0
var regions: Array[Dictionary] = []
var segments_a := PackedVector3Array()
var segments_b := PackedVector3Array()
var segments_extent := PackedFloat32Array()
var seeds := PackedVector3Array()
var candidates := PackedVector3Array()
var pull_axis := Vector3.RIGHT
var first_anchor := Vector3.ZERO
var phase := 0 # waiting, seeds, partition, active
var seed_cursor := 0
var seed_best := -1
var seed_best_distance := -1.0
var triangle_cursor := 0
var built: Array[Dictionary] = []
var vertex_cells := PackedInt32Array()
var cell_planes: Array = []
var last_gesture := -1
var pending_gestures: Array[Dictionary] = []
var network_passes := 0
var load_clock := 0.0
var release_clock := 0.0
var previous_bend := Vector3.ZERO
var sampled_bend := Vector3.ZERO
var speed_exposure := 0.0
var sampled_gesture := -1
var was_pulling := false
var release_rng := RandomNumberGenerator.new()

func setup(mode, patch: Dictionary) -> void:
	owner_mode = mode
	release_rng.randomize()
	source = patch.duplicate(true)

func step(delta: float = 1.0/60.0) -> void:
	var dt := clampf(delta,0.0,0.05)
	var blob = owner_mode.host._blob
	release_clock = maxf(0.0,release_clock-dt)
	var pulling: bool = owner_mode.drag_id != -2 and not owner_mode.rotating and blob.wax_bend.length()>=owner_mode.radius*0.06
	if pulling and phase==0: _begin(blob.wax_anchor,blob.wax_bend)
	if phase==1: _step_seeds()
	elif phase==2: _step_partition()
	# New grabs may reset the anchor/offset: do not count that reset as motion.
	if sampled_gesture!=owner_mode.gesture_serial:
		sampled_gesture = owner_mode.gesture_serial
		sampled_bend = blob.wax_bend
		previous_bend = blob.wax_bend
		speed_exposure = 0.0
		load_clock = 0.0
	var speed: float = blob.wax_bend.distance_to(sampled_bend)/maxf(owner_mode.radius*dt,0.000001)
	sampled_bend = blob.wax_bend
	var recovering: bool = started and owner_mode.drag_id == -2 and (blob.wax_bend.length()>owner_mode.radius*0.003 or speed>0.03)
	if (pulling or recovering) and not regions.is_empty():
		if pulling: last_gesture = owner_mode.gesture_serial
		load_clock += dt
		speed_exposure += _speed_damage_rate(speed)*dt
		if load_clock>=0.05:
			_apply_gesture({"anchor":blob.wax_anchor,"bend":blob.wax_bend,"id":last_gesture,"dt":load_clock,"motion_rate":speed_exposure/load_clock,"recovering":recovering})
			load_clock = 0.0
			speed_exposure = 0.0
	else:
		load_clock = 0.0
		speed_exposure = 0.0
		previous_bend = blob.wax_bend
	if was_pulling and not pulling:
		_queue_rebound_release()
	was_pulling = pulling
	_update_completed_fragments(dt)
	if ready:
		_release_rebound_fragments(dt)

func _begin(anchor: Vector3, bend: Vector3) -> void:
	started = true
	phase = 1
	first_anchor = anchor
	pull_axis = bend.normalized()
	var stride := maxi(1,source.vertices.size()/512)
	for i in range(0,source.vertices.size(),stride):
		candidates.append(source.vertices[i])
	if candidates.is_empty():
		phase = 0
		return
	var closest := 0
	for i in range(candidates.size()):
		if candidates[i].distance_squared_to(anchor)<candidates[closest].distance_squared_to(anchor): closest = i
	seeds.append(candidates[closest])

func _metric(v: Vector3) -> float:
	var along := v.dot(pull_axis)
	return v.length_squared()+along*along*3.0

func _step_seeds() -> void:
	# Stratified candidate selection with varying exclusion distances, not uniform farthest-point cells.
	var rng := RandomNumberGenerator.new()
	rng.seed = 19371
	var order: Array[int] = []
	for i in range(candidates.size()): order.append(i)
	for i in range(order.size()-1,0,-1):
		var j := rng.randi_range(0,i)
		var value := order[i]
		order[i] = order[j]
		order[j] = value
	for pass_index in range(2):
		for index in order:
			var point: Vector3 = candidates[index]
			var spacing: float = owner_mode.radius*rng.randf_range(0.07,0.30)*(1.0 if pass_index==0 else 0.25)
			var valid := true
			for seed: Vector3 in seeds:
				if _metric(point-seed)<spacing*spacing:
					valid = false
					break
			if valid: seeds.append(point)
			if seeds.size()>=TARGET_PIECES:
				_start_partition()
				return
	_start_partition()

func _empty_patch() -> Dictionary:
	return {"vertices":PackedVector3Array(),"normals":PackedVector3Array(),"colors":PackedColorArray(),"indices":PackedInt32Array(),"area":0.0,"center":Vector3.ZERO,"broken":false,"progress":0.0,"loaded_gestures":0,"last_loaded":-1}

func _start_partition() -> void:
	phase = 2
	vertex_cells.resize(source.vertices.size())
	vertex_cells.fill(-1)
	for i in range(seeds.size()):
		var planes: Array[Plane] = []
		for j in range(seeds.size()):
			planes.append(_bisector(seeds[i],seeds[j]) if i!=j else Plane())
		cell_planes.append(planes)
	for seed: Vector3 in seeds:
		var patch := _empty_patch()
		patch.center = seed
		built.append(patch)
		regions.append(patch)
	_assign_toughness()
	dirty = true

func _assign_toughness() -> void:
	# Shuffle once per coating: an exact quota, fixed for each fragment's lifetime.
	var order: Array[int] = []
	for i in range(regions.size()): order.append(i)
	for i in range(order.size()-1,0,-1):
		var j := release_rng.randi_range(0,i)
		var saved := order[i]
		order[i] = order[j]
		order[j] = saved
	var fragile_count := roundi(regions.size()*FRAGILE_RATIO)
	for rank in range(order.size()):
		var patch: Dictionary = regions[order[rank]]
		patch.fragile = rank<fragile_count
		patch.toughness = release_rng.randf_range(0.28,0.48) if patch.fragile else release_rng.randf_range(0.85,2.10)

func _bisector(a: Vector3, b: Vector3) -> Plane:
	var difference := b-a
	var weighted := difference+pull_axis*(difference.dot(pull_axis)*3.0)
	return Plane(weighted,weighted.dot((a+b)*0.5))

func _clip(poly: Array, plane: Plane) -> Array:
	var result: Array = []
	if poly.is_empty(): return result
	var previous: Dictionary = poly.back()
	var pd := plane.distance_to(previous.p)
	for current: Dictionary in poly:
		var cd := plane.distance_to(current.p)
		if (pd<=0.0)!=(cd<=0.0):
			var t := pd/(pd-cd)
			result.append({"p":previous.p.lerp(current.p,t),"n":previous.n.lerp(current.n,t).normalized(),"c":previous.c.lerp(current.c,t)})
		if cd<=0.0: result.append(current)
		previous = current
		pd = cd
	return result

func _step_partition() -> void:
	var deadline := Time.get_ticks_usec()+WORK_US
	var budget := WORK_ITEMS
	while triangle_cursor<source.indices.size() and budget>0 and Time.get_ticks_usec()<deadline:
		_partition_triangle(triangle_cursor)
		triangle_cursor += 3
		budget -= 1
	if triangle_cursor>=source.indices.size(): _finish_partition()

func _vertex_cell(index: int) -> int:
	if vertex_cells[index]>=0: return vertex_cells[index]
	var nearest := INF
	var winner := 0
	var point: Vector3 = source.vertices[index]
	for i in range(seeds.size()):
		var distance := _metric(point-seeds[i])
		if distance<nearest:
			nearest = distance
			winner = i
	vertex_cells[index] = winner
	return winner

func _partition_triangle(offset: int) -> void:
	var triangle: Array = []
	var center := Vector3.ZERO
	var bound := 0.0
	for i in range(3):
		var id: int = source.indices[offset+i]
		var point: Vector3 = source.vertices[id]
		triangle.append({"p":point,"n":source.normals[id],"c":source.colors[id]})
		center += point/3.0
	var cell := _vertex_cell(source.indices[offset])
	if _vertex_cell(source.indices[offset+1])==cell and _vertex_cell(source.indices[offset+2])==cell:
		# Weighted Voronoi cells are convex. Three vertices inside imply the entire
		# triangle is inside: no polygon clipping or pairwise plane work needed.
		_append(built[cell],triangle)
		return
	for vertex: Dictionary in triangle: bound = maxf(bound,vertex.p.distance_to(center))
	var nearest := INF
	for seed: Vector3 in seeds: nearest = minf(nearest,sqrt(_metric(center-seed)))
	for i in range(seeds.size()):
		if sqrt(_metric(center-seeds[i]))>nearest+4.0*bound: continue
		var poly := triangle.duplicate()
		for j in range(seeds.size()):
			if i==j: continue
			poly = _clip(poly,cell_planes[i][j])
			if poly.size()<3: break
		_append(built[i],poly)

func _append(patch: Dictionary, poly: Array) -> void:
	for i in range(1,poly.size()-1):
		var triangle := [poly[0],poly[i],poly[i+1]]
		var area: float = (triangle[1].p-triangle[0].p).cross(triangle[2].p-triangle[0].p).length()*0.5
		if area<owner_mode.radius*owner_mode.radius*0.00000001: continue
		patch.area += area
		for vertex: Dictionary in triangle:
			patch.indices.append(patch.vertices.size())
			patch.vertices.append(vertex.p)
			patch.normals.append(vertex.n)
			patch.colors.append(vertex.c)

func _finish_partition() -> void:
	# Keep IDs and accumulated surface damage stable across geometry completion.
	phase = 3
	ready = true
	topology_dirty = true
	dirty = true
	release_clock = 0.0

func _speed_damage_rate(speed: float) -> float:
	# Superlinear within a bounded range: faster equal-distance motion does more damage.
	var bounded := clampf(speed,0.0,6.0)
	return 0.10*bounded+0.035*bounded*bounded

func _apply_gesture(gesture: Dictionary) -> void:
	var dt: float = gesture.get("dt",0.05)
	var bend: Vector3 = gesture.bend
	var turn := 0.0
	if previous_bend.length()>owner_mode.radius*0.03:
		turn = previous_bend.normalized().angle_to(bend.normalized())
	previous_bend = bend
	var sigma: float = owner_mode.radius*0.45
	var center: Vector3 = owner_mode.host._blob._model_center
	var contact_axis: Vector3 = (gesture.anchor-center).normalized()
	for index in range(regions.size()):
		var patch: Dictionary = regions[index]
		if patch.broken: continue
		var distance: float = patch.center.distance_to(gesture.anchor)
		var facing: float = (patch.center-center).normalized().dot(contact_axis)
		var side_weight: float = lerpf(0.06,1.0,smoothstep(-0.2,0.6,facing))
		var influence: float = exp(-distance*distance/(2.0*sigma*sigma))*side_weight
		var direction_factor: float = 0.35+0.65*absf(bend.normalized().dot(pull_axis))
		var amplitude: float = bend.length()/maxf(owner_mode.radius,0.00001)
		var motion_rate: float = gesture.get("motion_rate",0.0)
		var rate: float = influence*(amplitude*(1.0+turn*2.0)+motion_rate)*direction_factor
		var toughness: float = patch.get("toughness",1.0)
		var previous: float = patch.get("network_progress",0.0)
		patch.network_progress = minf(1.0,previous+dt*rate*0.85*CRACK_SPEED_MULTIPLIER/toughness)
		patch.progress = minf(1.0,patch.progress+dt*rate*0.55/toughness)
		if patch.network_progress>0.12:
			patch.visible_time = patch.get("visible_time",0.0)+dt
		if rate>0.018:
			patch.last_stressed_gesture = gesture.id
		if patch.network_progress>=CRACK_COMPLETE and not patch.has("release_wait"):
			# Sample once at completion: current rebound, next pull, or second pull.
			var roll := release_rng.randf()
			if patch.get("fragile",false):
				patch.release_wait = 0 if roll<0.80 else 1
			else:
				patch.release_wait = 0 if roll<0.45 else (1 if roll<0.80 else 2)
			patch.completed_gesture = gesture.id
			patch.release_timeout = release_rng.randf_range(0.12,0.35) if patch.release_wait==0 else release_rng.randf_range(1.2,2.4)
			if gesture.get("recovering",false) and patch.release_wait==0:
				patch.release_delay = release_rng.randf_range(0.06,0.20)
	dirty = true

func _queue_rebound_release() -> void:
	for patch: Dictionary in regions:
		if patch.broken or not patch.has("release_wait"): continue
		if patch.get("last_stressed_gesture",-1)!=last_gesture: continue
		if patch.get("last_release_gesture",-1)==last_gesture: continue
		patch.last_release_gesture = last_gesture
		if last_gesture!=patch.completed_gesture:
			patch.release_wait = maxi(0,patch.release_wait-1)
		if patch.release_wait==0 and not patch.has("release_delay"):
			patch.release_delay = release_rng.randf_range(0.06,0.28)

func _update_completed_fragments(dt: float) -> void:
	# Start timeout when detached geometry is usable, not while the job is blocked.
	if not ready: return
	for patch: Dictionary in regions:
		if patch.broken or not patch.has("release_wait"): continue
		patch.release_timeout = patch.get("release_timeout",1.2)-dt
		if patch.release_timeout<=0.0 and not patch.has("release_delay"):
			patch.release_delay = 0.0

func _release_rebound_fragments(dt: float) -> void:
	for patch: Dictionary in regions:
		if not patch.broken and patch.has("release_delay"):
			patch.release_delay -= dt
	if release_clock>0.0: return
	var released := 0
	for patch: Dictionary in regions:
		if patch.broken or not patch.has("release_delay"): continue
		if patch.release_delay>0.0 or patch.indices.is_empty(): continue
		if released>=1: break
		patch.broken = true
		patch.dynamic_fragment = true
		owner_mode._dynamic_detach(patch)
		fragment_count += 1
		released += 1
		topology_dirty = true
		dirty = true
	if released>0:
		release_clock = release_rng.randf_range(0.14,0.24)


func _boundary_edges(patch: Dictionary) -> Array:
	var edges := {}
	var unit: float = maxf(owner_mode.radius*0.00001,0.0000001)
	for t in range(0,patch.indices.size(),3):
		for side in range(3):
			var a: Vector3 = patch.vertices[patch.indices[t+side]]
			var b: Vector3 = patch.vertices[patch.indices[t+(side+1)%3]]
			var ka := Vector3i((a/unit).round())
			var kb := Vector3i((b/unit).round())
			var key := str(ka)+"/"+str(kb) if str(ka)<str(kb) else str(kb)+"/"+str(ka)
			if edges.has(key): edges[key].count += 1
			else: edges[key] = {"a":a,"b":b,"count":1}
	var result: Array = []
	for edge: Dictionary in edges.values():
		if edge.count==1 and edge.a.distance_to(edge.b)>unit*2.0:
			result.append(edge)
	return result

func _rebuild_cracks() -> void:
	# Only the immutable cell partition is rendered. No separate crack geometry.
	for patch: Dictionary in regions:
		if not patch.broken and patch.get("network_progress",0.0)>0.0 and not patch.has("first_visible_gesture"):
			patch.first_visible_gesture = last_gesture

func attached_patch() -> Dictionary:
	var result := _empty_patch()
	result.center = owner_mode.host._blob._model_center
	for patch: Dictionary in regions:
		if patch.broken: continue
		var base: int = result.vertices.size()
		result.vertices.append_array(patch.vertices)
		result.normals.append_array(patch.normals)
		result.colors.append_array(patch.colors)
		for index: int in patch.indices: result.indices.append(base+index)
		result.area += patch.area
	return result
