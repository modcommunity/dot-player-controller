extends "res://examples/movement_selftest_physics.gd"

## The wall-running and wall-jumping sections of the movement self-test.


func _test_wall_run() -> void:
	_section("wall running")

	# Off by default: the same approach is an ordinary fall past the wall.
	var off_motor := _motor(_tunables(), _wall_world())
	var off := _beside_wall(9.0)
	var off_run := _run_along(off_motor, off, 30)
	_check(off_run.running == 0 and off_motor.wall_runs == 0,
		"wall running is off unless a game turns it on")

	var t := _wall_tunables()
	var motor := _motor(t, _wall_world())

	# Entry: airborne, fast along the wall.
	var s := _beside_wall(9.0)
	var speed_before := s.horizontal_speed()
	motor.simulate(s, _command(1.0, 0.0, 0.0), STEP)
	_check(s.is_wall_running(), "an airborne player fast along a wall runs on it",
		"%s" % ", ".join(s.describe_lines()))
	_check(s.wall_normal.dot(Vector3.LEFT) > 0.99, "and the state names the wall's normal",
		"%s" % s.wall_normal)
	_check_near(s.horizontal_speed(), speed_before, 0.01,
		"the speed along the wall is the speed the player arrived with")

	_wall_run_entry_refusals(t)

	# The cap: a run lasts wall_run_max_time and ends; still beside the wall it does not
	# start again until the player lands.
	var capped_motor := _motor(t, _wall_world())
	var capped := _beside_wall(9.0, 1.0, 8.0)
	var start_y := capped.position.y
	var during := _run_along(capped_motor, capped, 60)
	# A fall from 1 m/s up over the same second would lose nine metres.
	_check(capped.position.y > start_y - 1.0,
		"a run holds the player up: under a metre lost in a second on the wall",
		"y %.2f from %.2f" % [capped.position.y, start_y])
	var after := _run_along(capped_motor, capped, 30)
	var whole := {
		"running": during.running + after.running,
		"worst": maxf(during.worst, after.worst),
	}
	_check_near(whole.running * STEP, t.wall_run_max_time, STEP * 1.5,
		"a run ends at wall_run_max_time")
	_check(capped_motor.wall_runs == 1 and capped.wall_run_spent,
		"and does not start again on the same wall before landing",
		"%d runs" % capped_motor.wall_runs)
	_check(whole.worst < t.gravity * STEP * 1.05,
		"no tick changes the velocity by more than a tick of gravity, entry and end included",
		"worst %.3f m/s against %.3f" % [whole.worst, t.gravity * STEP])

	_wall_run_ends(t)

	# The wall slide: a run that ends decays into a capped slide down the wall.
	var sliding := _wall_tunables()
	sliding.wall_slide_speed = 2.0
	var slide_motor := _motor(sliding, _wall_world())
	var slider := _beside_wall(9.0, 1.0, 8.0)
	var slid := _run_along(slide_motor, slider, 150)
	_check(slider.wall_run_spent and slider.velocity.y >= -2.0 - 0.001 and slider.velocity.y < 0.0,
		"after the run the player slides down the wall at wall_slide_speed",
		"%.3f m/s" % slider.velocity.y)
	_check(slid.worst < sliding.gravity * STEP * 1.05, "and the slide starts without a jolt",
		"worst %.3f m/s" % slid.worst)
	_check(capped.velocity.y < -3.0,
		"while without the slide the same run ends in a free fall",
		"%.3f m/s" % capped.velocity.y)

	_wall_run_ledge(t)
	_done()


## Entry refusals: too slow, on the ground, no forward held, and head-on.
func _wall_run_entry_refusals(t: DotFpsTunables) -> void:
	# Entry needs speed along the wall.
	var slow_motor := _motor(t, _wall_world())
	var slow := _beside_wall(4.0)
	_run_along(slow_motor, slow, 10)
	_check(slow_motor.wall_runs == 0, "too slow along the wall is no run",
		"%d runs" % slow_motor.wall_runs)

	var floor_motor := _motor(t, _wall_world())
	var grounded := _beside_wall(9.0, 0.0, 0.0)
	grounded.mode = DotFpsState.Mode.GROUND
	grounded.time_since_grounded = 0.0
	_run_along(floor_motor, grounded, 30)
	_check(floor_motor.wall_runs == 0 and grounded.is_grounded(),
		"on the ground beside a wall is no run")

	# Entry needs forward held (wall_run_requires_forward).
	var idle_motor := _motor(t, _wall_world())
	var idle := _beside_wall(9.0)
	idle_motor.simulate(idle, _command(0.0, 0.0, 0.0), STEP)
	_check(not idle.is_wall_running(), "and forward held")

	# Head-on is not a run, however fast.
	var head_on_motor := _motor(t, _wall_world())
	var head_on := _beside_wall(0.0)
	# 62 degrees into the wall, with 6.2 m/s along it: fast enough, but at the wall.
	head_on.velocity = Vector3(12.0, 1.0, -6.2)
	head_on_motor.simulate(head_on, _command(1.0, 0.0, -90.0), STEP)
	_check(not head_on.is_wall_running(), "a player running at the wall head-on does not run on it")


## Releasing forward and landing both end a run.
func _wall_run_ends(t: DotFpsTunables) -> void:
	var drop_motor := _motor(t, _wall_world())
	var drop := _beside_wall(9.0)
	_run_along(drop_motor, drop, 10)
	drop_motor.simulate(drop, _command(0.0, 0.0, 0.0), STEP)
	_check(not drop.is_wall_running() and drop.wall_run_spent, "releasing forward ends the run")

	var heavy := _wall_tunables()
	heavy.wall_run_gravity_scale = 1.0
	heavy.wall_run_vertical_damping = 0.0
	var land_motor := _motor(heavy, _wall_world())
	var lander := _beside_wall(9.0, 0.0, 0.6)
	_run_along(land_motor, lander, 30)
	_check(lander.is_grounded() and not lander.is_wall_running() and not lander.wall_run_spent,
		"landing ends a run and lets the next one start", "%s" % ", ".join(lander.describe_lines()))


## A run just past a ledge's end keeps the wall beside it.
func _wall_run_ledge(t: DotFpsTunables) -> void:
	# The uncrouch after a slide-jump drops the feet under the ledge's top; nearest-wins then took
	# the ledge's end face, whose "along" speed is nothing, and ended the run.
	var ledged := _wall_world()
	ledged.add_box(AABB(Vector3(-3.0, 0.0, -1.55), Vector3(4.0, 2.52, 6.0)))
	var ledge_motor := _motor(t, ledged)
	var off_ledge := _beside_wall(11.8, 4.0, 2.6)
	# 16 cm off the wall, 10 behind the ledge's end: the ledge is the nearer face.
	off_ledge.position.x = 1.0 - 0.35 - 0.16
	off_ledge.wall_run_time = 0.05
	off_ledge.crouch_fraction = 0.26
	off_ledge.time_since_grounded = 0.06
	ledge_motor.simulate(off_ledge, _command(1.0, 0.0, 0.0), STEP)
	_check(off_ledge.is_wall_running() and off_ledge.wall_normal.dot(Vector3.LEFT) > 0.99,
		"a run just past a ledge's end keeps the wall beside it, not the ledge's face behind",
		"%s" % ", ".join(off_ledge.describe_lines()))


func _test_wall_run_corridor() -> void:
	_section("a wall run along a corridor, end to end")
	var jump := DotFpsCommand.BUTTON_JUMP
	var t := _wall_tunables()
	var wall_x := 1.0

	# Stays up: a second of running along the wall holds the player near their height and
	# on the wall the whole way (the cap is wall_run_max_time).
	var motor := _motor(t, _wall_world())
	var s := _beside_wall(11.0, 1.0, 8.0)
	var start_y := s.position.y
	var held := 0
	var near_wall := true
	for _i in range(int(0.8 / STEP)):
		motor.simulate(s, _command(1.0, 0.0, 0.0), STEP)
		if s.is_wall_running():
			held += 1
		near_wall = near_wall and wall_x - s.position.x < 0.6
	_check(held * STEP >= 0.75, "it keeps running for most of a second", "%.2f s" % (held * STEP))
	_check(near_wall and s.position.y > start_y - 0.8,
		"and stays up and beside the wall while it does", "y %.2f from %.2f" % [s.position.y, start_y])
	_check(s.horizontal_speed() > 10.0, "at the speed it arrived with (the speed floor holds)",
		"%.2f m/s" % s.horizontal_speed())

	# Space leaps off, away from the wall, and the run does not come back.
	motor.simulate(s, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(not s.is_wall_running() and s.velocity.x < 0.0, "space leaps off, away from the wall",
		"vx %.2f" % s.velocity.x)
	for _i in range(20):
		motor.simulate(s, _command(1.0, 0.0, 0.0), STEP)
	_check(wall_x - s.position.x > 1.0 and not s.is_wall_running(),
		"and a third of a second later the player is clear of the wall",
		"%.2f m off" % (wall_x - s.position.x))

	# Stopping drops you: forward released, the player falls and is not re-caught.
	var stop_motor := _motor(t, _wall_world())
	var stop := _beside_wall(11.0, 1.0, 8.0)
	for _i in range(15):
		stop_motor.simulate(stop, _command(1.0, 0.0, 0.0), STEP)
	_check(stop.is_wall_running(), "ready to be stopped: running")
	var y_stop := stop.position.y
	for _i in range(30):
		stop_motor.simulate(stop, _command(0.0, 0.0, 0.0), STEP)
	_check(not stop.is_wall_running() and stop.velocity.y < -2.0 and stop.position.y < y_stop - 0.3,
		"releasing forward drops the player, who then falls",
		"vy %.2f, dropped %.2f m" % [stop.velocity.y, y_stop - stop.position.y])

	# Turning away drops you: the view turned off the wall with forward held steers the
	# player away, and the run ends once the velocity leaves the wall.
	var turn_motor := _motor(t, _wall_world())
	var turn := _beside_wall(11.0, 1.0, 8.0)
	for _i in range(10):
		turn_motor.simulate(turn, _command(1.0, 0.0, 0.0), STEP)
	for _i in range(90):
		turn_motor.simulate(turn, _command(1.0, 0.0, 80.0), STEP)
	_check(not turn.is_wall_running(), "turning away from the wall ends the run",
		"%s" % ", ".join(turn.describe_lines()))
	_done()


func _test_wall_run_auto() -> void:
	_section("an airborne touch of a wall starts a run with no press")

	var jump := DotFpsCommand.BUTTON_JUMP
	var t := _wall_tunables()
	t.wall_run_min_speed = 20.0
	t.wall_jump_max_per_air = 3

	var off_motor := _motor(t, _wall_world())
	var off := _beside_wall(2.0, -1.0)
	off.velocity = Vector3(5.0, 0.0, -5.0)
	off_motor.simulate(off, _command(1.0, 0.0, 0.0), STEP)
	_check(off_motor.wall_runs == 0, "wall_run_auto is off unless a game turns it on")

	t.wall_run_auto = true
	var motor := _motor(t, _wall_world())
	var s := _beside_wall(2.0, -1.0)
	s.velocity = Vector3(5.0, 0.0, -5.0)
	motor.simulate(s, _command(1.0, 0.0, 0.0), STEP)
	_check(s.is_wall_running() and motor.wall_runs == 1 and motor.wall_jumps == 0,
		"moving into a wall in the air starts a run with no press", ", ".join(s.describe_lines()))
	motor.simulate(s, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(motor.wall_jumps == 1 and not s.is_wall_running(),
		"a press during the run jumps off the wall", ", ".join(s.describe_lines()))

	var idle := _beside_wall(2.0, -1.0)
	idle.velocity = Vector3(5.0, 0.0, -5.0)
	motor = _motor(t, _wall_world())
	motor.simulate(idle, _command(0.0, 0.0, 0.0), STEP)
	_check(motor.wall_runs == 0, "no forward held, no automatic run")
	_done()


func _test_wall_no_stick_walking() -> void:
	_section("walking or standing beside a wall never attaches; a real airborne run still does")

	for auto in [true, false]:
		var t := _wall_tunables()
		t.wall_run_auto = auto
		t.wall_run_min_speed = 5.0
		t.wall_run_jump_min_speed = 5.0
		var label := "auto" if auto else "plain"

		var motor := _motor(t, _wall_world())
		var walker := _beside_wall(0.0, 0.0, 0.0)
		walker.mode = DotFpsState.Mode.GROUND
		walker.position.y = 0.0
		walker.time_since_grounded = 0.0
		for _i in range(60):
			motor.simulate(walker, _command(1.0, 0.0, 0.0), STEP)
		_check(motor.wall_runs == 0 and not walker.is_wall_running(),
			"%s: a walk along a wall does not run" % label, ", ".join(walker.describe_lines()))

		motor = _motor(t, _wall_world())
		var bump := _beside_wall(8.0, 0.0)
		bump.time_since_grounded = 0.0
		motor.simulate(bump, _command(1.0, 0.0, 0.0), STEP)
		_check(motor.wall_runs == 0 and not bump.is_wall_running(),
			"%s: one tick of AIR at walking speed beside a wall does not attach" % label)

		motor = _motor(t, _wall_world())
		var real := _beside_wall(8.0, 0.5)
		motor.simulate(real, _command(1.0, 0.0, 0.0), STEP)
		_check(motor.wall_runs == 1 and real.is_wall_running(),
			"%s: a fast airborne run along the wall still starts" % label, ", ".join(real.describe_lines()))
	_done()


func _size_world(top: float) -> DotFpsFlatBody:
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, top, 200.0)))
	return world


## Runs a player beside an object of height [param top] and reports whether a run started, and
## whether the yaw or the view turn ever moved; a second motor replays the same ticks.
func _size_trial(t: DotFpsTunables, top: float, press_at: int = -1) -> Dictionary:
	var motor := _motor(t, _size_world(top))
	var twin := _motor(t, _size_world(top))
	var s := _beside_wall(8.0, 0.0, 1.0 if top > 2.0 else maxf(top - 0.2, 0.05))
	s.yaw = 0.0
	var mirror := s.duplicate_state()
	var steady := true
	var agree := true
	for i in range(30):
		var buttons := DotFpsCommand.BUTTON_JUMP if i == press_at else 0
		motor.simulate(s, _command(1.0, 0.0, 0.0, buttons), STEP)
		twin.simulate(mirror, _command(1.0, 0.0, 0.0, buttons), STEP)
		steady = steady and s.yaw == 0.0 and s.pitch == 0.0 and motor.view_turn == 0.0
		agree = agree and s.equals(mirror)
	return {"runs": motor.wall_runs, "jumps": motor.wall_jumps, "steady": steady, "agree": agree}


func _test_wall_run_min_size() -> void:
	_section("a wall run needs a wall of some size; a wall jump does not")

	var t := _wall_tunables()
	t.wall_run_auto = true
	t.wall_run_turn_view = true
	t.wall_run_jump_min_speed = 5.0

	var wall := _size_trial(t, 3.0)
	_check(wall["runs"] == 1 and wall["steady"] and wall["agree"], "a 3 m wall starts a run", str(wall))
	for top in [0.5, 1.0]:
		var low := _size_trial(t, top)
		_check(low["runs"] == 0 and low["steady"] and low["agree"],
			"a %.1f m block starts no run and never turns the view" % top, str(low))

	t.wall_run_auto = false
	t.wall_run_on_jump = true
	var pressed := _size_trial(t, 1.0, 2)
	_check(pressed["runs"] == 0 and pressed["jumps"] == 1 and pressed["steady"],
		"a press at a 1 m ledge wall-jumps instead of running", str(pressed))
	var big := _size_trial(t, 3.0, 2)
	_check(big["runs"] >= 1, "the same press at a 3 m wall still runs", str(big))

	t.wall_run_auto = true
	t.wall_run_on_jump = false
	t.wall_run_min_height = 0.0
	_check(_size_trial(t, 1.0)["runs"] == 1, "wall_run_min_height 0 turns the check off")

	t.wall_run_min_height = 2.0
	t.wall_run_min_length = 5.0
	var stub := DotFpsFlatBody.with_floor(0.0)
	stub.add_box(AABB(Vector3(1.0, 0.0, -3.0), Vector3(0.5, 12.0, 3.0)))
	var stub_motor := _motor(t, stub)
	var q := _beside_wall(8.0, 0.0, 3.0)
	q.position.z = -0.5
	stub_motor.simulate(q, _command(1.0, 0.0, 0.0), STEP)
	_check(stub_motor.wall_runs == 0, "a 3 m long wall stub does not carry a run needing 5 m")
	_done()


func _test_wall_run_on_jump() -> void:
	_section("a jump press starts a wall run")

	var jump := DotFpsCommand.BUTTON_JUMP
	var t := _wall_tunables()

	# Off by default: the press is a wall jump, not a run.
	var off_motor := _motor(t, _wall_world())
	var off := _beside_wall(2.0, -1.0)
	off.velocity = Vector3(5.0, -1.0, -5.0)
	off_motor.simulate(off, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(off_motor.wall_runs == 0, "wall_run_on_jump is off unless a game turns it on")

	t.wall_run_on_jump = true
	t.wall_run_min_speed = 20.0
	t.wall_jump_max_per_air = 3
	var motor := _motor(t, _wall_world())

	# 45 degrees into the wall at 7 m/s: too slow for the automatic run, enough for the press.
	var s := _beside_wall(2.0, -1.0)
	s.velocity = Vector3(5.0, 0.0, -5.0)
	var speed := s.horizontal_speed()
	motor.simulate(s, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(s.is_wall_running() and motor.wall_runs == 1 and motor.wall_jumps == 0,
		"a press beside the wall in the air starts a run, not a wall jump", ", ".join(s.describe_lines()))
	_check(absf(s.velocity.x) < 0.5 and -s.velocity.z > speed * 0.9,
		"the heading turns along the wall at the speed the player had",
		"%s from %.2f" % [s.velocity, speed])

	# A ground flicker (just left the floor, a kerb bump) with the press buffered is no run.
	var tf := _wall_tunables()
	tf.wall_run_on_jump = true
	tf.wall_run_min_speed = 20.0
	tf.coyote_time = 0.0
	var flicker_motor := _motor(tf, _wall_world())
	var flicker := _beside_wall(2.0, -1.0)
	flicker.velocity = Vector3(5.0, 0.0, -5.0)
	flicker.time_since_grounded = 0.0
	flicker_motor.simulate(flicker, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(flicker_motor.wall_runs == 0 and not flicker.is_wall_running(),
		"a jump press on a ground flicker does not attach a run", "%d runs" % flicker_motor.wall_runs)

	_wall_run_view_checks(motor, jump)

	var held := 0
	for _i in range(8):
		motor.simulate(s, _command(1.0, 0.0, 0.0), STEP)
		if s.is_wall_running():
			held += 1
	_check(held == 8, "and runs along it", "%d of 8 ticks" % held)

	# End 1: a second press jumps off the wall.
	motor.simulate(s, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(not s.is_wall_running() and motor.wall_jumps == 1 and s.velocity.x < -3.0,
		"a second press launches off the wall", "%s" % s.velocity)

	_wall_run_end_checks(t, jump)

	_wall_run_cooldown_checks(jump)

	_done()


## How a jump-started run turns the view along the wall.
func _wall_run_view_checks(motor: DotFpsMotor, jump: int) -> void:
	_check(motor.view_turn == 0.0, "the view is left alone unless wall_run_turn_view is on")
	var tv := _wall_tunables()
	tv.wall_run_on_jump = true
	tv.wall_run_turn_view = true
	tv.wall_run_min_speed = 20.0
	var turn_motor := _motor(tv, _wall_world())
	var turned := _beside_wall(2.0, -1.0)
	turned.velocity = Vector3(5.0, 0.0, -5.0)
	turn_motor.simulate(turned, _command(1.0, 0.0, -45.0, jump), STEP)
	_check(turned.is_wall_running() and absf(turn_motor.view_turn - 45.0) < 1.0,
		"a view looking where the player was heading is turned along the wall", "%.1f" % turn_motor.view_turn)
	turn_motor.simulate(turned, _command(1.0, 0.0, 0.0), STEP)
	_check(turn_motor.view_turn == 0.0, "and the turn is reported once")
	var away := _beside_wall(2.0, -1.0)
	away.velocity = Vector3(5.0, 0.0, -5.0)
	turn_motor.simulate(away, _command(1.0, 0.0, 135.0, jump), STEP)
	_check(away.is_wall_running() and turn_motor.view_turn == 0.0, "a view looking the other way is not turned")

	# Whatever the approach angle, the view ends parallel to the wall (yaw 0 runs down -Z).
	var at := _wall_tunables()
	at.wall_run_auto = true
	at.wall_run_turn_view = true
	at.wall_run_jump_min_speed = 5.0
	at.wall_run_jump_max_angle = 75.0
	for deg: float in [10.0, 25.0, 45.0, 60.0]:
		var align_motor := _motor(at, _wall_world())
		var aligned := _beside_wall(2.0, 1.0)
		var rad := deg_to_rad(deg)
		aligned.velocity = Vector3(sin(rad), 0.0, -cos(rad)) * 10.0
		var yaw: float = -deg
		align_motor.simulate(aligned, _command(1.0, 0.0, yaw), STEP)
		yaw += align_motor.view_turn
		align_motor.simulate(aligned, _command(1.0, 0.0, yaw), STEP)
		_check(aligned.is_wall_running() and absf(yaw) < 0.5 and absf(aligned.velocity.x) < 0.2,
			"attaching %d degrees off the wall settles the view and velocity parallel to it" % int(deg),
			"yaw %.2f vel %s" % [yaw, aligned.velocity])


## The ways a jump-started wall run ends: time cap, lost wall, stopping, forward released.
func _wall_run_end_checks(t: DotFpsTunables, jump: int) -> void:
	# End 2: the time cap.
	var tc := _wall_tunables()
	tc.wall_run_on_jump = true
	tc.wall_run_max_time = 0.25
	var cap_motor := _motor(tc, _wall_world())
	var cap := _beside_wall(2.0, 0.5, 8.0)
	cap.velocity = Vector3(3.0, 0.5, -9.0)
	cap_motor.simulate(cap, _command(1.0, 0.0, 0.0, jump), STEP)
	var started := cap.is_wall_running()
	var ticks := 0
	while cap.is_wall_running() and ticks < 100:
		cap_motor.simulate(cap, _command(1.0, 0.0, 0.0), STEP)
		ticks += 1
	_check(started and ticks > 5 and ticks < 40, "a run ends at wall_run_max_time", "%d ticks" % ticks)

	# End 3: losing the wall.
	var lost := _beside_wall(2.0, 0.5, 8.0)
	lost.velocity = Vector3(3.0, 0.5, -9.0)
	var lost_motor := _motor(t, _wall_world())
	lost_motor.simulate(lost, _command(1.0, 0.0, 0.0, jump), STEP)
	lost.position.x = -1.0
	lost_motor.simulate(lost, _command(1.0, 0.0, 0.0), STEP)
	_check(not lost.is_wall_running(), "a run ends when the wall is gone")

	# End 4: stopping.
	var slow := _beside_wall(2.0, 0.5, 8.0)
	slow.velocity = Vector3(3.0, 0.5, -9.0)
	var slow_motor := _motor(t, _wall_world())
	slow_motor.simulate(slow, _command(1.0, 0.0, 0.0, jump), STEP)
	slow.velocity = Vector3(0.0, 0.0, -1.0)
	slow_motor.simulate(slow, _command(1.0, 0.0, 0.0), STEP)
	_check(not slow.is_wall_running(), "a run ends when the player stops")

	# End 5: releasing forward.
	var rel := _beside_wall(2.0, 0.5, 8.0)
	rel.velocity = Vector3(3.0, 0.5, -9.0)
	var rel_motor := _motor(t, _wall_world())
	rel_motor.simulate(rel, _command(1.0, 0.0, 0.0, jump), STEP)
	rel_motor.simulate(rel, _command(0.0, 0.0, 0.0), STEP)
	_check(not rel.is_wall_running(), "a run ends when forward is released")


## Cooldown and cvar checks of the jump-started wall run.
func _wall_run_cooldown_checks(jump: int) -> void:
	# Cooldown: after an end no run starts until it has run down.
	var tcd := _wall_tunables()
	tcd.wall_run_on_jump = true
	tcd.wall_run_cooldown = 0.5
	tcd.wall_jump_enabled = false
	var cd_motor := _motor(tcd, _wall_world())
	var cd := _beside_wall(2.0, 0.5, 8.0)
	cd.velocity = Vector3(3.0, 0.5, -9.0)
	cd_motor.simulate(cd, _command(1.0, 0.0, 0.0, jump), STEP)
	cd_motor.simulate(cd, _command(0.0, 0.0, 0.0), STEP)
	_check(not cd.is_wall_running() and cd.wall_run_cooldown_left > 0.4, "an ended run starts the cooldown",
		"%.2f" % cd.wall_run_cooldown_left)
	var packed := DotFpsNetSync.pack_timers(cd)
	var restored := DotFpsState.new()
	DotFpsNetSync.unpack_timers(restored, packed)
	_check_near(restored.wall_run_cooldown_left, cd.wall_run_cooldown_left, 0.01,
		"and the cooldown rides in the rewind timers")

	# The cvars reach the tunables.
	var cv := DotFpsTunables.new()
	_check(cv.set_cvar("sv_wallrun_onjump", "1") and cv.wall_run_on_jump
		and cv.set_cvar("sv_wallrun_cooldown", "0.7") and absf(cv.wall_run_cooldown - 0.7) < 0.001,
		"sv_wallrun_onjump and sv_wallrun_cooldown set the tunables")


func _test_wall_jump() -> void:
	_section("wall jumping")

	var jump := DotFpsCommand.BUTTON_JUMP

	var off_motor := _motor(_tunables(), _wall_world())
	var off := _beside_wall(9.0, -1.0)
	off_motor.simulate(off, _command(1.0, 0.0, 0.0, jump), STEP)
	_check(off.velocity.x > -0.01 and off.velocity.y < 0.0, "wall jumping is off unless a game turns it on")

	var t := _wall_tunables()
	var motor := _motor(t, _wall_world())

	# Out of a run, looking along it.
	var s := _beside_wall(9.0)
	_run_along(motor, s, 10)
	var along_before := -s.velocity.z
	motor.simulate(s, _command(1.0, 0.0, 0.0, jump), STEP)
	var push := Vector3(s.velocity.x, 0.0, s.velocity.z + along_before)
	_check(motor.wall_jumps == 1 and not s.is_wall_running(), "a jump press during a run jumps off the wall")
	_check(s.velocity.x < -t.wall_jump_push_speed * 0.6, "away from the wall",
		"%.2f m/s along the normal" % -s.velocity.x)
	_check_near(s.velocity.y, t.wall_jump_up_speed, 0.4, "and up at wall_jump_up_speed")
	_check(-s.velocity.z >= along_before - 0.01,
		"keeping every bit of the speed along the wall", "%.2f from %.2f" % [-s.velocity.z, along_before])
	var expected := (Vector3.LEFT * (1.0 - t.wall_jump_look_blend) + Vector3.FORWARD * t.wall_jump_look_blend).normalized()
	_check(push.normalized().dot(expected) > 0.999,
		"the push leans from the normal toward the view by wall_jump_look_blend",
		"%s against %s" % [push.normalized(), expected])

	# Looking into the wall still pushes away from it.
	var facing_motor := _motor(t, _wall_world())
	var facing := _beside_wall(9.0, -1.0)
	facing_motor.simulate(facing, _command(0.0, 0.0, -90.0, jump), STEP)
	_check(facing_motor.wall_jumps == 1 and facing.velocity.x < -t.wall_jump_push_speed * 0.6,
		"a jump while looking into the wall still leaves it", "%.2f" % facing.velocity.x)

	# Touching, not running: a slow player beside the wall can still jump off it.
	var touch_motor := _motor(t, _wall_world())
	var toucher := _beside_wall(2.0, -1.0)
	touch_motor.simulate(toucher, _command(0.0, 0.0, 0.0, jump), STEP)
	_check(touch_motor.wall_jumps == 1, "a wall the player only touches can be jumped off")

	# Per wall: back onto the same wall, the second jump off it is refused.
	var again := _beside_wall(2.0, -1.0)
	again.wall_jump_count = toucher.wall_jump_count
	again.wall_jump_heading = toucher.wall_jump_heading
	again.wall_jumps_in_air = toucher.wall_jumps_in_air
	touch_motor.simulate(again, _command(0.0, 0.0, 0.0, jump), STEP)
	_check(touch_motor.wall_jumps == 1 and again.velocity.x > -0.01,
		"a second jump off the same wall before landing is refused (wall_jump_max_per_wall 1)")

	# The other wall of the corridor is another wall.
	var other := _beside_wall(2.0, -1.0)
	other.position.x = -3.0 + 0.35 + 0.05
	other.wall_jump_count = toucher.wall_jump_count
	other.wall_jump_heading = toucher.wall_jump_heading
	other.wall_jumps_in_air = toucher.wall_jumps_in_air
	touch_motor.simulate(other, _command(0.0, 0.0, 0.0, jump), STEP)
	_check(touch_motor.wall_jumps == 2 and other.velocity.x > t.wall_jump_push_speed * 0.6,
		"while the facing wall can be jumped off", "%.2f" % other.velocity.x)

	_wall_jump_budget()
	_done()


## Per airborne stretch: a budget across every wall, refilled by landing.
func _wall_jump_budget() -> void:
	var jump := DotFpsCommand.BUTTON_JUMP
	var budget := _wall_tunables()
	budget.wall_jump_max_per_wall = 0
	budget.wall_jump_max_per_air = 2
	var budget_motor := _motor(budget, _wall_world())
	var climber := _beside_wall(2.0, -1.0)
	var jumped := 0
	for i in range(3):
		climber.position = Vector3(0.6 if i % 2 == 0 else -2.6, 3.0, -2.0)
		climber.velocity = Vector3(0.0, -1.0, -2.0)
		climber.previous_buttons = 0
		var before := budget_motor.wall_jumps
		budget_motor.simulate(climber, _command(0.0, 0.0, 0.0, jump), STEP)
		jumped += budget_motor.wall_jumps - before
	_check(jumped == 2 and climber.wall_jumps_in_air == 2,
		"wall_jump_max_per_air limits the jumps across walls", "%d jumps" % jumped)
	for _i in range(200):
		budget_motor.simulate(climber, _command(), STEP)
	_check(climber.is_grounded() and climber.wall_jumps_in_air == 0 and climber.wall_jump_count == 0,
		"and landing refills the budget")


## The rewind a predicting client does, in the middle of a wall run.
func _test_wall_replay() -> void:
	_section("wall movement replays")

	var t := _wall_tunables()
	t.wall_slide_speed = 2.0
	var commands: Array[DotFpsCommand] = []
	for i in range(240):
		var buttons := DotFpsCommand.BUTTON_JUMP if i % 45 == 30 else 0
		# Looking a little off along the corridor, so each jump crosses it.
		var yaw := sin(float(i) * 0.07) * 12.0
		commands.append(_command(1.0, sin(float(i) * 0.05) * 0.3, yaw, buttons))

	for rate: float in [STEP, 1.0 / 64.0]:
		var full_motor := _motor(t, _wall_world())
		var full := _beside_wall(9.0)
		var positions: Array[Vector3] = []
		var snapshot: DotFpsState = null
		var split := -1
		for i in range(commands.size()):
			full_motor.simulate(full, commands[i], rate)
			positions.append(full.position)
			if snapshot == null and i >= 50 and full.is_wall_running() and full.wall_jumps_in_air > 0:
				snapshot = full.duplicate_state()
				split = i + 1

		if not _check(snapshot != null and full_motor.wall_runs >= 2 and full_motor.wall_jumps >= 2,
			"the scripted run wall-runs and wall-jumps more than once at %.0f Hz" % (1.0 / rate),
			"%d runs, %d jumps" % [full_motor.wall_runs, full_motor.wall_jumps]):
			continue

		# At the tick rate the wire counts in, the snapshot goes through the flags word, as
		# a client's rewind does. At 60 Hz it is the state itself (the timers quantise).
		var replay := snapshot.duplicate_state()
		if rate != STEP:
			DotFpsNetSync.unpack_flags(replay, DotFpsNetSync.pack_flags(snapshot))
		var replay_motor := _motor(t, _wall_world())
		var same := true
		for i in range(split, commands.size()):
			replay_motor.simulate(replay, commands[i], rate)
			same = same and replay.position == positions[i]
		_check(same and replay.equals(full, 0.0),
			"a rewind mid-run reproduces every position after it at %.0f Hz%s" % [
				1.0 / rate, " through the flags word" if rate != STEP else ""],
			"diverged %.6f m" % replay.divergence(full))

		# The negative control: a rewind that forgets the run and the counters.
		var amnesiac := snapshot.duplicate_state()
		amnesiac.wall_run_time = -1.0
		amnesiac.wall_run_spent = false
		amnesiac.wall_jump_count = 0
		amnesiac.wall_jumps_in_air = 0
		amnesiac.wall_jump_heading = 0
		var amnesiac_motor := _motor(t, _wall_world())
		for i in range(split, commands.size()):
			amnesiac_motor.simulate(amnesiac, commands[i], rate)
		_check(not amnesiac.equals(full, 0.0001),
			"negative control: a rewind that drops the wall fields diverges at %.0f Hz" % (1.0 / rate),
			"diverged %.6f m" % amnesiac.divergence(full))
	_done()


## The rewind a client really does: the snapshot pushed over its CURRENT state, then replayed.
## A player pinned against a wall, holding forward and hopping with auto-hop and coyote time.
func _test_wall_hop_rewind() -> void:
	_section("rewinding a wall-pinned hop restores the jump timers")

	# A deathmatch's movement: classic air control, auto-hop, coyote time and a jump buffer.
	var t := _hop_rewind_tunables()
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, 12.0, 400.0)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var commands: Array[DotFpsCommand] = []
	var jump := false
	var strafe := 0.0
	var next := 0
	for i in range(3000):
		if i >= next:
			next = i + rng.randi_range(18, 72)
			var pick := rng.randi_range(0, 3)
			jump = pick == 2
			strafe = -1.0 if pick == 0 else (1.0 if pick == 1 else 0.0)
		commands.append(_command(1.0, strafe, -90.0 + sin(i * 0.01) * 30.0,
			DotFpsCommand.BUTTON_JUMP if jump else 0))

	var motor := DotFpsMotor.new(t, world)
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.GROUND
	var full: Array[DotFpsState] = []
	for c in commands:
		motor.simulate(s, c, STEP)
		full.append(s.duplicate_state())
	_check(absf(s.position.x - (1.0 - t.radius)) < 0.01, "the run ends pinned against the wall",
		"x %.3f" % s.position.x)

	var plain: Object = _carrier_script().new()
	var timed: Object = _timers_carrier_script().new()
	var counts := []
	for carrier: Object in [timed, plain]:
		var bad := 0
		var worst := 0.0
		for n in range(3 * (commands.size() - 72)):
			var lead: int = [4, 8, 12][n % 3]
			var k := 60 + floori(n / 3.0)
			var replay := full[k + lead].duplicate_state()
			DotFpsNetSync.pull(full[k], carrier)
			DotFpsNetSync.push(carrier, replay)
			var replay_motor := DotFpsMotor.new(t, world)
			for j in range(k + 1, k + lead + 1):
				replay_motor.simulate(replay, commands[j], STEP)
			var e := replay.position.distance_to(full[k + lead].position)
			worst = maxf(worst, e)
			if e > 0.001:
				bad += 1
		counts.append([bad, worst])
	plain.free()
	timed.free()
	_check(counts[0][0] == 0, "every rewind through net_timers lands where the server did",
		"%d diverged, worst %.3f m" % counts[0])
	_check(counts[1][0] > 0, "negative control: a rewind without net_timers diverges",
		"%d diverged, worst %.3f m" % counts[1])
	var back := DotFpsState.new()
	DotFpsNetSync.unpack_timers(back, DotFpsNetSync.pack_timers(DotFpsState.new()))
	var spent := DotFpsState.new()
	spent.time_since_grounded = 1000.5
	DotFpsNetSync.unpack_timers(spent, DotFpsNetSync.pack_timers(spent))
	var zero := DotFpsState.new()
	DotFpsNetSync.unpack_timers(zero, 0)
	_check(back.time_since_grounded == 0.0 and back.time_since_jump == 1000.0
		and spent.time_since_grounded == 1000.0 and zero.time_since_grounded == 1000.0,
		"timers round-trip; long ago and an unsent 0 read as long ago")
	_done()


## A deathmatch's movement with the wall features on.
func _hop_rewind_tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = 9.0
	t.accelerate = 12.0
	t.friction = 5.5
	t.stop_speed = 3.0
	t.air_accelerate = 140.0
	t.max_air_wish_speed = 1.2
	t.gravity = 22.0
	t.jump_height = 1.25
	t.auto_hop = true
	t.coyote_time = 0.08
	t.jump_buffer_time = 0.12
	t.slide_enabled = true
	t.slide_min_speed = 6.5
	t.wall_run_enabled = true
	t.wall_run_min_speed = 9.5
	t.wall_jump_enabled = true
	t.wall_slide_speed = 2.5
	return t


## With every wall feature off the motor makes the same bytes as before they existed: a 600-tick
## run hashed against a stored hash. Failing alone after an engine upgrade means re-capture it.
func _test_walls_off_identical() -> void:
	_section("wall movement off is byte-identical to before it")

	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(2.0, 0.0, -12.0), Vector3(2.0, 0.3, 6.0)))
	world.add_box(AABB(Vector3(-6.0, 0.0, -20.0), Vector3(12.0, 3.0, 1.0)))
	world.add_box(AABB(Vector3(3.0, 0.0, -30.0), Vector3(0.5, 4.0, 30.0)))
	var old_body := _tunables()
	# The stored hash was taken on the old 1.8 / 0.9 / 0.35 m body, so keep that body here.
	old_body.stand_height = 1.8
	old_body.crouch_height = 0.9
	old_body.radius = 0.35
	var motor := _motor(old_body, world)
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.5, 0.0)
	var bytes := PackedByteArray()
	for i in range(600):
		var buttons := 0
		if i % 23 == 0:
			buttons |= DotFpsCommand.BUTTON_JUMP
		if (i / 40) % 3 == 1:
			buttons |= DotFpsCommand.BUTTON_CROUCH
		if (i / 40) % 3 == 2:
			buttons |= DotFpsCommand.BUTTON_SPRINT
		var c := _command(1.0, sin(float(i) * 0.11), sin(float(i) * 0.05) * 70.0 - 30.0, buttons)
		motor.simulate(s, c, STEP)
		bytes.append_array(var_to_bytes([s.position, s.velocity, s.mode, s.time_since_jump, s.time_since_grounded]))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	var digest := ctx.finish().hex_encode()
	_check(digest == "c1b2468664e0a74c72de9c70e7188bd9499eb60f314cd1bc56b0af2763abb81b",
		"600 ticks with every wall setting off hash the same as before wall movement", digest)
	_check(motor.wall_runs == 0 and motor.wall_jumps == 0 and s.wall_normal == Vector3.ZERO,
		"and no wall probe answered anything")
	_done()
