@tool
class_name DotFpsModifier
extends Resource

## A temporary change to how the player moves. A speed pad, a slow field, a stun.
##
## [codeblock]
## var boost := DotFpsModifier.make(&"speed_pad")
## boost.max_speed_scale = 1.8
## boost.duration_sec = 3.0
## motor.register_modifier(boost)
##
## motor.add_modifier(state, &"speed_pad")   # server side; replicated to the owner
## [/codeblock]
##
## [b]Definitions are configuration; the active set is state.[/b] That split is not
## tidiness — it is what makes modifiers survive client-side prediction. A rewind
## restores [DotFpsState] and replays every unacknowledged command, so anything that
## changes the simulation has to be [i]in[/i] the state or the replay diverges. The
## definition (how much faster, for how long) is the same on every machine and never
## changes, so it stays out.
##
## [b]Effects multiply.[/b] Two modifiers that each halve speed leave a quarter, not
## zero. Multiplication composes in any order, which matters because the order two
## effects were applied in is not something the network guarantees.

## Name this modifier is added and removed by. Must match on every machine.
@export var id: StringName = &""

@export_group("Duration")

## Seconds it lasts. 0 or less means it stays until removed explicitly.
##
## Counted in simulated seconds, never wall clock — like every timer in
## [DotFpsState], because a replay has to reproduce it.
@export_range(0.0, 600.0, 0.1) var duration_sec: float = 0.0

## Whether adding it again while it is active restarts the clock.
##
## On for a pad the player can keep stepping on; off for something that should not be
## refreshable by repeating the action that applied it.
@export var refreshable: bool = true

@export_group("Movement scales")

@export_range(0.0, 10.0, 0.01) var max_speed_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var accelerate_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var air_accelerate_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var friction_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var gravity_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var jump_scale: float = 1.0

@export_group("Denials")

## Deny jumping outright while active. A root, a stun, being grabbed.
##
## Separate from [code]jump_scale = 0[/code] because a denial should not be
## cancellable by another modifier multiplying the scale back up.
@export var deny_jump: bool = false

@export var deny_crouch: bool = false

## Deny movement input entirely. Velocity still decays and gravity still applies.
@export var deny_move: bool = false

@export_group("Impulse")

## Velocity added once, when the modifier is applied, in m/s.
##
## For a launch pad or a knockback. Applied in the simulation so it is predicted and
## reconciled like everything else, rather than as a one-off the server pushes.
@export var impulse: Vector3 = Vector3.ZERO

## Zero the player's velocity before applying [member impulse].
##
## What makes a launch pad send everyone the same distance regardless of how fast
## they arrived.
@export var impulse_clears_velocity: bool = false


static func make(p_id: StringName) -> DotFpsModifier:
	var m := DotFpsModifier.new()
	m.id = p_id
	return m


func describe() -> Dictionary:
	return {
		"id": String(id),
		"duration": duration_sec,
		"speed": max_speed_scale,
		"accel": accelerate_scale,
		"gravity": gravity_scale,
		"jump": jump_scale,
		"denies": _denials(),
	}


func _denials() -> String:
	var out := PackedStringArray()
	if deny_jump: out.append("jump")
	if deny_crouch: out.append("crouch")
	if deny_move: out.append("move")
	return ", ".join(out) if out.size() > 0 else "none"


func _to_string() -> String:
	return "DotFpsModifier(%s)" % id


# --- Aggregate -------------------------------------------------------------

## The combined effect of every active modifier, recomputed each tick.
##
## A plain object rather than a dictionary so a typo in a field name is a parse error
## rather than a silently-missing multiplier — this is read on the hot path by the
## acceleration code, and a scale that quietly reads as null would be 0.
class Aggregate extends RefCounted:
	var max_speed: float = 1.0
	var accelerate: float = 1.0
	var air_accelerate: float = 1.0
	var friction: float = 1.0
	var gravity: float = 1.0
	var jump: float = 1.0

	var deny_jump: bool = false
	var deny_crouch: bool = false
	var deny_move: bool = false

	func reset() -> void:
		max_speed = 1.0
		accelerate = 1.0
		air_accelerate = 1.0
		friction = 1.0
		gravity = 1.0
		jump = 1.0
		deny_jump = false
		deny_crouch = false
		deny_move = false

	func apply(modifier: DotFpsModifier) -> void:
		max_speed *= modifier.max_speed_scale
		accelerate *= modifier.accelerate_scale
		air_accelerate *= modifier.air_accelerate_scale
		friction *= modifier.friction_scale
		gravity *= modifier.gravity_scale
		jump *= modifier.jump_scale

		# Denials are sticky: any modifier denying an action denies it, and nothing
		# else can multiply it back.
		deny_jump = deny_jump or modifier.deny_jump
		deny_crouch = deny_crouch or modifier.deny_crouch
		deny_move = deny_move or modifier.deny_move

	func is_neutral() -> bool:
		return (
			is_equal_approx(max_speed, 1.0)
			and is_equal_approx(accelerate, 1.0)
			and is_equal_approx(air_accelerate, 1.0)
			and is_equal_approx(friction, 1.0)
			and is_equal_approx(gravity, 1.0)
			and is_equal_approx(jump, 1.0)
			and not (deny_jump or deny_crouch or deny_move)
		)

	func describe() -> Dictionary:
		return {
			"max_speed": "%.2f" % max_speed,
			"accelerate": "%.2f" % accelerate,
			"gravity": "%.2f" % gravity,
			"jump": "%.2f" % jump,
			"deny_jump": deny_jump,
			"deny_move": deny_move,
		}
