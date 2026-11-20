@tool
class_name DotFpsController
extends "dot_fps_controller_render.gd"

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
## A component, not a base class: a host's player already extends what it needs. Everything it touches goes through a [DotNodeRef], so the layout above is a suggestion.
## [constant Drive.LOCAL] samples the keyboard and ticks itself; [constant Drive.EXTERNAL] is fed by a net behaviour, replay or bot through [method apply_command] and [method simulate_tick]. The simulation is identical.
## GameSpice Net is not required; see [DotFpsNetSync] and docs/networking.md.
## It extends [DotPlayerController] for an identity and handover by a [DotPlayerControllerSwitch]; all of it is inert without a [DotPlayer] ancestor.


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if controller_id == &"":
		controller_id = &"fp"

	# Binds this node to its DotPlayer, when there is one. Harmless and inert when
	# there is not, which is the case in three of the four games that use this addon.
	super()

	var res := setup()
	# READY switched processing on for the overridden _process; only a view needs it.
	set_process(view != null)

	if not res.ok:
		DotLog.result(CHANNEL, "controller setup", res)
		set_physics_process(false)
		return

	set_physics_process(drive == Drive.LOCAL)


## Builds everything. Called by [method Node._ready]; safe to call again after
## changing the tunables.
func setup() -> DotResult:
	var usable := _resolve_tunables()
	if not usable.ok:
		return usable

	# The noclip gate is applied per tick, not here (see _gate_abilities): the tunables are a Resource the host keeps,
	# so anything assigning can_noclip later (a server reloading config mid-round) would re-open a gate set once at setup.
	_gate_abilities()

	var wired := _resolve_nodes()
	if not wired.ok:
		return wired

	body = _make_body()
	motor = DotFpsMotor.new(tunables, body)
	motor.set_tick_rate(tick_rate)
	motor.static_world = static_world
	DotFpsNetSync.set_tick_rate(tick_rate)

	if surfaces != null:
		motor.surfaces = surfaces
		motor.surface_resolver = _resolve_surface_id

	_register_extensions()

	# A host's own modes, after a subclass's, in list order: the same order on every machine
	# and on every rebuild (a style rebuilds the motor, which would otherwise drop them).
	for extra: Variant in extra_modes:
		if extra is DotFpsMoveMode:
			var _id := motor.register_mode(extra)

	# After the game's own, so turning this on does not renumber a game's modifiers.
	if admin_abilities:
		# DotFpsAdminModifiers, loaded so it and this file do not keep each other's parsers alive.
		var _count: int = (load("uid://debq1g843c2uy") as GDScript).register(motor)

	_setup_sampler()

	if _body_node != null:
		state.position = _body_node.global_position
		_previous_state.copy_from(state)
	_position_two_back = Vector3(NAN, NAN, NAN)

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


## The tunables this setup runs with: the style applied to the base, then loaded or validated.
func _resolve_tunables() -> DotResult:
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

	return DotResult.success(null)


## A local controller samples its own input; warns when the actions it reads are not bound.
func _setup_sampler() -> void:
	if drive == Drive.LOCAL:
		if use_touch_sampler and DotPlatform.has_touch():
			var touch := DotFpsTouchSampler.new(tunables)
			touch.set_screen_width(get_viewport().get_visible_rect().size.x if is_inside_tree() else 1152.0)
			sampler = touch
		else:
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

	# Unset refs fall back to "the obvious node under the body": a player has one collider and one view. An explicit ref always wins.
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
		# state, so it is wired here instead of leaving every game to remember it. Guarded:
		# this runs again when the controller re-enters the tree.
		if not landed.is_connected(view.note_landing):
			landed.connect(view.note_landing)

	return DotResult.success(null)


## A ref that finds the nearest descendant of a type, or nothing.
## [constant DotNodeRef.OnMissing.NULL], not FAIL: "no view" is a headless server, not an error.
static func _descendant_ref(type: StringName) -> DotNodeRef:
	var ref := DotNodeRef.new()
	ref.mode = DotNodeRef.Mode.DESCENDANT_OF_TYPE
	ref.type_name = type
	ref.on_missing = DotNodeRef.OnMissing.NULL
	return ref


## Registers this game's movement modes and modifiers. Override and call the motor.
## Called before the first tick in a fixed order on every machine: ids are handed out by registration order and travel on the wire, so conditional registration gives two peers different ids.
##
## [codeblock]
## func _register_extensions() -> void:
##     motor.register_modifier(preload("res://movement/speed_pad.tres"))
##     _ladder = motor.register_mode(LadderMode.new())
## [/codeblock]
func _register_extensions() -> void:
	pass


## Movement modes a host adds without subclassing (water, a ladder), registered on every
## [method setup] straight after [method _register_extensions], in this order. Every
## machine must list the same modes in the same order: the mode id is on the wire.
var extra_modes: Array[DotFpsMoveMode] = []


## Maps a collider to a surface id, for the motor.
## Reads scene metadata, not the physics handle, whose instance id differs between client and server. Cached until the player steps onto a different collider.
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


## Called before the motor runs, on the tick about to be simulated.
## Override for anything inside the simulation. It runs during replays too, so it is bound by the determinism rule of [method DotFpsMotor.simulate]: no wall clock, no unseeded random.
func _on_pre_simulate(_tick: int, _delta: float) -> void:
	pass


## Called after the motor runs and the scene has been updated.
## For cosmetic or non-simulated work; it also runs during a replay, so check [method is_replaying] before a side effect.
func _on_post_simulate(_tick: int, _delta: float) -> void:
	pass


## Whether the tick being simulated is a prediction replay rather than a fresh one.
## Anything that fires a sound or sends a message must not repeat it on a replay.
func is_replaying() -> bool:
	return _replaying


## Marks the following ticks as a replay. dot-net's reconciliation calls this.
func begin_replay() -> void:
	_replaying = true


func end_replay() -> void:
	_replaying = false


## Whether a command should be simulated at all. Override to veto input.
## Returning false substitutes a neutral command, because skipping a tick desynchronises the tick counter.
func _accept_command(_command: DotFpsCommand) -> bool:
	return true



## Applies a modifier. Server-side in a networked game; replicated to the owner.
func add_modifier(id: StringName) -> bool:
	return motor != null and motor.add_modifier(state, id)


func remove_modifier(id: StringName) -> bool:
	return motor != null and motor.remove_modifier(state, id)


func has_modifier(id: StringName) -> bool:
	return motor != null and motor.has_modifier(state, id)


## Puts this player on a movement style, rebuilding everything that depends on it. Pass null to go back to the unstyled tunables.
## Rebuilds the motor: it holds the tunables, so assigning [member style] alone changes nothing.
## Not safe mid-run in a timed game: it changes what every later tick produces, so the timer treats it as stopping the run.
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


## The collision layers this player's movement sweeps, set so it survives a style.
## Use this, not `tunables.collision_mask`: a style rebuilds [member tunables] from the base copy, so a mask on the live tunables reverts at the next [method set_style].
## The base, the live tunables and the body all take it.
func set_collision_mask(mask: int) -> void:
	if _base_tunables != null:
		_base_tunables.collision_mask = mask
	if tunables != null:
		tunables.collision_mask = mask
	if body != null:
		body.collision_mask = mask


## Layers this player may walk out of when it starts inside them (other players' hulls; see
## [member DotFpsBody.pass_out_mask]). Kept across a rebuilt body.
func set_pass_out_layers(mask: int) -> void:
	_pass_out_mask = mask
	if body != null:
		body.pass_out_mask = mask


## Bodies this player passes through although their hulls are solid: a pair the game's rules let
## through (`DotPlayerBodyRules.apply_exceptions`). Kept across a rebuilt body, and excluded from
## every query the body makes, so a rest or ground question ignores them as the sweep does.
func set_extra_excludes(rids: Array[RID]) -> void:
	_extra_exclude = rids.duplicate()
	if body != null:
		body.exclude = _exclude_list()


func _exclude_list() -> Array[RID]:
	var out: Array[RID] = []
	if _body_node is CollisionObject3D:
		out.append((_body_node as CollisionObject3D).get_rid())
	out.append_array(_extra_exclude)
	return out


## Switches movement mode, running the mode's exit and enter hooks.
func set_mode(mode: int) -> void:
	if motor != null:
		motor.set_mode(state, mode)


## A [DotFpsSimulator] of this player's movement: a second motor with copies of its tunables, body, modifiers and modes, which a bot runs ahead on copies of [member state].
## [param p_body] replaces the copy of [member body]. Null before [method setup] or when the body cannot be copied.
## Build a new one after a style or map changes the tunables or body; it does not follow them.
func simulator(p_body: DotFpsBody = null) -> DotFpsSimulator:
	if motor == null:
		return null
	return DotFpsSimulator.new().setup(tunables, motor, body, tick_rate, p_body)


## Builds the collision adapter. Override to simulate against your own geometry.
func _make_body() -> DotFpsBody:
	var physics := DotFpsPhysicsBody.new()
	physics.collision_mask = tunables.collision_mask
	physics.pass_out_mask = _pass_out_mask

	# Our own collider is excluded, or every downward probe hits it and the player stands on
	# themselves at the height they spawned.
	physics.exclude = _exclude_list()

	var bound := physics.bind(_body_node)
	if not bound.ok:
		DotLog.result(CHANNEL, "physics body", bound)

	return physics


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""



func _input(event: InputEvent) -> void:
	if drive == Drive.LOCAL and sampler != null:
		if sampler is DotFpsTouchSampler:
			(sampler as DotFpsTouchSampler).set_screen_width(get_viewport().get_visible_rect().size.x)
		sampler.handle_event(event)


func _physics_process(delta: float) -> void:
	if not _started or drive != Drive.LOCAL:
		return

	# A fixed step accumulated from the frame time, not the frame's own delta: determinism needs a constant step both peers agree on, and a variable one tunes differently on a faster-rendering machine.
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
		var drawn := render_state()
		# The view as of this frame's mouse, not the last tick's: a frame that ran no tick
		# would otherwise not turn. See [method DotFpsSampler.look_now].
		if drive == Drive.LOCAL and sampler != null:
			var look := sampler.look_now()
			drawn.yaw = look.x
			drawn.pitch = look.y
		view.apply(drawn, motor, delta)



## Sets the command the next [method simulate_tick] will use.
## Sanitised here so a driver cannot forget: on a server every field arrived from a client.
func apply_command(command: DotFpsCommand) -> void:
	if command == null:
		return

	command.sanitise(tunables.pitch_min, tunables.pitch_max)

	# Before the motor, on both machines, in place and idempotent: filtering only on the server makes the client predict movement the server will not produce,
	# and a replay runs this again over the stored commands.
	if style != null:
		style.filter_command(command)

	current_command = command


## Advances the simulation by one tick.
## [param delta] must be the fixed tick duration, not a frame time. Under GameSpice Net it runs on the server and the predicting client with the identical command.
func simulate_tick(tick: int, delta: float) -> void:
	if not begin_tick(tick, delta):
		return
	motor.simulate(state, current_command, delta)
	if DotFpsMotor.profile or phase_timers:
		_lap_ctrl(2, 0)
	end_tick(tick, delta)


## [method simulate_tick] up to the motor, for a game that runs the motor itself ([DotFpsMotorBatch]); false when the tick does not run.
## After the motor's tick the game calls [method end_tick].
func begin_tick(tick: int, delta: float) -> bool:
	if not _started or drive == Drive.REMOTE:
		return false

	var prof_t := Time.get_ticks_usec() if (DotFpsMotor.profile or phase_timers) else 0

	# Re-applied every tick so it cannot be undone by anything that touches the
	# tunables between ticks.
	_gate_abilities()

	if current_command == null:
		# A starved tick repeats the last command (keeps the view and held buttons, drops the
		# movement), as the netcode expects; a fresh command has yaw and pitch zero and would
		# turn the player north for a tick.
		current_command = _repeat_command()

	if not _accept_command(current_command):
		# Substituted, not skipped: skipping leaves the tick counter behind the server's.
		current_command = DotFpsCommand.new()
		current_command.yaw = state.yaw
		current_command.pitch = state.pitch

	# A reset (setup, teleport) makes the previous state the current one.
	_position_two_back = _previous_state.position
	# Only what the render blend reads ([method render_state], [method previous_position]): a whole copy_from is about
	# 30 property reads a tick per player, on a server that never draws one. Setup and teleport still copy it whole.
	_previous_state.position = state.position
	_previous_state.crouch_fraction = state.crouch_fraction

	_before_mode = state.mode
	_before_y = state.position.y
	_before_fall = state.velocity.y
	_before_crouched = state.is_crouched()
	_before_surface = state.surface
	_before_sliding = state.is_sliding()
	_before_launches = motor.launches
	_before_dashes = motor.dashes
	_before_wall_running = state.is_wall_running()
	_before_wall_jumps = motor.wall_jumps

	if prof_t != 0:
		_lap_ctrl(0, prof_t)
	_on_pre_simulate(tick, delta)

	_consume_external_velocity(state, _replaying)

	# Every tick: a game sets the tunables' mask after setup, and the body copied it when built.
	if body != null and body.collision_mask != tunables.collision_mask:
		body.collision_mask = tunables.collision_mask

	if prof_t != 0:
		_lap_ctrl(1, prof_t)
	return true


var _before_mode: DotFpsState.Mode = DotFpsState.Mode.GROUND
var _before_y: float = 0.0
var _before_fall: float = 0.0
var _before_crouched: bool = false
var _before_surface: StringName = &""
var _before_sliding: bool = false
var _before_launches: int = 0
var _before_dashes: int = 0
var _before_wall_running: bool = false
var _before_wall_jumps: int = 0


## [method simulate_tick] after the motor: publishes the tick and emits what changed.
func end_tick(tick: int, delta: float) -> void:
	var prof_t := Time.get_ticks_usec() if (DotFpsMotor.profile or phase_timers) else 0
	if prof_t != 0:
		_lap_ctrl_at = prof_t

	_tick = tick
	_publish(_before_mode, _before_y, _before_fall)
	if prof_t != 0:
		_lap_ctrl(3, prof_t)
	_report_changes(_before_crouched, _before_surface)
	if prof_t != 0:
		_lap_ctrl(4, prof_t)

	if not _replaying:
		if state.is_sliding() != _before_sliding:
			slide_changed.emit(state.is_sliding())

		if motor.launches != _before_launches:
			launched.emit()

		if motor.dashes != _before_dashes:
			dashed.emit()

		if motor.wall_jumps != _before_wall_jumps:
			wall_jumped.emit()

		if state.is_wall_running() != _before_wall_running:
			wall_run_changed.emit(state.is_wall_running())

		if motor.view_turn != 0.0:
			view_turned.emit(motor.view_turn)
			if sampler != null:
				sampler.look_at_angles(sampler.yaw + motor.view_turn, sampler.pitch)

	# Not during a replay: the statistics have seen that tick, and a lossy client would double-count.
	if not _replaying:
		state.airborne_time = (state.airborne_time + delta) if state.mode == DotFpsState.Mode.AIR else 0.0
	if not _replaying and observe_stats:
		stats.observe(state, current_command, _stats_previous, delta)
		if motor.perf_caches:
			# Observe only asks whether there was a previous command (null on the first tick and after a style change), never reads it: one object kept, not one allocated a tick.
			if _stats_previous == null:
				_stats_previous = current_command.duplicate_command()
		else:
			_stats_previous = current_command.duplicate_command()

	if prof_t != 0:
		_lap_ctrl(5, prof_t)
	_on_post_simulate(tick, delta)

	simulated.emit(tick, state)
	if prof_t != 0:
		_lap_ctrl(6, prof_t)


## Per-phase microseconds of [method simulate_tick] outside the motor, filled only while [member DotFpsMotor.profile] is on: pre (copy, gates), consume+mask, motor, publish, report, signals+stats, post.
static var phase_us := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
## Fills [member phase_us] without [member DotFpsMotor.profile], which also turns the native motor off: the phases of the path players really run.
static var phase_timers := false
var _lap_ctrl_at: int = 0


func _lap_ctrl(phase: int, start: int) -> void:
	var now := Time.get_ticks_usec()
	phase_us[phase] += now - (start if phase == 0 else _lap_ctrl_at)
	_lap_ctrl_at = now


## Emits the change signals for anything the tick altered.
## Diffed here so a game gets one edge per change instead of polling.
func _report_changes(
	before_crouched: bool,
	before_surface: StringName
) -> void:
	if state.is_crouched() != before_crouched:
		crouch_changed.emit(state.is_crouched())

	if state.surface != before_surface:
		surface_changed.emit(before_surface, state.surface)

	# Modifiers are diffed against a baseline that persists across ticks, not one captured at the top of this one:
	# a modifier applied between ticks is already present when the next starts, so a same-tick baseline never reports "added".
	# It also reports state at a tick boundary, where the replicated copy changes, so client and server agree when it started.
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
## Two gates: [member DotFpsTunables.can_noclip] is shared config the client holds and sets the command bit for; [member allow_noclip] is one controller's property a server grants per player.
func _gate_abilities() -> void:
	if tunables != null and not allow_noclip and tunables.can_noclip:
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
	var pt := Time.get_ticks_usec() if (DotFpsMotor.profile or phase_timers) else 0
	# Written only when the node is elsewhere: a write, even of the same place, walks the whole body subtree (hitboxes, figure)
	# marking transforms dirty, several microseconds a player a tick, and a player standing still did that every tick.
	if _body_node != null and _body_node.global_position != state.position:
		_body_node.global_position = state.position
	if pt != 0:
		phase_us[7] += Time.get_ticks_usec() - pt

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
	var shape_height := maxf(height, tunables.radius * 2.0)

	# Written only when it differs from the shape: assigning a size, even the same one, makes the shape emit `changed` and re-send itself to the physics server (the physics body does the same in `DotFpsPhysicsBody._configure`). Compared against the shape itself, so a size changed from outside is still put back. The shape and the node hold 32-bit floats, so a value such as 1.8 never reads back equal to the one written: a value that is the one last written and reads back as it read back then is already there (without this every player re-sent its shape and moved its collider every tick).
	var shape_now := _capsule.height
	if shape_now != shape_height and not (shape_height == _sent_height and shape_now == _held_height):
		_capsule.height = shape_height
		_sent_height = shape_height
		_held_height = _capsule.height

	var radius := tunables.radius
	var radius_now := _capsule.radius
	if radius_now != radius and not (radius == _sent_radius and radius_now == _held_radius):
		_capsule.radius = radius
		_sent_radius = radius
		_held_radius = _capsule.radius

	if _collider != null:
		# The collider's origin is its centre and the body's is its feet.
		var centre := height * 0.5
		var centre_now := _collider.position.y
		if centre_now != centre and not (centre == _sent_centre and centre_now == _held_centre):
			_collider.position.y = centre
			_sent_centre = centre
			_held_centre = _collider.position.y


## [method _apply_collider]'s last writes and what the shape and node held after them (NAN: none yet).
var _sent_height := NAN
var _held_height := NAN
var _sent_radius := NAN
var _held_radius := NAN
var _sent_centre := NAN
var _held_centre := NAN



## Moves the player, discarding velocity and smoothing.
## Under GameSpice Net this is server-authoritative: a client that teleported itself is corrected on the next snapshot.
func teleport(
	position: Vector3,
	yaw: float = NAN,
	pitch: float = NAN
) -> void:
	state.position = position
	state.velocity = Vector3.ZERO
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 0.0
	state.airborne_time = 0.0

	if is_finite(yaw):
		state.yaw = yaw
	if is_finite(pitch):
		state.pitch = clampf(pitch, tunables.pitch_min, tunables.pitch_max)

	_previous_state.copy_from(state)
	_position_two_back = Vector3(NAN, NAN, NAN)
	_last_modifiers = state.modifiers.duplicate()

	if sampler != null:
		sampler.look_at_angles(state.yaw, state.pitch)

	if _body_node != null:
		_body_node.global_position = position

	if view != null:
		view.snap()



## Facts a statistics rule can read about this player right now: airborne, airborne_seconds, wall_running, sliding and speed. GameSpice Combat reads it duck-typed from a victim's controller; only a simulating (server) controller has true values.
func get_stats_facts() -> Dictionary:
	return {
		"airborne": state.mode == DotFpsState.Mode.AIR,
		"airborne_seconds": state.airborne_time,
		"wall_running": state.is_wall_running(),
		"sliding": state.is_sliding(),
		"speed": state.speed(),
	}


func describe() -> Dictionary:
	return {
		"drive": Drive.keys()[drive],
		"tick": _tick,
		"tick_rate": tick_rate,
		"allow_noclip": allow_noclip,
		"admin_abilities": admin_abilities,
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


# The DotPlayerController contract: five small methods and one translation, unused unless a DotPlayerControllerSwitch hands this controller a player.


## Translates a generic intent into this controller's own command, and ticks once.
## [DotPlayerIntent] is what every controller agrees on (move, look, buttons); the extras of this movement model keep their defaults.
## A game that only uses this controller should keep calling [method apply_command] and [method simulate_tick].
func _apply_intent(intent: DotPlayerIntent, delta: float) -> void:
	if intent == null:
		return

	var command := DotFpsCommand.new()
	command.move = intent.move
	command.yaw = intent.view_yaw
	command.pitch = intent.view_pitch
	command.set_button(DotFpsCommand.BUTTON_JUMP, intent.holding(DotPlayerIntent.Btn.JUMP))
	command.set_button(DotFpsCommand.BUTTON_CROUCH, intent.holding(DotPlayerIntent.Btn.CROUCH))
	command.set_button(DotFpsCommand.BUTTON_SPRINT, intent.holding(DotPlayerIntent.Btn.SPRINT))
	command.set_button(DotFpsCommand.BUTTON_WALK, intent.holding(DotPlayerIntent.Btn.WALK))

	apply_command(command)
	simulate_tick(_tick, delta)
	_tick += 1


## The state's angles are degrees and everything on the base is radians.
## Every override below converts; a handover to a third-person controller would otherwise rotate the player by a factor of 57.
func _read_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(state.yaw)), state.position)


func _write_transform(to: Transform3D) -> void:
	teleport(to.origin, rad_to_deg(to.basis.get_euler().y))


func _read_velocity() -> Vector3:
	return state.velocity


func _write_velocity(v: Vector3) -> void:
	state.velocity = v


func _read_yaw() -> float:
	return deg_to_rad(state.yaw)


func _read_pitch() -> float:
	return deg_to_rad(state.pitch)


func _write_angles(yaw: float, pitch: float) -> void:
	state.yaw = rad_to_deg(yaw)
	state.pitch = clampf(rad_to_deg(pitch), tunables.pitch_min, tunables.pitch_max)


## Where the camera is, which is not where the feet are: the base default is the capsule origin, at the knees.
## The height comes from the motor's `eye_position`, which accounts for the current stance, not from `stand_height`.
func eye_transform() -> Transform3D:
	var height := (
		motor.eye_position(state).y - state.position.y if motor != null
		else tunables.stand_height - tunables.radius * 0.5
	)

	return Transform3D(
		Basis(Vector3.UP, deg_to_rad(state.yaw))
		* Basis(Vector3.RIGHT, deg_to_rad(state.pitch)),
		state.position + Vector3.UP * height
	)


## The motion description an animation driver wants, without it importing this addon.
func motion() -> Dictionary:
	return {
		"speed": Vector2(state.velocity.x, state.velocity.z).length(),
		"vertical": state.velocity.y,
		"on_floor": state.mode == DotFpsState.Mode.GROUND,
		# `crouch_fraction`, not the held flag: a player who released crouch under a low
		# ceiling is no longer holding it and is still crouched, and an animation driver
		# reading the flag would stand them up inside the ceiling.
		"crouched": state.crouch_fraction > 0.5,
		"sliding": state.is_sliding(),
		"sprinting": state.sprinting,
		"sprint_blocks_aim": tunables != null and tunables.sprint_blocks_aim,
		"sprint_blocks_fire": tunables != null and not tunables.sprint_can_shoot,
		"sprint_shot_follows_barrel": tunables != null and tunables.sprint_shot_follows_barrel,
		"facing": deg_to_rad(state.yaw),
	}
