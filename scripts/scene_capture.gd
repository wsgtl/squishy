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
	var trigger := hud.get_node("SceneCaptureButton") as Button
	trigger.pressed.connect(capture_scene)
	overlay = preload("res://scenes/photo.tscn").instantiate()
	add_child(overlay)
	preview = overlay.get_node("Card/PreviewFrame/SceneCapturePreview")
	status = overlay.get_node("Card/Status")
	save_button = overlay.get_node("Card/SaveSceneCaptureButton")
	save_button.get_node("Caption").text = tr("保存")
	save_button.pressed.connect(save_image)
	actions.append(save_button)
	for platform in ["X", "LINE", "Instagram", "TikTok", "Kakao"]:
		var button: Button = overlay.get_node("Card/ShareFrame/ShareScroll/Platforms/" + platform + "ShareButton")
		button.pressed.connect(func(): share_image(platform))
		button.tooltip_text = tr("在 %s 分享文字和游戏链接") % platform if platform in ["X", "LINE"] else tr("通过系统分享选择 %s；若未显示，请保存图片后上传。") % platform
		actions.append(button)
	var cancel: Button = overlay.get_node("Card/CloseSceneCaptureButton")
	cancel.get_node("Caption").text = tr("取消")
	cancel.pressed.connect(close)
	actions.append(cancel)
	dialog = FileDialog.new()
	dialog.name = "SaveSceneCaptureDialog"
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.filters = PackedStringArray([tr("*.jpg, *.jpeg ; JPEG 图片")])
	dialog.file_selected.connect(_save_to_path)
	add_child(dialog)

func is_open() -> bool:
	return overlay != null and overlay.visible

static func capture_size(physical_size: Vector2i) -> Vector2i:
	var size := Vector2(maxi(physical_size.x, 1), maxi(physical_size.y, 1))
	size *= minf(1.0, float(MAX_EDGE) / maxf(size.x, size.y))
	return Vector2i(maxi(roundi(size.x), 1), maxi(roundi(size.y), 1))

# Match the authored preview opening by cropping, never stretching the image.
static func crop_center(source: Image, opening: Vector2) -> Image:
	if opening.x <= 0.0 or opening.y <= 0.0:
		return source
	var source_size := source.get_size()
	var ratio := opening.x / opening.y
	var crop := source_size
	if float(source_size.x) / source_size.y > ratio:
		crop.x = maxi(1, roundi(source_size.y * ratio))
	else:
		crop.y = maxi(1, roundi(source_size.x / ratio))
	var origin := (source_size - crop) / 2
	return source.get_region(Rect2i(origin, crop))

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
	status.text = tr("正在生成场景照片…")
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
		captured = crop_center(captured, preview.size)
		captured.convert(Image.FORMAT_RGB8)
		jpeg = captured.save_jpg_to_buffer(0.93)
		filename = "punikko-" + Time.get_datetime_string_from_system().replace(":", "-") + ".jpg"
		var thumbnail := captured.duplicate() as Image
		var scale := minf(1.0, 960.0 / maxf(thumbnail.get_width(), thumbnail.get_height()))
		thumbnail.resize(maxi(1, roundi(thumbnail.get_width() * scale)), maxi(1, roundi(thumbnail.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		preview.texture = ImageTexture.create_from_image(thumbnail)
		status.text = ""
		if OS.has_feature("web"):
			_prepare_web_image()
	else:
		status.text = tr("图片生成失败，请关闭后重试。")
	busy = false
	for button in actions:
		button.disabled = jpeg.is_empty() and button.name != "CloseSceneCaptureButton"

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
		status.text = tr("保存失败，请检查所选目录权限后重试。")
		return
	file.store_buffer(jpeg)
	var error := file.get_error()
	file.close()
	status.text = tr("图片已保存。") if error == OK else tr("保存失败，请重试。")

func share_image(platform: String) -> void:
	if jpeg.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoPhoto && window.punikkoPhoto.share(%s)" % JSON.stringify(platform))
	elif platform == "X":
		OS.shell_open("https://twitter.com/intent/tweet?text=" + tr("我的捏捏纪念照 #punikko").uri_encode() + "&url=" + GAME_URL.uri_encode())
	elif platform == "LINE":
		OS.shell_open("https://social-plugins.line.me/lineit/share?url=" + GAME_URL.uri_encode())
	else:
		status.text = tr("当前桌面版不支持系统分享，请使用保存。")

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
	var messages := {"title":tr("捏捏纪念照"), "text":tr("我的捏捏纪念照 #punikko"),
		"unsupported":tr("此浏览器不支持系统图片分享，请使用保存。"), "failed":tr("系统分享未完成，请重试或使用保存。")}
	JavaScriptBridge.eval(WEB_BRIDGE % [JSON.stringify(Marshalls.raw_to_base64(jpeg)), JSON.stringify(filename), JSON.stringify(messages)], true)

const WEB_BRIDGE := """
(() => {
 if(window.punikkoPhoto) window.punikkoPhoto.dispose();
 const bytes=Uint8Array.from(atob(%s),c=>c.charCodeAt(0));
 const name=%s, blob=new Blob([bytes],{type:'image/jpeg'});
 const labels=%s;
 const file=new File([blob],name,{type:'image/jpeg'}), url=URL.createObjectURL(blob);
 const gameURL=location.origin+location.pathname;
 let message='';
 const canFileShare=()=>{try{return !!(window.isSecureContext&&navigator.share&&navigator.canShare&&navigator.canShare({files:[file]}));}catch(e){return false;}};
 const download=()=>{const a=document.createElement('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();};
 const share=async(platform)=>{
  if(platform==='X'){
   window.open('https://twitter.com/intent/tweet?text='+encodeURIComponent(labels.text)+'&url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(platform==='LINE'){
   window.open('https://social-plugins.line.me/lineit/share?url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(!canFileShare()){message=labels.unsupported;return;}
  try{await navigator.share({files:[file],title:labels.title,text:labels.text});}
  catch(e){if(e.name!=='AbortError') message=labels.failed;}
 };
 window.punikkoPhoto={save:download,share,takeMessage:()=>{const text=message;message='';return text;},
 dispose:()=>URL.revokeObjectURL(url)};
})();
"""
