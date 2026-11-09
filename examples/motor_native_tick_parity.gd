extends "res://examples/motor_native_parity.gd"

## Holds [member DotFpsMotor.native_tick] (the tick's start and end in dot-sim) and [member DotFpsMotor.native_full]
## (the whole tick in one call, [code]DotSimFpsBody.motor_tick[/code]) to the all-script motor, to the bit: the determinism
## world's scenarios at 22, 33 and 66 Hz, with and without other players' hulls, under four tunable sets (default; wall
## slides and jumps; launch, dash and auto-hop; auto and jump-started wall runs that turn the view), the last two on long
## randomized streams. Every tick's state, timers, wall fields and view turn, and the motor's counters, are identical.
## With no library it says the native half was skipped and passes; [code]DOT_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/motor_native_tick_parity.tscn[/code]


const RANDOM_TICKS := 3000


func _tick_tunables(variant: int) -> DotFpsTunables:
	var t := _tunables()
	if variant == 1:
		t.wall_slide_speed = 2.5
		t.wall_jump_enabled = true
		t.air_friction = 0.2
	elif variant == 2:
		t.launch_enabled = true
		t.launch_button = DotFpsCommand.BUTTON_USER_0
		t.dash_enabled = true
		t.dash_button = DotFpsCommand.BUTTON_USER_1
		t.dash_from_air = false
		t.auto_hop = true
		t.jump_adds_to_velocity = true
		t.bhop_speed_cap_scale = 1.4
		t.slide_requires_sprint = true
		t.wall_jump_enabled = true
	elif variant == 3:
		t.wall_run_auto = true
		t.wall_run_on_jump = true
		t.wall_run_turn_view = true
		t.wall_jump_enabled = true
		t.launch_enabled = true
		t.launch_button = DotFpsCommand.BUTTON_USER_0
		t.launch_from_air = false
	return t


## A seeded stream that changes its inputs every few ticks: any move, sprint, crouch, jump and the two move buttons.
func _random_stream(seed: int, ticks: int) -> Array[DotFpsCommand]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[DotFpsCommand] = []
	var c := DotFpsCommand.new()
	var yaw := 0.0
	for tick in range(ticks):
		if tick % 6 == 0 or rng.randf() < 0.08:
			c = DotFpsCommand.new()
			c.move = Vector2(rng.randi_range(-1, 1), -1.0 if rng.randf() < 0.6 else float(rng.randi_range(-1, 1)))
			var b := 0
			for bit: int in [DotFpsCommand.BUTTON_SPRINT, DotFpsCommand.BUTTON_CROUCH, DotFpsCommand.BUTTON_JUMP,
					DotFpsCommand.BUTTON_USER_0, DotFpsCommand.BUTTON_USER_1]:
				if rng.randf() < (0.5 if bit == DotFpsCommand.BUTTON_SPRINT else 0.18):
					b |= bit
			c.buttons = b
		yaw = wrapf(yaw + rng.randf_range(-0.2, 0.2), -PI, PI)
		var d := DotFpsCommand.new()
		d.move = c.move
		d.buttons = c.buttons
		d.yaw = yaw
		out.append(d)
	return out


## [param way] 0 is all script, 1 the native start and end, 2 the whole tick native.
func _tick_replay(way: int, sc: Array, stream: Array[DotFpsCommand], step: float, hulls: bool, variant: int) -> Dictionary:
	DotFpsPhysicsBody.native_enabled = way > 0
	DotFpsMotor.native_tick = way > 0
	DotFpsMotor.native_full = way == 2
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
			s.crouch_held, s.wall_jump_count, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.slide_time,
			s.slide_cooldown_left, s.launch_cooldown_left, s.dash_cooldown_left, s.wall_run_cooldown_left, s.wall_run_time,
			s.wall_run_spent, s.wall_jumps_in_air, s.wall_jump_heading, s.wall_normal, s.previous_buttons, motor.view_turn]))
	var counters := [body.hull_blocks, body.world_touches, motor.stuck_ticks, motor.duplicate_plane_ticks,
		motor.crease_leg_ticks, motor.split_leg_ticks, motor.depenetrated_ticks, motor.embedded_ticks, motor.lifted_ticks,
		motor.settled_ground_ticks, motor.reused_ground_ticks, motor.slides, motor.launches, motor.dashes, motor.wall_runs,
		motor.wall_jumps]
	return {"ticks": ticks, "counters": counters, "end": s.position, "native_ticks": DotFpsPhysicsBody.native_ticks - before}


func _tick_runs() -> void:
	var names := ["", " +walls", " +moves", " +wallruns"]
	var total := 0
	for variant: int in [0, 1, 2, 3]:
		for hulls: bool in [false, true]:
			for hz: int in RATES:
				var step := 1.0 / float(hz)
				for sc: Array in SCENARIOS:
					var stream := _record(sc[3], sc[4], RUN_TICKS) if variant < 2 else _random_stream(sc[3] * 31 + hz, RANDOM_TICKS)
					var a := _tick_replay(0, sc, stream, step, hulls, variant)
					var label := "%s @%d Hz%s%s" % [sc[0], hz, " +hulls" if hulls else "", names[variant]]
					_check(a["native_ticks"] == 0, label + ": the script run did not tick in the library")
					var ways: Array[int] = [2]
					if variant < 2:
						ways = [1, 2]
					for way in ways:
						var b := _tick_replay(way, sc, stream, step, hulls, variant)
						var first := -1
						for i in range(a["ticks"].size()):
							if a["ticks"][i] != b["ticks"][i]:
								first = i
								break
						var lw := label + (" full" if way == 2 else " halves")
						total += stream.size()
						print("  %-44s end %s  native %d  counters %s" % [lw, a["end"], b["native_ticks"], a["counters"]])
						var want: bool = b["native_ticks"] == stream.size() if way == 2 else b["native_ticks"] > stream.size()
						_check(want, lw + ": the native run ticked in the library, one call a tick when whole")
						_check(first < 0, lw + ": every one of %d ticks identical%s" % [stream.size(), "" if first < 0 else " (first differs at tick %d: script %s native %s)" % [first, bytes_to_var(a["ticks"][first]), bytes_to_var(b["ticks"][first])]])
						_check(a["counters"] == b["counters"], lw + ": the same motor and hull counters %s (native %s)" % [a["counters"], b["counters"]])
	print("  %d native ticks compared" % total)
	_sections += 1


## The motor keeps its native tunables arrays between ticks; a changed value or a swapped resource must rebuild both.
func _tun_cache_check() -> void:
	var was := DotFpsMotor.native_tick
	DotFpsMotor.native_tick = true
	var t := _tunables()
	var motor := DotFpsMotor.new(t, DotFpsPhysicsBody.for_node(self))
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.GROUND
	var tick := motor._native_tick_tun(s)
	var full := motor._native_full_tun(tick)
	_check(motor._native_tick_tun(s) == tick and motor._native_full_tun(tick) == full,
		"the native tunables arrays are reused while nothing changes")
	t.max_speed += 1.0
	t.wall_jump_up_speed += 1.0
	var tick2 := motor._native_tick_tun(s)
	var full2 := motor._native_full_tun(tick2)
	_check(tick2[11] == t.max_speed and full2[11] == t.max_speed and full2[full2.size() - 1] == t.wall_jump_up_speed,
		"a changed tunable rebuilds the tick and full arrays (max_speed %s, wall_jump_up_speed %s)" % [tick2[11], full2[-1]])
	var other := _tunables()
	other.max_speed = t.max_speed + 2.0
	motor.tunables = other
	_check(motor._native_tick_tun(s)[11] == other.max_speed, "swapped tunables rebuild the arrays")
	DotFpsMotor.native_tick = was


func _run() -> void:
	print("dot-player-controller motor native tick parity")
	_tun_cache_check()
	var loaded := DotFpsPhysicsBody.native_available()
	var expected := 1
	if not loaded or not ClassDB.class_has_method(DotFpsPhysicsBody.NATIVE_CLASS, &"motor_tick"):
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
	DotFpsMotor.native_full = true
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
