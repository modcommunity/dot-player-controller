extends "res://examples/motor_native_tick_parity.gd"

## Holds [DotFpsMotorBatch] (several players' motor ticks in runs of one dot-sim call) to the players' loop it replaces,
## [method DotFpsMotor.simulate] one player after another, to the bit: eight players walking into each other on random
## streams, six in dot-sim's hull world, one with no hulls and one gathering by script, at two rates under two tunable
## sets. A push between the add and a player's turn, a teleport after its tick and a death during another player's turn
## take the rows after them back; every tick's state and the counters stay identical.
## With no library it says so and passes; [code]DOT_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/motor_batch_parity.tscn[/code]

const PLAYERS := 8
const BATCH_TICKS := 1500
const PLAIN := 6
const SCRIPTED := 7
const DIES := 3
const DEATH_TICK := 900


func _start(i: int) -> Vector3:
	return Vector3(-3.2 + 0.9 * float(i), 0.05, 0.4 * float(i % 3))


func _snap(s: DotFpsState, motor: DotFpsMotor) -> PackedByteArray:
	return var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
		s.crouch_held, s.wall_jump_count, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.slide_time,
		s.slide_cooldown_left, s.launch_cooldown_left, s.dash_cooldown_left, s.wall_run_cooldown_left, s.wall_run_time,
		s.wall_run_spent, s.wall_jumps_in_air, s.wall_jump_heading, s.wall_normal, s.previous_buttons, motor.view_turn])


func _batch_replay(batched: bool, hz: int, variant: int, streams: Array) -> Dictionary:
	DotFpsPhysicsBody.native_enabled = true
	DotFpsMotor.native_tick = true
	DotFpsMotor.native_full = true
	var step := 1.0 / float(hz)
	var tun := _tick_tunables(variant)
	var world: Object = ClassDB.instantiate(&"DotSimHullWorld")
	var motors: Array[DotFpsMotor] = []
	var states: Array[DotFpsState] = []
	var alive: Array[bool] = []
	var ids := PackedInt64Array()
	var script_gathers: Array[int] = [0]
	var wired := true
	for i in range(PLAYERS):
		var physics := DotFpsPhysicsBody.for_node(self)
		physics.pass_out_mask = 1 << 3
		var body: DotFpsBody = physics
		if i != PLAIN:
			var me := i
			body = DotFpsHullBody.new().wrap(physics, func() -> Array:
				script_gathers[0] += 1
				var boxes := []
				for j in range(PLAYERS):
					if j != me and j != PLAIN and alive[j]:
						var f := states[j].position
						boxes.append(AABB(f - Vector3(tun.radius, 0.0, tun.radius), Vector3(tun.radius * 2.0, tun.stand_height, tun.radius * 2.0)))
				return boxes)
			if i != SCRIPTED:
				wired = body.set_hull_world(world, i) and wired
		motors.append(DotFpsMotor.new(tun, body))
		var s := DotFpsState.new()
		s.position = _start(i)
		s.mode = DotFpsState.Mode.AIR
		states.append(s)
		alive.append(true)
		ids.append(100 + i)
	var batch := DotFpsMotorBatch.new()
	var ticks: Array[PackedByteArray] = []
	var rows: Array[int] = []
	rows.resize(PLAYERS)
	var before := DotFpsPhysicsBody.native_ticks
	for tick in range(BATCH_TICKS):
		var data := PackedFloat64Array()
		for i in range(PLAYERS):
			var p := states[i].position
			var flags := 0 if i == PLAIN else (3 if i == SCRIPTED else 7)
			if not alive[i]:
				flags &= ~2
			data.append_array(PackedFloat64Array([p.x, p.y, p.z, tun.radius, tun.stand_height, flags]))
		world.begin(ids, data, Callable(), 1.0e9)
		if batched:
			wired = batch.start(step) and wired
			for i in range(PLAYERS):
				rows[i] = batch.add(motors[i], states[i], streams[i][tick]) if alive[i] else -1
		for i in range(PLAYERS):
			if batched and rows[i] >= 0 and not alive[i]:
				# The one tick the loops differ in: its start had run when the player died, and stays counted.
				batch.skip(rows[i])
				rows[i] = -1
				motors[i].ticks_simulated -= 1
			if not alive[i]:
				continue
			var s := states[i]
			if i == 2 and tick % 97 == 13:
				s.velocity += Vector3(0.5, 3.0, 1.0)
			var told := false
			if batched:
				told = batch.finish(rows[i])
			else:
				motors[i].simulate(s, streams[i][tick], step)
			if not told:
				world.moved(i, s.position.x, s.position.y, s.position.z)
			var changed := false
			if i == 1 and tick % 131 == 50:
				s.position = _start(i) + Vector3(0.0, 0.5, 0.0)
				s.velocity = Vector3.ZERO
				world.moved(i, s.position.x, s.position.y, s.position.z)
				changed = true
			if i == 1 and tick == DEATH_TICK:
				alive[DIES] = false
				world.set_alive(DIES, false)
				changed = true
			if changed and batched:
				batch.moved_after(rows[i])
		world.end()
		var all := PackedByteArray()
		for i in range(PLAYERS):
			if alive[i]:
				all.append_array(_snap(states[i], motors[i]))
		ticks.append(all)
	var counters := []
	for m in motors:
		counters.append_array([m.body.hull_blocks, m.body.world_touches, m.stuck_ticks, m.depenetrated_ticks, m.slides,
			m.launches, m.dashes, m.wall_runs, m.wall_jumps, m.ticks_simulated])
	return {"ticks": ticks, "counters": counters, "wired": wired, "script_gathers": script_gathers[0],
		"native_ticks": DotFpsPhysicsBody.native_ticks - before, "batch": batch, "blocks": motors[0].body.hull_blocks + motors[4].body.hull_blocks}


func _batch_runs() -> void:
	for variant: int in [0, 2]:
		for hz: int in [33, 66]:
			var streams := []
			for i in range(PLAYERS):
				streams.append(_random_stream(1000 + i * 77 + hz + variant, BATCH_TICKS))
			var a := _batch_replay(false, hz, variant, streams)
			var b := _batch_replay(true, hz, variant, streams)
			var label := "%d players @%d Hz set %d" % [PLAYERS, hz, variant]
			var first := -1
			for i in range(BATCH_TICKS):
				if a["ticks"][i] != b["ticks"][i]:
					first = i
					break
			var batch: DotFpsMotorBatch = b["batch"]
			print("  %-28s rows %d in %d runs, %d retakes, %d stale, hull blocks %d, script gathers %d" % [
				label, batch.rows, batch.runs, batch.retakes, batch.stale, a["blocks"], a["script_gathers"]])
			_check(a["wired"] and b["wired"], label + ": the hull world and the batch are there")
			_check(first < 0, label + ": every one of %d ticks identical for every player%s" % [BATCH_TICKS, "" if first < 0 else " (first differs at tick %d)" % first])
			_check(a["counters"] == b["counters"], label + ": the same motor and hull counters")
			_check(a["native_ticks"] == b["native_ticks"], label + ": as many native ticks (%d, batched %d)" % [a["native_ticks"], b["native_ticks"]])
			_check(a["script_gathers"] == b["script_gathers"], label + ": as many script gathers")
			_check(a["blocks"] > 0, label + ": the players do walk into each other")
			_check(batch.rows > BATCH_TICKS * 5 and batch.runs * 2 < batch.rows, label + ": most ticks ran in the batch, several a call")
			_check(batch.stale > 0 and batch.retakes > batch.stale, label + ": the push, the teleport and the death took rows back")
	_sections += 1


func _run() -> void:
	print("dot-player-controller motor batch parity")
	var expected := 1
	if not DotFpsPhysicsBody.native_available() or not DotFpsMotorBatch.available() or not ClassDB.class_exists(&"DotSimHullWorld"):
		print("  dot-sim's motor batch is not loaded: skipped")
		if OS.get_environment("DOT_SIM_REQUIRE_NATIVE") == "1" and not DotFpsPhysicsBody.native_available():
			_check(false, "the library is loaded (DOT_SIM_REQUIRE_NATIVE=1)")
		expected = 0
	else:
		_build_world()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_batch_runs()
	DotFpsPhysicsBody.native_enabled = true
	DotFpsMotor.native_tick = false
	DotFpsMotor.native_full = true
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
