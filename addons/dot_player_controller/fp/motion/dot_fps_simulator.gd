class_name DotFpsSimulator
extends RefCounted

## A player's own movement, run ahead of time on a copy of their state: what a bot plans a
## surf ride with and checks its next second against.
##
## [codeblock]
## var sim := controller.simulator()            # or DotFpsSimulator.new().setup(...)
## sim.oracle = func(state: DotFpsState) -> int: return my_course.event_at(state)
## var s := controller.state.duplicate_state()
## var event := sim.step(s, sim.command(yaw, Vector2(0, 1), false))
## [/codeblock]
##
## [b]A second motor, not a model of the first.[/b] Surfing is [method DotFpsMotor.accelerate]
## and the clip against a ramp meeting a map's collision, tick by tick; a re-implementation is
## a second copy of that rule that drifts, and a ride planned on the copy falls off the
## original. The motor is a pure function of (state, command, delta, tunables, body) and the
## body only queries, so a second [DotFpsMotor] over a copy of the body, with copied tunables,
## the same modifiers and the same modes in the same order, is the game itself. game-g2gfast's
## surf suite checks the three properties this rests on: a simulated tick leaves the live
## player, its motor and its controller untouched; the same start and inputs end bit-identical;
## and the live player given the same commands ends where the simulation did (0.0000 m after a
## 486-tick ride). Reasoning: docs/motor.md, "Simulating ahead".
##
## [b]What it copies.[/b] The tunables (a duplicate: the controller re-gates abilities on its
## own every tick), the body ([method DotFpsBody.copy_for_simulation]; a game's own body type
## overrides it, or the caller hands one to [method setup]), the modifiers and the custom modes
## in registration order (so a state's modifier and mode ids mean the same thing here), and the
## surfaces. [b]What it does not.[/b] Anything a game runs outside the motor (a map's pushes,
## water a game steps itself, a pit that teleports): that is [member mechanics], a callable the
## game sets, and [member oracle], which says what a position means.
##
## [b]Query-only by contract.[/b] Nothing here emits a signal or touches a node; a simulated
## tick changes the state it is handed and this object's own counters, nothing else.

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

## `func(state: DotFpsState, motor: DotFpsMotor, delta: float, start: Vector3) -> int` (an
## EVENT_*), run after each motor tick and before [member oracle]: whatever a game runs on a
## player beside the motor (a map's boosters, gravity volumes). [param start] is where the tick
## began, for a game that asks "was this player in it last tick" of the position rather than
## remembering it. It may change the state; a non-zero answer ends the step.
var mechanics: Callable = Callable()

## Motor ticks this simulator has run, and the microseconds they took: the compute cost.
var steps: int = 0
var usec: int = 0


## Builds the motor. [param live_motor] and [param live_body] are read for what this one must
## share with them (the modifiers and modes in order, the surfaces, the masks and excluded
## colliders) and never written. [param p_body] replaces the copy of [param live_body], for a
## body type that cannot copy itself. Returns this simulator, or null when there is no body.
func setup(tunables: DotFpsTunables, live_motor: DotFpsMotor, live_body: DotFpsBody,
		tick_rate: int, p_body: DotFpsBody = null) -> DotFpsSimulator:
	body = p_body if p_body != null else (live_body.copy_for_simulation() if live_body != null else null)
	if body == null:
		return null
	motor = DotFpsMotor.new(tunables.duplicate() as DotFpsTunables, body)
	motor.set_tick_rate(tick_rate)
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
