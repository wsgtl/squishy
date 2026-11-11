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
var _render_diagnostic_elapsed := 0.0
var _render_diagnostic_mask := -1
var _render_diagnostic_blob_id := 0
var _last_target_diagnostics := ""
var _capture_viewport: SubViewport
var _capture_camera: Camera3D
const GAME_URL := "https://game.punikko.fun/games/squishy/"

func setup(scene: Node3D, hud: Control, font: Font) -> void:
	host = scene
	if OS.has_feature("web"):
		JavaScriptBridge.eval(WEB_DIAGNOSTICS, true)
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
	get_node("/root/UiAudio").play_shutter()
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
	# Reuse the offscreen render target; recreate neither GPU buffers nor camera on reopen.
	if not is_instance_valid(_capture_viewport):
		_capture_viewport = SubViewport.new()
		_capture_viewport.name = "SceneOnlyCaptureViewport"
		_capture_viewport.transparent_bg = false
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_capture_viewport)
		_capture_camera = host._camera.duplicate() as Camera3D
		_capture_viewport.add_child(_capture_camera)
	_capture_viewport.size = _physical_size()
	_capture_viewport.world_3d = host.get_viewport().world_3d
	_capture_camera.global_transform = host._camera.global_transform
	for property in ["projection", "fov", "size", "near", "far", "keep_aspect", "h_offset", "v_offset", "frustum_offset", "cull_mask", "environment", "attributes"]:
		_capture_camera.set(property, host._camera.get(property))
	_capture_camera.make_current()
	_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_capture_log("capture.begin", {"size": str(_capture_viewport.size)})
	# A post-draw signal alone may belong to the frame before this target was ready.
	for attempt in range(3):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		captured = _capture_viewport.get_texture().get_image()
		_capture_log("capture.readback", {"attempt": attempt + 1, "valid": captured != null and not captured.is_empty(), "size": str(captured.get_size()) if captured != null else "null"})
		if captured != null and not captured.is_empty():
			break
	_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if captured != null and not captured.is_empty():
		captured.convert(Image.FORMAT_RGB8)
		jpeg = _encode_capture_jpeg(captured)
		_capture_log("capture.encoded", {"size": str(captured.get_size()), "jpeg_bytes": jpeg.size(), "preview_size": str(preview.size)})
		filename = "punikko-" + Time.get_datetime_string_from_system().replace(":", "-") + ".jpg"
		var thumbnail := captured.duplicate() as Image
		var scale := minf(1.0, 960.0 / maxf(thumbnail.get_width(), thumbnail.get_height()))
		thumbnail.resize(maxi(1, roundi(thumbnail.get_width() * scale)), maxi(1, roundi(thumbnail.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		preview.texture = ImageTexture.create_from_image(thumbnail)
		status.text = ""
	else:
		status.text = tr("图片生成失败，请关闭后重试。")
	if jpeg.is_empty():
		status.text = tr("图片生成失败，请关闭后重试。")
		_capture_log("capture.failed")
	busy = false
	for button in actions:
		button.disabled = jpeg.is_empty() and button.name != "CloseSceneCaptureButton"
	if OS.has_feature("web") and not jpeg.is_empty():
		# Publish only after controls are usable; do not rely on a later frame.
		_prepare_web_image()
		_sync_web_share_targets()
		_sync_web_share_targets.call_deferred()

func _encode_capture_jpeg(source: Image) -> PackedByteArray:
	if not OS.has_feature("web"):
		return source.save_jpg_to_buffer(0.93)
	# WebKit can return an empty buffer from the engine JPEG encoder on repeat captures.
	# Use browser-native encoding from raw pixels, without changing color space or cropping.
	var rgba := source.duplicate() as Image
	rgba.convert(Image.FORMAT_RGBA8)
	var encoded = JavaScriptBridge.eval(WEB_ENCODE_JPEG % [JSON.stringify(Marshalls.raw_to_base64(rgba.get_data())), rgba.get_width(), rgba.get_height()], true)
	if encoded is String and not encoded.is_empty():
		return Marshalls.base64_to_raw(encoded)
	return PackedByteArray()

func _capture_log(event: String, data: Dictionary = {}) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoShareLog && window.punikkoShareLog(%s, %s)" % [JSON.stringify(event), JSON.stringify(data)])

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
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoShareLog && window.punikkoShareLog('godot.button', %s)" % JSON.stringify({"platform": platform, "jpeg_bytes": jpeg.size(), "busy": busy}))
	if jpeg.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.punikkoPhoto && window.punikkoPhoto.shareFromGame(%s)" % JSON.stringify(platform))
	elif platform == "X":
		OS.shell_open("https://twitter.com/intent/tweet?text=" + tr("我的捏捏纪念照 #punikko").uri_encode() + "&url=" + GAME_URL.uri_encode())
	elif platform == "LINE":
		OS.shell_open("https://social-plugins.line.me/lineit/share?url=" + GAME_URL.uri_encode())
	else:
		status.text = tr("当前桌面版不支持系统分享，请使用保存。")

func _process(delta: float) -> void:
	_update_render_diagnostics(delta)
	if not OS.has_feature("web") or not is_open():
		return
	_sync_web_share_targets()
	_web_status_elapsed += delta
	if _web_status_elapsed < 0.2:
		return
	_web_status_elapsed = 0.0
	var message = JavaScriptBridge.eval("window.punikkoPhoto ? window.punikkoPhoto.takeMessage() : ''")
	if message is String and not message.is_empty():
		status.text = message

# Poll a tiny bitmask, including when the photo dialog is closed.
func _update_render_diagnostics(delta: float) -> void:
	if not OS.has_feature("web") or not is_instance_valid(host):
		return
	_render_diagnostic_elapsed += delta
	if _render_diagnostic_elapsed < 0.2:
		return
	_render_diagnostic_elapsed = 0.0
	var value: Variant = JavaScriptBridge.eval("window.punikkoRenderTestMask || 0")
	if value == null:
		return
	var mask := int(value)
	var blob: Node = host.get("_blob")
	var blob_id := blob.get_instance_id() if is_instance_valid(blob) else 0
	if mask == _render_diagnostic_mask and blob_id == _render_diagnostic_blob_id:
		return
	_render_diagnostic_mask = mask
	_render_diagnostic_blob_id = blob_id
	if is_instance_valid(blob):
		blob.set_diagnostic_surface_mode((mask & 4) != 0, (mask & 16) != 0, (mask & 32) != 0)
	JavaScriptBridge.eval("window.punikkoShareLog && window.punikkoShareLog('render.test_applied', %s)" % JSON.stringify({"rest_normal": (mask & 4) != 0, "normal_color": (mask & 16) != 0, "triangle_normal": (mask & 32) != 0, "blob_id": blob_id}))

func _sync_web_share_targets() -> void:
	var targets: Array = []
	var controls: Array = []
	var clip: Rect2 = overlay.get_node("Card/ShareFrame/ShareScroll").get_global_rect()
	var viewport_size: Vector2 = overlay.get_viewport_rect().size
	# Resolve the current scene controls on each sync rather than cached action references.
	for button in overlay.get_node("Card/ShareFrame/ShareScroll/Platforms").get_children():
		if not button is BaseButton:
			continue
		var rect: Rect2 = button.get_global_rect().intersection(clip)
		controls.append({"name": str(button.name), "disabled": button.disabled,
			"visible": button.is_visible_in_tree(), "rect": str(rect)})
		if button.disabled or not button.is_visible_in_tree():
			continue
		if not rect.has_area():
			continue
		targets.append({"platform": str(button.name).trim_suffix("ShareButton"),
			"x": rect.position.x / viewport_size.x, "y": rect.position.y / viewport_size.y,
			"w": rect.size.x / viewport_size.x, "h": rect.size.y / viewport_size.y})
	var diagnostics := JSON.stringify({"open": is_open(), "busy": busy, "jpeg_bytes": jpeg.size(), "viewport": str(viewport_size), "clip": str(clip), "controls": controls, "count": targets.size()})
	if diagnostics != _last_target_diagnostics:
		_last_target_diagnostics = diagnostics
		JavaScriptBridge.eval("window.punikkoShareLog && window.punikkoShareLog('godot.targets', %s)" % diagnostics)
	JavaScriptBridge.eval("if(window.punikkoPhoto) window.punikkoPhoto.setTargets(%s)" % JSON.stringify(targets))

func _prepare_web_image() -> void:
	_last_target_diagnostics = ""
	var messages := {"title":tr("捏捏纪念照"), "text":tr("我的捏捏纪念照 #punikko"),
		"unsupported":tr("此浏览器不支持系统图片分享，请使用保存。"), "failed":tr("系统分享未完成，请重试或使用保存。")}
	JavaScriptBridge.eval(WEB_BRIDGE % [JSON.stringify(Marshalls.raw_to_base64(jpeg)), JSON.stringify(filename), JSON.stringify(messages)], true)

const WEB_BRIDGE := """
(() => {
 if(window.punikkoPhoto) window.punikkoPhoto.dispose();
 const session=Date.now();
 const log=(event,data={})=>{if(window.punikkoShareLog) window.punikkoShareLog(event,Object.assign({session},data));};
 log('photo.create',{build:'share-debug-4',secure:window.isSecureContext,agent:navigator.userAgent});
 const bytes=Uint8Array.from(atob(%s),c=>c.charCodeAt(0));
 const name=%s, blob=new Blob([bytes],{type:'image/jpeg'});
 const labels=%s;
 const file=new File([blob],name,{type:'image/jpeg'}), url=URL.createObjectURL(blob);
 const gameURL=location.origin+location.pathname;
 let shareVersion=0;
 let message='', disposed=false, sharing=false, targets=[], touch=null, lastNativeAt=-Infinity;
 const canvas=document.getElementById('canvas');
 const canFileShare=()=>{try{return !!(window.isSecureContext&&navigator.share&&navigator.canShare&&navigator.canShare({files:[file]}));}catch(e){return false;}};
 const download=()=>{const a=document.createElement('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();};
 const share=async(platform)=>{
  log('share.request',{platform,disposed,sharing,active:navigator.userActivation ? navigator.userActivation.isActive : null,visibility:document.visibilityState,bytes:blob.size});
  if(disposed){log('share.skipped',{reason:'disposed'});return;}
  if(platform==='X'){
   log('share.web_intent',{platform});
   window.open('https://twitter.com/intent/tweet?text='+encodeURIComponent(labels.text)+'&url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(platform==='LINE'){
   log('share.web_intent',{platform});
   window.open('https://social-plugins.line.me/lineit/share?url='+encodeURIComponent(gameURL),'_blank','noopener,noreferrer');return;
  }
  if(sharing){log('share.skipped',{reason:'pending'});return;}
  if(!canFileShare()){log('share.unsupported');message=labels.unsupported;return;}
  sharing=true;
  const version=++shareVersion;
  try{log('share.invoke',{version});await navigator.share({files:[file],title:labels.title,text:labels.text});log('share.resolved',{version});}
  catch(e){log('share.rejected',{version,name:e.name,message:e.message});if(!disposed && version===shareVersion && e.name!=='AbortError') message=labels.failed;}
  finally{if(version===shareVersion) sharing=false;}
 };
 // Invoke Web Share/window.open within Safari's trusted touchend call stack.
 const hit=(x,y)=>{
  if(!canvas) return null;
  const r=canvas.getBoundingClientRect();
  if(!r.width || !r.height) return null;
  x=(x-r.left)/r.width; y=(y-r.top)/r.height;
  return targets.find(t=>x>=t.x && x<=t.x+t.w && y>=t.y && y<=t.y+t.h);
 };
 const start=e=>{
  touch=null;
  // Use the newly pressed contact, not stale contacts retained after an app switch.
  const p=(e.changedTouches && e.changedTouches[0]) || e.touches[0];
  if(!p) return;
  const target=hit(p.clientX,p.clientY);
  log('touch.start',{id:p.identifier,x:p.clientX,y:p.clientY,count:e.touches.length,hit:target ? target.platform : null,targetCount:targets.length,trusted:e.isTrusted});
  if(target) touch={id:p.identifier,x:p.clientX,y:p.clientY,platform:target.platform};
 };
 const move=e=>{
  if(!touch) return;
  const p=Array.from(e.touches).find(p=>p.identifier===touch.id);
  if(!p || Math.hypot(p.clientX-touch.x,p.clientY-touch.y)>8){log('touch.drag_cancel');touch=null;}
 };
 const cancel=e=>{log('lifecycle.cancel',{event:e ? e.type : 'hidden'});touch=null;};
 const resume=e=>{log('lifecycle.resume',{event:e ? e.type : 'visible',sharing});++shareVersion; touch=null; sharing=false; lastNativeAt=-Infinity;};
 const visibility=()=>{if(document.visibilityState==='visible') resume(); else cancel();};
 const end=e=>{
  log('touch.end',{tracked:!!touch,trusted:e.isTrusted});
  if(!touch) return;
  const gesture=touch; touch=null;
  const p=Array.from(e.changedTouches).find(p=>p.identifier===gesture.id);
  if(!p || Math.hypot(p.clientX-gesture.x,p.clientY-gesture.y)>8) return;
  const target=hit(p.clientX,p.clientY);
  if(!target || target.platform!==gesture.platform) return;
  lastNativeAt=Date.now();
  share(target.platform);
 };
 document.addEventListener('touchstart',start,true);
 document.addEventListener('touchmove',move,true);
 document.addEventListener('touchend',end,true);
 document.addEventListener('touchcancel',cancel,true);
 window.addEventListener('blur',cancel);
 window.addEventListener('focus',resume);
 window.addEventListener('pageshow',resume);
 document.addEventListener('visibilitychange',visibility);
 window.punikkoPhoto={save:download,share,
 setTargets:value=>{if(JSON.stringify(value)!==JSON.stringify(targets)) log('targets.update',{targets:value,canvas:canvas ? canvas.getBoundingClientRect().toJSON?.() : null});targets=value;},
 shareFromGame:platform=>{log('godot.dispatch',{platform,deduplicated:Date.now()-lastNativeAt<=700});if(Date.now()-lastNativeAt>700) return share(platform);},
 takeMessage:()=>{const text=message;message='';return text;},
 dispose:()=>{
  log('photo.dispose');
  disposed=true; touch=null; targets=[];
  document.removeEventListener('touchstart',start,true);
  document.removeEventListener('touchmove',move,true);
  document.removeEventListener('touchend',end,true);
  document.removeEventListener('touchcancel',cancel,true);
  window.removeEventListener('blur',cancel);
  window.removeEventListener('focus',resume);
  window.removeEventListener('pageshow',resume);
  document.removeEventListener('visibilitychange',visibility);
  URL.revokeObjectURL(url);
 }};
})();
"""

# Temporary on-device diagnostics. Never stores image bytes or sends logs anywhere.
const WEB_DIAGNOSTICS := """
(() => {
 const existing=document.getElementById('punikko-diagnostics');
 if(existing){existing.hidden=false;return;}
 const boot=document.getElementById('punikko-debug-boot');if(boot)boot.remove();
 const rows=window.punikkoDiagnosticRows||(window.punikkoDiagnosticRows=[]);
 window.punikkoShareLog=(event,data={})=>{
  const row={time:new Date().toISOString(),event,...data};
  rows.push(row); if(rows.length>400) rows.shift();
  console.info('[PunikkoShare]',JSON.stringify(row));
 };
 const panel=document.createElement('details');panel.id='punikko-diagnostics';
 panel.style.cssText='position:fixed;right:8px;top:8px;z-index:2147483647;max-width:90vw;background:#fff;color:#333;padding:6px;border:1px solid #aaa;border-radius:6px;font:12px sans-serif';
 const title=document.createElement('summary');title.textContent='手机诊断 / Debug log';panel.append(title);
 const area=document.createElement('textarea');area.readOnly=true;
 area.style.cssText='display:block;width:75vw;max-width:480px;height:230px;font:11px monospace;user-select:text;touch-action:auto';panel.append(area);
 const refresh=()=>{area.value=rows.map(r=>JSON.stringify(r)).join(String.fromCharCode(10));};
 panel.addEventListener('toggle',refresh);
 const copy=document.createElement('button');copy.textContent='复制日志 / Copy';
 copy.onclick=async()=>{
  refresh();const text=area.value;
  try{await navigator.clipboard.writeText(text);copy.textContent='已复制 '+text.length+' 字符';}
  catch(e){area.focus();area.select();copy.textContent=document.execCommand('copy')?'已复制 / Copied':'请长按文本复制 / Select text';}
 };panel.append(copy);

 const download=document.createElement('button');download.textContent='下载完整日志';
 download.onclick=()=>{
  const content=rows.map(r=>JSON.stringify(r)).join(String.fromCharCode(10));
  const blob=new Blob([content],{type:'text/plain;charset=utf-8'});
  const url=URL.createObjectURL(blob), link=document.createElement('a');
  link.href=url;link.download='punikko-diagnostics-'+Date.now()+'.jsonl';
  document.body.appendChild(link);link.click();link.remove();
  setTimeout(()=>URL.revokeObjectURL(url),60000);
 };panel.appendChild(download);

 const update=document.createElement('button');update.textContent='刷新 / Refresh';update.onclick=refresh;panel.append(update);
 panel.hidden=false;
 document.body.append(panel);

 // Keep diagnostics inside both the portrait game area and the visible viewport.
 if(!window.punikkoPlaceDiagnostics){
  window.punikkoPlaceDiagnostics=function(){
   var p=document.getElementById('punikko-diagnostics')||document.getElementById('punikko-debug-boot');if(!p)return;
   var v=window.visualViewport, vx=v?v.offsetLeft:0, vy=v?v.offsetTop:0;
   var vw=v?v.width:window.innerWidth, vh=v?v.height:window.innerHeight;
   var c=document.getElementById('canvas'), r=c?c.getBoundingClientRect():{left:vx,top:vy,width:vw,height:vh};
   var gameWidth=Math.min(r.width,r.height*720/1280);
   var left=Math.max(vx,r.left+(r.width-gameWidth)/2), right=Math.min(vx+vw,r.left+(r.width+gameWidth)/2);
   if(right-left<100){left=vx;right=vx+vw;}
   p.style.boxSizing='border-box';p.style.right='auto';p.style.maxWidth=Math.max(80,right-left-16)+'px';
   p.style.maxHeight=Math.max(60,vh-16)+'px';p.style.overflow='auto';p.style.touchAction='auto';
   var area=p.querySelector('textarea');if(area){area.style.width='min(480px, 70vw)';area.style.maxWidth='100%';area.style.boxSizing='border-box';}
   p.style.left=Math.max(left+8,right-8-p.getBoundingClientRect().width)+'px';
   p.style.top=Math.max(vy+8,r.top+8)+'px';
  };
  window.addEventListener('resize',window.punikkoPlaceDiagnostics);
  if(window.visualViewport){window.visualViewport.addEventListener('resize',window.punikkoPlaceDiagnostics);window.visualViewport.addEventListener('scroll',window.punikkoPlaceDiagnostics);}
  var diagnosticCanvas=document.getElementById('canvas');
  if(diagnosticCanvas&&window.ResizeObserver)new ResizeObserver(window.punikkoPlaceDiagnostics).observe(diagnosticCanvas);
 }
 panel.addEventListener('toggle',window.punikkoPlaceDiagnostics);
 window.punikkoPlaceDiagnostics();

 window.punikkoShareLog('diagnostics.ready',{build:'render-debug-10',agent:navigator.userAgent,dpr:window.devicePixelRatio});
 window.punikkoRenderTestMask=0;
 const tests=document.createElement('div');panel.append(tests);
 const switches=[];
 for(const [bit,caption] of [[4,'使用未形变法线（诊断）'],[16,'法线方向着色'],[32,'实际三角形法线（对照）']]){
  const label=document.createElement('label');label.style.cssText='display:block;padding:6px';
  const input=document.createElement('input');input.type='checkbox';switches.push(input);
  input.onchange=()=>{
   window.punikkoRenderTestMask=input.checked?(window.punikkoRenderTestMask|bit):(window.punikkoRenderTestMask&~bit);
   window.punikkoShareLog('render.test_requested',{mask:window.punikkoRenderTestMask});refresh();
  };
  label.append(input,document.createTextNode(caption));tests.append(label);
 }
 const mark=document.createElement('button');mark.textContent='标记阴影异常';
 mark.onclick=()=>{window.punikkoShareLog('render.anomaly',{mask:window.punikkoRenderTestMask,latest:window.punikkoRenderLatest||null});refresh();};panel.append(mark);
 // Inspect the existing engine context only; never create a second context,
 // consume GL errors, compile shaders or change render state.
 const canvas=document.getElementById('canvas');
 if(canvas){
  canvas.addEventListener('webglcontextlost',()=>window.punikkoShareLog('render.context_lost'));
  canvas.addEventListener('webglcontextrestored',()=>window.punikkoShareLog('render.context_restored'));
  try{
   const gl=canvas.getContext('webgl2');
   if(gl){
    const ext=gl.getExtension('WEBGL_debug_renderer_info');
    const precision={};
    for(const stage of ['VERTEX_SHADER','FRAGMENT_SHADER']) for(const kind of ['HIGH_FLOAT','MEDIUM_FLOAT']){
     const p=gl.getShaderPrecisionFormat(gl[stage],gl[kind]);
     precision[stage+'.'+kind]=p?{min:p.rangeMin,max:p.rangeMax,bits:p.precision}:null;
    }
    window.punikkoShareLog('render.device',{version:gl.getParameter(gl.VERSION),shading:gl.getParameter(gl.SHADING_LANGUAGE_VERSION),vendor:gl.getParameter(ext?ext.UNMASKED_VENDOR_WEBGL:gl.VENDOR),renderer:gl.getParameter(ext?ext.UNMASKED_RENDERER_WEBGL:gl.RENDERER),attributes:gl.getContextAttributes(),precision});
   }else window.punikkoShareLog('render.device_unavailable');
  }catch(e){window.punikkoShareLog('render.device_error',{message:String(e)});}
 }
})();
"""

const WEB_ENCODE_JPEG := """
(() => {
 let canvas=null;
 try {
  const raw=atob(%s), width=%s, height=%s;
  const pixels=new Uint8ClampedArray(raw.length);
  for(let i=0;i<raw.length;i++) pixels[i]=raw.charCodeAt(i);
  if(pixels.length!==width*height*4) throw new Error('RGBA size mismatch');
  canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
  const context=canvas.getContext('2d');
  if(!context) throw new Error('2D canvas unavailable');
  context.putImageData(new ImageData(pixels,width,height),0,0);
  const data=canvas.toDataURL('image/jpeg',0.93);
  if(!data.startsWith('data:image/jpeg;base64,')) throw new Error('JPEG encoder returned unexpected data');
  const result=data.slice(data.indexOf(',')+1);
  if(!result.length) throw new Error('Empty JPEG');
  if(window.punikkoShareLog) window.punikkoShareLog('capture.browser_encoded',{width,height,base64_length:result.length});
  return result;
 } catch(e) {
  if(window.punikkoShareLog) window.punikkoShareLog('capture.browser_encode_failed',{name:e.name,message:e.message});
  return '';
 } finally {
  if(canvas){canvas.width=0;canvas.height=0;}
 }
})();
"""
