extends "res://examples/motor_native_parity.gd"

## Holds [member DotFpsMotor.native_tick] (the tick's start and end in dot-sim, [code]DotSimFpsBody.motor_pre/motor_post[/code])
## to the all-script motor, to the bit: the determinism world's scenarios at 22, 33 and 66 Hz, with and without other players'
## hulls, with the default tunables and with wall slides and wall jumps on, once in script and once native, every tick's
## state and the motor's counters identical.
## With no library it says the native half was skipped and passes; [code]DOT_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/motor_native_tick_parity.tscn[/code]


func _tick_tunables(variant: int) -> DotFpsTunables:
	var t := _tunables()
	if variant == 1:
		t.wall_slide_speed = 2.5
		t.wall_jump_enabled = true
		t.air_friction = 0.2
	return t


func _tick_replay(native: bool, sc: Array, stream: Array[DotFpsCommand], step: float, hulls: bool, variant: int) -> Dictionary:
	DotFpsPhysicsBody.native_enabled = native
	DotFpsMotor.native_tick = native
	var physics := DotFpsPhysicsBody.for_node(self)
	physics.pass_out_mask = 1 << 3
	var body: DotFpsBody = physics
	var boxes := _hull_boxes()
	if hulls:
		body = DotFpsHullBody.new().wrap(physics, func() -> Array: return boxes)
	var motor := DotFpsMotor.new(_tick_tunables(variant), body)
	var s := DotFpsState.new()
	s.position = sc[1]
	s.velocity = sc[2]
	s.mode = DotFpsState.Mode.AIR
	var ticks: Array[PackedByteArray] = []
	var before := DotFpsPhysicsBody.native_ticks
	for c in stream:
		motor.simulate(s, c, step)
		ticks.append(var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
			s.crouch_held, s.wall_jump_count]))
	var counters := [body.hull_blocks, body.world_touches, motor.stuck_ticks, motor.duplicate_plane_ticks,
		motor.crease_leg_ticks, motor.split_leg_ticks, motor.depenetrated_ticks, motor.embedded_ticks, motor.lifted_ticks,
		motor.settled_ground_ticks, motor.reused_ground_ticks]
	return {"ticks": ticks, "counters": counters, "end": s.position, "native_ticks": DotFpsPhysicsBody.native_ticks - before}


func _tick_runs() -> void:
	for variant: int in [0, 1]:
		for hulls: bool in [false, true]:
			for hz: int in RATES:
				var step := 1.0 / float(hz)
				for sc: Array in SCENARIOS:
					var stream := _record(sc[3], sc[4], RUN_TICKS)
					var a := _tick_replay(false, sc, stream, step, hulls, variant)
					var b := _tick_replay(true, sc, stream, step, hulls, variant)
					var first := -1
					for i in range(a["ticks"].size()):
						if a["ticks"][i] != b["ticks"][i]:
							first = i
							break
					var label := "%s @%d Hz%s%s" % [sc[0], hz, " +hulls" if hulls else "", " +walls" if variant == 1 else ""]
					print("  %-34s end %s  native halves %d  counters %s" % [label, a["end"], b["native_ticks"], a["counters"]])
					_check(b["native_ticks"] > RUN_TICKS and a["native_ticks"] == 0, label + ": the native run ticked in the library, the script run did not")
					_check(first < 0, label + ": every one of %d ticks identical%s" % [RUN_TICKS, "" if first < 0 else " (first differs at tick %d)" % first])
					_check(a["counters"] == b["counters"], label + ": the same motor and hull counters %s (native %s)" % [a["counters"], b["counters"]])
	_sections += 1


func _run() -> void:
	print("dot-player-controller motor native tick parity")
	var loaded := DotFpsPhysicsBody.native_available()
	var expected := 1
	if not loaded or not ClassDB.class_has_method(DotFpsPhysicsBody.NATIVE_CLASS, &"motor_pre"):
		# A library from before the tick halves is a skip, not a failure: the slide's own suite still gates it.
		print("  dot-sim's motor tick is not loaded: the native half is skipped")
		if not loaded and OS.get_environment("DOT_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library is loaded (DOT_SIM_REQUIRE_NATIVE=1)")
		expected = 0
	else:
		_build_world()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_tick_runs()
	DotFpsPhysicsBody.native_enabled = true
	DotFpsMotor.native_tick = false
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
