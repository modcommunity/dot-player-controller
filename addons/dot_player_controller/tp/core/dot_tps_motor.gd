class_name DotTpsMotor
extends RefCounted

## The third-person simulation: a pure function of (state, intent, delta, tunables).
##
## [b]Pure, and deliberately simpler than dot-player-controller's.[/b] That motor
## does its own collide-and-slide because bunny-hopping and surfing are consequences of
## exactly how the sliding works; this one produces a velocity and lets Godot's
## [method CharacterBody3D.move_and_slide] resolve the collisions, because nothing about
## third-person movement depends on the shape of the resolution.
##
## The consequence is worth stating plainly rather than discovering: this motor is
## deterministic [i]given the same collision results[/i], which is enough for a replay
## on one machine and is not enough for bit-exact rewind against a server that resolved
## the collisions itself. A third-person shooter that needs the latter should drive
## dot-player-controller's motor and use this addon only for the camera.
##
## [method step] never reads a node, a clock, an input device or a random stream.

## One tick. Mutates [param state] and returns the velocity to move with.
static func step(
	state: DotTpsState,
	intent: DotPlayerIntent,
	tunables: DotTpsTunables,
	delta: float,
	on_floor: bool
) -> Vector3:
	if state == null or tunables == null:
		return Vector3.ZERO

	var move := intent.move if intent != null else Vector2.ZERO
	var buttons := intent.buttons if intent != null else 0

	state.running = (buttons & DotPlayerIntent.Btn.SPRINT) != 0
	state.crouched = (buttons & DotPlayerIntent.Btn.CROUCH) != 0
	state.aiming = (buttons & DotPlayerIntent.Btn.ZOOM) != 0

	_update_ground(state, tunables, delta, on_floor)
	_update_jump_buffer(state, intent, tunables, delta)

	var wish := _wish_direction(state, move)
	var target_speed := tunables.speed_for(state.running, state.crouched) * wish.length()

	_accelerate(state, tunables, wish.normalized(), target_speed, delta)
	_apply_jump(state, tunables)

	if not state.on_floor:
		state.velocity.y -= tunables.gravity * delta
	elif state.velocity.y <= 0.0:
		# Not zero: a small downward bias keeps the body pressed onto slopes, and
		# without it a character walking down a ramp leaves the ground every tick and
		# the animation state machine sees a stream of tiny falls.
		state.velocity.y = -2.0

	_turn(state, tunables, wish, delta)
	return state.velocity


## Where the character wants to go, in world terms.
##
## [b]Camera-relative, always.[/b] A third-person character whose forward is its own
## facing turns in circles as soon as the camera moves, because the player is steering
## with the camera and the character is steering with itself.
static func _wish_direction(state: DotTpsState, move: Vector2) -> Vector3:
	if move.is_zero_approx():
		return Vector3.ZERO

	var clamped := move.limit_length(1.0)
	var forward := Vector3(-sin(state.yaw), 0.0, -cos(state.yaw))
	var right := Vector3(cos(state.yaw), 0.0, -sin(state.yaw))
	return (forward * clamped.y + right * clamped.x)


static func _accelerate(
	state: DotTpsState,
	tunables: DotTpsTunables,
	direction: Vector3,
	target_speed: float,
	delta: float
) -> void:
	var planar := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var rate := tunables.acceleration if target_speed > 0.0 else tunables.deceleration

	if not state.on_floor:
		rate *= tunables.air_control

	var target := direction * target_speed
	var change := target - planar
	var step_size := rate * delta

	if change.length() <= step_size:
		planar = target
	else:
		planar += change.normalized() * step_size

	state.velocity.x = planar.x
	state.velocity.z = planar.z


static func _update_ground(
	state: DotTpsState,
	tunables: DotTpsTunables,
	delta: float,
	on_floor: bool
) -> void:
	if on_floor:
		state.on_floor = true
		state.air_time = 0.0
		state.air_jumps_used = 0
		return

	state.air_time += delta

	# The coyote window: still "on the floor" as far as jumping is concerned for a
	# moment after walking off a ledge. Twelve lines that turn "the jump is unreliable"
	# into "the jump is forgiving", and the single most valuable thing in any character
	# controller.
	state.on_floor = state.air_time <= tunables.coyote_time


static func _update_jump_buffer(
	state: DotTpsState,
	intent: DotPlayerIntent,
	tunables: DotTpsTunables,
	delta: float
) -> void:
	var pressed := intent != null and intent.just_pressed(DotPlayerIntent.Btn.JUMP)

	if pressed:
		state.jump_buffered = 0.0
		return

	if state.jump_buffered < 0.0:
		return

	state.jump_buffered += delta

	if state.jump_buffered > tunables.jump_buffer:
		state.jump_buffered = -1.0


static func _apply_jump(state: DotTpsState, tunables: DotTpsTunables) -> void:
	if state.jump_buffered < 0.0:
		return

	if state.on_floor:
		state.velocity.y = tunables.jump_speed()
		state.jump_buffered = -1.0
		state.on_floor = false
		# Past the coyote window immediately: without this the same buffered press
		# would still see on_floor next tick and fire a second jump, which presents as
		# the character occasionally leaping twice as high.
		state.air_time = tunables.coyote_time + 1.0
		return

	if state.air_jumps_used < tunables.air_jumps:
		state.air_jumps_used += 1
		state.velocity.y = tunables.jump_speed()
		state.jump_buffered = -1.0


static func _turn(
	state: DotTpsState,
	tunables: DotTpsTunables,
	wish: Vector3,
	delta: float
) -> void:
	if tunables.turn_mode == 1 or state.aiming:
		# Locked to the camera. Aiming forces it regardless of the mode, because a
		# character aiming at something must be facing it — otherwise the crosshair and
		# the muzzle point in different directions.
		state.target_facing = state.yaw
	elif not wish.is_zero_approx():
		state.target_facing = atan2(-wish.x, -wish.z)

	# Shortest way round, which is the thing that is wrong when a character spins 350
	# degrees to turn 10.
	var difference := wrapf(state.target_facing - state.facing, -PI, PI)
	var step_size := tunables.turn_speed * delta

	if absf(difference) <= step_size:
		state.facing = wrapf(state.target_facing, -PI, PI)
	else:
		state.facing = wrapf(state.facing + signf(difference) * step_size, -PI, PI)


## Applies a look delta to the state's camera angles, clamped by the tunables.
##
## Here rather than on the rig so that a rewind restores the camera as well as the body
## — a correction that put the player back and left them looking somewhere else is a
## correction that feels like being grabbed.
static func look(
	state: DotTpsState,
	delta_look: Vector2,
	tunables: DotTpsTunables,
	sensitivity: float = 1.0
) -> void:
	if state == null:
		return

	state.yaw = wrapf(state.yaw - delta_look.x * sensitivity, -PI, PI)
	state.pitch = clampf(
		state.pitch - delta_look.y * sensitivity,
		tunables.pitch_min_radians(),
		tunables.pitch_max_radians()
	)
