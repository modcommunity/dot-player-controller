extends Node3D

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

const STEP := 1.0 / 128.0
const CHECKS := 29

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 7

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0
var _t: DotFpsTunables


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.auto_hop = true
	t.bhop_speed_cap_scale = 0.0
	t.max_speed = 7.0
	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	t.gravity = 20.0
	t.friction = 6.0
	t.max_slope_angle = 46.0
	return t


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


# --- Geometry --------------------------------------------------------------

func _normal_for(angle: float) -> Vector3:
	var r := deg_to_rad(angle)
	return (Vector3.UP * cos(r) + Vector3.FORWARD * sin(r)).normalized()


## A solid whose TOP face is the plane through the origin tilted [param angle].
##
## A real box rather than a plane, because the whole point of this file is to use the
## collision the games use, and Godot has no half-space collider.
func _add_ramp(angle: float, size: float = 200.0) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, size * 0.2, size)
	cs.shape = box
	sb.add_child(cs)
	sb.transform = Transform3D(
		Basis.from_euler(Vector3(-deg_to_rad(angle), 0.0, 0.0)),
		-_normal_for(angle) * (size * 0.1)
	)
	add_child(sb)
	return sb


func _add_floor(y: float) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 10.0, 200.0)
	cs.shape = box
	sb.add_child(cs)
	sb.position = Vector3(0.0, y - 5.0, 0.0)
	add_child(sb)
	return sb


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame


func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


## Positive means the capsule's surface is PAST the ramp face by this many metres.
func _penetration(feet: Vector3, normal: Vector3) -> float:
	var centre := feet + Vector3.UP * (_t.stand_height * 0.5)
	return DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius) - normal.dot(centre)


## A state placed clear of the ramp face by [param above] metres.
func _on_ramp(normal: Vector3, z: float, above: float) -> DotFpsState:
	var s := DotFpsState.new()
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	# Solve for the feet height that puts the capsule `above` clear of the face.
	var centre_y := (support + above + normal.z * z * -1.0 * 0.0) / normal.y
	centre_y = (support + above - normal.z * z) / normal.y
	s.position = Vector3(0.0, centre_y - _t.stand_height * 0.5, z)
	s.mode = DotFpsState.Mode.AIR
	return s


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

## A slab like game-playground's long bank: 20 x 1 x 40 m, rolled [param roll] about its
## length so its +X edge is high, then pitched [param pitch] down toward -Z. Its top
## face's near edge runs through the origin. Returns the basis.
func _add_bank(roll: float, pitch: float, length: float) -> Basis:
	var basis := Basis(Vector3.RIGHT, -deg_to_rad(pitch)) * Basis(Vector3.BACK, deg_to_rad(roll))
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, length)
	cs.shape = box
	sb.add_child(cs)
	sb.transform = Transform3D(basis, basis * Vector3(0.0, -0.5, -length * 0.5))
	add_child(sb)
	return basis


## One rider down a bank and off its far end, holding into the face. Returns the worst
## single-tick speed loss as a fraction of the speed before it, and the speed 2 m past
## the edge (or -1 if the rider never got there).
func _ride_off_the_end(pitch: float, across: float, speed: float) -> Vector2:
	await _clear()
	var length := 40.0
	var basis := _add_bank(56.0, pitch, length)
	await _settle()

	var normal := basis * Vector3.UP
	var far_z := (basis * Vector3(0.0, 0.0, -length)).z
	var motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))
	var s := DotFpsState.new()
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	var centre := basis * Vector3(across, 0.0, -5.0) + normal * (support + 0.03)
	s.position = centre - Vector3.UP * (_t.stand_height * 0.5)
	s.mode = DotFpsState.Mode.AIR
	s.velocity = (basis * Vector3.FORWARD) * speed

	var hold := DotFpsCommand.new()
	hold.move = Vector2(1.0, 0.0)

	var worst := 0.0
	var past := -1.0
	for _i in range(1024):
		var before := s.velocity.length()
		motor.simulate(s, hold, STEP)
		if before > 1.0:
			worst = maxf(worst, 1.0 - s.velocity.length() / before)
		if s.position.z < far_z - 2.0:
			past = s.velocity.length()
			break
	return Vector2(worst, past)


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

## Capsules resting a hair off a 52 degree slab, at the spots the engine answers wrongly.
func _resting_on_slab(normal: Vector3, support: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 400:
		var gap := (i % 20) * 0.0001 - 0.0005
		var p := Vector3((i / 20) * 0.37 - 3.0, 0.0, ((i * 7) % 13) * 0.3 - 2.0)
		p -= normal * normal.dot(p)
		out.append(p + normal * (support + gap))
	return out


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
