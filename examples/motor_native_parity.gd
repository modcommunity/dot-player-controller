extends "res://examples/motor_determinism_selftest.gd"

## Holds dot-sim's native collision body ([code]DotSimFpsBody[/code]) to [DotFpsPhysicsBody]'s script answers, to the bit,
## since web clients run the script and native clients and servers the library, and they play together.
## Two levels: the motor replays recorded input streams (the determinism world's twelve scenarios at 22, 33 and 66 Hz) once
## in script and once native, and every tick's state must be identical; then thousands of random sweeps, rest contacts and
## overlaps, inside and outside motor ticks, are asked of both and every field compared exactly. The replays run again with
## other players' hulls ([DotFpsHullBody]), and random slides compare the native collide-and-slide with the script's.
## With no library it says the native half was skipped and passes; [code]DOT_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/motor_native_parity.tscn[/code]

const RATES := [22, 33, 66]
const RUN_TICKS := 900
const FUZZ := 6000
const SLIDE_FUZZ := 3000

const SCENARIOS := [
	["floor_run", Vector3(0, 0.05, 0), Vector3.ZERO, 1, 1],
	["floor_walk", Vector3(5, 0.05, -15), Vector3.ZERO, 2, 0],
	["ramps", Vector3(-20, 0.05, -2), Vector3(0, 0, -6), 3, 1],
	["turning", Vector3(0, 0.05, 10), Vector3(0, 0, -8), 4, 2],
	["wall_run", Vector3(26, 1.5, 0), Vector3(0, 0, -10), 5, 1],
	["surf_slab", Vector3(14, 6, 2), Vector3(0, 0, 6), 6, 1],
	["trimesh", Vector3(-8, 0.05, 24), Vector3(0, 0, -5), 7, 1],
	["pillars", Vector3(-14, 0.05, 6), Vector3(4, 0, 0), 8, 1],
	["stairs", Vector3(0, 0.05, -2), Vector3(0, 0, -3), 9, 1],
	["air_drop", Vector3(0, 12, 0), Vector3(5, 0, 3), 10, 0],
	["corner", Vector3(27, 0.05, 27), Vector3(3, 0, 3), 11, 1],
	["hull_walk", Vector3(2, 0.05, 3), Vector3(0, 0, 4), 12, 1],
]

var _sections := 0


## The input stream of one scenario, recorded once and replayed to both bodies.
func _record(seed: int, plan: int, ticks: int) -> Array[DotFpsCommand]:
	var out: Array[DotFpsCommand] = []
	for tick in range(ticks):
		out.append(_command_for(tick, seed, plan))
	return out


## Standing hulls on a lattice over the test world, so most scenarios meet one: the same list every call.
func _hull_boxes() -> Array:
	var out := []
	for x in range(-30, 31, 6):
		for z in range(-30, 31, 6):
			out.append(AABB(Vector3(x + 1.6, 0.0, z + 2.3), Vector3(0.8, 1.8, 0.8)))
	return out


## Every tick's state, as exact bytes, plus the body's and motor's counters at the end.
func _replay(native: bool, sc: Array, stream: Array[DotFpsCommand], step: float, hulls: bool = false) -> Dictionary:
	DotFpsPhysicsBody.native_enabled = native
	var physics := DotFpsPhysicsBody.for_node(self)
	physics.pass_out_mask = 1 << 3
	var body: DotFpsBody = physics
	var boxes := _hull_boxes()
	if hulls:
		body = DotFpsHullBody.new().wrap(physics, func() -> Array: return boxes)
	var motor := DotFpsMotor.new(_tunables(), body)
	var s := DotFpsState.new()
	s.position = sc[1]
	s.velocity = sc[2]
	s.mode = DotFpsState.Mode.AIR
	var ticks: Array[PackedByteArray] = []
	var slides_before := DotFpsPhysicsBody.native_slides
	var stops_before := DotFpsHullBody.hull_stops
	for c in stream:
		motor.simulate(s, c, step)
		ticks.append(var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.crouch_held, s.wall_jump_count]))
	var counters := [physics.query_count, physics.flipped_normals, physics.rest_memo_hits, body.hull_blocks, body.world_touches,
		DotFpsHullBody.hull_stops - stops_before, motor.stuck_ticks, motor.duplicate_plane_ticks, motor.crease_leg_ticks, motor.split_leg_ticks]
	return {"ticks": ticks, "counters": counters, "end": s.position, "native": physics.uses_native(),
		"slides": DotFpsPhysicsBody.native_slides - slides_before}


func _motor_runs() -> void:
	for hulls: bool in [false, true]:
		for hz: int in RATES:
			var step := 1.0 / float(hz)
			for sc: Array in SCENARIOS:
				var stream := _record(sc[3], sc[4], RUN_TICKS)
				var a := _replay(false, sc, stream, step, hulls)
				var b := _replay(true, sc, stream, step, hulls)
				var first := -1
				for i in range(a["ticks"].size()):
					if a["ticks"][i] != b["ticks"][i]:
						first = i
						break
				var label := "%s @%d Hz%s" % [sc[0], hz, " +hulls" if hulls else ""]
				print("  %-27s end %s  counters %s" % [label, a["end"], a["counters"]])
				_check(b["native"] and not a["native"] and b["slides"] > 0 and a["slides"] == 0, label + ": the native run slid in the library, the script run did not")
				_check(first < 0, label + ": every one of %d ticks identical%s" % [RUN_TICKS, "" if first < 0 else " (first differs at tick %d)" % first])
				_check(a["counters"] == b["counters"], label + ": the same queries, flips, memo hits, hull and slide counters %s" % [b["counters"]])
	_sections += 1


## Random single moves, both ways a motor slides (a walk's slide-and-step and [method DotFpsMotor.move_and_slide]),
## from anywhere in the world with and without hulls, in and out of ticks: script and library must agree to the bit.
func _slide_fuzz() -> void:
	DotFpsPhysicsBody.native_enabled = true
	var boxes := _hull_boxes()
	var hull_fn := func() -> Array: return boxes
	var sp := DotFpsPhysicsBody.for_node(self)
	sp.use_native = false
	var np := DotFpsPhysicsBody.for_node(self)
	var sh := DotFpsHullBody.new().wrap(sp, hull_fn)
	var nh := DotFpsHullBody.new().wrap(np, hull_fn)
	var pairs := [
		[DotFpsMotor.new(_tunables(), sp), DotFpsMotor.new(_tunables(), np)],
		[DotFpsMotor.new(_tunables(), sh), DotFpsMotor.new(_tunables(), nh)],
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261109
	var mismatched := 0
	var slides_before := DotFpsPhysicsBody.native_slides
	for i in range(SLIDE_FUZZ):
		var pair: Array = pairs[i % 2]
		var on := rng.randf() < 0.5
		for m: DotFpsMotor in pair:
			m.body.perf_caches = on
			m.body.pass_out_mask = 1 << 3 if i % 5 == 0 else 0
		var pos := Vector3(rng.randf_range(-31, 31), rng.randf_range(0.0, 3.0), rng.randf_range(-31, 31))
		if rng.randf() < 0.5:
			pos.y = rng.randf_range(0.0, 0.1)
		if i % 2 == 1 and rng.randf() < 0.6:
			# Beside a hull, so a short move meets it.
			var near: AABB = boxes[rng.randi() % boxes.size()]
			pos = near.get_center() + Vector3(rng.randf_range(-1.4, 1.4), 0.0, rng.randf_range(-1.4, 1.4))
			pos.y = rng.randf_range(0.0, 0.1)
		var vel := Vector3(rng.randf_range(-14, 14), rng.randf_range(-12, 8), rng.randf_range(-14, 14))
		var delta: float = 1.0 / float(RATES[rng.randi() % RATES.size()])
		var walk := rng.randf() < 0.6
		var flag := rng.randf() < 0.7
		var grounded := rng.randf() < 0.7
		var tick := rng.randf() < 0.7
		var out := []
		for m: DotFpsMotor in pair:
			var s := DotFpsState.new()
			s.position = pos
			s.velocity = vel
			s.mode = DotFpsState.Mode.GROUND if grounded else DotFpsState.Mode.AIR
			if tick:
				m.body.begin_tick()
			if walk:
				m._move(s, delta, not flag)
			else:
				m.move_and_slide(s, delta, flag)
			if tick:
				m.body.end_tick()
			out.append(var_to_bytes([s.position, s.velocity, s.mode, s.ground_normal, m.body.hull_blocks, m.body.world_touches,
				m.stuck_ticks, m.duplicate_plane_ticks, m.crease_leg_ticks, m.split_leg_ticks]))
		if out[0] != out[1]:
			mismatched += 1
			if mismatched <= 5:
				print("  slide mismatch at %d: at %s v %s dt %s walk %s flag %s hulls %s" % [i, pos, vel, delta, walk, flag, i % 2])
	var native_slides := DotFpsPhysicsBody.native_slides - slides_before
	print("  %d slides, %d native; hull blocks %d/%d, world touches %d/%d, crease legs %d/%d, split legs %d/%d" % [
		SLIDE_FUZZ, native_slides, sh.hull_blocks, nh.hull_blocks, sh.world_touches, nh.world_touches,
		pairs[0][0].crease_leg_ticks + pairs[1][0].crease_leg_ticks, pairs[0][1].crease_leg_ticks + pairs[1][1].crease_leg_ticks,
		pairs[0][0].split_leg_ticks + pairs[1][0].split_leg_ticks, pairs[0][1].split_leg_ticks + pairs[1][1].split_leg_ticks])
	_check(native_slides > SLIDE_FUZZ / 2, "the slide fuzz ran the library's slide")
	_check(mismatched == 0, "every slide answered identically (%d differed)" % mismatched)
	_check(sh.hull_blocks > 50 and sh.world_touches > 50, "the slide fuzz met hulls and the world often enough to mean anything")
	_sections += 1


func _same_hit(a: DotFpsBody.Hit, b: DotFpsBody.Hit) -> bool:
	return var_to_bytes([a.hit, a.fraction, a.normal, a.point, a.collider_id, a.depth]) == var_to_bytes([b.hit, b.fraction, b.normal, b.point, b.collider_id, b.depth])


func _query_fuzz() -> void:
	DotFpsPhysicsBody.native_enabled = true
	var sb := DotFpsPhysicsBody.for_node(self)
	sb.use_native = false
	var nb := DotFpsPhysicsBody.for_node(self)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261108
	var mismatched := 0
	var hits := 0
	var kinds := [0, 0, 0]
	var heights := [1.8, 1.8, 1.0, 0.9, 1.62]
	var radii := [0.4, 0.4, 0.3, 0.45]
	var in_tick := false
	for i in range(FUZZ):
		# Ticks of a few queries each, with repeats, so the rest memo is exercised; filters change now and then.
		if i % 7 == 0:
			if in_tick:
				sb.end_tick()
				nb.end_tick()
			in_tick = rng.randf() < 0.8
			if in_tick:
				sb.begin_tick()
				nb.begin_tick()
		if i % 500 == 250:
			var mask: int = [1, 1 | (1 << 3), 0xFFFFFFFF][rng.randi() % 3]
			var po: int = [0, 1 << 3][rng.randi() % 2]
			sb.collision_mask = mask
			nb.collision_mask = mask
			sb.pass_out_mask = po
			nb.pass_out_mask = po
		if i % 1000 == 999:
			var on := rng.randf() < 0.5
			sb.perf_caches = on
			nb.perf_caches = on
		var at := Vector3(rng.randf_range(-31, 31), rng.randf_range(-0.5, 9.0), rng.randf_range(-31, 31))
		if i % 3 == 1:
			at.y = rng.randf_range(-0.05, 0.3)
		var h: float = heights[rng.randi() % heights.size()]
		var r: float = radii[rng.randi() % radii.size()]
		var kind := rng.randi() % 3
		kinds[kind] += 1
		var same := true
		match kind:
			0:
				var motion := Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 1), rng.randf_range(-3, 3))
				if rng.randf() < 0.1:
					motion = Vector3.ZERO
				elif rng.randf() < 0.3:
					motion *= 0.01
				var x := sb.sweep(at, motion, h, r)
				var y := nb.sweep(at, motion, h, r)
				same = _same_hit(x, y)
				hits += int(x.hit)
			1:
				var x := sb.rest_contact(at, h, r)
				var y := nb.rest_contact(at, h, r)
				same = _same_hit(x, y)
				hits += int(x.hit)
				# The same question again, as a tick asks it: the memo's answer must match too.
				if rng.randf() < 0.3:
					same = same and _same_hit(sb.rest_contact(at, h, r), nb.rest_contact(at, h, r))
			2:
				same = sb.overlaps(at, h, r) == nb.overlaps(at, h, r)
		if not same:
			mismatched += 1
			if mismatched <= 5:
				print("  mismatch at query %d (kind %d) at %s h %s r %s" % [i, kind, at, h, r])
	if in_tick:
		sb.end_tick()
		nb.end_tick()
	print("  %d queries (%d sweeps, %d rests, %d overlaps), %d hits; counts %d/%d, flips %d/%d, memo %d/%d" % [
		FUZZ, kinds[0], kinds[1], kinds[2], hits, sb.query_count, nb.query_count, sb.flipped_normals, nb.flipped_normals, sb.rest_memo_hits, nb.rest_memo_hits])
	_check(nb.uses_native() and not sb.uses_native(), "the fuzz compared the library with the script")
	_check(mismatched == 0, "every query answered identically (%d differed)" % mismatched)
	_check(hits > FUZZ / 10, "the fuzz hit something often enough to mean anything")
	_check(sb.query_count == nb.query_count and sb.flipped_normals == nb.flipped_normals and sb.rest_memo_hits == nb.rest_memo_hits, "the same query, flip and memo counts")
	_sections += 1


func _run() -> void:
	print("dot-player-controller motor native parity")
	var loaded := DotFpsPhysicsBody.native_available()
	var expected := 3
	if not loaded:
		print("  dot-sim's motor module is not loaded: the native half is skipped")
		if OS.get_environment("DOT_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library is loaded (DOT_SIM_REQUIRE_NATIVE=1)")
		expected = 0
	else:
		_build_world()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_motor_runs()
		_query_fuzz()
		_slide_fuzz()
	DotFpsPhysicsBody.native_enabled = true
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
