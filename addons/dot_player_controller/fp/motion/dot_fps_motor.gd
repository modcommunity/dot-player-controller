class_name DotFpsMotor
extends "dot_fps_motor_native.gd"

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
## The clocks and cooldowns of the prepared tick left to dot-sim's row (bit 0), the tick having begun on the ground
## (bit 1): a fourth meta value for [code]DotSimMotorBatch.run_rows[/code]. Every end but [method batch_apply] runs them here.
var batch_clocks: int = 0


## The start of [method simulate] for a tick that may run in dot-sim's batch with other players' ([DotFpsMotorBatch]): everything before the first world query that depends on another player. On [constant BATCH_READY] row [param row] of [param input] (55 values) and [param meta] ([param meta_len] values, 3 or 4) is filled and [method batch_apply] ends the tick; on [constant BATCH_DEFER] [method batch_resume] does, the same way [method simulate] would have. With 4 the row may leave the clocks to dot-sim ([member batch_clocks], API 31).
func batch_prepare(
	state: DotFpsState, command: DotFpsCommand, delta: float, input: PackedFloat64Array, meta: PackedInt64Array, row: int,
	meta_len: int = 3
) -> int:
	body.begin_tick()
	batch_clocks = 0
	if meta_len > 3 and _clocks_may_wait(state, command):
		_batch_head(state, command)
	elif _simulate_head(state, command, delta):
		body.end_tick()
		return BATCH_DONE
	if profile:
		_lap(0)
	_update_crouch(state, command, delta)
	if profile:
		_lap(1)
	# A walker that may take the idle path asks the world its own way: left to the single tick.
	if profile or (idle_fast_path and _rest_valid and command.move == Vector2.ZERO and command.buttons == 0):
		return _batch_defer(state, command, delta)
	var tick_tun := _native_tick_tun(state)
	if (
		tick_tun.is_empty() or not native_full or _wall_jump_run_in_script(state)
	):
		return _batch_defer(state, command, delta)
	var at := row * meta_len
	batch_body = body.native_batch(meta, at)
	if batch_body == null:
		return _batch_defer(state, command, delta)
	if meta_len > 3:
		meta[at + 3] = batch_clocks
	batch_tun = _native_full_tun(tick_tun)
	_fill_full_in(state, command, delta, input, row * 55)
	return BATCH_READY


## Row [param row] again from the state as it is now (something moved the player after [method batch_prepare]). The
## clocks run here then ([member batch_clocks] is 0 after), on the values the row was filled with: a value the game
## wrote since stays, as it would have over clocks run at prepare.
func batch_refill(state: DotFpsState, command: DotFpsCommand, delta: float, input: PackedFloat64Array, row: int) -> void:
	if batch_clocks != 0:
		var o := row * 55
		var now := []
		for f: Array in _CLOCK_FIELDS:
			now.append(state.get(f[0]))
		for i in _CLOCK_FIELDS.size():
			state.set(_CLOCK_FIELDS[i][0], type_convert(input[o + _CLOCK_FIELDS[i][1]], typeof(now[i])))
		var sent := []
		for f: Array in _CLOCK_FIELDS:
			sent.append(state.get(f[0]))
		_batch_settle(state, command, delta)
		for i in _CLOCK_FIELDS.size():
			if now[i] != sent[i]:
				state.set(_CLOCK_FIELDS[i][0], now[i])
	_fill_full_in(state, command, delta, input, row * 55)


## Ends a [constant BATCH_READY] tick with the batch's answer, the 45 values at [param at] in [param out].
func batch_apply(state: DotFpsState, command: DotFpsCommand, out: PackedFloat64Array, at: int) -> void:
	batch_clocks = 0
	body.native_batch_done(int(out[at + 20]), int(out[at + 21]), int(out[at + 22]))
	_native_full_apply(state, out, at)
	state.previous_buttons = command.buttons
	body.end_tick()


## Ends a [constant BATCH_DEFER] tick, or a [constant BATCH_READY] one the batch had no answer for, in this motor.
func batch_resume(state: DotFpsState, command: DotFpsCommand, delta: float) -> void:
	_batch_settle(state, command, delta)
	_simulate_tail(state, command, delta, true)
	body.end_tick()


## Drops a prepared tick whose player will not tick after all. Its start stays run, clocks included, so a row that left
## them to dot-sim needs the tick's [param state], [param command] and [param delta].
func batch_cancel(state: DotFpsState = null, command: DotFpsCommand = null, delta: float = 0.0) -> void:
	if batch_clocks != 0:
		if state == null or command == null:
			push_error("DotFpsMotor.batch_cancel: the prepared row left its clocks to dot-sim; pass its state, command and delta")
		else:
			_batch_settle(state, command, delta)
	batch_clocks = 0
	body.end_tick()


## The fields [method _advance_clocks] reads or writes, with their index in [method _fill_full_in]'s row.
const _CLOCK_FIELDS := [
	[&"previous_buttons", 19], [&"time_since_jump", 39], [&"time_since_grounded", 40],
	[&"time_since_jump_pressed", 41], [&"slide_time", 42], [&"slide_cooldown_left", 43],
	[&"launch_cooldown_left", 44], [&"dash_cooldown_left", 45], [&"wall_run_cooldown_left", 46],
	[&"wall_run_time", 47], [&"wall_run_spent", 48], [&"wall_jump_count", 49], [&"wall_jumps_in_air", 50],
]


## Whether this tick's start is [method _batch_head]'s: a plain walker whose effects, noclip and stamina are all no-ops.
func _clocks_may_wait(state: DotFpsState, command: DotFpsCommand) -> bool:
	return (
		perf_caches and not profile and _effects_clean and not tunables.stamina_enabled and state.modifiers.is_empty()
		and (state.mode == DotFpsState.Mode.GROUND or state.mode == DotFpsState.Mode.AIR)
		and not _modes.has(state.mode)
		and not (
			tunables.can_noclip and ((command.buttons & ~state.previous_buttons) & DotFpsCommand.BUTTON_NOCLIP) != 0
		)
	)


## [method _simulate_head] where [method _clocks_may_wait]: the same writes but the clocks, which dot-sim's row runs
## ([member batch_clocks]). The modifiers, effects, noclip and mode calls would all return at once.
func _batch_head(state: DotFpsState, command: DotFpsCommand) -> void:
	view_turn = 0.0
	ticks_simulated += 1
	state.tick += 1
	state.yaw = command.yaw
	state.pitch = clampf(command.pitch, tunables.pitch_min, tunables.pitch_max)
	var grounded := state.mode == DotFpsState.Mode.GROUND
	state.ground_ticks = state.ground_ticks + 1 if grounded else 0
	state.sprinting = _wants_sprint(command)
	state.stamina = 1.0
	state.stamina_exhausted = false
	state.stamina_delay_left = 0.0
	_rest_valid = _rest_valid and grounded
	batch_clocks = 3 if grounded else 1


func _batch_settle(state: DotFpsState, command: DotFpsCommand, delta: float) -> void:
	if batch_clocks != 0:
		_advance_clocks(state, command, delta, batch_clocks == 3)
		batch_clocks = 0


func _batch_defer(state: DotFpsState, command: DotFpsCommand, delta: float) -> int:
	_batch_settle(state, command, delta)
	return BATCH_DEFER


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
	var whole := not tick_tun.is_empty() and native_full
	if whole and _wall_jump_run_in_script(state):
		whole = false
		wall_jump_script_ticks += 1
	if whole and _native_tick_full(state, command, delta, tick_tun):
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

	# The wall, probed once a tick and only when a wall move could use it: both are off by default,
	# and a game that leaves them off makes no extra query and simulates what it did before they existed.
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

	_script_tick_end(
		state, command, delta, wall, jumped or launched, start_settled, start_position, start_velocity, start_height
	)


## The end of [method _simulate_tail] when dot-sim did not run it: friction, the wish move, gravity or the surface push,
## the slide, and the end-of-tick ground check. [param left_ground] is a jump or a launch this tick.
func _script_tick_end(
	state: DotFpsState, command: DotFpsCommand, delta: float, wall: DotFpsBody.Hit, left_ground: bool,
	start_settled: bool, start_position: Vector3, start_velocity: Vector3, start_height: float
) -> void:
	if state.mode == DotFpsState.Mode.GROUND and not left_ground:
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
	var settled := _move(state, delta, left_ground)
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


func _advance_timers(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	var grounded := state.mode == DotFpsState.Mode.GROUND
	_advance_clocks(state, command, delta, grounded)
	# Counted in TICKS, not seconds: "jumped on the tick the player landed" is a perfect
	# bunny-hop, and a seconds counter answers that differently at 64 Hz and 128 Hz.
	state.ground_ticks = state.ground_ticks + 1 if grounded else 0
	_tick_stamina(state, command, delta)
	# Without stamina the fields are written to their constants (1, false, 0) above, which are exactly on the wire grid: packing and unpacking them is the identity.
	if tunables.stamina_enabled or not perf_caches:
		DotFpsNetSync.snap_stamina(state)


## The clocks, cooldowns, landing crouch press and wall reset of [method _advance_timers]; dot-sim's
## [code]full::advance_timers[/code] is the same for a batch row. [param grounded]: the tick began on the ground.
func _advance_clocks(state: DotFpsState, command: DotFpsCommand, delta: float, grounded: bool) -> void:
	state.time_since_jump = minf(state.time_since_jump + delta, TIMER_CAP)

	if grounded:
		_landing_counts_as_crouch_press(state, command)
		state.time_since_grounded = 0.0
		if tunables.wall_run_enabled or tunables.wall_jump_enabled:
			_reset_walls(state)
	else:
		state.time_since_grounded = minf(state.time_since_grounded + delta, TIMER_CAP)

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


func _wants_sprint(command: DotFpsCommand) -> bool:
	var t := tunables
	return (
		t.can_sprint and (command.buttons & DotFpsCommand.BUTTON_SPRINT) != 0
		and command.move.length_squared() > 0.0001 and not _effects.deny_move
		and not (t.can_crouch and (command.buttons & DotFpsCommand.BUTTON_CROUCH))
		and not (t.can_walk and (command.buttons & DotFpsCommand.BUTTON_WALK))
	)


## Decides whether this tick sprints and moves stamina. Crouch and walk win over sprint, as in speed_for.
func _tick_stamina(state: DotFpsState, command: DotFpsCommand, delta: float) -> void:
	var t := tunables
	var wants := _wants_sprint(command)
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


## The first tick on the ground after a real stretch in the air (time_since_grounded still holds it) with crouch held sees crouch as pressed again,
## so a crouch pressed in the air (off a wall run, after a jump) starts the slide its press would have on the ground.
## Done on the replicated previous buttons before anything reads them, so script, dot-sim's whole tick and the batch all see the same press; [constant WALL_ENTRY_MIN_AIR] keeps a one-tick kerb bump at a crouched run from counting as a landing; a crouch that also launches or dashes is left alone.
func _landing_counts_as_crouch_press(state: DotFpsState, command: DotFpsCommand) -> void:
	var crouch := DotFpsCommand.BUTTON_CROUCH
	if (
		tunables.slide_enabled and not state.is_sliding()
		and state.time_since_grounded >= WALL_ENTRY_MIN_AIR
		and command.is_pressed(crouch)
		and ((tunables.launch_button | tunables.dash_button) & crouch) == 0
	):
		state.previous_buttons &= ~crouch


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


## The "never happened" value the timers start at; they stop here, because a float32 timer past it
## rounds differently on the client and the server and reads as a misprediction every few ticks.
const TIMER_CAP := 1000.0


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
