extends "res://examples/movement_selftest_wallalign.gd"
## The touch-sampling, idle-parity and wall-rewind sections of the movement self-test. Split out of movement_selftest.gd for file size.


func _test_touch_sampler() -> void:
	_section("touch sampling")

	var t := _tunables()
	var sampler := DotFpsTouchSampler.new(t)
	sampler.set_screen_width(1000.0)
	sampler.tap_button = DotFpsCommand.BUTTON_JUMP

	# A finger on the left half plants the stick where it landed.
	sampler.handle_event(_touch(0, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(0, Vector2(200.0, 500.0 - sampler.stick_radius)))

	var forward := sampler.sample(STEP)
	_check_near(forward.move.y, 1.0, 0.02, "dragging up the screen moves forward")
	_check_near(forward.move.x, 0.0, 0.02, "with no lateral component")

	sampler.handle_event(_drag(0, Vector2(200.0 + sampler.stick_radius, 500.0)))
	var strafe := sampler.sample(STEP)
	_check_near(strafe.move.x, 1.0, 0.02, "and dragging right strafes right")

	# A thumb resting on glass drifts; a player who is not moving must not creep.
	sampler.handle_event(_drag(0, Vector2(205.0, 500.0)))
	var resting := sampler.sample(STEP)
	_check( resting.move == Vector2.ZERO, "a drift inside the dead zone is no input", str(resting.move) )

	sampler.handle_event(_touch(0, Vector2(205.0, 500.0), false))
	var lifted := sampler.sample(STEP)
	_check(lifted.move == Vector2.ZERO, "lifting the finger stops the player")

	# The right half turns the view.
	var before_yaw := sampler.yaw
	sampler.handle_event(_touch(1, Vector2(800.0, 500.0), true))
	sampler.handle_event(_drag(1, Vector2(900.0, 500.0)))
	sampler.sample(STEP)

	_check( not is_equal_approx(sampler.yaw, before_yaw), "dragging the right half turns the view" )

	_touch_sampler_bad_drags(sampler)

	# And a short, still touch there is a tap, not a drag of zero length.
	sampler.handle_event(_touch(1, Vector2(900.0, 500.0), false))
	sampler.handle_event(_touch(2, Vector2(820.0, 400.0), true))
	sampler.handle_event(_touch(2, Vector2(822.0, 401.0), false))

	var tapped := sampler.sample(STEP)
	_check( tapped.is_pressed(DotFpsCommand.BUTTON_JUMP), "a tap presses the configured button" )

	var after_tap := sampler.sample(STEP)
	_check( not after_tap.is_pressed(DotFpsCommand.BUTTON_JUMP), "for exactly one command, so a tap and a hold stay distinguishable" )

	# The game's own on-screen buttons.
	sampler.hold(DotFpsCommand.BUTTON_CROUCH, true)
	_check( sampler.sample(STEP).is_pressed(DotFpsCommand.BUTTON_CROUCH), "a held on-screen button reaches the command" )

	sampler.hold(DotFpsCommand.BUTTON_CROUCH, false)
	_check( not sampler.sample(STEP).is_pressed(DotFpsCommand.BUTTON_CROUCH), "and releasing it stops" )

	_touch_sampler_claimed(sampler)

	_touch_sampler_drives(sampler, t)
	_done()


## A non-finite drag is dropped, so the view keeps its last good angles.
func _touch_sampler_bad_drags(sampler: DotFpsTouchSampler) -> void:
	sampler.handle_event(_touch(1, Vector2(900.0, 500.0), false))
	sampler.handle_event(_touch(7, Vector2(800.0, 500.0), true))
	sampler.handle_event(_drag(7, Vector2(850.0, 540.0)))
	sampler.sample(STEP)
	_check(is_finite(sampler.yaw) and is_finite(sampler.pitch), "a good drag leaves yaw and pitch finite")
	var good_yaw := sampler.yaw
	var good_pitch := sampler.pitch
	sampler.handle_event(_drag(7, Vector2(NAN, 540.0)))
	sampler.handle_event(_drag(7, Vector2(INF, -INF)))
	var rel := _drag(7, Vector2(860.0, 545.0))
	rel.relative = Vector2(NAN, INF)
	sampler.handle_event(rel)
	sampler.sample(STEP)
	_check(is_finite(sampler.yaw) and is_finite(sampler.pitch), "NaN and inf drags keep yaw and pitch finite")
	_check(sampler.yaw == good_yaw and sampler.pitch == good_pitch, "and leave them unchanged")
	sampler.handle_event(_drag(7, Vector2(900.0, 500.0)))
	sampler.sample(STEP)
	_check(sampler.yaw != good_yaw, "and the next good drag still turns the view")
	sampler.handle_event(_touch(7, Vector2(900.0, 500.0), false))
	sampler.handle_event(_touch(1, Vector2(900.0, 500.0), true))


## A finger on the game's own button must not also steer: the button is checked first.
func _touch_sampler_claimed(sampler: DotFpsTouchSampler) -> void:
	sampler.ignore_fn = func(pos: Vector2) -> bool: return pos.x > 900.0
	var yaw_before := sampler.yaw
	sampler.handle_event(_touch(5, Vector2(950.0, 500.0), true))
	sampler.handle_event(_drag(5, Vector2(990.0, 500.0)))
	sampler.sample(STEP)
	_check(sampler._look_finger == -1 and is_equal_approx(sampler.yaw, yaw_before), "a touch the game claims does not start a look drag")
	sampler.handle_event(_touch(5, Vector2(990.0, 500.0), false))
	sampler.handle_event(_touch(6, Vector2(800.0, 500.0), true))
	_check(sampler._look_finger == 6, "while one elsewhere on the look side still does")
	sampler.handle_event(_touch(6, Vector2(800.0, 500.0), false))
	sampler.ignore_fn = Callable()


## Suspending stops everything, and touch drives the simulation like any other input.
func _touch_sampler_drives(sampler: DotFpsTouchSampler, t: DotFpsTunables) -> void:
	# Suspending has to stop everything, or an open chat box leaves the player
	# running because a finger was down when it opened.
	sampler.handle_event(_touch(3, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(3, Vector2(200.0, 300.0)))
	sampler.suspended = true

	var suspended := sampler.sample(STEP)
	_check( suspended.move == Vector2.ZERO and suspended.buttons == 0, "a suspended sampler emits nothing" )

	# And the point of the whole exercise: touch produces ordinary commands, so the
	# simulation cannot tell where they came from.
	var motor := _motor(t)
	var s := _standing(motor)

	sampler.suspended = false
	sampler.handle_event(_touch(3, Vector2(200.0, 500.0), false))
	sampler.handle_event(_touch(4, Vector2(200.0, 500.0), true))
	sampler.handle_event(_drag(4, Vector2(200.0, 500.0 - sampler.stick_radius)))

	for _i in range(120):
		motor.simulate(s, sampler.sample(STEP), STEP)

	_check(
		s.horizontal_speed() > t.max_speed * 0.8,
		"and a touch-driven player reaches ordinary walking speed",
		"%.2f m/s" % s.horizontal_speed()
	)


## Builds the parity world: [world, pad collision shape, moving platform].
func _build_parity_world() -> Array:
	var world := Node3D.new()
	add_child(world)
	var pad := StaticBody3D.new()
	var pad_shape := CollisionShape3D.new()
	var pad_box := BoxShape3D.new()
	pad_box.size = Vector3(8.0, 1.0, 8.0)
	pad_shape.shape = pad_box
	pad.add_child(pad_shape)
	pad.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(pad)
	var low := StaticBody3D.new()
	var low_shape := CollisionShape3D.new()
	var low_box := BoxShape3D.new()
	low_box.size = Vector3(60.0, 1.0, 60.0)
	low_shape.shape = low_box
	low.add_child(low_shape)
	low.position = Vector3(0.0, -3.5, 0.0)
	world.add_child(low)
	var platform := AnimatableBody3D.new()
	var platform_shape := CollisionShape3D.new()
	var platform_box := BoxShape3D.new()
	platform_box.size = Vector3(6.0, 1.0, 6.0)
	platform_shape.shape = platform_box
	platform.add_child(platform_shape)
	platform.position = Vector3(20.0, -0.5, 0.0)
	world.add_child(platform)
	return [world, pad_shape, platform]


## The idle fast path against the full path, tick for tick, over a script that idles, walks, stops, jumps, rides a moving platform and loses its floor.
func _test_idle_parity() -> void:
	_section("idle fast path parity")

	var parts := _build_parity_world()
	var world: Node3D = parts[0]
	var pad_shape: CollisionShape3D = parts[1]
	var platform: AnimatableBody3D = parts[2]
	await get_tree().physics_frame
	await get_tree().physics_frame

	var t := _tunables()
	var fast_body := DotFpsPhysicsBody.new()
	var full_body := DotFpsPhysicsBody.new()
	if not (fast_body.bind(world).ok and full_body.bind(world).ok):
		_check(false, "both physics bodies bind to the parity world")
		world.queue_free()
		return
	var fast := DotFpsMotor.new(t, fast_body)
	var full := DotFpsMotor.new(t, full_body)
	fast.idle_fast_path = true
	full.idle_fast_path = false
	full.reuse_settled_ground = false
	var fs := DotFpsState.new()
	var rs := DotFpsState.new()
	fs.mode = DotFpsState.Mode.GROUND
	rs.mode = DotFpsState.Mode.GROUND

	var diverged := {}
	var ticks := 0
	for tick in range(900):
		var phase := "idle"
		var cmd := DotFpsCommand.new()
		if tick >= 120 and tick < 200:
			phase = "walk"
			cmd = _command(1.0)
		elif tick >= 200 and tick < 380:
			phase = "stop"
		elif tick >= 380 and tick < 440:
			phase = "jump"
			if tick == 380:
				cmd.set_button(DotFpsCommand.BUTTON_JUMP, true)
		elif tick >= 440 and tick < 740:
			phase = "platform"
			if tick == 440:
				for st in [fs, rs]:
					st.position = Vector3(20.0, 0.0, 0.0)
					st.velocity = Vector3.ZERO
					st.mode = DotFpsState.Mode.GROUND
			if tick < 640:
				platform.position.x += 0.01
			await get_tree().physics_frame
		elif tick >= 740:
			phase = "floor"
			if tick == 740:
				for st in [fs, rs]:
					st.position = Vector3.ZERO
					st.velocity = Vector3.ZERO
					st.mode = DotFpsState.Mode.GROUND
			if tick == 840:
				pad_shape.disabled = true
				await get_tree().physics_frame
				await get_tree().physics_frame
		fast.simulate(fs, cmd, STEP)
		full.simulate(rs, cmd, STEP)
		ticks += 1
		if not fs.equals(rs, 0.0001) and not diverged.has(phase):
			diverged[phase] = "tick %d: fast %s %s, full %s %s" % [tick, fs.position, fs.velocity, rs.position, rs.velocity]

	_check(ticks == 900, "all 900 parity ticks ran", "%d" % ticks)
	for phase in ["idle", "walk", "stop", "jump", "platform", "floor"]:
		_check(not diverged.has(phase), "the fast and full paths agree through the %s phase" % phase, str(diverged.get(phase, "")))
	_check(fast.idle_ticks > 100, "the fast path was taken while idle", "%d ticks" % fast.idle_ticks)
	_check(full.idle_ticks == 0, "the reference never takes the fast path", "%d ticks" % full.idle_ticks)
	_check(fs.position.y < -2.0 and rs.position.y < -2.0, "a floor removed under an idle body wakes it and it falls", "%.2f and %.2f" % [fs.position.y, rs.position.y])
	world.queue_free()
	_done()


## A settled player must notice a floor that goes away: the ground-reuse stamp and the idle fast path both skip ground
## queries, so each way of losing the floor is run with both, for a body that stood still and one that just stopped walking.
func _test_settled_floor_removed() -> void:
	_section("settled floor removed")
	for removal in ["shape disabled", "layer cleared", "body freed"]:
		for walked in [false, true]:
			for idle_fast in [false, true]:
				var parts := _build_parity_world()
				var world: Node3D = parts[0]
				var pad_shape: CollisionShape3D = parts[1]
				var body := DotFpsPhysicsBody.new()
				if not body.bind(world).ok:
					_check(false, "the body binds")
					world.queue_free()
					continue
				await get_tree().physics_frame
				await get_tree().physics_frame
				var motor := DotFpsMotor.new(_tunables(), body)
				motor.idle_fast_path = idle_fast
				var st := DotFpsState.new()
				st.mode = DotFpsState.Mode.GROUND
				for i in range(120):
					motor.simulate(st, _command(1.0 if walked and i < 30 else 0.0), STEP)
				var label := "%s, %s, idle fast path %s" % [removal, "stopped walking" if walked else "standing", idle_fast]
				_check(st.mode == DotFpsState.Mode.GROUND, "%s: settled before the floor goes" % label)
				var pad: Node = pad_shape.get_parent()
				match removal:
					"shape disabled":
						pad_shape.disabled = true
					"layer cleared":
						(pad as CollisionObject3D).collision_layer = 0
					"body freed":
						pad.free()
				await get_tree().physics_frame
				await get_tree().physics_frame
				var left_at := -1
				for i in range(60):
					motor.simulate(st, _command(), STEP)
					if left_at < 0 and st.mode != DotFpsState.Mode.GROUND:
						left_at = i
				_check(left_at >= 0 and left_at <= 2, "%s: leaves the ground within 3 ticks of the floor going" % label, "tick %d, y %.2f" % [left_at, st.position.y])
				world.queue_free()
	_done()


## The rewind a client really does: the snapshot pushed over its CURRENT state, then replayed.
## A player pinned against a wall, holding forward and hopping with auto-hop and coyote time.
func _test_wall_hop_rewind() -> void:
	_section("rewinding a wall-pinned hop restores the jump timers")

	# A deathmatch's movement: classic air control, auto-hop, coyote time and a jump buffer.
	var t := _hop_rewind_tunables()
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, 12.0, 400.0)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var commands: Array[DotFpsCommand] = []
	var jump := false
	var strafe := 0.0
	var next := 0
	for i in range(3000):
		if i >= next:
			next = i + rng.randi_range(18, 72)
			var pick := rng.randi_range(0, 3)
			jump = pick == 2
			strafe = -1.0 if pick == 0 else (1.0 if pick == 1 else 0.0)
		commands.append(_command(1.0, strafe, -90.0 + sin(i * 0.01) * 30.0,
			DotFpsCommand.BUTTON_JUMP if jump else 0))

	var motor := DotFpsMotor.new(t, world)
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.GROUND
	var full: Array[DotFpsState] = []
	for c in commands:
		motor.simulate(s, c, STEP)
		full.append(s.duplicate_state())
	_check(absf(s.position.x - (1.0 - t.radius)) < 0.01, "the run ends pinned against the wall", "x %.3f" % s.position.x)

	var plain: Object = _carrier_script().new()
	var timed: Object = _timers_carrier_script().new()
	var counts := []
	for carrier: Object in [timed, plain]:
		var bad := 0
		var worst := 0.0
		for n in range(3 * (commands.size() - 72)):
			var lead: int = [4, 8, 12][n % 3]
			var k := 60 + floori(n / 3.0)
			var replay := full[k + lead].duplicate_state()
			DotFpsNetSync.pull(full[k], carrier)
			DotFpsNetSync.push(carrier, replay)
			var replay_motor := DotFpsMotor.new(t, world)
			for j in range(k + 1, k + lead + 1):
				replay_motor.simulate(replay, commands[j], STEP)
			var e := replay.position.distance_to(full[k + lead].position)
			worst = maxf(worst, e)
			if e > 0.001:
				bad += 1
		counts.append([bad, worst])
	plain.free()
	timed.free()
	_check(counts[0][0] == 0, "every rewind through net_timers lands where the server did", "%d diverged, worst %.3f m" % counts[0])
	_check(counts[1][0] > 0, "negative control: a rewind without net_timers diverges", "%d diverged, worst %.3f m" % counts[1])
	var back := DotFpsState.new()
	DotFpsNetSync.unpack_timers(back, DotFpsNetSync.pack_timers(DotFpsState.new()))
	var spent := DotFpsState.new()
	spent.time_since_grounded = 1000.5
	DotFpsNetSync.unpack_timers(spent, DotFpsNetSync.pack_timers(spent))
	var zero := DotFpsState.new()
	DotFpsNetSync.unpack_timers(zero, 0)
	_check(back.time_since_grounded == 0.0 and back.time_since_jump == 1000.0
		and spent.time_since_grounded == 1000.0 and zero.time_since_grounded == 1000.0,
		"timers round-trip; long ago and an unsent 0 read as long ago")
	_done()


## A deathmatch's movement with the wall features on.
func _hop_rewind_tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = 9.0
	t.accelerate = 12.0
	t.friction = 5.5
	t.stop_speed = 3.0
	t.air_accelerate = 140.0
	t.max_air_wish_speed = 1.2
	t.gravity = 22.0
	t.jump_height = 1.25
	t.auto_hop = true
	t.coyote_time = 0.08
	t.jump_buffer_time = 0.12
	t.slide_enabled = true
	t.slide_min_speed = 6.5
	t.wall_run_enabled = true
	t.wall_run_min_speed = 9.5
	t.wall_jump_enabled = true
	t.wall_slide_speed = 2.5
	return t


## With every wall feature off the motor makes the same bytes as before they existed: a 600-tick
## run hashed against a stored hash. Failing alone after an engine upgrade means re-capture it. Re-captured when the
## jump/ground timers got their 1000 s cap (position, velocity and mode hash unchanged).
func _test_walls_off_identical() -> void:
	_section("wall movement off is byte-identical to before it")

	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(2.0, 0.0, -12.0), Vector3(2.0, 0.3, 6.0)))
	world.add_box(AABB(Vector3(-6.0, 0.0, -20.0), Vector3(12.0, 3.0, 1.0)))
	world.add_box(AABB(Vector3(3.0, 0.0, -30.0), Vector3(0.5, 4.0, 30.0)))
	var old_body := _tunables()
	# The stored hash was taken on the old 1.8 / 0.9 / 0.35 m body, so keep that body here.
	old_body.stand_height = 1.8
	old_body.crouch_height = 0.9
	old_body.radius = 0.35
	var motor := _motor(old_body, world)
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.5, 0.0)
	var bytes := PackedByteArray()
	for i in range(600):
		var buttons := 0
		if i % 23 == 0:
			buttons |= DotFpsCommand.BUTTON_JUMP
		if (i / 40) % 3 == 1:
			buttons |= DotFpsCommand.BUTTON_CROUCH
		if (i / 40) % 3 == 2:
			buttons |= DotFpsCommand.BUTTON_SPRINT
		var c := _command(1.0, sin(float(i) * 0.11), sin(float(i) * 0.05) * 70.0 - 30.0, buttons)
		motor.simulate(s, c, STEP)
		bytes.append_array(var_to_bytes([s.position, s.velocity, s.mode, s.time_since_jump, s.time_since_grounded]))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	var digest := ctx.finish().hex_encode()
	_check(digest == "c8daef020927f76a18aa639c018f468dd09a1c7310904538f3cfce157f1d6c66",
		"600 ticks with every wall setting off hash the same as before wall movement", digest)
	_check(motor.wall_runs == 0 and motor.wall_jumps == 0 and s.wall_normal == Vector3.ZERO, "and no wall probe answered anything")
	_done()
