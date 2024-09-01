extends Node
class_name Player_Settings

@export_category("General Settings")
@export var verbose = 0
@export var mouse_sens_x = 0.3
@export var mouse_sens_y = 0.3
@export var max_look_angle_down = -90
@export var max_look_angle_up = 90
@export var max_slope_angle = deg_to_rad(45)
@export var crouch_depth = -0.5
@export var crouch_lerp_speed = 12.0

@export_category("Feature Settings")
@export var can_noclip = false
@export var can_crouch = true
@export var can_sprint = true
@export var can_walk = true
@export var can_auto_hop = false

@export_category("Movement Settings")
@export var max_speed = 7
@export var speed_left = 0.100
@export var speed_right = 0.100
@export var speed_forward = 0.100
@export var speed_back = 0.100

@export var crouch_speed_multiplier = 0.4
@export var walk_speed_multiplier = 0.4
@export var sprint_speed_multiplier = 1.5

@export var accelerate = 3
@export var air_accelerate = 100
@export var max_air_speed = 1
@export var friction = 1.5
@export var stop_speed = 10
@export var gravity = 25
@export var max_velocity = 40000

@export var jump_height = 1
