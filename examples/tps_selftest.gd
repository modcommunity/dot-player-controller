extends Node

## Exercises dot-player-controller with a motor driven by hand and a real body.
##
## The motor is a pure function, so the interesting half — coyote time, the jump buffer,
## camera-relative movement, shortest-way-round turning — is checkable as arithmetic and
## is checked exhaustively. The controller and the camera rig are exercised against a
## real [CharacterBody3D] in a real tree, because a spring arm is not a value.
##
## [codeblock]
## godot --headless --path . res://examples/tps_selftest.tscn
## [/codeblock]

const SECTIONS := 7
const CHECKS := 100

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-player-controller self-test")
	_line("")

	_test_tunables()
	_test_state()
	_test_movement()
	_test_jumping()
	_test_turning()
	_test_look()
	await _test_controller()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _intent(move: Vector2 = Vector2.ZERO, buttons: int = 0) -> DotPlayerIntent:
	var i := DotPlayerIntent.make(move, buttons, 0)
	i.diff_from(0)
	return i


# --- Tunables ---------------------------------------------------------------

func _test_tunables() -> void:
	_section("tunables")

	var t := DotTpsTunables.new()
	_check(t.validate().ok, "the defaults validate")
	_check(t.jump_speed() > 0.0, "and the jump height converts to a launch speed")
	_check(
		is_equal_approx(t.speed_for(true, false), t.run_speed),
		"the speed depends on what is held"
	)
	_check(is_equal_approx(t.speed_for(true, true), t.crouch_speed), "crouch wins over run")

	var slow := DotTpsTunables.new()
	slow.gravity = 5.0
	_check(
		slow.jump_speed() < t.jump_speed(),
		"lower gravity needs less launch speed for the same height, which is what "
		+ "keeps a jump honest when gravity is retuned"
	)

	var backwards := DotTpsTunables.new()
	backwards.run_speed = 1.0
	_check(not backwards.validate().ok, "running slower than walking is refused")

	var inverted := DotTpsTunables.new()
	inverted.pitch_min = 80.0
	_check(not inverted.validate().ok, "and an inverted pitch range")

	var wrong_aim := DotTpsTunables.new()
	wrong_aim.aim_distance = 20.0
	_check(
		not wrong_aim.validate().ok,
		"and an aim distance further than the resting one — aiming would push the "
		+ "camera away, which is the opposite of what the button was pressed for"
	)

	_check(DotTpsTunables.shooter().turn_mode == 1, "the shooter preset locks to the camera")
	_check(DotTpsTunables.adventure().turn_mode == 0, "the adventure one turns to face movement")
	_check(DotTpsTunables.platformer().air_jumps == 1, "the platformer has a double jump")
	_check(DotTpsTunables.presets().size() == 3, "three presets")
	_check(DotTpsTunables.preset(&"shooter") != null, "resolving by name")
	_check(DotTpsTunables.preset(&"nope") == null, "and nothing otherwise")

	# The smoothing, which is the thing everybody writes wrong.
	var slow_frame := DotTpsTunables.smoothing(10.0, 1.0 / 30.0)
	var fast_frame := DotTpsTunables.smoothing(10.0, 1.0 / 120.0)
	_check(slow_frame > fast_frame, "a longer frame moves further towards the target")

	var by_thirty := 1.0
	for i in range(30):
		by_thirty *= (1.0 - DotTpsTunables.smoothing(10.0, 1.0 / 30.0))

	var by_one_twenty := 1.0
	for i in range(120):
		by_one_twenty *= (1.0 - DotTpsTunables.smoothing(10.0, 1.0 / 120.0))

	_check(
		absf(by_thirty - by_one_twenty) < 0.01,
		"and a second of smoothing converges to the same place at 30 and at 120 frames "
		+ "per second — which lerp(a, b, rate * delta) does not, and which is why the "
		+ "camera behaves differently on two machines when it is written that way"
	)
	_check(is_equal_approx(DotTpsTunables.smoothing(0.0, 0.016), 1.0), "a rate of zero is rigid")
	_check(t.env_prefix() == "DOT_TPS_", "and the config layers the family's way")


func _test_state() -> void:
	_section("state")

	var s := DotTpsState.new()
	_check(s.on_floor, "a fresh state is on the ground")
	_check(
		s.jump_buffered < 0.0,
		"with no jump buffered — negative rather than zero, because zero means "
		+ "'pressed this very tick' and that is the commonest case there is"
	)
	_check(s.shoulder == 1, "and the camera over the right shoulder")

	s.velocity = Vector3(3, 5, 4)
	_check(is_equal_approx(s.speed(), 5.0), "speed is the planar speed, not including the fall")

	var copy := s.copy_state()
	copy.velocity = Vector3.ZERO
	_check(not s.velocity.is_zero_approx(), "a copy is a copy")

	var adopted := DotTpsState.new()
	adopted.adopt(s)
	_check(adopted.velocity.is_equal_approx(s.velocity), "and a state can be adopted")
	adopted.adopt(null)
	_check(adopted.velocity.is_equal_approx(s.velocity), "adopting nothing changes nothing")

	s.forget_state()
	_check(s.velocity.is_zero_approx(), "and everything can be put back for a respawn")
	_check(s.describe().contains("grounded"), "and it describes itself")


# --- Movement ---------------------------------------------------------------

func _test_movement() -> void:
	_section("movement")

	var t := DotTpsTunables.new()
	var s := DotTpsState.new()

	var v := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 0.1, true)
	_check(v.z < 0.0, "forward intent moves forward")
	_check(
		absf(v.x) < 0.001,
		"and not sideways, because the camera is facing down -Z"
	)

	s.forget_state()
	s.yaw = PI * 0.5
	var turned := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 0.1, true)
	_check(
		turned.x < 0.0,
		"and with the camera turned a quarter, forward is a different direction — "
		+ "movement is camera-relative, because a character whose forward is its own "
		+ "facing turns in circles the moment the camera moves"
	)

	s.forget_state()
	for i in range(60):
		var _v := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 1.0 / 60.0, true)
	_check(
		is_equal_approx(s.speed(), t.walk_speed) or absf(s.speed() - t.walk_speed) < 0.05,
		"a second of holding forward reaches walking speed (%.2f)" % s.speed()
	)

	for i in range(60):
		var _v := DotTpsMotor.step(
			s, _intent(Vector2(0, 1), DotPlayerIntent.Btn.SPRINT), t, 1.0 / 60.0, true
		)
	_check(s.speed() > t.walk_speed + 1.0, "and sprinting gets faster")
	_check(s.running, "with the state saying so")

	for i in range(60):
		var _v := DotTpsMotor.step(
			s, _intent(Vector2(0, 1), DotPlayerIntent.Btn.CROUCH), t, 1.0 / 60.0, true
		)
	_check(s.speed() < t.walk_speed, "and crouching gets slower")
	_check(s.crouched, "with the state saying so too")

	for i in range(120):
		var _v := DotTpsMotor.step(s, _intent(), t, 1.0 / 60.0, true)
	_check(s.speed() < 0.01, "letting go stops")

	s.forget_state()
	var diagonal := DotTpsMotor.step(s, _intent(Vector2(1, 1)), t, 1.0, true)
	_check(
		Vector2(diagonal.x, diagonal.z).length() <= t.walk_speed + 0.01,
		"and a diagonal is not faster than a straight line, because the intent is "
		+ "clamped to a unit length rather than trusted"
	)

	s.forget_state()
	s.on_floor = false
	s.air_time = 999.0
	var before_air := s.speed()
	for i in range(10):
		var _v := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 1.0 / 60.0, false)
	var air_gain := s.speed() - before_air

	s.forget_state()
	for i in range(10):
		var _v := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 1.0 / 60.0, true)
	var ground_gain := s.speed()

	_check(
		air_gain > 0.0 and air_gain < ground_gain,
		"air control is real but reduced (%.2f against %.2f) — zero makes a missed "
		% [air_gain, ground_gain] + "jump unrecoverable and reads as the controls "
		+ "having stopped working; full makes the jump arc meaningless"
	)

	s.forget_state()
	s.on_floor = true
	var _grounded := DotTpsMotor.step(s, _intent(), t, 0.1, true)
	_check(
		s.velocity.y < 0.0,
		"a grounded character is pressed downward, so walking down a ramp does not "
		+ "leave the floor every tick and fill the animation machine with tiny falls"
	)

	var nothing := DotTpsMotor.step(null, _intent(), t, 0.1, true)
	_check(nothing.is_zero_approx(), "stepping nothing does nothing")


func _test_jumping() -> void:
	_section("jumping")

	var t := DotTpsTunables.new()
	var s := DotTpsState.new()

	var pressed := _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP)
	var _v := DotTpsMotor.step(s, pressed, t, 1.0 / 60.0, true)
	_check(s.velocity.y > 0.0, "pressing jump on the ground jumps")
	_check(not s.on_floor, "and leaves the ground")

	var height := s.velocity.y
	var again := _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP)
	again.diff_from(DotPlayerIntent.Btn.JUMP)
	var _v2 := DotTpsMotor.step(s, again, t, 1.0 / 60.0, false)
	_check(
		s.velocity.y < height,
		"and holding it does not jump again — the buffered press is cleared and the "
		+ "coyote window closed, or the character occasionally leaps twice as high"
	)

	# Coyote time.
	s.forget_state()
	var _walk := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 1.0 / 60.0, true)
	var _step_off := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 0.05, false)
	_check(
		s.on_floor,
		"a character that has just walked off a ledge is still 'on the floor' for "
		+ "jumping purposes"
	)

	var late := _intent(Vector2(0, 1), DotPlayerIntent.Btn.JUMP)
	var _late := DotTpsMotor.step(s, late, t, 1.0 / 60.0, false)
	_check(
		s.velocity.y > 0.0,
		"so a jump pressed one frame late still works — twelve lines that turn 'the "
		+ "jump is unreliable' into 'the jump is forgiving'"
	)

	s.forget_state()
	var _off := DotTpsMotor.step(s, _intent(), t, 0.5, false)
	_check(not s.on_floor, "but a character that has been falling for half a second is not")
	var _too_late := DotTpsMotor.step(
		s, _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP), t, 1.0 / 60.0, false
	)
	_check(s.velocity.y < 0.0, "and their jump does nothing")

	# The buffer.
	s.forget_state()
	s.on_floor = false
	s.air_time = 999.0
	var early := _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP)
	var _early := DotTpsMotor.step(s, early, t, 1.0 / 60.0, false)
	_check(s.jump_buffered >= 0.0, "a jump pressed in the air is remembered")
	_check(s.velocity.y < 0.0, "and does nothing yet")

	var _land := DotTpsMotor.step(s, _intent(), t, 1.0 / 60.0, true)
	_check(
		s.velocity.y > 0.0,
		"and fires on landing — the other half of the same problem, from the other side"
	)

	s.forget_state()
	s.on_floor = false
	s.air_time = 999.0
	var _stale := DotTpsMotor.step(
		s, _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP), t, 1.0 / 60.0, false
	)
	var _wait := DotTpsMotor.step(s, _intent(), t, 1.0, false)
	_check(s.jump_buffered < 0.0, "a buffered jump expires")
	var _landed := DotTpsMotor.step(s, _intent(), t, 1.0 / 60.0, true)
	_check(
		s.velocity.y < 0.0,
		"and does not fire a second later, which would be a jump the player never asked for"
	)

	# Air jumps.
	var double := DotTpsTunables.platformer()
	var d := DotTpsState.new()
	var _first := DotTpsMotor.step(
		d, _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP), double, 1.0 / 60.0, true
	)
	var _fall := DotTpsMotor.step(d, _intent(), double, 0.8, false)
	_check(d.velocity.y < 0.0, "a platformer character falls after its first jump")

	var second := _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP)
	var _second := DotTpsMotor.step(d, second, double, 1.0 / 60.0, false)
	_check(d.velocity.y > 0.0, "and can jump again in the air")
	_check(d.air_jumps_used == 1, "once")

	var third := _intent(Vector2.ZERO, DotPlayerIntent.Btn.JUMP)
	var _drop := DotTpsMotor.step(d, _intent(), double, 0.8, false)
	var _third := DotTpsMotor.step(d, third, double, 1.0 / 60.0, false)
	_check(d.velocity.y < 0.0, "and not twice")

	var _ground := DotTpsMotor.step(d, _intent(), double, 1.0 / 60.0, true)
	_check(d.air_jumps_used == 0, "landing gives it back")


func _test_turning() -> void:
	_section("turning")

	var t := DotTpsTunables.new()
	t.turn_mode = 0
	var s := DotTpsState.new()

	for i in range(120):
		var _v := DotTpsMotor.step(s, _intent(Vector2(0, 1)), t, 1.0 / 60.0, true)

	_check(
		absf(wrapf(s.facing - 0.0, -PI, PI)) < 0.1,
		"walking forward with the camera at zero faces the character forward (%.2f)"
		% s.facing
	)

	for i in range(120):
		var _v := DotTpsMotor.step(s, _intent(Vector2(1, 0)), t, 1.0 / 60.0, true)
	_check(
		absf(wrapf(s.facing - (-PI * 0.5), -PI, PI)) < 0.15,
		"and walking right turns it right (%.2f)" % s.facing
	)

	# Shortest way round.
	s.forget_state()
	s.facing = PI - 0.1
	s.target_facing = -PI + 0.1
	var before := s.facing
	for i in range(3):
		var _v := DotTpsMotor.step(s, _intent(), t, 1.0 / 60.0, true)
	_check(
		absf(wrapf(s.facing - before, -PI, PI)) < 0.5,
		"turning from just under PI to just over goes the short way round, not 350 "
		+ "degrees the other way"
	)

	# Camera lock.
	var locked := DotTpsTunables.shooter()
	var l := DotTpsState.new()
	l.yaw = 1.0
	for i in range(120):
		var _v := DotTpsMotor.step(l, _intent(Vector2(1, 0)), locked, 1.0 / 60.0, true)
	_check(
		absf(wrapf(l.facing - 1.0, -PI, PI)) < 0.1,
		"in camera-locked mode the body faces the camera regardless of which way it is "
		+ "strafing, which is what makes strafing possible at all"
	)

	var aiming := DotTpsState.new()
	aiming.yaw = -1.0
	for i in range(120):
		var _v := DotTpsMotor.step(
			aiming, _intent(Vector2(1, 0), DotPlayerIntent.Btn.ZOOM), t, 1.0 / 60.0, true
		)
	_check(
		absf(wrapf(aiming.facing - (-1.0), -PI, PI)) < 0.1,
		"and aiming forces the same lock even in turn-to-face mode, because a "
		+ "character aiming at something must be facing it or the crosshair and the "
		+ "muzzle point in different directions"
	)


func _test_look() -> void:
	_section("looking")

	var t := DotTpsTunables.new()
	var s := DotTpsState.new()

	DotTpsMotor.look(s, Vector2(0.5, 0.0), t)
	_check(s.yaw < 0.0, "a rightward mouse movement turns the camera")

	DotTpsMotor.look(s, Vector2(100.0, 0.0), t)
	_check(s.yaw >= -PI and s.yaw <= PI, "and yaw wraps rather than accumulating")

	DotTpsMotor.look(s, Vector2(0.0, 100.0), t)
	_check(
		is_equal_approx(s.pitch, t.pitch_min_radians()),
		"while pitch clamps to the tunables' range"
	)

	DotTpsMotor.look(s, Vector2(0.0, -1000.0), t)
	_check(is_equal_approx(s.pitch, t.pitch_max_radians()), "at the other end too")

	DotTpsMotor.look(null, Vector2.ONE, t)
	_check(true, "and looking with no state does nothing rather than erroring")

	var sensitive := DotTpsState.new()
	DotTpsMotor.look(sensitive, Vector2(0.1, 0.0), t, 2.0)
	var half := DotTpsState.new()
	DotTpsMotor.look(half, Vector2(0.1, 0.0), t, 1.0)
	_check(absf(sensitive.yaw) > absf(half.yaw), "and sensitivity scales the delta")


# --- The controller ---------------------------------------------------------

func _test_controller() -> void:
	_section("the controller")

	var roster := DotPlayerRoster.new()
	roster.register_service = false
	add_child(roster)
	var _j := roster.join("ada", "Ada", 1, 0)

	var player := DotPlayer.new()
	player.roster_ref = DotNodeRef.of_path(roster.get_path())
	player.is_local = true
	add_child(player)

	var body := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.35
	shape.shape = capsule
	body.add_child(shape)
	player.add_child(body)

	var controller := DotTpsController.new()
	controller.tunables = DotTpsTunables.new()
	player.add_child(controller)
	player.player_key = "ada"

	await get_tree().process_frame

	_check(controller.is_bound(), "the controller binds to its player")
	_check(controller.controller_id == &"tp", "and names itself for a switch")
	_check(controller.character_body() == body, "and finds the body")
	_check(not controller.is_active(), "and starts idle")

	controller.activate()
	await get_tree().process_frame
	_check(controller.is_active(), "activating takes over")
	_check(controller.rig != null, "and builds a camera rig for a local player")
	_check(controller.rig.arm != null, "with a spring arm")
	_check(controller.rig.camera != null, "and a camera")

	var grounded_events: Array = []
	controller.grounded_changed.connect(func(on: bool) -> void: grounded_events.append(on))

	for i in range(10):
		controller.simulate(_intent(Vector2(0, 1)), 1.0 / 60.0)
		await get_tree().physics_frame

	_check(controller.speed() > 0.0, "driving moves the player")
	_check(
		body.global_position.z < 0.0,
		"forwards, in the world (%.2f)" % body.global_position.z
	)

	var motion := controller.motion()
	_check(motion.has("speed") and motion.has("on_floor"),
		"and it offers the motion description an animation driver wants, without the "
		+ "driver needing to know this controller exists")

	controller.place(Transform3D(Basis.IDENTITY, Vector3(20, 0, 20)))
	_check(body.global_position.is_equal_approx(Vector3(20, 0, 20)), "a teleport moves it")
	_check(controller.velocity().is_zero_approx(), "and stops it")
	_check(
		is_zero_approx(controller.state.facing),
		"and the facing follows the transform, so the model does not keep the heading "
		+ "it had before it was moved"
	)

	# The handover, which is what makes having two controllers worth anything.
	var state := controller.handover_state()
	_check(state.has("transform") and state.has("yaw"), "it offers a handover state")

	controller.adopt_state({
		"transform": Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)),
		"velocity": Vector3(0, 5, 0),
		"yaw": 1.0,
		"pitch": -0.2,
	})
	_check(body.global_position.is_equal_approx(Vector3(1, 2, 3)), "and adopts one")
	_check(controller.velocity().is_equal_approx(Vector3(0, 5, 0)), "with the velocity")
	_check(is_equal_approx(controller.state.yaw, 1.0), "and the camera angles")

	controller.adopt_state({"yaw": 0.0, "pitch": -99.0})
	_check(
		controller.state.pitch >= controller.tunables.pitch_min_radians(),
		"and an absurd pitch from a handover is clamped rather than trusted"
	)

	_check(
		controller.eye_transform().origin != body.global_position,
		"the eye transform is the camera, not the head — in third person the player's "
		+ "viewpoint is nowhere near their character, and a trace from the head would "
		+ "point somewhere they are not looking"
	)

	# The camera rig's own behaviour.
	var rig := controller.rig
	var before_shoulder := rig.pivot.position.x
	rig.swap_shoulder(controller.state)
	rig.follow(controller.state, Vector3.ZERO, 1.0)
	_check(
		signf(rig.pivot.position.x) != signf(before_shoulder) or is_zero_approx(before_shoulder),
		"the shoulder can be swapped"
	)
	_check(
		controller.state.shoulder == -1,
		"and it lives on the state, so a rewind does not undo a choice the player made"
	)

	controller.state.aiming = true
	for i in range(60):
		rig.follow(controller.state, Vector3.ZERO, 1.0 / 60.0)
	_check(
		rig.arm.spring_length < controller.tunables.camera_distance,
		"aiming pulls the camera in"
	)
	controller.state.aiming = false
	for i in range(120):
		rig.follow(controller.state, Vector3.ZERO, 1.0 / 60.0)
	_check(
		is_equal_approx(rig.arm.spring_length, controller.tunables.camera_distance)
		or absf(rig.arm.spring_length - controller.tunables.camera_distance) < 0.05,
		"and letting go puts it back"
	)

	_check(rig.aim_point(10.0) != rig.camera_transform().origin, "the rig offers an aim point")
	_check(rig.describe_lines().size() == 1, "and describes itself")
	_check(controller.describe_lines().size() >= 3, "and so does the controller")

	controller.deactivate()
	_check(not controller.is_active(), "and it hands back")

	# A sampler, which reads no input in a headless run and must still be safe.
	var sampler := DotTpsSampler.new()
	add_child(sampler)
	var sampled := sampler.sample(7, 1.0 / 60.0)
	_check(sampled != null and sampled.tick == 7, "a sampler produces an intent")
	_check(sampled.is_idle(), "an idle one, with no input to read")
	sampler.discard_pending()
	_check(
		sampler.missing_actions().size() > 0,
		"and reports the input actions this project has not defined rather than "
		+ "pushing an engine error per action per tick"
	)
	_check(sampler.describe_lines().size() == 1, "and describes itself")

	player.queue_free()
	roster.queue_free()
	sampler.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
