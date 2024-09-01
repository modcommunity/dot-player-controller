extends Resource

var ply: Player

func activate(data = {}):
	ply.utils.debug_msg(1, "[STATE_AIR] Activated! Data => %s" % data)
	
	ply.on_floor = false
	
	if "jump" in data:
		check_jump()
		
func deactivate(data = {}):
	ply.utils.debug_msg(1, "[STATE_AIR] Deactivated! Data => %s" % data)

func _physics_process(delta):
	ply.utils.debug_msg(4, "[STATE_AIR] Physics process!")
		
	move(delta)
	
	if ply.on_floor:
		ply.state.swap_state("air", "run")
	
func _process(_delta):
	pass
	
func move(delta):
	var forward = Vector3.FORWARD
	var side = Vector3.LEFT
	
	forward = forward.rotated(Vector3.UP, ply.camera.rotation.y)
	side = side.rotated(Vector3.UP, ply.camera.rotation.y)
	
	forward = forward.normalized()
	side = side.normalized()
	
	ply.vel.y -= ply.settings.gravity * delta
	
	var f_move = ply.move_forward
	var s_move = ply.move_side
	
	ply.snap = Vector3.ZERO
	
	var wish_vel = side * s_move + forward * f_move
	
	wish_vel.y = 0
	
	var wish_dir = wish_vel.normalized()
	var wish_speed = wish_vel.length()
	
	if wish_speed != 0.0 and wish_speed > ply.settings.max_speed:
		wish_vel *= ply.settings.max_speed / wish_speed
		wish_speed = ply.settings.max_speed
		
	accelerate(wish_dir, wish_speed, ply.settings.air_accelerate, delta)
	
	ply.velocity_check()
	
func accelerate(wish_dir, wish_speed, accel, delta):
	wish_speed = min(wish_speed, ply.settings.max_air_speed)
	
	var cur_speed = ply.vel.dot(wish_dir)
	
	var add_speed = wish_speed - cur_speed
	
	if add_speed <= 0:
		return
		
	var accel_speed = accel * wish_speed * delta
	accel_speed = min(accel_speed, add_speed)
	
	ply.vel += accel_speed * wish_dir
	
func check_jump():
	ply.snap = Vector3.ZERO
	
	if not ply.should_jump:
		return
		
	ply.clear_jump_timer()
		
	var groundFactor = 1.0
	
	var mul = sqrt(2 * ply.settings.gravity * ply.settings.jump_height)
	
	var jump_vel = groundFactor * mul * max(0, ply.vel.y)
	
	ply.vel.y = max(jump_vel, jump_vel + ply.vel.y)
