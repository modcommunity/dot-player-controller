extends "res://examples/motor_determinism_selftest.gd"

## The motor's perf work (DotFpsMotor.perf_caches: broad-phase rejection in the flat body, per-tick hull candidates, the rest-query memo, skipped stamina snaps and effect resets)
## must change nothing a player or the netcode can see. Replays the determinism scenarios' scripted inputs (runs, jumps, crouch-slides, wall runs, strafes, turns, ramps, stairs, corners)
## through two motors side by side, one on the original code paths and one on the optimised ones, in two worlds (the physics server and analytic boxes with other players' hulls),
## and asserts position, velocity, mode and flags agree to EPSILON on every one of TICKS ticks. Run: godot --headless --path . res://examples/motor_perf_equivalence.tscn
## A check that cannot fail proves nothing: the last section turns a perf flag on in one motor only with a deliberately wrong input and must report a divergence.

const EPSILON := 1e-6

var _worst := 0.0
var _flat_boxes: Array[AABB] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run_equivalence.call_deferred()


func _section(title: String) -> void:
	print(title)


func _bodies_physics() -> Array[DotFpsBody]:
	var out: Array[DotFpsBody] = []
	for _i in range(2):
		var body := DotFpsPhysicsBody.for_node(self)
		body.pass_out_mask = 1 << 3
		out.append(body)
	return out


func _make_flat_world() -> void:
	_flat_boxes.clear()
	_flat_boxes.append(AABB(Vector3(29, 0, -60), Vector3(2, 8, 120)))
	_flat_boxes.append(AABB(Vector3(-31, 0, -60), Vector3(2, 8, 120)))
	_flat_boxes.append(AABB(Vector3(-60, 0, 29), Vector3(120, 8, 2)))
	_flat_boxes.append(AABB(Vector3(-60, 0, -31), Vector3(120, 8, 2)))
	for i in range(5):
		_flat_boxes.append(AABB(Vector3(-3, 0, -4.6 - i * 1.2), Vector3(6, 0.2 * (i + 1), 1.2)))
	for i in range(6):
		_flat_boxes.append(AABB(Vector3(-12.75 + i * 3.0, 0, 2.25 + (i % 2) * 1.8), Vector3(1.5, 2.5, 1.5)))
	for i in range(12):
		_flat_boxes.append(AABB(Vector3(-25 + i * 4.0, 0, -20 + (i % 3) * 9.0), Vector3(1.0 + (i % 4) * 0.5, 0.3 + (i % 5) * 0.4, 1.5)))


## A flat body wrapped with the hulls of ten other players that walk circles, as the arena does for each of its bots.
func _bodies_flat(clock: Array) -> Array[DotFpsBody]:
	var out: Array[DotFpsBody] = []
	for _i in range(2):
		var flat := DotFpsFlatBody.with_floor(0.0)
		for b in _flat_boxes:
			flat.add_box(b)
		var hulls := func() -> Array:
			var list: Array = []
			var t: int = clock[0]
			for k in range(10):
				var a := float(t) * 0.01 + float(k) * 0.9
				var feet := Vector3(cos(a) * (6.0 + k), 0.0, sin(a) * (6.0 + k))
				list.append(AABB(feet - Vector3(0.35, 0.0, 0.35), Vector3(0.7, 1.8, 0.7)))
			return list
		out.append(DotFpsHullBody.new().wrap(flat, hulls))
	return out


func _stamina_tunables() -> DotFpsTunables:
	var t := _tunables()
	t.stamina_enabled = true
	return t


func _same(a: DotFpsState, b: DotFpsState) -> float:
	var d := maxf(a.position.distance_to(b.position), a.velocity.distance_to(b.velocity))
	d = maxf(d, a.ground_normal.distance_to(b.ground_normal))
	d = maxf(d, absf(a.crouch_fraction - b.crouch_fraction))
	d = maxf(d, absf(a.stamina - b.stamina))
	if a.mode != b.mode or a.move_flags() != b.move_flags() or a.ground_id != b.ground_id or a.surface != b.surface:
		d = maxf(d, 1.0)
	if a.modifiers != b.modifiers or a.wall_jump_count != b.wall_jump_count or a.sprinting != b.sprinting or a.stamina_exhausted != b.stamina_exhausted:
		d = maxf(d, 1.0)
	return d


func _pair(name: String, bodies: Array[DotFpsBody], tun: DotFpsTunables, clock: Array, start: Vector3, vel: Vector3, seed: int, plan: int, modifier: bool = false) -> void:
	var motors: Array[DotFpsMotor] = []
	var states: Array[DotFpsState] = []
	for i in range(2):
		var m := DotFpsMotor.new(tun.duplicate() as DotFpsTunables, bodies[i])
		m.perf_caches = i == 0
		if modifier:
			var slow := DotFpsModifier.make(&"slow")
			slow.max_speed_scale = 0.6
			slow.duration_sec = 1.0
			var _idx := m.register_modifier(slow)
		var s := DotFpsState.new()
		s.position = start
		s.velocity = vel
		s.mode = DotFpsState.Mode.AIR
		motors.append(m)
		states.append(s)
	var worst := 0.0
	var first_bad := -1
	var modes := {}
	for tick in range(TICKS):
		clock[0] = tick
		if modifier and tick % 300 == 50:
			for i in range(2):
				var _ok := motors[i].add_modifier(states[i], &"slow")
		var cmd := _command_for(tick, seed, plan)
		for i in range(2):
			motors[i].simulate(states[i], cmd.duplicate_command(), STEP)
		var d := _same(states[0], states[1])
		modes[str(states[0].mode) + ":" + str(states[0].move_flags())] = true
		if d > worst:
			worst = d
		if d > EPSILON and first_bad < 0:
			first_bad = tick
	_worst = maxf(_worst, worst)
	print("  %-18s ticks %d  max divergence %.9f  states %d  end %s  memo hits %s" % [
		name, TICKS, worst, modes.size(), states[0].position,
		str((bodies[0] as DotFpsPhysicsBody).rest_memo_hits) if bodies[0] is DotFpsPhysicsBody else "-"])
	_check(worst <= EPSILON, "%s: old and new paths agree to %s on every tick" % [name, EPSILON] + ("" if first_bad < 0 else " (first at tick %d)" % first_bad))


func _run_equivalence() -> void:
	print("dot-player-controller motor perf equivalence self-test")
	_build_world()
	_make_flat_world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var scenarios := [
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
	_section("physics world")
	for sc in scenarios:
		var bodies := _bodies_physics()
		_pair("phys " + sc[0], bodies, _tunables(), [0], sc[1], sc[2], sc[3], sc[4])
	_section("physics world, stamina and a modifier")
	for sc in scenarios.slice(0, 4):
		_pair("phys+sta " + sc[0], _bodies_physics(), _stamina_tunables(), [0], sc[1], sc[2], sc[3] + 100, sc[4], true)
	_section("analytic boxes with other players' hulls")
	var flat_scenarios := [
		["flat run", Vector3(0, 0.05, 0), Vector3.ZERO, 21, 1],
		["flat walk", Vector3(5, 0.05, -15), Vector3.ZERO, 22, 0],
		["flat turning", Vector3(0, 0.05, 10), Vector3(0, 0, -8), 23, 2],
		["flat wall run", Vector3(26, 1.5, 0), Vector3(0, 0, -10), 24, 1],
		["flat stairs", Vector3(0, 0.05, -2), Vector3(0, 0, -3), 25, 1],
		["flat pillars", Vector3(-14, 0.05, 6), Vector3(4, 0, 0), 26, 1],
		["flat corner", Vector3(27, 0.05, 27), Vector3(3, 0, 3), 27, 1],
		["flat air drop", Vector3(0, 12, 0), Vector3(5, 0, 3), 28, 0],
		["flat through hulls", Vector3(6, 0.05, 0), Vector3(0, 0, 3), 29, 1],
	]
	for sc in flat_scenarios:
		var clock := [0]
		_pair(sc[0], _bodies_flat(clock), _tunables(), clock, sc[1], sc[2], sc[3], sc[4])
	var clock2 := [0]
	_pair("flat+sta+modifier", _bodies_flat(clock2), _stamina_tunables(), clock2, Vector3(0, 0.05, 0), Vector3.ZERO, 31, 1, true)
	_section("the check can fail")
	# One motor fed a different seed must diverge: proves the comparison is not vacuous.
	var bodies := _bodies_physics()
	var a := DotFpsMotor.new(_tunables(), bodies[0])
	var b := DotFpsMotor.new(_tunables(), bodies[1])
	var sa := DotFpsState.new()
	var sb := DotFpsState.new()
	sa.position = Vector3(0, 0.05, 0)
	sb.position = Vector3(0, 0.05, 0)
	var diverged := 0.0
	for tick in range(200):
		a.simulate(sa, _command_for(tick, 1, 1), STEP)
		b.simulate(sb, _command_for(tick, 2, 1), STEP)
		diverged = maxf(diverged, _same(sa, sb))
	_check(diverged > EPSILON, "a motor fed other input diverges (%.9f)" % diverged)
	_completed = 1
	print("worst divergence over all runs: " + str(_worst))
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of 1 sections ran to their last line" % _completed)
	get_tree().quit(1 if _failed > 0 or _completed != 1 else 0)
