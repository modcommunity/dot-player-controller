extends "res://examples/surf_physics_selftest_base.gd"

## Surf, against the physics server the games actually run on.
##
## [codeblock]
## godot --headless --path . res://examples/surf_physics_selftest.tscn
## [/codeblock]
##
## [b]Why this exists when surf_selftest already covers surf.[/b] That suite runs
## against [DotFpsFlatBody], deliberately and for good reasons — analytic geometry,
## one possible cause per failure, no scene, no physics step. It proved every surf
## property this motor has and it was all true, and a player on a real map still sank
## through the ramp, because the bug was never in the motor. It was in the one
## component that suite replaces: a swept query against Godot's physics server does
## not see a collider the capsule is already touching, so from first contact onward
## the ramp did not exist.
##
## A suite that substitutes the component under suspicion cannot see a bug in it. So
## this file builds real [StaticBody3D] geometry and runs the same motor against
## [DotFpsPhysicsBody] — and every check here is one that passed in the analytic
## suite while the game was visibly broken.
##
## Cheap to state, expensive to learn: [b]penetration is the measurement, not
## speed.[/b] A player sinking through a ramp still has plausible speed, plausible
## position and a clean [member DotFpsMotor.stuck_ticks]. What they do not have is
## clearance, and nothing but a geometric test of the capsule against the face they
## are on can tell you so.

const CHECKS := 46

## Sections entered against sections that ran to their last line, and against this: a
## runtime error aborts a section silently. CHECKS is the other half (docs/testing.md).
const SECTIONS := 11


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	_t = _tunables()
	print("dot-player-controller surf self-test, against the physics server")
	print("")

	await _test_rest_contact_sees_what_a_sweep_cannot()
	await _test_a_surfer_stays_on_the_ramp()
	await _test_an_embedded_spawn_recovers()
	await _test_a_standing_player_is_left_alone()
	await _test_leaving_a_surface_is_not_blocked()
	await _test_a_surfer_leaves_a_face_over_its_far_end()
	await _test_a_reversed_rest_normal_is_turned_round()
	await _test_a_body_falls_out_of_an_acute_corner()
	await _test_a_simulator_is_the_motor()
	await _test_a_surfer_rides_the_crease_of_two_slabs()
	await _test_static_world_changes_no_result()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- The query the whole bug lived in --------------------------------------

func _test_rest_contact_sees_what_a_sweep_cannot() -> void:
	_section("a resting query sees a surface the sweep has stopped reporting")

	await _clear()
	_add_ramp(60.0)
	await _settle()

	var normal := _normal_for(60.0)
	var body := DotFpsPhysicsBody.for_node(self)
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)

	# Clear of the face, the sweep is correct and needs no help.
	var clear_centre := normal * (support + 0.03)
	var swept := body.sweep(clear_centre, -normal * 0.06, _t.stand_height, _t.radius)
	_check(swept.hit, "a capsule 3 cm clear of a ramp is seen by a sweep")
	_check(
		swept.normal.dot(normal) > 0.99,
		"and the sweep reports the ramp's own normal",
		"%v" % swept.normal
	)

	# Touching or inside, it is not — this is the engine behaviour being worked around.
	var depths: PackedFloat64Array = [0.001, 0.02, 0.2]
	for depth in depths:
		var centre := normal * (support - depth)
		var rest := body.rest_contact(centre, _t.stand_height, _t.radius)
		_check(
			rest.hit and rest.normal.dot(normal) > 0.99,
			"a capsule %.0f mm inside the ramp still resolves the ramp" % (depth * 1000.0),
			"hit=%s n=%v" % [rest.hit, rest.normal]
		)
		_check(
			absf(rest.depth - depth) < 0.002,
			"and reports how deep it is, to the millimetre",
			"%.4f vs %.4f" % [rest.depth, depth]
		)

	# And the sweep now refuses to report free space where the capsule is buried.
	var buried := normal * (support - 0.05)
	var blocked := body.sweep(buried, -normal * 0.04, _t.stand_height, _t.radius)
	_check(
		blocked.hit and blocked.normal.dot(normal) > 0.99,
		"a sweep driving further into a ramp it is inside is blocked, not free",
		"hit=%s n=%v" % [blocked.hit, blocked.normal]
	)
	_done()


# --- The symptom -----------------------------------------------------------

func _test_a_surfer_stays_on_the_ramp() -> void:
	_section("a surfer stays on the ramp rather than inside it")

	await _clear()
	_add_ramp(60.0)
	await _settle()

	var normal := _normal_for(60.0)
	var motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))
	var s := _on_ramp(normal, 6.0, 0.05)
	s.velocity = Vector3(6.0, 0.0, 0.0)

	var worst := 0.0

	for _i in range(256):
		motor.simulate(s, DotFpsCommand.new(), STEP)
		worst = maxf(worst, _penetration(s.position, normal))

	# The number that matters. Before the resting query this reached 0.83 m in 96
	# ticks and was still growing — the player was a third of the way through the
	# ramp and accelerating, with every motor counter reading zero.
	_check(
		worst < 0.02,
		"never sinks more than 2 cm into a 60° face over 256 ticks",
		"worst %.4f m" % worst
	)
	_check(
		not s.is_grounded(),
		"is never grounded on it, which is what makes it surf",
		"mode %s" % DotFpsState.mode_name(s.mode)
	)
	_check(
		s.horizontal_speed() > 8.0,
		"and gains speed down it",
		"%.2f m/s" % s.horizontal_speed()
	)

	# A shallow face is a hill: walkable, and it must not be pushed off.
	await _clear()
	_add_ramp(20.0)
	await _settle()

	var hill := _normal_for(20.0)
	var hill_motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))
	var h := _on_ramp(hill, 4.0, 0.05)

	for _i in range(192):
		hill_motor.simulate(h, DotFpsCommand.new(), STEP)

	_check(
		h.is_grounded(),
		"a 20° face is still ground and still stands a player up",
		"mode %s" % DotFpsState.mode_name(h.mode)
	)
	_check(
		_penetration(h.position, hill) < 0.02,
		"without sinking into it either",
		"%.4f m" % _penetration(h.position, hill)
	)
	_done()


func _test_an_embedded_spawn_recovers() -> void:
	_section("a player who starts inside geometry gets out")

	await _clear()
	_add_ramp(60.0)
	await _settle()

	var normal := _normal_for(60.0)
	var motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))

	# Spawned 20 cm inside the ramp — a spawn point placed a little generously, or a
	# prediction correction landing in solid. Before the push this was terminal: the
	# sweep saw nothing, so nothing stopped them and nothing moved them out.
	var s := _on_ramp(normal, 6.0, -0.2)
	_check(
		_penetration(s.position, normal) > 0.15,
		"starts genuinely embedded, so the test is testing something",
		"%.3f m" % _penetration(s.position, normal)
	)

	for _i in range(64):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(
		_penetration(s.position, normal) < 0.02,
		"is clear of the face within 64 ticks",
		"%.4f m" % _penetration(s.position, normal)
	)
	_check(
		motor.depenetrated_ticks > 0,
		"and says so, rather than recovering silently",
		"%d ticks" % motor.depenetrated_ticks
	)
	_done()


func _test_a_standing_player_is_left_alone() -> void:
	_section("a player on a floor is not pushed around by the recovery")

	await _clear()
	_add_floor(0.0)
	await _settle()

	var motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.5, 0.0)
	s.mode = DotFpsState.Mode.AIR

	for _i in range(128):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	var settled := s.position.y

	for _i in range(256):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.is_grounded(), "stands on the floor", "mode %s" % DotFpsState.mode_name(s.mode))
	_check(
		absf(s.position.y - settled) < 0.002,
		"and does not creep up or down over 256 further ticks",
		"%.5f m of drift" % absf(s.position.y - settled)
	)
	_check(
		absf(s.position.y) < 0.02,
		"resting at the floor's height rather than above or below it",
		"y %.4f" % s.position.y
	)
	# The recovery must be idle here: a floor a player is standing on is a resting
	# contact at zero depth, and pushing on that would lift everybody off the ground.
	_check(
		motor.depenetrated_ticks < 8,
		"the recovery stays out of the way of ordinary standing",
		"%d of 384 ticks" % motor.depenetrated_ticks
	)
	_done()


func _test_leaving_a_surface_is_not_blocked() -> void:
	_section("a capsule inside a surface may still move away from it")

	await _clear()
	_add_ramp(60.0)
	await _settle()

	var normal := _normal_for(60.0)
	var body := DotFpsPhysicsBody.for_node(self)
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	var buried := normal * (support - 0.05)

	# Outward: nothing is in the way, and reporting the surface behind would pin a
	# player against the thing they are escaping.
	var out := body.sweep(buried, normal * 0.04, _t.stand_height, _t.radius)
	_check(
		not out.hit,
		"moving out along the normal is not blocked by the surface behind it",
		"fraction %.3f n=%v" % [out.fraction, out.normal]
	)

	# Inward: blocked, as the surfing case needs.
	var into := body.sweep(buried, -normal * 0.04, _t.stand_height, _t.radius)
	_check(into.hit, "moving further in is blocked")

	# Along it: the motion that surf is made of. Must not be stopped dead.
	var along := normal.cross(Vector3.RIGHT).normalized()
	var slide := body.sweep(buried, along * 0.04, _t.stand_height, _t.radius)
	_check(
		not slide.hit,
		"and sliding along the face is not blocked either",
		"fraction %.3f" % slide.fraction
	)
	_done()


# --- The far end of a face (`[fps-face-edge-stop]`) -------------------------

func _test_a_surfer_leaves_a_face_over_its_far_end() -> void:
	_section("a surfer leaving a rolled, pitched face over its far end keeps its speed")

	# Three rides that each stopped DEAD on the edge tick: cast_motion grazed the edge
	# between the slab's top and end faces, no rest query along the motion could name a
	# surface the motion was leaving, and sweep answered with the motion's reverse --
	# which the slide clips the velocity against, to exactly zero. 93 of 800 rides in a
	# sweep over pitch, line, speed and a second face did it.
	var rides: Array[Vector3] = [
		Vector3(7.0, 0.0, 28.0), Vector3(5.0, 0.0, 36.0), Vector3(5.0, 6.0, 28.0),
	]
	var worst := 0.0
	var slowest := INF
	var detail := PackedStringArray()
	for ride in rides:
		var r: Vector2 = await _ride_off_the_end(ride.x, ride.y, ride.z)
		worst = maxf(worst, r.x)
		slowest = minf(slowest, r.y if r.y >= 0.0 else -1.0)
		detail.append("pitch %.0f x %.0f %.0f m/s: lost %.0f%%, %.1f m/s past" % [
			ride.x, ride.y, ride.z, r.x * 100.0, r.y])

	_check(
		worst < 0.1,
		"no tick of three rides off the far end costs a tenth of the speed",
		"; ".join(detail)
	)
	_check(
		slowest > 20.0,
		"and every rider is still past 20 m/s 2 m beyond the edge",
		"; ".join(detail)
	)
	_done()


# --- A rest normal pointing into the face ([ramp-pop-1]) -------------------

func _test_a_reversed_rest_normal_is_turned_round() -> void:
	_section("a rest normal reported into the face is turned round, and nobody is pushed through")

	await _clear()
	# A thin slab, the shape an imported ramp brush is: Godot's resting query reverses
	# the normal for some capsules resting on it (game-g2gfast surf_mesa, 2026-10-08).
	var r := deg_to_rad(52.0)
	var normal := _normal_for(52.0)
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.5, 20.0)
	cs.shape = box
	sb.add_child(cs)
	sb.transform = Transform3D(Basis.from_euler(Vector3(-r, 0.0, 0.0)), -normal * 0.25)
	add_child(sb)
	await _settle()

	var body := DotFpsPhysicsBody.for_node(self)
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	var raw_reversed := 0
	var reported_reversed := 0
	var worst := 0.0
	for centre in _resting_on_slab(normal, support):
		var raw := body._raw_rest_contact(centre, _t.stand_height, _t.radius)
		if raw.hit and raw.normal.dot(normal) < 0.0:
			raw_reversed += 1
		var rest := body.rest_contact(centre, _t.stand_height, _t.radius)
		if rest.hit and rest.normal.dot(normal) < 0.0:
			reported_reversed += 1
			worst = maxf(worst, rest.depth)

	# The guard on the guard: if the engine stops doing it, this section proves nothing.
	_check(raw_reversed > 0, "the engine still reverses some resting normals on this slab",
		"%d" % raw_reversed)
	_check(reported_reversed == 0, "rest_contact reports none of them reversed",
		"%d reversed, deepest %.3f m" % [reported_reversed, worst])

	# The motor's view: a capsule resting on the face is never moved INTO it. Before the
	# fix _depenetrate pushed these a full step through the slab.
	var motor := DotFpsMotor.new(_t, body)
	var deepest := -INF
	for centre in _resting_on_slab(normal, support):
		var s := DotFpsState.new()
		s.position = centre - Vector3.UP * (_t.stand_height * 0.5)
		s.mode = DotFpsState.Mode.AIR
		motor._depenetrate(s, _t.stand_height)
		deepest = maxf(deepest, _penetration(s.position, normal))
	_check(deepest < 0.001, "depenetration never pushes a resting capsule into the face",
		"%.3f m past it" % deepest)
	_done()


# --- An acute corner: a wall and an open door's panel (`[hns-door-wedge-1]`) ---------

func _test_a_body_falls_out_of_an_acute_corner() -> void:
	_section("a body hopping into the corner of a wall and an open door comes down")

	await _clear()
	_add_wall_and_open_door()
	await _settle()

	var t := _tunables()
	t.radius = 0.35
	t.stand_height = 1.8
	t.step_height = 0.4
	var motor := DotFpsMotor.new(t, DotFpsPhysicsBody.for_node(self))

	# Where the bot froze, moved to this wall: touching the wall's face to 15 micrometres and
	# the panel to under a millimetre, at the top of an unstick hop, still pushing at the panel.
	# Before the fix: the slide met the wall face at fraction ~0 twice, called it a duplicate
	# plane, and the leg off it ran into the panel, so the move stopped every tick with the
	# fall speed kept: hanging at 0.6 m for the rest of the round.
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.AIR
	s.position = Vector3(-0.4742, 0.6136, 0.350015)
	s.velocity = Vector3(1.2, -4.47, 0.0)
	var body := DotFpsPhysicsBody.for_node(self)
	var centre := s.position + Vector3.UP * (t.stand_height * 0.5)
	var down := body.sweep(centre, Vector3(0.0, -0.15, 0.0), t.stand_height, t.radius)
	var rest := body.rest_contact(centre, t.stand_height, t.radius)
	_check(not down.hit and rest.hit and absf(rest.normal.z - 1.0) < 1e-3,
		"the capsule is placed as the bot was: free straight down, resting on the wall's face",
		"down %s, rest %s n=%v" % [down.hit, rest.hit, rest.normal])

	# The query the bug was in: a push at the panel, beside the wall, names the WALL, a face
	# square to the motion. If the engine ever names the panel here, this setup no longer
	# reproduces the hang and needs another.
	var into := body.sweep(centre, Vector3(0.04, -0.15, 0.0), t.stand_height, t.radius)
	_check(into.hit and absf(into.normal.dot(Vector3(0.04, -0.15, 0.0).normalized())) < 0.02,
		"a push at the panel is reported as the wall it grazes (the engine's answer the fix copes with)",
		"hit %s n=%v" % [into.hit, into.normal])

	var command := DotFpsCommand.new()
	command.move = Vector2(1.0, 0.0)
	var lowest := s.position.y
	for _i in range(48):
		motor.simulate(s, command, 1.0 / 32.0)
		lowest = minf(lowest, s.position.y)
	_check(lowest < 0.05, "it reaches the floor within a second and a half", "lowest feet %.3f, at %v" % [lowest, s.position])
	# Out by the crease of the wall and the panel (straight down) since the crease leg runs
	# first; by the split leg before that existed. Either is the counter that says so.
	_check(s.mode == DotFpsState.Mode.GROUND and motor.split_leg_ticks + motor.crease_leg_ticks > 0,
		"and stands there, and says how it got out",
		"mode %d, %d split legs, %d crease legs" % [s.mode, motor.split_leg_ticks, motor.crease_leg_ticks])

	# The second wedge the school's doors found: three planes at once, the classic slide's
	# "stop dead". Measured in a room's corner under a window: the side wall, an upright
	# edge and a downward-leaning edge of the window's boxes, with a push into the corner
	# and gravity. Straight down leaves all three, so the answer must not be zero.
	var corner: Array[Vector3] = [Vector3(-1.0, 0.0, 0.0), Vector3(0.0, -0.140875, -0.990027).normalized(),
		Vector3(0.142474, 0.0, -0.989798).normalized()]
	var out := motor._resolve_planes(corner, Vector3(0.013258, -0.004883, 0.013258))
	var leaves_all := out.length() > 1e-4
	for plane in corner:
		leaves_all = leaves_all and out.dot(plane) >= -1e-5
	_check(leaves_all and out.y < 0.0, "three planes with a way down between them give the way down", "%v" % out)
	var pocket: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	_check(motor._resolve_planes(pocket, Vector3(-1.0, -1.0, -1.0)).is_zero_approx(),
		"and a real pocket, with none, still stops")
	_done()


# --- The simulator a bot plans with --------------------------------------------

## DotFpsSimulator is a second motor over a copy of the body. What a surf bot stands on: a ride
## simulated ahead is the ride the player will have, and simulating it changes nothing live.
## Armed by dropping the tunables duplicate (the sim then shares the live ones; the counter
## check still passes) and by making copy_for_simulation return the live body itself (the
## query-count check fails).
func _test_a_simulator_is_the_motor() -> void:
	_section("a simulator rides a ramp exactly as the live motor does, and touches nothing live")

	await _clear()
	_add_ramp(60.0)
	_add_floor(-30.0)
	await _settle()

	var normal := _normal_for(60.0)
	var live_body := DotFpsPhysicsBody.for_node(self)
	var live := DotFpsMotor.new(_tunables(), live_body)
	var start := _on_ramp(normal, 6.0, 0.05)
	start.velocity = Vector3(6.0, 0.0, 0.0)
	var commands: Array[DotFpsCommand] = []
	for i in range(256):
		var c := DotFpsCommand.new()
		c.yaw = -90.0
		c.move = Vector2(-1.0 if i < 128 else 1.0, 0.0)
		commands.append(c)

	var sim := DotFpsSimulator.new().setup(live.tunables, live, live_body, 128)
	var queries_before := live_body.query_count
	var a := start.duplicate_state()
	for c in commands:
		var _e := sim.step(a, c)
	var b := start.duplicate_state()
	for c in commands:
		var _e := sim.step(b, c)
	_check(live.ticks_simulated == 0 and live_body.query_count == queries_before,
		"simulating moves no counter of the live motor or its body",
		"%d ticks, %d queries" % [live.ticks_simulated, live_body.query_count - queries_before])
	_check(a.equals(b, 0.0), "the same start and commands end bit-identical", "%.6f m" % a.divergence(b))

	var s := start.duplicate_state()
	for c in commands:
		live.simulate(s, c, STEP)
	_check(s.position.distance_to(a.position) < 0.0001 and a.horizontal_speed() > 6.0,
		"the live motor given the same commands ends where the simulation did",
		"%.6f m apart, %.2f m/s" % [s.position.distance_to(a.position), a.horizontal_speed()])

	# The oracle ends a step: a pit under the ramp.
	sim.oracle = func(state: DotFpsState) -> int:
		return DotFpsSimulator.EVENT_PIT if state.position.y < -3.0 else DotFpsSimulator.EVENT_NONE
	var fall := start.duplicate_state()
	var event := DotFpsSimulator.EVENT_NONE
	var ticks := 0
	while event == DotFpsSimulator.EVENT_NONE and ticks < 2048:
		event = sim.step(fall, DotFpsCommand.new())
		ticks += 1
	_check(event == DotFpsSimulator.EVENT_PIT and fall.position.y < -3.0,
		"the oracle reports the pit the ride falls into", "event %d after %d ticks" % [event, ticks])

	# A flat body copies itself too: the same boxes, the same answer.
	var flat := DotFpsFlatBody.with_floor(0.0)
	var _box := flat.add_box(AABB(Vector3(2.0, 0.0, -2.0), Vector3(1.0, 2.0, 4.0)))
	var flat_motor := DotFpsMotor.new(_tunables(), flat)
	var flat_sim := DotFpsSimulator.new().setup(flat_motor.tunables, flat_motor, flat, 128)
	var walk := DotFpsCommand.new()
	walk.yaw = -90.0
	walk.move = Vector2(0.0, 1.0)
	var f1 := DotFpsState.new()
	var f2 := DotFpsState.new()
	for _i in range(128):
		flat_motor.simulate(f1, walk, STEP)
		var _e := flat_sim.step(f2, walk)
	_check(flat_sim != null and f1.equals(f2, 0.0) and f1.position.x > 1.0 and f1.position.x < 2.0,
		"a flat body's copy stops at the same box", "x %.3f and %.3f" % [f1.position.x, f2.position.x])
	_done()


# --- The crease of two surf slabs ------------------------------------------------

## `g2gfast-surf-crease-hang-1`: in the V of two 50 degree slabs the capsule sits in both
## faces at once, equally deep, and which one the physics server's rest query names is its
## own business. game-g2gfast's surf bonus rider froze there, speed kept, for 32 to 1,469
## ticks or for good, and which depended only on the absolute tick the ride began on. Here the
## same geometry is ridden from 48 starts (two places in the world, six along the crease, four
## micrometre offsets across it), because each start is a different tie. Armed: with
## [method DotFpsMotor._leave_crease] skipped, all 48 starts freeze at some point, the worst for 218
## ticks, and the shortest ride covers 3.1 m of 23.
func _test_a_surfer_rides_the_crease_of_two_slabs() -> void:
	_section("a surfer in the crease of two slabs rides along it, whatever it starts from")

	var speed := 11.53392
	var ticks := 256
	var free := speed * STEP * ticks
	var rides := 0
	var frozen_rides := PackedStringArray()
	var short_rides := PackedStringArray()
	var crease_legs := 0
	var shortest := INF
	for x0: float in [0.0, 117.0432]:
		await _clear()
		_add_crease(x0)
		await _settle()
		# Dropped into the V and left to settle, so the start is where a rider really sits.
		var motor := DotFpsMotor.new(_crease_tunables(), DotFpsPhysicsBody.for_node(self))
		var drop := DotFpsState.new()
		drop.mode = DotFpsState.Mode.AIR
		drop.position = Vector3(x0, 1.0, 20.0)
		for _i in range(256):
			motor.simulate(drop, DotFpsCommand.new(), STEP)
		for dz: float in [0.0, 0.0123, 0.37, 1.1, 2.5, 3.33]:
			for dx: float in [0.0, 1e-5, -1e-5, 3e-4]:
				var start := drop.duplicate_state()
				start.position += Vector3(dx, 0.0, -dz)
				start.velocity = Vector3(0.0, 0.0, -speed)
				var r := _ride_crease(start, ticks)
				rides += 1
				crease_legs += int(r[2])
				shortest = minf(shortest, float(r[0]))
				var name := "x %.5f z -%.4f" % [x0 + dx, dz]
				if int(r[1]) > 0:
					frozen_rides.append("%s: %d ticks" % [name, r[1]])
				if float(r[0]) < free * 0.98:
					short_rides.append("%s: %.2f m" % [name, r[0]])

	_check(rides == 48 and crease_legs > 0,
		"the rides reach the tie the hang came from (some leg goes along a crease no query named)",
		"%d rides, %d crease legs" % [rides, crease_legs])
	_check(frozen_rides.is_empty(), "no start freezes in the crease with its speed",
		"%d of %d: %s" % [frozen_rides.size(), rides, ", ".join(frozen_rides.slice(0, 4))])
	_check(short_rides.is_empty(), "every start covers the crease at its speed (98%% of %.2f m in %d ticks)" % [free, ticks],
		"shortest %.2f m; %s" % [shortest, ", ".join(short_rides.slice(0, 4))])
	_done()


func _test_static_world_changes_no_result() -> void:
	_section("a static world's reused probes change no result, and ask less")

	await _clear()
	_add_ramp(60.0)
	_add_floor(-2.0)
	await _settle()

	var plain := _replay_log(false)
	var reused := _replay_log(true)

	_check(plain[0] == reused[0] and plain[1] == reused[1] and plain[2] == reused[2],
		"the replayed log ends on the same position, velocity and mode, bit for bit",
		"%s vs %s" % [plain[0], reused[0]])
	_check(plain[3] == reused[3], "and every tick on the way is the same",
		"%d vs %d" % [plain[3], reused[3]])
	_check(reused[4] < plain[4], "with fewer physics queries",
		"%d vs %d" % [reused[4], plain[4]])
	_done()
