@tool
class_name DotFpsModifier
extends Resource

## A temporary change to how the player moves: a speed pad, a slow field, a stun.
## Definitions are configuration; the active set is [DotFpsState], so a rewind restores it and replays predict it.
## Effects multiply, so the order the network applied them in does not matter.

## Name this modifier is added and removed by. Must match on every machine.
@export var id: StringName = &""

@export_group("Duration")

## Seconds it lasts, in simulated time so a replay reproduces it. 0 or less means until removed.
@export_range(0.0, 600.0, 0.1) var duration_sec: float = 0.0

## Whether adding it again while active restarts the clock.
@export var refreshable: bool = true

@export_group("Movement scales")

@export_range(0.0, 10.0, 0.01) var max_speed_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var accelerate_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var air_accelerate_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var friction_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var gravity_scale: float = 1.0
@export_range(0.0, 10.0, 0.01) var jump_scale: float = 1.0

@export_group("Denials")

## Deny jumping outright while active. Separate from [code]jump_scale = 0[/code] so another modifier cannot scale it back up.
@export var deny_jump: bool = false

@export var deny_crouch: bool = false

## Deny movement input entirely. Velocity still decays and gravity still applies.
@export var deny_move: bool = false

@export_group("Abilities")

## Hold the player in noclip while active, whatever [member DotFpsTunables.can_noclip] says.
## A modifier because it is already replicated and rewound: setting [member DotFpsState.mode] alone is undone by the client's replay.
## Removing it does not land the player; see [method DotFpsAdminModifiers.set_noclip].
@export var forces_noclip: bool = false

## Lets the noclip button work while this is active, whatever [member DotFpsTunables.can_noclip] says.
## A permission, not a force: the server adds it for somebody its groups allow, so the key is
## predicted on the owner's client and never works without it.
@export var grants_noclip: bool = false

@export_group("Impulse")

## Velocity added once when applied, in m/s (launch pad, knockback); applied in the simulation so it is predicted.
@export var impulse: Vector3 = Vector3.ZERO

## Zero the velocity before applying [member impulse], so a pad launches everyone the same distance.
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
	if forces_noclip: out.append("walking (noclip is forced)")
	return ", ".join(out) if out.size() > 0 else "none"


func _to_string() -> String:
	return "DotFpsModifier(%s)" % id



## The combined effect of every active modifier, recomputed each tick.
## A typed object, not a dictionary, so a misspelt field is a parse error rather than a silent 0 on the hot path.
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

	var force_noclip: bool = false
	var grant_noclip: bool = false

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
		force_noclip = false
		grant_noclip = false

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
		force_noclip = force_noclip or modifier.forces_noclip
		grant_noclip = grant_noclip or modifier.grants_noclip

	func is_neutral() -> bool:
		return (
			is_equal_approx(max_speed, 1.0)
			and is_equal_approx(accelerate, 1.0)
			and is_equal_approx(air_accelerate, 1.0)
			and is_equal_approx(friction, 1.0)
			and is_equal_approx(gravity, 1.0)
			and is_equal_approx(jump, 1.0)
			and not (deny_jump or deny_crouch or deny_move or force_noclip)
		)

	func describe() -> Dictionary:
		return {
			"max_speed": "%.2f" % max_speed,
			"accelerate": "%.2f" % accelerate,
			"gravity": "%.2f" % gravity,
			"jump": "%.2f" % jump,
			"deny_jump": deny_jump,
			"deny_move": deny_move,
			"force_noclip": force_noclip,
		}
