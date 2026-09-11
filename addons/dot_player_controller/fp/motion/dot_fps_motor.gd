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

## Ticks where the collide-and-slide ran out of iterations with motion left.
##
## Non-zero means the player is in geometry tight enough that the slide could not
## resolve it — a wedge, a corner of three surfaces. A few are normal; a rising count
## is a level-geometry problem that will read to players as getting stuck.
var stuck_ticks: int = 0


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
	_categorise_ground(state)

	var jumped := _try_jump(state, command, delta)

	if state.mode == DotFpsState.Mode.GROUND and not jumped:
		_apply_friction(state, delta)
	elif tunables.air_friction > 0.0:
		_apply_air_friction(state, delta)

	_apply_wish_move(state, command, delta)

	if state.mode == DotFpsState.Mode.GROUND:
		# A conveyor, a slick slope, a wind volume. Applied as an acceleration rather
		# than as a velocity so it composes with friction instead of fighting it.
		if _surface.push != Vector3.ZERO:
			state.velocity += _surface.push * delta
	else:
		state.velocity.y -= tunables.gravity * _effects.gravity * delta

	_clamp_velocity(state)
	_move(state, delta, jumped)

	# After the move, so the next tick starts from the truth rather than from where
	# the player was before sliding into a wall or off a ledge.
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


# --- Noclip ----------------------------------------------------------------

func _update_noclip(state: DotFpsState, command: DotFpsCommand) -> void:
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
	if state.mode == DotFpsState.Mode.NOCLIP:
		return

	# Moving upward fast enough to have left the ground is not on it, whatever is
	# under the feet. Without this the tick a jump starts still counts as grounded,
	# gravity is skipped, ground friction applies, and the jump loses most of its
	# height for no visible reason.
	if state.velocity.y > 0.1:
		state.mode = DotFpsState.Mode.AIR
		state.ground_normal = Vector3.UP
		state.ground_id = 0
		return

	var was_grounded := state.mode == DotFpsState.Mode.GROUND

	var height := _height(state)
	var centre := _capsule_centre(state.position, height)
	var probe := Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02)

	var hit := _sweep(centre, probe, height)

	if hit.hit and _is_floor(hit.normal):
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
			return

		state.mode = DotFpsState.Mode.GROUND
		state.ground_normal = hit.normal
		state.ground_id = hit.collider_id
		state.surface = found
		_resolve_surface(state)
		return

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
		DotLog.debug(
			CHANNEL,
			"ground probe missed while embedded; staying grounded",
			{"position": str(state.position)}
		)
		state.mode = DotFpsState.Mode.GROUND
		return

	state.mode = DotFpsState.Mode.AIR
	state.ground_normal = Vector3.UP
	state.ground_id = 0
	state.surface = &""
	_resolve_surface(state)


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
	if state.velocity.y > 0.1:
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

	var drop := (
		control * tunables.friction * _surface.friction_scale
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
		accelerate(
			state,
			direction,
			target,
			tunables.accelerate * _surface.accelerate_scale * _effects.accelerate,
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
	height: float
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
		centre, motion + direction * margin, height, tunables.radius
	)

	if not hit.hit:
		return hit

	var travelled := clampf(
		hit.fraction * (length + margin) - margin, 0.0, length
	)
	hit.fraction = travelled / length

	return hit


# --- Movement --------------------------------------------------------------

func _move(state: DotFpsState, delta: float, jumped: bool) -> void:
	var height := _height(state)
	var motion := state.velocity * delta

	if motion.length_squared() <= 0.0:
		return

	var was_grounded := state.mode == DotFpsState.Mode.GROUND

	var plain := _slide(state.position, state.velocity, motion, height)

	# Stepping is tried only when it could help: on the ground, actually blocked, and
	# not on the tick a jump left the surface. Attempting it every tick would double
	# the query cost of the most expensive part of the frame for nothing.
	if was_grounded and not jumped and plain.blocked and tunables.step_height > 0.0:
		var stepped := _slide_with_step(state.position, state.velocity, motion, height)

		# Only if it genuinely got further. A step that gains nothing but ends
		# slightly higher would ratchet the player up a wall over many ticks.
		if stepped.travelled > plain.travelled + 0.0001:
			plain = stepped

	state.position = plain.position
	state.velocity = plain.velocity

	if plain.ran_out:
		stuck_ticks += 1

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
		_categorise_ground(state)

		if state.mode != DotFpsState.Mode.GROUND:
			_snap_to_ground(state, height)


## The result of one collide-and-slide.
class MoveResult extends RefCounted:
	var position: Vector3
	var velocity: Vector3
	var travelled: float = 0.0
	var blocked: bool = false
	## Iterations were exhausted with motion remaining.
	var ran_out: bool = false


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

	# Motion left over means the iteration budget ran out rather than the move
	# completing — the player is in a wedge the slide could not resolve.
	if time_left > 1e-6 and current.length_squared() > 1e-12:
		result.ran_out = true

	result.travelled = Vector3(
		result.position.x - start.x, 0.0, result.position.z - start.z
	).length()

	return result


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

	if count != 2:
		return Vector3.ZERO

	var crease := planes[0].cross(planes[1])

	# Parallel planes — two faces of the same wall the player is sandwiched between.
	# There is no crease and no way through.
	if crease.length_squared() < 1e-12:
		return Vector3.ZERO

	crease = crease.normalized()

	return crease * crease.dot(original)


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
	var lift := Vector3.UP * tunables.step_height
	var centre := _capsule_centre(from, height)

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
	var drop := Vector3.DOWN * (tunables.step_height + tunables.skin_width)
	var landing := _sweep(_capsule_centre(across.position, height), drop, height)

	var result := MoveResult.new()
	result.velocity = across.velocity
	result.blocked = across.blocked

	if not landing.hit or not _is_floor(landing.normal):
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


## Pulls the player back down onto ground they have just walked off the edge of.
##
## Without it, walking down a ramp or a staircase leaves the ground for one tick in
## every few. Those ticks get air physics — no friction, no ground acceleration — so
## the player accelerates down slopes and skates at the bottom, which reads as the
## movement being slippery rather than as a grounding bug.
func _snap_to_ground(state: DotFpsState, height: float) -> void:
	if state.velocity.y > 0.1:
		return

	var centre := _capsule_centre(state.position, height)
	var probe := Vector3.DOWN * tunables.ground_snap_distance

	var hit := _sweep(centre, probe, height)

	if not hit.hit or not _is_floor(hit.normal):
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
		if stepped.travelled > result.travelled + 0.0001:
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
		"surface": _surface.id if _surface != null else &"",
		"effects": _effects.describe() if not _effects.is_neutral() else "neutral",
		"custom_modes": Array(mode_names),
		"modifiers_registered": _modifier_order.size(),
		"tunables": tunables.describe_summary() if tunables != null else "<none>",
		"body": body.describe() if body != null else {},
	}
