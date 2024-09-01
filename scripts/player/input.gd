extends Resource
class_name Player_Input

var ply: Player = null

func HandleLook(event):
	if not ply or not ply.settings:
		return
		
	ply.look_x += -event.relative.y * ply.settings.mouse_sens_x
	ply.look_y += -event.relative.x * ply.settings.mouse_sens_y
	
	ply.look_x = clamp(ply.look_x, ply.settings.max_look_angle_down, ply.settings.max_look_angle_up)

func HandleViewAngles(_delta):
	if not ply or not ply.settings:
		return
		
	ply.camera.rotation_degrees.x = ply.look_x
	ply.camera.rotation_degrees.y = ply.look_y
	
func HandleKeys():
	if not ply or not ply.settings:
		return

	ply.move_side = 0
	ply.move_forward = 0
	
	ply.move_side += (ply.settings.speed_left * ply.speed_multiplier) * (Input.get_action_strength("player_l") * 50)
	ply.move_side -= (ply.settings.speed_right * ply.speed_multiplier) * (Input.get_action_strength("player_r") * 50)
	
	ply.move_forward += ply.settings.speed_forward * ply.speed_multiplier * (Input.get_action_strength("player_f") * 50)
	ply.move_forward -= (ply.settings.speed_back * ply.speed_multiplier) * (Input.get_action_strength("player_b") * 50)
	
	# Make clamps to movement.
	if Input.is_action_just_released("player_l") or Input.is_action_just_released("player_r"):
		ply.move_side = 0
	else:
		ply.move_side = clamp(ply.move_side, -4096, 4096)

	if Input.is_action_just_released("player_f") or Input.is_action_just_released("player_b"):
		ply.move_forward = 0
	else:
		ply.move_forward = clamp(ply.move_forward, -4096, 4096)

	# Check for crouching.
	if ply.settings.can_crouch:
		if Input.is_action_pressed("player_crouch") and not ply.state.has_state("crouch"):
			ply.state.add_state("crouch")
		elif Input.is_action_just_released("player_crouch") and  ply.state.has_state("crouch"):
			# We want to set crouching back to false since we need to perform motion.
			ply.is_crouching = false

	# Check for sprinting.
	if ply.settings.can_sprint:
		if Input.is_action_pressed("player_sprint") and not ply.state.has_state("sprint"):
			ply.state.add_state("sprint")
		elif Input.is_action_just_released("player_sprint") and ply.state.has_state("sprint"):
			ply.state.del_state("sprint")
		
	# Check for walking.
	if ply.settings.can_walk:
		if Input.is_action_pressed("player_walk") and not ply.state.has_state("walk"):
			ply.state.add_state("walk")
		elif Input.is_action_just_released("player_walk") and ply.state.has_state("walk"):
			ply.state.del_state("walk")
