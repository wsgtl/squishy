extends RefCounted

# Rest-space surface projection. A spatial grid is built once per model.
# The result uses the existing ink atlas, with no persistent decal draw calls.
var positions: PackedVector3Array
var normals: PackedVector3Array
var uvs: PackedVector2Array
var indices: PackedInt32Array
var cells: Dictionary = {}
var cell_size := 0.2
var last_triangles := 0
var last_pixels := 0
var _source_original: Image
var _source_ready: Image

func build(p: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, ix: PackedInt32Array, size: Vector3) -> void:
	positions = p
	normals = n
	uvs = uv
	indices = ix
	cell_size = maxf(size[size.max_axis_index()] / 12.0, 0.001)
	cells.clear()
	for triangle in range(indices.size() / 3):
		var a := positions[indices[triangle * 3]]
		var b := positions[indices[triangle * 3 + 1]]
		var c := positions[indices[triangle * 3 + 2]]
		var low := Vector3i((a.min(b).min(c) / cell_size).floor())
		var high := Vector3i((a.max(b).max(c) / cell_size).floor())
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					var key := Vector3i(x, y, z)
					if not cells.has(key):
						cells[key] = []
					cells[key].append(triangle)

# Align to a fixed reference rather than accumulating rotation from drag history.
static func surface_up(normal: Vector3, preferred: Vector3, fallback: Vector3) -> Vector3:
	var up := preferred - normal * preferred.dot(normal)
	if up.length_squared() < 0.0001:
		up = fallback - normal * fallback.dot(normal)
	if up.length_squared() < 0.0001:
		up = normal.cross(Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP)
	return up.normalized()

# Clip in projector space, keeping UVs attached to vertices. This avoids
# scanning the full atlas-sized bounds of large triangles for a small sticker.
func _clip(poly: Array, axis: int, limit: float, sign_value: float) -> Array:
	var result: Array = []
	if poly.is_empty():
		return result
	var previous: Dictionary = poly.back()
	var previous_distance: float = limit - previous.p[axis] * sign_value
	for current: Dictionary in poly:
		var distance: float = limit - current.p[axis] * sign_value
		if (distance >= 0.0) != (previous_distance >= 0.0):
			var t := previous_distance / (previous_distance - distance)
			result.append({"p": previous.p.lerp(current.p, t), "uv": previous.uv.lerp(current.uv, t)})
		if distance >= 0.0:
			result.append(current)
		previous = current
		previous_distance = distance
	return result

# Restore only the previous projected footprint, then rasterize candidate faces.
func bake(canvas: Image, base: Image, source: Image, pose: Dictionary, width: float, angle: float, previous_rects: Array) -> Array:
	for rect: Rect2i in previous_rects:
		canvas.blit_rect(base, rect, rect.position)
	var rects: Array = []
	last_triangles = 0
	last_pixels = 0
	if source == null or pose.is_empty():
		return rects
	if source != _source_original:
		_source_original = source
		_source_ready = source.duplicate() as Image
		if _source_ready.is_compressed():
			_source_ready.decompress()
		_source_ready.convert(Image.FORMAT_RGBA8)
	source = _source_ready
	var center: Vector3 = pose.center
	var normal: Vector3 = pose.normal
	var up: Vector3 = pose.up
	var right := up.cross(normal).normalized()
	# Positive UI rotation is clockwise when looking at the surface.
	var rotated_right := right * cos(angle) - up * sin(angle)
	var rotated_up := right * sin(angle) + up * cos(angle)
	var half_width := width * 0.5
	var half_height := half_width * float(source.get_height()) / source.get_width()
	var depth := width * 0.3
	var bounds := rotated_right.abs() * half_width + rotated_up.abs() * half_height + normal.abs() * depth
	var low := Vector3i(((center - bounds) / cell_size).floor())
	var high := Vector3i(((center + bounds) / cell_size).floor())
	var candidates: Dictionary = {}
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				for triangle: int in cells.get(Vector3i(x, y, z), []):
					candidates[triangle] = true
	var touched: Dictionary = {}
	var borders: Dictionary = {}
	var resolution := float(canvas.get_width() - 1)
	for triangle: int in candidates:
		var poly: Array = []
		var average_normal := Vector3.ZERO
		for corner in range(3):
			var index := indices[triangle * 3 + corner]
			var relative := positions[index] - center
			poly.append({"p": Vector3(relative.dot(rotated_right), relative.dot(rotated_up), relative.dot(normal)), "uv": uvs[index] * resolution})
			average_normal += normals[index]
		if average_normal.normalized().dot(normal) < 0.4:
			continue
		for axis in range(3):
			var limit: float = [half_width, half_height, depth][axis]
			poly = _clip(poly, axis, limit, 1.0)
			poly = _clip(poly, axis, limit, -1.0)
		if poly.size() < 3:
			continue
		last_triangles += 1
		for fan in range(1, poly.size() - 1):
			_raster(canvas, base, source, poly[0], poly[fan], poly[fan + 1], half_width, half_height, rects, touched, borders)
	# One texel of gutter prevents bilinear filtering from exposing atlas seams.
	# Always blend against the pre-preview image, so shared edges do not darken.
	for key: int in borders:
		var point := Vector2i(key % canvas.get_width(), key / canvas.get_width())
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor: Vector2i = point + step
			if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= canvas.get_width() or neighbor.y >= canvas.get_height():
				continue
			var neighbor_key := neighbor.y * canvas.get_width() + neighbor.x
			if not touched.has(neighbor_key):
				touched[neighbor_key] = true
				canvas.set_pixelv(neighbor, base.get_pixelv(neighbor).blend(borders[key]))
	return rects

func _raster(canvas: Image, base: Image, source: Image, a: Dictionary, b: Dictionary, c: Dictionary, hw: float, hh: float, rects: Array, touched: Dictionary, borders: Dictionary) -> void:
	var uv0: Vector2 = a.uv
	var edge1: Vector2 = b.uv - uv0
	var edge2: Vector2 = c.uv - uv0
	var determinant := edge1.cross(edge2)
	if absf(determinant) < 0.000001:
		return
	var minimum := uv0.min(b.uv).min(c.uv).floor().max(Vector2.ZERO)
	var maximum := uv0.max(b.uv).max(c.uv).ceil().min(Vector2(canvas.get_size()) - Vector2.ONE)
	var rect := Rect2i(Vector2i(minimum), Vector2i(maximum - minimum) + Vector2i.ONE)
	if not rect.has_area():
		return
	rects.append(rect.grow(1).intersection(Rect2i(Vector2i.ZERO, canvas.get_size())))
	var dx1 := edge2.y / determinant
	var dy1 := -edge2.x / determinant
	var dx2 := -edge1.y / determinant
	var dy2 := edge1.x / determinant
	var delta1: Vector3 = b.p - a.p
	var delta2: Vector3 = c.p - a.p
	var boundary1 := Vector2(dx1,dy1).length()
	var boundary2 := Vector2(dx2,dy2).length()
	var boundary0 := Vector2(dx1+dx2,dy1+dy2).length()
	for y in range(rect.position.y, rect.end.y):
		var relative := Vector2(rect.position.x, y) - uv0
		var w1 := relative.x * dx1 + relative.y * dy1
		var w2 := relative.x * dx2 + relative.y * dy2
		for x in range(rect.position.x, rect.end.x):
			if w1 >= -0.00001 and w2 >= -0.00001 and w1 + w2 <= 1.00001:
				var key := y * canvas.get_width() + x
				if not touched.has(key):
					touched[key] = true
					var p: Vector3 = a.p + delta1 * w1 + delta2 * w2
					var sx := clampi(roundi((p.x / (hw * 2.0) + 0.5) * (source.get_width() - 1)), 0, source.get_width() - 1)
					var sy := clampi(roundi((0.5 - p.y / (hh * 2.0)) * (source.get_height() - 1)), 0, source.get_height() - 1)
					var ink := source.get_pixel(sx, sy)
					if ink.a > 0.0:
						canvas.set_pixel(x, y, base.get_pixel(x, y).blend(ink))
						if w1 < boundary1 or w2 < boundary2 or 1.0-w1-w2 < boundary0:
							borders[key] = ink
					last_pixels += 1
			w1 += dx1
			w2 += dx2
