extends Resource

var ply: Player

func activate(data = {}):
	ply.utils.debug_msg(1, "[STATE_WALK] Activated! Data => %s" % data)

	ply.speed_multiplier = ply.settings.walk_speed_multiplier
	
func deactivate(data = {}):
	ply.utils.debug_msg(1, "[STATE_WALK] Deactivated! Data => %s" % data)

	ply.speed_multiplier = 1

func _physics_process(_delta):
	pass
	
func _process(_delta):
	pass
