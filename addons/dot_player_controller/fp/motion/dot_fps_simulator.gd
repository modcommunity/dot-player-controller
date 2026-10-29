class_name DotFpsSimulator
extends RefCounted

## A player's own movement, run ahead of time on a copy of their state: what a bot plans a surf ride with.
## A second [DotFpsMotor] over a copy of the body, tunables, modifiers and modes, not a model of the first;
## query-only, never touches the live player. Reasoning and usage: docs/motor.md, "Simulating ahead".

# No log channel: a pure function with counters.

## What a simulated tick ended in, as [member oracle] and [member mechanics] report it.
const EVENT_NONE := 0
## Arrived: inside what the caller's course counts as the goal.
const EVENT_GOAL := 1
## Fell: a pit, a teleport that leads back, a lethal volume.
const EVENT_PIT := 2
## Below the lowest point the course allows.
const EVENT_BELOW := 3

var motor: DotFpsMotor = null
var body: DotFpsBody = null
var delta: float = 1.0 / 60.0

## `func(state: DotFpsState) -> int` (an EVENT_*): what the course says the state is in, after
## each tick. Unset, every state is [constant EVENT_NONE].
var oracle: Callable = Callable()

## `func(state, motor, delta, start: Vector3) -> int` (an EVENT_*), run after each motor tick and before
## [member oracle]: whatever a game runs on a player beside the motor. [param start] is where the tick
## began. It may change the state; a non-zero answer ends the step.
var mechanics: Callable = Callable()

## Motor ticks this simulator has run, and the microseconds they took: the compute cost.
var steps: int = 0
var usec: int = 0


## Builds the motor. [param live_motor] and [param live_body] are read, never written; [param p_body]
## replaces the body copy for a body type that cannot copy itself. Returns null when there is no body.
func setup(tunables: DotFpsTunables, live_motor: DotFpsMotor, live_body: DotFpsBody,
		tick_rate: int, p_body: DotFpsBody = null) -> DotFpsSimulator:
	body = p_body if p_body != null else (live_body.copy_for_simulation() if live_body != null else null)
	if body == null:
		return null
	motor = DotFpsMotor.new(tunables.duplicate() as DotFpsTunables, body)
	motor.set_tick_rate(tick_rate)
	DotFpsNetSync.set_tick_rate(tick_rate)
	delta = 1.0 / float(maxi(tick_rate, 1))
	if live_motor != null:
		motor.surfaces = live_motor.surfaces
		motor.surface_resolver = live_motor.surface_resolver
		var i := 0
		while live_motor.modifier_at(i) != null:
			var _id := motor.register_modifier(live_motor.modifier_at(i))
			i += 1
		# Modes hold nothing between ticks (the rule in docs/motor.md), so the same instance
		# serves both motors; registering in id order gives every mode the same id here.
		var mode_id := DotFpsState.FIRST_CUSTOM_MODE
		while live_motor.mode_for(mode_id) != null:
			var _m := motor.register_mode(live_motor.mode_for(mode_id))
			mode_id += 1
	return self


## One tick of [param state] (changed in place) under [param command]; what it ended in.
func step(state: DotFpsState, command: DotFpsCommand) -> int:
	var began := Time.get_ticks_usec()
	var start := state.position
	motor.simulate(state, command, delta)
	var event := EVENT_NONE
	if mechanics.is_valid():
		event = int(mechanics.call(state, motor, delta, start))
	steps += 1
	usec += Time.get_ticks_usec() - began
	if event == EVENT_NONE and oracle.is_valid():
		event = int(oracle.call(state))
	return event


## A command: the view at [param yaw] degrees, the stick at [param move] (x strafes right, y
## forward), jump held or not. What a caller that may not name [DotFpsCommand] builds one with.
func command(yaw: float, move: Vector2, jump: bool) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.yaw = yaw
	c.move = move
	c.set_button(DotFpsCommand.BUTTON_JUMP, jump)
	return c


## Microseconds a motor tick has cost on average, 0 before the first.
func tick_usec() -> float:
	return float(usec) / float(steps) if steps > 0 else 0.0


func describe() -> Dictionary:
	return {"steps": steps, "tick_usec": snappedf(tick_usec(), 0.1), "delta": delta,
		"body": body.get_script().get_global_name() if body != null and body.get_script() != null else "?"}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["simulator  %d motor ticks, %.1f us each, %s" % [d["steps"], d["tick_usec"], d["body"]]])
