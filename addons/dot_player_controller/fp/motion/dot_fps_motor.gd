class_name DotFpsMotor
extends RefCounted

## The movement simulation. Deterministic, engine-independent, and the only place
## movement rules live.
##
## [codeblock]
## var motor := DotFpsMotor.new(tunables, body)
## motor.simulate(state, command, 1.0 / 60.0)
## [/codeblock]
##
## [b]The contract, and why it is worth the discipline.[/b] Given the same
## [DotFpsState], the same [DotFpsCommand], the same delta and the same world,
## [method simulate] produces the same result on every machine. That single property
## is what lets a client predict its own movement and a server correct it: the client
## applies input immediately, the server applies the identical input a round trip
## later, and the two agree — so nothing has to be corrected and the player sees no
## rubber-banding. Break it and reconciliation corrects every tick forever, which
## feels exactly like packet loss and is diagnosed as such for weeks.
##
## Concretely, nothing in here may read the keyboard, the wall clock, an unseeded
## random stream, the frame rate, or any node's transform. Time comes from
## [param delta]; intent comes from the command; the world comes from [DotFpsBody].
## Every timer in [DotFpsState] is counted in simulated seconds for the same reason.
##
## [b]The movement model is the classic one.[/b] Ground acceleration toward a wish
## direction with friction, and airborne acceleration capped at a small absolute
## speed — which is not a limitation but the entire mechanism behind air-strafing and
## bunny-hopping. See [method accelerate].

const CHANNEL := "fps.motor"

## Fraction of a sweep's length treated as untrustworthy at its far end.
##
## [b]A swept query's precision is relative to how far it swept.[/b] Godot's
## [method PhysicsDirectSpaceState3D.cast_motion] binary-searches for the contact
## point and stops at a tolerance proportional to the motion, so the "safe" fraction
## it returns can still overlap by around a percent of the sweep length. On a 12 cm
## slide step that is a tenth of a millimetre and invisible. On the 35 cm ground-snap
## probe it is three and a half millimetres — enough to place the player [i]below[/i]
## the floor they were snapping onto, after which every subsequent query starts inside
## geometry and reports nothing, and they sink through the world at a constant rate.
##
## So the margin scales with the sweep rather than being a fixed skin width. Costs a
## sub-centimetre gap on the longest probe, which nothing can see and the ground check
## comfortably spans.
const SWEEP_TOLERANCE := 0.02

## Speed away from a surface, in m/s, above which a player has left it rather than
## resting on it. Measured along the ground normal when they are standing, so walking
## up a slope is not leaving it — see [method _categorise_ground].
const LEAVING_SPEED := 0.1

var tunables: DotFpsTunables
var body: DotFpsBody

## Surfaces this motor knows about. Null means every surface behaves the same.
var surfaces: DotFpsSurfaceSet = null

## Maps the collider a ground probe hit to a surface id.
##
## [b]Must be pure and must agree across machines.[/b] It runs inside the simulation,
## so a client and a server that resolve different surfaces for the same floor
## disagree about friction and the prediction never settles.
## [DotFpsController] installs one that reads scene metadata, which both machines
## load from the same file. Resolving from the collider's instance id would not work:
## those differ between processes.
var surface_resolver: Callable = Callable()

## Modifier definitions by id. The active set lives in [DotFpsState].
var modifier_defs: Dictionary = {}

## Modifier ids in registration order, so an index is stable and can be replicated.
var _modifier_order: Array[StringName] = []

## Custom modes by id, from [constant DotFpsState.FIRST_CUSTOM_MODE] up.
var _modes: Dictionary = {}

## The combined effect of the active modifiers, recomputed once per tick.
##
## Reused rather than allocated: this is read several times per tick per player, and
## on a server simulating thirty of them the allocations are measurable.
var _effects := DotFpsModifier.Aggregate.new()

## The surface under the player this tick. Never null after [method simulate] starts.
var _surface: DotFpsSurface = null

## Ticks simulated by this motor. Diagnostic.
var ticks_simulated: int = 0

## Slides started and launches made by this motor, replays included. Diagnostic: the
## controller's signals are what a game should react to, because they skip replays.
var slides: int = 0
var launches: int = 0
var dashes: int = 0
var wall_runs: int = 0
## Degrees the view should turn after the last [method simulate] (a jump-started run turning along its wall); 0 when none. An output: the owning client applies it to its look input.
var view_turn: float = 0.0
var wall_jumps: int = 0

## Ticks where the collide-and-slide ran out of iterations with motion left.
##
## Non-zero means the player is in geometry tight enough that the slide could not
## resolve it — a wedge, a corner of three surfaces. A few are normal; a rising count
## is a level-geometry problem that will read to players as getting stuck.
var stuck_ticks: int = 0




## Ticks on which a player was found INSIDE geometry with no floor under them.
##
## [b]This is "I went through the floor", counted.[/b] It is the one number that says so:
## an overlap test from outside the simulation cannot, because a capsule resting a
## millimetre above a floor overlaps it too — shapes have margins — so "is the player in
## solid" answers yes for everybody standing anywhere. The distinction that matters is
## the one [method _categorise_ground] already makes and had no way to report: the ground
## probe found nothing AND the player is in something.
var embedded_ticks: int = 0

## How many of those were lifted back out. See [method _lift_clear].
##
## The two together are the whole measurement: `embedded_ticks` is how often it happens,
## and the gap between them is how often a player is left under the floor to walk around
## in the dark until they respawn — which before there was a lift was all of them.
var lifted_ticks: int = 0
## Ticks whose move stopped early on a plane it had already resolved against.
##
## The intended path rather than a fault, but a tick that ends this way spends only part
## of its motion — so a high count on a surface a player should be flowing across is
## worth looking at even though nothing is wrong on any single tick. Close to zero on
## hand-built geometry; 10% to 14% of ticks on a map imported as one convex hull per
## brush, where a curved ramp is a fan of faces a degree apart and every one of them is
## a near-copy of the last.
var duplicate_plane_ticks: int = 0
## Duplicate-plane legs that went nowhere whole and were spent split into their vertical and
## horizontal parts ([method _split_leg]): a capsule touching two faces whose rest query named
## the one it was not moving into. Zero almost everywhere; rising, somebody is in a corner.
var split_leg_ticks: int = 0
## Duplicate-plane legs spent along a crease the slide was never told about
## ([method _leave_crease]): the capsule sat in a two-face wedge and every query named the
## same one of the two. Zero off a crease; on a V of two surf slabs, a few per ride.
var crease_leg_ticks: int = 0

## Ticks that began with the capsule inside geometry and pushed it back out.
##
## [b]Not the same measurement as [member embedded_ticks], and the difference is the
## bug it was added for.[/b] That one counts a player who is embedded AND was grounded
## last tick, which is the only case [method _categorise_ground] could recover; a
## surfer is never grounded, so a player sinking through a ramp incremented nothing at
## all. Every counter on this motor read zero through a measured 83 cm of penetration.
##
## Expect a small non-zero number on any real map — resting contact and overlap are
## the same thing to within a margin, so a tick or two of a few microns is ordinary.
## A count that tracks the tick rate on one surface is that surface eating players.
var depenetrated_ticks: int = 0

## Ticks whose end-of-tick ground check was not re-run because the ground snap's check in
## [method _move], or for a walker who did not move the tick's first check, had already
## settled the same question on the same state. Diagnostic;
## see [method _categorise_ground_settled].
var settled_ground_ticks: int = 0
func _init(p_tunables: DotFpsTunables, p_body: DotFpsBody) -> void:
	tunables = p_tunables
	body = p_body
	_surface = DotFpsSurface.make(&"default")


# --- Extension registries --------------------------------------------------

## Registers a custom movement mode and returns its id.
##
## Ids must be handed out in the same order on every machine, because the id is what
## travels on the wire. Register them at startup, in a fixed order, from code both
## sides run — not from anything conditional on being a client or a server.
func register_mode(mode: DotFpsMoveMode) -> int:
	if mode == null:
		return -1

	for existing_id in _modes:
		var existing: DotFpsMoveMode = _modes[existing_id]
		if existing._name() == mode._name():
			DotLog.warn(
				CHANNEL,
				"a mode with this name is already registered; reusing its id",
				{"name": String(mode._name()), "id": existing_id}
			)
			return existing_id

	var id := DotFpsState.FIRST_CUSTOM_MODE + _modes.size()

	if id >= DotFpsState.MAX_MODES:
		DotLog.error(
			CHANNEL,
			"too many movement modes; the wire format cannot carry this one",
			{"max": DotFpsState.MAX_MODES, "name": String(mode._name())}
		)
		return -1

	mode.mode_id = id
	_modes[id] = mode

	return id


func mode_for(id: int) -> DotFpsMoveMode:
	var found: Variant = _modes.get(id)
	return found if found is DotFpsMoveMode else null


func mode_id_of(name: StringName) -> int:
	for id in _modes:
		if (_modes[id] as DotFpsMoveMode)._name() == name:
			return id
	return -1


func mode_name(id: int) -> String:
	return DotFpsState.mode_name(id, self)


## Switches mode, running the exit and enter hooks.
##
## The only supported way to change [member DotFpsState.mode] — assigning it directly
## skips the hooks, so a mode that allocated something in [method DotFpsMoveMode._enter]
## never gets told to release it.
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


## Registers a modifier definition. Returns its index, which is what replicates.
##
## Like modes, the registration order is part of the contract between machines.
func register_modifier(modifier: DotFpsModifier) -> int:
	if modifier == null or modifier.id == &"":
		DotLog.warn(CHANNEL, "a modifier needs an id")
		return -1

	if modifier_defs.has(modifier.id):
		modifier_defs[modifier.id] = modifier
		return _modifier_order.find(modifier.id)

	if _modifier_order.size() >= 32:
		# The active set is replicated as a 32-bit mask. Silently dropping the 33rd
		# would make it apply on the server and not on the client, which is a
		# divergence that only shows up for whoever picks up that one power-up.
		DotLog.error(
			CHANNEL,
			"too many modifiers; the active set is a 32-bit mask",
			{"id": String(modifier.id)}
		)
		return -1

	modifier_defs[modifier.id] = modifier
	_modifier_order.append(modifier.id)

	return _modifier_order.size() - 1


func modifier_index(id: StringName) -> int:
	return _modifier_order.find(id)


func modifier_at(index: int) -> DotFpsModifier:
	if index < 0 or index >= _modifier_order.size():
		return null
	return modifier_defs.get(_modifier_order[index])


## Applies a modifier to a state. Returns whether anything changed.
##
## Server-side in a networked game: the active set is replicated to the owner, which
## is what lets the client predict the effect instead of feeling it a round trip late.
func add_modifier(state: DotFpsState, id: StringName) -> bool:
	var index := modifier_index(id)
	var definition: DotFpsModifier = modifier_defs.get(id)

	if index < 0 or definition == null:
		DotLog.warn(CHANNEL, "unknown modifier", {"id": String(id)})
		return false

	var expiry := -1
	if definition.duration_sec > 0.0:
		expiry = state.tick + int(ceilf(definition.duration_sec * _tick_rate_hint))

	# Sorted insert by index, so two machines that applied the same set in different
	# orders still hold it in the same order — see DotFpsState.modifiers.
	var slot := 0
	while slot < state.modifiers.size() and state.modifiers[slot].x < index:
		slot += 1

	if slot < state.modifiers.size() and state.modifiers[slot].x == index:
		if not definition.refreshable:
			return false
		state.modifiers[slot] = Vector2i(index, expiry)
		return true

	state.modifiers.insert(slot, Vector2i(index, expiry))

	if definition.impulse_clears_velocity:
		state.velocity = Vector3.ZERO

	if definition.impulse != Vector3.ZERO:
		state.velocity += definition.impulse
		# A launch is a departure. Leaving the mode alone would let the ground check
		# at the end of the tick decide the player never left, and the impulse would
		# be eaten by the ground snap.
		if definition.impulse.y > 0.0:
			state.mode = DotFpsState.Mode.AIR
			state.time_since_grounded = 1000.0

	return true


func remove_modifier(state: DotFpsState, id: StringName) -> bool:
	var index := modifier_index(id)

	for i in range(state.modifiers.size()):
		if state.modifiers[i].x == index:
			state.modifiers.remove_at(i)
			return true

	return false


func has_modifier(state: DotFpsState, id: StringName) -> bool:
	# Nearly every player nearly always has none, and the answer is then no for every id;
	# the lookup below is a linear search of the registered ids, asked a dozen times a tick
	# per player by the admin-modifier readers.
	if state.modifiers.is_empty():
		return false

	var index := modifier_index(id)

	for entry in state.modifiers:
		if entry.x == index:
			return true

	return false


## Ticks per second, used only to turn a modifier's duration into an expiry tick.
##
## Set by whatever drives the motor. It does not have to be exact for the simulation
## to be correct — it only decides which tick a modifier ends on — but it does have to
## be the same on both machines, or a boost lasts longer on one of them.
var _tick_rate_hint: float = 60.0


func set_tick_rate(rate: int) -> void:
	_tick_rate_hint = float(maxi(1, rate))


# --- The tick --------------------------------------------------------------

## Advances [param state] by one tick under [param command].
##
## The order of operations is the classic one and is not arbitrary: the ground is
## categorised before acceleration so that friction and the acceleration constant are
## chosen for the surface the player is actually on, and again after the move so the
## next tick's ground state reflects where the player ended up. Swapping them makes
## the first airborne tick use ground friction, which is the difference between a
## jump that gains speed and one that does not.
func simulate(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	if delta <= 0.0:
		return
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
	var custom := mode_for(state.mode)

	if custom != null:
		if custom._uses_crouch():
			_update_crouch(state, command, delta)

		custom._simulate(state, command, delta, self)
		state.previous_buttons = command.buttons
		return

	if state.mode == DotFpsState.Mode.NOCLIP:
		_simulate_noclip(state, command, delta)
		state.previous_buttons = command.buttons
		return

	_update_crouch(state, command, delta)

	# Before the ground is categorised, because a probe that starts inside geometry
	# reports nothing and the answer it produces is the one this whole tick is built
	# on. Unconditional rather than gated on a mode: the case it exists for is a
	# player in AIR on a ramp, which is exactly the case every earlier guard excluded.
	_depenetrate(state, _height(state))

	var start_settled := _categorise_ground_settled(state)
	var start_position := state.position
	var start_velocity := state.velocity
	var start_height := _height(state)

	var jumped := _try_jump(state, command, delta)

	# The wall, probed once a tick and only when a wall move could use it: both are off
	# by default, and a game that leaves them off makes no extra query and simulates what
	# it did before they existed.
	var wall := _wall_contact(state, command)
	var wall_jumped := false
	if not jumped and not _try_jump_run(state, wall):
		wall_jumped = _try_wall_jump(state, command, wall)

	var launched := _try_launch(state, command)
	launched = _try_dash(state, command) or launched

	# After the jump and the launch, because both end a slide by leaving the ground, and
	# before friction, because a slide is what decides which friction this tick gets.
	_update_slide(state, command, delta, jumped or launched)
	_update_wall_run(state, command, delta, wall, jumped or wall_jumped or launched)

	if state.mode == DotFpsState.Mode.GROUND and not jumped and not launched:
		_apply_friction(state, delta)
	elif tunables.air_friction > 0.0:
		_apply_air_friction(state, delta)

	_apply_wish_move(state, command, delta)

	if state.mode == DotFpsState.Mode.GROUND:
		# A conveyor, a slick slope, a wind volume. Applied as an acceleration rather
		# than as a velocity so it composes with friction instead of fighting it.
		if _surface.push != Vector3.ZERO:
			state.velocity += _surface.push * delta
	elif state.is_wall_running():
		_wall_run_vertical(state, delta)
	else:
		var falling_at := state.velocity.y
		state.velocity.y -= tunables.gravity * _effects.gravity * delta
		if _wall_slides(state, command, wall):
			_wall_slide_vertical(state, falling_at, delta)

	_clamp_velocity(state)
	var settled := _move(state, delta, jumped or launched)

	# After the move, so the next tick starts from the truth rather than from where
	# the player was before sliding into a wall or off a ledge.
	#
	# [b]Unless the move's own check already is that truth.[/b] A grounded walker's
	# [method _move] categorises after the slide (for the ground snap), and nothing runs
	# between that and here. When that check changed nothing but the ground fields and left
	# the player GROUNDED as it found them, running it again is the same function of the
	# same inputs: it would make the same queries, get the same answers and write the same
	# fields. [method _categorise_ground_settled] says when that is provable; it is one
	# ground probe a tick (plus four quarter probes against a wall) for every walker.
	# Likewise a walker who did not move this tick: the start's check was a fixed point, and
	# mode, position, velocity and height are as it left them, so it would repeat exactly.
	if settled or (
		start_settled and state.mode == DotFpsState.Mode.GROUND
		and state.position == start_position and state.velocity == start_velocity
		and _height(state) == start_height
	):
		settled_ground_ticks += 1
	else:
		_categorise_ground(state)

	state.previous_buttons = command.buttons


# --- Modifiers -------------------------------------------------------------

## Drops modifiers whose expiry tick has passed.
##
## Compared against the simulated tick, not a clock, so a replay expires them on
## exactly the tick the original run did.
func _expire_modifiers(state: DotFpsState) -> void:
	if state.modifiers.is_empty():
		return

	var i := state.modifiers.size() - 1

	while i >= 0:
		var entry := state.modifiers[i]
		if entry.y >= 0 and state.tick >= entry.y:
			state.modifiers.remove_at(i)
		i -= 1


func _rebuild_effects(state: DotFpsState) -> void:
	_effects.reset()

	for entry in state.modifiers:
		var definition := modifier_at(entry.x)
		if definition != null:
			_effects.apply(definition)


## The combined modifier effect for the tick in progress.
##
## Public so a [DotFpsMoveMode] scales by the same numbers the built-in modes do —
## a ladder that ignored a slow field would be a way to escape one.
func effects() -> DotFpsModifier.Aggregate:
	return _effects


## The surface under the player, or the default. Never null.
func surface() -> DotFpsSurface:
	return _surface


func _resolve_surface(state: DotFpsState) -> void:
	if surfaces == null:
		return

	var id := state.surface
	_surface = surfaces.get_surface(id)


# --- Timers ----------------------------------------------------------------

func _advance_timers(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float
) -> void:
	state.time_since_jump += delta

	if state.mode == DotFpsState.Mode.GROUND:
		state.time_since_grounded = 0.0
		# Counted in TICKS, not seconds, and deliberately so: "did the jump go out on
		# the same tick the player landed" is the definition of a perfect bunny-hop,
		# and it is a tick question. A seconds counter compared against a tick
		# duration answers it differently at 64 Hz and at 128 Hz, which is exactly
		# the thing a timer's statistics must not do.
		state.ground_ticks += 1

		if tunables.wall_run_enabled or tunables.wall_jump_enabled:
			_reset_walls(state)
	else:
		state.time_since_grounded += delta
		state.ground_ticks = 0

	var jump_pressed := (
		(command.buttons & ~state.previous_buttons) & DotFpsCommand.BUTTON_JUMP
	) != 0

	if jump_pressed:
		state.time_since_jump_pressed = 0.0
	else:
		state.time_since_jump_pressed += delta

	state.slide_cooldown_left = maxf(state.slide_cooldown_left - delta, 0.0)
	state.launch_cooldown_left = maxf(state.launch_cooldown_left - delta, 0.0)
	state.dash_cooldown_left = maxf(state.dash_cooldown_left - delta, 0.0)
	state.wall_run_cooldown_left = maxf(state.wall_run_cooldown_left - delta, 0.0)


# --- Noclip ----------------------------------------------------------------

func _update_noclip(state: DotFpsState, command: DotFpsCommand) -> void:
	# Before the ability gate, because this is the case where somebody else decided. An
	# administrator's noclip arrives as a modifier (DotFpsModifier.forces_noclip), which
	# is in the replicated state — so this line runs identically on the server and in the
	# client's replay, and the button, which the player still holds, is ignored while it
	# is in force.
	if _effects.force_noclip:
		if state.mode != DotFpsState.Mode.NOCLIP:
			state.mode = DotFpsState.Mode.NOCLIP
			state.velocity = Vector3.ZERO
		return

	if not tunables.can_noclip:
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


# --- Crouching -------------------------------------------------------------

## Moves the crouch fraction toward what the player is holding, if it fits.
##
## [b]The standing-up test is the part that matters.[/b] The previous controller
## lerped a camera offset and never resized the collider or checked for headroom, so
## releasing crouch under a low ceiling pushed the player through it. Here standing up
## is attempted, tested, and abandoned for this tick if it does not fit — so a player
## holding a wall of geometry above them simply stays crouched and stands the moment
## they step clear.
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
##
## On the ground the feet stay put and the head moves — the player does not sink into
## the floor. Airborne the head stays put and the feet come up, which is the
## crouch-jump: it clears a ledge a standing jump cannot, and players who have played
## a shooter expect it to work.
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


# --- Ground ----------------------------------------------------------------

## Decides whether the player is standing on something.
##
## A short downward sweep rather than a contact list, because contacts are a property
## of the last physics step and this has to be answerable at any point in the tick,
## including mid-slide.
func _categorise_ground(state: DotFpsState) -> void:
	_categorise_ground_settled(state)


## [method _categorise_ground], answering whether this call was a FIXED POINT: whether a
## second call on the state it leaves would make exactly the same queries and write exactly
## the same values. True only on the floor branch, for a player who was GROUNDED on entry
## and whose position and velocity it did not touch (no [method _keep_skin] lift, no slide
## onto the floor). The argument, because it is what makes skipping the second call safe:
## the function reads the mode, position, velocity, crouch height and -- only in the rising
## branch -- the ground normal. Mode, position, velocity and height are unchanged, so the
## probe, [method _standable_normal] and the quarter probes repeat exactly, against a world
## nothing has stepped. The ground normal is now the floor's, and the rising branch then
## tests [code]velocity . floor <= LEAVING_SPEED[/code], which held here or the slide onto
## the floor would have changed the velocity. Every other branch -- AIR, the embedded
## recovery, an unstandable surface -- answers false and is simply run again.
func _categorise_ground_settled(state: DotFpsState) -> bool:
	if state.mode == DotFpsState.Mode.NOCLIP:
		return false

	var was_grounded := state.mode == DotFpsState.Mode.GROUND
	var position_in := state.position
	var velocity_in := state.velocity
	var rising := state.velocity.y > LEAVING_SPEED

	# Moving upward fast enough to have left the ground is not on it, whatever is
	# under the feet. Without this the tick a jump starts still counts as grounded,
	# gravity is skipped, ground friction applies, and the jump loses most of its
	# height for no visible reason.
	#
	# [b]Upward is not the same as away from the ground[/b], and this used to treat
	# them as one: `velocity.y > 0.1` put every player walking up any walkable slope in
	# AIR on the first tick of it — 18 degrees at 6.5 m/s is 2 m/s upward ALONG the
	# surface — so nothing in the family could walk up a ramp. A grounded player is asked
	# the question below, after the probe, against the plane.
	#
	# [b]And so is an airborne one that is only rising slowly.[/b] Landing while moving
	# uphill makes exactly the same velocity: the slide clips it onto the face, and
	# walking pace along 13 degrees is 0.4 m/s upward. Leaving here without a query kept
	# that player in AIR; gravity took a third of a metre per second off, the next slide
	# put it back, and they glided up the slope at air speed until a tick happened to end
	# inside the probe's two centimetres — over a second, in one game. Only a rise of more
	# than half a jump's launch skips the query: that is a jump or a launch, the classic
	# movement model draws its own line at the same ratio, and it is what keeps a jump
	# into a steep uphill from landing on the tick it leaves, and a bunny-hopper crossing a
	# walkable ramp at speed from being put on it.
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

	var hit := _sweep(centre, probe, height)
	var floor_normal := _standable_normal(state, hit)

	# [b]A face too steep to stand on is asked again, in quarters[/b] (`[steep-climb-1]`).
	# A capsule pressed against a face that leans back touches it with its rounded
	# bottom, so the probe reports the face and not the floor the player is standing on,
	# and a walker was put in AIR at the foot of it. Air acceleration into the face then
	# carried them 2.5 m up a 70 degree wall, where they hung. The classic movement code
	# has the same problem with its box and answers it by tracing four quarter-boxes when
	# the whole one hits a steep plane: a quarter away from the face still finds the
	# floor. Four half-radius capsules, each offset toward one quarter, do the same here,
	# over the same probe distance, and only a floor counts.
	if floor_normal == Vector3.ZERO and hit.hit and not _is_floor(hit.normal):
		var quarter := _quadrant_floor(centre, probe, height)
		if quarter.hit:
			hit = quarter
			floor_normal = quarter.normal

	if rising:
		# Moving up, and either grounded last tick or airborne and rising slowly (above).
		# That is a walk up a slope, or a landing on one, when the velocity lies in the
		# ground plane — along the floor under the feet now, or the one stood on last
		# tick, which is the crest of a ramp (UP for an airborne player, so never) — and a
		# launch when it points out of both. A jump never reaches this: [method _try_jump] puts the player in AIR
		# itself, and its launch is `jump_velocity * normal.y` out of any floor, which is
		# metres per second against a tenth. So is anything a game throws them with.
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

		# Along the floor they are on now. At a ramp's crest the velocity still points
		# up the ramp, and leaving it there makes the next tick see 2 m/s away from the
		# flat top and throw a walker a tenth of a metre into the air. Changes nothing
		# on the slope itself, where it is already in the plane.
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

	# The recovery path, and the reason it is worth an extra query.
	#
	# A swept query cannot report anything useful about a shape that starts inside
	# geometry — Godot's returns "no collision", which is technically about the sweep
	# and reads as "nothing below me". A player who is embedded by a fraction of a
	# millimetre therefore looks airborne, falls, embeds further, and leaves the
	# level. Every collision backend has some version of this and none of them fail
	# safely.
	#
	# So a player who was on the ground and now appears not to be is asked the one
	# question a swept query cannot answer: are we inside something? If so they stay
	# grounded and keep their previous floor normal. The cost is one overlap test on
	# the tick a player leaves the ground, which is rare; the alternative is an
	# occasional, unreproducible fall through the world.
	if was_grounded and body.overlaps(centre, height, tunables.radius):
		embedded_ticks += 1
		# [b]And then get them OUT, which is the half that was missing.[/b] Staying
		# grounded stops the fall out of the level and does nothing at all about being
		# inside the floor: the probe above still starts in geometry next tick, still
		# reports nothing, and still arrives here — so this branch answers GROUND for
		# ever, keeps a stale [member DotFpsState.ground_normal], and skips the one
		# call that could have lifted the player out, because [method _move] runs
		# [method _snap_to_ground] only when this function says they are NOT grounded.
		#
		# It is an absorbing state. Every route into it is a bug somewhere else — a
		# grazing landing at bhop speed leaves about a millimetre of vertical clearance,
		# and the snap's 35 cm sweep is a 7 mm margin against a backend tolerance nobody
		# measured — but the reason it is *noticed* is that there is no route out. A
		# player goes through the floor and is then stuck under it until they respawn,
		# which is exactly how it was reported.
		#
		# So: lift them clear first, and keep the old answer only if that fails. A
		# player who is not embedded any more is one the ordinary probe can find a floor
		# for on the very next tick.
		# [b]Only when the probe saw nothing.[/b] A probe that reported a steep surface
		# at fraction 0 has found a WALL the capsule is a hair inside — a step that
		# dropped back beside a kerb leaves it 0.1 mm into the face — and straight up is
		# not out of a wall: it lifted a walker held against a 0.46 m kerb 0.13 m into
		# the air, and from there the next step cleared the kerb. [method _depenetrate]
		# leaves a wall along its own normal at the start of the next tick; until then
		# the old answer stands.
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


# --- Jumping ---------------------------------------------------------------

## Applies a jump if one is owed. Returns whether it fired.
##
## Coyote time and jump buffering are both here because both are about a press
## landing slightly outside the window where it is strictly legal, and a player reads
## either failure as the game dropping the input rather than as their own timing.
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

	# Only while descending or level. Without this a player under a ceiling can jump
	# repeatedly on the way up and climb it.
	#
	# Level with the ground they are standing on, not with the horizon: a player walking
	# up a slope is moving upward and is on the ground, and asking `velocity.y` refused
	# every jump on every uphill. Airborne (coyote time) the normal is UP, so it is the
	# same question it always was.
	var normal := state.ground_normal if state.mode == DotFpsState.Mode.GROUND else Vector3.UP
	if state.velocity.dot(normal) > LEAVING_SPEED:
		return false

	var launch := (
		tunables.jump_velocity() * _surface.jump_scale * _effects.jump
	)

	# A surface or a modifier can make jumping impossible, and that has to mean the
	# jump does not happen rather than a jump of zero height: a jump of zero still
	# leaves the ground for a tick, which loses ground friction and reads as the
	# player twitching in place while stuck to flypaper.
	if launch <= 0.0:
		return false

	# The landing cap, applied BEFORE the launch so it measures the
	# speed the player arrived with rather than one the jump has already changed.
	# Off by default: with it on there is no bunny-hopping, which is the whole point
	# of the cvar in those shooters and the whole point of turning it off on a bhop
	# server.
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

	# Coyote time is spent, not refreshed. Leaving it at zero would leave the window
	# open for another jump in mid-air; today the upward-velocity check above happens
	# to close it first, but that is a coincidence of the default jump height and
	# gravity, and it stops being true the moment either is tuned.
	state.time_since_grounded = 1000.0

	# Consumed, so one press cannot be spent twice through the buffer.
	state.time_since_jump_pressed = 1000.0

	return true


# --- Launch ----------------------------------------------------------------

## The launch ability: [member DotFpsTunables.launch_button] throws the player upward.
##
## [b]On the press, not the hold[/b], and read from [member DotFpsState.previous_buttons]
## like the jump buffer, so a replay of the same commands launches on the same tick. The
## upward speed REPLACES a lower one rather than adding to it: added, a launch at the top
## of a jump would go half again as high as one from the ground, and the height of an
## escape would depend on when in a jump it was pressed.
##
## A stun ([code]deny_jump[/code] or [code]deny_move[/code]) refuses it, for the reason a
## stun refuses a jump: an ability that escapes a freeze is a way out of every freeze.
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


# --- Dash ------------------------------------------------------------------

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


# --- Walls -----------------------------------------------------------------

## How finely a wall's heading is counted for [member DotFpsTunables.wall_jump_max_per_wall]:
## eighths of a turn, the width of its replicated field. Coarse, and it does not need to be
## finer: two walls at a right angle are always two headings apart, so a corner is two
## walls, and a single wall is never counted as two however its normal rounds.
const WALL_HEADINGS := 8

## The wall counters' ceiling, the width of their replicated field.
const WALL_JUMP_COUNT_MAX := 3

## Below this horizontal speed, in m/s, the velocity has no direction worth probing along,
## and only the view's directions are asked.
const WALL_PROBE_MIN_SPEED := 0.5


## The wall beside the player this tick, or null. Also writes [member DotFpsState.wall_normal].
##
## [b]Asked fresh every tick, never remembered.[/b] Whether the wall is still there is a
## question about the world, and the world answers it the same way on both machines; a
## normal carried over from the last tick would be one more thing a rewind has to restore.
##
## Probed only when something will use the answer: a run in progress, a run that could
## start (airborne, fast enough, not spent), or a jump press a wall jump could spend. A
## short sideways sweep (`wall_reach`) to each side of the velocity, then along the view's
## four flat directions, and the nearest wall steep enough wins. Every direction is
## needed: a run keeps the wall beside the velocity, while a player touching a wall from a
## standstill has only the view to say where it is.
func _wall_contact(state: DotFpsState, command: DotFpsCommand) -> DotFpsBody.Hit:
	if (
		not tunables.wall_run_enabled
		and not tunables.wall_jump_enabled
		and tunables.wall_slide_speed <= 0.0
	):
		return null

	state.wall_normal = Vector3.ZERO

	if state.mode != DotFpsState.Mode.AIR:
		return null

	var wants_run := (
		tunables.wall_run_enabled
		and (state.is_wall_running() or (
			not state.wall_run_spent
			and state.horizontal_speed() >= tunables.wall_run_min_speed
		))
	)
	var wants_jump := (
		(tunables.wall_jump_enabled or (tunables.wall_run_enabled and tunables.wall_run_on_jump))
		and state.time_since_jump_pressed <= tunables.jump_buffer_time
	)

	var wants_slide := (
		tunables.wall_slide_speed > 0.0
		and state.velocity.y < 0.0
		and (command.move != Vector2.ZERO or state.wall_run_spent)
	)

	if not wants_run and not wants_jump and not wants_slide:
		return null

	var directions: Array[Vector3] = []
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if flat.length() >= WALL_PROBE_MIN_SPEED:
		var side := flat.normalized().cross(Vector3.UP)
		directions.append(side)
		directions.append(-side)

	var view := _view_basis(state.yaw, 0.0)
	directions.append(view.forward)
	directions.append(-view.forward)
	directions.append(view.right)
	directions.append(-view.right)

	var height := _height(state)
	var centre := _capsule_centre(state.position, height)
	var steepest := cos(deg_to_rad(90.0 - tunables.wall_max_angle_from_vertical))
	var best: DotFpsBody.Hit = null

	# [b]A run keeps the wall beside it.[/b] While running, a wall found by the two
	# sideways probes wins over anything nearer behind or ahead: a player who has just
	# jumped off a ledge's end onto the wall beside it has that ledge's end face a hand
	# behind them, and an uncrouch in the air drops the feet past its top. Nearest-wins
	# took that face, whose "along" speed is nothing, and ended the run four ticks in.
	var sideways := 2 if state.is_wall_running() and directions.size() == 6 else 0
	var beside: DotFpsBody.Hit = null

	for index in range(directions.size()):
		var direction := directions[index]
		var hit := _sweep(centre, direction * tunables.wall_reach, height)
		if not hit.hit or absf(hit.normal.y) > steepest:
			continue
		if hit.normal.dot(direction) >= 0.0:
			continue
		if index < sideways and (beside == null or hit.fraction < beside.fraction):
			beside = hit
		if best == null or hit.fraction < best.fraction:
			best = hit

	if beside != null:
		best = beside

	if best != null:
		state.wall_normal = best.normal

	return best


## The wall's normal laid flat and normalised: what "away from the wall" means for a push
## and "along the wall" for a run, whatever the wall's lean.
static func _flat_normal(normal: Vector3) -> Vector3:
	var flat := Vector3(normal.x, 0.0, normal.z)
	return flat.normalized() if flat.length_squared() > 1e-8 else Vector3.ZERO


## A flat normal's heading in eighths of a turn, 0..7.
static func wall_heading_of(normal: Vector3) -> int:
	var turns := atan2(normal.x, normal.z) / TAU
	return posmod(roundi(turns * WALL_HEADINGS), WALL_HEADINGS)


## Whether two headings name the same wall: within one eighth, either way round.
## One either side rather than an exact match, so a wall whose normal sits on a boundary
## is not two walls depending on which side of it the rounding falls.
static func _same_wall(a: int, b: int) -> bool:
	var apart := posmod(a - b, WALL_HEADINGS)
	return apart <= 1 or apart >= WALL_HEADINGS - 1


## Starts, carries and ends a wall run.
##
## [b]Entered only from the air[/b], beside a wall steep enough, moving along it at
## [member DotFpsTunables.wall_run_min_speed] or more and not into it head-on, not falling
## fast, with forward held (when required), and not after a run already ended in this
## airborne stretch. While it lasts the speed along the wall is left alone (nothing here
## writes the horizontal velocity) and gravity is reduced, in [method _wall_run_vertical].
## It ends on the time cap, on losing the wall, on slowing down, on releasing forward, on
## landing, and on any jump or launch, a wall jump included.
func _update_wall_run(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float,
	wall: DotFpsBody.Hit,
	left_this_tick: bool
) -> void:
	if not tunables.wall_run_enabled and not tunables.wall_jump_enabled:
		return

	# Touching the ground resets both wall moves, whichever of them is on. Also done in
	# [method _advance_timers], because a jump off the ground has put the player in AIR by
	# the time this runs, and that tick started on the ground all the same.
	if state.mode == DotFpsState.Mode.GROUND:
		_reset_walls(state)
		return

	if not tunables.wall_run_enabled:
		# A run in progress when a server turns running off ends rather than freezing.
		if state.is_wall_running():
			_end_wall_run(state)
		return

	if state.is_wall_running():
		state.wall_run_time += delta

		if (
			left_this_tick
			or wall == null
			or _effects.deny_move
			or state.wall_run_time >= minf(tunables.wall_run_max_time, DotFpsTunables.WALL_RUN_TIME_LIMIT)
			or _speed_along_wall(state, wall) < tunables.wall_run_end_speed
			or (tunables.wall_run_requires_forward and command.move.y <= 0.0)
			or (
				not tunables.wall_jump_enabled and tunables.wall_run_on_jump
				and state.time_since_jump_pressed <= tunables.jump_buffer_time
			)
		):
			# A wall jump has already ended the run and un-spent it; nothing to do.
			if state.is_wall_running():
				_end_wall_run(state)
		return

	if left_this_tick or wall == null or state.wall_run_spent or _effects.deny_move:
		return

	if state.mode != DotFpsState.Mode.AIR or state.wall_run_cooldown_left > 0.0:
		return

	if tunables.wall_run_requires_forward and command.move.y <= 0.0:
		return

	if state.velocity.y < -tunables.wall_run_max_fall_speed:
		return

	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var into := -flat.dot(normal)

	# Moving away from the wall is leaving it, not running on it.
	if into < -LEAVING_SPEED:
		return

	var along := _speed_along_wall(state, wall)
	if along < tunables.wall_run_min_speed:
		return

	# The angle between the velocity and the wall's plane: 0 along it, 90 straight in.
	var approach := rad_to_deg(atan2(maxf(into, 0.0), along))
	if approach > tunables.wall_run_max_approach_angle:
		return

	state.wall_run_time = 0.0
	wall_runs += 1


func _reset_walls(state: DotFpsState) -> void:
	state.wall_run_time = -1.0
	state.wall_run_spent = false
	state.wall_jump_count = 0
	state.wall_jumps_in_air = 0


func _end_wall_run(state: DotFpsState) -> void:
	state.wall_run_time = -1.0
	state.wall_run_spent = true
	state.wall_run_cooldown_left = tunables.wall_run_cooldown


## A jump press in the air beside a wall starts a run: the heading is turned along the wall at
## the horizontal speed the player had, and the press is spent. Returns whether it started one.
func _try_jump_run(state: DotFpsState, wall: DotFpsBody.Hit) -> bool:
	if not (tunables.wall_run_enabled and tunables.wall_run_on_jump) or wall == null:
		return false

	if state.mode != DotFpsState.Mode.AIR or state.is_wall_running() or state.wall_run_spent:
		return false

	if state.wall_run_cooldown_left > 0.0 or _effects.deny_move or _effects.deny_jump:
		return false

	if state.time_since_jump_pressed > tunables.jump_buffer_time:
		return false

	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := flat.length()
	if normal == Vector3.ZERO or speed < tunables.wall_run_jump_min_speed:
		return false

	var into := -flat.dot(normal)
	if into < -LEAVING_SPEED:
		return false

	var tangent := normal.cross(Vector3.UP)
	if tangent.dot(flat) < 0.0:
		tangent = -tangent
	var approach := rad_to_deg(atan2(maxf(into, 0.0), absf(tangent.dot(flat))))
	if approach > tunables.wall_run_jump_max_angle:
		return false

	var turned := tangent * speed
	state.velocity.x = turned.x
	state.velocity.z = turned.z
	state.time_since_jump_pressed = 1000.0
	state.wall_run_time = 0.0
	wall_runs += 1
	if tunables.wall_run_turn_view:
		var view := forward_for(state.yaw)
		if view.dot(turned.normalized()) > 0.0:
			view_turn = wrapf(rad_to_deg(atan2(-turned.x, -turned.z)) - state.yaw, -180.0, 180.0)
	return true


## Horizontal speed along the wall's face.
func _speed_along_wall(state: DotFpsState, wall: DotFpsBody.Hit) -> float:
	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	return (flat - normal * flat.dot(normal)).length()


## The vertical half of a wall run, in place of gravity.
##
## Gravity scaled by [member DotFpsTunables.wall_run_gravity_scale] (and by a modifier,
## as everywhere), and the vertical speed eased toward zero at
## [member DotFpsTunables.wall_run_vertical_damping] per second. [b]Eased, never set[/b]:
## a player who jumped onto the wall rises a little further and levels off, one who was
## falling is caught over a few ticks, and nothing changes by more than a tick's worth of
## acceleration, at the start, during, or when the run ends and full gravity returns.
func _wall_run_vertical(state: DotFpsState, delta: float) -> void:
	state.velocity.y -= tunables.gravity * tunables.wall_run_gravity_scale * _effects.gravity * delta
	state.velocity.y *= exp(-tunables.wall_run_vertical_damping * delta)


## Whether an airborne player is sliding down a wall this tick: falling, beside a wall, and
## either pushing into it or done running on it (so a run that ends decays into a slide).
func _wall_slides(state: DotFpsState, command: DotFpsCommand, wall: DotFpsBody.Hit) -> bool:
	if tunables.wall_slide_speed <= 0.0 or wall == null or state.velocity.y >= 0.0:
		return false

	if state.mode != DotFpsState.Mode.AIR or state.is_wall_running():
		return false

	if state.wall_run_spent:
		return true

	var basis := _view_basis(state.yaw, 0.0)
	var wish := basis.right * command.move.x + basis.forward * command.move.y
	wish.y = 0.0
	if wish.length_squared() < 1e-6:
		return false

	# Into the wall by more than a glance: about 30 degrees off along it, or steeper.
	return wish.normalized().dot(-_flat_normal(wall.normal)) > 0.5


## The wall slide, after gravity: a fall that reaches [member DotFpsTunables.wall_slide_speed]
## stops gaining speed there, and one that arrived faster is eased down to it,
## exponentially at [member DotFpsTunables.wall_run_vertical_damping], with no gravity on
## top. Never cut to the cap in one tick: the change is at most the tick's gravity or the
## easing's step. [param falling_at] is the vertical speed before this tick's gravity.
func _wall_slide_vertical(state: DotFpsState, falling_at: float, delta: float) -> void:
	var cap := -tunables.wall_slide_speed
	if state.velocity.y >= cap:
		return

	if falling_at >= cap:
		state.velocity.y = cap
	else:
		state.velocity.y = cap + (falling_at - cap) * exp(-tunables.wall_run_vertical_damping * delta)


## A jump off a wall the player is touching or running on. Returns whether it fired.
##
## On the jump press (buffered like a ground jump, never held: holding jump with
## [member DotFpsTunables.auto_hop] on would otherwise wall-jump the instant a wall came
## within reach), in the air, beside a wall steep enough, and not past
## [member DotFpsTunables.wall_jump_max_per_wall] jumps off that wall since the ground.
##
## [b]The speed along the wall is kept[/b] and the push is added on top, so a jump out of a
## run carries the run. The push leans from the wall's normal toward the view by
## [member DotFpsTunables.wall_jump_look_blend], with the part of the look that points
## into the wall dropped first, so the jump always leaves the wall and goes roughly where
## the player is looking. The upward speed replaces a lower one, like the launch's.
func _try_wall_jump(
	state: DotFpsState,
	command: DotFpsCommand,
	wall: DotFpsBody.Hit
) -> bool:
	if not tunables.wall_jump_enabled or wall == null:
		return false

	if not tunables.can_jump or _effects.deny_jump or _effects.deny_move or _effects.jump <= 0.0:
		return false

	if state.mode != DotFpsState.Mode.AIR:
		return false

	if state.time_since_jump_pressed > tunables.jump_buffer_time:
		return false

	if state.time_since_jump < tunables.jump_cooldown:
		return false

	var normal := _flat_normal(wall.normal)
	if normal == Vector3.ZERO:
		return false

	var heading := wall_heading_of(normal)
	var same := state.wall_jump_count > 0 and _same_wall(heading, state.wall_jump_heading)

	if (
		same
		and tunables.wall_jump_max_per_wall > 0
		and state.wall_jump_count >= tunables.wall_jump_max_per_wall
	):
		return false

	if (
		tunables.wall_jump_max_per_air > 0
		and state.wall_jumps_in_air >= tunables.wall_jump_max_per_air
	):
		return false

	var look := _view_basis(state.yaw, 0.0).forward
	look.y = 0.0
	look = look.normalized()
	# Only the part of the look that does not point into the wall.
	look -= normal * minf(look.dot(normal), 0.0)

	var push := normal * (1.0 - tunables.wall_jump_look_blend) + look * tunables.wall_jump_look_blend
	push = push.normalized() if push.length_squared() > 1e-8 else normal

	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	# Whatever was going into the wall is gone (the wall stopped it); along it is kept.
	var kept := flat - normal * minf(flat.dot(normal), 0.0)
	var jumped := kept + push * tunables.wall_jump_push_speed * _effects.jump

	state.velocity.x = jumped.x
	state.velocity.z = jumped.z
	state.velocity.y = maxf(state.velocity.y, tunables.wall_jump_up_speed * _effects.jump)

	state.time_since_jump = 0.0
	state.time_since_jump_pressed = 1000.0
	state.time_since_grounded = 1000.0

	# A jump ends a run, and un-spends running: a jump to the facing wall may run on it.
	state.wall_run_time = -1.0
	state.wall_run_spent = false

	state.wall_jump_count = mini(state.wall_jump_count + 1, WALL_JUMP_COUNT_MAX) if same else 1
	state.wall_jumps_in_air = mini(state.wall_jumps_in_air + 1, WALL_JUMP_COUNT_MAX)
	state.wall_jump_heading = heading
	wall_jumps += 1

	return true


# --- Sliding ---------------------------------------------------------------

## Starts, carries and ends a slide.
##
## [b]A slide is a crouch with different friction and steering, and nothing else.[/b] The
## collider is the crouched one because the crouch button is held — [method _update_crouch]
## already did that this tick — so a slide goes under what a crouch goes under and stands
## up where a crouch does. What changes is [member DotFpsTunables.slide_friction] in place
## of [member DotFpsTunables.friction] and [member DotFpsTunables.slide_accelerate] in
## place of [member DotFpsTunables.accelerate], read by [method _apply_friction] and
## [method _apply_wish_move] from [method DotFpsState.is_sliding].
##
## It starts on the crouch PRESS, grounded, at [member DotFpsTunables.slide_min_speed] or
## more: holding crouch and then running is a crouch-walk, which is what anybody holding
## crouch expects. It ends on releasing crouch, on leaving the ground, at
## [member DotFpsTunables.slide_duration], or below [member DotFpsTunables.slide_end_speed];
## whatever crouch is still held carries on as an ordinary crouch.
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


# --- Acceleration ----------------------------------------------------------

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

	var target := tunables.speed_for(command.buttons) * magnitude * _effects.max_speed

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
##
## Speed is only ever added along [param direction], and only up to
## [param wish_speed] [i]measured as a projection of current velocity onto that
## direction[/i]. On the ground that is an ordinary speed limit.
##
## Airborne, [param cap] clamps the target to about a metre per second while the
## acceleration constant stays large. Turn the view while holding strafe and the wish
## direction is nearly perpendicular to motion, so the projection of a fast velocity
## onto it is near zero — the cap is not reached, the full increment is added, and it
## goes sideways. Repeat every tick and the speed compounds. Nothing here special-cases
## it; it falls out of the projection, which is why it has survived thirty years of
## engines re-implementing this function.
func accelerate(
	state: DotFpsState,
	direction: Vector3,
	wish_speed: float,
	accel: float,
	delta: float,
	cap: float = -1.0
) -> void:
	# The cap applies to the target, not to the increment: `add` is measured against
	# the capped speed while `step` is scaled by the uncapped one. Capping both
	# removes air control entirely, and it is the single most common mistake in a
	# re-implementation of this function.
	# Negative means no cap. Zero is a real value and means no air control at all,
	# which a game that does not want this movement configures deliberately —
	# treating it as "unlimited" gave exactly the opposite of what was asked for.
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


# --- Queries ---------------------------------------------------------------

## The first of four half-radius capsules, one in each quarter of the player, that finds
## a FLOOR along [param probe]. See [method _categorise_ground]. Each sits half a radius
## out along its diagonal, so all four stay inside the player's own footprint, as the
## classic quarter-boxes do: a quarter that poked outside would start its sweep inside
## the very face that made it necessary, or find floor the player is not over.
func _quadrant_floor(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	var half := tunables.radius * 0.5
	for quarter: Vector2 in QUADRANTS:
		var offset := Vector3(quarter.x, 0.0, quarter.y).normalized() * half
		var hit := _sweep(centre + offset, probe, height, half)
		if hit.hit and _is_floor(hit.normal):
			return hit
	return DotFpsBody.Hit.miss()


const QUADRANTS: Array[Vector2] = [
	Vector2(-1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0),
]


## A sweep that always leaves [member DotFpsTunables.skin_width] between the player
## and whatever it hit.
##
## [b]Resting exactly on a surface is a degenerate state and every collision backend
## handles it differently.[/b] Godot's [method PhysicsDirectSpaceState3D.cast_motion]
## reports [i]no collision[/i] when a move ends with the shapes precisely touching —
## which is reasonable, since touching is not overlapping. The consequence is not: a
## player who lands so that their feet come to rest at exactly the floor's height is
## then in a position where every subsequent downward sweep also reports nothing, so
## they are never grounded again and sink through the world at a constant rate. It
## takes one tick where the fall distance happens to equal the remaining gap, which at
## 60 Hz happens within a second or two of ordinary play.
##
## So every query sweeps [member DotFpsTunables.skin_width] further than asked and
## gives the extra distance back. Contact is detected slightly early, the player is
## left slightly clear, and the exactly-coincident case never arises. The returned
## fraction is rescaled to the motion the caller asked about, so call sites read as
## though none of this were happening.
func _sweep(
	centre: Vector3,
	motion: Vector3,
	height: float,
	radius: float = -1.0
) -> DotFpsBody.Hit:
	var length := motion.length()

	if length <= 0.0:
		return DotFpsBody.Hit.miss()

	var direction := motion / length

	# Proportional to the sweep, never less than the configured skin. See
	# SWEEP_TOLERANCE: a fixed margin is correct for a short slide step and far too
	# small for a long probe.
	var margin := maxf(tunables.skin_width, length * SWEEP_TOLERANCE)

	var hit := body.sweep(
		centre, motion + direction * margin, height,
		tunables.radius if radius < 0.0 else radius
	)

	if not hit.hit:
		return hit

	var travelled := clampf(
		hit.fraction * (length + margin) - margin, 0.0, length
	)
	hit.fraction = travelled / length

	return hit


# --- Movement --------------------------------------------------------------

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

	var plain := _slide(state.position, state.velocity, motion, height)

	# Stepping is tried only when it could help: on the ground, actually blocked, and
	# not on the tick a jump left the surface. Attempting it every tick would double
	# the query cost of the most expensive part of the frame for nothing.
	if was_grounded and not jumped and plain.blocked and tunables.step_height > 0.0:
		var stepped := _slide_with_step(state.position, state.velocity, motion, height)

		# Only if it genuinely got further. A step that gains nothing but ends
		# slightly higher would ratchet the player up a wall over many ticks.
		#
		# [b]And by more than a skin.[/b] Raised to step height, the capsule's rounded
		# bottom can slide a millimetre past a kerb's top corner that its straight side
		# could not; dropped back to the floor, that millimetre is inside the kerb's face.
		if stepped.travelled > plain.travelled + tunables.skin_width * 2.0:
			plain = stepped

	state.position = plain.position
	state.velocity = plain.velocity

	# [b]A walker is not lifted by a face they cannot stand on[/b] (`[steep-climb-1]`).
	# Sliding along a face that leans back turns a walk into it partly UP it, and that
	# lift then reads as leaving the floor. The classic walk move zeroes the vertical
	# before it moves and again once the player is still on the ground, so a walk never
	# climbs. Here only the lift the slide ADDED along the floor's normal goes, and only
	# when a steep face did it: a walkable ramp's lift is the floor's own, and a jump
	# never reaches this. With the quarter probes in [method _categorise_ground], this is
	# the other half; either alone still let a walker up a 70 degree face.
	if was_grounded and not jumped and plain.met_steep_face:
		var lift := state.velocity.dot(stood_on) - maxf(velocity_in.dot(stood_on), 0.0)
		if lift > 0.0:
			state.velocity -= stood_on * lift

	if plain.ran_out:
		stuck_ticks += 1

	if plain.stopped_on_duplicate:
		duplicate_plane_ticks += 1

	if was_grounded and not jumped and tunables.ground_snap:
		# Categorise first and snap only if the player actually left the ground.
		#
		# [b]Not just an optimisation.[/b] The snap probe is the longest query in the
		# tick — 35 cm against a 12 cm slide step — and a swept query's precision is
		# proportional to its length, so running it on a player who is already
		# standing still meant re-deriving a position that was already correct from
		# the least precise measurement available. Each tick moved them a fraction of
		# a millimetre further down; after a few dozen they were below the surface,
		# and from there every query starts inside geometry and reports nothing.
		# The player then fell out of the level, half a second after landing on it.
		#
		# It also removes the most expensive query in the frame from the common case,
		# which on a server simulating thirty players is the whole point.
		if _categorise_ground_settled(state):
			return true

		if state.mode != DotFpsState.Mode.GROUND:
			_snap_to_ground(state, height, stood_on)

	return false


## The result of one collide-and-slide.
class MoveResult extends RefCounted:
	var position: Vector3
	var velocity: Vector3
	var travelled: float = 0.0
	var blocked: bool = false
	## Iterations were exhausted with motion remaining: a wedge the slide gave up on.
	var ran_out: bool = false
	## The move stopped early because it met a plane it had already resolved against.
	##
	## Not a failure — see the comment on that branch — but the rest of the tick's motion
	## goes unspent, so a player meeting one every tick keeps their velocity and covers
	## less ground than it implies. Counted separately because telling the two apart is
	## the only reason to count either.
	var stopped_on_duplicate: bool = false
	## Whether the move met a face too steep to stand on that leans back toward the
	## sky. Sliding along one of those turns a push into a climb.
	var met_steep_face: bool = false


## Collide and slide: move, and on contact continue along the surface.
##
## Velocity is slid as well as motion, so running into a wall at an angle keeps the
## component along it instead of stopping dead — and so the [i]next[/i] tick starts
## from a velocity consistent with what actually happened.
##
## [b]Every plane touched during one move is remembered[/b], and the direction chosen
## after each contact has to satisfy all of them at once. See [method _resolve_planes]
## — that is the part surf depends on, and the part a naive collide-and-slide gets
## wrong.
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

	# The move is carried as (direction-and-speed, fraction of the tick left) rather
	# than as one shrinking "remaining" vector, because the crease resolution below
	# re-derives the direction from the ORIGINAL motion every bump. The classic
	# implementations do the
	# same, and for the same reason: deriving it from the already-clipped vector makes
	# the answer depend on the order the planes happened to be hit in, so a player
	# entering a seam from the left and from the right comes out differently.
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
			# A genuine five-plane corner. There is no direction out, and the classic
			# implementations
			# stops here too: carrying on finds one that leaves the player inside the
			# geometry rather than outside it.
			current = Vector3.ZERO
			result.velocity = Vector3.ZERO
			break

		if outcome == PLANE_DUPLICATE:
			# [b]Spend the rest of the tick along the plane, a skin off it, and stop.[/b]
			# The same plane again at the start of a leg is a capsule resting on it with
			# a velocity that already lies in it — a surfer pressed into a bank. Breaking
			# with nothing more spent none of the tick: the first leg ended touching the
			# face, the second met it again at fraction zero, and the player hung in
			# mid-air with its speed intact — 697 of 1,786 ticks of one bank in
			# game-g2gfast, and every tick of some lines. Lifting the leg off the face
			# by a skin (the classic slide move's one-unit nudge, for the same reason)
			# makes it a leg that leaves the face instead of grazing it.
			#
			# One leg, not a return to the loop: carrying on collects the near-copies
			# of the face a real contact reports, fills the plane list, and zeroes the
			# velocity in a corner that is not there — measured, a surfer stopped dead
			# after 38 ticks. The velocity is not touched; whatever this leg meets is
			# next tick's business.
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
			# [b]Still nothing: step off the face first, then go along it[/b]
			# (`[arrive-3]`). A capsule exactly touching a face is blocked at the
			# first step of cast_motion's bisection by ANY move that starts there,
			# even one leaving the face — and that is where a grazing contact leaves
			# it, since the skin is taken along the motion, not the normal. Measured
			# on a surf_summit displacement, triangles a fraction of a degree apart:
			# the rest query names the face underneath, the plane list calls it a
			# duplicate, and a rider hung there at 75 u/s for good. Lifted a
			# millimetre, the same leg ran 40 cm clear.
			#
			# A wedge first, though: when the face the queries keep naming is one of two
			# the capsule is in, none of the legs below can leave it ([method _leave_crease]).
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
			# The same plane again. The velocity has already been resolved against
			# it, so resolving again is a no-op and the loop would spin until it ran
			# out of iterations. Stop the move and KEEP the velocity.
			#
			# [b]Keeping it is the whole point.[/b] Zeroing here looks tidy, and it
			# is how a player who starts a tick a millimetre inside a surf ramp —
			# which happens on every spawn onto one and after every correction —
			# comes to a dead stop on a surface they should be accelerating down. The
			# first version of this did exactly that and cost a surfer every metre
			# per second they had.
			break

		current = _resolve_planes(planes, motion)
		result.velocity = _resolve_planes(planes, velocity)

	# Motion left over means the move did not complete. [b]That is two different things
	# and this counted them as one.[/b] The duplicate-plane break above leaves exactly
	# this state on purpose — time left, velocity kept — and is documented twenty lines
	# up as the correct outcome; running out of iterations is a player wedged in geometry
	# the slide gave up on. Both set `ran_out`, so [member stuck_ticks] has counted the
	# intended path as a fault since it was written.
	#
	# It matters because that counter is the only instrument anybody would reach for. On
	# an imported map it reads 10% to 14% of all ticks — which looks like a serious
	# collision failure, is almost entirely the early-out working as designed, and hid
	# the genuine figure, which is ONE tick in fifteen thousand. Raising
	# `max_slide_iterations` from 5 to 20 moved it not at all, and that experiment is
	# what separates them.
	if time_left > 1e-6 and current.length_squared() > 1e-12 and not result.stopped_on_duplicate:
		result.ran_out = true

	result.travelled = Vector3(
		result.position.x - start.x, 0.0, result.position.z - start.z
	).length()

	return result


## The duplicate-plane leg's last resort: lift straight off [param normal] by one, two,
## then four skins, and spend [param leg] from there. True and [param result] moved if
## any of them got anywhere; false and untouched if none did (a real pocket, or a
## ceiling a skin away), which leaves the old answer — stop, keep the velocity.
##
## Bounded on purpose: at most four skins off a face the player is already touching,
## along its own normal, so a wrong answer is a few millimetres of air that gravity
## takes back on the next tick. The velocity is not touched.
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


## The duplicate-plane leg's answer in a wedge (`g2gfast-surf-crease-hang-1`, 2026-10-15): find
## the second face, and spend the leg along the crease of the two. True and [param result]
## moved (velocity laid along the crease too) if that got anywhere; false and untouched if
## there is no second face or no way along it.
##
## [b]Two faces equally deep, and the queries name one of them every time.[/b] A surfer
## sliding down the V of two 50 degree slabs sits in both, a fraction of a millimetre deep.
## The rest query reports one contact, and which of two equal ones it picks is the physics
## server's business: in game-g2gfast it changed with how many physics frames had run before
## the ride, from the same state. Named the faces in turn, the plane list learns both and
## [method _resolve_planes] goes along the crease. Named the same face twice, the leg along it
## (which runs into the other), the lift off it and both halves of the split all start into
## the unnamed face and stop at fraction zero, and the rider hung there with its speed for
## 32 to 1,469 ticks, or for good. Which of those happened depended only on the tick the ride
## began on. Asked before [method _leave_face] and [method _split_leg], because both can
## succeed by a hair there: a tick spent as a few millimetres instead of a crease leg, and
## the same ride finishing in different times.
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

	# From where the capsule is first, and only then lifted off both faces at once: the
	# lift that leaves each face by a skin lies along their sum. Unlifted first because a
	# crease leg that is clear from here is exactly the leg the slide takes when the query
	# happens to name the faces the other way round, so either answer rides the same line.
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


## The duplicate-plane leg's very last resort (`[hns-door-wedge-1]`, 2026-10-12): spend
## [param leg]'s vertical part alone, or failing that its horizontal part alone. True and
## [param result] moved if either got anywhere.
##
## [b]A rest query names one contact, and with two touching it can be the wrong one.[/b] A
## capsule in the 80 degree corner of a wall and an open door's panel, touching the wall's
## face to 15 micrometres and pushing at the panel, was stopped by the panel and told it had
## met the wall: a normal square to the motion, which clips nothing. The slide met "the wall"
## again at fraction zero, called it a duplicate, the leg off it and the lift off it both ran
## into the panel, and the move stopped every tick with the fall speed kept: a body that
## hopped into the corner hung 0.6 m up for the rest of the round (game-hide-n-seek's school
## fire door; most of the school's doors did it). Straight down was clear all along. The panel
## cannot be added as a plane, because no query along the motion names it; and asking the
## rest query to look past a grazed face for the one the motion goes into (tried first) also
## re-ordered the two faces of a surf crease and hung a rider there (game-g2gfast's surf
## bonus). Splitting the leg asks nothing new of the world, runs only where the move was
## otherwise lost for the tick, and moves no further than the leg itself. The velocity is
## not touched.
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
##
## Near-duplicates are rejected because a long surf ramp is not one polygon: sliding
## along it produces a contact every few centimetres with a normal that differs in
## the last bits, and without this the list fills with copies of the same plane and
## the crease search never gets to look at the wall the player is actually caught on.
##
## A duplicate and a full list are told apart because the caller must treat them
## differently: a duplicate is a plane already satisfied, and a full list is a corner.
func _remember_plane(planes: Array[Vector3], normal: Vector3) -> int:
	for existing in planes:
		if existing.dot(normal) > 0.999:
			return PLANE_DUPLICATE

	if planes.size() >= tunables.max_slide_planes:
		return PLANE_FULL

	planes.append(normal)
	return PLANE_ADDED


## A direction that satisfies every plane touched so far, or zero if there is none.
##
## [b]This is why surf works.[/b] The classic slide pass, second half.
## Clipping a vector against one plane and then the next is not the same as finding a
## direction that leaves both: on a surf map the two ramps at a seam meet at a shallow
## angle, and the vector clipped against the first ramp points back into the second, so
## the next iteration clips it against that, which points it back into the first. The
## player arrives at 20 m/s and stops dead in the corner.
##
## So: try each plane in turn, and take the first whose clipped direction does not
## re-enter any other. If none does, the player is in a two-plane wedge and the only
## direction out is along the crease — the cross product of the two normals, which is
## by construction parallel to both surfaces. Three or more planes with no valid
## direction is a genuine corner, and stopping is correct; continuing to search finds
## a direction that leaves the player inside the geometry rather than outside it.
##
## [param original] is the velocity (or the motion) at the START of the move, never
## the already-clipped one — see [method _slide].
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

	# [b]Every crease, not only the first two planes[/b] (`[hns-door-wedge-1]`). The
	# classic slide stops dead at three planes, which is right for a corner with no way
	# out and wrong for one with a way down: a body hopping into a room's corner under a
	# window (game-hide-n-seek's school washroom) met the side wall and two edges of the
	# boxes the window is cut from, one leaning down, and the line where the side wall and
	# the upright edge meet (straight down) left all three; with the velocity zeroed every
	# tick it hung 0.7 m up for good. A crease of two planes that also leaves
	# every other one is a real way out; with two planes this is the old answer exactly.
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
##
## Probed with a thin capsule rather than the player's own, and offset past their
## radius: the question is whether there is floor under a point in front of the feet,
## and sweeping the full capsule would answer "no" for anybody standing against a
## wall — which would double the friction of every player in a corridor.
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


## Up, across, down — the standard way to walk up a step without jumping.
##
## Godot's own [method CharacterBody3D.move_and_slide] can do this, but only as part
## of the stateful move this motor deliberately does not use. Doing it explicitly also
## makes the failure mode visible: the down leg has to land on something that counts
## as a floor, or the step is rejected and the player stays put rather than being
## deposited on top of a wall.
func _slide_with_step(
	from: Vector3,
	velocity: Vector3,
	motion: Vector3,
	height: float
) -> MoveResult:
	var centre := _capsule_centre(from, height)

	# [b]A step is measured from the floor, not from the feet.[/b] A grounded player can
	# be up to the ground probe's two centimetres above it — the tick they land — and a
	# full lift from there clears a kerb that much taller than step_height: a walker
	# landing beside a 0.46 m kerb with step_height 0.45 stepped straight onto it. One
	# short query, and only on a tick the slide was blocked.
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

	# [b]And what it lands on is at most step_height above the floor it left.[/b] Asked
	# of every landing, not only the edge's: a capsule coming down with its axis a
	# quarter-metre short of a kerb meets the corner at about 41 degrees, which is a
	# floor, and a 0.5 m kerb with step_height 0.45 was stepped onto at 10 m/s.
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


## Whether a steep landing contact is the rounded bottom of the capsule on the edge of
## a floor, rather than a steep face.
##
## [b]The step's down leg reports the capsule's normal, not the kerb's.[/b] At walking
## pace one tick's across leg is a few centimetres, so the capsule's axis is still short
## of the edge when it comes down, its hemisphere lands on the corner, and the contact
## normal points from the corner to the sphere's centre: 50 to 80 degrees from up. So a
## 0.34 m kerb under a 0.45 m step_height was refused at every walking speed, and once
## refused the slide had taken the speed into it, so the next tick's leg was shorter
## still. The question the step is asking is whether the surface is a floor, and that is
## answered by a thin probe just past the contact, which must find a floor at the
## contact's own height. A steep face answers no, so surf and walls are unaffected.
## Only the step asks it; the ground probe still reads the capsule's normal.
##
## [b]And the floor has to be within a step of where the step started[/b]
## ([param start_y], the feet before the lift). Without that this answered yes for any
## kerb at all: the across leg's slide rides the capsule's hemisphere up the corner, the
## down leg comes to rest on the corner above the lifted feet, and the probe finds the
## kerb's top at the contact's height and calls it a floor, which it is. With
## step_height 0.45 a walker went over 0.5 m kerbs at 3 and 7 m/s and 0.7 m at 7, and
## was stopped only at 1.0 m. The feet end up below that corner, hanging on it, so a cap
## on how far the feet rose would not catch this; the floor's height does.
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


## Puts a grounded player back a skin clear of the floor [param hit] found, if they are
## closer than half of one. Straight up, and never further than the skin.
##
## [b]Exactly touching a floor is a state a horizontal sweep cannot move out of.[/b] Every
## query here stops a skin short of what it meets, so the motor never puts a player there
## itself — but a spawn at the floor's height does, and nothing then moved them off it,
## because a player the ground check finds a floor under is never snapped. From exactly
## touching, cast_motion reports the floor as an obstacle to a HORIZONTAL move, at fraction
## ~0, in about one position in five (none at 0.2 mm clear, measured on 4 m and 40 m
## boxes); the slide met that plane twice and stopped, every tick, velocity intact. A
## runner at 12 m/s spawned on a floor's centre line froze in front of every kerb.
func _keep_skin(state: DotFpsState, hit: DotFpsBody.Hit, probe: Vector3) -> void:
	var gap := probe.length() * hit.fraction
	if gap < tunables.skin_width * 0.5 and hit.normal.y > 0.0:
		state.position.y += tunables.skin_width - gap


## The floor [param hit] puts the player on, or [constant Vector3.ZERO] if it is not one.
##
## A walkable contact is its own answer. A steep one is the capsule's rounded bottom on
## an edge, and counts as the floor beyond it — [method _edge_floor_normal] — [b]only
## for a player moving onto that floor[/b]. That is the case a step leaves behind: it
## accepts a landing on a kerb's corner, and the next tick's ground check read the
## corner's normal, said AIR, and the air slide turned the run into a climb up the
## corner — at 15 m/s over a 0.34 m kerb, to 1.07 m. Standing still on a ledge, walking
## off one and running along one keep the capsule's answer and roll off as they did.
func _standable_normal(state: DotFpsState, hit: DotFpsBody.Hit) -> Vector3:
	if not hit.hit:
		return Vector3.ZERO

	if _is_floor(hit.normal):
		return hit.normal

	var toward := Vector3(hit.point.x - state.position.x, 0.0, hit.point.z - state.position.z)
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if horizontal.dot(toward) <= 0.0:
		return Vector3.ZERO

	return _edge_floor_normal(hit, state.position, state.position.y)


## Pulls the player back down onto ground they have just walked off the edge of.
##
## Without it, walking down a ramp or a staircase leaves the ground for one tick in
## every few. Those ticks get air physics — no friction, no ground acceleration — so
## the player accelerates down slopes and skates at the bottom, which reads as the
## movement being slippery rather than as a grounding bug.
## Lifts a player who is inside geometry until they are not, and says whether it worked.
##
## Straight up, and never further than a step: the player got here by sinking through a
## surface they were standing on, so the surface is above them and a step is as far as it
## can be without this having been something other than a sinking. Lifting further would
## be a teleport, and teleporting somebody out of a wall they legitimately spawned inside
## is a different problem with a different answer.
##
## [b]The lift doubles each try.[/b] Starting at the skin width and stepping by it would
## be several hundred overlap queries to cover a step; doubling covers the same distance
## in about nine, which matters because this runs inside the simulation and the server
## runs it for everybody. The cost is landing up to twice as high as strictly necessary,
## and the ground probe on the next tick brings them back down.
##
## Deterministic — arithmetic and shape queries, no clock and no RNG — so a client and a
## server recovering from the same embedded position recover to the same place, which is
## the whole contract this file is written to.
## Pushes the capsule out of whatever it is already inside, along that surface's own
## normal. Returns whether it moved.
##
## [b]The general form of [method _lift_clear], and the reason one was not enough.[/b]
## Lifting straight up is the right move out of a floor and the wrong one out of a
## ramp: on a 60 degree face the shortest way out is mostly sideways, and pushing up
## instead climbs along the inside of the surface rather than leaving it. Worse,
## [method _lift_clear] is only ever reached from the branch of
## [method _categorise_ground] that requires the player to have been GROUNDED last
## tick — and a player on a surf ramp is never grounded, by design, because that is
## what makes it surf. The one recovery this motor had could not run on the one
## surface that needed it.
##
## Costs one query per tick per player. That is real on a full server and it is worth
## it: the alternative is asking a cheaper question first, and the cheaper question
## ([method DotFpsBody.overlaps]) cannot tell a player resting on a floor from a
## player buried in it, so it answers yes for almost everybody and buys nothing.
func _depenetrate(state: DotFpsState, height: float) -> bool:
	var centre := _capsule_centre(state.position, height)
	var resting := body.rest_contact(centre, height, tunables.radius)

	if not resting.hit or resting.depth <= 0.0:
		return false

	# Out by the measured depth plus the skin every sweep expects to find, and never
	# further in one tick than a step. The clamp is what makes a wrong answer
	# survivable: a degenerate normal that moves a player a centimetre is a glitch
	# they may not notice, and the same normal unclamped against a deep penetration
	# throws them across the level. A genuine deep embed simply takes a few ticks to
	# climb out of, and converges because each one is measured afresh.
	var push := minf(
		resting.depth + tunables.skin_width,
		maxf(tunables.step_height, tunables.skin_width * 2.0)
	)

	state.position += resting.normal * push
	depenetrated_ticks += 1

	return true


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


##
## [param stood_on] is the floor the player was on at the start of the tick. Moving away
## from it means something launched them and the snap must not cancel it; moving along
## it is a walk, and at the crest of a ramp that walk still points upward while the feet
## have run off the top — without the snap a walker is thrown about fifteen centimetres
## into the air at every crest. So "away" is measured against that plane, not the horizon.
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

	# Downward velocity accumulated while briefly airborne is discarded: keeping it
	# means the next tick's ground check sees a fast descent and un-grounds again,
	# which is the flicker this exists to stop. Upward velocity is left alone — it
	# belongs to something that launched the player and is not ours to cancel.
	if state.velocity.y < 0.0:
		state.velocity.y = 0.0
	elif state.velocity.dot(hit.normal) > LEAVING_SPEED:
		# Walked over a crest, still carrying the ramp's climb. Laid along the floor they
		# have been put on, or the next tick reads that climb as leaving it.
		state.velocity = state.velocity.slide(hit.normal)


# --- The surface a custom mode builds on -----------------------------------

## Moves the player by its velocity for one tick, colliding and sliding.
##
## The built-in modes' movement, exposed so a [DotFpsMoveMode] does not have to
## re-implement collide-and-slide — and, more to the point, so it gets the same
## skin-margin and step handling, which is where all the collision bugs were.
##
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

	var result := _slide(state.position, state.velocity, motion, height)

	if step and result.blocked and tunables.step_height > 0.0:
		var stepped := _slide_with_step(state.position, state.velocity, motion, height)
		if stepped.travelled > result.travelled + tunables.skin_width * 2.0:
			result = stepped

	state.position = result.position
	state.velocity = result.velocity

	if result.ran_out:
		stuck_ticks += 1


## A swept capsule query with the skin margin applied, in world space.
##
## [param from] is the player's feet, not the capsule centre — the same convention as
## [member DotFpsState.position], so a mode never has to remember the offset.
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


# --- Geometry helpers ------------------------------------------------------

## View directions for a yaw and pitch, in degrees.
class ViewBasis extends RefCounted:
	var forward: Vector3
	var right: Vector3
	var up: Vector3


## [b][param state].position is the player's feet[/b], not the capsule's centre.
##
## Feet-relative because that is where a scene places a character's origin, so the
## host's node transform and the simulated position are the same number and no call
## site has to remember to convert. Everything that talks to [DotFpsBody] converts
## here, in one place.
func _capsule_centre(feet: Vector3, height: float) -> Vector3:
	return feet + Vector3.UP * (height * 0.5)


func _height(state: DotFpsState) -> float:
	return tunables.height_at(state.crouch_fraction)


## Eye position for a state, for the camera and for anything tracing from the view.
##
## Sat slightly below the top of the capsule rather than at it, so the camera is not
## coplanar with the collider's cap — at exactly the top, a ceiling the player is
## touching intersects the near plane and the view sees through it.
func eye_position(state: DotFpsState) -> Vector3:
	var height := _height(state)
	return state.position + Vector3.UP * (height - tunables.radius * 0.5)


static func _view_basis(yaw_degrees: float, pitch_degrees: float) -> ViewBasis:
	var yaw := deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)

	var basis := ViewBasis.new()

	# Godot is Y-up and right-handed with -Z forward.
	basis.forward = Vector3(
		-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)
	)
	basis.right = Vector3(cos(yaw), 0.0, -sin(yaw))
	basis.up = basis.right.cross(basis.forward)

	return basis


## The flat forward direction for a yaw, for aiming and for a game's own traces.
static func forward_for(yaw_degrees: float) -> Vector3:
	var yaw := deg_to_rad(yaw_degrees)
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## The full look direction for a yaw and a pitch.
##
## [b]Public because every game needs it and there is exactly one right answer.[/b]
## A weapon traces along it, a physics gun reaches along it, and a camera points down
## it — and a game that re-derives it from the angles gets the sign of one of them
## wrong roughly half the time, because Godot is Y-up, right-handed and -Z forward.
## Getting it wrong produces a game that aims correctly at the horizon and inverts as
## soon as the player looks up.
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
		"surface": _surface.id if _surface != null else &"",
		"effects": _effects.describe() if not _effects.is_neutral() else "neutral",
		"custom_modes": Array(mode_names),
		"modifiers_registered": _modifier_order.size(),
		"tunables": tunables.describe_summary() if tunables != null else "<none>",
		"body": body.describe() if body != null else {},
	}
