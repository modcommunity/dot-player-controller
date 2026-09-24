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
const CHECKS := 24

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 5

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
