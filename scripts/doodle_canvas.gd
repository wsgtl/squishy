extends RefCounted

# Independent UV ink layer; uploaded only once per rendered frame when dirty.
const SIZE := 1024
var brush_radius := 5.0
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
var _stroke_active := false
# Remember only touched texels, not a second full-size texture per stroke.
var _stroke_base: Dictionary = {}
var _stroke_coverage: Dictionary = {}

func begin_stroke() -> void:
	end_stroke()
	_stroke_active = true

func end_stroke() -> void:
	_stroke_active = false
	_stroke_base.clear()
	_stroke_coverage.clear()

func _init() -> void:
	image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	texture = ImageTexture.create_from_image(image)

func clear() -> void:
	end_stroke()
	image.fill(Color.TRANSPARENT)
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

func flush() -> void:
	if dirty:
		texture.update(image)
		dirty = false
