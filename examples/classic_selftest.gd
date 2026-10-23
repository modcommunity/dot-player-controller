extends Node

## The classic competitive-shooter profile measured against closed forms of its reference
## numbers (all in source units, 0.01905 m each): friction 4, stop speed 75, accelerate 5,
## air accelerate 10, air wish cap 30, gravity 800, run 250, jump apex 57. A feel judgement is
## not made here; the numbers a player's hands are trained on are.

const STEP := 1.0 / 60.0
const U := 0.01905
const CHECKS := 39
const SECTIONS := 7

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("dot-player-controller classic profile self-test")
	_test_profiles()
	_test_cvars()
	_test_ground()
	_test_jump()
	_test_strafe_jump()
	_test_hops()
	_test_water_ladder()
	print("%d passed, %d failed" % [_passed, _failed])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered, %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [what, detail])


func _near(value: float, expected: float, tol: float, what: String) -> void:
	_check(absf(value - expected) <= tol, what, "got %.4f expected %.4f +-%.4f" % [value, expected, tol])


func _motor(t: DotFpsTunables) -> DotFpsMotor:
	return DotFpsMotor.new(t, DotFpsFlatBody.with_floor(0.0))


func _standing(motor: DotFpsMotor, height: float = 0.0, mode := DotFpsState.Mode.GROUND) -> DotFpsState:
	var s := DotFpsState.new()
	s.position = Vector3(0.0, height, 0.0)
	s.mode = mode
	for _i in range(4):
		motor.simulate(s, DotFpsCommand.new(), STEP)
	return s


func _cmd(forward: float = 0.0, yaw: float = 0.0, buttons: int = 0) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, forward)
	c.yaw = yaw
	c.buttons = buttons
	return c


func _test_profiles() -> void:
	_section("profiles")
	var fresh := DotFpsTunables.new()
	var classic := DotFpsTunables.with_profile("classic")
	var legacy := DotFpsTunables.with_profile("legacy")
	_check(fresh.fingerprint() == classic.fingerprint(), "the defaults are the classic profile")
	_check(fresh.fingerprint() != legacy.fingerprint(), "the legacy profile is a different set")
	_near(legacy.max_speed, 7.0, 1e-6, "legacy keeps the old 7 m/s run")
	_near(legacy.jump_height, 1.1, 1e-6, "legacy keeps the old jump")
	_check(not fresh.apply_profile("nonsense").ok, "an unknown profile is refused")
	_check(fresh.validate().ok, "the classic set validates")
	_done()


func _test_cvars() -> void:
	_section("cvars in source units")
	var t := DotFpsTunables.new()
	_check(t.set_cvar("sv_gravity", "800"), "sv_gravity accepts 800")
	_near(t.gravity, 800.0 * U, 1e-4, "800 units/s^2 is 15.24 m/s^2")
	_check(t.set_cvar("sv_stepsize", "18") and absf(t.step_height - 18.0 * U) < 1e-4, "sv_stepsize 18 is 0.343 m")
	_check(t.set_cvar("sv_autohop", "1") and t.auto_hop, "sv_autohop turns auto-hop on")
	_check(not t.set_cvar("sv_gravity", "fast") and not t.set_cvar("sv_nothing", "1"), "a bad value or name is refused")
	_check(t.set_cvar("sv_movement_profile", "legacy") and t.accelerate == 10.0, "the profile cvar swaps the set")
	var specs := DotFpsTunables.new().cvar_specs()
	var seen := {}
	for spec in specs:
		seen[spec["name"]] = spec["value"]
	_near(float(seen["sv_friction"]), 4.0, 1e-3, "the cvar list reports friction 4")
	_near(float(seen["sv_gravity"]), 800.0, 0.01, "and gravity 800 units")
	_near(float(seen["sv_stopspeed"]), 75.0, 0.01, "and stop speed 75 units")
	_done()


func _test_ground() -> void:
	_section("ground: top speed and stopping")
	var t := DotFpsTunables.new()
	var motor := _motor(t)
	var s := _standing(motor)
	for _i in range(120):
		motor.simulate(s, _cmd(1.0), STEP)
	_near(s.horizontal_speed(), 250.0 * U, 0.01, "top speed is the 250 unit run speed")
	var start := s.position
	var ticks := 0
	while s.horizontal_speed() > 0.001 and ticks < 300:
		motor.simulate(s, _cmd(), STEP)
		ticks += 1
	var v0 := 250.0 * U
	var stop := 75.0 * U
	# Friction is applied before the move, so the first tick already moves at the slowed speed.
	var expected := (v0 - stop * 0.5) / 4.0 - v0 * STEP
	_near(start.distance_to(s.position), expected, expected * 0.03, "stopping distance is (v - stop/2) / friction less one tick")
	_check(ticks < 100, "friction brings the player to rest", "took %d ticks" % ticks)
	# Time to run speed from rest: acceleration adds accel * wish * dt per tick, less friction.
	var s2 := _standing(motor)
	var n := 0
	while s2.horizontal_speed() < v0 - 0.001 and n < 300:
		motor.simulate(s2, _cmd(1.0), STEP)
		n += 1
	var ref_v := 0.0
	var ref_n := 0
	while ref_v < v0 - 0.001 and ref_n < 300:
		ref_v -= maxf(ref_v, stop) * 4.0 * STEP if ref_v > 0.0 else 0.0
		ref_v = maxf(ref_v, 0.0)
		ref_v += minf(5.0 * v0 * STEP, v0 - ref_v)
		ref_n += 1
	_check(absi(n - ref_n) <= 1, "ticks to run speed match the recurrence", "%d vs %d" % [n, ref_n])
	_done()


func _test_jump() -> void:
	_section("jump apex")
	var t := DotFpsTunables.new()
	var motor := _motor(t)
	var s := _standing(motor)
	var peak := 0.0
	var apex_tick := 0
	for i in range(120):
		motor.simulate(s, _cmd(0.0, 0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0), STEP)
		if s.position.y > peak:
			peak = s.position.y
			apex_tick = i
	_near(peak / U, 57.0, 3.0, "apex is about 57 units")
	var v := sqrt(2.0 * t.gravity * 57.0 * U)
	_near(float(apex_tick + 1) * STEP, v / t.gravity, 2.5 * STEP, "time to apex is v / g")
	_near(peak, v * v / (2.0 * t.gravity), 0.06, "apex is v^2 / 2g within half a tick")
	_check(s.is_grounded(), "and the player lands again")
	_done()


func _test_strafe_jump() -> void:
	_section("air strafe gain")
	var t := DotFpsTunables.new()
	var motor := _motor(t)
	var s := _standing(motor, 200.0, DotFpsState.Mode.AIR)
	s.velocity = Vector3(0.0, 0.0, -250.0 * U)
	var v0 := s.velocity.length()
	var cap := 30.0 * U
	for n in range(1, 61):
		# Aim the wish a quarter turn off the current heading, the best case for the gain.
		var heading := Vector2(s.velocity.x, s.velocity.z).normalized()
		var perp := Vector2(-heading.y, heading.x)
		var yaw := atan2(-perp.x, -perp.y)
		motor.simulate(s, _cmd(1.0, rad_to_deg(yaw)), STEP)
		if n == 20 or n == 60:
			var expected := sqrt(v0 * v0 + float(n) * cap * cap)
			_near(s.horizontal_speed(), expected, expected * 0.015, "after %d perpendicular ticks speed is sqrt(v0^2 + n cap^2)" % n)
	var plain := _standing(motor, 200.0, DotFpsState.Mode.AIR)
	plain.velocity = Vector3(0.0, 0.0, -250.0 * U)
	for _i in range(60):
		motor.simulate(plain, _cmd(1.0, 0.0), STEP)
	_near(plain.horizontal_speed(), v0, 0.01, "holding forward alone adds nothing in the air")
	_check(s.horizontal_speed() > v0 * 1.3, "so strafing gains well over 30 percent in a second")
	_done()


func _test_water_ladder() -> void:
	_section("water and ladder cvars")
	var swim := DotFpsSwimMode.new()
	_check(swim.set_cvar("sv_wateraccelerate", "10") and swim.accelerate == 10.0, "sv_wateraccelerate sets the water acceleration")
	_check(swim.set_cvar("sv_waterfriction", "1") and swim.friction == 1.0, "sv_waterfriction sets the water friction")
	_check(not swim.set_cvar("sv_waterfriction", "x") and not swim.set_cvar("sv_gravity", "1"), "a bad water value or name is refused")
	_check(swim.cvar_specs().size() == 2, "two water cvars are listed")
	var ladder := DotFpsLadderMode.new()
	_check(ladder.set_cvar("sv_ladder_dampen", "0.5") and ladder.dampen == 0.5, "sv_ladder_dampen sets the dampening")
	_check(not ladder.set_cvar("sv_ladder_dampen", "x") and not ladder.set_cvar("sv_x", "1"), "a bad ladder value or name is refused")
	_check(DotFpsLadderMode.new().dampen == 0.0 and DotFpsSwimMode.new().friction == 0.0, "both default to off, as before")
	_check(ladder.cvar_specs()[0]["name"] == "sv_ladder_dampen", "the ladder cvar is listed")
	_done()


func _test_hops() -> void:
	_section("bunny hops")
	var t := DotFpsTunables.new()
	var motor := _motor(t)
	var s := _standing(motor)
	s.velocity = Vector3(0.0, 0.0, -10.0)
	motor.simulate(s, _cmd(1.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)
	_check(s.horizontal_speed() > 9.5, "a jump at twice run speed is not capped", "%.2f" % s.horizontal_speed())
	for auto in [false, true]:
		var tt := DotFpsTunables.new()
		tt.auto_hop = auto
		var m := _motor(tt)
		var st := _standing(m)
		var takeoffs := 0
		var was_ground := true
		for _i in range(240):
			m.simulate(st, _cmd(0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)
			if was_ground and not st.is_grounded():
				takeoffs += 1
			was_ground = st.is_grounded()
		if auto:
			_check(takeoffs >= 3, "auto-hop re-jumps while jump is held", "%d takeoffs" % takeoffs)
		else:
			_check(takeoffs == 1, "without auto-hop a held jump is one jump", "%d takeoffs" % takeoffs)
	var legacy_buffer := DotFpsTunables.with_profile("legacy")
	_check(legacy_buffer.jump_buffer_time > 0.0 and DotFpsTunables.new().jump_buffer_time == 0.0, "the classic jump has no buffer, legacy keeps one")
	_done()


func _done() -> void:
	_completed += 1
