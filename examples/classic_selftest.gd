extends Node

## The classic competitive-shooter profile measured against closed forms of its reference
## numbers (all in source units, 0.01905 m each): friction 4, stop speed 75, accelerate 5,
## air accelerate 10, air wish cap 30, gravity 800, run 250, jump apex 57. A feel judgement is
## not made here; the numbers a player's hands are trained on are.

const STEP := 1.0 / 60.0
const U := 0.01905
const CHECKS := 59
const SECTIONS := 10

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
	_test_steps()
	_test_crouch_jump()
	_test_water_ladder()
	_test_cvar_binding()
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


func _run_into_box(box_height_units: float) -> Vector2:
	var t := DotFpsTunables.new()
	var body := DotFpsFlatBody.with_floor(0.0)
	body.add_box(AABB(Vector3(-2.0, 0.0, -30.0), Vector3(4.0, box_height_units * U, 30.0)))
	var motor := DotFpsMotor.new(t, body)
	var s := _standing(motor, 0.0)
	s.position.z = 1.0
	for _i in range(120):
		motor.simulate(s, _cmd(1.0, 0.0), STEP)
	return Vector2(s.position.y, s.position.z)


func _test_steps() -> void:
	_section("step handling (sv_stepsize 18)")
	var up := _run_into_box(18.0)
	_check(up.x > 17.0 * U and up.x < 18.5 * U and up.y < -0.5, "an 18 unit step is climbed and stood on", "y %.3f z %.2f" % [up.x, up.y])
	var wall := _run_into_box(19.0)
	_check(wall.x < 0.01 and wall.y > 0.0, "a 19 unit kerb is a wall", "y %.3f z %.2f" % [wall.x, wall.y])
	var low := DotFpsTunables.new()
	_check(low.set_cvar("sv_stepsize", "30") and absf(low.step_height - 30.0 * U) < 1e-4, "sv_stepsize reshapes the limit")
	_done()


func _crouch_jump_peak(crouch_in_air: bool, crouch_time: float) -> float:
	var t := DotFpsTunables.new()
	t.crouch_transition_time = crouch_time
	var motor := _motor(t)
	var s := _standing(motor)
	var peak := 0.0
	for i in range(120):
		var buttons := DotFpsCommand.BUTTON_JUMP if i == 0 else 0
		if crouch_in_air and i >= 3:
			buttons |= DotFpsCommand.BUTTON_CROUCH
		motor.simulate(s, _cmd(0.0, 0.0, buttons), STEP)
		peak = maxf(peak, s.position.y)
	return peak


func _test_crouch_jump() -> void:
	_section("crouch-jump and duck timing")
	var t := DotFpsTunables.new()
	var plain := _crouch_jump_peak(false, t.crouch_transition_time)
	var ducked := _crouch_jump_peak(true, t.crouch_transition_time)
	_near(ducked - plain, t.stand_height - t.crouch_height, 0.05, "a crouch in the air lifts the feet by the hull difference")
	_check(ducked > 57.0 * U + 0.5, "so a crouch-jump clears a ledge a standing jump cannot")
	var slow := _crouch_jump_peak(true, 0.4)
	_near(slow - plain, t.stand_height - t.crouch_height, 0.05, "the air duck is instant whatever the duck time")
	_check(t.set_cvar("sv_ducktime", "0.4") and t.crouch_transition_time == 0.4, "sv_ducktime sets the duck time")
	_check(t.set_cvar("sv_airduck", "0") and not t.instant_air_crouch, "sv_airduck switches the air duck off")
	var off := DotFpsTunables.new()
	off.instant_air_crouch = false
	off.crouch_transition_time = 0.4
	var m := _motor(off)
	var s := _standing(m)
	m.simulate(s, _cmd(0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)
	m.simulate(s, _cmd(0.0, 0.0, DotFpsCommand.BUTTON_CROUCH), STEP)
	_check(s.crouch_fraction < 0.5, "with the air duck off a crouch in the air is gradual", "%.2f" % s.crouch_fraction)
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


func _test_cvar_binding() -> void:
	_section("cvar binding: console, cfg layer, per-map override")
	var t := DotFpsTunables.new()
	var swim := DotFpsSwimMode.new()
	var ladder := DotFpsLadderMode.new()
	var cvars := DotFpsCvars.new().add_target(t).add_target(swim).add_target(ladder).add_target(RefCounted.new())
	_check(cvars.targets.size() == 3, "an object without the two methods is not a target")
	var made := {}
	var add := func(cvar_name: String, value: String, _d: String, _f: int) -> Object:
		var cv := FakeCvar.new()
		# A cfg or argv value, held before registration.
		cv.value = "600" if cvar_name == "sv_gravity" else value
		made[cvar_name] = cv
		return cv
	var heard: Array = []
	cvars.applied.connect(func(n: String, _v: String) -> void: heard.append(n))
	var _bound := cvars.bind_cvars(add)
	_check(made.has("sv_gravity") and made.has("sv_waterfriction") and made.has("sv_ladder_dampen") and made.has("sv_movement_profile"), "tunables, water and ladder cvars are all registered")
	_near(t.gravity, 600.0 * U, 1e-4, "a cfg value held before binding is applied (layered config)")
	_check(not heard.has("sv_friction"), "a default read back is not re-applied")
	made["sv_airaccelerate"].set_value("1000")
	_near(t.air_accelerate, 1000.0, 1e-3, "a cvar change reaches the tunables")
	made["sv_waterfriction"].set_value("3")
	made["sv_ladder_dampen"].set_value("0.5")
	_check(swim.friction == 3.0 and ladder.dampen == 0.5, "and the water and ladder modes")
	var keys := cvars.map_config_keys()
	_check(keys.has("sv_gravity") and not keys.has("sv_movement_profile") and keys["sv_autohop"]["type"] == "bool", "the map whitelist lists numeric cvars, bools as bool, not the profile")
	_check(cvars.map_config_keys(PackedStringArray(["sv_gravity"]), {"sv_friction": {"max": 9.0}}).has("sv_gravity") == false, "a game can exclude keys and tighten limits")
	# What DotGameMapConfig does: remember, set, then put back through the same cvar.
	var cv: FakeCvar = made["sv_gravity"]
	var before := cv.value
	cv.set_value("200")
	_near(t.gravity, 200.0 * U, 1e-4, "a per-map override reaches the tunables")
	cv.set_value(before)
	_near(t.gravity, 600.0 * U, 1e-4, "and putting it back restores them")
	_check(not cvars.set_cvar("sv_nothing", "1"), "an unknown cvar is refused")
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


class FakeCvar:
	extends RefCounted
	signal changed(old_value: String, new_value: String)
	var value := ""
	func get_string() -> String:
		return value
	func set_value(v: String) -> void:
		var old := value
		value = v
		changed.emit(old, v)


func _done() -> void:
	_completed += 1
