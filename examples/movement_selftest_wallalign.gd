extends "res://examples/movement_selftest_walls.gd"

## The wall-run alignment probe of the movement self-test: numbers, at FC's 66 Hz, for what "lined up" means
## (the view along the wall once the attach turn has settled, the velocity along it, a steady distance from it) and for
## a client rewound from the wire ending a run on the tick the server does.

const ALIGN_HZ := 66
## The FC's attach ease (game-fatal-contact VIEW_TURN_RATE): the share of the pending turn applied each second.
const ALIGN_EASE_RATE := 22.0


## One auto run, approached [param deg] off the wall with the view held there, the view turn eased in as FC does.
## Returns the worst angle between the view and the wall's tangent in the first tenth of a second and after the first
## third, the velocity's sideways speed after that, the spread of the distance from the wall, and the run's ticks.
func _align_trial(t: DotFpsTunables, deg: float) -> Dictionary:
	var step := 1.0 / ALIGN_HZ
	var motor := _motor(t, _wall_world())
	var s := _beside_wall(8.0, 0.5, 9.0)
	var rad := deg_to_rad(deg)
	s.velocity = Vector3(sin(rad), 0.5, -cos(rad)) * 8.0
	var yaw := -deg
	var pending := 0.0
	var out := {"early": 0.0, "late": 0.0, "side": 0.0, "near": 99.0, "far": 0.0, "ticks": 0}
	var first := -1
	for i in range(ALIGN_HZ * 2):
		motor.simulate(s, _command(1.0, 0.0, yaw), step)
		pending += motor.view_turn
		var eased := pending if absf(pending) < 0.1 else pending * (1.0 - exp(-ALIGN_EASE_RATE * step))
		pending -= eased
		yaw += eased
		if not s.is_wall_running():
			if first >= 0:
				break
			continue
		first = i if first < 0 else first
		out.ticks += 1
		var age := float(i - first) * step
		var off := absf(wrapf(yaw, -180.0, 180.0))
		if age < 0.1:
			out.early = maxf(out.early, off)
		elif age > 0.33:
			out.late = maxf(out.late, off)
			out.side = maxf(out.side, absf(s.velocity.x))
			var gap := 1.0 - (s.position.x + 0.35)
			out.near = minf(out.near, gap)
			out.far = maxf(out.far, gap)
	return out


## Whether a client that is rewound to the wire's copy of the server's flags every [param every] ticks ends a run capped
## at [param cap] seconds on the server's tick. Returns the two end ticks.
func _align_cap_trial(cap: float, every: int) -> Vector2i:
	var step := 1.0 / ALIGN_HZ
	var t := _wall_tunables()
	t.wall_run_auto = true
	t.wall_run_max_time = cap
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -400.0), Vector3(0.5, 12.0, 400.0)))
	var server := _motor(t, world)
	var client := _motor(t, world)
	var s := _beside_wall(8.0, 0.5, 9.0)
	var c := _beside_wall(8.0, 0.5, 9.0)
	var ends := Vector2i(-1, -1)
	var started := false
	for i in range(ALIGN_HZ * 2):
		server.simulate(s, _command(1.0), step)
		client.simulate(c, _command(1.0), step)
		if i % every == 0:
			DotFpsNetSync.unpack_flags(c, DotFpsNetSync.pack_flags(s))
		started = started or s.is_wall_running()
		if started and ends.x < 0 and not s.is_wall_running():
			ends.x = i
		if started and ends.y < 0 and not c.is_wall_running():
			ends.y = i
	return ends


func _test_wall_run_alignment() -> void:
	_section("wall run alignment at 66 Hz: the view, the velocity and the wall, and a rewound client")

	var was := DotFpsNetSync.timer_scale
	DotFpsNetSync.set_tick_rate(ALIGN_HZ)

	# The FC's wall run: touch a wall in the air, the view turned along it from any angle.
	var t := _wall_tunables()
	t.wall_run_auto = true
	t.wall_run_turn_view = true
	t.wall_run_turn_view_max_angle = 180.0
	t.wall_run_min_speed = 5.9
	for deg: float in [10.0, 30.0, 60.0]:
		var r := _align_trial(t, deg)
		var line := "view %.1f deg off the wall in the first 0.1 s, %.2f after 0.33 s; %.3f m/s sideways; wall %.3f to %.3f m; %d ticks" % [
			r.early, r.late, r.side, r.near, r.far, r.ticks]
		print("  measured: ", line)
		_check(r.ticks >= ALIGN_HZ - 1 and r.early < deg and r.late < 0.5 and r.side < 0.1 and r.far - r.near < 0.01,
			"attaching %d degrees off the wall, the view settles along it, the velocity runs along it and the distance holds" % int(deg), line)

	# A cap that is a whole number of ticks: the server counts it by adding, a client rewound from the wire has it exactly.
	for cap: float in [0.5, 1.0, 1.5]:
		var every := [1, 3]
		for n: int in every:
			var ends := _align_cap_trial(cap, n)
			print("  measured: cap %.1f s, rewind every %d: server ends tick %d, client tick %d" % [cap, n, ends.x, ends.y])
			_check(ends.x == ends.y and absi(ends.x - roundi(cap * ALIGN_HZ)) <= 1,
				"a %.1f s run ends on the server's tick on a client rewound every %d tick(s)" % [cap, n],
				"server tick %d, client tick %d, cap tick %d" % [ends.x, ends.y, roundi(cap * ALIGN_HZ)])

	DotFpsNetSync.timer_scale = was
	_done()


## Off a wall run, a jump, crouch held in the air: the landing starts the slide, which lasts until crouch is let go or slide_duration.
func _test_wall_jump_land_slide() -> void:
	_section("landing from a wall jump with crouch held slides")
	var t := _wall_tunables()
	DotFpsSlidePreset.apply_run(t)
	var crouch := DotFpsCommand.BUTTON_CROUCH

	var landed := _land_from_wall_jump(t, -1)
	_check(landed.slid_on == 0, "the slide starts on touchdown",
		"slid %d ticks after landing, %.2f m/s at landing" % [landed.slid_on, landed.landing_speed])
	_check(landed.boosted > landed.landing_speed + 0.5,
		"and gets the slide's burst", "%.2f from %.2f m/s" % [landed.boosted, landed.landing_speed])
	_check_near(landed.slid_for * STEP, t.slide_duration, STEP * 1.5, "held, it lasts slide_duration")

	var released := _land_from_wall_jump(t, 10)
	_check(released.slid_on == 0 and released.slid_for == 10, "letting go of crouch ends it",
		"%d ticks" % released.slid_for)

	# No crouch: a plain landing; and a landing too slow to slide is a crouch.
	var plain := _land_from_wall_jump(t, -1, 0)
	_check(plain.slid_on < 0, "landing without crouch does not slide")
	var slow := _wall_tunables()
	DotFpsSlidePreset.apply_run(slow)
	slow.slide_min_speed = 40.0
	_check(_land_from_wall_jump(slow, -1).slid_on < 0, "nor does a landing under slide_min_speed")
	var dash := _wall_tunables()
	DotFpsSlidePreset.apply_run(dash)
	dash.dash_button = DotFpsCommand.BUTTON_CROUCH
	dash.dash_enabled = false
	_check(_land_from_wall_jump(dash, -1).slid_on < 0, "nor one whose crouch is also the dash button, which a landing must not press")

	# A held crouch on the ground is still not a press: only a landing counts.
	var motor := _motor(t)
	var crouch_runner := _standing(motor)
	for _i in range(20):
		motor.simulate(crouch_runner, _command(1.0, 0.0, 0.0, crouch), STEP)
	crouch_runner.velocity = Vector3(0.0, 0.0, -10.0)
	motor.simulate(crouch_runner, _command(1.0, 0.0, 0.0, crouch), STEP)
	_check(not crouch_runner.is_sliding(), "crouch held on the ground when the speed arrives still does not slide")
	_done()


## Runs along the right-hand wall, jumps off it and holds [param buttons] until landing and after, letting go [param release] ticks after the slide starts (never when negative).
func _land_from_wall_jump(t: DotFpsTunables, release: int, buttons: int = DotFpsCommand.BUTTON_CROUCH) -> Dictionary:
	var motor := _motor(t, _wall_world())
	var s := _beside_wall(9.0)
	_run_along(motor, s, 10)
	motor.simulate(s, _command(1.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP), STEP)
	var result := {"slid_on": -1, "slid_for": 0, "landing_speed": 0.0, "boosted": 0.0}
	if not _check(motor.wall_jumps == 1, "the run ends in a wall jump"):
		return result
	var ground_at := -1
	var slide_at := -1
	for i in range(300):
		var pressed := buttons if release < 0 or slide_at < 0 or i - slide_at < release else 0
		var speed := s.horizontal_speed()
		motor.simulate(s, _command(1.0, 0.0, 0.0, pressed), STEP)
		if ground_at < 0 and s.is_grounded():
			ground_at = i
			result.landing_speed = speed
		if slide_at < 0 and s.is_sliding():
			slide_at = i
			result.boosted = s.horizontal_speed()
		if slide_at >= 0 and s.is_sliding():
			result.slid_for += 1
		if slide_at >= 0 and not s.is_sliding():
			break
	if slide_at >= 0:
		# The landing is seen at the next tick's start when the move's own check grounded the player.
		result.slid_on = maxi(slide_at - ground_at - 1, 0) if ground_at >= 0 else -1
	return result


## Bouncing down a corridor: each wall jump's push across it must not be turned along the next wall by the run that wall starts, or every bounce adds the push again.
func _test_wall_jump_corridor_speed() -> void:
	_section("wall jumps down a corridor gain only the push's lean along it")
	var t := _wall_tunables()
	t.wall_run_auto = true
	t.wall_run_turn_view = true
	t.wall_run_turn_view_max_angle = 180.0
	var blend := t.wall_jump_look_blend
	# The most of one push that can point along the wall: the look along it, blended in.
	var lean := t.wall_jump_push_speed * blend / Vector2(1.0 - blend, blend).length()
	var worst := {"over": -INF, "case": ""}
	var runs := 0
	for speed in [3.0, 6.0, 9.0]:
		for look in [0.0, 30.0, -30.0]:
			for every in [8, 14, 20, 30]:
				var r := _corridor_bounce(t, speed, look, every)
				runs += r.runs
				var bound: float = maxf(speed, t.wall_run_min_speed) + r.jumps * lean + 0.5
				var over: float = r.along - bound
				if over > worst.over:
					worst = {"over": over, "case": "start %.0f look %.0f every %d: %.2f m/s along after %d jumps, bound %.2f" % [
						speed, look, every, r.along, r.jumps, bound]}
	_check(runs > 0, "the bounces start runs on the facing wall")
	_check(worst.over <= 0.0, "speed along the corridor stays within the start plus each jump's lean", worst.case)
	_done()


## Starts beside the right-hand wall at [param speed] down -Z, presses jump every [param every] ticks with the view [param look] degrees off the run's, and returns the fastest speed along the corridor, the wall jumps and the runs.
func _corridor_bounce(t: DotFpsTunables, speed: float, look: float, every: int) -> Dictionary:
	var motor := _motor(t, _wall_world())
	var s := _beside_wall(speed, 3.0)
	var yaw := 0.0
	var along := 0.0
	for i in range(120):
		var buttons := DotFpsCommand.BUTTON_JUMP if i % every == 2 else 0
		motor.simulate(s, _command(1.0, 0.0, yaw + look, buttons), STEP)
		yaw += motor.view_turn
		if motor.wall_jumps > 0:
			along = maxf(along, absf(s.velocity.z))
		if s.is_grounded():
			break
	return {"along": along, "jumps": motor.wall_jumps, "runs": motor.wall_runs}
