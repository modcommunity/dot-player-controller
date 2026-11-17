extends "res://examples/fps_controller_selftest_sections.gd"

## Exercises [DotFpsController] as a node in a real scene tree. Run: [code]godot --headless --path . res://examples/fps_controller_selftest.tscn[/code]
## [method movement_selftest] tests the simulation; this tests the wiring around it (reference resolution, collider following the crouch, fixed-step accumulator, drive modes, registry, the noclip safety gate), which a host game touches first.
## Scenes are built in code so a failure names a line and an editor change cannot silently pass.

const CHECKS := 132

## Sections entered against sections that ran to their last line, and against this: a
## runtime error aborts a section silently. CHECKS is the other half (docs/testing.md).
const SECTIONS := 20


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-player-controller controller self-test")
	print("")

	await _test_zero_configuration()
	await _test_external_drive()
	await _test_threaded_bind()
	await _test_mask_set_after_setup()
	await _test_collider_follows_crouch()
	await _test_noclip_gate()
	await _test_admin_abilities()
	await _test_teleport_and_signals()
	await _test_registry_and_describe()
	await _test_local_drive_accumulator()
	await _test_surfaces_from_scene()
	await _test_change_signals()
	await _test_command_veto()
	_test_wall_run_roll()
	_test_wall_run_camera_roll()
	_test_view_motion()
	await _test_wheel_jump()
	await _test_pair_exceptions()
	await _test_landing_kick_and_legs()
	await _test_touch_sampler_pick()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_surfaces_from_scene() -> void:
	_section("surfaces from the scene")

	var world := _make_world()

	# Mark the floor the way a level designer would, and check the controller
	# resolves it without being told anything about that particular collider.
	var ground := world.get_child(0)
	ground.set_meta(&"dot_fps_surface", "ice")

	var ice := DotFpsSurface.make(&"ice")
	ice.friction_scale = 0.02
	ice.accelerate_scale = 0.1

	var set := DotFpsSurfaceSet.new()
	set.add(ice)

	var controller := _make_player(
		world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void: c.surfaces = set
	)

	await get_tree().physics_frame
	await get_tree().physics_frame

	controller.teleport(Vector3(0.0, 0.5, 0.0))

	for i in range(120):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)

	_check(
		controller.state.surface == &"ice",
		"the surface resolves from node metadata, with nothing wired by hand",
		"got '%s'" % controller.state.surface
	)

	# The resolver runs inside the simulation and must not do a scene lookup per
	# tick — the cache is what makes surfaces affordable on a 32-slot server.
	controller.state.velocity = Vector3(8.0, 0.0, 0.0)

	for i in range(120):
		controller.apply_command(_command())
		controller.simulate_tick(200 + i, STEP)

	_check(
		controller.state.horizontal_speed() > 6.0,
		"and ice actually applies to the simulation",
		"%.2f m/s from 8.00" % controller.state.horizontal_speed()
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_change_signals() -> void:
	_section("change signals")

	var world := _make_world()

	var step := StaticBody3D.new()
	var step_shape := CollisionShape3D.new()
	var step_box := BoxShape3D.new()
	step_box.size = Vector3(8.0, 0.3, 4.0)
	step_shape.shape = step_box
	step.add_child(step_shape)
	step.position = Vector3(0.0, 0.15, -6.0)
	world.add_child(step)

	var boost := DotFpsModifier.make(&"boost")
	boost.max_speed_scale = 1.5
	boost.duration_sec = 0.25

	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)

	await get_tree().physics_frame
	await get_tree().physics_frame

	controller.motor.register_modifier(boost)

	# Arrays, not ints: a GDScript lambda captures locals by value, so a counter
	# incremented in a handler stays zero outside it.
	var crouches: Array[bool] = []
	var steps: Array[float] = []
	var added: Array[StringName] = []
	var removed: Array[StringName] = []

	controller.crouch_changed.connect(
		func(c: bool) -> void: crouches.append(c))
	controller.stepped_up.connect(
		func(h: float) -> void: steps.append(h))
	controller.modifier_added.connect(
		func(id: StringName) -> void: added.append(id))
	controller.modifier_removed.connect(
		func(id: StringName) -> void: removed.append(id))

	controller.teleport(Vector3(0.0, 0.5, 0.0))

	for i in range(60):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)

	# Crouch, then release. One edge each, not one per tick held.
	for i in range(60):
		controller.apply_command(
			_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH))
		controller.simulate_tick(100 + i, STEP)

	for i in range(60):
		controller.apply_command(_command())
		controller.simulate_tick(200 + i, STEP)

	_check( crouches.size() == 2 and crouches[0] and not crouches[1], "crouching reports one edge down and one up", str(crouches) )

	# Walk into the step.
	for i in range(240):
		controller.apply_command(_command(1.0))
		controller.simulate_tick(300 + i, STEP)

	_check(steps.size() > 0, "stepping up is reported", "%d" % steps.size())
	_check( steps.size() == 0 or steps[0] <= controller.tunables.step_height + 0.01, "with a height no larger than step_height" )

	# A modifier that expires reports both edges, from the same diff.
	_check(controller.add_modifier(&"boost"), "a modifier applies through the controller")

	for i in range(60):
		controller.apply_command(_command())
		controller.simulate_tick(600 + i, STEP)

	_check(added.size() == 1 and added[0] == &"boost", "and is reported once", str(added))
	_check( removed.size() == 1 and removed[0] == &"boost", "and its expiry is reported once", str(removed) )
	_check( not controller.has_modifier(&"boost"), "after which the controller agrees it is gone" )

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_command_veto() -> void:
	_section("command veto and extension registration")

	var world := _make_world()

	var player := CharacterBody3D.new()
	world.add_child(player)

	var collision := CollisionShape3D.new()
	collision.shape = CapsuleShape3D.new()
	player.add_child(collision)

	var controller := FrozenController.new()
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.register_default_actions = false
	player.add_child(controller)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check( controller.registered == 1, "_register_extensions runs exactly once, before the first tick", "%d" % controller.registered )
	_check( controller.motor.modifier_index(&"slow") == 0, "and what it registered is there" )

	controller.teleport(Vector3(0.0, 0.5, 0.0))

	for i in range(120):
		controller.apply_command(_command(1.0))
		controller.simulate_tick(i + 1, STEP)

	_check(
		controller.state.horizontal_speed() < 0.1,
		"a vetoed command does not move the player",
		"%.3f m/s" % controller.state.horizontal_speed()
	)

	# Vetoed, not skipped: the tick still ran, so gravity applied and the tick
	# counter kept up with the server's.
	_check( controller.state.is_grounded(), "but the tick still ran, so the player still fell and landed" )

	controller.frozen = false

	for i in range(120):
		controller.apply_command(_command(1.0))
		controller.simulate_tick(200 + i, STEP)

	_check(
		controller.state.horizontal_speed() > 4.0,
		"and lifting the veto restores control",
		"%.2f m/s" % controller.state.horizontal_speed()
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_zero_configuration() -> void:
	_section("zero-configuration wiring")

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(controller.motor != null, "the motor is built")
	_check(controller.body is DotFpsPhysicsBody, "against the physics body")
	_check( controller.view != null, "the view is found without a view_ref being set" )
	_check( controller.tunables != null and controller.tunables.validate().ok, "default tunables are created and valid" )

	# The one thing the whole family exists to avoid: a hardcoded path. Every
	# reference above was resolved by type, from the body, with nothing configured.
	_check( controller.view.camera() != null, "the view finds the camera without a camera_ref being set" )
	_check(controller.is_processing(), "a controller with a view draws it every frame")
	var kept := controller.view
	controller.view = null
	_check(not controller.is_processing(), "and one without a view has no frame work")
	controller.view = kept
	_check(controller.is_processing(), "until a view is assigned again")

	world.queue_free()
	await get_tree().process_frame
	_done()


## With `physics/3d/run_on_separate_thread` the space is reachable only inside the step, and a server
## makes a player's body between ticks (a join): the bind must not ask for the space there.
func _test_threaded_bind() -> void:
	_section("a body made between ticks on a threaded server binds in the step")
	var native := load("res://addons/dot_player_controller/fp/motion/dot_fps_physics_body_native.gd") as GDScript
	var was: bool = native.get(&"threaded_physics")
	native.set(&"threaded_physics", true)
	await get_tree().process_frame

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)
	var body := controller.body as DotFpsPhysicsBody
	_check(body != null and not body.is_bound(), "made between ticks, the body holds no space handle")

	await get_tree().physics_frame
	controller.teleport(Vector3(0.0, 2.0, 0.0))
	for i in range(120):
		controller.apply_command(_command(0.0))
		controller.simulate_tick(i + 1, STEP)
	_check(body != null and body.is_bound() and controller.state.is_grounded(),
		"its first tick in the step binds it, and it lands",
		"bound %s at %s" % [body != null and body.is_bound(), controller.state.position])

	native.set(&"threaded_physics", was)
	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_external_drive() -> void:
	_section("external drive")

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var player := controller.get_parent() as Node3D
	controller.teleport(Vector3(0.0, 2.0, 0.0))

	for i in range(180):
		controller.apply_command(_command(1.0))
		controller.simulate_tick(i + 1, STEP)

	_check(
		controller.state.is_grounded(),
		"the player lands under external drive",
		"mode %s at %s" % [
			DotFpsState.Mode.keys()[controller.state.mode],
			controller.state.position,
		]
	)
	_check( controller.state.position.z < -5.0, "and moves in the commanded direction", "z = %.2f" % controller.state.position.z )

	# The simulated position has to reach the scene, or nothing else in the game can
	# see where the player is.
	_check(
		player.global_position.distance_to(controller.state.position) < 0.001,
		"the body node follows the simulated position",
		"node %s vs state %s" % [player.global_position, controller.state.position]
	)

	# A tick with no fresh command must not stop the player dead — it repeats.
	var before := controller.state.position.z
	controller.current_command = null
	controller.simulate_tick(200, STEP)

	_check( controller.state.position.z < before, "a starved tick keeps the player moving rather than stopping dead" )

	# And keeps them LOOKING where they were. With no buttons held the starved tick used
	# a fresh command, whose yaw and pitch are zero, so every lost packet snapped the
	# view north and level for a tick — and the motor takes the view from the command.
	var looking := _command(0.0, 0.0, 90.0)
	looking.pitch = 20.0
	controller.apply_command(looking)
	controller.simulate_tick(201, STEP)
	controller.current_command = null
	controller.simulate_tick(202, STEP)

	_check(
		is_equal_approx(controller.state.yaw, 90.0)
		and is_equal_approx(controller.state.pitch, 20.0),
		"a starved tick with nothing held repeats the last view, not north",
		"yaw %.1f pitch %.1f" % [controller.state.yaw, controller.state.pitch]
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


## The mask a game sets on the tunables AFTER setup is the one the body sweeps: games know their physics layout only then, and a body that kept the mask copied at build let players walk through every prop.
func _test_mask_set_after_setup() -> void:
	_section("a mask set after setup is the one swept")

	var world := Node3D.new()
	add_child(world)
	# The only floor is on layer 2, which the default mask (1) does not see.
	var floor := StaticBody3D.new()
	floor.collision_layer = 2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	shape.shape = box
	floor.add_child(shape)
	floor.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(floor)

	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)
	await get_tree().physics_frame
	await get_tree().physics_frame

	controller.tunables.collision_mask = 1 | 2
	controller.teleport(Vector3(0.0, 1.0, 0.0))
	for i in range(90):
		controller.apply_command(_command(0.0))
		controller.simulate_tick(i + 1, STEP)

	_check(controller.body.collision_mask == 3, "the body sweeps the tunables' mask", "body %d" % controller.body.collision_mask)

	_check(controller.state.is_grounded() and controller.state.position.y > -0.1,
		"and the player stands on the layer it added", "y %.2f" % controller.state.position.y)

	# A style rebuilds the tunables from the base: set_collision_mask is the way that survives.
	# The order the bug needs: a style first (the base is taken, the live tunables become a
	# copy), then the mask, then another style (rebuilt from the base).
	var _first := controller.set_style(DotFpsStyle.new())
	controller.set_collision_mask(1 | 4)
	var _styled := controller.set_style(DotFpsStyle.new())
	controller.simulate_tick(91, STEP)
	_check(controller.tunables.collision_mask == 5 and controller.body.collision_mask == 5,
		"and set_collision_mask survives a style", "tunables %d body %d" % [controller.tunables.collision_mask, controller.body.collision_mask])

	# A host's own mode, without subclassing: registered on every setup, so a style's rebuilt
	# motor still has it, under the same id.
	var swim := DotFpsSwimMode.new()
	controller.extra_modes = [swim]
	var _with := controller.set_style(DotFpsStyle.new())
	var first_id := controller.motor.mode_id_of(&"swim")
	var _again := controller.set_style(DotFpsStyle.new())
	_check(first_id >= DotFpsState.FIRST_CUSTOM_MODE, "a host's extra mode is registered by setup", str(first_id))
	_check(controller.motor.mode_id_of(&"swim") == first_id and controller.motor.mode_for(first_id) == swim,
		"and survives the motor a style rebuilds, under the same id")

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_collider_follows_crouch() -> void:
	_section("collider follows the crouch")

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var collision := controller.get_parent().get_node("Collision") as CollisionShape3D
	var capsule := collision.shape as CapsuleShape3D

	if not _check(capsule != null, "the collider carries a capsule"):
		world.queue_free()
		return

	# Not the shape the scene supplied: a CapsuleShape3D loaded from a .tscn is shared by every instance, so resizing one player's collider on crouch would resize every player's.
	_check( capsule != null and capsule.resource_path == "", "with a private shape, not one shared across instances" )

	controller.teleport(Vector3(0.0, 1.0, 0.0))

	for i in range(120):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)

	_check_near( capsule.height, controller.tunables.stand_height, 0.01, "standing height matches the tunables" )

	for i in range(120):
		controller.apply_command(_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH))
		controller.simulate_tick(200 + i, STEP)

	_check_near( capsule.height, controller.tunables.crouch_height, 0.01, "and the collider shrinks with the crouch" )
	_check_near(
		collision.position.y, controller.tunables.crouch_height * 0.5, 0.01,
		"and stays centred on the body, whose origin is at the feet"
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_noclip_gate() -> void:
	_section("noclip gate")

	var world := _make_world()
	var controller := _make_player(
		world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void:
			c.tunables = DotFpsTunables.with_profile("legacy")
			c.tunables.can_noclip = true
			c.allow_noclip = false
	)

	await get_tree().physics_frame
	await get_tree().physics_frame

	# The tunables say yes and the instance says no. The instance wins: the tunables
	# are shared configuration a client also holds a copy of, and the command's
	# noclip bit is set by the client. Only a server-side property can gate this.
	_check( not controller.tunables.can_noclip, "allow_noclip false overrides can_noclip true" )

	controller.teleport(Vector3(0.0, 1.0, 0.0))

	for i in range(60):
		controller.apply_command(_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP))
		controller.simulate_tick(i + 1, STEP)

	_check( controller.state.mode != DotFpsState.Mode.NOCLIP, "and a client asking for noclip does not get it" )

	world.queue_free()
	await get_tree().process_frame

	var allowed_world := _make_world()
	var allowed := _make_player(
		allowed_world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void:
			c.tunables = DotFpsTunables.with_profile("legacy")
			c.tunables.can_noclip = true
			c.allow_noclip = true
	)

	await get_tree().physics_frame
	await get_tree().physics_frame

	allowed.teleport(Vector3(0.0, 1.0, 0.0))
	allowed.apply_command(_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP))
	allowed.simulate_tick(1, STEP)

	_check( allowed.state.mode == DotFpsState.Mode.NOCLIP, "and does get it when the server allows it" )

	allowed_world.queue_free()
	await get_tree().process_frame
	_done()


## The controller half of DotFpsAdminModifiers: refused without the switch, and "off"
## lands a player even when their own tunables would have let them keep flying.
func _test_admin_abilities() -> void:
	_section("admin abilities")

	var plain_world := _make_world()
	var plain := _make_player(plain_world, DotFpsController.Drive.EXTERNAL)
	await get_tree().physics_frame

	var refused := DotFpsAdminModifiers.set_noclip(plain, true)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_UNSUPPORTED,
		"a controller built without admin_abilities refuses them rather than improvising"
	)

	plain_world.queue_free()
	await get_tree().process_frame

	var world := _make_world()
	var controller := _make_player(
		world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void:
			c.tunables = DotFpsTunables.with_profile("legacy")
			c.tunables.can_noclip = true
			c.allow_noclip = true
			c.admin_abilities = true
	)
	await get_tree().physics_frame

	controller.teleport(Vector3(0.0, 1.0, 0.0))
	var on := DotFpsAdminModifiers.set_noclip(controller, true)
	controller.apply_command(DotFpsCommand.new())
	controller.simulate_tick(1, STEP)

	_check(
		on.ok and controller.state.mode == DotFpsState.Mode.NOCLIP
		and DotFpsAdminModifiers.is_noclipped(controller),
		"with it, an admin noclip takes effect on the next tick"
	)

	var _off := DotFpsAdminModifiers.set_noclip(controller, false)
	controller.apply_command(DotFpsCommand.new())
	controller.simulate_tick(2, STEP)

	_check( controller.state.mode != DotFpsState.Mode.NOCLIP, "and turning it off lands a player whose own tunables allow noclip" )

	var applied := DotFpsAdminModifiers.set_speed(controller, 2.4)
	_check(
		applied.ok and is_equal_approx(float(applied.value), 2.0)
		and is_equal_approx(DotFpsAdminModifiers.speed_of(controller), 2.0),
		"a speed is applied as the nearest step and reported as that step",
		str(applied.value)
	)

	DotFpsAdminModifiers.clear(controller)
	_check(
		is_equal_approx(DotFpsAdminModifiers.speed_of(controller), 1.0)
		and not DotFpsAdminModifiers.is_frozen(controller),
		"and clear takes every admin modifier off"
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_teleport_and_signals() -> void:
	_section("teleport and signals")

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var landings: Array[float] = []
	# Arrays, not ints. A GDScript lambda captures locals by value, so `jumps += 1`
	# inside a handler increments the lambda's own copy and the test reads zero for
	# a signal that fired perfectly. An Array is captured by reference.
	var jumps: Array[int] = []
	var modes: Array[int] = []

	controller.landed.connect(func(impact: float) -> void: landings.append(impact))
	controller.jumped.connect(func() -> void: jumps.append(1))
	controller.mode_changed.connect(
		func(_a: DotFpsState.Mode, _b: DotFpsState.Mode) -> void: modes.append(1)
	)

	controller.teleport(Vector3(0.0, 4.0, 0.0), 45.0, -10.0)

	_check_near(controller.state.yaw, 45.0, 0.001, "teleport sets the view angles")
	_check( controller.state.velocity == Vector3.ZERO, "and discards velocity, so a fall does not carry through it" )
	_check( (controller.get_parent() as Node3D).global_position.y == 4.0, "and moves the node immediately, not on the next tick" )

	_check(controller.state.airborne_seconds() == 0.0 and controller.get_stats_facts()["airborne"], "teleport starts an airborne stretch at zero")
	for i in range(30):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)
	var air_facts := controller.get_stats_facts()
	_check_near(air_facts["airborne_seconds"], 30.0 * STEP, 0.001, "airborne seconds count simulated ticks")
	_check(air_facts["airborne"] and not air_facts["wall_running"], "facts report airborne, not wall running")
	controller.begin_replay()
	controller.apply_command(_command())
	controller.simulate_tick(31, STEP)
	controller.end_replay()
	_check_near(controller.state.airborne_seconds(), 30.0 * STEP, 0.001, "a replayed tick does not add airborne time")

	for i in range(240):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)

	_check(landings.size() == 1, "landing is reported once", "%d" % landings.size())
	_check(
		landings.size() == 1 and landings[0] > 5.0,
		"with the impact speed",
		"%.2f m/s" % (landings[0] if landings.size() > 0 else 0.0)
	)

	for i in range(60):
		controller.apply_command(
			_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0)
		)
		controller.simulate_tick(300 + i, STEP)

	_check(jumps.size() == 1, "a jump is reported once", "%d" % jumps.size())
	_check(modes.size() >= 3, "mode changes are reported", "%d" % modes.size())

	_test_external_push(controller)

	world.queue_free()
	await get_tree().process_frame
	_done()
