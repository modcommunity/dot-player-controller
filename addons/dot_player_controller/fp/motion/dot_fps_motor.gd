class_name DotFpsMotor
extends "dot_fps_motor_walls.gd"

## The movement simulation. Deterministic, engine-independent, and the only place movement rules live.
##
## [codeblock]
## var motor := DotFpsMotor.new(tunables, body)
## motor.simulate(state, command, 1.0 / 60.0)
## [/codeblock]
##
## The contract: the same [DotFpsState], [DotFpsCommand], delta and world give the same result on every machine, which is what lets a client predict and a server agree. Break it and reconciliation corrects every tick like packet loss.
## So nothing here may read the keyboard, wall clock, unseeded random, frame rate or any node's transform: time is [param delta], intent is the command, the world is [DotFpsBody].
## The model is the classic one: ground acceleration with friction, and air acceleration capped at a small absolute speed, which is what air-strafing and bunny-hopping are. See [method accelerate].


func _init(p_tunables: DotFpsTunables, p_body: DotFpsBody) -> void:
	tunables = p_tunables
	body = p_body
	_surface = DotFpsSurface.make(&"default")


## Switches mode, running the exit and enter hooks.
## The only supported way to change [member DotFpsState.mode]: assigning it skips the hooks, so a mode that allocated something in [method DotFpsMoveMode._enter] is never told to release it.
func set_mode(state: DotFpsState, id: int) -> void:
	if state.mode == id:
		return

	var leaving := mode_for(state.mode)
	if leaving != null:
		leaving._exit(state, self)

	state.mode = id

	var entering := mode_for(id)
	if entering != null:
		entering._enter(state, self)


## Advances [param state] by one tick under [param command].
## The order is load-bearing: the ground is categorised before acceleration so friction fits the surface stood on, and again after the move for the next tick. Swapped, the first airborne tick uses ground friction and a jump gains no speed.
func simulate(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	if delta <= 0.0:
		return
	body.begin_tick()
	if not _simulate_head(state, command, delta):
		_simulate_tail(state, command, delta, false)
	body.end_tick()


## [method batch_prepare]'s answers: the tick is over, the caller runs [method batch_resume], or the row is filled for dot-sim's batch.
const BATCH_DONE := 0
const BATCH_DEFER := 1
const BATCH_READY := 2

## After a [constant BATCH_READY] answer: the native body and tunables of the row.
var batch_body: Object = null
var batch_tun := PackedFloat64Array()


## The start of [method simulate] for a tick that may run in dot-sim's batch with other players' ([DotFpsMotorBatch]): everything
## before the first world query that depends on another player. On [constant BATCH_READY] row [param row] of [param input]
## (55 values) and [param meta] (3) is filled and [method batch_apply] ends the tick; on [constant BATCH_DEFER]
## [method batch_resume] does, the same way [method simulate] would have.
func batch_prepare(
	state: DotFpsState, command: DotFpsCommand, delta: float, input: PackedFloat64Array, meta: PackedInt64Array, row: int
) -> int:
	body.begin_tick()
	if _simulate_head(state, command, delta):
		body.end_tick()
		return BATCH_DONE
	if profile:
		_lap(0)
	_update_crouch(state, command, delta)
	if profile:
		_lap(1)
	# A walker that may take the idle path asks the world its own way: left to the single tick.
	if profile or (idle_fast_path and _rest_valid and command.move == Vector2.ZERO and command.buttons == 0):
		return BATCH_DEFER
	var tick_tun := _native_tick_tun(state)
	if tick_tun.is_empty() or not native_full:
		return BATCH_DEFER
	batch_body = body.native_batch(meta, row * 3)
	if batch_body == null:
		return BATCH_DEFER
	batch_tun = _native_full_tun(tick_tun)
	_fill_full_in(state, command, delta, input, row * 55)
	return BATCH_READY


## Row [param row] again from the state as it is now (something moved the player after [method batch_prepare]).
func batch_refill(state: DotFpsState, command: DotFpsCommand, delta: float, input: PackedFloat64Array, row: int) -> void:
	_fill_full_in(state, command, delta, input, row * 55)


## Ends a [constant BATCH_READY] tick with the batch's answer, the 45 values at [param at] in [param out].
func batch_apply(state: DotFpsState, command: DotFpsCommand, out: PackedFloat64Array, at: int) -> void:
	var r := out.slice(at, at + 45)
	body.native_batch_done(int(r[20]), int(r[21]), int(r[22]))
	_native_full_apply(state, r)
	state.previous_buttons = command.buttons
	body.end_tick()


## Ends a [constant BATCH_DEFER] tick, or a [constant BATCH_READY] one the batch had no answer for, in this motor.
func batch_resume(state: DotFpsState, command: DotFpsCommand, delta: float) -> void:
	_simulate_tail(state, command, delta, true)
	body.end_tick()


## Drops a prepared tick whose player will not tick after all.
func batch_cancel() -> void:
	body.end_tick()


## The tick up to where a custom mode or noclip ends it (true) or the walker's tick starts (false).
func _simulate_head(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> bool:
	if profile:
		_lap_at = Time.get_ticks_usec()
	view_turn = 0.0

	ticks_simulated += 1
	state.tick += 1

	# View is authoritative from the command and never integrated locally: a replay
	# has to reproduce the exact angles the tick was simulated with.
	state.yaw = command.yaw
	state.pitch = clampf(command.pitch, tunables.pitch_min, tunables.pitch_max)

	_advance_timers(state, command, delta)

	# Before anything reads a scale: the aggregate is what friction, acceleration,
	# gravity and jumping are all multiplied by this tick.
	_expire_modifiers(state)
	_rebuild_effects(state)

	_update_noclip(state, command)

	# Noclip or a game's own mode (water, a ladder) ends a wall run: those modes own their
	# whole tick, and a run left on would keep the view rolled while swimming.
	if state.is_wall_running() and state.mode >= DotFpsState.Mode.NOCLIP:
		_end_wall_run(state)

	# A custom mode owns its whole tick — gravity, acceleration, collision — because
	# a ladder that had gravity applied behind its back would have to cancel a force
	# it never asked for. See DotFpsMoveMode.
	_rest_valid = _rest_valid and state.mode == DotFpsState.Mode.GROUND
	var custom := mode_for(state.mode)

	if custom != null:
		if custom._uses_crouch():
			_update_crouch(state, command, delta)

		custom._simulate(state, command, delta, self)
		state.previous_buttons = command.buttons
		return true

	if state.mode == DotFpsState.Mode.NOCLIP:
		_simulate_noclip(state, command, delta)
		state.previous_buttons = command.buttons
		return true
	return false


## The walker's tick; [param crouched] when [method batch_prepare] has already run the crouch.
func _simulate_tail(state: DotFpsState, command: DotFpsCommand, delta: float, crouched: bool) -> void:
	if not crouched:
		if profile:
			_lap(0)
		_update_crouch(state, command, delta)
		if profile:
			_lap(1)

	if idle_fast_path and _idle_tick(state, command):
		state.previous_buttons = command.buttons
		return

	# The tick's start and end in dot-sim when it can (see [member native_tick]); empty to run them here.
	var tick_tun := _native_tick_tun(state)
	if not tick_tun.is_empty() and native_full and _native_tick_full(state, command, delta, tick_tun):
		if profile:
			_lap(7)
		state.previous_buttons = command.buttons
		return
	var start_settled := false
	if tick_tun.is_empty() or not _native_tick_pre(state, tick_tun):
		# Before the ground is categorised, because a probe starting inside geometry reports nothing and the whole tick is built on that answer.
		# Unconditional: the case it exists for is a player in AIR on a ramp, which every earlier guard excluded.
		_depenetrate(state, _height(state))
		if profile:
			_lap(2)

		# A reused stamp skipped the probe, so it cannot vouch for the end of the tick: a stationary body would re-stamp itself for ever
		# and never see its floor go. `start_settled` stays false then, the end check runs, and the next tick's start probes again.
		if not _reuse_rest(state):
			start_settled = _categorise_ground_settled(state)
	else:
		start_settled = _native_start_settled
		if profile:
			_lap(2)
	var start_position := state.position
	var start_velocity := state.velocity
	var start_height := _height(state)
	if profile:
		_lap(3)

	var jumped := _try_jump(state, command, delta)

	# The wall, probed once a tick and only when a wall move could use it: both are off
	# by default, and a game that leaves them off makes no extra query and simulates what
	# it did before they existed.
	if profile:
		_lap(4)
	var wall := _wall_contact(state, command)
	var wall_jumped := false
	if not jumped and not _try_jump_run(state, wall):
		wall_jumped = _try_wall_jump(state, command, wall)
		if not wall_jumped and not jumped:
			_try_auto_run(state, command, wall)

	if profile:
		_lap(5)
	var launched := _try_launch(state, command)
	launched = _try_dash(state, command) or launched

	# After the jump and the launch, because both end a slide by leaving the ground, and
	# before friction, because a slide is what decides which friction this tick gets.
	_update_slide(state, command, delta, jumped or launched)
	_update_wall_run(state, command, delta, wall, jumped or wall_jumped or launched)

	if (
		not tick_tun.is_empty() and not state.is_wall_running()
		and _native_tick_post(state, command, delta, tick_tun, jumped or launched, wall, start_settled, start_position, start_velocity)
	):
		if profile:
			_lap(7)
		state.previous_buttons = command.buttons
		return

	if state.mode == DotFpsState.Mode.GROUND and not jumped and not launched:
		_apply_friction(state, delta)
	elif tunables.air_friction > 0.0:
		_apply_air_friction(state, delta)

	_ground_cap = 0.0
	_apply_wish_move(state, command, delta)

	if state.mode == DotFpsState.Mode.GROUND:
		# A conveyor, a slick slope, a wind volume. Applied as an acceleration rather
		# than as a velocity so it composes with friction instead of fighting it.
		if _surface.push != Vector3.ZERO:
			state.velocity += _surface.push * delta
			# Environment motion is not wall-creep: let the cap rise by the horizontal push
			# only; a vertical component cannot move the walker along the ground.
			if _ground_cap > 0.0:
				_ground_cap += Vector2(_surface.push.x, _surface.push.z).length() * delta
	elif state.is_wall_running():
		_wall_run_vertical(state, delta)
	else:
		var falling_at := state.velocity.y
		state.velocity.y -= tunables.gravity * _effects.gravity * delta
		if _wall_slides(state, command, wall):
			_wall_slide_vertical(state, falling_at, delta)

	_clamp_velocity(state)
	if profile:
		_lap(6)
	var settled := _move(state, delta, jumped or launched)
	if profile:
		_lap(7)

	# After the move, so the next tick starts from the truth, unless the move's own check already is that truth:
	# a grounded walker's [method _move] categorises after the slide, and if that changed only the ground fields and left it GROUNDED, running it again repeats the same queries ([method _categorise_ground_settled]).
	# Likewise a walker who did not move: the start's check was a fixed point. It saves one ground probe a tick per walker.
	if settled or (
		start_settled and state.mode == DotFpsState.Mode.GROUND
		and state.position == start_position and state.velocity == start_velocity
		and _height(state) == start_height
	):
		settled_ground_ticks += 1
		_stamp_rest(state)
	else:
		_rest_valid = false
		_categorise_ground(state)
	if profile:
		_lap(8)

	state.previous_buttons = command.buttons


## [member native_tick]'s tunables for this tick, or empty when this tick may not run natively.
func _native_tick_tun(state: DotFpsState) -> PackedFloat64Array:
	if (
		not native_tick or surfaces != null or tunables.edge_friction > 1.0
		or (state.mode != DotFpsState.Mode.GROUND and state.mode != DotFpsState.Mode.AIR)
	):
		return PackedFloat64Array()
	if tunables.get_instance_id() != _tun_for or tunables.revision != _tun_rev:
		_tun_cache = _build_tick_tun()
		_tun_full_cache = PackedFloat64Array()
		_tun_for = tunables.get_instance_id()
		_tun_rev = tunables.revision
	return _tun_cache


## [method _native_tick_tun]'s array and [method _native_full_tun]'s, kept until [member tunables] or one of its values
## changes ([member DotFpsTunables.revision]): rebuilding them was a per-tick copy of about 75 values per player.
var _tun_cache := PackedFloat64Array()
var _tun_full_cache := PackedFloat64Array()
var _tun_for := 0
var _tun_rev := -1


func _build_tick_tun() -> PackedFloat64Array:
	return PackedFloat64Array([
		tunables.max_slide_iterations, 1.0 if tunables.crease_slide else 0.0, tunables.skin_width,
		tunables.max_slide_planes, tunables.step_height, tunables.radius, tunables.max_slope_radians(),
		tunables.jump_velocity(), 1.0 if tunables.ground_snap else 0.0, tunables.ground_snap_distance,
		tunables.crest_launch_speed_scale, tunables.max_speed, tunables.stop_speed, tunables.air_friction,
		tunables.max_velocity, tunables.backward_speed_scale, tunables.max_air_wish_speed,
		tunables.wall_slide_speed, tunables.wall_run_vertical_damping,
	])


## The start ground check's answer from [method _native_tick_pre].
var _native_start_settled := false


## [method _depenetrate], [method _reuse_rest] and [method _categorise_ground_settled] in one native call; false (nothing
## written) when the body cannot. The script decides everything [method _reuse_rest] compares but the position, which the
## native depenetration may move.
func _native_tick_pre(state: DotFpsState, tun: PackedFloat64Array) -> bool:
	var height := _height(state)
	var rest_ok := _native_rest_ok(state, height)
	var p := state.position
	var v := state.velocity
	var n := state.ground_normal
	var id := state.ground_id
	var r := body.native_tick(0, PackedFloat64Array([
		p.x, p.y, p.z, v.x, v.y, v.z, n.x, n.y, n.z, state.mode, id & 0xFFFFFFFF, id >> 32, height,
		1.0 if rest_ok else 0.0, _rest_position.x, _rest_position.y, _rest_position.z,
	]), tun)
	if r.size() < 23:
		return false
	_rest_valid = false
	var flags := _native_tick_apply(state, r)
	# As in [method simulate]: a reused start proves nothing about the end of the tick.
	_native_start_settled = flags & 1 != 0 and flags & 2 == 0
	if flags & 2 != 0:
		reused_ground_ticks += 1
	return true


## Whether [method _reuse_rest] may reuse the last rest, for the native start: all it compares but the position.
func _native_rest_ok(state: DotFpsState, height: float) -> bool:
	return (
		_rest_valid and state.mode == DotFpsState.Mode.GROUND
		and state.velocity == _rest_velocity
		and state.ground_normal == _rest_normal and state.ground_id == _rest_ground_id
		and state.surface == _rest_surface and height == _rest_height
		and _rest_ground_unmoved()
	)


## The move tunables [method _native_tick_full] sends after the tick ones.
func _native_full_tun(tun: PackedFloat64Array) -> PackedFloat64Array:
	if not _tun_full_cache.is_empty():
		return _tun_full_cache
	var t := tunables
	var full := tun.duplicate()
	full.append_array(PackedFloat64Array([
		t.can_jump, t.auto_hop, t.jump_buffer_time, t.jump_cooldown, t.coyote_time, t.bhop_speed_cap_scale,
		t.jump_adds_to_velocity,
		t.launch_enabled, t.launch_button, t.launch_from_air, t.launch_velocity, t.launch_forward, t.launch_cooldown,
		t.dash_enabled, t.dash_button, t.dash_from_air, t.dash_speed, t.dash_cooldown, t.dash_lift,
		t.slide_enabled, t.slide_duration, t.slide_end_speed, t.can_crouch, t.slide_requires_sprint,
		t.slide_min_speed, t.slide_boost, t.slide_max_speed, t.slide_cooldown,
		t.friction, t.slide_friction, t.accelerate, t.slide_accelerate,
		t.wall_run_enabled, t.wall_jump_enabled, t.wall_run_auto, t.wall_run_on_jump, t.wall_run_jump_min_speed,
		t.wall_run_min_speed, t.wall_max_angle_from_vertical, t.wall_reach, t.wall_run_max_time,
		t.wall_run_end_speed, t.wall_run_requires_forward, t.wall_run_max_fall_speed,
		t.wall_run_max_approach_angle, t.wall_run_min_height, t.wall_run_min_length, t.wall_run_cooldown,
		t.wall_run_jump_max_angle, t.wall_run_turn_view, t.wall_run_turn_view_max_angle,
		t.wall_jump_max_per_wall, t.wall_jump_max_per_air, t.wall_jump_look_blend, t.wall_jump_push_speed,
		t.wall_jump_up_speed,
	]))
	_tun_full_cache = full
	return full


## [method _native_tick_full]'s input, kept and refilled each tick.
var _full_in := PackedFloat64Array()


## The whole tick from the start ground check to the end one in one native call: the halves and every move between;
## false (nothing written) when the body cannot.
func _native_tick_full(state: DotFpsState, command: DotFpsCommand, delta: float, tun: PackedFloat64Array) -> bool:
	var a := _full_in
	if a.size() != 55:
		a.resize(55)
	_fill_full_in(state, command, delta, a, 0)
	var r := body.native_tick(2, a, _native_full_tun(tun))
	if r.size() < 45:
		return false
	_native_full_apply(state, r)
	return true


## The whole tick's input, 55 values from [param o] in [param a] (set by index: a literal built a Variant Array of every value, each tick).
func _fill_full_in(state: DotFpsState, command: DotFpsCommand, delta: float, a: PackedFloat64Array, o: int) -> void:
	var height := _height(state)
	var p := state.position
	var v := state.velocity
	var n := state.ground_normal
	var id := state.ground_id
	var push := _surface.push
	var w := state.wall_normal
	var buttons := command.buttons if state.sprinting else command.buttons & ~DotFpsCommand.BUTTON_SPRINT
	var effects := (
		(1 if _effects.deny_move else 0) | (2 if _effects.deny_jump else 0) | (4 if _effects.deny_crouch else 0)
	)
	a[o + 0] = p.x
	a[o + 1] = p.y
	a[o + 2] = p.z
	a[o + 3] = v.x
	a[o + 4] = v.y
	a[o + 5] = v.z
	a[o + 6] = n.x
	a[o + 7] = n.y
	a[o + 8] = n.z
	a[o + 9] = state.mode
	a[o + 10] = id & 0xFFFFFFFF
	a[o + 11] = id >> 32
	a[o + 12] = height
	a[o + 13] = 1.0 if _native_rest_ok(state, height) else 0.0
	a[o + 14] = _rest_position.x
	a[o + 15] = _rest_position.y
	a[o + 16] = _rest_position.z
	a[o + 17] = delta
	a[o + 18] = command.buttons
	a[o + 19] = state.previous_buttons
	a[o + 20] = command.move.x
	a[o + 21] = command.move.y
	a[o + 22] = state.yaw
	a[o + 23] = effects
	a[o + 24] = _effects.jump
	a[o + 25] = tunables.jump_velocity() * _surface.jump_scale * _effects.jump
	a[o + 26] = tunables.speed_for(buttons, load_fraction)
	a[o + 27] = _effects.max_speed
	a[o + 28] = _surface.max_speed_scale
	a[o + 29] = _surface.friction_scale
	a[o + 30] = _effects.friction
	a[o + 31] = _surface.accelerate_scale
	a[o + 32] = _effects.accelerate
	a[o + 33] = tunables.air_accelerate * _effects.air_accelerate
	a[o + 34] = push.x
	a[o + 35] = push.y
	a[o + 36] = push.z
	a[o + 37] = tunables.gravity * _effects.gravity
	a[o + 38] = tunables.gravity * tunables.wall_run_gravity_scale * _effects.gravity
	a[o + 39] = state.time_since_jump
	a[o + 40] = state.time_since_grounded
	a[o + 41] = state.time_since_jump_pressed
	a[o + 42] = state.slide_time
	a[o + 43] = state.slide_cooldown_left
	a[o + 44] = state.launch_cooldown_left
	a[o + 45] = state.dash_cooldown_left
	a[o + 46] = state.wall_run_cooldown_left
	a[o + 47] = state.wall_run_time
	a[o + 48] = 1.0 if state.wall_run_spent else 0.0
	a[o + 49] = state.wall_jump_count
	a[o + 50] = state.wall_jumps_in_air
	a[o + 51] = state.wall_jump_heading
	a[o + 52] = w.x
	a[o + 53] = w.y
	a[o + 54] = w.z


## Writes a whole native tick's 45 values into the state and the counters.
func _native_full_apply(state: DotFpsState, r: PackedFloat64Array) -> void:
	_rest_valid = false
	var flags := _native_tick_apply(state, r)
	if flags & 2 != 0:
		reused_ground_ticks += 1
	if flags & 16 != 0:
		DotLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
	if flags & 8 != 0:
		settled_ground_ticks += 1
		_stamp_rest(state)
	state.time_since_jump = r[23]
	state.time_since_grounded = r[24]
	state.time_since_jump_pressed = r[25]
	state.slide_time = r[26]
	state.slide_cooldown_left = r[27]
	state.launch_cooldown_left = r[28]
	state.dash_cooldown_left = r[29]
	state.wall_run_cooldown_left = r[30]
	state.wall_run_time = r[31]
	state.wall_run_spent = r[32] != 0.0
	state.wall_jump_count = int(r[33])
	state.wall_jumps_in_air = int(r[34])
	state.wall_jump_heading = int(r[35])
	state.wall_normal = Vector3(r[36], r[37], r[38])
	view_turn = r[39]
	slides += int(r[40])
	launches += int(r[41])
	dashes += int(r[42])
	wall_runs += int(r[43])
	wall_jumps += int(r[44])


## From friction to the end ground check in one native call; false (nothing written) when the body cannot.
func _native_tick_post(
	state: DotFpsState, command: DotFpsCommand, delta: float, tun: PackedFloat64Array, jumped: bool,
	wall: DotFpsBody.Hit, start_settled: bool, start_position: Vector3, start_velocity: Vector3
) -> bool:
	if state.mode != DotFpsState.Mode.GROUND and state.mode != DotFpsState.Mode.AIR:
		return false
	var sliding := state.is_sliding()
	var buttons := command.buttons if state.sprinting else command.buttons & ~DotFpsCommand.BUTTON_SPRINT
	var flags := (
		(1 if jumped else 0) | (2 if sliding else 0) | (4 if _effects.deny_move else 0)
		| (8 if _wall_slide_ok(state, command, wall) else 0) | (16 if start_settled else 0)
	)
	var p := state.position
	var v := state.velocity
	var n := state.ground_normal
	var id := state.ground_id
	var push := _surface.push
	var r := body.native_tick(1, PackedFloat64Array([
		p.x, p.y, p.z, v.x, v.y, v.z, n.x, n.y, n.z, state.mode, id & 0xFFFFFFFF, id >> 32, _height(state),
		delta, flags, command.move.x, command.move.y, state.yaw,
		tunables.speed_for(buttons, load_fraction), _effects.max_speed, _surface.max_speed_scale,
		tunables.slide_friction if sliding else tunables.friction, _surface.friction_scale, _effects.friction,
		(tunables.slide_accelerate if sliding else tunables.accelerate) * _surface.accelerate_scale * _effects.accelerate,
		tunables.air_accelerate * _effects.air_accelerate,
		push.x, push.y, push.z, tunables.gravity * _effects.gravity,
		start_position.x, start_position.y, start_position.z, start_velocity.x, start_velocity.y, start_velocity.z,
	]), tun)
	if r.size() < 23:
		return false
	var out := _native_tick_apply(state, r)
	if out & 16 != 0:
		DotLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
	if out & 8 != 0:
		settled_ground_ticks += 1
		_stamp_rest(state)
	else:
		_rest_valid = false
	return true


## Writes a native tick half's answer to [param state] and the counters; returns its flags.
func _native_tick_apply(state: DotFpsState, r: PackedFloat64Array) -> int:
	state.position = Vector3(r[0], r[1], r[2])
	state.velocity = Vector3(r[3], r[4], r[5])
	state.ground_normal = Vector3(r[6], r[7], r[8])
	state.mode = int(r[9])
	state.ground_id = int(r[10]) | (int(r[11]) << 32)
	var flags := int(r[12])
	if flags & 4 != 0:
		state.surface = &""
	depenetrated_ticks += int(r[13])
	embedded_ticks += int(r[14])
	lifted_ticks += int(r[15])
	stuck_ticks += int(r[16])
	duplicate_plane_ticks += int(r[17])
	crease_leg_ticks += int(r[18])
	split_leg_ticks += int(r[19])
	return flags


## The whole tick for a walker standing still on the floor the last tick proved, or false (nothing written) when anything differs.
## Same answers as the full path, which for such a tick changes nothing: wish, velocity and buttons are zero, so only the world can differ, and two queries ask it (embedded? floor still there?).
func _idle_tick(state: DotFpsState, command: DotFpsCommand) -> bool:
	if (
		not _rest_valid or command.move != Vector2.ZERO or command.buttons != 0
		or state.previous_buttons != 0 or state.mode != DotFpsState.Mode.GROUND
		or state.velocity != Vector3.ZERO or state.is_sliding() or state.is_wall_running()
		or state.position != _rest_position or state.velocity != _rest_velocity
		or state.ground_normal != _rest_normal or state.ground_id != _rest_ground_id
		or state.surface != _rest_surface or _height(state) != _rest_height
		or not state.modifiers.is_empty() or _surface.push != Vector3.ZERO
		or tunables.wall_run_enabled or tunables.wall_jump_enabled
		or not _rest_ground_unmoved()
	):
		return false

	_idle_streak += 1
	if idle_full_every > 0 and _idle_streak >= idle_full_every:
		_idle_streak = 0
		_rest_valid = false
		return false

	var height := _rest_height
	var centre := _capsule_centre(state.position, height)
	var resting := body.rest_contact(centre, height, tunables.radius)
	if resting.hit and resting.depth > 0.0:
		return false

	var probe := Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02)
	var hit := _ground_probe(centre, probe, height)
	if (
		not hit.hit or hit.collider_id != _rest_ground_id or hit.normal != _rest_normal
		or probe.length() * hit.fraction < tunables.skin_width * 0.5
	):
		_idle_streak = 0
		_rest_valid = false
		return false

	_resolve_surface(state)
	idle_ticks += 1
	settled_ground_ticks += 1
	return true


## Remembers the state a settled ground check just proved, for [method _reuse_rest].
func _stamp_rest(state: DotFpsState) -> void:
	_rest_valid = reuse_settled_ground and state.mode == DotFpsState.Mode.GROUND
	_rest_position = state.position
	_rest_velocity = state.velocity
	_rest_height = _height(state)
	_rest_normal = state.ground_normal
	_rest_ground_id = state.ground_id
	_rest_surface = state.surface
	_rest_ground_node = _ground_node(state.ground_id)
	if _rest_ground_node != null:
		_rest_ground_xform = _rest_ground_node.global_transform


## Horizontal speed a blocked ground walk may keep this tick; 0 when the tick has no ground wish.
var _ground_cap := 0.0

var _rest_ground_node: Node3D = null
var _rest_ground_xform := Transform3D.IDENTITY


## The ground collider as a node, or null when it is not one (a stamp then never compares transforms).
func _ground_node(id: int) -> Node3D:
	return body.collider_node(id) if id != 0 else null


## Whether the state is the one the last tick ended on after a settled ground check, so the start-of-tick check would repeat its queries.
## Only the world can differ between ticks; the stamp is dropped on any other change, so a mover carrying its rider is still probed.
func _reuse_rest(state: DotFpsState) -> bool:
	if not _rest_valid:
		return false
	_rest_valid = false
	if (
		state.mode == DotFpsState.Mode.GROUND
		and state.position == _rest_position and state.velocity == _rest_velocity
		and state.ground_normal == _rest_normal and state.ground_id == _rest_ground_id
		and state.surface == _rest_surface and _height(state) == _rest_height
		and _rest_ground_unmoved()
	):
		reused_ground_ticks += 1
		return true
	return false


## False when the ground collider was moved since the stamp (a teleported platform leaves
## from under a rider whose own state does not change), or has been freed or left the tree.
func _rest_ground_unmoved() -> bool:
	if _rest_ground_node == null:
		return true
	if not is_instance_valid(_rest_ground_node) or not _rest_ground_node.is_inside_tree():
		return false
	return _rest_ground_node.global_transform == _rest_ground_xform


func _advance_timers(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	state.time_since_jump = minf(state.time_since_jump + delta, TIMER_CAP)

	if state.mode == DotFpsState.Mode.GROUND:
		state.time_since_grounded = 0.0
		# Counted in TICKS, not seconds: "jumped on the tick the player landed" is a perfect
		# bunny-hop, and a seconds counter answers that differently at 64 Hz and 128 Hz.
		state.ground_ticks += 1

		if tunables.wall_run_enabled or tunables.wall_jump_enabled:
			_reset_walls(state)
	else:
		state.time_since_grounded = minf(state.time_since_grounded + delta, TIMER_CAP)
		state.ground_ticks = 0

	var jump_pressed := (
		(command.buttons & ~state.previous_buttons) & DotFpsCommand.BUTTON_JUMP
	) != 0

	if jump_pressed:
		state.time_since_jump_pressed = 0.0
	else:
		state.time_since_jump_pressed = minf(state.time_since_jump_pressed + delta, TIMER_CAP)

	state.slide_cooldown_left = maxf(state.slide_cooldown_left - delta, 0.0)
	state.launch_cooldown_left = maxf(state.launch_cooldown_left - delta, 0.0)
	state.dash_cooldown_left = maxf(state.dash_cooldown_left - delta, 0.0)
	state.wall_run_cooldown_left = maxf(state.wall_run_cooldown_left - delta, 0.0)
	_tick_stamina(state, command, delta)
	# Without stamina the fields are written to their constants (1, false, 0) above, which are exactly on the wire grid: packing and unpacking them is the identity.
	if tunables.stamina_enabled or not perf_caches:
		DotFpsNetSync.snap_stamina(state)


## Decides whether this tick sprints and moves stamina. Crouch and walk win over sprint, as in speed_for.
func _tick_stamina(state: DotFpsState, command: DotFpsCommand, delta: float) -> void:
	var t := tunables
	var wants: bool = (
		t.can_sprint and (command.buttons & DotFpsCommand.BUTTON_SPRINT) != 0
		and command.move.length_squared() > 0.0001 and not _effects.deny_move
		and not (t.can_crouch and (command.buttons & DotFpsCommand.BUTTON_CROUCH))
		and not (t.can_walk and (command.buttons & DotFpsCommand.BUTTON_WALK))
	)
	if not t.stamina_enabled:
		state.sprinting = wants
		state.stamina = 1.0
		state.stamina_exhausted = false
		state.stamina_delay_left = 0.0
		return

	state.sprinting = wants and not state.stamina_exhausted and state.stamina > 0.0
	if state.sprinting:
		var load := clampf(load_fraction, 0.0, 1.0)
		state.stamina -= t.stamina_drain * (1.0 + load * t.sprint_load_drain) * delta
		if state.stamina <= 0.0:
			state.stamina = 0.0
			state.stamina_exhausted = true
			state.stamina_delay_left = t.stamina_exhaust_delay
		return

	state.stamina_delay_left = maxf(state.stamina_delay_left - delta, 0.0)
	if state.stamina_delay_left <= 0.0:
		state.stamina = minf(state.stamina + t.stamina_recover * delta, 1.0)
	if state.stamina_exhausted and state.stamina >= t.stamina_resume_at and state.stamina_delay_left <= 0.0:
		state.stamina_exhausted = false


func _update_noclip(state: DotFpsState, command: DotFpsCommand) -> void:
	# Before the ability gate, because here somebody else decided: an administrator's noclip arrives as a modifier ([code]forces_noclip[/code]) in replicated state,
	# so this runs identically on the server and in a replay, and the held button is ignored while it is in force.
	if _effects.force_noclip:
		if state.mode != DotFpsState.Mode.NOCLIP:
			state.mode = DotFpsState.Mode.NOCLIP
			state.velocity = Vector3.ZERO
		return

	if not (tunables.can_noclip or _effects.grant_noclip):
		# The bit may still be set — a client can put anything in a command. Leaving
		# noclip on a state that entered it before the ability was revoked would let
		# a player keep flying, so it is cleared here rather than only ignored.
		if state.mode == DotFpsState.Mode.NOCLIP:
			state.mode = DotFpsState.Mode.AIR
		return

	var toggled := (
		(command.buttons & ~state.previous_buttons) & DotFpsCommand.BUTTON_NOCLIP
	) != 0

	if not toggled:
		return

	if state.mode == DotFpsState.Mode.NOCLIP:
		state.mode = DotFpsState.Mode.AIR
		state.velocity = Vector3.ZERO
	else:
		state.mode = DotFpsState.Mode.NOCLIP
		state.velocity = Vector3.ZERO


## Free flight. No collision, no gravity, and the only mode where pitch moves you.
func _simulate_noclip(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	var basis := _view_basis(state.yaw, state.pitch)

	var wish := (
		basis.right * command.move.x + basis.forward * command.move.y
	).limit_length(1.0) * tunables.noclip_speed

	if command.is_pressed(DotFpsCommand.BUTTON_JUMP):
		wish.y += tunables.noclip_speed
	if command.is_pressed(DotFpsCommand.BUTTON_CROUCH):
		wish.y -= tunables.noclip_speed

	# A root holds in noclip too. Without this a frozen player who is also noclipped —
	# the ordinary order an admin does the two in — flies away from the freeze.
	if _effects.deny_move:
		wish = Vector3.ZERO

	# Eased rather than snapped so noclip is usable for lining up a screenshot, and
	# framed as an exponential decay so it is frame-rate independent.
	var t := clampf(tunables.noclip_accelerate * delta, 0.0, 1.0)
	state.velocity = state.velocity.lerp(wish, t)

	state.position += state.velocity * delta
	state.crouch_fraction = 0.0


## Moves the crouch fraction toward what the player is holding, if it fits.
## Standing up is attempted, tested and abandoned for this tick if it does not fit, so a player under a low ceiling stays crouched and stands once clear.
func _update_crouch(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	state.crouch_held = (
		tunables.can_crouch
		and not _effects.deny_crouch
		and command.is_pressed(DotFpsCommand.BUTTON_CROUCH)
	)

	var target := 1.0 if state.crouch_held else 0.0

	if is_equal_approx(state.crouch_fraction, target):
		state.crouch_fraction = target
		return

	var airborne := state.mode != DotFpsState.Mode.GROUND
	var instant := tunables.crouch_transition_time <= 0.0 or (
		airborne and tunables.instant_air_crouch and state.crouch_held
	)

	var next := target
	if not instant:
		var rate := 1.0 / tunables.crouch_transition_time
		next = move_toward(state.crouch_fraction, target, rate * delta)

	if next >= state.crouch_fraction:
		# Getting smaller. Always fits.
		_set_crouch(state, next, airborne)
		return

	# Getting larger: the capsule has to have somewhere to grow into.
	var height := tunables.height_at(next)
	var probe := _capsule_centre(_position_for_crouch(state, next, airborne), height)

	if body.overlaps(probe, height, tunables.radius):
		# Blocked. Hold at the current fraction and try again next tick; the player
		# is under something and standing would put them inside it.
		return

	_set_crouch(state, next, airborne)


## Applies a new crouch fraction, moving the body to keep the right end fixed.
## On the ground the feet stay put and the head moves; airborne the head stays put and the feet come up (the crouch-jump, which clears a ledge a standing jump cannot).
func _set_crouch(state: DotFpsState, fraction: float, airborne: bool) -> void:
	state.position = _position_for_crouch(state, fraction, airborne)
	state.crouch_fraction = fraction


func _position_for_crouch(
	state: DotFpsState,
	fraction: float,
	airborne: bool
) -> Vector3:
	if not airborne:
		return state.position

	var current := tunables.height_at(state.crouch_fraction)
	var wanted := tunables.height_at(fraction)

	var moved := state.position
	moved.y += current - wanted
	return moved


## Decides whether the player is standing on something.
## A short downward sweep, not a contact list: contacts belong to the last physics step and this must answer mid-slide.
func _categorise_ground(state: DotFpsState) -> void:
	_categorise_ground_settled(state)


## [method _categorise_ground], answering whether this call was a fixed point: a second call on the state it leaves would make the same queries and write the same values.
## True only on the floor branch, for a player GROUNDED on entry whose position and velocity it did not touch (no [method _keep_skin] lift, no slide onto the floor); every other branch answers false and is run again.
func _categorise_ground_settled(state: DotFpsState) -> bool:
	if state.mode == DotFpsState.Mode.NOCLIP:
		return false

	var was_grounded := state.mode == DotFpsState.Mode.GROUND
	var position_in := state.position
	var velocity_in := state.velocity
	var rising := state.velocity.y > LEAVING_SPEED

	# Moving upward fast enough to have left the ground is not on it, or the tick a jump starts counts as grounded and the jump loses most of its height.
	# Upward is not away from the ground: walking up 18 degrees at 6.5 m/s is 2 m/s upward ALONG the surface, so a grounded player is asked against the plane, and a slow airborne rise (0.4 m/s on 13 degrees) is probed too.
	# Only a rise of more than half a jump's launch skips the query, which keeps a bunny-hopper crossing a walkable ramp from being put on it.
	if rising and not was_grounded and (
		state.velocity.y > maxf(tunables.jump_velocity() * 0.5, LEAVING_SPEED)
	):
		state.mode = DotFpsState.Mode.AIR
		state.ground_normal = Vector3.UP
		state.ground_id = 0
		return false

	var height := _height(state)
	var centre := _capsule_centre(state.position, height)
	var probe := Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02)

	var hit := _ground_probe(centre, probe, height)
	var floor_normal := _standable_normal(state, hit)

	# A face too steep to stand on is asked again, in quarters (`[steep-climb-1]`): a capsule pressed against a leaning face touches it with its rounded bottom,
	# so the probe reports the face, not the floor, and air acceleration carried the walker 2.5 m up a 70 degree wall.
	# Four half-radius capsules each offset toward one quarter find the floor a quarter away from the face; only a floor counts.
	if floor_normal == Vector3.ZERO and hit.hit and not _is_floor(hit.normal):
		var quarter := _quadrant_floor(centre, probe, height)
		if quarter.hit:
			hit = quarter
			floor_normal = quarter.normal

	if rising:
		# Moving up, and either grounded last tick or airborne and rising slowly: a walk up a slope or a landing on one when the velocity lies in the ground plane
		# (the floor now, or last tick's at a ramp's crest; UP for an airborne player, so never), and a launch when it points out of both.
		# A jump never reaches this: [method _try_jump] puts the player in AIR itself, with a launch of metres per second against a tenth.
		var walking := (
			floor_normal != Vector3.ZERO
			and (
				state.velocity.dot(floor_normal) <= LEAVING_SPEED
				or state.velocity.dot(state.ground_normal) <= LEAVING_SPEED
			)
		)

		if not walking:
			state.mode = DotFpsState.Mode.AIR
			state.ground_normal = Vector3.UP
			state.ground_id = 0
			return false

		# Along the floor now: at a ramp's crest the velocity still points up the ramp, and the next tick would throw a walker a tenth of a metre into the air.
		# Changes nothing on the slope itself.
		state.velocity = state.velocity.slide(floor_normal)

	if floor_normal != Vector3.ZERO:
		var found := _surface_id_for(hit.collider_id)

		# A surface marked unstandable behaves like a wall whatever its angle: a
		# handrail, a pane of glass, the top of a fence. Checked here rather than in
		# the slide so the player still collides with it and simply cannot stand.
		if surfaces != null and not surfaces.get_surface(found).standable:
			state.mode = DotFpsState.Mode.AIR
			state.ground_normal = Vector3.UP
			state.ground_id = 0
			state.surface = &""
			_resolve_surface(state)
			return false

		state.mode = DotFpsState.Mode.GROUND
		state.ground_normal = floor_normal
		state.ground_id = hit.collider_id
		state.surface = found
		_resolve_surface(state)
		_keep_skin(state, hit, probe)
		return was_grounded and state.position == position_in and state.velocity == velocity_in

	# The recovery path: a swept query on a shape starting inside geometry returns "no collision", so a player embedded by a fraction of a millimetre looks airborne, falls and leaves the level.
	# A player who was grounded and now appears not to be is asked the one question a sweep cannot answer, whether they are inside something; if so they stay grounded with the previous normal.
	# One overlap test on the tick a player leaves the ground, against an occasional unreproducible fall through the world.
	if was_grounded and body.overlaps(centre, height, tunables.radius):
		embedded_ticks += 1
		# Then get them out: staying grounded stops the fall, but the next probe still starts in geometry and [method _snap_to_ground] runs only when NOT grounded, so the stale [member DotFpsState.ground_normal] stood for ever. Lift clear first; keep the old answer only if that fails.
		# Only when the probe saw nothing: a steep surface at fraction 0 is a wall the capsule is a hair inside, and straight up is not out of a wall (it lifted a walker 0.13 m over a 0.46 m kerb). [method _depenetrate] handles that next tick.
		if not hit.hit and _lift_clear(state, height):
			lifted_ticks += 1
			DotLog.debug(
				CHANNEL,
				"was embedded in geometry; lifted clear",
				{"position": str(state.position)}
			)
			var recovered := _sweep(_capsule_centre(state.position, height), probe, height)
			if recovered.hit and _is_floor(recovered.normal):
				state.mode = DotFpsState.Mode.GROUND
				state.ground_normal = recovered.normal
				state.ground_id = recovered.collider_id
				_resolve_surface(state)
				return false
		else:
			DotLog.debug(
				CHANNEL,
				"ground probe missed while embedded; staying grounded",
				{"position": str(state.position)}
			)

		state.mode = DotFpsState.Mode.GROUND
		return false

	state.mode = DotFpsState.Mode.AIR
	state.ground_normal = Vector3.UP
	state.ground_id = 0
	state.surface = &""
	_resolve_surface(state)
	return false


## Asks the game which surface a collider is. Empty when it has no resolver.
func _surface_id_for(collider_id: int) -> StringName:
	if surfaces == null or collider_id == 0 or not surface_resolver.is_valid():
		return &""

	var resolved: Variant = surface_resolver.call(collider_id)
	return resolved if resolved is StringName else StringName(str(resolved))


func _is_floor(normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) <= tunables.max_slope_radians()


## Applies a jump if one is owed. Returns whether it fired.
## Coyote time and jump buffering both cover a press landing slightly outside the legal window, which a player reads as the game dropping the input.
func _try_jump(
	state: DotFpsState,
	command: DotFpsCommand,
	_delta: float
) -> bool:
	if not tunables.can_jump or _effects.deny_jump:
		return false

	var wants := false

	if tunables.auto_hop:
		wants = command.is_pressed(DotFpsCommand.BUTTON_JUMP)
	else:
		# Buffered: a press up to jump_buffer_time ago still counts, so pressing just
		# before touching down jumps on landing rather than being swallowed.
		wants = state.time_since_jump_pressed <= tunables.jump_buffer_time

	if not wants:
		return false

	if state.time_since_jump < tunables.jump_cooldown:
		return false

	# Coyote time: still jumpable shortly after walking off a ledge.
	var can := (
		state.mode == DotFpsState.Mode.GROUND
		or state.time_since_grounded <= tunables.coyote_time
	)

	if not can:
		return false

	# Only while descending or level, or a player under a ceiling jumps repeatedly on the way up and climbs it.
	# Level with the ground stood on, not the horizon: `velocity.y` refused every jump on every uphill. Airborne (coyote time) the normal is UP.
	var normal := state.ground_normal if state.mode == DotFpsState.Mode.GROUND else Vector3.UP
	if state.velocity.dot(normal) > LEAVING_SPEED:
		return false

	var launch := (
		tunables.jump_velocity() * _surface.jump_scale * _effects.jump
	)

	# A surface or modifier that forbids jumping must mean no jump, not a jump of zero height, which still leaves the ground for a tick and loses ground friction.
	if launch <= 0.0:
		return false

	# The landing cap runs BEFORE the launch, so it measures the speed the player arrived with.
	# Off by default: with it on there is no bunny-hopping, which is the point of the cvar.
	if tunables.bhop_speed_cap_scale > 0.0:
		var cap := tunables.max_speed * tunables.bhop_speed_cap_scale
		var horizontal := Vector2(state.velocity.x, state.velocity.z)
		var horizontal_speed := horizontal.length()

		if horizontal_speed > cap and horizontal_speed > 0.0:
			var scale := cap / horizontal_speed
			state.velocity.x *= scale
			state.velocity.z *= scale

	if tunables.jump_adds_to_velocity:
		state.velocity.y = maxf(state.velocity.y, 0.0) + launch
	else:
		state.velocity.y = launch

	state.mode = DotFpsState.Mode.AIR
	state.time_since_jump = 0.0

	# Coyote time is spent, not refreshed, or the window stays open for another jump in mid-air.
	# The upward-velocity check above closes it only by coincidence of the default jump height and gravity.
	state.time_since_grounded = 1000.0

	# Consumed, so one press cannot be spent twice through the buffer.
	state.time_since_jump_pressed = 1000.0

	return true


## The launch ability: [member DotFpsTunables.launch_button] throws the player upward, on the press so a replay launches on the same tick.
## The upward speed REPLACES a lower one instead of adding, or a launch at the top of a jump would go half again as high.
## A stun refuses it, as it refuses a jump: an ability that escapes a freeze is a way out of every freeze.
func _try_launch(state: DotFpsState, command: DotFpsCommand) -> bool:
	if not tunables.launch_enabled or tunables.launch_button <= 0:
		return false

	if _effects.deny_jump or _effects.deny_move:
		return false

	if state.launch_cooldown_left > 0.0:
		return false

	var pressed := (command.buttons & ~state.previous_buttons) & tunables.launch_button

	if pressed == 0:
		return false

	if not tunables.launch_from_air and not (
		state.mode == DotFpsState.Mode.GROUND
		or state.time_since_grounded <= tunables.coyote_time
	):
		return false

	state.velocity.y = maxf(state.velocity.y, tunables.launch_velocity)

	if tunables.launch_forward > 0.0:
		var forward := _view_basis(state.yaw, 0.0).forward
		forward.y = 0.0

		if forward.length_squared() > 0.0:
			state.velocity += forward.normalized() * tunables.launch_forward

	# What a jump does on leaving the ground, for the same reasons: AIR now so this tick's
	# move does not snap the player back onto the floor, and coyote time spent so the
	# ground they left cannot be jumped from again in mid-air.
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 1000.0
	state.launch_cooldown_left = tunables.launch_cooldown
	launches += 1

	return true


## The dash: [member DotFpsTunables.dash_button] throws the player along the way they
## are steering, or along the view's heading with nothing held. On the press, refused by
## a stun, on a cooldown, the launch's shape exactly; returns whether it left the ground.
func _try_dash(state: DotFpsState, command: DotFpsCommand) -> bool:
	if not tunables.dash_enabled or tunables.dash_button <= 0:
		return false

	if _effects.deny_move or state.dash_cooldown_left > 0.0:
		return false

	if ((command.buttons & ~state.previous_buttons) & tunables.dash_button) == 0:
		return false

	var grounded := state.mode == DotFpsState.Mode.GROUND
	if not tunables.dash_from_air and not grounded:
		return false

	var basis := _view_basis(state.yaw, 0.0)
	var direction := basis.right * command.move.x + basis.forward * command.move.y
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		direction = basis.forward
		direction.y = 0.0
	direction = direction.normalized()

	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var along := flat.dot(direction)
	var across := flat - direction * along
	var speed := maxf(along, tunables.dash_speed)
	var dashed := direction * speed + across
	state.velocity.x = dashed.x
	state.velocity.z = dashed.z
	state.dash_cooldown_left = tunables.dash_cooldown
	dashes += 1

	if tunables.dash_lift > 0.0:
		state.velocity.y = maxf(state.velocity.y, tunables.dash_lift)
		state.mode = DotFpsState.Mode.AIR
		state.time_since_grounded = 1000.0
		return true

	return false


## Starts, carries and ends a slide: a crouch with different friction and steering, nothing else.
## The collider is the crouched one ([method _update_crouch] already did that), so a slide fits where a crouch fits.
## It starts on the crouch PRESS, grounded, at [member DotFpsTunables.slide_min_speed] or more, and ends on release, leaving the ground, [member DotFpsTunables.slide_duration] or below [member DotFpsTunables.slide_end_speed].
func _update_slide(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float,
	left_ground: bool
) -> void:
	if not tunables.slide_enabled:
		# A slide in progress when a server turns sliding off ends rather than freezing
		# its friction for good.
		if state.is_sliding():
			_end_slide(state)
		return

	if state.is_sliding():
		state.slide_time += delta

		if (
			left_ground
			or state.mode != DotFpsState.Mode.GROUND
			or not command.is_pressed(DotFpsCommand.BUTTON_CROUCH)
			or state.slide_time >= tunables.slide_duration
			or state.horizontal_speed() < tunables.slide_end_speed
			or _effects.deny_move
		):
			_end_slide(state)

		return

	if left_ground or state.mode != DotFpsState.Mode.GROUND:
		return

	if state.slide_cooldown_left > 0.0:
		return

	if not tunables.can_crouch or _effects.deny_crouch or _effects.deny_move:
		return

	var pressed := (
		(command.buttons & ~state.previous_buttons) & DotFpsCommand.BUTTON_CROUCH
	) != 0

	if not pressed:
		return

	if tunables.slide_requires_sprint and not command.is_pressed(DotFpsCommand.BUTTON_SPRINT):
		return

	var speed := state.horizontal_speed()

	if speed < tunables.slide_min_speed or speed <= 0.0:
		return

	state.slide_time = 0.0
	slides += 1

	if tunables.slide_boost > 0.0 and speed < tunables.slide_max_speed:
		var boosted := minf(speed + tunables.slide_boost, tunables.slide_max_speed)
		var scale := boosted / speed
		state.velocity.x *= scale
		state.velocity.z *= scale


func _end_slide(state: DotFpsState) -> void:
	state.slide_time = -1.0
	state.slide_cooldown_left = tunables.slide_cooldown


func _apply_friction(state: DotFpsState, delta: float) -> void:
	var speed := state.velocity.length()

	if speed <= 0.0:
		return

	# Below stop_speed, friction is applied as though moving at stop_speed. Without
	# it friction is proportional to speed, decays asymptotically, and the player
	# drifts at walking pace for a second after releasing the keys.
	var control := maxf(speed, tunables.stop_speed)

	# sv_edgefriction. Standing with your toes over a drop stops you faster,
	# so walking to the edge of a block leaves you on it rather than sliding off.
	# Costs one query per grounded tick, which is why it is opt-in.
	var edge := 1.0
	if tunables.edge_friction > 1.0 and _near_ledge(state):
		edge = tunables.edge_friction

	# A slide swaps the base friction rather than scaling it, so a surface and a modifier
	# still scale a slide the way they scale a walk: ice is slicker to slide on too.
	var base := tunables.slide_friction if state.is_sliding() else tunables.friction

	var drop := (
		control * base * _surface.friction_scale
		* _effects.friction * edge * delta
	)

	var scale := maxf(speed - drop, 0.0) / speed
	state.velocity *= scale


func _apply_air_friction(state: DotFpsState, delta: float) -> void:
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := horizontal.length()

	if speed <= 0.0:
		return

	var scale := maxf(speed - speed * tunables.air_friction * delta, 0.0) / speed
	state.velocity.x *= scale
	state.velocity.z *= scale


func _apply_wish_move(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	if _effects.deny_move:
		return

	var basis := _view_basis(state.yaw, 0.0)

	var wish := basis.right * command.move.x + basis.forward * command.move.y
	wish.y = 0.0

	var magnitude := minf(wish.length(), 1.0)

	if magnitude <= 0.0:
		return

	var buttons := command.buttons if state.sprinting else command.buttons & ~DotFpsCommand.BUTTON_SPRINT
	var target := tunables.speed_for(buttons, load_fraction) * magnitude * _effects.max_speed

	if command.move.y < 0.0:
		target *= tunables.backward_speed_scale

	var direction := wish.normalized()

	if state.mode == DotFpsState.Mode.GROUND:
		# The surface scales the ground cap and acceleration but not the air ones:
		# what you are standing on stops mattering the moment you are not.
		target *= _surface.max_speed_scale

		# Along the slope rather than through it, so walking up a ramp does not spend
		# most of the acceleration pushing into the surface for the slide to discard.
		direction = _project_on_slope(direction, state.ground_normal)
		var ground_accel := (
			tunables.slide_accelerate if state.is_sliding() else tunables.accelerate
		)
		_ground_cap = maxf(Vector2(state.velocity.x, state.velocity.z).length(), target)
		accelerate(
			state,
			direction,
			target,
			ground_accel * _surface.accelerate_scale * _effects.accelerate,
			delta
		)
	else:
		accelerate(
			state,
			direction,
			target,
			tunables.air_accelerate * _effects.air_accelerate,
			delta,
			tunables.max_air_wish_speed
		)


## The classic acceleration function, and the reason air-strafing exists.
## Speed is only added along [param direction], up to [param wish_speed] measured as the projection of current velocity onto it.
## Airborne, [param cap] clamps that target to about a metre per second while the constant stays large: turn the view while strafing and the projection of a fast velocity is near zero, so the full increment is added sideways and compounds.
func accelerate(
	state: DotFpsState,
	direction: Vector3,
	wish_speed: float,
	accel: float,
	delta: float,
	cap: float = -1.0
) -> void:
	# The cap applies to the target, not the increment: [code]add[/code] uses the capped speed, [code]step[/code] the uncapped one. Capping both removes air control entirely.
	# Negative means no cap; zero is a real value (no air control). Reading zero as "unlimited" did the opposite of what was asked.
	var target := wish_speed if cap < 0.0 else minf(wish_speed, cap)

	var current := state.velocity.dot(direction)
	var add := target - current

	if add <= 0.0:
		return

	var step := accel * wish_speed * delta
	state.velocity += direction * minf(step, add)


func _project_on_slope(direction: Vector3, normal: Vector3) -> Vector3:
	if normal.is_equal_approx(Vector3.UP):
		return direction

	var projected := direction.slide(normal)

	# A direction that projects to nothing means the slope is a wall by another name.
	# Keeping the flat direction lets the slide handle it rather than freezing input.
	if projected.length_squared() < 1e-8:
		return direction

	return projected.normalized()


func _clamp_velocity(state: DotFpsState) -> void:
	# A NaN here is unrecoverable: it survives limit_length, propagates into the
	# position, and from there into whatever the position is replicated as. Cheap to
	# check once a tick, effectively impossible to trace back to afterwards.
	if not (
		is_finite(state.velocity.x)
		and is_finite(state.velocity.y)
		and is_finite(state.velocity.z)
	):
		DotLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
		state.velocity = Vector3.ZERO
		return

	state.velocity = state.velocity.limit_length(tunables.max_velocity)


## One of four half-radius capsules, one per quarter of the player, that finds a FLOOR along [param probe]. See [method _categorise_ground].
## Each sits half a radius out along its diagonal, inside the player's footprint: one poking outside would start inside the very face that made it necessary, or find floor the player is not over.
func _quadrant_floor(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	if not static_world:
		return _quadrant_floor_probe(centre, probe, height)
	# The end-of-tick check and the next tick's first check ask this at one position, and in a
	# world nothing moves in the answer is the same: 4 sweeps, up to 16 queries, saved.
	var radius := tunables.radius
	var mask := body.collision_mask
	if (_qf_valid and centre == _qf_centre and probe == _qf_probe and height == _qf_height
			and radius == _qf_radius and mask == _qf_mask):
		return _copy_hit(_qf_hit) if _qf_hit != null else DotFpsBody.Hit.new()
	var found := _quadrant_floor_probe(centre, probe, height)
	_qf_valid = true
	_qf_centre = centre
	_qf_probe = probe
	_qf_height = height
	_qf_radius = radius
	_qf_mask = mask
	_qf_hit = _copy_hit(found) if found.hit else null
	return found


## The ground check's sweep, remembered across ticks under [member static_world] like
## [method _quadrant_floor]: the last check of a tick and the first of the next are one question.
func _ground_probe(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	if not static_world:
		return _sweep(centre, probe, height)
	var radius := tunables.radius
	var mask := body.collision_mask
	if (_gp_valid and centre == _gp_centre and probe == _gp_probe and height == _gp_height
			and radius == _gp_radius and mask == _gp_mask and tunables.skin_width == _gp_skin):
		return _copy_hit(_gp_hit)
	var found := _sweep(centre, probe, height)
	_gp_valid = true
	_gp_centre = centre
	_gp_probe = probe
	_gp_height = height
	_gp_radius = radius
	_gp_mask = mask
	_gp_skin = tunables.skin_width
	_gp_hit = _copy_hit(found)
	return found


var _gp_valid := false
var _gp_centre := Vector3.ZERO
var _gp_probe := Vector3.ZERO
var _gp_height := 0.0
var _gp_radius := 0.0
var _gp_mask := 0
var _gp_skin := 0.0
var _gp_hit: DotFpsBody.Hit = null


## True when nothing the body queries moves between ticks (no platforms, doors or hulls), so
## the quarter probes may be reused across ticks. Off by default: a moving world makes a
## remembered answer wrong. Call [method invalidate_probe_cache] when the level changes.
var static_world := false:
	set(value):
		if value != static_world:
			_qf_valid = false
			_gp_valid = false
			_en_valid = false
			body.set_static_world(value)
		static_world = value


## Forgets the remembered quarter probe; for a level change under a [member static_world] motor.
func invalidate_probe_cache() -> void:
	_qf_valid = false
	_gp_valid = false
	_en_valid = false


func _copy_hit(from: DotFpsBody.Hit) -> DotFpsBody.Hit:
	var out := DotFpsBody.Hit.new()
	out.hit = from.hit
	out.fraction = from.fraction
	out.normal = from.normal
	out.point = from.point
	out.collider_id = from.collider_id
	out.depth = from.depth
	return out


var _qf_valid := false
var _qf_found := false
var _qf_centre := Vector3.ZERO
var _qf_probe := Vector3.ZERO
var _qf_height := 0.0
var _qf_radius := 0.0
var _qf_mask := 0
var _qf_hit: DotFpsBody.Hit = null


func _quadrant_floor_probe(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	var half := tunables.radius * 0.5
	for quarter: Vector2 in QUADRANTS:
		var offset := Vector3(quarter.x, 0.0, quarter.y).normalized() * half
		var hit := _sweep(centre + offset, probe, height, half)
		if hit.hit and _is_floor(hit.normal):
			return hit
	return DotFpsBody.Hit.miss()


## The "never happened" value the timers start at; they stop here, because a float32 timer past it
## rounds differently on the client and the server and reads as a misprediction every few ticks.
const TIMER_CAP := 1000.0

const QUADRANTS: Array[Vector2] = [
	Vector2(-1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0),
]


## Returns whether the ground check it ran for the snap is already the end-of-tick answer
## (see [method _categorise_ground_settled]); false whenever it ran none.
func _move(state: DotFpsState, delta: float, jumped: bool) -> bool:
	var height := _height(state)
	var motion := state.velocity * delta

	if motion.length_squared() <= 0.0:
		return false

	var was_grounded := state.mode == DotFpsState.Mode.GROUND
	var velocity_in := state.velocity
	# The floor the tick started on. The snap below compares the velocity with THIS
	# plane, because by the time it runs the categorise has already forgotten it.
	var stood_on := state.ground_normal

	var plain := _native_move(state.position, state.velocity, motion, height, 0, was_grounded and not jumped)
	if plain == null:
		var hulls_before := body.hull_blocks
		var world_before := body.world_touches
		plain = _slide(state.position, state.velocity, motion, height)
		# Only another player stopped the slide: no kerb to climb, and a step over a standing player won 1 in 5000 ticks.
		var hull_only := body.hull_blocks > hulls_before and body.world_touches == world_before

		plain = _prefer_step(state, plain, motion, height, was_grounded and not jumped, hull_only)

	state.position = plain.position
	state.velocity = plain.velocity

	# A diagonal wish held into a wall is measured along its own direction, and the slide strips
	# the sideways half every tick, so the walker would creep to target / cos(45). Only a blocked
	# walk is held to the speed it arrived with or the cap, so free running is untouched.
	if was_grounded and not jumped and plain.blocked and _ground_cap > 0.0:
		var flat := Vector2(state.velocity.x, state.velocity.z)
		if flat.length() > _ground_cap:
			flat = flat.normalized() * _ground_cap
			state.velocity.x = flat.x
			state.velocity.z = flat.y

	_strip_steep_lift(state, plain, velocity_in, stood_on, was_grounded and not jumped)

	if plain.ran_out:
		stuck_ticks += 1

	if plain.stopped_on_duplicate:
		duplicate_plane_ticks += 1

	if was_grounded and not jumped and tunables.ground_snap:
		# Categorise first and snap only if the player left the ground. The snap probe is the longest query in the tick, and a swept query's precision is proportional to its length:
		# run on a standing player it re-derived a correct position from the least precise measurement, sank them a fraction of a millimetre a tick, and they fell out of the level.
		# It also drops the most expensive query from the common case.
		if _categorise_ground_settled(state):
			return true

		if state.mode != DotFpsState.Mode.GROUND:
			_snap_to_ground(state, height, stood_on)

	return false


## [method _slide] then [method _prefer_step] (mode 0, [param flag] walking) or the slide and step of [method move_and_slide]
## (mode 1, [param flag] step) in one native call, when the body runs one ([method DotFpsBody.native_slide]); null to run them here.
## The native slide is this script's to the bit (dot-sim's motor parity suite), so a web client running the script agrees.
func _native_move(
	from: Vector3, velocity: Vector3, motion: Vector3, height: float, mode: int, flag: bool
) -> MoveResult:
	var tun := PackedFloat64Array([
		tunables.max_slide_iterations, 1.0 if tunables.crease_slide else 0.0, tunables.skin_width,
		tunables.max_slide_planes, tunables.step_height, tunables.radius, tunables.max_slope_radians(),
	])
	var r := body.native_slide(from, velocity, motion, height, mode, flag, tun)
	if r.size() < 13:
		return null
	var m := MoveResult.new()
	m.position = Vector3(r[0], r[1], r[2])
	m.velocity = Vector3(r[3], r[4], r[5])
	m.travelled = r[6]
	var flags := int(r[7])
	m.blocked = flags & 1 != 0
	m.ran_out = flags & 2 != 0
	m.stopped_on_duplicate = flags & 4 != 0
	m.met_steep_face = flags & 8 != 0
	crease_leg_ticks += int(r[8])
	split_leg_ticks += int(r[9])
	return m


## The collide-and-slide result to keep: the plain slide, or the stepped one when it got further.
func _prefer_step(
	state: DotFpsState, plain: MoveResult, motion: Vector3, height: float,
	walking: bool, hull_only: bool
) -> MoveResult:
	# Stepping is tried only when it could help: grounded, blocked, and not the tick a jump left the surface.
	# A step cannot travel further than the horizontal motion, so when the slide is already within the acceptance margin of it, skip its queries.
	if (
		walking and plain.blocked and tunables.step_height > 0.0
		and not hull_only
		and plain.travelled + tunables.skin_width * 2.0 + 1e-4
			< Vector2(motion.x, motion.z).length()
	):
		var stepped := _slide_with_step(state.position, state.velocity, motion, height)

		# Only if it got further, or a step that gains nothing but ends higher would ratchet the player up a wall.
		# And by more than a skin: raised to step height, the rounded bottom can slide a millimetre past a kerb's top corner that dropped back is inside the kerb's face.
		if stepped.travelled > plain.travelled + tunables.skin_width * 2.0:
			return stepped

	return plain


## Removes the lift a steep face added to a walker's velocity along the floor they stood on.
func _strip_steep_lift(
	state: DotFpsState, plain: MoveResult, velocity_in: Vector3, stood_on: Vector3, walking: bool
) -> void:
	# A walker is not lifted by a face they cannot stand on (`[steep-climb-1]`). The classic walk move zeroes the vertical before and after, so a walk never climbs.
	# Here only the lift the slide ADDED along the floor's normal goes, and only when a steep face did it; a walkable ramp's lift is the floor's own, and a jump never reaches this.
	# With the quarter probes in [method _categorise_ground] this is the other half; either alone still let a walker up a 70 degree face.
	if walking and plain.met_steep_face:
		var lift := state.velocity.dot(stood_on) - maxf(velocity_in.dot(stood_on), 0.0)
		if lift > 0.0:
			state.velocity -= stood_on * lift


## The result of one collide-and-slide.
class MoveResult extends RefCounted:
	var position: Vector3
	var velocity: Vector3
	var travelled: float = 0.0
	var blocked: bool = false
	## Iterations were exhausted with motion remaining: a wedge the slide gave up on.
	var ran_out: bool = false
	## The move stopped early because it met a plane it had already resolved against.
	## Not a failure, but the tick's remaining motion goes unspent. Counted apart from running out of iterations because telling the two apart is the point of counting either.
	var stopped_on_duplicate: bool = false
	## Whether the move met a face too steep to stand on that leans back toward the
	## sky. Sliding along one of those turns a push into a climb.
	var met_steep_face: bool = false


## Collide and slide: move, and on contact continue along the surface.
## Velocity is slid as well as motion, so running into a wall at an angle keeps the component along it, and the next tick starts from a velocity consistent with what happened.
## Every plane touched during one move is remembered and the direction must satisfy all of them; see [method _resolve_planes], which surf depends on.
func _slide(
	from: Vector3,
	velocity: Vector3,
	motion: Vector3,
	height: float
) -> MoveResult:
	var result := MoveResult.new()
	result.position = from
	result.velocity = velocity

	var start := from

	# The move is carried as direction-and-speed plus the fraction of the tick left, because crease resolution re-derives the direction from the ORIGINAL motion every bump.
	# Deriving it from the already-clipped vector makes the answer depend on the order planes were hit in.
	var current := motion
	var time_left := 1.0

	var planes: Array[Vector3] = []

	for _i in range(tunables.max_slide_iterations):
		var step := current * time_left

		if step.length_squared() <= 1e-12:
			break

		var centre := _capsule_centre(result.position, height)
		var hit := _sweep(centre, step, height)

		if not hit.hit:
			result.position += step
			time_left = 0.0
			break

		result.blocked = true
		if hit.normal.y > 0.0 and not _is_floor(hit.normal):
			result.met_steep_face = true

		# The skin gap is already deducted by _sweep, so this stops just short of the
		# surface rather than exactly on it.
		result.position += step * hit.fraction
		time_left -= time_left * hit.fraction

		if not tunables.crease_slide:
			current = current.slide(hit.normal)
			result.velocity = result.velocity.slide(hit.normal)
			continue

		var outcome := _remember_plane(planes, hit.normal)

		if outcome == PLANE_FULL:
			# A genuine five-plane corner: no direction out. Carrying on finds one that leaves the player inside the geometry.
			current = Vector3.ZERO
			result.velocity = Vector3.ZERO
			break

		if outcome == PLANE_DUPLICATE:
			# Spend the rest of the tick along the plane, a skin off it, and stop. The same plane again at the start of a leg is a capsule resting on it with a velocity already in it (a surfer pressed into a bank);
			# breaking there spent none of the tick, and the player hung in mid-air with its speed intact (697 of 1,786 ticks of one bank).
			# One leg, not a return to the loop: carrying on fills the plane list with near-copies and zeroes the velocity in a corner that is not there. The velocity is not touched.
			var rest := current * time_left + hit.normal * tunables.skin_width
			var clear := _sweep(_capsule_centre(result.position, height), rest, height)
			var spent := 1.0 if not clear.hit else clear.fraction
			result.position += rest * spent
			if spent > 1e-6:
				# Stopped part of the way along: in a wedge, by the other face, and the
				# rest of the tick goes along the crease instead of nowhere. Off a wedge
				# there is no other face and this changes nothing.
				if spent < 1.0:
					var _along := _leave_crease(
						result, planes, motion, velocity, time_left * (1.0 - spent),
						hit.normal, height
					)
				time_left = 0.0
				break
			# Still nothing: step off the face first, then go along it (`[arrive-3]`). A capsule exactly touching a face is blocked at the first bisection step by ANY move starting there, even one leaving it,
			# and a grazing contact leaves it there since the skin is taken along the motion, not the normal; a rider hung at 75 u/s for good. Lifted a millimetre, the same leg ran 40 cm clear.
			# A wedge first: when the face the queries keep naming is one of two the capsule is in, none of the legs below can leave it ([method _leave_crease]).
			if _leave_crease(result, planes, motion, velocity, time_left, hit.normal, height):
				time_left = 0.0
				break
			if _leave_face(result, current * time_left, hit.normal, height):
				time_left = 0.0
				break
			if _split_leg(result, current * time_left, height):
				time_left = 0.0
				break
			result.stopped_on_duplicate = true
			# The same plane again: the velocity is already resolved against it, so resolving again is a no-op and the loop would spin. Stop the move and KEEP the velocity.
			# Zeroing looks tidy but stops a player who starts a tick a millimetre inside a surf ramp (every spawn onto one, every correction) dead on a surface they should accelerate down.
			break

		current = _resolve_planes(planes, motion)
		result.velocity = _resolve_planes(planes, velocity)

	# Motion left over means the move did not complete, which is two things: the duplicate-plane break above leaves this state on purpose (time left, velocity kept),
	# while running out of iterations is a player wedged in geometry. Counting both in [member stuck_ticks] read 10% to 14% of ticks on imported maps and hid the real figure, one tick in fifteen thousand.
	# Raising max_slide_iterations from 5 to 20 moved it not at all, which is what separates them.
	if time_left > 1e-6 and current.length_squared() > 1e-12 and not result.stopped_on_duplicate:
		result.ran_out = true

	result.travelled = Vector3(
		result.position.x - start.x, 0.0, result.position.z - start.z
	).length()

	return result


## The duplicate-plane leg's last resort: lift straight off [param normal] by one, two, then four skins and spend [param leg] from there.
## True and [param result] moved if any got anywhere; false and untouched if none did, which leaves the old answer (stop, keep the velocity).
## Bounded on purpose: a wrong answer is a few millimetres of air that gravity takes back next tick.
func _leave_face(
	result: MoveResult, leg: Vector3, normal: Vector3, height: float
) -> bool:
	if tunables.skin_width <= 0.0 or leg.length_squared() <= 1e-12:
		return false

	for scale: float in [1.0, 2.0, 4.0]:
		var lift := normal * tunables.skin_width * scale
		var off := _sweep(_capsule_centre(result.position, height), lift, height)
		if off.hit:
			return false
		var from := result.position + lift
		var along := _sweep(_capsule_centre(from, height), leg, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6:
			result.position = from + leg * spent
			return true

	return false


## The duplicate-plane leg's answer in a wedge (`g2gfast-surf-crease-hang-1`): find the second face and spend the leg along the crease. True and [param result] moved if that got anywhere; false and untouched otherwise.
## A surfer in the V of two slabs sits in both and the rest query names one of two equal contacts; named the same face twice, the leg, the lift and the split all stop at fraction zero and the rider hangs.
## Asked before [method _leave_face] and [method _split_leg], because both can succeed by a hair there and the same ride would finish in different times.
func _leave_crease(
	result: MoveResult,
	planes: Array[Vector3],
	motion: Vector3,
	velocity: Vector3,
	time_left: float,
	normal: Vector3,
	height: float
) -> bool:
	if tunables.skin_width <= 0.0:
		return false

	# The face the queries are not naming. A skin or more off the one they do name, that one
	# is no longer touched and the rest query has only the other left to report.
	var other := Vector3.ZERO
	for scale: float in [1.0, 2.0, 4.0]:
		var probe := body.rest_contact(
			_capsule_centre(result.position + normal * tunables.skin_width * scale, height),
			height, tunables.radius
		)
		if probe.hit and probe.normal.dot(normal) < 0.999:
			other = probe.normal
			break

	if other == Vector3.ZERO:
		return false

	# Two faces almost back to back are a slot, not a crease: there is no lift off both.
	var c := normal.dot(other)
	if c < -0.9:
		return false

	var wedge: Array[Vector3] = planes.duplicate()
	if _remember_plane(wedge, other) == PLANE_FULL:
		return false

	var leg := _resolve_planes(wedge, motion) * time_left
	if leg.length_squared() <= 1e-12:
		return false

	# From where the capsule is first, and only then lifted off both faces at once (the lift that leaves each by a skin lies along their sum).
	# Unlifted first because a crease leg clear from here is the leg the slide takes when the query names the faces the other way round, so either answer rides the same line.
	var off_both := (normal + other) * (tunables.skin_width / (1.0 + c))
	for scale: float in [0.0, 1.0, 2.0, 4.0]:
		var lift := off_both * scale
		if scale > 0.0 and _sweep(_capsule_centre(result.position, height), lift, height).hit:
			continue
		var from := result.position + lift
		var along := _sweep(_capsule_centre(from, height), leg, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6 and (scale > 0.0 or not along.hit):
			result.position = from + leg * spent
			result.velocity = _resolve_planes(wedge, velocity)
			crease_leg_ticks += 1
			return true

	return false


## The duplicate-plane leg's very last resort (`[hns-door-wedge-1]`): spend [param leg]'s vertical part alone, or failing that its horizontal part alone. True and [param result] moved if either got anywhere.
## A rest query names one contact and with two touching it can be the wrong one (a wall corner with an open door panel: a normal square to the motion, which clips nothing). The panel cannot be added as a plane, so splitting asks nothing new of the world.
func _split_leg(result: MoveResult, leg: Vector3, height: float) -> bool:
	for part: Vector3 in [Vector3(0.0, leg.y, 0.0), Vector3(leg.x, 0.0, leg.z)]:
		if part.length_squared() <= 1e-12:
			continue
		var along := _sweep(_capsule_centre(result.position, height), part, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6:
			result.position += part * spent
			split_leg_ticks += 1
			return true

	return false


## Outcomes of [method _remember_plane]. The two failures need different answers.
const PLANE_ADDED := 0
const PLANE_DUPLICATE := 1
const PLANE_FULL := 2


## Adds [param normal] to the plane list.
## Near-duplicates are rejected because a long surf ramp yields a contact every few centimetres with a normal differing in the last bits, which would fill the list and hide the wall the player is caught on.
## A duplicate and a full list are told apart because the caller treats them differently: a duplicate is already satisfied, a full list is a corner.
func _remember_plane(planes: Array[Vector3], normal: Vector3) -> int:
	for existing in planes:
		if existing.dot(normal) > 0.999:
			return PLANE_DUPLICATE

	if planes.size() >= tunables.max_slide_planes:
		return PLANE_FULL

	planes.append(normal)
	return PLANE_ADDED


## A direction that satisfies every plane touched so far, or zero if there is none. This is why surf works.
## Clipping against one plane then the next does not leave both: at a seam of two shallow ramps the clipped vector points back into the other and the player stops dead. Take the first plane whose clip re-enters no other, else go along the crease (cross of the normals); three planes with no direction is a corner and stopping is correct.
## [param original] is the velocity or motion at the START of the move, never the clipped one; see [method _slide].
func _resolve_planes(planes: Array[Vector3], original: Vector3) -> Vector3:
	var count := planes.size()

	for i in range(count):
		var candidate := original.slide(planes[i])
		var clear := true

		for j in range(count):
			if j == i:
				continue
			# A small negative tolerance rather than zero: a direction exactly in a
			# plane reads as "entering" it about half the time in single precision,
			# and rejecting it sends a surfer to the crease branch on a flat ramp.
			if candidate.dot(planes[j]) < -1e-5:
				clear = false
				break

		if clear:
			return candidate

	# Every crease, not only the first two planes (`[hns-door-wedge-1]`). The classic slide stops dead at three planes, right for a corner with no way out and wrong for one with a way down:
	# a body hopping into a corner under a window met the side wall and two box edges, and the line where the wall and the upright edge meet (straight down) left all three.
	# A crease of two planes that also leaves every other one is a real way out; with two planes this is the old answer exactly.
	for i in range(count):
		for j in range(i + 1, count):
			var crease := planes[i].cross(planes[j])

			# Parallel planes — two faces of the same wall the player is sandwiched
			# between. There is no crease and no way through.
			if crease.length_squared() < 1e-12:
				continue

			crease = crease.normalized()
			var along := crease * crease.dot(original)
			var leaves := true

			for k in range(count):
				if k != i and k != j and along.dot(planes[k]) < -1e-5:
					leaves = false
					break

			if leaves:
				return along

	return Vector3.ZERO


## Whether there is a drop just in front of the player. For [member DotFpsTunables.edge_friction].
## Probed with a thin capsule offset past their radius: sweeping the full capsule would answer "no" for anybody standing against a wall, doubling the friction of every player in a corridor.
func _near_ledge(state: DotFpsState) -> bool:
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if horizontal.length_squared() < 1e-6:
		return false

	var ahead := (
		state.position
		+ horizontal.normalized()
		* (tunables.radius + tunables.edge_friction_reach)
	)

	var probe_radius := minf(0.05, tunables.radius * 0.25)
	var probe_height := probe_radius * 2.0
	var centre := ahead + Vector3.UP * (probe_height * 0.5 + 0.02)

	var hit := body.sweep(
		centre,
		Vector3.DOWN * tunables.edge_friction_drop,
		probe_height,
		probe_radius
	)

	return not hit.hit


## Up, across, down: the standard way to walk up a step without jumping.
## Done explicitly because [method CharacterBody3D.move_and_slide] needs the stateful move this motor avoids, and the down leg must land on a floor or the step is rejected rather than depositing the player on top of a wall.
func _slide_with_step(
	from: Vector3,
	velocity: Vector3,
	motion: Vector3,
	height: float
) -> MoveResult:
	var centre := _capsule_centre(from, height)

	# A step is measured from the floor, not the feet: a grounded player can be up to the probe's two centimetres above it, and a full lift from there clears a kerb that much taller than step_height.
	# One short query, and only on a tick the slide was blocked.
	var seat := _sweep(centre, Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02), height)
	var hover := 0.0
	if seat.hit:
		hover = maxf((tunables.skin_width * 2.0 + 0.02) * seat.fraction - tunables.skin_width, 0.0)
	var floor_y := from.y - hover
	var lift := Vector3.UP * (tunables.step_height - hover)

	# Up. If there is no room above, there is no step to take.
	var up := _sweep(centre, lift, height)
	if up.hit:
		var result := MoveResult.new()
		result.position = from
		result.velocity = velocity
		result.blocked = true
		return result

	var raised := from + lift

	# Across, horizontally only: keeping the vertical component would carry the
	# player's fall through the step and undo the lift.
	var horizontal := Vector3(motion.x, 0.0, motion.z)
	var across := _slide(raised, velocity, horizontal, height)

	# Down, by at least the lift. Landing higher than we started is a step up;
	# landing lower is walking off the far edge, which the ground snap then handles.
	var drop := Vector3.DOWN * (lift.y + tunables.skin_width)
	var landing := _sweep(_capsule_centre(across.position, height), drop, height)

	var result := MoveResult.new()
	result.velocity = across.velocity
	result.blocked = across.blocked

	# And what it lands on is at most step_height above the floor it left. Asked of every landing, not only the edge's:
	# a capsule coming down a quarter-metre short of a kerb meets the corner at about 41 degrees, which is a floor, and a 0.5 m kerb with step_height 0.45 was stepped onto.
	var too_high := landing.hit and landing.point.y - floor_y > tunables.step_height + tunables.skin_width

	if not landing.hit or too_high or not (
		_is_floor(landing.normal) or _floor_beyond_edge(landing, across.position, floor_y)
	):
		# Nothing to stand on up there. Refusing the step is important: accepting it
		# would leave the player floating at step height with no ground under them,
		# and the next tick would drop them back, once per tick, forever.
		result.position = from
		result.travelled = 0.0
		result.blocked = true
		return result

	result.position = across.position + drop * landing.fraction
	result.travelled = Vector3(
		result.position.x - from.x, 0.0, result.position.z - from.z
	).length()

	return result


## Whether a steep landing contact is the capsule's rounded bottom on the edge of a floor, rather than a steep face.
## The step's down leg reports the capsule's normal, not the kerb's (50 to 80 degrees from up at walking pace), so a thin probe just past the contact must find a floor at the contact's own height. A steep face answers no, so surf and walls are unaffected.
## And the floor must be within a step of where the step started ([param start_y]): the across leg rides the hemisphere up the corner, so without that any kerb answered yes (0.7 m at 7 m/s with step_height 0.45).
func _floor_beyond_edge(landing: DotFpsBody.Hit, feet: Vector3, start_y: float) -> bool:
	return _edge_floor_normal(landing, feet, start_y) != Vector3.ZERO


## The floor's own normal behind [method _floor_beyond_edge]'s answer, or
## [constant Vector3.ZERO] when there is none.
func _edge_floor_normal(landing: DotFpsBody.Hit, feet: Vector3, start_y: float) -> Vector3:
	if landing.point.y - start_y > tunables.step_height + tunables.skin_width:
		return Vector3.ZERO

	var outward := Vector3(landing.point.x - feet.x, 0.0, landing.point.z - feet.z)
	if outward.length_squared() < 1e-8:
		return Vector3.ZERO

	var probe_radius := minf(0.05, tunables.radius * 0.25)
	var probe_height := probe_radius * 2.0
	var at := landing.point + outward.normalized() * (probe_radius + 0.01)
	var centre := at + Vector3.UP * (probe_radius + 0.05)
	var hit := body.sweep(centre, Vector3.DOWN * 0.1, probe_height, probe_radius)

	if not hit.hit or not _is_floor(hit.normal):
		return Vector3.ZERO

	var bottom := centre.y - probe_radius + (-0.1 * hit.fraction)
	return hit.normal if absf(bottom - landing.point.y) < 0.02 else Vector3.ZERO


## Puts a grounded player back a skin clear of the floor [param hit] found, if closer than half of one. Straight up, never further than the skin.
## Exactly touching a floor is a state a horizontal sweep cannot move out of: cast_motion reports the floor as an obstacle to a HORIZONTAL move at fraction ~0 in about one position in five, so a runner spawned on a floor froze in front of every kerb.
## Every query here stops a skin short, so only a spawn at the floor's height gets there, and a grounded player is never snapped.
func _keep_skin(state: DotFpsState, hit: DotFpsBody.Hit, probe: Vector3) -> void:
	var gap := probe.length() * hit.fraction
	if gap < tunables.skin_width * 0.5 and hit.normal.y > 0.0:
		state.position.y += tunables.skin_width - gap


## The floor [param hit] puts the player on, or [constant Vector3.ZERO] if it is not one.
## A walkable contact is its own answer. A steep one is the capsule's rounded bottom on an edge and counts as the floor beyond it ([method _edge_floor_normal]), [b]only for a player moving onto that floor[/b].
## Otherwise the next tick read a kerb corner's normal as AIR and the air slide turned a run into a climb (1.07 m at 15 m/s over a 0.34 m kerb). Standing on, walking off or running along a ledge keep the capsule's answer.
func _standable_normal(state: DotFpsState, hit: DotFpsBody.Hit) -> Vector3:
	if not hit.hit:
		return Vector3.ZERO

	if _is_floor(hit.normal):
		return hit.normal

	var toward := Vector3(hit.point.x - state.position.x, 0.0, hit.point.z - state.position.z)
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if horizontal.dot(toward) <= 0.0:
		return Vector3.ZERO

	if not static_world:
		return _edge_floor_normal(hit, state.position, state.position.y)
	# Remembered like [method _ground_probe]: the same landing point from the same feet.
	var mask := body.collision_mask
	if (_en_valid and hit.point == _en_point and state.position == _en_feet
			and mask == _en_mask and tunables.radius == _en_radius):
		return _en_normal
	var found := _edge_floor_normal(hit, state.position, state.position.y)
	_en_valid = true
	_en_point = hit.point
	_en_feet = state.position
	_en_mask = mask
	_en_radius = tunables.radius
	_en_normal = found
	return found


var _en_valid := false
var _en_point := Vector3.ZERO
var _en_feet := Vector3.ZERO
var _en_mask := 0
var _en_radius := 0.0
var _en_normal := Vector3.ZERO


## Pushes the capsule out of whatever it is inside along that surface's own normal. Returns whether it moved.
## The general form of [method _lift_clear]: straight up is right out of a floor and wrong out of a 60 degree ramp, and [method _lift_clear] is reached only for a player GROUNDED last tick, which a surfer never is.
## One query a tick per player: the cheaper [method DotFpsBody.overlaps] cannot tell a player resting on a floor from one buried in it.
func _depenetrate(state: DotFpsState, height: float) -> bool:
	var centre := _capsule_centre(state.position, height)
	var resting := body.rest_contact(centre, height, tunables.radius)

	if not resting.hit or resting.depth <= 0.0:
		return false

	# Out by the measured depth plus the skin every sweep expects, never further than a step per tick.
	# The clamp makes a wrong answer survivable: a degenerate normal moves a player a centimetre, unclamped against a deep penetration it throws them across the level. A deep embed climbs out over a few ticks.
	var push := minf(
		resting.depth + tunables.skin_width,
		maxf(tunables.step_height, tunables.skin_width * 2.0)
	)

	state.position += resting.normal * push
	depenetrated_ticks += 1

	return true


## Lifts a player who is inside geometry until they are not, and says whether it worked.
## Straight up and never further than a step: the player got here by sinking through a surface they stood on. Lifting further would be a teleport.
## The lift doubles each try (about nine overlap queries to cover a step, not hundreds), landing up to twice as high as needed; the next ground probe brings them back down. Deterministic: shape queries and arithmetic only.
func _lift_clear(state: DotFpsState, height: float) -> bool:
	var lift := maxf(tunables.skin_width * 2.0, 0.0005)
	var limit := maxf(tunables.step_height, lift)
	var moved := 0.0

	while moved < limit:
		moved = minf(moved + lift, limit)
		var centre := _capsule_centre(state.position + Vector3.UP * moved, height)

		if not body.overlaps(centre, height, tunables.radius):
			state.position.y += moved
			return true

		if moved >= limit:
			break

		lift *= 2.0

	return false


## Pulls the player back down onto ground they have just walked off the edge of, so walking down a ramp does not get air physics (no friction) one tick in a few.
## [param stood_on] is the floor at the start of the tick. Moving away from it means a launch the snap must not cancel; moving along it is a walk, and at a ramp's crest that walk still points upward.
func _snap_to_ground(
	state: DotFpsState,
	height: float,
	stood_on: Vector3 = Vector3.UP
) -> void:
	if state.velocity.dot(stood_on) > LEAVING_SPEED:
		return

	var centre := _capsule_centre(state.position, height)
	var probe := Vector3.DOWN * tunables.ground_snap_distance

	var hit := _sweep(centre, probe, height)

	# The same quarters as [method _categorise_ground], for the same capsule: pressed
	# against a face that leans back, the whole capsule's probe meets the face and the
	# snap gave up with the floor a couple of centimetres under the player.
	if hit.hit and not _is_floor(hit.normal):
		hit = _quadrant_floor(centre, probe, height)

	if not hit.hit or not _is_floor(hit.normal):
		return

	# Over a crest, still carrying the climb, and fast enough: a launch, not a snap. Left in
	# the air with every bit of its speed (`crest_launch_speed_scale`).
	if (
		tunables.crest_launch_speed_scale > 0.0
		and state.velocity.dot(hit.normal) > LEAVING_SPEED
		and state.velocity.length() >= tunables.max_speed * tunables.crest_launch_speed_scale
	):
		return

	state.position += probe * hit.fraction
	state.mode = DotFpsState.Mode.GROUND
	state.ground_normal = hit.normal
	state.ground_id = hit.collider_id

	# Downward velocity accumulated while briefly airborne is discarded, or the next tick sees a fast descent and un-grounds again (the flicker).
	# Upward velocity belongs to whatever launched the player and is not ours to cancel.
	if state.velocity.y < 0.0:
		state.velocity.y = 0.0
	elif state.velocity.dot(hit.normal) > LEAVING_SPEED:
		# Walked over a crest, still carrying the ramp's climb. Laid along the floor they
		# have been put on, or the next tick reads that climb as leaving it.
		state.velocity = state.velocity.slide(hit.normal)


## Moves the player by its velocity for one tick, colliding and sliding.
## Exposed so a [DotFpsMoveMode] gets the same skin-margin and step handling without re-implementing collide-and-slide.
## [param step] enables stair stepping; a swimming or flying mode wants it off.
func move_and_slide(
	state: DotFpsState,
	delta: float,
	step: bool = false
) -> void:
	var height := _height(state)
	var motion := state.velocity * delta

	if motion.length_squared() <= 0.0:
		return

	var result := _native_move(state.position, state.velocity, motion, height, 1, step)
	if result == null:
		result = _slide(state.position, state.velocity, motion, height)

		if step and result.blocked and tunables.step_height > 0.0:
			var stepped := _slide_with_step(state.position, state.velocity, motion, height)
			if stepped.travelled > result.travelled + tunables.skin_width * 2.0:
				result = stepped

	state.position = result.position
	state.velocity = result.velocity

	if result.ran_out:
		stuck_ticks += 1


## A swept capsule query with the skin margin applied, in world space.
## [param from] is the player's feet, not the capsule centre, the same convention as [member DotFpsState.position].
func probe(
	state: DotFpsState,
	from: Vector3,
	motion: Vector3
) -> DotFpsBody.Hit:
	var height := _height(state)
	return _sweep(_capsule_centre(from, height), motion, height)


## Whether the player's capsule would overlap anything at [param feet].
func would_overlap(state: DotFpsState, feet: Vector3) -> bool:
	var height := _height(state)
	return body.overlaps(_capsule_centre(feet, height), height, tunables.radius)


## Re-runs the ground check. For a mode deciding whether it should hand back.
func categorise_ground(state: DotFpsState) -> void:
	_categorise_ground(state)


## Eye position for a state, for the camera and for anything tracing from the view.
## Slightly below the capsule's top so a ceiling the player touches does not intersect the near plane.
func eye_position(state: DotFpsState) -> Vector3:
	var height := _height(state)
	return state.position + Vector3.UP * (height - tunables.radius * 0.5)


## The full look direction for a yaw and a pitch.
## Public because every game needs it: Godot is Y-up, right-handed and -Z forward, and a re-derivation that gets one sign wrong aims right at the horizon and inverts looking up.
static func aim_for(yaw_degrees: float, pitch_degrees: float) -> Vector3:
	return _view_basis(yaw_degrees, pitch_degrees).forward


func describe() -> Dictionary:
	var mode_names := PackedStringArray()
	for id in _modes:
		mode_names.append(String((_modes[id] as DotFpsMoveMode)._name()))

	return {
		"ticks": ticks_simulated,
		"stuck_ticks": stuck_ticks,
		"depenetrated_ticks": depenetrated_ticks,
		"settled_ground_ticks": settled_ground_ticks,
		"reused_ground_ticks": reused_ground_ticks,
		"surface": _surface.id if _surface != null else &"",
		"effects": _effects.describe() if not _effects.is_neutral() else "neutral",
		"custom_modes": Array(mode_names),
		"modifiers_registered": _modifier_order.size(),
		"tunables": tunables.describe_summary() if tunables != null else "<none>",
		"body": body.describe() if body != null else {},
	}
