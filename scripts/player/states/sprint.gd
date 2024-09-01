extends Resource

var ply: Player

func activate(data = {}):
	ply.utils.debug_msg(1, "[STATE_SPRINT] Activated! Data => %s" % data)

	ply.speed_multiplier = ply.settings.sprint_speed_multiplier
	
func deactivate(data = {}):
	ply.utils.debug_msg(1, "[STATE_SPRINT] Deactivated! Data => %s" % data)

	ply.speed_multiplier = 1

func _physics_process(_delta):
	pass
	
func _process(_delta):
	pass
