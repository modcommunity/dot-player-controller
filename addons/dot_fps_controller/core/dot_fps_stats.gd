class_name DotFpsStats
extends RefCounted

## What a movement run looked like: jumps, strafes, sync, perfect hops, speed.
##
## [b]The numbers a bhop or surf player judges a run by.[/b] A timer says how long it
## took; this says how it was done, and on a surf or bhop server the second is what
## people actually talk about. Sync in particular is the single most-watched number on
## a bhop HUD: it is the fraction of strafe ticks where the player's mouse was turning
## the same way as their strafe key, which is the mechanic the whole movement rests on
## ([method DotFpsMotor.accelerate]) rendered as one percentage.
##
## [codeblock]
## var stats := DotFpsStats.new()
## # once per simulated tick, after the motor has run
## stats.observe(state, command, previous_command, delta)
## [/codeblock]
##
## [b]Fed from the simulation, never from the frame loop.[/b] Every counter here is
## per-tick, so a player on a 144 Hz monitor and a player on a 60 Hz one get the same
## sync for the same run. Reading input in [code]_process[/code] to compute this — the
## obvious shortcut — makes the number a property of the monitor.
##
## [b]Not part of [DotFpsState], and deliberately.[/b] Statistics are not an input to
## the simulation, so putting them in the state would put them in the prediction
## rewind and on the wire for no reason. The consequence is that a client's own
## statistics are computed over its predicted ticks and the server's over the ticks it
## simulated, and the two can differ by the handful of commands a correction discarded.
## The server's copy is the one a record is filed with.

## Ticks observed.
var ticks: int = 0

## Jumps that left the ground.
var jumps: int = 0

## Jumps taken on the tick the player landed. The definition of a perfect hop.
##
## Requires [member DotFpsState.ground_ticks], which is why that counter is in the
## state and counted in ticks rather than seconds.
var perfect_jumps: int = 0

## Jumps that were close enough to a landing to have been aiming for a perfect one.
##
## The denominator for the perfect-jump percentage. Without it a player who takes one
## deliberate standing jump at the start of a run has their score halved by it.
var measured_jumps: int = 0

## How many ticks of the run were counted as a perfect-hop opportunity.
const PERFECT_WINDOW_TICKS := 10

## Direction changes on the strafe keys. The "strafes" a HUD shows.
var strafes: int = 0

## Ticks where a strafe key was held while airborne. The sync denominator.
var sync_measures: int = 0

## Of those, the ones where the view was turning the same way as the strafe.
var sync_hits: int = 0

## Highest horizontal speed reached, in m/s.
var max_speed: float = 0.0

## Highest speed at the moment of a jump, in m/s. What a bhop run is really about.
var max_jump_speed: float = 0.0

## Sum of horizontal speed per tick, for the average.
var _speed_sum: float = 0.0

## Which strafe key was held last, -1 left, 1 right, 0 neither.
var _last_strafe: int = 0

## Yaw on the previous tick, for the turn direction.
var _last_yaw: float = 0.0

var _had_yaw: bool = false

## Whether the player was on the ground on the previous tick.
var _was_grounded: bool = false


## Folds one simulated tick in. Call after [method DotFpsMotor.simulate].
##
## [param previous] is the command from the tick before, for edge detection. Null on
## the first tick.
func observe(
	state: DotFpsState,
	command: DotFpsCommand,
	previous: DotFpsCommand,
	_delta: float
) -> void:
	ticks += 1

	var horizontal := state.horizontal_speed()
	_speed_sum += horizontal
	max_speed = maxf(max_speed, horizontal)

	# --- Jumps ------------------------------------------------------------
	#
	# Detected from the state transition rather than from the button, because a
	# button press that was refused — cooldown, no ground, a modifier denying it —
	# is not a jump and counting it would let a player inflate their hop count by
	# holding the key.
	var grounded := state.is_grounded()

	if _was_grounded and not grounded and state.velocity.y > 0.0:
		jumps += 1
		max_jump_speed = maxf(max_jump_speed, horizontal)

		# ground_ticks is the count BEFORE this tick's leap: 1 means the player
		# touched down on this very tick and jumped straight back out.
		if state.ground_ticks <= PERFECT_WINDOW_TICKS:
			measured_jumps += 1

			if state.ground_ticks <= 1:
				perfect_jumps += 1

	# --- Strafes and sync -------------------------------------------------
	var strafe := 0

	if command.move.x > 0.01:
		strafe = 1
	elif command.move.x < -0.01:
		strafe = -1

	if strafe != 0 and strafe != _last_strafe:
		strafes += 1

	_last_strafe = strafe

	if not grounded and strafe != 0 and _had_yaw:
		sync_measures += 1

		# Shortest signed turn, so wrapping past ±180 does not read as a full
		# rotation the wrong way. A player crossing that boundary mid-strafe would
		# otherwise lose a chunk of sync for a turn they made correctly.
		var turn := wrapf(command.yaw - _last_yaw, -180.0, 180.0)

		# Right strafe (+x) accelerates while the view turns right. Godot's yaw is
		# counter-clockwise about +Y, so turning right is DECREASING yaw — the sign
		# here is the one thing in this file that is easy to get backwards, and
		# getting it backwards produces a plausible-looking number that is 100 minus
		# the truth.
		if absf(turn) > 0.0001 and signf(-turn) == float(strafe):
			sync_hits += 1

	_last_yaw = command.yaw
	_had_yaw = true

	if previous == null:
		_last_strafe = strafe

	_was_grounded = grounded


## Fraction of strafe ticks that were in sync, 0..1. 1 when nothing was measured.
##
## One rather than zero for an unmeasured run: a player who walked the whole map
## without strafing did not strafe badly.
func sync() -> float:
	if sync_measures <= 0:
		return 1.0
	return float(sync_hits) / float(sync_measures)


## Fraction of hop-shaped jumps that were perfect, 0..1.
func perfect_ratio() -> float:
	if measured_jumps <= 0:
		return 0.0
	return float(perfect_jumps) / float(measured_jumps)


## Mean horizontal speed over every observed tick, in m/s.
func average_speed() -> float:
	if ticks <= 0:
		return 0.0
	return _speed_sum / float(ticks)


func reset() -> void:
	ticks = 0
	jumps = 0
	perfect_jumps = 0
	measured_jumps = 0
	strafes = 0
	sync_measures = 0
	sync_hits = 0
	max_speed = 0.0
	max_jump_speed = 0.0
	_speed_sum = 0.0
	_last_strafe = 0
	_last_yaw = 0.0
	_had_yaw = false
	_was_grounded = false


func copy_from(other: DotFpsStats) -> void:
	ticks = other.ticks
	jumps = other.jumps
	perfect_jumps = other.perfect_jumps
	measured_jumps = other.measured_jumps
	strafes = other.strafes
	sync_measures = other.sync_measures
	sync_hits = other.sync_hits
	max_speed = other.max_speed
	max_jump_speed = other.max_jump_speed
	_speed_sum = other._speed_sum
	_last_strafe = other._last_strafe
	_last_yaw = other._last_yaw
	_had_yaw = other._had_yaw
	_was_grounded = other._was_grounded


func duplicate_stats() -> DotFpsStats:
	var out := DotFpsStats.new()
	out.copy_from(self)
	return out


## The summary a record carries. Plain types only, so it survives JSON.
func to_dictionary() -> Dictionary:
	return {
		"jumps": jumps,
		"strafes": strafes,
		"sync": sync(),
		"perfect_jumps": perfect_jumps,
		"measured_jumps": measured_jumps,
		"avg_speed": average_speed(),
		"max_speed": max_speed,
		"max_jump_speed": max_jump_speed,
	}


func describe() -> Dictionary:
	return {
		"jumps": "%d (%d/%d perfect)" % [jumps, perfect_jumps, measured_jumps],
		"strafes": strafes,
		"sync": "%.1f%%" % (sync() * 100.0),
		"speed": "avg %.1f, max %.1f m/s" % [average_speed(), max_speed],
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var fields := describe()
	for key in fields:
		out.append("%-10s %s" % [key, str(fields[key])])
	return out


func _to_string() -> String:
	return "DotFpsStats(%d jumps, %.0f%% sync)" % [jumps, sync() * 100.0]
