extends "motor_determinism_selftest.gd"

## perf-native-motor-1 phase 1 (b), scratch probe, not a test: how much does an ULP-level difference between two motor
## implementations (a native server motor vs the GDScript motor a web client predicts with) show up after a prediction
## window? Same world as motor_determinism_selftest plus a ladder. Per scenario and tick rate:
##   * determinism: the same trace twice gives the same digest (bit-exact);
##   * windows: from every tick of the baseline trace, simulate W ticks (W = 0.2 s of ticks, a prediction horizon)
##     twice: clean, and with +-1 ulp noise on every float32 component of position and velocity after EVERY tick
##     (models a port whose rounding differs somewhere each tick). Reports how often the window ends bit-identical,
##     and how often the end positions differ by more than 1e-4 m, 1 mm and dot-net's 1 cm reconcile epsilon.
## godot --headless --path . res://examples/nmotor_parity_probe.tscn [-- --hz 22,33,66 --seconds 20 --window 0.2]

var _hzs: Array = [22, 33, 66]
var _seconds := 20.0
var _window := 0.2
var _rng := RandomNumberGenerator.new()
const LADDER_BOX := AABB(Vector3(-29.2, 0.0, -0.6), Vector3(0.2, 7.5, 1.2))


func _ulp(x: float) -> float:
	var a := absf(x)
	if a < 1e-30:
		return 1.4e-45
	return pow(2.0, floor(log(a) / log(2.0)) - 23.0)


func _jitter(v: Vector3) -> Vector3:
	var out := v
	out.x = v.x + _ulp(v.x) * (1.0 if _rng.randi() & 1 else -1.0)
	out.y = v.y + _ulp(v.y) * (1.0 if _rng.randi() & 1 else -1.0)
	out.z = v.z + _ulp(v.z) * (1.0 if _rng.randi() & 1 else -1.0)
	return out


func _tunables() -> DotFpsTunables:
	var t := super._tunables()
	t.wall_jump_enabled = true    # off by default; Arena-style movement uses it
	t.wall_run_auto = true
	return t


## Plan 10: sprint into the (-30, -30) corner and press jump every 0.3 s, so jumps beside a wall wall-jump.
func _walljump_command(tick: int, hz: int) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	var sec := float(tick) / hz
	c.yaw = 45.0 + 60.0 * sin(sec * 0.7)    # sweeps between the two walls of the corner
	c.move = Vector2(0.4 * sin(sec * 1.3), 1.0)
	c.buttons = DotFpsCommand.BUTTON_SPRINT
	if int(sec / 0.3) != int((sec - 1.0 / hz) / 0.3):
		c.buttons |= DotFpsCommand.BUTTON_JUMP
	return c


func _new_motor() -> Array:
	var body := DotFpsPhysicsBody.for_node(self)
	body.pass_out_mask = 1 << 3
	var motor := DotFpsMotor.new(_tunables(), body)
	var ladder := DotFpsLadderMode.new()
	ladder.volumes = [LADDER_BOX]
	motor.register_mode(ladder)
	return [motor, ladder]


func _ladder_command(tick: int, hz: int) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	var sec := float(tick) / hz
	c.yaw = 90.0    # degrees: facing -X, into the ladder on the x=-30 wall
	c.pitch = 20.0 if fmod(sec, 6.0) < 4.0 else -40.0
	c.move = Vector2(0.3 * sin(sec), 1.0 if fmod(sec, 6.0) < 4.5 else -1.0)    # +y is forward
	if fmod(sec, 6.0) > 5.2 and fmod(sec, 6.0) < 5.3:
		c.buttons |= DotFpsCommand.BUTTON_JUMP
	return c


func _step(m: Array, s: DotFpsState, c: DotFpsCommand, dt: float) -> void:
	var motor: DotFpsMotor = m[0]
	var ladder: DotFpsLadderMode = m[1]
	motor.simulate(s, c, dt)
	var b := DotFpsMotor._view_basis(c.yaw, 0.0)
	ladder.wish = (b.forward * c.move.y + b.right * c.move.x)
	ladder.wish.y = 0.0
	ladder.update(motor, s)


func _digest(s: DotFpsState, d: int) -> int:
	return hash([d, s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.crouch_held, s.wall_jump_count])


func _trace(start: Vector3, vel: Vector3, seed: int, plan: int, hz: int, ticks: int) -> Array:
	var m := _new_motor()
	var s := DotFpsState.new()
	s.position = start
	s.velocity = vel
	s.mode = DotFpsState.Mode.AIR
	var states: Array[DotFpsState] = []
	var cmds: Array[DotFpsCommand] = []
	var d := 0
	for tick in ticks:
		# Commands are scripted against the 128 Hz selftest's 64-tick phases: rescale so a phase is 0.5 s at any rate.
		var c := _ladder_command(tick, hz) if plan == 9 else (_walljump_command(tick, hz) if plan == 10 else _command_for(tick * 128 / hz, seed, plan))
		cmds.append(c)
		states.append(s.duplicate_state())
		_step(m, s, c, 1.0 / hz)
		d = _digest(s, d)
	states.append(s.duplicate_state())
	return [states, cmds, d]


func _probe(name: String, start: Vector3, vel: Vector3, seed: int, plan: int, hz: int) -> Dictionary:
	var ticks := int(_seconds * hz)
	var a := _trace(start, vel, seed, plan, hz, ticks)
	var b := _trace(start, vel, seed, plan, hz, ticks)
	var states: Array[DotFpsState] = a[0]
	var cmds: Array[DotFpsCommand] = a[1]
	var w := int(ceil(_window * hz))
	var dt := 1.0 / hz
	var n := 0
	var exact := 0
	var gt := [0, 0, 0]    # > 1e-4, > 1 mm, > 1 cm
	var errs := PackedFloat64Array()
	var mode_flip := 0
	var modes := {}
	var wall_jumps := 0
	var ladder_ticks := 0
	var wallrun_ticks := 0
	var prev_wj := 0
	for st in states:
		modes[DotFpsState.mode_name(st.mode)] = true
		if st.wall_jumps_in_air > prev_wj:
			wall_jumps += st.wall_jumps_in_air - prev_wj
		prev_wj = st.wall_jumps_in_air
		if st.move_flags() & DotFpsState.Move.WALL_RUN:
			wallrun_ticks += 1
		if st.mode >= DotFpsState.FIRST_CUSTOM_MODE:
			ladder_ticks += 1
	_rng.seed = hash([seed, hz])
	var k := 0
	while k + w < ticks:
		var ma := _new_motor()
		var mb := _new_motor()
		var sa := states[k].duplicate_state()
		var sb := states[k].duplicate_state()
		for i in w:
			_step(ma, sa, cmds[k + i], dt)
			_step(mb, sb, cmds[k + i], dt)
			sb.position = _jitter(sb.position)
			sb.velocity = _jitter(sb.velocity)
		var e := sa.position.distance_to(sb.position)
		n += 1
		errs.append(e)
		if sa.position == sb.position and sa.mode == sb.mode and sa.move_flags() == sb.move_flags():
			exact += 1
		if e > 1e-4: gt[0] += 1
		if e > 1e-3: gt[1] += 1
		if e > 1e-2: gt[2] += 1
		if sa.mode != sb.mode or sa.move_flags() != sb.move_flags():
			mode_flip += 1
		k += 1
	errs.sort()
	var r := {"scenario": name, "hz": hz, "ticks": ticks, "window_ticks": w, "deterministic": a[2] == b[2], "windows": n,
		"bitexact_pct": snappedf(100.0 * exact / n, 0.01), "gt_0p1mm_pct": snappedf(100.0 * gt[0] / n, 0.01),
		"gt_1mm_pct": snappedf(100.0 * gt[1] / n, 0.01), "gt_1cm_pct": snappedf(100.0 * gt[2] / n, 0.01),
		"mode_flip_pct": snappedf(100.0 * mode_flip / n, 0.01), "p50_m": errs[n / 2], "p99_m": errs[mini(n - 1, n * 99 / 100)],
		"max_m": errs[n - 1], "modes": modes.keys(), "wall_jumps": wall_jumps, "wallrun_ticks": wallrun_ticks, "ladder_ticks": ladder_ticks}
	print("PARITY " + JSON.stringify(r))
	return r


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		match args[i]:
			"--hz": _hzs = Array(args[i + 1].split(",")).map(func(x): return int(x))
			"--seconds": _seconds = float(args[i + 1])
			"--window": _window = float(args[i + 1])
	_build_world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	for hz: int in _hzs:
		_probe("wall_run", Vector3(26, 1.5, 0), Vector3(0, 0, -10), 5, 1, hz)
		_probe("corner", Vector3(27, 0.05, 27), Vector3(3, 0, 3), 11, 1, hz)
		_probe("stairs", Vector3(0, 0.05, -2), Vector3(0, 0, -3), 9, 1, hz)
		_probe("ramps", Vector3(-20, 0.05, -2), Vector3(0, 0, -6), 3, 1, hz)
		_probe("pillars", Vector3(-14, 0.05, 6), Vector3(4, 0, 0), 8, 1, hz)
		_probe("surf_slab", Vector3(14, 6, 2), Vector3(0, 0, 6), 6, 1, hz)
		_probe("floor_run", Vector3(0, 0.05, 0), Vector3.ZERO, 1, 1, hz)
		_probe("ladder", Vector3(-27.5, 0.05, 0), Vector3.ZERO, 0, 9, hz)
		_probe("wall_jump", Vector3(-24, 0.05, -24), Vector3.ZERO, 0, 10, hz)
	print("PARITY_DONE")
	get_tree().quit(0)
