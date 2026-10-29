extends CanvasLayer

# A one-shot 3D viewport shares the world, never the UI canvas.
const MAX_EDGE := 4096
var host: Node3D
var overlay: Control
var preview: TextureRect
var status: Label
var save_button: Button
var actions: Array[Button] = []
var captured: Image
var jpeg := PackedByteArray()
var filename := ""
var busy := false
var dialog: FileDialog
var _web_status_elapsed := 0.0
const GAME_URL := "https://game.punikko.fun/games/squishy/"

func setup(scene: Node3D, hud: Control, font: Font) -> void:
	host = scene
	layer = 100
	var trigger := Button.new()
	trigger.name = "SceneCaptureButton"
	trigger.text = "拍照"
	hud.add_child(trigger)
	trigger.anchor_left = 1.0
	trigger.anchor_right = 1.0
	trigger.offset_left = -160
	trigger.offset_right = -24
	trigger.offset_top = 120
	trigger.offset_bottom = 188
	trigger.add_theme_font_override("font", font)
	trigger.add_theme_font_size_override("font_size", 24)
	trigger.pressed.connect(capture_scene)
	overlay = Control.new()
	overlay.name = "SceneCaptureModal"
	add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.hide()
	var shade := ColorRect.new()
	shade.color = Color(0.08, 0.05, 0.07, 0.6)
	overlay.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var card := PanelContainer.new()
	overlay.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.anchor_left = 0.07
	card.anchor_right = 0.93
	card.anchor_top = 0.06
	card.anchor_bottom = 0.94
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#e1e5c9")
	style.set_corner_radius_all(28)
	style.set_content_margin_all(24)
	card.add_theme_stylebox_override("panel", style)
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 24
	card.theme = theme
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	card.add_child(box)
	var title := Label.new()
	title.text = "捏捏纪念照"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color("#493c37"))
	box.add_child(title)
	preview = TextureRect.new()
	preview.name = "SceneCapturePreview"
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.custom_minimum_size.y = 120
	box.add_child(preview)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 18)
	status.add_theme_color_override("font_color", Color("#67544c"))
	box.add_child(status)
	save_button = _button("保存", save_image)
	save_button.name = "SaveSceneCaptureButton"
	box.add_child(save_button)
	var share := HBoxContainer.new()
	share.add_theme_constant_override("separation", 12)
	box.add_child(share)
	for platform in ["X", "LINE", "系统分享"]:
		var button := _button(platform, func(): share_image(platform))
		button.name = "SystemShareButton" if platform == "系统分享" else platform + "ShareButton"
		button.tooltip_text = "分享当前 JPEG 图片" if platform == "系统分享" else "在 %s 分享文字和游戏链接" % platform
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 22)
		share.add_child(button)
	var cancel := _button("取消", close)
	cancel.name = "CloseSceneCaptureButton"
	box.add_child(cancel)
	dialog = FileDialog.new()
	dialog.name = "SaveSceneCaptureDialog"
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.filters = PackedStringArray(["*.jpg, *.jpeg ; JPEG 图片"])
	dialog.file_selected.connect(_save_to_path)
	add_child(dialog)

func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 62
	button.pressed.connect(callback)
	actions.append(button)
	return button

func is_open() -> bool:
	return overlay != null and overlay.visible

static func capture_size(physical_size: Vector2i) -> Vector2i:
	var size := Vector2(maxi(physical_size.x, 1), maxi(physical_size.y, 1))
	size *= minf(1.0, float(MAX_EDGE) / maxf(size.x, size.y))
	return Vector2i(maxi(roundi(size.x), 1), maxi(roundi(size.y), 1))

func _physical_size() -> Vector2i:
	if OS.has_feature("web"):
		var dimensions = JavaScriptBridge.eval("JSON.stringify([Math.round(innerWidth*devicePixelRatio),Math.round(innerHeight*devicePixelRatio)])")
		var parsed = JSON.parse_string(str(dimensions))
		if parsed is Array and parsed.size() == 2:
			return capture_size(Vector2i(int(parsed[0]), int(parsed[1])))
	return capture_size(DisplayServer.window_get_size())

func capture_scene() -> void:
	if busy or is_open():
		return
	busy = true
	host._finish_gesture()
	host._refresh_sticker_preview()
	host._doodle.flush()
	overlay.show()
	preview.texture = null
	captured = null
	jpeg.clear()
	status.text = "正在生成场景照片…"
	for button in actions:
		button.disabled = true
	var viewport := SubViewport.new()
	viewport.name = "SceneOnlyCaptureViewport"
	viewport.size = _physical_size()
	viewport.world_3d = host.get_viewport().world_3d
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(viewport)
	var camera := host._camera.duplicate() as Camera3D
	viewport.add_child(camera)
	camera.global_transform = host._camera.global_transform
	camera.current = true
	await RenderingServer.frame_post_draw
	captured = viewport.get_texture().get_image()
	viewport.queue_free()
	if captured != null and not captured.is_empty():
		captured.convert(Image.FORMAT_RGB8)
		jpeg = captured.save_jpg_to_buffer(0.93)
		filename = "punikko-" + Time.get_datetime_string_from_system().replace(":", "-") + ".jpg"
		var thumbnail := captured.duplicate() as Image
		var scale := minf(1.0, 960.0 / maxf(thumbnail.get_width(), thumbnail.get_height()))
		thumbnail.resize(maxi(1, roundi(thumbnail.get_width() * scale)), maxi(1, roundi(thumbnail.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		preview.texture = ImageTexture.create_from_image(thumbnail)
		status.text = "%d × %d · JPEG · 仅模型与场景" % [captured.get_width(), captured.get_height()]
		if OS.has_feature("web"):
			_prepare_web_image()
	else:
		status.text = "图片生成失败，请关闭后重试。"
	busy = false
	for button in actions:
		button.disabled = jpeg.is_empty() and button.text != "取消"

func close() -> void:
	if busy:
		return
	dialog.hide()
	overlay.hide()
	preview.texture = null
	captured = null
	jpeg.clear()
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if(window.punikkoPhoto){window.punikkoPhoto.dispose();window.punikkoPhoto=null;}")

func save_image() -> void:
	if jpeg.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoPhoto && window.punikkoPhoto.save()")
	else:
		dialog.current_file = filename
		dialog.popup_centered_ratio(0.8)

func _save_to_path(path: String) -> void:
	if jpeg.is_empty():
		return
	if not path.get_extension().to_lower() in ["jpg", "jpeg"]:
		path += ".jpg"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		status.text = "保存失败，请检查所选目录权限后重试。"
		return
	file.store_buffer(jpeg)
	var error := file.get_error()
	file.close()
	status.text = "图片已保存。" if error == OK else "保存失败，请重试。"

func share_image(platform: String) -> void:
	if jpeg.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoPhoto && window.punikkoPhoto.share(%s)" % JSON.stringify(platform))
	elif platform == "X":
		OS.shell_open("https://twitter.com/intent/tweet?text=" + "我的捏捏纪念照 #punikko".uri_encode() + "&url=" + GAME_URL.uri_encode())
	elif platform == "LINE":
		OS.shell_open("https://social-plugins.line.me/lineit/share?url=" + GAME_URL.uri_encode())
	else:
		status.text = "当前桌面版不支持系统分享，请使用保存。"

func _process(delta: float) -> void:
	if not OS.has_feature("web") or not is_open():
		return
	_web_status_elapsed += delta
	if _web_status_elapsed < 0.2:
		return
	_web_status_elapsed = 0.0
	var message = JavaScriptBridge.eval("window.punikkoPhoto ? window.punikkoPhoto.takeMessage() : ''")
	if message is String and not message.is_empty():
		status.text = message

func _prepare_web_image() -> void:
	JavaScriptBridge.eval(WEB_BRIDGE % [JSON.stringify(Marshalls.raw_to_base64(jpeg)), JSON.stringify(filename)], true)

const WEB_BRIDGE := """
(() => {
 if(window.punikkoPhoto) window.punikkoPhoto.dispose();
 const bytes=Uint8Array.from(atob(%s),c=>c.charCodeAt(0));
 const name=%s, blob=new Blob([bytes],{type:'image/jpeg'});
 const file=new File([blob],name,{type:'image/jpeg'}), url=URL.createObjectURL(blob);
 const gameURL=location.origin+location.pathname;
 let message='';
 const canFileShare=()=>{try{return !!(window.isSecureContext&&navigator.share&&navigator.canShare&&navigator.canShare({files:[file]}));}catch(e){return false;}};
 const download=()=>{const a=document.createElement('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();};
 const share=async(platform)=>{
  if(platform==='X'){
   window.open('https://twitter.com/intent/tweet?text='+encodeURIComponent('我的捏捏纪念照 #punikko')+'&url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(platform==='LINE'){
   window.open('https://social-plugins.line.me/lineit/share?url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(!canFileShare()){message='此浏览器不支持系统图片分享，请使用保存。';return;}
  try{await navigator.share({files:[file],title:'捏捏纪念照',text:'我的捏捏纪念照 #punikko'});}
  catch(e){if(e.name!=='AbortError') message='系统分享未完成，请重试或使用保存。';}
 };
 window.punikkoPhoto={save:download,share,takeMessage:()=>{const text=message;message='';return text;},
 dispose:()=>URL.revokeObjectURL(url)};
})();
"""
