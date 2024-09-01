extends Resource

var ply: Player

func activate(data = {}):
	ply.utils.debug_msg(1, "[STATE_CROUCH] Activated! Data => %s" % data)

	# Set speed multiplier.
	ply.speed_multiplier = ply.settings.crouch_speed_multiplier

	# Set is crouching.
	ply.is_crouching = true

func deactivate(data = {}):
	ply.utils.debug_msg(1, "[STATE_CROUCH] Deactivated! Data => %s" % data)

	# Set speed modifier back to 1.
	ply.speed_multiplier = 1

func _physics_process(delta):
	if ply.is_crouching:
		ply.head.position.y = lerp(ply.head.position.y, ply.head_init_pos + ply.settings.crouch_depth, delta * ply.settings.crouch_lerp_speed)
	else:
		ply.head.position.y = lerp(ply.head.position.y, ply.head_init_pos, delta * ply.settings.crouch_lerp_speed)

		ply.state.del_state("crouch")
	
func _process(_delta):
	pass
