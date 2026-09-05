class_name DotFpsState
extends RefCounted

## Everything the movement simulation carries from one tick to the next.
##
## [b]Why this is a separate object from the node.[/b] Client-side prediction rewinds
## to a server-authoritative state and replays every command since. That is only
## possible if "the state" is something you can capture, restore and compare — and if
## it is [i]all[/i] of it. A single stray field left on the controller node (a
## cooldown, a latch, "was I on the ground last tick") is not restored by the rewind,
## so the replay diverges from the server in a way that only appears while moving and
## only under latency.
##
## The rule this class exists to enforce: if the simulation reads it, it lives here.

## The built-in movement modes.
##
## Deliberately an [code]int[/code] on [member mode] rather than this enum's type:
## [method DotFpsMotor.register_mode] hands out ids above these for a game's own
## modes — a ladder, water, a grapple — and a typed enum would make those
## unrepresentable. The three here are the ones the tunables describe, so they stay
## built in.
enum Mode {
	GROUND,
	AIR,
	NOCLIP,
}

## The first id [method DotFpsMotor.register_mode] hands out.
const FIRST_CUSTOM_MODE := 3

## Most modes one motor can have, built-in and custom.
##
## Bounded because the mode travels on the wire as a fixed-width field; see
## [DotFpsNetSync].
const MAX_MODES := 16

var mode: int = Mode.AIR

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO

## View angles in degrees. Copied from the command each tick and kept here so a
## replay restores the view the tick was simulated with.
var yaw: float = 0.0
var pitch: float = 0.0

## 0 standing, 1 fully crouched. Fractional mid-transition.
var crouch_fraction: float = 0.0

## Whether the crouch button was held on the command just applied.
##
## Distinct from [member crouch_fraction] > 0: a player who releases crouch under a
## low ceiling is no longer holding it but is still crouched, and the difference is
## what makes the stand-up attempt retry next tick instead of clipping.
var crouch_held: bool = false

## Normal of the floor under the player. Up when airborne.
var ground_normal: Vector3 = Vector3.UP

## The collider the player is standing on, or 0.
##
## Not replicated and not part of [method equals]: it is a local physics handle,
## and the same surface has different ids on different machines.
var ground_id: int = 0

## Id of the surface under the player. [code]&""[/code] when unmarked or airborne.
##
## [b]This one is part of the simulation[/b], unlike [member ground_id]: it scales
## friction and acceleration, so a client and a server that disagreed about it would
## disagree about where the player ends up. It is resolved from scene data rather
## than from a physics handle precisely so both machines reach the same answer. See
## [DotFpsSurfaceSet].
var surface: StringName = &""

## Active modifiers as (id index, tick they expire on), sorted by index.
##
## [b]Sorted, and in the state, for the same reason.[/b] In the state because a
## prediction rewind restores the state and replays from it, so a modifier held
## anywhere else would vanish on the first correction. Sorted because the aggregate
## is a product and floating-point multiplication is not associative — two machines
## applying the same modifiers in different orders reach answers that differ in the
## last bits, which is exactly the kind of drift that makes a reconciliation never
## settle.
##
## An expiry of [code]-1[/code] means it lasts until removed explicitly.
var modifiers: Array[Vector2i] = []

## Seconds since last on the ground. 0 while grounded.
##
## Drives coyote time. Counted in simulated seconds, never wall clock — the whole
## state has to be reproducible from a replay, and [code]Time.get_ticks_msec()[/code]
## is not.
var time_since_grounded: float = 0.0

## Seconds since the jump button was pressed, or a large number if it never was.
var time_since_jump_pressed: float = 1000.0

## Seconds since the last jump left the ground.
var time_since_jump: float = 1000.0

## Consecutive ticks spent on the ground. 0 while airborne.
##
## [b]Ticks, not seconds, and that is the whole point of it.[/b] A perfect bunny-hop
## is a jump that leaves on the same tick the player landed, and a timer that reports
## the fraction of perfect hops has to count them the same way at 64 Hz and at 128 Hz.
## Deriving it from [member time_since_grounded] and a tick duration does not: the
## comparison lands on a different side of the boundary at each rate, so the same run
## scores differently on two servers.
##
## Nothing in the movement reads it today. It is in the state rather than beside it
## because a prediction rewind restores the state and replays from it, and a counter
## kept anywhere else would be reset by every correction — so the statistic would
## quietly measure the client's packet loss instead of the player's timing.
var ground_ticks: int = 0

## Buttons on the previous command, for edge detection.
var previous_buttons: int = 0

## Ticks simulated. Diagnostic; not compared.
var tick: int = 0


## A readable name for a mode id, built-in or custom.
##
## [param motor] supplies the names of registered custom modes; without one, a custom
## id renders as its number rather than as a wrong built-in name.
static func mode_name(id: int, motor: DotFpsMotor = null) -> String:
	if id >= 0 and id < FIRST_CUSTOM_MODE:
		return Mode.keys()[id]

	if motor != null:
		var custom := motor.mode_for(id)
		if custom != null:
			return String(custom._name())

	return "mode#%d" % id


func is_grounded() -> bool:
	return mode == Mode.GROUND


func is_crouched() -> bool:
	return crouch_fraction > 0.001


func speed() -> float:
	return velocity.length()


## Horizontal speed. The number a speedometer should show in a movement game —
## vertical velocity is gravity, not skill.
func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func copy_from(other: DotFpsState) -> void:
	mode = other.mode
	position = other.position
	velocity = other.velocity
	yaw = other.yaw
	pitch = other.pitch
	crouch_fraction = other.crouch_fraction
	crouch_held = other.crouch_held
	ground_normal = other.ground_normal
	ground_id = other.ground_id
	surface = other.surface
	modifiers = other.modifiers.duplicate()
	time_since_grounded = other.time_since_grounded
	time_since_jump_pressed = other.time_since_jump_pressed
	time_since_jump = other.time_since_jump
	ground_ticks = other.ground_ticks
	previous_buttons = other.previous_buttons
	tick = other.tick


func duplicate_state() -> DotFpsState:
	var s := DotFpsState.new()
	s.copy_from(self)
	return s


## Whether two states are the same to within [param epsilon].
##
## Used by the self-test to prove a replay reproduces a simulation exactly, which is
## the property client-side prediction depends on. Floating-point results are
## bit-identical for an identical sequence of operations, so the epsilon exists for
## comparing across quantisation, not for tolerating nondeterminism.
func equals(other: DotFpsState, epsilon: float = 0.0001) -> bool:
	if other == null:
		return false
	return (
		mode == other.mode
		and position.distance_to(other.position) <= epsilon
		and velocity.distance_to(other.velocity) <= epsilon
		and absf(crouch_fraction - other.crouch_fraction) <= epsilon
		and crouch_held == other.crouch_held
		and previous_buttons == other.previous_buttons
		and surface == other.surface
		and modifiers == other.modifiers
		# The timers are compared too. They feed coyote time and the jump buffer, so
		# a replay that reproduced the position but not the timers would still jump
		# differently on the next tick — a divergence one tick later, blamed on
		# something else.
		and absf(time_since_grounded - other.time_since_grounded) <= epsilon
		and absf(time_since_jump - other.time_since_jump) <= epsilon
		and absf(time_since_jump_pressed - other.time_since_jump_pressed) <= epsilon
		and ground_ticks == other.ground_ticks
	)


## How far two states have diverged, in metres. For diagnostics and for deciding
## whether a correction is worth showing the player.
func divergence(other: DotFpsState) -> float:
	if other == null:
		return INF
	return position.distance_to(other.position)


func describe() -> Dictionary:
	return {
		"mode": mode_name(mode),
		"position": "(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z],
		"velocity": "(%.2f, %.2f, %.2f)" % [velocity.x, velocity.y, velocity.z],
		"speed": "%.2f m/s (%.2f horizontal)" % [speed(), horizontal_speed()],
		"view": "%.1f / %.1f" % [yaw, pitch],
		"crouch": "%.2f%s" % [crouch_fraction, " held" if crouch_held else ""],
		"surface": String(surface) if surface != &"" else "-",
		"modifiers": modifiers.size(),
		"airborne_for": "%.2f s" % time_since_grounded,
	}


func describe_lines() -> PackedStringArray:
	var fields := describe()
	var out := PackedStringArray()
	for key in fields:
		out.append("%-14s %s" % [key, str(fields[key])])
	return out


func _to_string() -> String:
	return "DotFpsState(%s @ %.1f,%.1f,%.1f)" % [
		mode_name(mode), position.x, position.y, position.z
	]
