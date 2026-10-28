extends RefCounted

## State and the modifier, mode and surface registries of [DotFpsMotor], kept apart so the simulation file stays small.

const CHANNEL := "fps.motor"

## Fraction of a sweep's length treated as untrustworthy at its far end.
## cast_motion's tolerance is relative to the sweep: on the 35 cm snap probe it can place the player
## below the floor and they sink. Scaling with the sweep, not a fixed skin, costs an invisible sub-centimetre gap.
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
## Must be pure and agree across machines, or friction and prediction diverge. The default reads scene
## metadata; an instance id would not work, as those differ between processes.
var surface_resolver: Callable = Callable()


## Modifier definitions by id. The active set lives in [DotFpsState].
var modifier_defs: Dictionary = {}


## Modifier ids in registration order, so an index is stable and can be replicated.
var _modifier_order: Array[StringName] = []


## Custom modes by id, from [constant DotFpsState.FIRST_CUSTOM_MODE] up.
var _modes: Dictionary = {}


## The combined effect of the active modifiers, recomputed once per tick.
## Reused rather than allocated: read several times per tick per player.
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
## A few are normal; a rising count is geometry (a wedge, a three-surface corner) that reads as stuck.
var stuck_ticks: int = 0


## Ticks on which a player was found INSIDE geometry with no floor under them: "I went through the floor", counted.
## An outside overlap test cannot say so, since a capsule resting a millimetre above a floor overlaps it too.
## The distinction is that the ground probe found nothing AND the player is in something.
var embedded_ticks: int = 0


## How many of those were lifted back out. See [method _lift_clear].
## The gap between the two is how often a player is left under the floor until respawn.
var lifted_ticks: int = 0


## Ticks whose move stopped early on a plane it had already resolved against.
## The intended path, but a high count where a player should flow is worth a look: near zero on
## hand-built geometry, 10% to 14% on a map imported as one convex hull per brush.
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
## Unlike [member embedded_ticks] this counts a never-grounded surfer sinking through a ramp.
## A few microns' contact on any real map is ordinary; a count tracking the tick rate on one surface is that surface eating players.
var depenetrated_ticks: int = 0


## Ticks whose end-of-tick ground check was skipped because an earlier check this tick had settled
## the same question on the same state. Diagnostic; see [method _categorise_ground_settled].
var settled_ground_ticks: int = 0


## Registers a custom movement mode and returns its id.
## Ids travel on the wire, so register in the same fixed order on every machine, not conditionally
## on being a client or server.
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
## Server-side in a networked game; the replicated set lets the owner predict the effect.
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
## It need not be exact but must match on both machines, or a boost outlasts on one.
var _tick_rate_hint: float = 60.0


func set_tick_rate(rate: int) -> void:
	_tick_rate_hint = float(maxi(1, rate))


## Drops modifiers whose expiry tick has passed.
## Compared against the simulated tick, not a clock, so a replay expires them on the original tick.
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
## Public so a [DotFpsMoveMode] scales by the same numbers; a ladder ignoring a slow field would escape it.
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


