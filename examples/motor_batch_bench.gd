extends "res://examples/motor_bench.gd"

## Micro-benchmark of the players' loop a dedicated server runs with [DotFpsMotorBatch] (game-arena's
## `_tick_players_batched`): N controllers in a collision world, their hulls in dot-sim's hull world, each tick
## begin_tick and add for every player, then finish and end_tick for every player. Prints microseconds per player per
## tick for each of the four steps, and a digest of every tick's states: one build prints one digest, and a change that
## keeps results identical prints the digest the tree before it printed. Also runs the one-by-one loop
## ([method DotFpsController.simulate_tick]) and says whether it ends in the same states.
## With no dot-sim library it says so and exits 0.
## Run: [code]godot --headless --path . res://examples/motor_batch_bench.tscn [-- --n=32 --ticks=1000][/code]


## A controller whose physics body is wrapped in a hull body, as game-arena's players are (ArenaSolidBody).
class HullController extends DotFpsController:
	func _make_body() -> DotFpsBody:
		return DotFpsHullBody.new().wrap(super._make_body(), Callable())


func _hull_player(i: int, parent: Node) -> DotFpsController:
	var player := CharacterBody3D.new()
	player.name = "P%d" % i
	player.collision_layer = 0
	player.collision_mask = 0
	parent.add_child(player)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = CapsuleShape3D.new()
	player.add_child(collision)
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	var camera := Camera3D.new()
	camera.name = "Camera"
	head.add_child(camera)
	var view := DotFpsView.new()
	view.name = "View"
	player.add_child(view)
	var c := HullController.new()
	c.name = "Controller"
	c.drive = DotFpsController.Drive.EXTERNAL
	c.register_default_actions = false
	c.register_service = false
	player.add_child(c)
	return c


## One run of [member _ticks] ticks; [param batched] picks the loop. Returns the microseconds per player per tick of
## each step and the digest of every tick's states.
func _loop(batched: bool) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	_world_into(root, true)
	var ctrls: Array[DotFpsController] = []
	for i in range(_n):
		ctrls.append(_hull_player(i, root))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var world: Object = ClassDB.instantiate(&"DotSimHullWorld")
	var ids := PackedInt64Array()
	var wired := true
	for i in range(_n):
		var c := ctrls[i]
		if not c._started:
			c.setup()
		# Close together, so the hulls block each other now and then.
		c.teleport(Vector3(-6.0 + float(i % 8) * 1.5, 0.05, -6.0 + float(i / 8) * 1.5))
		wired = c.body.set_hull_world(world, i) and wired
		ids.append(100 + i)
	var batch := DotFpsMotorBatch.new()
	var rows := PackedInt64Array()
	rows.resize(_n)
	var us := PackedInt64Array([0, 0, 0, 0, 0])
	var digest := 0
	var tun := ctrls[0].tunables
	for tick in range(_ticks):
		var data := PackedFloat64Array()
		for i in range(_n):
			var p := ctrls[i].state.position
			data.append_array(PackedFloat64Array([p.x, p.y, p.z, tun.radius, tun.stand_height, 7]))
		world.begin(ids, data, Callable(), 1.0e9)
		for i in range(_n):
			ctrls[i].apply_command(command_for(tick, i, false))
		var t0 := Time.get_ticks_usec()
		if batched:
			wired = batch.start(STEP) and wired
			for i in range(_n):
				var c := ctrls[i]
				var t := Time.get_ticks_usec()
				var began := c.begin_tick(tick, STEP)
				var t1 := Time.get_ticks_usec()
				us[0] += t1 - t
				rows[i] = batch.add(c.motor, c.state, c.current_command) if began else -2
				us[1] += Time.get_ticks_usec() - t1
			for i in range(_n):
				var c := ctrls[i]
				if rows[i] < 0:
					continue
				var t := Time.get_ticks_usec()
				var told := batch.finish(rows[i])
				var t1 := Time.get_ticks_usec()
				us[2] += t1 - t
				c.end_tick(tick, STEP)
				us[3] += Time.get_ticks_usec() - t1
				if not told:
					var f := c.state.position
					world.moved(i, f.x, f.y, f.z)
		else:
			for i in range(_n):
				var c := ctrls[i]
				c.simulate_tick(tick, STEP)
				var f := c.state.position
				world.moved(i, f.x, f.y, f.z)
		us[4] += Time.get_ticks_usec() - t0
		world.end()
		for i in range(_n):
			var s := ctrls[i].state
			digest = hash([digest, s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.surface,
				s.time_since_grounded, s.time_since_jump, s.previous_buttons, ctrls[i].motor.view_turn])
	var counters := []
	for c in ctrls:
		counters.append_array([c.body.hull_blocks, c.motor.ticks_simulated, c.motor.wall_jumps, c.motor.slides])
	root.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var per := float(_n * _ticks)
	return {"begin": us[0] / per, "add": us[1] / per, "finish": us[2] / per, "end": us[3] / per, "total": us[4] / per,
		"digest": digest, "counters": hash(counters), "wired": wired, "rows": batch.rows, "runs": batch.runs}


func _run() -> void:
	print("motor batch bench: n=%d ticks=%d" % [_n, _ticks])
	if not DotFpsPhysicsBody.native_available() or not DotFpsMotorBatch.available() or not ClassDB.class_exists(&"DotSimHullWorld"):
		print("  dot-sim's motor batch is not loaded: skipped")
		get_tree().quit(0)
		return
	DotFpsPhysicsBody.native_enabled = true
	DotFpsMotor.native_tick = true
	DotFpsMotor.native_full = true
	DotFpsMotor.profile = false
	await get_tree().physics_frame
	var best := {}
	var one: Dictionary = {}
	var digests := {}
	# Interleaved, best of three, so a loaded machine biases neither loop.
	for rep in range(3):
		one = await _loop(false)
		var b: Dictionary = await _loop(true)
		digests[b["digest"]] = true
		if best.is_empty() or b["total"] < best["total"]:
			best = b
		print("  rep %d: one-by-one %.1f us/player, batched %.1f (begin_tick %.1f add %.1f finish %.1f end_tick %.1f)" % [
			rep, one["total"], b["total"], b["begin"], b["add"], b["finish"], b["end"]])
	print("  best batched %.1f us/player/tick: begin_tick %.1f, add %.1f, finish %.1f, end_tick %.1f; rows %d in %d runs" % [
		best["total"], best["begin"], best["add"], best["finish"], best["end"], best["rows"], best["runs"]])
	print("  BATCH_DIGEST %d counters %d" % [best["digest"], best["counters"]])
	var ok: bool = best["wired"] and digests.size() == 1
	print("  batched runs identical to each other: %s; identical to the one-by-one loop: %s" % [
		digests.size() == 1, one["digest"] == best["digest"] and one["counters"] == best["counters"]])
	get_tree().quit(0 if ok else 1)
