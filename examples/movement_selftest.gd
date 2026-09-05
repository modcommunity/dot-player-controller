extends Node

## Proves the movement simulation does what the netcode needs it to do.
##
## [codeblock]
## godot --headless --path . res://examples/movement_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]The most important test here is [method _test_replay_determinism].[/b]
## Everything else checks that the movement feels right; that one checks that it can
## be networked at all. Client-side prediction works by replaying stored commands
## from an authoritative state and expecting the same answer the server got. If
## replaying diverges — by a field left outside [DotFpsState], by a query that reads
## something machine-local, by an accumulator that is not restored — the client is
## corrected on every snapshot forever, and the symptom looks exactly like packet
## loss. It is worth an entire test file to know it does not.
##
## Most tests run against [DotFpsFlatBody] rather than the physics server: the
## property under test belongs to [DotFpsMotor], and against analytic geometry a
## failure has exactly one possible cause. [method _test_physics_body] covers the real
## implementation separately.

const STEP := 1.0 / 60.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("dot-fps-controller movement self-test")
	print("")

	_test_configuration()
	_test_falling_and_landing()
	_test_jump_height()
	_test_ground_friction()
	_test_ground_speed_cap()
	_test_air_strafing()
	_test_speed_modifiers()
	_test_surfaces()
	_test_modifiers()
	_test_custom_mode()
	_test_crouch_headroom()
	_test_crouch_jump()
	_test_stair_step()
	_test_step_refused_without_floor()
	_test_ground_snap()
	_test_coyote_and_buffer()
	_test_noclip_gating()
	_test_command_sanitising()
	_test_touch_sampler()
	_test_wire_round_trip()
	_test_net_sync_round_trip()
	_test_fingerprint()
	_test_replay_determinism()
	await _test_physics_body()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Fixtures --------------------------------------------------------------

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
	var t := DotFpsTunables.new()
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

func _test_configuration() -> void:
	print("configuration")

	var good := _tunables()
	_check(good.validate().ok, "default tunables validate")

	var bad := _tunables()
	bad.crouch_height = 2.5
	bad.stand_height = 1.8
	_check(not bad.validate().ok, "crouch taller than standing is rejected")

	var thin := _tunables()
	thin.radius = 0.6
	thin.crouch_height = 0.9
	_check(
		not thin.validate().ok,
		"a capsule the engine would silently grow is rejected"
	)

	var climber := _tunables()
	climber.step_height = 1.0
	climber.crouch_height = 0.9
	_check(
		not climber.validate().ok,
		"a step height that would let the player climb walls is rejected"
	)

	var derived := _tunables()
	derived.gravity = 20.0
	derived.jump_height = 1.25
	_check_near(
		derived.jump_velocity(),
		sqrt(2.0 * 20.0 * 1.25),
		0.0001,
		"jump velocity is derived from gravity and height"
	)


func _test_falling_and_landing() -> void:
	print("falling")

	var t := _tunables()
	var motor := _motor(t)

	var s := DotFpsState.new()
	s.position = Vector3(0.0, 5.0, 0.0)
	s.mode = DotFpsState.Mode.AIR

	for _i in range(240):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.is_grounded(), "a falling player lands")
	_check_near(s.position.y, 0.0, 0.02, "and comes to rest on the floor")
	_check_near(s.velocity.y, 0.0, 0.001, "with no residual downward velocity")

	# Not a formality: the previous controller clamped a Vector3 to a float, so
	# `vel` became a scalar and every later vector operation on it was wrong.
	_check(
		s.velocity is Vector3,
		"velocity is still a Vector3 after clamping"
	)


func _test_jump_height() -> void:
	print("jumping")

	var t := _tunables()
	t.jump_height = 1.2
	var motor := _motor(t)
	var s := _standing(motor)

	var peak := 0.0
	var previous: DotFpsCommand = null

	for i in range(120):
		# Held for one tick only: without auto-hop the jump must come from the press
		# edge, and a held button that keeps re-jumping is the bug this catches.
		var c := _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0)
		motor.simulate(s, c, STEP)
		peak = maxf(peak, s.position.y)
		previous = c

	# Discrete integration undershoots the analytic peak by about half a tick of
	# gravity, which at 60 Hz and g=20 is a couple of centimetres.
	_check_near(peak, 1.2, 0.06, "a jump reaches roughly its configured height")
	_check(s.is_grounded(), "and the player lands again")

	var auto := _tunables()
	auto.auto_hop = true
	var auto_motor := _motor(auto)
	var auto_state := _standing(auto_motor)

	var hops := 0
	var was_grounded := true

	for _i in range(300):
		auto_motor.simulate(
			auto_state, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP
		)
		if was_grounded and not auto_state.is_grounded():
			hops += 1
		was_grounded = auto_state.is_grounded()

	_check(hops >= 3, "auto-hop re-jumps while held", "hops: %d" % hops)

	var manual := _tunables()
	var manual_motor := _motor(manual)
	var manual_state := _standing(manual_motor)

	var manual_hops := 0
	was_grounded = true

	for _i in range(300):
		manual_motor.simulate(
			manual_state, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP
		)
		if was_grounded and not manual_state.is_grounded():
			manual_hops += 1
		was_grounded = manual_state.is_grounded()

	_check(
		manual_hops == 1,
		"without auto-hop a held button jumps exactly once",
		"hops: %d" % manual_hops
	)


func _test_ground_friction() -> void:
	print("friction")

	var t := _tunables()
	var motor := _motor(t)
	var s := _standing(motor)

	s.velocity = Vector3(6.0, 0.0, 0.0)

	for _i in range(180):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(
		s.horizontal_speed() < 0.01,
		"friction brings a sliding player to a stop",
		"%.4f m/s" % s.horizontal_speed()
	)


func _test_ground_speed_cap() -> void:
	print("ground speed")

	var t := _tunables()
	t.max_speed = 7.0
	var motor := _motor(t)
	var s := _standing(motor)

	for _i in range(240):
		motor.simulate(s, _command(1.0), STEP)

	_check_near(
		s.horizontal_speed(), 7.0, 0.15, "running forward settles at max_speed"
	)

	# The classic diagonal bug: an unclamped forward+strafe is √2 times faster.
	var diagonal := _standing(motor)

	for _i in range(240):
		motor.simulate(diagonal, _command(1.0, 1.0), STEP)

	_check(
		diagonal.horizontal_speed() <= 7.0 + 0.15,
		"running diagonally is not faster than running forward",
		"%.3f m/s" % diagonal.horizontal_speed()
	)


func _test_air_strafing() -> void:
	print("air control")

	var t := _tunables()
	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	var motor := _motor(t)
	var s := _standing(motor)

	# Run up to speed, jump, then hold strafe and sweep the view — the strafe-jump.
	for _i in range(120):
		motor.simulate(s, _command(1.0), STEP)

	var launch_speed := s.horizontal_speed()

	motor.simulate(s, _command(1.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)

	var yaw := 0.0
	var airborne := 0

	while not s.is_grounded() and airborne < 300:
		# Strafe right and turn right: the wish direction stays nearly perpendicular
		# to the velocity, which is the whole trick.
		yaw -= 1.6
		motor.simulate(s, _command(0.0, 1.0, yaw), STEP)
		airborne += 1

	_check(
		s.horizontal_speed() > launch_speed + 0.5,
		"strafe-jumping gains speed",
		"%.2f -> %.2f m/s" % [launch_speed, s.horizontal_speed()]
	)

	# The counter-test: with the cap at zero there is no air control at all, which is
	# what a game that does not want this movement configures.
	var locked := _tunables()
	locked.max_air_wish_speed = 0.0
	var locked_motor := _motor(locked)
	var locked_state := _standing(locked_motor)

	for _i in range(120):
		locked_motor.simulate(locked_state, _command(1.0), STEP)

	var locked_launch := locked_state.horizontal_speed()
	locked_motor.simulate(
		locked_state, _command(1.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP
	)

	var locked_yaw := 0.0
	var locked_air := 0

	while not locked_state.is_grounded() and locked_air < 300:
		locked_yaw -= 1.6
		locked_motor.simulate(locked_state, _command(0.0, 1.0, locked_yaw), STEP)
		locked_air += 1

	_check(
		locked_state.horizontal_speed() <= locked_launch + 0.01,
		"max_air_wish_speed 0 removes air control entirely",
		"%.2f -> %.2f m/s" % [locked_launch, locked_state.horizontal_speed()]
	)


func _test_speed_modifiers() -> void:
	print("speed modifiers")

	var t := _tunables()
	t.max_speed = 8.0
	t.crouch_speed_scale = 0.5
	t.sprint_speed_scale = 1.5
	t.walk_speed_scale = 0.25

	_check_near(t.speed_for(0), 8.0, 0.001, "no modifier is max_speed")
	_check_near(
		t.speed_for(DotFpsCommand.BUTTON_SPRINT), 12.0, 0.001, "sprint scales up"
	)
	_check_near(
		t.speed_for(DotFpsCommand.BUTTON_CROUCH), 4.0, 0.001, "crouch scales down"
	)
	_check_near(
		t.speed_for(DotFpsCommand.BUTTON_WALK), 2.0, 0.001, "walk scales down"
	)

	# The regression this ordering exists for. The previous controller stored one
	# multiplier and each modifier reset it to 1 on release, so releasing sprint
	# while still crouched restored full speed and the player crouch-ran at sprint
	# pace. Most restrictive wins, so this cannot happen.
	_check_near(
		t.speed_for(DotFpsCommand.BUTTON_CROUCH | DotFpsCommand.BUTTON_SPRINT),
		4.0,
		0.001,
		"crouch beats sprint when both are held"
	)

	var disabled := _tunables()
	disabled.can_sprint = false
	disabled.max_speed = 8.0
	_check_near(
		disabled.speed_for(DotFpsCommand.BUTTON_SPRINT),
		8.0,
		0.001,
		"a disabled ability ignores its button"
	)


func _test_surfaces() -> void:
	print("surfaces")

	var ice := DotFpsSurface.make(&"ice")
	ice.friction_scale = 0.02
	ice.accelerate_scale = 0.15

	var glass := DotFpsSurface.make(&"glass")
	glass.standable = false

	var belt := DotFpsSurface.make(&"belt")
	# Well above stop_speed * friction (24 m/s² with these defaults), because a push
	# below that is entirely absorbed by low-speed friction and moves nobody. That
	# threshold is not obvious from the field name, which is why it is in the docs.
	belt.push = Vector3(0.0, 0.0, -80.0)

	var set := DotFpsSurfaceSet.new()
	set.add(ice).add(glass).add(belt)

	_check(set.get_surface(&"ice") == ice, "a surface resolves by id")
	_check(
		set.get_surface(&"nothing_here") != null,
		"an unknown id falls back rather than returning null"
	)

	# Everything the caller does with a surface goes through get_surface, so a null
	# fallback would be a crash on the first unmarked floor in a level.
	_check(
		set.get_surface(&"nothing_here").friction_scale == 1.0,
		"and the fallback is neutral"
	)

	var t := _tunables()
	var world := DotFpsFlatBody.with_floor(0.0)

	# One collider id per surface, mapped the way a game's resolver would.
	var motor := _motor(t, world)
	motor.surfaces = set
	motor.surface_resolver = func(_id: int) -> StringName: return &"ice"

	var s := _standing(motor)
	s.velocity = Vector3(6.0, 0.0, 0.0)

	for _i in range(60):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(
		s.surface == &"ice",
		"the surface under the player reaches the state",
		String(s.surface)
	)
	_check(
		s.horizontal_speed() > 5.0,
		"and ice barely slows a sliding player",
		"%.2f m/s from 6.00" % s.horizontal_speed()
	)

	# The control: the same slide on default ground stops.
	var plain := _motor(t, DotFpsFlatBody.with_floor(0.0))
	var plain_state := _standing(plain)
	plain_state.velocity = Vector3(6.0, 0.0, 0.0)

	for _i in range(60):
		plain.simulate(plain_state, DotFpsCommand.new(), STEP)

	_check(
		plain_state.horizontal_speed() < 1.0,
		"where ordinary ground stops them",
		"%.2f m/s" % plain_state.horizontal_speed()
	)

	# Unstandable: a floor by geometry, a wall by configuration.
	var glass_motor := _motor(t, DotFpsFlatBody.with_floor(0.0))
	glass_motor.surfaces = set
	glass_motor.surface_resolver = func(_id: int) -> StringName: return &"glass"

	var glass_state := DotFpsState.new()
	glass_state.position = Vector3(0.0, 1.0, 0.0)

	for _i in range(60):
		glass_motor.simulate(glass_state, DotFpsCommand.new(), STEP)

	_check(
		not glass_state.is_grounded(),
		"an unstandable surface cannot be stood on whatever its angle"
	)

	# A conveyor pushes a player who is not otherwise moving.
	var belt_motor := _motor(t, DotFpsFlatBody.with_floor(0.0))
	belt_motor.surfaces = set
	belt_motor.surface_resolver = func(_id: int) -> StringName: return &"belt"

	var belt_state := _standing(belt_motor)

	for _i in range(60):
		belt_motor.simulate(belt_state, DotFpsCommand.new(), STEP)

	_check(
		belt_state.position.z < -5.0,
		"a surface push carries a standing player",
		"z = %.2f" % belt_state.position.z
	)

	# And the threshold itself, because a push that silently does nothing is the
	# failure a level designer would hit first.
	var weak := DotFpsSurface.make(&"weak_belt")
	weak.push = Vector3(0.0, 0.0, -10.0)
	set.add(weak)

	var weak_motor := _motor(t, DotFpsFlatBody.with_floor(0.0))
	weak_motor.surfaces = set
	weak_motor.surface_resolver = func(_id: int) -> StringName: return &"weak_belt"

	var weak_state := _standing(weak_motor)
	for _i in range(60):
		weak_motor.simulate(weak_state, DotFpsCommand.new(), STEP)

	_check(
		weak_state.position.z > -1.0,
		"a push below stop_speed * friction is absorbed, as documented",
		"z = %.2f" % weak_state.position.z
	)

	# And the resolver contract: a surface id must come from something both machines
	# see, so the same node metadata resolves the same on either side.
	var marker := Node3D.new()
	marker.set_meta(&"dot_fps_surface", "ice")
	_check(
		DotFpsSurfaceSet.resolve_from_node(marker) == &"ice",
		"a surface resolves from node metadata"
	)

	var grouped := Node3D.new()
	grouped.add_to_group(&"surface_mud")
	_check(
		DotFpsSurfaceSet.resolve_from_node(grouped) == &"mud",
		"and from a group"
	)

	var unmarked := Node3D.new()
	_check(
		DotFpsSurfaceSet.resolve_from_node(unmarked) == &"",
		"an unmarked node resolves to nothing, not to a default"
	)

	marker.free()
	grouped.free()
	unmarked.free()


func _test_modifiers() -> void:
	print("modifiers")

	var t := _tunables()
	var motor := _motor(t)

	var boost := DotFpsModifier.make(&"boost")
	boost.max_speed_scale = 2.0
	boost.duration_sec = 1.0

	var slow := DotFpsModifier.make(&"slow")
	slow.max_speed_scale = 0.5

	var root := DotFpsModifier.make(&"root")
	root.deny_jump = true
	root.deny_move = true

	var pad := DotFpsModifier.make(&"pad")
	pad.impulse = Vector3(0.0, 12.0, 0.0)
	pad.impulse_clears_velocity = true

	var low_g := DotFpsModifier.make(&"low_gravity")
	low_g.gravity_scale = 0.25

	_check(motor.register_modifier(boost) == 0, "modifier indices start at 0")
	_check(motor.register_modifier(slow) == 1, "and increment in registration order")
	motor.register_modifier(root)
	motor.register_modifier(pad)
	motor.register_modifier(low_g)

	_check(
		motor.modifier_index(&"nothing") < 0,
		"an unregistered modifier has no index"
	)

	var s := _standing(motor)

	_check(motor.add_modifier(s, &"boost"), "a modifier applies")
	_check(motor.has_modifier(s, &"boost"), "and is then active")
	_check(
		not motor.add_modifier(s, &"not_a_modifier"),
		"an unknown one is refused rather than silently ignored"
	)

	for _i in range(50):
		motor.simulate(s, _command(1.0), STEP)

	_check(
		s.horizontal_speed() > t.max_speed * 1.4,
		"a speed modifier raises the ground cap",
		"%.2f m/s against a base of %.2f" % [s.horizontal_speed(), t.max_speed]
	)

	# Expiry is counted in ticks, not seconds off a clock, so a replay ends it on
	# exactly the tick the original run did.
	for _i in range(90):
		motor.simulate(s, _command(1.0), STEP)

	_check(not motor.has_modifier(s, &"boost"), "and expires on its own")
	_check(
		s.horizontal_speed() < t.max_speed + 0.3,
		"after which the player is back to base speed",
		"%.2f m/s" % s.horizontal_speed()
	)

	# Effects multiply, so two modifiers compose without either winning.
	var both := _standing(motor)
	motor.add_modifier(both, &"boost")
	motor.add_modifier(both, &"slow")
	motor.simulate(both, DotFpsCommand.new(), STEP)

	_check_near(
		motor.effects().max_speed, 1.0, 0.001,
		"a doubling and a halving compose to no change"
	)

	# Sorted by index, whatever order they were applied in — the aggregate is a
	# product, and floating-point multiplication is not associative.
	var forwards := _standing(motor)
	motor.add_modifier(forwards, &"boost")
	motor.add_modifier(forwards, &"slow")

	var backwards := _standing(motor)
	motor.add_modifier(backwards, &"slow")
	motor.add_modifier(backwards, &"boost")

	_check(
		forwards.modifiers == backwards.modifiers,
		"the active set is order-independent",
		"%s vs %s" % [str(forwards.modifiers), str(backwards.modifiers)]
	)

	# Denials are not scales: nothing can multiply them back.
	var rooted := _standing(motor)
	motor.add_modifier(rooted, &"root")

	var before_y := rooted.position.y
	for i in range(30):
		motor.simulate(
			rooted,
			_command(1.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0),
			STEP
		)

	_check_near(rooted.position.y, before_y, 0.02, "deny_jump stops a jump")
	_check(
		rooted.horizontal_speed() < 0.1,
		"deny_move stops movement",
		"%.3f m/s" % rooted.horizontal_speed()
	)

	# An impulse is applied inside the simulation, so it is predicted and reconciled
	# like everything else rather than pushed by the server as a one-off.
	var launched := _standing(motor)
	launched.velocity = Vector3(5.0, 0.0, 0.0)
	motor.add_modifier(launched, &"pad")

	_check_near(
		launched.velocity.y, 12.0, 0.001, "an impulse launches the player"
	)
	_check_near(
		launched.velocity.x, 0.0, 0.001,
		"and impulse_clears_velocity means everyone leaves at the same speed"
	)

	motor.simulate(launched, DotFpsCommand.new(), STEP)
	_check(
		not launched.is_grounded(),
		"an upward impulse leaves the ground rather than being eaten by the snap"
	)

	# Gravity scaling, which is the one that changes the shape of a jump.
	var floaty := _standing(motor)
	motor.add_modifier(floaty, &"low_gravity")

	var peak := 0.0
	for i in range(200):
		motor.simulate(
			floaty,
			_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0),
			STEP
		)
		peak = maxf(peak, floaty.position.y)

	_check(
		peak > t.jump_height * 2.0,
		"a gravity modifier changes how high a jump goes",
		"%.2f m against a base of %.2f" % [peak, t.jump_height]
	)

	_check(motor.remove_modifier(floaty, &"low_gravity"), "a modifier is removable")
	_check(
		not motor.remove_modifier(floaty, &"low_gravity"),
		"and removing it twice reports nothing to remove"
	)


func _test_custom_mode() -> void:
	print("custom movement modes")

	var t := _tunables()
	var motor := _motor(t)

	var ladder := LadderMode.new()
	var ladder_id := motor.register_mode(ladder)

	_check(
		ladder_id == DotFpsState.FIRST_CUSTOM_MODE,
		"a custom mode gets the first id above the built-ins",
		"%d" % ladder_id
	)
	_check(
		motor.mode_id_of(&"ladder") == ladder_id, "and is findable by name"
	)
	_check(
		motor.register_mode(LadderMode.new()) == ladder_id,
		"registering the same name twice reuses the id rather than shifting the wire"
	)

	var s := _standing(motor)

	motor.set_mode(s, ladder_id)
	_check(ladder.entered == 1, "entering runs the mode's enter hook")

	for _i in range(60):
		motor.simulate(s, _command(1.0), STEP)

	_check(ladder.ticks == 60, "the mode owns the tick", "%d" % ladder.ticks)
	_check(
		s.position.y > 2.0,
		"and climbs, with no gravity applied behind its back",
		"y = %.2f" % s.position.y
	)

	motor.set_mode(s, DotFpsState.Mode.AIR)
	_check(ladder.exited == 1, "leaving runs the exit hook")

	# The names have to survive being asked for outside the enum's range.
	_check(
		DotFpsState.mode_name(ladder_id, motor) == "ladder",
		"a custom mode renders by name",
		DotFpsState.mode_name(ladder_id, motor)
	)
	_check(
		DotFpsState.mode_name(DotFpsState.Mode.GROUND) == "GROUND",
		"and a built-in one still does without a motor"
	)

	# Gravity resumes as soon as the built-in mode is back, which is the check that
	# the dispatch actually returns rather than falling through.
	var before := s.position.y
	for _i in range(30):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.position.y < before, "and the built-in modes take over again")


func _test_crouch_headroom() -> void:
	print("crouching")

	var t := _tunables()
	t.crouch_transition_time = 0.0

	# A ceiling at 1.2 m: enough room to crouch under, not enough to stand.
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(-4.0, 1.2, -4.0), Vector3(8.0, 1.0, 8.0)))

	var motor := _motor(t, world)
	var s := DotFpsState.new()
	s.position = Vector3.ZERO
	s.mode = DotFpsState.Mode.GROUND

	for _i in range(10):
		motor.simulate(
			s, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH), STEP
		)

	_check(s.is_crouched(), "the player crouches under a low ceiling")

	# Release crouch. There is no headroom, so the stand-up must be refused rather
	# than pushing the player through the ceiling — which is what the previous
	# controller did, because it only lerped a camera offset and never tested.
	for _i in range(30):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(
		s.is_crouched(),
		"standing up is refused when there is no headroom",
		"crouch fraction %.3f" % s.crouch_fraction
	)
	_check(
		not s.crouch_held,
		"but the controller knows the button was released"
	)
	_check(
		s.position.y < 1.2,
		"and the player is still below the ceiling",
		"y = %.3f" % s.position.y
	)

	# Step out from under it and the player stands on their own.
	s.position = Vector3(0.0, 0.0, 20.0)

	for _i in range(60):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(not s.is_crouched(), "and stands as soon as there is room")


func _test_crouch_jump() -> void:
	print("crouch-jump")

	var t := _tunables()
	t.instant_air_crouch = true
	var motor := _motor(t)
	var s := _standing(motor)

	motor.simulate(s, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)

	var feet_before := s.position.y
	motor.simulate(s, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH), STEP)

	_check(
		s.position.y > feet_before,
		"crouching in mid-air lifts the feet toward the head",
		"%.3f -> %.3f" % [feet_before, s.position.y]
	)


func _test_stair_step() -> void:
	print("stairs")

	var t := _tunables()
	t.step_height = 0.4
	var world := DotFpsFlatBody.with_floor(0.0)

	# A 0.3 m step, well within step_height, blocking the path forward.
	world.add_box(AABB(Vector3(-4.0, 0.0, -8.0), Vector3(8.0, 0.3, 4.0)))

	var motor := _motor(t, world)
	var s := _standing(motor)

	# Sampled while the player is over the step rather than at the end of the run:
	# the step is only four metres deep and at 7 m/s they walk off the far side of it
	# long before 180 ticks are up. Checking the final position tested where the
	# level ran out, not whether the step was climbed.
	var height_on_step := -1.0

	for _i in range(180):
		motor.simulate(s, _command(1.0), STEP)
		if s.position.z < -4.5 and s.position.z > -7.5:
			height_on_step = maxf(height_on_step, s.position.y)

	_check(
		s.position.z < -4.5,
		"the player walks up a step instead of stopping at it",
		"z = %.2f" % s.position.z
	)
	_check_near(height_on_step, 0.3, 0.05, "and is standing on top of it")

	# A wall taller than step_height must still stop them.
	var walled := DotFpsFlatBody.with_floor(0.0)
	walled.add_box(AABB(Vector3(-4.0, 0.0, -8.0), Vector3(8.0, 2.0, 4.0)))

	var wall_motor := _motor(t, walled)
	var wall_state := _standing(wall_motor)

	for _i in range(180):
		wall_motor.simulate(wall_state, _command(1.0), STEP)

	_check(
		wall_state.position.y < 0.1,
		"a wall taller than step_height is not climbed",
		"y = %.3f" % wall_state.position.y
	)


func _test_step_refused_without_floor() -> void:
	print("step rejection")

	var t := _tunables()
	t.step_height = 0.4

	# A thin overhang with nothing to stand on: the up-and-across leg succeeds and
	# the down leg finds nothing, so the step must be rejected. Accepting it would
	# leave the player hovering at step height, dropped back next tick, forever.
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(-4.0, 0.0, -8.0), Vector3(8.0, 0.2, 0.2)))

	var motor := _motor(t, world)
	var s := _standing(motor)

	var max_y := 0.0

	for _i in range(120):
		motor.simulate(s, _command(1.0), STEP)
		max_y = maxf(max_y, s.position.y)

	_check(
		max_y <= 0.25,
		"a step with nothing behind it does not leave the player hovering",
		"peak y = %.3f" % max_y
	)


func _test_ground_snap() -> void:
	print("ground snap")

	var t := _tunables()
	t.ground_snap = true

	# A descending staircase. Without snapping the player leaves the ground on every
	# tread, gets air physics, and skates.
	var world := DotFpsFlatBody.with_floor(-10.0)
	for i in range(12):
		world.add_box(AABB(
			Vector3(-4.0, -0.2 * float(i) - 1.0, -2.0 - 2.0 * float(i)),
			Vector3(8.0, 1.0 + 0.2 * float(i), 2.0)
		))

	var motor := _motor(t, world)
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.0, -1.0)
	s.mode = DotFpsState.Mode.GROUND

	for _i in range(8):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	var airborne_ticks := 0

	for _i in range(180):
		motor.simulate(s, _command(1.0), STEP)
		if not s.is_grounded():
			airborne_ticks += 1

	_check(
		airborne_ticks <= 6,
		"walking down steps keeps the player grounded",
		"%d airborne ticks of 180" % airborne_ticks
	)


func _test_coyote_and_buffer() -> void:
	print("jump forgiveness")

	var t := _tunables()
	t.coyote_time = 0.1
	t.jump_buffer_time = 0.1

	# A ledge to walk off.
	var world := DotFpsFlatBody.with_floor(-20.0)
	world.add_box(AABB(Vector3(-4.0, -1.0, -3.0), Vector3(8.0, 1.0, 8.0)))

	var motor := _motor(t, world)
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.0, 0.0)
	s.mode = DotFpsState.Mode.GROUND

	for _i in range(6):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.is_grounded(), "standing on the ledge")

	# Walk off the near edge (+Z), then jump two ticks later — inside coyote time.
	var left := false
	var ticks := 0

	while not left and ticks < 200:
		motor.simulate(s, _command(-1.0), STEP)
		left = not s.is_grounded()
		ticks += 1

	motor.simulate(s, _command(-1.0), STEP)

	var before := s.velocity.y
	motor.simulate(s, _command(-1.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)

	_check(
		s.velocity.y > before + 1.0,
		"a jump just after leaving a ledge still fires (coyote time)",
		"%.2f -> %.2f" % [before, s.velocity.y]
	)

	# And the counter-test: long past the window, it must not.
	var late := DotFpsState.new()
	late.position = Vector3(0.0, 8.0, 0.0)
	late.mode = DotFpsState.Mode.AIR
	late.time_since_grounded = 5.0

	var late_before := late.velocity.y
	motor.simulate(
		late, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP
	)

	_check(
		late.velocity.y < late_before,
		"a jump long after leaving the ground does not fire",
		"%.2f -> %.2f" % [late_before, late.velocity.y]
	)


func _test_noclip_gating() -> void:
	print("noclip")

	var allowed := _tunables()
	allowed.can_noclip = true
	var motor := _motor(allowed)
	var s := _standing(motor)

	motor.simulate(s, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP), STEP)
	_check(
		s.mode == DotFpsState.Mode.NOCLIP,
		"the noclip button toggles noclip when it is allowed"
	)

	# Straight through the floor.
	for _i in range(60):
		motor.simulate(s, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH), STEP)

	_check(s.position.y < -1.0, "and the player passes through geometry")

	var denied := _tunables()
	denied.can_noclip = false
	var denied_motor := _motor(denied)
	var denied_state := _standing(denied_motor)

	for _i in range(4):
		denied_motor.simulate(
			denied_state,
			_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP),
			STEP
		)

	_check(
		denied_state.mode != DotFpsState.Mode.NOCLIP,
		"and is ignored when it is not"
	)

	# Revoking the ability mid-flight must drop the player out of it, not leave them
	# flying because they entered before the rules changed.
	var revoked := _tunables()
	revoked.can_noclip = true
	var revoked_motor := _motor(revoked)
	var revoked_state := _standing(revoked_motor)

	revoked_motor.simulate(
		revoked_state, _command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP), STEP
	)
	revoked.can_noclip = false
	revoked_motor.simulate(revoked_state, DotFpsCommand.new(), STEP)

	_check(
		revoked_state.mode != DotFpsState.Mode.NOCLIP,
		"revoking noclip drops a player already using it"
	)


func _test_command_sanitising() -> void:
	print("command validation")

	var c := DotFpsCommand.new()
	c.move = Vector2(40.0, 40.0)
	c.yaw = 100000.0
	c.pitch = 5000.0
	c.buttons = 0xFFFF
	c.sanitise(-89.0, 89.0)

	_check(
		c.move.length() <= 1.0001,
		"an oversized move vector is clamped",
		"%.3f" % c.move.length()
	)
	_check(absf(c.yaw) <= 180.0, "yaw is wrapped")
	_check(c.pitch <= 89.0001, "pitch is clamped")
	_check(
		c.buttons < (1 << DotFpsCommand.BUTTON_BITS),
		"unknown button bits are dropped"
	)

	# NaN survives every comparison, so a naive clamp lets it through and it poisons
	# the position permanently.
	var nan_command := DotFpsCommand.new()
	nan_command.move = Vector2(NAN, NAN)
	nan_command.yaw = NAN
	nan_command.pitch = NAN
	nan_command.sanitise()

	_check(
		is_finite(nan_command.move.x) and is_finite(nan_command.yaw),
		"a NaN command is neutralised"
	)

	# And the whole point: a sanitised command cannot move the player faster.
	var t := _tunables()
	var motor := _motor(t)
	var s := _standing(motor)

	var cheat := DotFpsCommand.new()
	cheat.move = Vector2(0.0, 50.0)
	cheat.sanitise()

	for _i in range(240):
		motor.simulate(s, cheat, STEP)

	_check(
		s.horizontal_speed() <= t.max_speed + 0.2,
		"a client claiming a huge move vector still runs at max_speed",
		"%.2f m/s" % s.horizontal_speed()
	)


func _test_touch_sampler() -> void:
	print("touch sampling")

	var t := _tunables()
	var sampler := DotFpsTouchSampler.new(t)
	sampler.set_screen_width(1000.0)
	sampler.tap_button = DotFpsCommand.BUTTON_JUMP

	# A finger on the left half plants the stick where it landed.
	sampler.handle_event(_touch(0, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(0, Vector2(200.0, 500.0 - sampler.stick_radius)))

	var forward := sampler.sample(STEP)
	_check_near(forward.move.y, 1.0, 0.02, "dragging up the screen moves forward")
	_check_near(forward.move.x, 0.0, 0.02, "with no lateral component")

	sampler.handle_event(_drag(0, Vector2(200.0 + sampler.stick_radius, 500.0)))
	var strafe := sampler.sample(STEP)
	_check_near(strafe.move.x, 1.0, 0.02, "and dragging right strafes right")

	# A thumb resting on glass drifts; a player who is not moving must not creep.
	sampler.handle_event(_drag(0, Vector2(205.0, 500.0)))
	var resting := sampler.sample(STEP)
	_check(
		resting.move == Vector2.ZERO,
		"a drift inside the dead zone is no input",
		str(resting.move)
	)

	sampler.handle_event(_touch(0, Vector2(205.0, 500.0), false))
	var lifted := sampler.sample(STEP)
	_check(lifted.move == Vector2.ZERO, "lifting the finger stops the player")

	# The right half turns the view.
	var before_yaw := sampler.yaw
	sampler.handle_event(_touch(1, Vector2(800.0, 500.0), true))
	sampler.handle_event(_drag(1, Vector2(900.0, 500.0)))
	sampler.sample(STEP)

	_check(
		not is_equal_approx(sampler.yaw, before_yaw),
		"dragging the right half turns the view"
	)

	# And a short, still touch there is a tap, not a drag of zero length.
	sampler.handle_event(_touch(1, Vector2(900.0, 500.0), false))
	sampler.handle_event(_touch(2, Vector2(820.0, 400.0), true))
	sampler.handle_event(_touch(2, Vector2(822.0, 401.0), false))

	var tapped := sampler.sample(STEP)
	_check(
		tapped.is_pressed(DotFpsCommand.BUTTON_JUMP),
		"a tap presses the configured button"
	)

	var after_tap := sampler.sample(STEP)
	_check(
		not after_tap.is_pressed(DotFpsCommand.BUTTON_JUMP),
		"for exactly one command, so a tap and a hold stay distinguishable"
	)

	# The game's own on-screen buttons.
	sampler.hold(DotFpsCommand.BUTTON_CROUCH, true)
	_check(
		sampler.sample(STEP).is_pressed(DotFpsCommand.BUTTON_CROUCH),
		"a held on-screen button reaches the command"
	)

	sampler.hold(DotFpsCommand.BUTTON_CROUCH, false)
	_check(
		not sampler.sample(STEP).is_pressed(DotFpsCommand.BUTTON_CROUCH),
		"and releasing it stops"
	)

	# Suspending has to stop everything, or an open chat box leaves the player
	# running because a finger was down when it opened.
	sampler.handle_event(_touch(3, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(3, Vector2(200.0, 300.0)))
	sampler.suspended = true

	var suspended := sampler.sample(STEP)
	_check(
		suspended.move == Vector2.ZERO and suspended.buttons == 0,
		"a suspended sampler emits nothing"
	)

	# And the point of the whole exercise: touch produces ordinary commands, so the
	# simulation cannot tell where they came from.
	var motor := _motor(t)
	var s := _standing(motor)

	sampler.suspended = false
	sampler.handle_event(_touch(3, Vector2(200.0, 500.0), false))
	sampler.handle_event(_touch(4, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(4, Vector2(200.0, 500.0 - sampler.stick_radius)))

	for _i in range(120):
		motor.simulate(s, sampler.sample(STEP), STEP)

	_check(
		s.horizontal_speed() > t.max_speed * 0.8,
		"and a touch-driven player reaches ordinary walking speed",
		"%.2f m/s" % s.horizontal_speed()
	)


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


func _test_wire_round_trip() -> void:
	print("wire format")

	var original := DotFpsCommand.new()
	original.move = Vector2(-0.5, 0.75)
	original.yaw = -134.0
	original.pitch = 42.0
	original.buttons = (
		DotFpsCommand.BUTTON_JUMP
		| DotFpsCommand.BUTTON_SPRINT
		| DotFpsCommand.BUTTON_USER_1
	)

	var wire := FakeWire.new()
	original.write(wire)

	var decoded := DotFpsCommand.new()
	decoded.read(wire)

	_check(
		wire.values.size() == 5,
		"the command writes every field",
		"wrote %d" % wire.values.size()
	)
	_check_near(decoded.move.x, -0.5, 0.01, "move.x survives quantisation")
	_check_near(decoded.move.y, 0.75, 0.01, "move.y survives quantisation")
	_check_near(decoded.yaw, -134.0, 0.2, "yaw survives quantisation")
	_check_near(decoded.pitch, 42.0, 0.5, "pitch survives quantisation")
	_check(
		decoded.buttons == original.buttons,
		"buttons survive exactly, including the game's own bits"
	)
	_check(
		DotFpsCommand.estimated_bits() < 64,
		"a command costs under 8 bytes",
		"%d bits" % DotFpsCommand.estimated_bits()
	)


func _test_net_sync_round_trip() -> void:
	print("net sync")

	var specs := DotFpsNetSync.state_specs()
	_check(specs.size() == 7, "seven properties replicate", "%d" % specs.size())

	for spec in specs:
		_check(
			spec.has("property") and spec.has("type") and spec.has("source"),
			"spec %s is complete" % str(spec.get("property", "?"))
		)

	# A stand-in for the DotNetBehaviour the host game writes. Only get/set are used,
	# which is exactly what DotFpsNetSync relies on.
	var carrier := Node.new()
	carrier.set_script(_carrier_script())

	var source := DotFpsState.new()
	source.position = Vector3(12.5, 3.25, -7.75)
	source.velocity = Vector3(1.5, -4.0, 0.25)
	source.yaw = 91.0
	source.pitch = -20.0
	source.crouch_fraction = 1.0
	source.crouch_held = true
	source.mode = DotFpsState.Mode.GROUND

	DotFpsNetSync.pull(source, carrier)

	var target := DotFpsState.new()
	DotFpsNetSync.push(carrier, target)

	_check(
		target.position.is_equal_approx(source.position),
		"position round-trips"
	)
	_check(
		target.velocity.is_equal_approx(source.velocity),
		"velocity round-trips"
	)
	_check(target.mode == source.mode, "the movement mode round-trips")
	_check(target.crouch_held == source.crouch_held, "crouch_held round-trips")
	_check_near(
		target.crouch_fraction, 1.0, 0.0001, "the crouch fraction round-trips"
	)

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

	_check(
		DotFpsNetSync.estimated_state_bits() < 160,
		"a full state update stays under 20 bytes",
		"%d bits" % DotFpsNetSync.estimated_state_bits()
	)

	carrier.free()


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


func _test_fingerprint() -> void:
	print("configuration agreement")

	var a := _tunables()
	var b := _tunables()

	_check(
		a.fingerprint() == b.fingerprint(),
		"identical tunables have identical fingerprints"
	)

	b.mouse_sensitivity = 3.0
	b.invert_look_y = true

	_check(
		a.fingerprint() == b.fingerprint(),
		"look preferences do not change the fingerprint"
	)

	b.air_accelerate = 10.0

	_check(
		a.fingerprint() != b.fingerprint(),
		"a simulation value does change it"
	)
	_check(
		not DotFpsNetSync.agrees(a, b.fingerprint()),
		"and the peers are reported as disagreeing"
	)

	var diff := DotFpsNetSync.differences(a, b)
	var named := false
	for line in diff:
		if line.begins_with("air_accelerate"):
			named = true

	_check(named, "the mismatch names the property that differs")


## The property everything else depends on.
##
## Simulate a command sequence twice from the same start and require identical
## results; then simulate once, snapshot mid-way, and replay the rest from the
## snapshot — which is precisely what client-side reconciliation does. If this fails,
## prediction cannot work, and the failure at runtime looks like packet loss rather
## than like a bug.
func _test_replay_determinism() -> void:
	print("determinism")

	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(2.0, 0.0, -12.0), Vector3(2.0, 0.3, 6.0)))
	world.add_box(AABB(Vector3(-6.0, 0.0, -20.0), Vector3(12.0, 3.0, 1.0)))

	var t := _tunables()

	# Surfaces and modifiers are simulation, so the replay has to reproduce them too.
	# Without them in here, the determinism guarantee would cover the movement and
	# quietly not cover the two systems most likely to break it — a modifier held
	# outside the state, or a surface resolved from something machine-local.
	var patch := DotFpsSurface.make(&"ice")
	patch.friction_scale = 0.1
	patch.accelerate_scale = 0.4

	var surface_set := DotFpsSurfaceSet.new()
	surface_set.add(patch)

	var boost := DotFpsModifier.make(&"boost")
	boost.max_speed_scale = 1.6
	boost.duration_sec = 1.5

	# A varied sequence: running, turning, jumping, crouching, hitting a step and a
	# wall. A sequence of one held key would pass this test with a broken replay.
	var commands: Array[DotFpsCommand] = []

	for i in range(400):
		var yaw := sin(float(i) * 0.05) * 70.0
		var buttons := 0

		if i % 37 == 0:
			buttons |= DotFpsCommand.BUTTON_JUMP
		if (i / 40) % 3 == 1:
			buttons |= DotFpsCommand.BUTTON_CROUCH
		if (i / 40) % 3 == 2:
			buttons |= DotFpsCommand.BUTTON_SPRINT

		commands.append(_command(1.0, sin(float(i) * 0.11), yaw, buttons))

	var first_motor := _build_motor(t, world, surface_set, boost)
	var first := DotFpsState.new()
	first.position = Vector3(0.0, 0.5, 0.0)
	_run_window(first_motor, first, commands, 0, commands.size())

	var second_motor := _build_motor(t, world, surface_set, boost)
	var second := DotFpsState.new()
	second.position = Vector3(0.0, 0.5, 0.0)
	_run_window(second_motor, second, commands, 0, commands.size())

	_check(
		first.equals(second, 0.0),
		"the same commands produce a bit-identical result",
		"diverged by %.6f m" % first.divergence(second)
	)

	# Now the reconciliation shape. Run to tick 250, keep the state, then replay the
	# last 150 commands from that snapshot and require the same endpoint.
	var split := 250

	var full_motor := _build_motor(t, world, surface_set, boost)
	var full := DotFpsState.new()
	full.position = Vector3(0.0, 0.5, 0.0)

	var snapshot: DotFpsState = null

	for i in range(commands.size()):
		_apply_scripted_modifier(full_motor, full, i)
		full_motor.simulate(full, commands[i], STEP)
		if i == split - 1:
			snapshot = full.duplicate_state()

	var replay_motor := _build_motor(t, world, surface_set, boost)
	var replayed := snapshot.duplicate_state()

	_run_window(replay_motor, replayed, commands, split, commands.size())

	_check(
		replayed.equals(full, 0.0001),
		"replaying from a snapshot reproduces the simulation exactly",
		"diverged by %.6f m over %d replayed ticks"
			% [replayed.divergence(full), commands.size() - split]
	)

	# The negative control. Without one, "the replay matched" could mean the check is
	# incapable of noticing that it did not — so replay the same window with a single
	# command altered and require the result to differ.
	#
	# [b]Altering a command, not the starting state, is the sharper control.[/b] An
	# earlier version dropped half the fields from the snapshot and expected
	# divergence; it converged anyway, because the motor recomputes the ground mode
	# from geometry every tick and the crouch fraction and timers all settle within a
	# few ticks. That is a good property of the simulation and a useless control: it
	# proved only that those fields are self-healing, not that the comparison works.
	var altered: Array[DotFpsCommand] = commands.duplicate()
	# Typed explicitly: Array.duplicate() returns an untyped Array, so indexing it
	# yields a Variant and `var changed := ...` is a parse error under these
	# projects' warning settings.
	var changed: DotFpsCommand = altered[split + 5].duplicate_command()
	# The move vector, not a button: a jump press changes nothing on a tick the
	# player happens to be airborne, and a control that silently no-ops is worse than
	# no control at all. Reversing the direction always changes the next tick.
	changed.move = -changed.move
	changed.yaw += 90.0
	altered[split + 5] = changed

	var altered_motor := _build_motor(t, world, surface_set, boost)
	var altered_state := snapshot.duplicate_state()

	_run_window(altered_motor, altered_state, altered, split, altered.size())

	_check(
		not altered_state.equals(full, 0.0001),
		"changing one command in the replay does diverge, so the test can fail",
		"divergence %.6f m" % altered_state.divergence(full)
	)


## The real [DotFpsBody], against the real physics server.
##
## Everything above tests the motor. This tests the query layer the motor asks, which
## is the other half and cannot be exercised without a physics world and a frame for
## it to settle.
func _test_physics_body() -> void:
	print("physics body")

	var world := Node3D.new()
	add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 40.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(floor_body)

	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(10.0, 4.0, 1.0)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(0.0, 2.0, -6.0)
	world.add_child(wall)

	# Two physics frames: one for the bodies to enter the space, one for it to build.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	var bound := body.bind(world)

	if not _check(bound.ok, "the physics body binds to a world"):
		world.queue_free()
		return

	var t := _tunables()
	var motor := DotFpsMotor.new(t, body)

	var s := DotFpsState.new()
	s.position = Vector3(0.0, 3.0, 0.0)
	s.mode = DotFpsState.Mode.AIR

	for _i in range(180):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.is_grounded(), "a player falls onto real collision geometry")
	_check_near(s.position.y, 0.0, 0.05, "and rests on its surface")

	for _i in range(240):
		motor.simulate(s, _command(1.0), STEP)

	_check(
		s.position.z > -6.0,
		"and is stopped by a real wall",
		"z = %.3f" % s.position.z
	)
	_check(
		motor.stuck_ticks == 0,
		"without the slide running out of iterations",
		"%d stuck ticks" % motor.stuck_ticks
	)

	# The overlap query, which is what the standing-up test uses.
	var inside := body.overlaps(
		Vector3(0.0, 2.0, -6.0), t.stand_height, t.radius
	)
	var clear := body.overlaps(
		Vector3(0.0, 2.0, 6.0), t.stand_height, t.radius
	)

	_check(inside, "overlaps() finds geometry the capsule is inside")
	_check(not clear, "and reports clear space as clear")

	world.queue_free()
