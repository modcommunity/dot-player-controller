extends Node

## Shared fixtures, counters and assertions for the movement self-test.
## The sections themselves live in the files that extend this one.

const STEP := 1.0 / 60.0

var _passed := 0


var _failed := 0


var _failures := PackedStringArray()


var _entered := 0


var _completed := 0


## A ladder, of the kind a game would write. The smallest thing that proves the mode
## hook actually replaces the built-in simulation rather than running alongside it.
class LadderMode extends DotFpsMoveMode:
	var entered := 0
	var exited := 0
	var ticks := 0

	func _name() -> StringName:
		return &"ladder"

	func _enter(_state: DotFpsState, _motor: DotFpsMotor) -> void:
		entered += 1

	func _exit(_state: DotFpsState, _motor: DotFpsMotor) -> void:
		exited += 1

	func _simulate(
		state: DotFpsState,
		command: DotFpsCommand,
		delta: float,
		motor: DotFpsMotor
	) -> void:
		ticks += 1

		# Straight up at the command's pace, no gravity — which is the point: a mode
		# that had gravity applied for it would have to cancel a force it never asked
		# for.
		state.velocity = Vector3(0.0, command.move.y * 3.0, 0.0)
		motor.move_and_slide(state, delta)


func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.with_profile("legacy")
	# Deterministic and easy to reason about, not necessarily fun.
	t.can_noclip = true
	return t


func _motor(
	t: DotFpsTunables,
	body: DotFpsBody = null
) -> DotFpsMotor:
	return DotFpsMotor.new(t, body if body != null else DotFpsFlatBody.with_floor(0.0))


## A player standing on the floor at the origin, already settled.
func _standing(motor: DotFpsMotor) -> DotFpsState:
	var s := DotFpsState.new()
	s.position = Vector3.ZERO
	s.mode = DotFpsState.Mode.GROUND

	# A few idle ticks so the ground categorisation and crouch fraction have settled;
	# starting a test from a hand-built state tests the state, not the motor.
	for _i in range(4):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	return s


func _command(
	forward: float = 0.0,
	strafe: float = 0.0,
	yaw: float = 0.0,
	buttons: int = 0
) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(strafe, forward)
	c.yaw = yaw
	c.buttons = buttons
	return c


## A motor with the surface set and modifier the determinism test uses.
func _build_motor(
	t: DotFpsTunables,
	world: DotFpsFlatBody,
	surface_set: DotFpsSurfaceSet,
	boost: DotFpsModifier
) -> DotFpsMotor:
	var motor := DotFpsMotor.new(t, world)
	motor.surfaces = surface_set
	# The first box is ice, everything else is default. Keyed on the body's own
	# collider ids, which stand in for the scene metadata a game would read.
	motor.surface_resolver = func(id: int) -> StringName:
		return &"ice" if id == DotFpsFlatBody.box_id(0) else &""
	motor.register_modifier(boost)
	return motor


## Applies the modifier on a fixed tick index, so every run applies it identically.
##
## Keyed on the loop index rather than on anything the simulation produces: the point
## is to prove the replay reproduces a modifier, not to test what triggers one.
static func _apply_scripted_modifier(
	motor: DotFpsMotor,
	state: DotFpsState,
	index: int
) -> void:
	if index == 120 or index == 300:
		motor.add_modifier(state, &"boost")


func _run_window(
	motor: DotFpsMotor,
	state: DotFpsState,
	commands: Array,
	from: int,
	to: int
) -> void:
	for i in range(from, to):
		_apply_scripted_modifier(motor, state, i)
		motor.simulate(state, commands[i], STEP)


func _run_ticks(
	motor: DotFpsMotor,
	state: DotFpsState,
	commands: Array[DotFpsCommand]
) -> void:
	for command in commands:
		motor.simulate(state, command, STEP)


# --- Assertions ------------------------------------------------------------


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s — %s" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
	return condition


func _check_near(
	value: float,
	expected: float,
	tolerance: float,
	what: String
) -> bool:
	return _check(
		absf(value - expected) <= tolerance,
		what,
		"got %.4f, expected %.4f ±%.4f" % [value, expected, tolerance]
	)


# --- Tests -----------------------------------------------------------------


static func _touch(index: int, at: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = pressed
	return event


static func _drag(index: int, to: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = to
	return event


## A stand-in for [code]DotNetWriter[/code] / [code]DotNetReader[/code].
##
## dot-net is not installed in this project and must not be — the whole point is that
## the controller works without it. But the duck-typed calls in
## [method DotFpsCommand.write] have to line up with the real thing, and a typo in a
## method name is a runtime failure only the host game would ever see. This records
## the calls so the test can check the contract without the dependency.
class FakeWire extends RefCounted:
	var values: Array = []
	var _read_index := 0

	func write_float_range(v: float, lo: float, hi: float, bits: int) -> void:
		var steps := float((1 << bits) - 1)
		var t := clampf((v - lo) / (hi - lo), 0.0, 1.0)
		values.append(lo + roundf(t * steps) / steps * (hi - lo))

	func write_angle(degrees: float, bits: int) -> void:
		var wrapped := fposmod(degrees, 360.0)
		var steps := float(1 << bits)
		values.append(roundf(wrapped / 360.0 * steps) / steps * 360.0)

	func write_uint(v: int, _bits: int) -> void:
		values.append(v)

	func write_bool(v: bool) -> void:
		values.append(v)

	func read_float_range(_lo: float, _hi: float, _bits: int) -> float:
		return _next()

	func read_angle(_bits: int) -> float:
		var a: float = _next()
		return a - 360.0 if a > 180.0 else a

	func read_uint(_bits: int) -> int:
		return int(_next())

	func read_bool() -> bool:
		return bool(_next())

	func _next() -> Variant:
		var v: Variant = values[_read_index]
		_read_index += 1
		return v


func _carrier_script() -> GDScript:
	var script := GDScript.new()
	script.source_code = """
extends Node
var net_position: Vector3
var net_velocity: Vector3
var net_yaw: float
var net_pitch: float
var net_crouch: float
var net_flags: int
var net_modifiers: int
"""
	script.reload()
	return script


## A floor and a corridor along -Z: a wall whose face is x = 1 (normal -X, on the right of
## a player looking down -Z) and one whose face is x = -3 (normal +X, on the left).
func _wall_world() -> DotFpsFlatBody:
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, 12.0, 200.0)))
	world.add_box(AABB(Vector3(-3.5, 0.0, -200.0), Vector3(0.5, 12.0, 200.0)))
	return world


func _wall_tunables() -> DotFpsTunables:
	var t := _tunables()
	t.wall_run_enabled = true
	t.wall_jump_enabled = true
	t.wall_run_min_speed = 6.0
	t.wall_run_max_time = 1.0
	t.wall_jump_max_per_wall = 1
	t.wall_jump_max_per_air = 3
	return t


## An airborne player 5 cm off the right-hand wall, moving down -Z at [param speed] and
## rising at [param rise], well past coyote time.
func _beside_wall(speed: float, rise: float = 1.0, height: float = 3.0) -> DotFpsState:
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.AIR
	s.position = Vector3(1.0 - 0.35 - 0.05, height, -2.0)
	s.velocity = Vector3(0.0, rise, -speed)
	s.time_since_grounded = 1.0
	return s


## Largest change of velocity between consecutive ticks over [param ticks] forward-held
## ticks, and how many of them were wall running.
func _run_along(motor: DotFpsMotor, s: DotFpsState, ticks: int, yaw: float = 0.0) -> Dictionary:
	var worst := 0.0
	var running := 0
	var before := s.velocity
	for _i in range(ticks):
		motor.simulate(s, _command(1.0, 0.0, yaw), STEP)
		worst = maxf(worst, (s.velocity - before).length())
		before = s.velocity
		if s.is_wall_running():
			running += 1
	return {"worst": worst, "running": running}


func _timers_carrier_script() -> GDScript:
	var script := GDScript.new()
	script.source_code = (_carrier_script().source_code as String) + "var net_timers: int\n"
	script.reload()
	return script


func _slide_tunables() -> DotFpsTunables:
	var t := _tunables()
	t.slide_enabled = true
	t.slide_min_speed = 6.0
	t.slide_boost = 3.0
	t.slide_max_speed = 16.0
	t.slide_duration = 1.0
	t.slide_cooldown = 0.5
	return t


func _launch_tunables() -> DotFpsTunables:
	var t := _tunables()
	t.launch_enabled = true
	t.launch_button = DotFpsCommand.BUTTON_USER_0
	t.launch_velocity = 12.0
	t.launch_cooldown = 3.0
	return t


## A player at a settled sprint along -Z, on the floor.
func _running(motor: DotFpsMotor) -> DotFpsState:
	var s := _standing(motor)

	for _i in range(120):
		motor.simulate(s, _command(1.0, 0.0, 0.0, DotFpsCommand.BUTTON_SPRINT), STEP)

	return s


func _check_mode_packing() -> void:
	# Every mode has to survive the three-bit packing, noclip included — a player
	# corrected out of noclip because the flag did not fit would be a good bug.
	for mode in [
		DotFpsState.Mode.GROUND, DotFpsState.Mode.AIR, DotFpsState.Mode.NOCLIP
	]:
		var probe := DotFpsState.new()
		probe.mode = mode
		var restored := DotFpsState.new()
		DotFpsNetSync.unpack_flags(
			restored, DotFpsNetSync.pack_flags(probe)
		)
		_check(
			restored.mode == mode,
			"mode %s survives packing" % DotFpsState.Mode.keys()[mode]
		)

	# Every mode has to survive the packing, including a custom one — a player
	# corrected out of a ladder because the id did not fit would be a good bug.
	var motor := _motor(_tunables())
	var ladder_id := motor.register_mode(LadderMode.new())

	for mode in [
		DotFpsState.Mode.GROUND,
		DotFpsState.Mode.AIR,
		DotFpsState.Mode.NOCLIP,
		ladder_id,
		DotFpsState.MAX_MODES - 1,
	]:
		var probe := DotFpsState.new()
		probe.mode = mode
		probe.crouch_held = true

		var restored := DotFpsState.new()
		DotFpsNetSync.unpack_flags(restored, DotFpsNetSync.pack_flags(probe))

		_check(
			restored.mode == mode and restored.crouch_held,
			"mode %s survives packing alongside the crouch bit"
				% DotFpsState.mode_name(mode, motor)
		)


func _check_timer_and_button_packing() -> void:
	# The slide and launch timers ride in the same word, and must not disturb the mode or
	# crouch below them. Without them a rewind kept the client's own cooldown and refused
	# a launch the server made (game-arena measured 3.2 m apart).
	var timed := DotFpsState.new()
	timed.mode = DotFpsState.Mode.AIR
	timed.crouch_held = true
	timed.launch_cooldown_left = 7.25
	timed.slide_time = 0.5
	timed.slide_cooldown_left = 0.25
	var untimed := DotFpsState.new()
	DotFpsNetSync.unpack_flags(untimed, DotFpsNetSync.pack_flags(timed))
	_check(
		is_equal_approx(untimed.launch_cooldown_left, 7.25)
			and is_equal_approx(untimed.slide_time, 0.5)
			and is_equal_approx(untimed.slide_cooldown_left, 0.25),
		"the slide and launch timers round-trip to the tick",
		"%.4f %.4f %.4f" % [untimed.launch_cooldown_left, untimed.slide_time, untimed.slide_cooldown_left]
	)
	_check(untimed.mode == DotFpsState.Mode.AIR and untimed.crouch_held,
		"without disturbing the mode or the crouch bit")
	# At 30 Hz a timer counted down a tick at a time is a multiple of 1/30 s, which 1/64 s cannot hold.
	DotFpsNetSync.set_tick_rate(30)
	var thirty := DotFpsState.new()
	thirty.slide_time = 7.0 / 30.0
	thirty.dash_cooldown_left = 41.0 / 30.0
	var thirty_back := DotFpsState.new()
	DotFpsNetSync.unpack_flags(thirty_back, DotFpsNetSync.pack_flags(thirty))
	_check(
		is_equal_approx(thirty_back.slide_time, 7.0 / 30.0)
			and is_equal_approx(thirty_back.dash_cooldown_left, 41.0 / 30.0),
		"at 30 Hz the timers round-trip exactly (the scale follows the tick rate)",
		"%.5f %.5f" % [thirty_back.slide_time, thirty_back.dash_cooldown_left]
	)
	DotFpsNetSync.set_tick_rate(128)
	_check(DotFpsNetSync.timer_scale == 64.0, "and above 64 Hz the wire keeps its 1/64 s scale")
	DotFpsNetSync.set_tick_rate(64)
	var idle := DotFpsState.new()
	DotFpsNetSync.unpack_flags(idle, DotFpsNetSync.pack_flags(DotFpsState.new()))
	_check(not idle.is_sliding() and idle.launch_cooldown_left == 0.0,
		"and a player doing neither arrives doing neither")
	var pressed := DotFpsState.new()
	pressed.previous_buttons = DotFpsCommand.BUTTON_USER_0 | DotFpsCommand.BUTTON_CROUCH
	var restored_buttons := DotFpsState.new()
	DotFpsNetSync.unpack_flags(restored_buttons, DotFpsNetSync.pack_flags(pressed))
	_check(restored_buttons.previous_buttons == pressed.previous_buttons,
		"and the buttons every press is detected against arrive with it")


func _check_modifier_mask() -> void:
	# The active modifier set travels as a mask, so membership and order both have
	# to come back — the aggregate is a product and the order it is taken in is part
	# of the determinism contract.
	var with_mods := DotFpsState.new()
	with_mods.modifiers = [Vector2i(0, 40), Vector2i(3, -1), Vector2i(31, 90)]

	var mask := DotFpsNetSync.pack_modifiers(with_mods)
	var rebuilt := DotFpsState.new()
	DotFpsNetSync.unpack_modifiers(rebuilt, mask)

	_check(rebuilt.modifiers.size() == 3, "every active modifier survives the mask")
	_check(
		rebuilt.modifiers[0].x == 0
		and rebuilt.modifiers[1].x == 3
		and rebuilt.modifiers[2].x == 31,
		"in ascending index order, which the aggregate depends on"
	)
	_check(
		rebuilt.modifiers[0].y == -1,
		"with expiry cleared, because it is deliberately not sent"
	)

	var empty := DotFpsState.new()
	DotFpsNetSync.unpack_modifiers(empty, 0)
	_check(empty.modifiers.is_empty(), "and an empty mask clears the set")
