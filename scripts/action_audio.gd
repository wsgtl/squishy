extends Node

const SQUEEZE = preload("res://sound/ani_ji.mp3")
const STRETCH = preload("res://sound/ani_la.mp3")
const REBOUND = preload("res://sound/ani_ht.mp3")
# First 0.2 seconds of ani_an.mp3, with 3 ms fades at the loop edges.
const PRESS = preload("res://sound/ani_an_short.wav")
const SHORT_CLIP_SECONDS := 1.0
var player: AudioStreamPlayer
var rebound: AudioStreamPlayer
var press_player: AudioStreamPlayer
const PRESS_DRAG_SPEED := 0.8 # Viewport widths per second.
const PRESS_INTERVAL := 0.28
var _press_cooldown := 0.0
var _last_press_position := Vector2.ZERO
var current := ""
var last_strength := 0.0
var action_is_short := false

func _ready() -> void:
	player = AudioStreamPlayer.new()
	add_child(player)
	rebound = AudioStreamPlayer.new()
	var clip: AudioStreamMP3 = REBOUND.duplicate()
	clip.loop = false
	rebound.stream = clip
	add_child(rebound)
	press_player = AudioStreamPlayer.new()
	var press_clip: AudioStreamWAV = PRESS.duplicate()
	press_clip.loop_mode = AudioStreamWAV.LOOP_DISABLED
	press_player.volume_db = -24.0
	press_player.stream = press_clip
	add_child(press_player)

func _update_press_audio(pressing: bool, delta: float, position: Vector2, viewport_width: float) -> void:
	_press_cooldown = maxf(0.0, _press_cooldown - delta)
	var first_press: bool = pressing and current != "press"
	var speed: float = position.distance_to(_last_press_position) / maxf(delta, 0.001) / maxf(viewport_width, 1.0)
	_last_press_position = position
	if not pressing:
		press_player.stop()
		_press_cooldown = 0.0
		return
	# One shot on contact, then spaced one shots only during fast movement.
	if first_press or (speed >= PRESS_DRAG_SPEED and _press_cooldown <= 0.0 and not press_player.playing):
		press_player.play()
		_press_cooldown = PRESS_INTERVAL

func _stop_at_one_second(audio: AudioStreamPlayer) -> void:
	if audio.playing and audio.get_playback_position() >= SHORT_CLIP_SECONDS:
		audio.stop()

func update_action(action: String, strength: float, delta: float, enabled: bool = true, pointer_position: Vector2 = Vector2.ZERO, viewport_width: float = 720.0) -> void:
	if not enabled:
		current = ""
		last_strength = 0.0
		player.stop()
		rebound.stop()
		press_player.stop()
		_press_cooldown = 0.0
		return
	_update_press_audio(action == "press", delta, pointer_position, viewport_width)
	if action_is_short:
		_stop_at_one_second(player)
	if action != current:
		player.stop()
		if action.is_empty() and not current.is_empty() and last_strength > 0.01:
			player.stop()
			rebound.volume_db = lerpf(-16.0,-7.0,clampf(last_strength,0.0,1.0))
			rebound.play()
		elif not action.is_empty():
			rebound.stop()
			player.stop()
			if action == "squeeze" or action == "stretch":
				action_is_short = action == "stretch"
				var clip: AudioStreamMP3 = (STRETCH if action_is_short else SQUEEZE).duplicate()
				clip.loop = false
				player.stream = clip
				player.pitch_scale = 1.0
				player.volume_db = -8.0
				player.play()
		current = action
		last_strength = 0.0
	last_strength = maxf(last_strength,strength)
