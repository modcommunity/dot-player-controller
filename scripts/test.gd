extends Node

@onready var fps_label = $UI/Container/Port/FPS
@onready var speed_label = $UI/Container/Port/Speed

@onready var ply = $Player

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _process(_delta):
	# Update FPS label.
	if fps_label:
		var fps = Engine.get_frames_per_second()
		
		fps_label.text = "FPS: %s" % fps
		
	if speed_label and ply:
		var cur_speed = ply.vel.length() if ply.vel else 0
		
		speed_label.text = "Speed: %s" % cur_speed
		
