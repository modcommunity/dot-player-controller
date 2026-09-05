@tool
class_name DotFpsController
extends Node

## The player controller. Add it under a [Node3D] and it moves.
##
## [codeblock]
## Player (CharacterBody3D or Node3D)
##  ├── Collision   (CollisionShape3D)   sized by the controller
##  ├── Head        (Node3D)
##  │    └── Camera (Camera3D)
##  ├── FpsView     (DotFpsView)
##  └── FpsControl  (DotFpsController)   body_ref -> parent
## [/codeblock]
##
## [b]A component, not a base class.[/b] The same reasoning as [DotNetIdentity]: a
## host game's player already extends whatever that game needs, and demanding it
## extend ours instead is the one change that cannot be worked around. Everything it
## touches in the host scene goes through a [DotNodeRef], so the layout above is a
## suggestion and not a requirement.
##
## [b]Two ways to drive it.[/b] In [constant Drive.LOCAL] it samples the keyboard and
## ticks itself, which is single-player and the editor. In
## [constant Drive.EXTERNAL] it does neither, and something else — a
## [code]DotNetBehaviour[/code] under dot-net, a replay, a bot — feeds it commands
## with [method apply_command] and advances it with [method simulate_tick]. The
## simulation is identical in both; the only difference is who supplies the commands
## and when.
##
## dot-net is not imported and is not required. See [DotFpsNetSync] and the worked
## bridge in this project's CLAUDE.md.

const CHANNEL := "fps"
const SERVICE := &"dot_fps_controller"

## Emitted after every simulated tick, on whichever peer simulated it.
signal simulated(tick: int, state: DotFpsState)

## Emitted when the player touches down. [param impact] is the downward speed lost.
signal landed(impact: float)

signal jumped()

## Emitted when the movement mode changes — grounded to airborne, or into noclip.
##
## Modes are ints rather than the enum because a game registers its own; use
## [method DotFpsState.mode_name] to render one.
signal mode_changed(from: int, to: int)

## Emitted when the player steps up onto something, with the height gained.
signal stepped_up(height: float)

## Emitted when the ground under the player changes kind. Ids, not resources.
##
## The hook for footstep sounds and decals: a game listens once here rather than
## sampling the surface every frame and diffing it itself.
signal surface_changed(from: StringName, to: StringName)

## Emitted when the player starts or stops being crouched.
signal crouch_changed(crouched: bool)

## Emitted when a modifier starts or stops applying, on whichever peer simulates.
signal modifier_added(id: StringName)
signal modifier_removed(id: StringName)

## Who supplies commands and drives ticks.
enum Drive {
	## Sample input and tick in [method Node._physics_process]. Single-player.
	LOCAL,
	## Someone else calls [method apply_command] and [method simulate_tick].
	EXTERNAL,
	## Simulate nothing; only apply state written from elsewhere.
	##
	## What a remote player's copy uses: their position arrives over the network and
	## running the motor on it locally would fight the incoming state.
	REMOTE,
}

@export_group("Role")

@export var drive: Drive = Drive.LOCAL

## Simulation ticks per second in [constant Drive.LOCAL].
##
## Ignored in the other modes, where the tick rate is whatever the driver uses — under
## dot-net, [code]DotNetConfig.tick_rate[/code]. [b]It must match on the client and
## the server[/b]: delta is an input to the simulation, so two peers stepping at
## different rates reach different answers from the same commands.
@export_range(1, 240, 1) var tick_rate: int = 60

## Register in [DotRegistry] under [constant SERVICE] so other systems can find this.
##
## Off by default: registering is a global name, and a scene with several players
## would have them overwrite each other. Set [member service_scope] for that case.
@export var register_service: bool = false

## Suffix for the registry name, so several controllers can coexist.
@export var service_scope: StringName = &""

@export_group("Configuration")

## Movement tunables. One is created with the defaults if this is left empty.
@export var tunables: DotFpsTunables = null

## The surfaces this game has. Null means every surface behaves identically.
##
## Opt-in: without one, the surface lookup never runs and costs nothing.
@export var surfaces: DotFpsSurfaceSet = null

## The movement style in force for this player, or null for the base tunables.
##
## Assign in the inspector or through [method set_style], never by writing this
## property at runtime: the motor holds a reference to the tunables it was built
## with, so a style swapped in without rebuilding it changes nothing and looks like
## the style system not working. [method set_style] does both halves.
@export var style: DotFpsStyle = null

## JSON file layered over the exported defaults. Empty disables the file layer.
##
## Deployment configuration, so it participates in the usual layering: exported
## defaults, then this file, then [code]DOT_FPS_*[/code], then [code]--fps-*[/code].
@export var config_file: String = ""

## Apply the environment and command-line layers.
##
## Wanted on a dedicated server and usually not in a client, where an ambient
## variable silently changing movement is a support call rather than a feature.
@export var load_layered_config: bool = false

@export_group("Wiring")

## The node the simulated position is written to. Defaults to the parent.
@export var body_ref: DotNodeRef = null

## The collision shape resized when crouching. Optional but strongly recommended.
##
## Without it the simulation crouches and the host's collider does not, so anything
## else in the game that queries the player — a bullet trace, a trigger volume — sees
## a standing player who is visibly crouched.
@export var collider_ref: DotNodeRef = null

## The view. Optional: a headless server has nothing to look through.
@export var view_ref: DotNodeRef = null

@export_group("Safety")

## Whether this instance honours the noclip button at all.
##
## Separate from [member DotFpsTunables.can_noclip] and deliberately redundant. The
## tunables are shared configuration that a client also holds a copy of; this is a
## property of one controller on one machine. A server sets it per player from its own
## permissions and does not have to trust either the client's copy of the config or
## the bit the client set in the command.
@export var allow_noclip: bool = false

## Register this addon's default input bindings if the project has none.
@export var register_default_actions: bool = true

## The simulated state. Authoritative in [constant Drive.LOCAL] and
## [constant Drive.EXTERNAL]; written from the network in [constant Drive.REMOTE].
var state: DotFpsState = DotFpsState.new()

var motor: DotFpsMotor = null
var body: DotFpsBody = null
var sampler: DotFpsSampler = null
var view: DotFpsView = null

## The command applied on the most recent tick. Held so a driver can resend it.
var current_command: DotFpsCommand = null

## Movement statistics for the current run: jumps, strafes, sync, speed.
##
## Folded once per simulated tick, and NOT during a prediction replay — a replayed
## tick is the same tick simulated again, and counting it twice would give a client
## under packet loss a jump count that climbs on its own.
var stats := DotFpsStats.new()

## The tunables before the style was applied. See [method set_style].
##
## Kept so a style change derives from the original rather than from the previous
## style's output — otherwise two style changes compound their scales and a player
## who switched to low-gravity and back lands in a third of the gravity they started
## with.
var _base_tunables: DotFpsTunables = null

## The command the statistics last saw, for their own edge detection.
var _stats_previous: DotFpsCommand = null

var _body_node: Node3D = null
var _collider: CollisionShape3D = null
var _capsule: CapsuleShape3D = null

## State at the end of the previous tick, for render interpolation.
var _previous_state: DotFpsState = DotFpsState.new()

## collider instance id -> surface id. See _resolve_surface_id.
var _surface_cache: Dictionary = {}

## The modifier set as of the last time changes were reported. See _report_changes.
var _last_modifiers: Array[Vector2i] = []

var _replaying: bool = false

var _accumulator: float = 0.0
var _tick: int = 0
var _started: bool = false
var _registered_name: StringName = &""


# --- Lifecycle -------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		DotLog.result(CHANNEL, "controller setup", res)
		set_physics_process(false)
		return

	set_physics_process(drive == Drive.LOCAL)


## Builds everything. Called by [method Node._ready]; safe to call again after
## changing the tunables.
func setup() -> DotResult:
	if tunables == null:
		tunables = DotFpsTunables.new()

	if _base_tunables == null:
		_base_tunables = tunables

	# Always from the base, never from whatever the last style left behind. Calling
	# setup() twice with a style set must not apply it twice.
	if style != null:
		tunables = style.apply_to(_base_tunables)
	else:
		tunables = _base_tunables

	if load_layered_config or config_file != "":
		var loaded := tunables.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Movement configuration is not usable.")
	else:
		var valid := tunables.validate()
		if not valid.ok:
			return valid.wrap("Movement configuration is not usable.")

	# The noclip gate is applied per tick, not here — see _gate_abilities. Applying
	# it once at setup looks equivalent and is not: the tunables are a Resource the
	# host keeps a reference to, so anything that assigns can_noclip afterwards
	# re-opens a gate that was supposed to be closed. A server that reloads its
	# config mid-round does exactly that.
	_gate_abilities()

	var wired := _resolve_nodes()
	if not wired.ok:
		return wired

	body = _make_body()
	motor = DotFpsMotor.new(tunables, body)
	motor.set_tick_rate(tick_rate)

	if surfaces != null:
		motor.surfaces = surfaces
		motor.surface_resolver = _resolve_surface_id

	_register_extensions()

	if drive == Drive.LOCAL:
		sampler = DotFpsSampler.new(tunables)

		if register_default_actions:
			DotFpsSampler.register_default_actions(sampler)

		var missing := sampler.missing_actions()
		if not missing.is_empty():
			# Not an error — a game may drive this without a keyboard at all — but a
			# missing action in Godot is silence, and the symptom is a controller
			# that runs flawlessly and does not move.
			DotLog.warn(
				CHANNEL,
				"input actions are not bound; the player will not move",
				{"actions": ", ".join(missing)}
			)

		sampler.look_at_angles(state.yaw, state.pitch)

	if _body_node != null:
		state.position = _body_node.global_position
		_previous_state.copy_from(state)

	_apply_collider(state)

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_started = true

	DotLog.info(
		CHANNEL,
		"controller ready",
		{
			"drive": Drive.keys()[drive],
			"tick_rate": tick_rate,
			"movement": tunables.describe_summary(),
		}
	)

	return DotResult.success(null)


func _resolve_nodes() -> DotResult:
	if body_ref == null:
		body_ref = DotNodeRef.new()
		body_ref.mode = DotNodeRef.Mode.PARENT

	var resolved := body_ref.resolve(self)
	if not resolved.ok:
		return resolved.wrap("Could not resolve the player body.")

	_body_node = resolved.value as Node3D

	if _body_node == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The player body must be a Node3D.",
			body_ref.describe()
		)

	# Unset refs fall back to "the obvious node under the body". Wiring every
	# reference by hand is the price of never hardcoding a scene path, and for the
	# conventional layout it is a price with nothing bought: a player has one
	# collider and one view. An explicit ref always wins, so a game with two
	# colliders still says which.
	if collider_ref == null:
		collider_ref = _descendant_ref(&"CollisionShape3D")

	if view_ref == null:
		view_ref = _descendant_ref(&"DotFpsView")

	if collider_ref != null:
		# Resolved against the body, not against this node: the collider is a sibling
		# of the controller, so a descendant search from here would find nothing.
		var collider := collider_ref.resolve_or_null(_body_node, CHANNEL)
		_collider = collider as CollisionShape3D

		if _collider != null:
			# Never shared: a CapsuleShape3D from a .tscn is shared between every
			# instance of that scene, so resizing one player's collider on crouch
			# would resize every player's. Costs one resource per controller.
			_capsule = CapsuleShape3D.new()
			_capsule.radius = tunables.radius
			_capsule.height = tunables.stand_height
			_collider.shape = _capsule
		elif collider != null:
			DotLog.warn(
				CHANNEL,
				"collider_ref resolved a %s, not a CollisionShape3D; "
				% collider.get_class()
				+ "the collider will not follow the crouch",
				{"ref": collider_ref.describe()}
			)

	if view_ref != null:
		view = view_ref.resolve_or_null(_body_node, CHANNEL) as DotFpsView

	if view != null:
		# The landing kick is the one view effect that needs an event rather than a
		# state, so it is wired here instead of leaving every game to remember it.
		landed.connect(view.note_landing)

	return DotResult.success(null)


## A ref that finds the nearest descendant of a type, or nothing.
##
## [constant DotNodeRef.OnMissing.NULL] rather than FAIL: these are the defaults for
## optional wiring, and "no view" is a headless server, not an error.
static func _descendant_ref(type: StringName) -> DotNodeRef:
	var ref := DotNodeRef.new()
	ref.mode = DotNodeRef.Mode.DESCENDANT_OF_TYPE
	ref.type_name = type
	ref.on_missing = DotNodeRef.OnMissing.NULL
	return ref


## Registers this game's movement modes and modifiers. Override and call the motor.
##
## [b]Called before the first tick and in a fixed order, on every machine.[/b] That
## matters: [method DotFpsMotor.register_mode] and
## [method DotFpsMotor.register_modifier] hand out ids by registration order, and the
## id is what travels on the wire. Registering conditionally — only on the server,
## only when a game mode is active — gives two peers different ids for the same
## modifier, and the symptom is a power-up that works for some players.
##
## [codeblock]
## func _register_extensions() -> void:
##     motor.register_modifier(preload("res://movement/speed_pad.tres"))
##     _ladder = motor.register_mode(LadderMode.new())
## [/codeblock]
func _register_extensions() -> void:
	pass


## Maps a collider to a surface id, for the motor.
##
## Reads scene metadata rather than anything derived from the physics handle, because
## a collider's instance id differs between the client's process and the server's and
## the surface has to resolve identically on both. Cached, because the answer only
## changes when the player steps onto a different collider.
func _resolve_surface_id(collider_id: int) -> StringName:
	if _surface_cache.has(collider_id):
		return _surface_cache[collider_id]

	var resolved := &""
	var node := instance_from_id(collider_id)

	if node is Node:
		resolved = DotFpsSurfaceSet.resolve_from_node(
			node as Node, surfaces.metadata_key, surfaces.group_prefix
		)

	# Bounded so a level with thousands of colliders cannot grow this without limit.
	# Clearing wholesale rather than evicting one entry: the cache is a pure function
	# of the scene, so rebuilding it costs one lookup per collider actually walked on.
	if _surface_cache.size() > 512:
		_surface_cache.clear()

	_surface_cache[collider_id] = resolved
	return resolved


## Called before the motor runs, on the tick that is about to be simulated.
##
## Override for anything that has to happen inside the simulation — applying a
## modifier from a trigger volume, switching to a custom mode. [b]It runs during
## prediction replays too[/b], so it is bound by the same determinism rule as
## [method DotFpsMotor.simulate]: no wall clock, no unseeded random, nothing that
## differs between the client and the server.
func _on_pre_simulate(_tick: int, _delta: float) -> void:
	pass


## Called after the motor runs and the scene has been updated.
##
## The place for anything cosmetic or non-simulated — a footstep, a trigger query.
## Also runs during a replay, so anything with a side effect outside the simulation
## should check [method is_replaying] first.
func _on_post_simulate(_tick: int, _delta: float) -> void:
	pass


## Whether the tick being simulated is a prediction replay rather than a fresh one.
##
## A replay re-runs ticks the player has already seen. Anything that fires a sound,
## spawns a particle or sends a message must not do it again — the player would hear
## six footsteps for one step, once per correction.
func is_replaying() -> bool:
	return _replaying


## Marks the following ticks as a replay. dot-net's reconciliation calls this.
func begin_replay() -> void:
	_replaying = true


func end_replay() -> void:
	_replaying = false


## Whether a command should be simulated at all. Override to veto input.
##
## For a cutscene, a respawn freeze, or a server refusing input from a player who
## should not have any. Returning false substitutes a neutral command rather than
## skipping the tick, because skipping a tick desynchronises the tick counter.
func _accept_command(_command: DotFpsCommand) -> bool:
	return true


# --- Modes and modifiers ---------------------------------------------------

## Applies a modifier. Server-side in a networked game; replicated to the owner.
func add_modifier(id: StringName) -> bool:
	return motor != null and motor.add_modifier(state, id)


func remove_modifier(id: StringName) -> bool:
	return motor != null and motor.remove_modifier(state, id)


func has_modifier(id: StringName) -> bool:
	return motor != null and motor.has_modifier(state, id)


## Puts this player on a movement style, rebuilding everything that depends on it.
##
## [b]Rebuilds the motor.[/b] The tunables are an input the motor holds a reference
## to, so assigning [member style] alone changes nothing — which is the single most
## likely way to use this wrongly, and the symptom is a style that appears to be set
## and has no effect.
##
## Pass null to go back to the unstyled tunables.
##
## [b]Not safe to call mid-run in a timed game[/b], and the timer treats it as
## stopping the run: the tunables are an input to the simulation, so changing them
## changes what every subsequent tick produces, and a record whose first half was set
## under one style is not a record on either.
func set_style(new_style: DotFpsStyle) -> DotResult:
	if _base_tunables == null:
		_base_tunables = tunables

	style = new_style

	if not _started:
		# setup() has not run yet, so it will pick the style up itself and rebuilding
		# now would build against unresolved node references.
		return DotResult.success(null)

	var rebuilt := setup()

	if not rebuilt.ok:
		return rebuilt.wrap("Could not apply the movement style.")

	stats.reset()
	_stats_previous = null

	return DotResult.success(null)


## Switches movement mode, running the mode's exit and enter hooks.
func set_mode(mode: int) -> void:
	if motor != null:
		motor.set_mode(state, mode)


## Builds the collision adapter. Override to simulate against your own geometry.
func _make_body() -> DotFpsBody:
	var physics := DotFpsPhysicsBody.new()
	physics.collision_mask = tunables.collision_mask

	if _body_node is CollisionObject3D:
		# Excluded, or every downward probe hits the player's own collider and the
		# player stands on themselves at the height they spawned.
		physics.exclude = [(_body_node as CollisionObject3D).get_rid()]

	var bound := physics.bind(_body_node)
	if not bound.ok:
		DotLog.result(CHANNEL, "physics body", bound)

	return physics


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


# --- Local driving ---------------------------------------------------------

func _input(event: InputEvent) -> void:
	if drive == Drive.LOCAL and sampler != null:
		sampler.handle_event(event)


func _physics_process(delta: float) -> void:
	if not _started or drive != Drive.LOCAL:
		return

	# A fixed step accumulated from the frame time, rather than simulating with the
	# frame's own delta. The whole determinism argument depends on the step being a
	# constant both peers agree on, and it is worth honouring in single-player too:
	# a controller tuned against a variable step behaves differently on a machine
	# that renders faster.
	var step := 1.0 / float(maxi(1, tick_rate))
	_accumulator += delta

	# Bounded so a frame spike — a shader compile, a level load — does not spend the
	# next frame simulating a hundred ticks and make the stall worse.
	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1

		apply_command(sampler.sample(step))
		simulate_tick(_tick + 1, step)

	if _accumulator >= step:
		DotLog.debug(
			CHANNEL,
			"tick budget exhausted; dropping simulation time",
			{"dropped": "%.3f s" % _accumulator}
		)
		_accumulator = 0.0


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _started:
		return

	if view != null:
		view.apply(render_state(), motor, delta)


# --- Driving from outside --------------------------------------------------

## Sets the command the next [method simulate_tick] will use.
##
## Sanitised here rather than at the call site so a driver cannot forget: on a server
## every field arrived from a client and can be anything the wire format allows.
func apply_command(command: DotFpsCommand) -> void:
	if command == null:
		return

	command.sanitise(tunables.pitch_min, tunables.pitch_max)

	# Before the motor, on BOTH machines, and in place. Filtering only on the server
	# makes the client predict movement the server will not produce, and the
	# correction lands a round trip later — the worst possible way to tell somebody a
	# key is disabled. In place, and idempotent, because a prediction replay runs
	# this again over the stored commands.
	if style != null:
		style.filter_command(command)

	current_command = command


## Advances the simulation by one tick.
##
## [param delta] must be the fixed tick duration, not a frame time. Under dot-net
## this is called from [code]_net_simulate[/code], on both the server and the
## predicting client, with the identical command — which is what makes them agree.
func simulate_tick(tick: int, delta: float) -> void:
	if not _started or drive == Drive.REMOTE:
		return

	# Re-applied every tick so it cannot be undone by anything that touches the
	# tunables between ticks.
	_gate_abilities()

	if current_command == null:
		# No command for this tick. Repeating the last one is what the netcode
		# expects of a starved tick: a player whose packet was lost should keep
		# moving in a straight line rather than stopping dead and jerking forward
		# when it arrives.
		current_command = (
			DotFpsCommand.new() if state.previous_buttons == 0
			else _repeat_command()
		)

	if not _accept_command(current_command):
		# Substituted, not skipped. Skipping the tick would leave the tick counter
		# behind the server's, and every input after it would be stamped with a tick
		# that has already been simulated.
		current_command = DotFpsCommand.new()
		current_command.yaw = state.yaw
		current_command.pitch = state.pitch

	_previous_state.copy_from(state)

	var before_mode := state.mode
	var before_y := state.position.y
	var before_fall := state.velocity.y
	var before_crouched := state.is_crouched()
	var before_surface := state.surface

	_on_pre_simulate(tick, delta)

	motor.simulate(state, current_command, delta)

	_tick = tick
	_publish(before_mode, before_y, before_fall)
	_report_changes(before_crouched, before_surface)

	# Not during a replay: a replayed tick is one the statistics have already seen,
	# and counting it again gives a client on a lossy link a jump count that climbs
	# by itself. The server's copy is the one a record is filed with for exactly this
	# reason.
	if not _replaying:
		stats.observe(state, current_command, _stats_previous, delta)
		_stats_previous = current_command.duplicate_command()

	_on_post_simulate(tick, delta)

	simulated.emit(tick, state)


## Emits the change signals for anything the tick altered.
##
## Diffed here rather than polled by whoever cares, so a game gets one edge per
## change instead of comparing state every frame and disagreeing about when it
## happened.
func _report_changes(
	before_crouched: bool,
	before_surface: StringName
) -> void:
	if state.is_crouched() != before_crouched:
		crouch_changed.emit(state.is_crouched())

	if state.surface != before_surface:
		surface_changed.emit(before_surface, state.surface)

	# Modifiers are diffed against a baseline that persists across ticks, not against
	# one captured at the top of this one.
	#
	# [b]The difference is not cosmetic.[/b] A modifier applied between ticks — which
	# is every modifier a trigger volume or a server-side rule applies — is already
	# present by the time the next tick starts, so a same-tick baseline sees no
	# change and the "added" edge is never reported. Only expiry was, which made the
	# pair look like it fired for some modifiers and not others.
	#
	# It also means the signal reports state as of a tick boundary, which is where
	# the replicated copy changes too, so a client and a server agree about when a
	# modifier started rather than differing by one tick.
	if state.modifiers == _last_modifiers:
		return

	var before_modifiers := _last_modifiers
	_last_modifiers = state.modifiers.duplicate()

	# Small arrays — usually empty, rarely more than two or three — so a linear
	# comparison is cheaper than building sets to diff them.
	for entry in state.modifiers:
		if not _contains_modifier(before_modifiers, entry.x):
			var added := motor.modifier_at(entry.x)
			if added != null:
				modifier_added.emit(added.id)

	for entry in before_modifiers:
		if not _contains_modifier(state.modifiers, entry.x):
			var removed := motor.modifier_at(entry.x)
			if removed != null:
				modifier_removed.emit(removed.id)


static func _contains_modifier(entries: Array[Vector2i], index: int) -> bool:
	for entry in entries:
		if entry.x == index:
			return true
	return false


## Closes off anything this instance is not permitted to do.
##
## [b]Two gates, deliberately.[/b] [member DotFpsTunables.can_noclip] is shared
## configuration — the client holds a copy of it, and the noclip bit in a command is
## set by the client. [member allow_noclip] is a property of one controller on one
## machine, so a server can grant it per player from its own permissions without
## trusting either.
func _gate_abilities() -> void:
	if tunables != null and not allow_noclip:
		tunables.can_noclip = false


func _repeat_command() -> DotFpsCommand:
	var repeated := DotFpsCommand.new()
	repeated.buttons = state.previous_buttons
	repeated.yaw = state.yaw
	repeated.pitch = state.pitch
	# Movement is dropped but buttons are kept: a held crouch should stay held
	# through a dropped packet, whereas continuing to run in a direction the player
	# may have released is the version of this that walks people off ledges.
	return repeated


## Writes the simulated state out to the scene, and reports what changed.
func _publish(
	before_mode: DotFpsState.Mode,
	before_y: float,
	before_fall: float
) -> void:
	if _body_node != null:
		_body_node.global_position = state.position

	_apply_collider(state)

	if before_mode != state.mode:
		mode_changed.emit(before_mode, state.mode)

		if (
			state.mode == DotFpsState.Mode.GROUND
			and before_mode == DotFpsState.Mode.AIR
		):
			landed.emit(absf(before_fall))
		elif (
			state.mode == DotFpsState.Mode.AIR
			and before_mode == DotFpsState.Mode.GROUND
			and state.velocity.y > 0.0
		):
			jumped.emit()

	# A grounded tick that gained height is a stair step, not a jump — the view
	# absorbs it so the camera does not jolt once per tread.
	if state.mode == DotFpsState.Mode.GROUND:
		var gained := state.position.y - before_y
		if gained > 0.001 and gained <= tunables.step_height + 0.01:
			if view != null:
				view.note_step_up(gained)
			stepped_up.emit(gained)


func _apply_collider(from: DotFpsState) -> void:
	if _capsule == null:
		return

	var height := tunables.height_at(from.crouch_fraction)
	_capsule.height = maxf(height, tunables.radius * 2.0)
	_capsule.radius = tunables.radius

	if _collider != null:
		# The collider's origin is its centre and the body's is its feet.
		_collider.position.y = height * 0.5


# --- Rendering -------------------------------------------------------------

## The state to render this frame, interpolated between the last two ticks.
##
## Simulation runs at the tick rate and rendering does not, so rendering the tick
## state directly quantises all motion to the tick rate — visible as stutter at any
## tick rate a game can afford. Purely cosmetic: the returned state is a copy and
## nothing writes it back.
func render_state() -> DotFpsState:
	if drive != Drive.LOCAL or tick_rate <= 0:
		return state

	var step := 1.0 / float(tick_rate)
	var alpha := clampf(_accumulator / step, 0.0, 1.0)

	var blended := state.duplicate_state()
	blended.position = _previous_state.position.lerp(state.position, alpha)
	blended.crouch_fraction = lerpf(
		_previous_state.crouch_fraction, state.crouch_fraction, alpha
	)

	# View angles are not interpolated. They come straight from the sampler, which
	# has already read this frame's mouse motion — blending toward the previous tick
	# would add a frame of latency to aiming, which is the one place it is felt.
	return blended


# --- Teleporting -----------------------------------------------------------

## Moves the player, discarding velocity and smoothing.
##
## Under dot-net this is a server-authoritative action: a client that teleported
## itself would be corrected on the next snapshot, having briefly been somewhere it
## was not allowed to be.
func teleport(
	position: Vector3,
	yaw: float = NAN,
	pitch: float = NAN
) -> void:
	state.position = position
	state.velocity = Vector3.ZERO
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 0.0

	if is_finite(yaw):
		state.yaw = yaw
	if is_finite(pitch):
		state.pitch = clampf(pitch, tunables.pitch_min, tunables.pitch_max)

	_previous_state.copy_from(state)
	_last_modifiers = state.modifiers.duplicate()

	if sampler != null:
		sampler.look_at_angles(state.yaw, state.pitch)

	if _body_node != null:
		_body_node.global_position = position

	if view != null:
		view.snap()


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"drive": Drive.keys()[drive],
		"tick": _tick,
		"tick_rate": tick_rate,
		"allow_noclip": allow_noclip,
		"state": state.describe(),
		"motor": motor.describe() if motor != null else {},
		"sampler": sampler.describe() if sampler != null else {},
		"view": view.describe() if view != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("drive        %s   tick %d @ %d Hz" % [
		Drive.keys()[drive], _tick, tick_rate
	])
	out.append("movement     %s" % tunables.describe_summary())
	out.append("mode         %s" % DotFpsState.mode_name(state.mode, motor))

	if state.surface != &"":
		out.append("surface      %s" % state.surface)

	if not state.modifiers.is_empty():
		var names := PackedStringArray()
		for entry in state.modifiers:
			var definition := motor.modifier_at(entry.x)
			names.append(String(definition.id) if definition != null else "?")
		out.append("modifiers    %s" % ", ".join(names))
	out.append_array(state.describe_lines())

	if motor != null:
		out.append("stuck_ticks  %d" % motor.stuck_ticks)

	return out
