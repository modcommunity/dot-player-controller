extends RefCounted

## State and the modifier, mode and surface registries of [DotFpsMotor], kept apart so the simulation file stays small.

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


## Carried load, 0 empty to 1 at capacity. The game sets it on both machines (the server from its
## carry rules, the client from the same replicated figure); it scales the sprint bonus and drain.
var load_fraction: float = 0.0


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

	if _modifier_order.size() >= DotFpsNetSync.MODIFIER_BITS:
		# The active set is replicated as a 48-bit mask, the 49th
		# would make it apply on the server and not on the client, which is a
		# divergence that only shows up for whoever picks up that one power-up.
		DotLog.error(
			CHANNEL,
			"too many modifiers; the active set is a DotFpsNetSync.MODIFIER_BITS-bit mask",
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


