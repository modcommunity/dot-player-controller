extends "res://examples/movement_selftest_walls.gd"

## The wall-run alignment probe of the movement self-test: numbers, at the arena's 66 Hz, for what "lined up" means
## (the view along the wall once the attach turn has settled, the velocity along it, a steady distance from it) and for
## a client rewound from the wire ending a run on the tick the server does.

const ALIGN_HZ := 66
## The arena's attach ease (game-fatal-contact VIEW_TURN_RATE): the share of the pending turn applied each second.
const ALIGN_EASE_RATE := 22.0


## One auto run, approached [param deg] off the wall with the view held there, the view turn eased in as the arena does.
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

	# The arena's wall run: touch a wall in the air, the view turned along it from any angle.
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
