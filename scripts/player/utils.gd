extends Resource
class_name Player_Utils

var ply : Player

func debug_msg(lvl, msg):
	if ply.settings.verbose < lvl:
		return
		
	var msg_formatted = "[%s] %s" % [lvl, msg]
	
	print(msg_formatted)
