extends CanvasLayer
class_name SubtitlesLayer3D

var default_theme := load("res://addons/subtitles/default_theming/base_theme.tres")

# padding range of 0.0 - 1.0. Ideally in the upper limits
var fov_padding_percent := 0.95
var screen_padding_min := Vector2(10, 10) # added to top left corner
var screen_padding_max := Vector2(10, 10) # subtracted from bottom right corner

var _position_mapping := {}
var _sub_data_cache := {}
var _viewport_size_cache := Vector2()
var viewport : Viewport = null

func _ready() -> void:
	Subtitles.connect("on_viewport_changed", Callable(self, "_viewport_changed"))
	_viewport_changed(get_tree().root.get_viewport())

func _viewport_changed(n_viewport : Viewport) -> void:
	if n_viewport == viewport:
		return
	viewport = n_viewport
	if not viewport.is_connected("size_changed", Callable(self, "_cache_viewport_size")):
		viewport.connect("size_changed", Callable(self, "_cache_viewport_size"))
	_cache_viewport_size()

func _cache_viewport_size() -> void:
	_viewport_size_cache = viewport.size
#	print("Viewport Size : %s" % str(_viewport_size_cache))
#	if viewport and viewport.get_camera():
#		print("Using camera: %s" % (viewport.get_camera().get_path()))

func _process(_delta : float) -> void:
	_update_subtitles() 

func _update_subtitles() -> void:
	var cam := viewport.get_camera_3d()
	#print("updating subtitles")
	for c in get_children():
		if not is_instance_valid(c) or not c is PanelContainer:
			# skip any invalid nodes or extras
			#push_warning("Invalid or non-subtitle child detected " + str(c))
			continue
		_update_subtitle_position(c as PanelContainer, cam)
		_update_subtitle_visibility(c as PanelContainer, cam)


func _update_subtitle_position(panel : PanelContainer, cam : Camera3D) -> void:
	if not is_instance_valid(cam) or not is_instance_valid(panel):
		return
	if _position_mapping.has(panel.name):
		var position : Node3D = _position_mapping[panel.name]
		if not is_instance_valid(position):
			return
		var pos_calc := cam.unproject_position(position.global_transform.origin)
		pos_calc = _apply_cam_angles(cam, position, pos_calc, panel)
		panel.position = _clamp_subtitle_pos(panel, pos_calc)
		panel.position *= Subtitles.custom_viewport_scale
	else:
		push_warning("Orphaned subtitle detected! " + str(panel))

func _update_subtitle_visibility(panel : PanelContainer, cam : Camera3D) -> void:
	if not is_instance_valid(cam) or not is_instance_valid(panel):
		return
	if _position_mapping.has(panel.name) and _sub_data_cache.has(panel.name):
		var position : Node3D = _position_mapping[panel.name]
		if not is_instance_valid(position):
			return
		var data : SubtitleData = _sub_data_cache[panel.name]
		var distance := position.global_transform.origin.distance_to(cam.global_transform.origin)
		panel.visible = distance < data.audio_max_distance # use the audio stream player's max distance
	else:
		push_warning("Orphaned subtitle detected! " + str(panel))


func _apply_cam_angles(cam : Camera3D, pos : Node3D, calc_pos : Vector2, _panel : PanelContainer) -> Vector2:
	# better calculations for where to place the subtitle on screen based on closeness of angle (along y-axis)
	var cam_forward :Vector3= -cam.global_transform.basis.z
	var delta :Vector3= pos.global_transform.origin - cam.global_transform.origin
	
	var a := Vector2(cam_forward.x, cam_forward.z).normalized()
	var b := Vector2(delta.x, delta.z).normalized()
	
	var angle := a.angle_to(b) # not accounting for y
	var dot := a.dot(b) # not accounting for y
	var side_pos := Vector2()
	var behind_pos := Vector2()

	# very behind, remap appropriately
	behind_pos.y = -_viewport_size_cache.y
	behind_pos.x = _viewport_size_cache.x / 2

	# somewhere to the side	
	side_pos.y = _viewport_size_cache.y / 2
	if angle > 0:
		# off right side
		side_pos.x = _viewport_size_cache.x*2
	else:
		# off left side
		side_pos.x = -1 - _viewport_size_cache.x

	var fov_ang := deg_to_rad(cam.fov * (fov_padding_percent))
	if abs(angle) < fov_ang:
		# on-screen
		var abs_ang := abs(angle)
		var max_ang := fov_ang
		var min_ang := max_ang * 0.75
		var diff_ang := clamp(abs_ang, min_ang, max_ang)
		var ramp := _remap(diff_ang, min_ang, max_ang, 0.0, 1.0)
		ramp = pow(ramp, 3)
		return calc_pos.lerp(side_pos, ramp)

	return side_pos.lerp(behind_pos, clamp(-dot, 0, 1.0))

func _remap(value : float, input_a : float, input_b : float, output_a : float, output_b : float) -> float:
	return (value - input_a) / (input_b - input_a) * (output_b - output_a) + output_a

func _clamp_subtitle_pos(panel : PanelContainer, pos : Vector2) -> Vector2:
	# not perfect, but works ok.
	pos.x = clamp(pos.x, screen_padding_min.x, _viewport_size_cache.x - panel.size.x - screen_padding_max.x)
	pos.y = clamp(pos.y, screen_padding_min.y, _viewport_size_cache.y - panel.size.y - screen_padding_max.y)
	return pos

func add_subtitle(stream_node : AudioStreamPlayer3D, sub_data : SubtitleData, theme_override : Theme = null) -> void:
	"""
	Creates and adds a subtitle to the system
	"""
	# create the positional object
	var pos := _get_position(stream_node, sub_data)
	# create the panel object
	var panel := _create_sub(sub_data,pos)
	# add to layer
	add_child(panel, true)
	# apply theme override
	panel.theme = default_theme if not theme_override else theme_override
	# apply kill timer
	_create_subtitle_timer(panel, stream_node, sub_data)
	# register mapping
	_position_mapping[panel.name] = pos
	_sub_data_cache[panel.name] = sub_data
	# connect for erasing mapping
	_connect_mapping_erase(panel)
	# force position update
	_update_subtitle_position(panel, viewport.get_camera_3d())

func _get_position(stream_node : AudioStreamPlayer3D, sub_data : SubtitleData) -> Node3D:
	var override_path := sub_data.subtitle_position_override
	if not override_path.is_empty():
		# check that the position override is set and is a spatial node
		# since this could be any spatial node, it could even be tied to an animated element of a character, like the muzzle of a gun or the throat of a creature.
		return sub_data.get_node(override_path) as Node3D
	# revert to the actual audio stream player position, which can be set fairly easily in editor
	return stream_node as Node3D

func _create_sub(sub_data : SubtitleData, _position : Node3D) -> PanelContainer:
	var panel := PanelContainer.new()
	var key := sub_data.subtitle_key
	if key.find(":") != -1:
		# treat as character dialogue, 3D positional
		var vbox := VBoxContainer.new()
		var lbl_name := Label.new()
		var lbl_text := Label.new()
		var parts := key.split(":", false, 1)
		lbl_name.text = parts[0] as String
		lbl_text.text = parts[1] as String
		vbox.add_child(lbl_name)
		vbox.add_child(lbl_text)
		panel.add_child(vbox)
	else:
		# treat as general subtitle
		var label := Label.new()
		label.text = sub_data.subtitle_key
		panel.add_child(label)
	_create_panel_name(panel, sub_data)
	return panel

func _create_subtitle_timer(panel : PanelContainer, audio : AudioStreamPlayer3D, sub_data : SubtitleData) -> void:
	var timer := Timer.new()
	panel.add_child(timer)
	timer.wait_time = max(audio.stream.get_length() + sub_data.subtitles_padding, 0.001) # make sure the wait time doesn't go negative
	timer.connect("timeout", Callable(panel, "queue_free"))
	timer.start()

var _subtitle_id :int= 0 # this is tucked here because it is only used here
func _create_panel_name(panel : PanelContainer, sub_data : SubtitleData) -> void:
	# sets the subtitle's name to be something like "Sub3D_key_023"
	# the ID is not specific to any one key since there could be thousands of keys. It just heavily decreases the potential for any two suibtitles having the same name, which results in a garbage-looking name generated by Godot
	panel.name = "Sub3D_" + sub_data.subtitle_key + "_" + str(_subtitle_id).pad_zeros(3)
	_subtitle_id += 1
	_subtitle_id %= 999

func _connect_mapping_erase(panel : PanelContainer) -> void:
	panel.connect("tree_exiting", Callable(self, "_clear_mapping").bind(panel.name))

func _clear_mapping(key : String) -> void:
	_position_mapping.erase(key)
	_sub_data_cache.erase(key)

func clear() -> void:
	# clears the subtitles
	set_visible(false)
	for c in get_children():
		c.queue_free()
		remove_child(c)
	_position_mapping.clear()
	_sub_data_cache.clear()

	self._process(0.1)

func set_visible(is_visible : bool) -> void:
	for c in get_children():
		if c is Control:
			(c as Control).visible = is_visible
