extends RefCounted

# Refine long edges once at model load, sharing midpoints across adjacent faces.
# This preserves UV seams and vertex attributes without per-frame tessellation.
static func refine(arrays: Array, max_edge: float) -> Array:
	var result := arrays.duplicate(true)
	var original_count: int = result[Mesh.ARRAY_VERTEX].size()
	var pending: Array[int] = []
	if result[Mesh.ARRAY_INDEX] != null and not result[Mesh.ARRAY_INDEX].is_empty():
		pending.assign(result[Mesh.ARRAY_INDEX])
	else:
		for i in range(original_count):
			pending.append(i)
	var indices := PackedInt32Array()
	var midpoints := {}
	while not pending.is_empty():
		var c: int = pending.pop_back()
		var b: int = pending.pop_back()
		var a: int = pending.pop_back()
		var vertices: PackedVector3Array = result[Mesh.ARRAY_VERTEX]
		var ab := vertices[a].distance_squared_to(vertices[b])
		var bc := vertices[b].distance_squared_to(vertices[c])
		var ca := vertices[c].distance_squared_to(vertices[a])
		if maxf(ab, maxf(bc, ca)) <= max_edge * max_edge or vertices.size() >= original_count + 12000:
			indices.append_array(PackedInt32Array([a, b, c]))
			continue
		if bc > ab and bc >= ca:
			var old_a := a
			a = b
			b = c
			c = old_a
		elif ca > ab and ca > bc:
			var old_c := c
			c = b
			b = a
			a = old_c
		var key := Vector2i(mini(a, b), maxi(a, b))
		var mid: int = midpoints.get(key, -1)
		if mid < 0:
			mid = vertices.size()
			midpoints[key] = mid
			for slot in range(Mesh.ARRAY_INDEX):
				if result[slot] == null or result[slot].is_empty():
					continue
				var values = result[slot]
				var stride: int = values.size() / mid
				for component in range(stride):
					var value = lerp(values[a * stride + component], values[b * stride + component], 0.5)
					if slot == Mesh.ARRAY_NORMAL:
						value = value.normalized()
					values.append(value)
				result[slot] = values
		pending.append_array([a, mid, c, mid, b, c])
	result[Mesh.ARRAY_INDEX] = indices
	return result
