extends CharacterBody3D
class_name Player

var input : Player_Input
var state : Player_State
var utils : Player_Utils

@onready var head = $Head
@onready var camera = $Head/Camera
@onready var collision = $Collision
@onready var jump_timer = $JumpTimer

@onready var settings = $Settings

# Local variables.
var vel = Vector3.ZERO
var snap = Vector3.DOWN

var is_noclip = false
var is_crouching : bool
var is_crouched : bool
var is_sprinting : bool
var can_jump : bool
var was_on_floor = false
var on_floor = false
var should_jump = false

var move_side : float
var move_forward : float

var look_y : float
var look_x : float

var speed_multiplier = 1

var head_init_pos

func _ready():
	# Get this script's base directory.
	var base_dir = get_script().resource_path.get_base_dir()
	
	# Load our utils class.
	utils = load(base_dir + "/player/utils.gd").new()
	utils.ply = self
	
	# Load our input class + assign ply to self.
	input = load(base_dir + "/player/input.gd").new()
	input.ply = self
	
	# Load our state class and assign ply to self.
	state = load(base_dir + "/player/state.gd").new()
	state.ply = self
	
	state.setup()

	# Get head initial position.
	head_init_pos = head.position.y 
	
func _input(event):
	if event is InputEventMouseMotion:
		input.HandleLook(event)
		
func _process(delta):
	# Clamp field of view.
	camera.fov = clamp(70 + sqrt(vel.length() * 7), 90, 180)
	
	# Handle view angles.
	input.HandleViewAngles(delta)
	
	# Handle input keys.
	input.HandleKeys()
	
	# Set snap.
	snap = -get_floor_normal()
	
	# Tell us if we were on the floor or not.
	was_on_floor = on_floor
	
	# Set velocity.
	velocity = vel
	move_and_slide_collide()
	vel = velocity
	
	if was_on_floor and not on_floor:
		utils.debug_msg(2, "[PLY] Starting jump timer!")
		jump_timer.start()
	
	if on_floor:
		should_jump = true
	else:
		if jump_timer.is_stopped():
			should_jump = false
		
	# Handle states.
	state._process(delta)
	
func clear_jump_timer():
	jump_timer.stop()
	should_jump = false
	on_floor = false

func move_and_slide_collide() -> bool:
	var collided := false
	
	on_floor = false
	
	# Check floor.
	var checkMot := velocity * (1/60.)
	checkMot.y -= settings.gravity * (1/360.)
	
	var testCol := move_and_collide(checkMot, true)
	
	if testCol:
		var testNorm = testCol.get_normal()
		
		if testNorm.angle_to(up_direction) < settings.max_slope_angle:
			on_floor = true
			
	var motion := velocity * get_delta_time()
	
	for step in max_slides:
		var col := move_and_collide(motion)
		
		if not col:
			break
			
		var norm = col.get_normal()
		
		motion = col.get_remainder().slide(norm)
		velocity = velocity.slide(norm)
		
		collided = true
		
	return collided
	
func get_delta_time() -> float:
	if Engine.is_in_physics_frame():
		return get_physics_process_delta_time()
		
	return get_process_delta_time()
	
func _physics_process(delta):
	# Handle states.
	state._physics_process(delta)
	
func velocity_check():
	if vel.length() > settings.max_velocity:
		vel = settings.max_velocity
	elif vel.length() < -settings.max_velocity:
		vel = -settings.max_velocity
