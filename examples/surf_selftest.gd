extends Node

## Proves the things a surf or bhop timer depends on.
##
## [codeblock]
## godot --headless --path . res://examples/surf_selftest.tscn
## [/codeblock]
##
## The movement self-test already covers strafe acceleration, air-strafing and the
## collision backend. This one covers what a movement-game server adds on top, and
## every check here is a property somebody would notice on the first map:
##
## - a ramp too steep to stand on does not ground the player, so air control keeps
##   working all the way down it — that IS surf, and if the ground check accepted the
##   ramp the player would walk down it at walking pace;
## - a player sliding into a seam between two ramps comes out the other side rather
##   than stopping dead. This is [method DotFpsMotor._resolve_planes] and it is the
##   single most important thing in this file;
## - hopping preserves speed with the cap off and cannot with it on;
## - a style is a pure transform of the tunables and of the command.
##
## Run against [DotFpsFlatBody], because every one of those is a property of the
## motor and against analytic geometry a failure has one possible cause.

const STEP := 1.0 / 128.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("dot-fps-controller surf and bunny-hop self-test")
	print("")

	_test_ramp_is_not_ground()
	_test_surf_keeps_speed()
	_test_surf_gains_speed_from_strafing()
	_test_crease_does_not_stop_a_surfer()
	_test_bhop_preserves_speed()
	_test_bhop_cap_removes_it()
	_test_perfect_jump_counting()
	_test_sync_measurement()
	_test_style_transform()
	_test_style_command_filter()
	_test_style_round_trip()
	_test_edge_friction()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Helpers ---------------------------------------------------------------

func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()
	# A bhop/surf server's values, not the shooter defaults: hold to hop, no landing
	# cap, and enough air acceleration for strafing to pay.
	t.auto_hop = true
	t.bhop_speed_cap_scale = 0.0
	t.max_speed = 7.0
	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	t.gravity = 20.0
	t.friction = 6.0
	t.max_slope_angle = 46.0
	return t


func _command(x: float, y: float, yaw: float, jump: bool = false) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(x, y)
	c.yaw = yaw
	c.set_button(DotFpsCommand.BUTTON_JUMP, jump)
	return c


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon,
		what,
		"%.4f vs %.4f" % [value, expected]
	)


# --- Surf ------------------------------------------------------------------

## A world with one surf ramp descending toward -Z through the origin.
##
## Returned with the ramp's index so a test can ask [method DotFpsFlatBody.ramp_height]
## where the surface is rather than re-deriving it — the sign of a ramp's tilt is
## exactly the thing that is easy to get backwards, and a test that gets it backwards
## puts its player twenty metres under the map and then reports that surf does not
## work.
func _surf_world(angle: float) -> DotFpsFlatBody:
	var body := DotFpsFlatBody.new()
	body.floor_y = -500.0
	body.add_ramp(Vector3.ZERO, Vector3.FORWARD, angle)
	return body


## A state placed [param above] metres clear of the ramp at [param z].
##
## [b]Clear of the surface, not above the point under the feet.[/b] The capsule
## touches a 60° face well before its feet reach the surface height directly below
## them — about a metre before, for the shipped collider — so "0.2 above" placed
## naively starts the player deeply embedded. That is not a hypothetical: the first
## version of this file did it, and every surf test then measured what the motor does
## to a player inside a wall.
func _on_ramp(body: DotFpsFlatBody, z: float, above: float) -> DotFpsState:
	var t := _tunables()
	var normal := body.planes[0].normal

	# How far the capsule reaches toward the face from its centre, and what that is
	# worth in vertical clearance.
	var support := (
		t.radius * absf(normal.x)
		+ t.stand_height * 0.5 * absf(normal.y)
		+ t.radius * absf(normal.z)
	)
	var clearance := support / absf(normal.y) - t.stand_height * 0.5

	var s := DotFpsState.new()
	s.position = Vector3(
		0.0,
		body.ramp_height(0, Vector3(0.0, 0.0, z)) + clearance + above,
		z
	)
	s.mode = DotFpsState.Mode.AIR
	return s


func _test_ramp_is_not_ground() -> void:
	print("a ramp is not ground")

	# 60° — well past the 46° the tunables allow anybody to stand on.
	var body := _surf_world(60.0)
	var motor := DotFpsMotor.new(_tunables(), body)

	var s := _on_ramp(body, 6.0, 3.0)

	for _i in range(256):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(
		not s.is_grounded(),
		"a player on a 60° face is never grounded",
		"mode %s" % DotFpsState.mode_name(s.mode)
	)
	_check(
		s.horizontal_speed() > 1.0,
		"and slides down it rather than standing on it",
		"%.2f m/s horizontal" % s.horizontal_speed()
	)
	_check(
		s.position.z < 5.0,
		"downhill, which for this ramp is -Z",
		"z = %.2f" % s.position.z
	)

	# The control: the same face at 30° IS ground, so this is a test of the angle and
	# not of planes-are-never-ground.
	var walkable := _surf_world(30.0)
	var motor2 := DotFpsMotor.new(_tunables(), walkable)
	var s2 := _on_ramp(walkable, 6.0, 3.0)

	for _i in range(256):
		motor2.simulate(s2, DotFpsCommand.new(), STEP)

	_check(s2.is_grounded(), "while a 30° face is ordinary ground")


func _test_surf_keeps_speed() -> void:
	print("surfing preserves speed")

	var body := _surf_world(60.0)
	var motor := DotFpsMotor.new(_tunables(), body)

	var s := _on_ramp(body, 10.0, 0.2)
	# Already moving down the slope: this is a player a few seconds into a ramp.
	s.velocity = Vector3(0.0, -17.3, -10.0)

	var entry := s.horizontal_speed()

	for _i in range(128):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	# Gravity's along-slope component is g·sin(60°) ≈ 17 m/s², so a second on the
	# ramp should ADD speed rather than cost it. A collide-and-slide that clipped the
	# velocity wrongly would take it instead, which is what this measures.
	_check(
		s.horizontal_speed() > entry,
		"a second on a ramp with no input gains speed rather than losing it",
		"%.2f -> %.2f m/s" % [entry, s.horizontal_speed()]
	)
	_check(
		not s.is_grounded(),
		"and the player is still surfing at the end of it"
	)
	_check(
		motor.stuck_ticks == 0,
		"and the slide never runs out of iterations",
		"%d stuck ticks" % motor.stuck_ticks
	)


func _test_surf_gains_speed_from_strafing() -> void:
	print("surfing gains speed from strafing")

	var body := _surf_world(60.0)

	# Hold right and turn right: the classic strafe. The wish direction stays nearly
	# perpendicular to the velocity, so the projection never reaches the air cap and
	# the full increment goes in every tick.
	var strafed := _run_ramp(body, true)
	var straight := _run_ramp(body, false)

	_check(
		strafed > straight,
		"a strafing surfer outruns one who only turns the view",
		"%.2f vs %.2f m/s" % [strafed, straight]
	)


## Runs 200 ticks down the ramp, turning throughout, and returns the speed reached.
func _run_ramp(body: DotFpsFlatBody, strafe: bool) -> float:
	var motor := DotFpsMotor.new(_tunables(), body)

	var s := _on_ramp(body, 10.0, 0.2)
	s.velocity = Vector3(0.0, -8.66, -5.0)

	var yaw := 0.0

	for _i in range(200):
		yaw -= 0.35
		motor.simulate(s, _command(1.0 if strafe else 0.0, 0.0, yaw), STEP)

	return s.horizontal_speed()


func _test_crease_does_not_stop_a_surfer() -> void:
	print("a seam between two ramps")

	# Two ramps falling toward each other along X, meeting in a valley that runs
	# along Z. A player sliding down the valley is in permanent contact with both.
	# This is the shape every surf map is made of and the shape a sequential
	# collide-and-slide stops dead in.
	var body := DotFpsFlatBody.new()
	body.floor_y = -500.0
	body.add_ramp(Vector3(-1.5, 0.0, 0.0), Vector3.RIGHT, 55.0)
	body.add_ramp(Vector3(1.5, 0.0, 0.0), Vector3.LEFT, 55.0)

	var with_crease := _tunables()
	with_crease.crease_slide = true

	var motor := DotFpsMotor.new(with_crease, body)

	var s := DotFpsState.new()
	s.position = Vector3(0.0, 4.0, 12.0)
	s.mode = DotFpsState.Mode.AIR
	s.velocity = Vector3(0.0, 0.0, -16.0)

	var start_z := s.position.z

	for _i in range(200):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	var travelled := start_z - s.position.z

	_check(
		travelled > 12.0,
		"a surfer wedged in the seam keeps travelling along it",
		"%.2f m in 200 ticks" % travelled
	)
	_check(
		s.horizontal_speed() > 8.0,
		"with most of their speed intact",
		"%.2f m/s" % s.horizontal_speed()
	)

	# The negative control, and the reason the flag exists: the same run with the
	# plane list off is measurably worse. A test whose fix cannot be switched off is
	# not evidence that the fix did anything.
	var without := _tunables()
	without.crease_slide = false

	var motor2 := DotFpsMotor.new(without, body)

	var s2 := DotFpsState.new()
	s2.position = Vector3(0.0, 4.0, 12.0)
	s2.mode = DotFpsState.Mode.AIR
	s2.velocity = Vector3(0.0, 0.0, -16.0)

	for _i in range(200):
		motor2.simulate(s2, DotFpsCommand.new(), STEP)

	var travelled2 := start_z - s2.position.z

	_check(
		travelled >= travelled2,
		"and does at least as well as the plain sequential slide",
		"%.2f m with, %.2f m without" % [travelled, travelled2]
	)


# --- Bunny-hopping ---------------------------------------------------------

func _test_bhop_preserves_speed() -> void:
	print("bunny-hopping")

	var body := DotFpsFlatBody.with_floor(0.0)
	var t := _tunables()
	var motor := DotFpsMotor.new(t, body)

	var s := DotFpsState.new()
	s.position = Vector3.ZERO
	s.velocity = Vector3(0.0, 0.0, -14.0)
	s.mode = DotFpsState.Mode.GROUND

	# Jump held the whole time, which is what auto_hop means. Two hundred ticks is
	# several hops at this height.
	for _i in range(200):
		motor.simulate(s, _command(0.0, 0.0, 0.0, true), STEP)

	_check(
		s.horizontal_speed() > 12.0,
		"holding jump keeps speed the ground friction would have taken",
		"%.2f m/s" % s.horizontal_speed()
	)

	# The control: the same run without the jump key loses it all to friction.
	var s2 := DotFpsState.new()
	s2.velocity = Vector3(0.0, 0.0, -14.0)
	s2.mode = DotFpsState.Mode.GROUND

	var motor2 := DotFpsMotor.new(t, body)

	for _i in range(200):
		motor2.simulate(s2, DotFpsCommand.new(), STEP)

	_check(
		s2.horizontal_speed() < 1.0,
		"while standing on it does not",
		"%.2f m/s" % s2.horizontal_speed()
	)


func _test_bhop_cap_removes_it() -> void:
	print("the landing cap")

	var body := DotFpsFlatBody.with_floor(0.0)

	var capped := _tunables()
	capped.bhop_speed_cap_scale = 1.104

	var motor := DotFpsMotor.new(capped, body)

	var s := DotFpsState.new()
	s.velocity = Vector3(0.0, 0.0, -14.0)
	s.mode = DotFpsState.Mode.GROUND

	for _i in range(200):
		motor.simulate(s, _command(0.0, 0.0, 0.0, true), STEP)

	_check(
		s.horizontal_speed() <= capped.max_speed * 1.104 + 0.01,
		"a capped server clamps a hop to 1.104 x max_speed",
		"%.2f m/s, cap %.2f" % [
			s.horizontal_speed(), capped.max_speed * 1.104
		]
	)


func _test_perfect_jump_counting() -> void:
	print("perfect-hop statistics")

	var body := DotFpsFlatBody.with_floor(0.0)
	var motor := DotFpsMotor.new(_tunables(), body)
	var stats := DotFpsStats.new()

	var s := DotFpsState.new()
	s.velocity = Vector3(0.0, 0.0, -10.0)
	s.mode = DotFpsState.Mode.GROUND

	var previous: DotFpsCommand = null

	# 800 ticks at 128 Hz is 6.25 s, and one hop at this jump height and gravity is
	# 0.66 s of air time — so this is nine or ten hops, not a boundary case.
	for _i in range(800):
		var c := _command(0.0, 0.0, 0.0, true)
		motor.simulate(s, c, STEP)
		stats.observe(s, c, previous, STEP)
		previous = c

	_check(stats.jumps >= 8, "auto-hop produces a run of jumps", "%d" % stats.jumps)
	_check(
		stats.perfect_jumps == stats.measured_jumps,
		"and holding the key makes every one of them perfect",
		"%d/%d" % [stats.perfect_jumps, stats.measured_jumps]
	)
	_check_near(stats.perfect_ratio(), 1.0, 0.0001, "so the ratio is 1")

	# A standing jump every second is the opposite: the player sat on the ground for
	# a hundred ticks first, so it is not a hop attempt at all and must not be
	# counted against them.
	var stats2 := DotFpsStats.new()
	var s2 := DotFpsState.new()
	s2.mode = DotFpsState.Mode.GROUND

	var previous2: DotFpsCommand = null

	for i in range(600):
		var c := _command(0.0, 0.0, 0.0, i % 100 == 0)
		motor.simulate(s2, c, STEP)
		stats2.observe(s2, c, previous2, STEP)
		previous2 = c

	_check(stats2.jumps > 0, "a standing jump is still a jump", "%d" % stats2.jumps)
	_check(
		stats2.measured_jumps == 0,
		"but is not measured as a hop attempt",
		"%d measured" % stats2.measured_jumps
	)
	_check_near(
		stats2.perfect_ratio(), 0.0, 0.0001,
		"so the perfect ratio reports nothing rather than a failure"
	)


func _test_sync_measurement() -> void:
	print("strafe synchronisation")

	var body := DotFpsFlatBody.new()
	body.floor_y = -500.0

	var motor := DotFpsMotor.new(_tunables(), body)
	var stats := DotFpsStats.new()

	var s := DotFpsState.new()
	s.position = Vector3(0.0, 100.0, 0.0)
	s.mode = DotFpsState.Mode.AIR
	s.velocity = Vector3(0.0, 0.0, -10.0)

	var yaw := 0.0
	var previous: DotFpsCommand = null

	# Right strafe, turning right. Godot's yaw increases counter-clockwise about +Y,
	# so turning right is yaw DECREASING — the sign of this loop is the whole test.
	for _i in range(200):
		yaw -= 0.3
		var c := _command(1.0, 0.0, yaw)
		motor.simulate(s, c, STEP)
		stats.observe(s, c, previous, STEP)
		previous = c

	_check_near(stats.sync(), 1.0, 0.02, "strafing with the turn is fully in sync")

	var stats2 := DotFpsStats.new()
	var s2 := DotFpsState.new()
	s2.position = Vector3(0.0, 100.0, 0.0)
	s2.mode = DotFpsState.Mode.AIR
	s2.velocity = Vector3(0.0, 0.0, -10.0)

	var yaw2 := 0.0
	var previous2: DotFpsCommand = null

	for _i in range(200):
		yaw2 += 0.3
		var c := _command(1.0, 0.0, yaw2)
		motor.simulate(s2, c, STEP)
		stats2.observe(s2, c, previous2, STEP)
		previous2 = c

	_check_near(stats2.sync(), 0.0, 0.02, "and against it is fully out of sync")
	_check(
		s.horizontal_speed() > s2.horizontal_speed(),
		"which is not a cosmetic number: the in-sync run is faster",
		"%.2f vs %.2f m/s" % [s.horizontal_speed(), s2.horizontal_speed()]
	)


# --- Styles ----------------------------------------------------------------

func _test_style_transform() -> void:
	print("styles transform the tunables")

	var base := _tunables()
	base.gravity = 20.0
	base.max_speed = 7.0

	var low := DotFpsStyle.new()
	low.id = &"low_gravity"
	low.gravity_scale = 0.5

	var derived := low.apply_to(base)

	_check_near(derived.gravity, 10.0, 0.0001, "a gravity scale halves gravity")
	_check_near(base.gravity, 20.0, 0.0001, "and the base is not modified")

	# Applying twice from the base must give the same answer as applying once. The
	# controller derives from a stored base for exactly this reason: deriving from
	# the previous result compounds, and a player who switched to low gravity and
	# back lands in a quarter of it.
	var twice := low.apply_to(low.apply_to(base))
	_check_near(twice.gravity, 5.0, 0.0001, "applying to a derived set compounds")
	_check_near(
		low.apply_to(base).gravity, 10.0, 0.0001,
		"which is why apply_to always takes the base"
	)

	var fast := DotFpsStyle.new()
	fast.speed_scale = 40.0
	var fast_tunables := fast.apply_to(base)

	_check(
		fast_tunables.validate().ok,
		"a style that outruns the velocity backstop lifts it rather than being refused"
	)

	var hard := DotFpsStyle.new()
	hard.easy_bhop = DotFpsStyle.Toggle.OFF
	_check_near(
		hard.apply_to(base).jump_buffer_time, 0.0, 0.0001,
		"turning easy-bhop off removes the jump buffer entirely"
	)


func _test_style_command_filter() -> void:
	print("styles filter the command")

	var sideways := DotFpsStyle.new()
	sideways.key_preset = DotFpsStyle.KeyPreset.SIDEWAYS

	var c := _command(0.7, 0.7, 0.0)
	sideways.filter_command(c)

	_check_near(c.move.y, 0.0, 0.0001, "sideways removes the forward key")
	_check_near(c.move.x, 0.7, 0.0001, "and leaves the strafe")

	# Idempotent, because a prediction replay runs it again over stored commands.
	sideways.filter_command(c)
	_check_near(c.move.x, 0.7, 0.0001, "filtering twice changes nothing")

	var half := DotFpsStyle.new()
	half.key_preset = DotFpsStyle.KeyPreset.HALF_SIDEWAYS
	half.one_strafe_key_only = true

	var c2 := _command(0.7, 0.7, 0.0)
	half.filter_command(c2)

	_check_near(c2.move.x, 0.7, 0.0001, "half-sideways keeps the strafe")
	_check_near(
		c2.move.y, 0.0, 0.0001,
		"and one-key-only drops the forward half of the diagonal, not the strafe"
	)

	var backwards := DotFpsStyle.new()
	backwards.key_preset = DotFpsStyle.KeyPreset.BACKWARDS

	var c3 := _command(0.5, -1.0, 0.0)
	backwards.filter_command(c3)

	_check_near(c3.move.y, -1.0, 0.0001, "backwards keeps the back key")
	_check_near(c3.move.x, 0.0, 0.0001, "and removes the strafes")

	var no_crouch := DotFpsStyle.new()
	no_crouch.block_crouch = true

	var c4 := _command(0.0, 1.0, 0.0)
	c4.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	no_crouch.filter_command(c4)

	_check(
		not c4.is_pressed(DotFpsCommand.BUTTON_CROUCH),
		"a style that blocks crouch clears the button"
	)


func _test_style_round_trip() -> void:
	print("styles survive serialisation")

	for style in DotFpsStyle.defaults():
		var back := DotFpsStyle.from_dictionary(style.to_dictionary())
		_check(
			back.fingerprint() == style.fingerprint(),
			"%s round-trips through a dictionary" % style.display_name,
			"%s vs %s" % [back.fingerprint(), style.fingerprint()]
		)

	# Untrusted input: an out-of-range enum from a config file or a peer must land on
	# a member that exists, not on a number every match falls through.
	var junk := DotFpsStyle.from_dictionary({
		"id": "junk", "key_preset": 99, "auto_hop": -4
	})

	_check(
		junk.key_preset == DotFpsStyle.KeyPreset.FREE,
		"an out-of-range key preset falls back to FREE"
	)
	_check(
		junk.auto_hop == DotFpsStyle.Toggle.INHERIT,
		"and an out-of-range toggle to INHERIT"
	)

	var ids := {}
	for style in DotFpsStyle.defaults():
		_check(not ids.has(style.id), "%s has a unique id" % style.display_name)
		ids[style.id] = true


func _test_edge_friction() -> void:
	print("edge friction")

	# A single block with nothing beyond it. A player sliding toward the drop passes
	# over the edge partway through the run.
	var body := DotFpsFlatBody.new()
	body.floor_y = -500.0
	body.add_box(AABB(Vector3(-4.0, -1.0, -4.0), Vector3(8.0, 1.0, 8.0)))

	var plain := _tunables()
	plain.edge_friction = 1.0

	var edged := _tunables()
	edged.edge_friction = 4.0
	edged.edge_friction_reach = 0.6

	var slid_plain := _slide_to_edge(body, plain)
	var slid_edged := _slide_to_edge(body, edged)

	_check(
		slid_edged < slid_plain,
		"a player skidding at a ledge stops shorter with edge friction on",
		"%.3f m vs %.3f m" % [slid_edged, slid_plain]
	)


## Runs a player toward the lip of the block and returns how far they got.
func _slide_to_edge(body: DotFpsBody, t: DotFpsTunables) -> float:
	var motor := DotFpsMotor.new(t, body)

	# Started next to the lip, not across the block: edge friction can only change a
	# run in which the player is actually near an edge, and the first version of this
	# test skidded to a halt three metres short of one and measured nothing.
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.0, -3.2)
	s.velocity = Vector3(0.0, 0.0, -9.0)
	s.mode = DotFpsState.Mode.GROUND

	var start := s.position.z

	for _i in range(120):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	return start - s.position.z
