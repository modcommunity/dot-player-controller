class_name DotFpsLadderMode
extends DotFpsMoveMode

## Climbing a ladder: a player whose hull touches a ladder box and pushes into it, or falls past it, is on it.
## Ladders are data, not areas, so a client replaying prediction gets the server's answer; the game calls [method update]
## once a tick after the move to put a player on, [method _simulate] takes them off.

## The ladder boxes, world space, metres.
var volumes: Array[AABB] = []

## Climb speed, m/s.
var climb_speed: float = 3.81

## Speed a jump pushes a climber off the ladder, away from it.
var jump_off_speed: float = 5.14

## How far past the hull a ladder still counts as touched.
var reach: float = 0.05

## Fraction of the sideways part of a climber's move removed, 0 to 1 (the classic ladder_dampen).
var dampen: float = 0.0

## Applies the ladder cvar. False for an unknown name or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	if cvar_name != "sv_ladder_dampen" or not value.strip_edges().is_valid_float():
		return false
	dampen = clampf(value.strip_edges().to_float(), 0.0, 1.0)
	return true


## One entry per ladder cvar: name, value, description, member.
func cvar_specs() -> Array[Dictionary]:
	return [{"name": "sv_ladder_dampen", "value": dampen,
		"description": "Fraction of sideways ladder movement removed", "member": "dampen"}]

## The tick a climber last jumped off, so the ladder they are still touching does not
## take them straight back. One per player: every player has their own mode.
var _jumped_off_tick: int = -1000


func _name() -> StringName:
	return &"ladder"


func _uses_crouch() -> bool:
	return false


## The ladder the hull at [param feet] touches, or AABB() for none.
func touching(feet: Vector3, radius: float, height: float) -> AABB:
	var hull := AABB(feet - Vector3(radius + reach, 0.0, radius + reach),
		Vector3((radius + reach) * 2.0, height, (radius + reach) * 2.0))
	for box in volumes:
		if box.intersects(hull):
			return box
	return AABB()


## Once a tick, after the move: a player touching a ladder who is off the ground, or
## walking into it, is put on it. Read from the state rather than the command, so it
## needs nothing a replayed tick does not have. Noclip, and somebody already on, are left.
func update(motor: DotFpsMotor, state: DotFpsState) -> void:
	if mode_id < 0 or volumes.is_empty() or state.mode == mode_id or state.mode == DotFpsState.Mode.NOCLIP:
		return
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		return
	if state.time_since_jump < 0.15 or state.tick - _jumped_off_tick < 32:
		return    # a jump at the foot of a ladder, or off it, is a jump
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var into := -flat.dot(_away(box, state.position))
	if (not state.is_grounded() and state.velocity.y < 0.0) or into > 0.25:
		motor.set_mode(state, mode_id)
		state.velocity = Vector3.ZERO


func _simulate(state: DotFpsState, command: DotFpsCommand, delta: float, motor: DotFpsMotor) -> void:
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		motor.set_mode(state, DotFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	var away := _away(box, state.position)
	if command.is_pressed(DotFpsCommand.BUTTON_JUMP):
		state.velocity = away * jump_off_speed
		_jumped_off_tick = state.tick
		motor.set_mode(state, DotFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	# The wish along the view, split into what goes into the ladder's face (turned into motion up it)
	# and the rest, which is kept: forward climbs, looking up climbs faster, strafe slides across.
	var basis := DotFpsMotor._view_basis(state.yaw, state.pitch)
	var wish := (basis.forward * clampf(command.move.y, -1.0, 1.0)
		+ basis.right * clampf(command.move.x, -1.0, 1.0)) * climb_speed
	var into := wish.dot(away)
	var lateral := wish - away * into
	var perp := Vector3.UP.cross(away).normalized()
	var up_face := away.cross(perp)
	var v := lateral * (1.0 - dampen) - up_face * into
	state.velocity = v.limit_length(climb_speed * 1.5)
	motor.move_and_slide(state, delta)

	# Down onto the floor at the foot: back to walking. Asked only while going down, and the mode
	# put back if there is no floor: the ground check writes AIR for every riser, which dropped
	# climbers off the ladder on every tick.
	if v.y <= 0.0:
		motor.categorise_ground(state)
		if not state.is_grounded():
			state.mode = mode_id


## Horizontal unit vector from the ladder's face out toward the player.
static func _away(box: AABB, feet: Vector3) -> Vector3:
	var c := box.get_center()
	var d := Vector3(feet.x - c.x, 0.0, feet.z - c.z)
	# A ladder is thin: its normal is the short horizontal axis.
	if box.size.x < box.size.z:
		d = Vector3(signf(d.x) if d.x != 0.0 else 1.0, 0.0, 0.0)
	else:
		d = Vector3(0.0, 0.0, signf(d.z) if d.z != 0.0 else 1.0)
	return d


func describe() -> Dictionary:
	var out := super.describe()
	out["volumes"] = volumes.size()
	return out
