extends RefCounted

# Independent UV ink layer; uploaded only once per rendered frame when dirty.
const SIZE := 1024
var brush_radius := 2.5
var eraser_radius := 15.0
var radius: float:
	get:
		return eraser_radius if erasing else brush_radius
	set(value):
		if erasing:
			eraser_radius = value
		else:
			brush_radius = value
var color := Color.BLACK
var erasing := false
var image: Image
var texture: ImageTexture
var dirty := false
var has_content := false
var _stroke_active := false
var _stroke_before: Image
var undo_steps: Array[PackedByteArray] = []
var redo_steps: Array[PackedByteArray] = []
const HISTORY_BYTES := 32 * 1024 * 1024
const HISTORY_LIMIT := 20
# Remember only touched texels, not a second full-size texture per stroke.
var _stroke_base: Dictionary = {}
var _stroke_coverage: Dictionary = {}

func begin_stroke() -> void:
	end_stroke()
	_stroke_before = image.duplicate()
	_stroke_active = true

func end_stroke() -> void:
	if _stroke_active and _stroke_before != null:
		record_change(_stroke_before)
	_stroke_before = null
	_stroke_active = false
	_stroke_base.clear()
	_stroke_coverage.clear()

func _init() -> void:
	image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	texture = ImageTexture.create_from_image(image)

func clear() -> void:
	end_stroke()
	var before := image.duplicate() as Image
	image.fill(Color.TRANSPARENT)
	record_change(before)
	dirty = true

func stamp(uv: Vector2) -> void:
	var center := uv * float(SIZE - 1)
	for y in range(maxi(0, floori(center.y - radius)), mini(SIZE, ceili(center.y + radius) + 1)):
		for x in range(maxi(0, floori(center.x - radius)), mini(SIZE, ceili(center.x + radius) + 1)):
			var alpha := clampf(radius - Vector2(x, y).distance_to(center), 0.0, 1.0)
			if alpha > 0.0:
				var previous := image.get_pixel(x, y)
				if _stroke_active:
					var index := y * SIZE + x
					if alpha <= float(_stroke_coverage.get(index, 0.0)):
						continue
					if not _stroke_base.has(index):
						_stroke_base[index] = previous
					previous = _stroke_base[index]
					_stroke_coverage[index] = alpha
				if erasing:
					# Remove ink coverage to reveal the original material underneath.
					previous.a *= 1.0 - alpha
					image.set_pixel(x, y, previous if previous.a > 0.0 else Color.TRANSPARENT)
				else:
					# Composite once against the pre-stroke pixel, never against this stroke.
					image.set_pixel(x, y, previous.blend(Color(color.r, color.g, color.b, alpha * color.a)))
				dirty = true

# Bake a sticker into the existing ink texture; no new mesh or draw call.
func place_sticker(uv: Vector2, source: Image, width: int, angle: float = 0.0) -> void:
	end_stroke()
	if source == null or source.is_empty():
		return
	var sticker := source.duplicate() as Image
	if sticker.is_compressed():
		sticker.decompress()
	sticker.convert(Image.FORMAT_RGBA8)
	var target_width := clampi(width, 16, SIZE)
	var target_height := maxi(1, roundi(target_width * float(sticker.get_height()) / sticker.get_width()))
	sticker.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
	if not is_zero_approx(angle):
		var rotated_size := Vector2(target_width, target_height).length()
		var side := ceili(rotated_size)
		var rotated := Image.create(side, side, false, Image.FORMAT_RGBA8)
		rotated.fill(Color.TRANSPARENT)
		var center := Vector2(side - 1, side - 1) * 0.5
		var source_center := Vector2(target_width - 1, target_height - 1) * 0.5
		var inverse := Transform2D(-angle, Vector2.ZERO)
		for y in range(side):
			for x in range(side):
				var sample := inverse * (Vector2(x, y) - center) + source_center
				var pixel := Vector2i(sample.round())
				if pixel.x >= 0 and pixel.x < target_width and pixel.y >= 0 and pixel.y < target_height:
					rotated.set_pixel(x, y, sticker.get_pixelv(pixel))
		sticker = rotated
	var origin := Vector2i((uv * float(SIZE - 1)).round()) - sticker.get_size() / 2
	image.blend_rect(sticker, Rect2i(Vector2i.ZERO, sticker.get_size()), origin)
	dirty = true

func flush() -> void:
	if dirty:
		texture.update(image)
		dirty = false

# Lossless bounded snapshots, committed once per stroke/action, never per frame.
func record_change(before: Image) -> void:
	has_content = image.get_used_rect().has_area()
	if before == null or before.get_data() == image.get_data():
		return
	undo_steps.append(before.get_data().compress(FileAccess.COMPRESSION_FASTLZ))
	redo_steps.clear()
	var total := 0
	for step in undo_steps:
		total += step.size()
	while undo_steps.size() > HISTORY_LIMIT or total > HISTORY_BYTES:
		total -= undo_steps.pop_front().size()

func undo() -> void:
	end_stroke()
	if undo_steps.is_empty():
		return
	redo_steps.append(image.get_data().compress(FileAccess.COMPRESSION_FASTLZ))
	_restore(undo_steps.pop_back())

func redo() -> void:
	end_stroke()
	if redo_steps.is_empty():
		return
	undo_steps.append(image.get_data().compress(FileAccess.COMPRESSION_FASTLZ))
	_restore(redo_steps.pop_back())

func _restore(data: PackedByteArray) -> void:
	image = Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, data.decompress(SIZE * SIZE * 4, FileAccess.COMPRESSION_FASTLZ))
	has_content = image.get_used_rect().has_area()
	dirty = true

func reset_history() -> void:
	undo_steps.clear()
	redo_steps.clear()
