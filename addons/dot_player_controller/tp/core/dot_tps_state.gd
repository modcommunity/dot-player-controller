class_name DotTpsState
extends RefCounted

## Everything the third-person simulation carries between ticks.
##
## [b]Everything, and that is the rule rather than a description.[/b] A field left on
## the controller node is a field a rewind does not restore, so a replay starts from a
## state the server never computed and the correction is measured against a fiction.
## dot-player-controller's `DotFpsState` documents the same rule and it is the same
## rule: if the motor reads it between ticks, it lives here.

var velocity: Vector3 = Vector3.ZERO

## Which way the body is actually facing, in radians about the up axis.
var facing: float = 0.0

## Which way it is turning towards.
var target_facing: float = 0.0

var on_floor: bool = true

## Simulated seconds since leaving the floor. Counts the coyote window.
var air_time: float = 0.0

## Simulated seconds since a jump was pressed. Counts the buffer window.
##
## Negative means no jump is buffered, which is distinct from zero — zero is "pressed
## this very tick" and is the commonest case there is.
var jump_buffered: float = -1.0

var air_jumps_used: int = 0

var crouched: bool = false

var running: bool = false

var aiming: bool = false

## Which shoulder the camera is over. 1 is right, -1 is left.
var shoulder: int = 1

## Camera angles. Held here rather than on the rig so a rewind restores them.
var yaw: float = 0.0
var pitch: float = 0.0


func copy_state() -> DotTpsState:
	var s := DotTpsState.new()
	s.velocity = velocity
	s.facing = facing
	s.target_facing = target_facing
	s.on_floor = on_floor
	s.air_time = air_time
	s.jump_buffered = jump_buffered
	s.air_jumps_used = air_jumps_used
	s.crouched = crouched
	s.running = running
	s.aiming = aiming
	s.shoulder = shoulder
	s.yaw = yaw
	s.pitch = pitch
	return s


func adopt(other: DotTpsState) -> void:
	if other == null:
		return

	var copy := other.copy_state()
	velocity = copy.velocity
	facing = copy.facing
	target_facing = copy.target_facing
	on_floor = copy.on_floor
	air_time = copy.air_time
	jump_buffered = copy.jump_buffered
	air_jumps_used = copy.air_jumps_used
	crouched = copy.crouched
	running = copy.running
	aiming = copy.aiming
	shoulder = copy.shoulder
	yaw = copy.yaw
	pitch = copy.pitch


func forget_state() -> void:
	adopt(DotTpsState.new())


func speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func describe() -> String:
	return "%.2f m/s, facing %.0f°, %s%s%s" % [
		speed(), rad_to_deg(facing),
		"grounded" if on_floor else "airborne (%.2fs)" % air_time,
		", crouched" if crouched else "",
		", aiming" if aiming else "",
	]


func _to_string() -> String:
	return "DotTpsState(%s)" % describe()
