extends Node

## Exercises [DotFpsController] as a node in a real scene tree.
##
## [codeblock]
## godot --headless --path . res://examples/controller_selftest.tscn
## [/codeblock]
##
## [method movement_selftest] tests the simulation. This tests the wiring around it:
## reference resolution, the collider following the crouch, the fixed-step
## accumulator, the three drive modes, the registry, and the safety gate on noclip.
## None of that is reachable from the motor alone, and all of it is the part a host
## game touches first.
##
## The scenes are built in code rather than loaded from [code].tscn[/code] files so
## that a failure names a line rather than a resource, and so the test does not
## silently pass when someone edits a scene in the editor.

const STEP := 1.0 / 60.0

const CHECKS := 114

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 18

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-player-controller controller self-test")
	print("")

	await _test_zero_configuration()
	await _test_external_drive()
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
	_test_view_motion()
	await _test_wheel_jump()
	await _test_pair_exceptions()
	await _test_landing_kick_and_legs()

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


## A controller that refuses input, of the kind a respawn freeze would use.
class FrozenController extends DotFpsController:
	var frozen := true
	var registered := 0

	func _register_extensions() -> void:
		registered += 1

		var slow := DotFpsModifier.make(&"slow")
		slow.max_speed_scale = 0.25
		motor.register_modifier(slow)

	func _accept_command(_command: DotFpsCommand) -> bool:
		return not frozen


# --- Assertions ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _check_near(v: float, expected: float, tol: float, what: String) -> bool:
	return _check(
		absf(v - expected) <= tol,
		what,
		"got %.4f, expected %.4f ±%.4f" % [v, expected, tol]
	)


# --- Fixtures --------------------------------------------------------------

## Builds a world with a floor and returns its root.
func _make_world() -> Node3D:
	var world := Node3D.new()
	add_child(world)

	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(ground)

	return world


## The conventional player layout, with nothing wired by hand.
##
## Player (CharacterBody3D) / Collision, Head / Camera, View, Controller.
## [param configure] runs before the controller enters the tree.
##
## [b]It has to.[/b] A Node's _ready() fires on add_child, and DotFpsController does
## all of its wiring there — so a test that assigns tunables or register_service
## afterwards is configuring an object that has already finished setting itself up,
## and silently tests the defaults instead. Caught here, but it is exactly the
## mistake a host game makes when it builds a player from code.
func _make_player(
	world: Node3D,
	drive: DotFpsController.Drive,
	configure: Callable = Callable()
) -> DotFpsController:
	var player := CharacterBody3D.new()
	player.name = "Player"
	world.add_child(player)

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = CapsuleShape3D.new()
	player.add_child(collision)

	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)

	var camera := Camera3D.new()
	camera.name = "Camera"
	head.add_child(camera)

	var view := DotFpsView.new()
	view.name = "View"
	player.add_child(view)

	var controller := DotFpsController.new()
	controller.name = "Controller"
	controller.drive = drive
	controller.register_default_actions = false

	if configure.is_valid():
		configure.call(controller)

	player.add_child(controller)

	return controller


func _command(
	forward: float = 0.0,
	strafe: float = 0.0,
	yaw: float = 0.0,
	buttons: int = 0
) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(strafe, forward)
	c.yaw = yaw
	c.buttons = buttons
	return c


# --- Tests -----------------------------------------------------------------

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

	_check(
		crouches.size() == 2 and crouches[0] and not crouches[1],
		"crouching reports one edge down and one up",
		str(crouches)
	)

	# Walk into the step.
	for i in range(240):
		controller.apply_command(_command(1.0))
		controller.simulate_tick(300 + i, STEP)

	_check(steps.size() > 0, "stepping up is reported", "%d" % steps.size())
	_check(
		steps.size() == 0 or steps[0] <= controller.tunables.step_height + 0.01,
		"with a height no larger than step_height"
	)

	# A modifier that expires reports both edges, from the same diff.
	_check(controller.add_modifier(&"boost"), "a modifier applies through the controller")

	for i in range(60):
		controller.apply_command(_command())
		controller.simulate_tick(600 + i, STEP)

	_check(added.size() == 1 and added[0] == &"boost", "and is reported once", str(added))
	_check(
		removed.size() == 1 and removed[0] == &"boost",
		"and its expiry is reported once",
		str(removed)
	)
	_check(
		not controller.has_modifier(&"boost"),
		"after which the controller agrees it is gone"
	)

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

	_check(
		controller.registered == 1,
		"_register_extensions runs exactly once, before the first tick",
		"%d" % controller.registered
	)
	_check(
		controller.motor.modifier_index(&"slow") == 0,
		"and what it registered is there"
	)

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
	_check(
		controller.state.is_grounded(),
		"but the tick still ran, so the player still fell and landed"
	)

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
	_check(
		controller.view != null,
		"the view is found without a view_ref being set"
	)
	_check(
		controller.tunables != null and controller.tunables.validate().ok,
		"default tunables are created and valid"
	)

	# The one thing the whole family exists to avoid: a hardcoded path. Every
	# reference above was resolved by type, from the body, with nothing configured.
	_check(
		controller.view.camera() != null,
		"the view finds the camera without a camera_ref being set"
	)

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
	_check(
		controller.state.position.z < -5.0,
		"and moves in the commanded direction",
		"z = %.2f" % controller.state.position.z
	)

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

	_check(
		controller.state.position.z < before,
		"a starved tick keeps the player moving rather than stopping dead"
	)

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


## The mask a game sets on the tunables AFTER setup is the one the body sweeps. Games set it
## then, because that is when they know their physics layout, and the body used to keep the
## mask it copied when it was built: game-playground's players walked through every prop.
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

	# Not the shape the scene supplied. A CapsuleShape3D loaded from a .tscn is
	# shared between every instance of that scene, so resizing one player's collider
	# on crouch would resize every player's — a bug that only appears with more than
	# one player in the level.
	_check(
		capsule != null and capsule.resource_path == "",
		"with a private shape, not one shared across instances"
	)

	controller.teleport(Vector3(0.0, 1.0, 0.0))

	for i in range(120):
		controller.apply_command(_command())
		controller.simulate_tick(i + 1, STEP)

	_check_near(
		capsule.height, controller.tunables.stand_height, 0.01,
		"standing height matches the tunables"
	)

	for i in range(120):
		controller.apply_command(_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_CROUCH))
		controller.simulate_tick(200 + i, STEP)

	_check_near(
		capsule.height, controller.tunables.crouch_height, 0.01,
		"and the collider shrinks with the crouch"
	)
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
	_check(
		not controller.tunables.can_noclip,
		"allow_noclip false overrides can_noclip true"
	)

	controller.teleport(Vector3(0.0, 1.0, 0.0))

	for i in range(60):
		controller.apply_command(_command(0.0, 0.0, 0.0, DotFpsCommand.BUTTON_NOCLIP))
		controller.simulate_tick(i + 1, STEP)

	_check(
		controller.state.mode != DotFpsState.Mode.NOCLIP,
		"and a client asking for noclip does not get it"
	)

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

	_check(
		allowed.state.mode == DotFpsState.Mode.NOCLIP,
		"and does get it when the server allows it"
	)

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

	_check(
		controller.state.mode != DotFpsState.Mode.NOCLIP,
		"and turning it off lands a player whose own tunables allow noclip"
	)

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
	_check(
		controller.state.velocity == Vector3.ZERO,
		"and discards velocity, so a fall does not carry through it"
	)
	_check(
		(controller.get_parent() as Node3D).global_position.y == 4.0,
		"and moves the node immediately, not on the next tick"
	)

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

	world.queue_free()
	await get_tree().process_frame
	_done()


func _test_registry_and_describe() -> void:
	_section("registry and diagnostics")

	var world := _make_world()
	var controller := _make_player(
		world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void:
			c.register_service = true
			c.service_scope = &"p1"
	)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var scoped := DotRegistry.scoped_name(DotFpsController.SERVICE, &"p1")

	_check(
		DotRegistry.get_service(scoped) == controller,
		"a scoped controller registers under its scope"
	)

	# Scoped rather than global by default: two players in one scene would otherwise
	# overwrite each other's registration, which is the configuration split-screen
	# and a listen server both need.
	var lines := controller.describe_lines()
	_check(lines.size() > 4, "describe_lines produces something to paste in a report")

	var described := controller.describe()
	_check(
		described.has("state") and described.has("motor"),
		"describe covers the state and the motor"
	)

	world.queue_free()
	await get_tree().process_frame

	_check(
		not DotRegistry.has(scoped),
		"and unregisters when it leaves the tree"
	)
	_done()


func _test_local_drive_accumulator() -> void:
	_section("local drive")

	var world := _make_world()
	var controller := _make_player(
		world,
		DotFpsController.Drive.LOCAL,
		func(c: DotFpsController) -> void: c.tick_rate = 60
	)

	await get_tree().physics_frame
	await get_tree().physics_frame

	controller.teleport(Vector3(0.0, 1.0, 0.0))

	var ticks: Array[int] = []
	controller.simulated.connect(
		func(_t: int, _s: DotFpsState) -> void: ticks.append(1)
	)

	# A frame's worth of time at exactly the tick rate is one tick.
	controller._physics_process(STEP)
	_check(ticks.size() == 1, "one tick per frame at the tick rate", "%d" % ticks.size())

	# Three ticks' worth in one frame is three ticks, not one — otherwise a slow
	# frame silently loses simulation time and the player's movement depends on the
	# frame rate.
	ticks.clear()
	controller._physics_process(STEP * 3.0)
	_check(ticks.size() == 3, "and catches up after a slow frame", "%d" % ticks.size())

	# A very long stall is dropped rather than simulated, so a level load does not
	# spend the next frame running a thousand ticks and make the stall worse.
	ticks.clear()
	controller._physics_process(10.0)
	_check(ticks.size() <= 8, "but a long stall is bounded", "%d ticks" % ticks.size())

	# Rendering interpolates between ticks; the simulation does not.
	var rendered := controller.render_state()
	_check(
		rendered != controller.state,
		"render_state is a copy, so nothing can write back through it"
	)

	# [b]And it has to do that under EXTERNAL drive, which is the only one a
	# networked game uses.[/b] It used to refuse anything but LOCAL and return the raw
	# tick state, so every client of every game in this family drew its own player
	# quantised to the tick rate — 74 mm on six frames out of seven and 112 mm on the
	# seventh, at 60 frames against a 128-tick server. The cure was written, documented
	# and unreachable from the one deployment shape that needed it.
	#
	# Asserted with an explicit alpha rather than a frame-timed one: the fraction's
	# source is the host's business, the blend is this class's, and only the blend can
	# be checked without a clock.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller._previous_state.copy_from(controller.state)
	controller._previous_state.position = Vector3(0.0, 0.0, 0.0)
	controller.state.position = Vector3(0.0, 0.0, 10.0)

	var midpoint := controller.render_state(0.5)
	_check(
		midpoint.position.is_equal_approx(Vector3(0.0, 0.0, 5.0)),
		"render_state blends under EXTERNAL drive, which is what a netcode uses",
		str(midpoint.position)
	)
	_check(
		controller.render_state(0.0).position.is_equal_approx(Vector3.ZERO)
		and controller.render_state(1.0).position.is_equal_approx(Vector3(0.0, 0.0, 10.0)),
		"and reaches both ends of the tick it is drawn across"
	)

	# [b]A connected client draws at its clock's alpha, which leaves 0..1 after a slip.[/b]
	# The clock stretches its ticks while it settles, so a physics frame now and then runs
	# none or two, and drawn at the engine's fraction the eye stood still or moved double.
	# Past 1 the drawing goes on along the last step; below 0 it is between the two before.
	# Armed by clamping the clock's alpha to 0..1: this check fails (10 cm and 0 cm drawn).
	var clock := FakeClock.new()
	controller._position_two_back = Vector3(0.0, 0.0, -10.0)
	controller.render_clock = clock
	clock.alpha = 0.25
	var on_clock := controller.render_state()
	clock.alpha = 1.5
	var past := controller.render_state()
	clock.alpha = -0.5
	var before := controller.render_state()
	_check(
		on_clock.position.is_equal_approx(Vector3(0.0, 0.0, 2.5))
		and past.position.is_equal_approx(Vector3(0.0, 0.0, 15.0))
		and before.position.is_equal_approx(Vector3(0.0, 0.0, -5.0)),
		"a render_clock's alpha draws the eye, extrapolated past 1 and two ticks back below 0",
		"%s %s %s" % [on_clock.position, past.position, before.position]
	)
	controller._position_two_back = Vector3(NAN, NAN, NAN)
	_check(
		controller.render_state().position.is_equal_approx(Vector3.ZERO),
		"and with no tick two back, below 0 holds the previous tick",
		str(controller.render_state().position)
	)
	# A clock without render_alpha (an older dot-net) is the engine's fraction, 0..1.
	controller.render_clock = RefCounted.new()
	var engine := controller.render_state().position.z
	_check(
		engine >= 0.0 and engine <= 10.0,
		"a clock without render_alpha leaves the engine's fraction in charge",
		str(engine)
	)
	controller.render_clock = null

	# A remote player is written by the interpolator every frame and has no second
	# tick to blend from; blending would drag it back toward a state nothing updates.
	controller.drive = DotFpsController.Drive.REMOTE
	_check(
		controller.render_state(0.5).position.is_equal_approx(Vector3(0.0, 0.0, 10.0)),
		"but a REMOTE player is left exactly where the network put it"
	)
	controller.drive = DotFpsController.Drive.LOCAL

	# [b]The view is drawn from the sampler once a frame, not from the last tick.[/b] A
	# frame on which no tick ran used to draw the view where the last frame left it while
	# the mouse moved, and the next one turned double: one frame in nine at 144 Hz against
	# 128 ticks. `look_now` folds the pending motion in, and the command after it carries
	# exactly the same view, so the simulation never sees a different yaw.
	var looker := DotFpsSampler.new(DotFpsTunables.with_profile("legacy"))
	looker.tunables.mouse_sensitivity = 0.1
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(-50.0, 0.0)
	looker.handle_event(motion)
	var drawn := looker.look_now()
	_check(
		absf(drawn.x - 5.0 * looker.tunables.mouse_sensitivity_x) < 0.001,
		"look_now turns the view by the mouse motion of this frame, before any tick",
		"yaw %.3f" % drawn.x
	)
	_check(
		is_equal_approx(looker.sample(STEP).yaw, drawn.x) and is_equal_approx(looker.look_now().x, drawn.x),
		"and the next command carries that view, turned once and not twice"
	)

	# Zoomed, a mouse count turns the view by the lens's scale: a x0.3 scope turns 0.3 as far.
	var zoomed := DotFpsSampler.new(DotFpsTunables.with_profile("legacy"))
	zoomed.tunables.mouse_sensitivity = 0.1
	zoomed.look_scale = 0.3
	zoomed.handle_event(motion)
	_check(
		absf(zoomed.look_now().x - 5.0 * 0.3 * zoomed.tunables.mouse_sensitivity_x) < 0.001,
		"look_scale narrows mouse look by the zoom (x0.3 turns 1.5 degrees for 5)"
	)

	world.queue_free()
	await get_tree().process_frame
	_done()


## The wall-run roll: toward the open side, eased in and out with no snap, and nothing at 0.
## View only, so it is driven here straight from states; the motor's half is in
## movement_selftest.
func _test_wall_run_roll() -> void:
	_section("wall-run body pose")
	var bm := DotFpsViewMotion.new()
	var bs := DotFpsState.new()
	bs.mode = DotFpsState.Mode.AIR
	bs.velocity = Vector3(0.0, 0.0, -9.0)
	bs.wall_run_time = 0.1
	bs.wall_normal = Vector3.LEFT
	for _i in range(120):
		bm.advance(bs, 1.0 / 144.0)
	_check_near(bm.body_roll(), bm.wall_run_body_roll, 0.5,
		"a wall on the right rolls the body left (head away, feet to the wall)")
	_check_near(bm.body_yaw(), -bm.wall_run_body_yaw, 0.5, "and turns it toward the wall")
	bs.wall_normal = Vector3.RIGHT
	for _i in range(120):
		bm.advance(bs, 1.0 / 144.0)
	_check(bm.body_roll() < -1.0 and bm.body_yaw() > 1.0, "a wall on the left mirrors both")
	bs.wall_run_time = -1.0
	bs.wall_normal = Vector3.ZERO
	for _i in range(240):
		bm.advance(bs, 1.0 / 144.0)
	_check(absf(bm.body_roll()) < 0.1 and absf(bm.body_yaw()) < 0.1, "and both settle off the wall")
	bm.wall_run_body_roll = 0.0
	bm.wall_run_body_yaw = 0.0
	bs.wall_run_time = 0.1
	bs.wall_normal = Vector3.LEFT
	for _i in range(120):
		bm.advance(bs, 1.0 / 144.0)
	_check(absf(bm.body_roll()) < 0.01 and absf(bm.body_yaw()) < 0.01, "0 turns the body pose off")
	_done()

	_section("wall-run camera roll")

	var body := Node3D.new()
	add_child(body)
	var head := Node3D.new()
	body.add_child(head)
	var camera := Camera3D.new()
	head.add_child(camera)
	var view := DotFpsView.new()
	view.strafe_roll = 0.0
	view.slide_roll = 0.0
	body.add_child(view)

	var motor := DotFpsMotor.new(DotFpsTunables.with_profile("legacy"), DotFpsFlatBody.with_floor(0.0))
	var frame := 1.0 / 144.0

	var state := DotFpsState.new()
	state.mode = DotFpsState.Mode.AIR
	state.velocity = Vector3(0.0, 0.0, -9.0)

	var rolls: Array[float] = []
	# Idle, then a second on a wall to the right (its normal points left), then off it.
	for i in range(360):
		var running := i >= 30 and i < 174
		state.wall_run_time = 0.1 if running else -1.0
		state.wall_normal = Vector3.LEFT if running else Vector3.ZERO
		view.apply(state, motor, frame)
		rolls.append(rad_to_deg(camera.rotation.z))

	var worst_step := 0.0
	for i in range(1, rolls.size()):
		worst_step = maxf(worst_step, absf(rolls[i] - rolls[i - 1]))

	_check(absf(rolls[29]) < 0.001, "no roll before the run")
	_check_near(rolls[173], view.wall_run_roll, 0.2,
		"a wall on the right rolls the view left, away from it, by wall_run_roll")
	_check(worst_step < 0.4,
		"eased in and out: no frame turns it by more than a fraction of a degree",
		"worst %.3f degrees in one frame" % worst_step)
	_check(absf(rolls[359]) < 0.2, "and it settles back to level once the run ends",
		"%.3f degrees" % rolls[359])

	state.wall_run_time = 0.1
	state.wall_normal = Vector3.RIGHT
	for _i in range(200):
		view.apply(state, motor, frame)
	_check(rad_to_deg(camera.rotation.z) < -view.wall_run_roll + 0.2,
		"a wall on the left rolls it right",
		"%.3f degrees" % rad_to_deg(camera.rotation.z))

	view.wall_run_roll = 0.0
	view.snap()
	for _i in range(60):
		view.apply(state, motor, frame)
	_check(absf(camera.rotation.z) < 0.0001, "and wall_run_roll 0 turns it off")

	body.queue_free()
	_done()


## The landing dip, the strafe roll and the widening ([DotFpsViewMotion], which [DotFpsView]
## and a game writing its own camera share): each eases, none moves the view in one frame.
## Armed: the landing set the full dip on the landing frame before the spring (the first
## check fails at 89 mm), and a one-stage roll starts at its full rate (the fourth and fifth
## fail, 0.15 degrees in one frame).
func _test_view_motion() -> void:
	_section("camera motion: landing dip, strafe roll, widening")
	var frame := 1.0 / 144.0

	# A landing through the view, as DotFpsController wires it.
	var body := Node3D.new()
	add_child(body)
	var head := Node3D.new()
	body.add_child(head)
	var camera := Camera3D.new()
	head.add_child(camera)
	var view := DotFpsView.new()
	view.strafe_roll = 0.0
	view.slide_roll = 0.0
	view.fov_speed_gain = 0.0
	body.add_child(view)
	var motor := DotFpsMotor.new(DotFpsTunables.with_profile("legacy"), DotFpsFlatBody.with_floor(0.0))
	var state := DotFpsState.new()
	state.mode = DotFpsState.Mode.GROUND
	for _i in range(30):
		view.apply(state, motor, frame)
	var rest := head.position.y
	view.note_landing(view.landing_reference_speed)
	var ys: Array[float] = []
	for _i in range(144):
		view.apply(state, motor, frame)
		ys.append(head.position.y - rest)
	var deepest := 0.0
	var worst_step := absf(ys[0])
	for i in range(ys.size()):
		deepest = minf(deepest, ys[i])
		if i > 0:
			worst_step = maxf(worst_step, absf(ys[i] - ys[i - 1]))
	_check(absf(ys[0]) < view.landing_dip * 0.4,
		"a landing starts the dip, it does not set it: the first frame drops under 40% of it",
		"%.1f mm of %.1f" % [-ys[0] * 1000.0, view.landing_dip * 1000.0])
	_check_near(-deepest, view.landing_dip, view.landing_dip * 0.1,
		"a landing at the reference speed dips landing_dip at the deepest")
	_check(absf(ys[143]) < 0.002, "and the eye is back a second later", "%.2f mm" % (ys[143] * 1000.0))
	body.queue_free()

	# The strafe roll, eased in and out.
	var motion := DotFpsViewMotion.new()
	motion.slide_roll = 0.0
	motion.fov_speed_gain = 0.0
	var strafing := DotFpsState.new()
	strafing.mode = DotFpsState.Mode.GROUND
	var rolls: Array[float] = []
	for i in range(288):
		# A second strafing right at the reference speed, then still.
		strafing.velocity = (
			DotFpsMotor.forward_for(0.0).cross(Vector3.UP) * motion.strafe_roll_reference
			if i < 144 else Vector3.ZERO
		)
		motion.advance(strafing, frame)
		rolls.append(motion.roll())
	var steps: Array[float] = []
	for i in range(1, rolls.size()):
		steps.append(absf(rolls[i] - rolls[i - 1]))
	_check(absf(rolls[0]) < motion.strafe_roll * 0.02,
		"the strafe roll eases in: the first frame turns it under 2% of the way",
		"%.4f of %.2f degrees" % [rolls[0], motion.strafe_roll])
	_check(steps.max() < motion.strafe_roll * 0.04,
		"and no frame turns it more than 4% of the way",
		"worst %.4f degrees" % steps.max())
	_check_near(absf(rolls[143]), motion.strafe_roll, motion.strafe_roll * 0.05,
		"a strafe at the reference speed leans strafe_roll")
	_check(rolls[143] < 0.0, "into the strafe: right leans right (negative)")
	_check(absf(rolls[287]) < motion.strafe_roll * 0.05, "and eases back out")

	# Bounded, with the wall-run lean on top.
	motion.snap()
	motion.roll_limit = 7.0
	strafing.velocity = DotFpsMotor.forward_for(0.0).cross(Vector3.UP) * -40.0
	strafing.wall_run_time = 0.1
	strafing.wall_normal = Vector3.LEFT
	var widest := 0.0
	for _i in range(288):
		motion.advance(strafing, frame)
		widest = maxf(widest, absf(motion.roll()))
	_check(widest <= 7.0 + 1e-4 and widest > 6.9, "the strafe and wall-run rolls add, never past roll_limit",
		"%.3f degrees" % widest)

	# The widening: none under the floor, the gain at the reference, eased.
	var widening := DotFpsViewMotion.new()
	widening.strafe_roll = 0.0
	widening.fov_speed_gain = 5.0
	widening.fov_speed_floor = 9.0
	widening.fov_speed_reference = 15.0
	var running := DotFpsState.new()
	running.mode = DotFpsState.Mode.GROUND
	running.velocity = Vector3(0.0, 0.0, -9.0)
	for _i in range(144):
		widening.advance(running, frame)
	_check(absf(widening.fov_added()) < 1e-4, "no widening at or under fov_speed_floor")
	running.velocity = Vector3(0.0, 0.0, -15.0)
	widening.advance(running, frame)
	var first := widening.fov_added()
	for _i in range(287):
		widening.advance(running, frame)
	_check(first < 0.05 and absf(widening.fov_added() - 5.0) < 0.1,
		"the widening eases to fov_speed_gain at the reference speed",
		"first frame %.3f, after two seconds %.2f degrees" % [first, widening.fov_added()])

	# Each amount at 0 is off.
	var off := DotFpsViewMotion.new()
	off.strafe_roll = 0.0
	off.slide_roll = 0.0
	off.wall_run_roll = 0.0
	off.landing_dip = 0.0
	off.fov_speed_gain = 0.0
	off.slide_fov_gain = 0.0
	off.note_landing(30.0)
	strafing.slide_time = 0.1
	for _i in range(60):
		off.advance(strafing, frame)
	_check(off.roll() == 0.0 and off.eye_drop() == 0.0 and off.pitch() == 0.0 and off.fov_added() == 0.0,
		"every amount at 0 moves nothing", str(off.describe()))

	# DotFpsView forwards every field of the motion object. Read by reflection, so a field
	# added to DotFpsViewMotion later and not to the view fails here rather than leaving a
	# game on the view stuck at its default. Armed: without the five forwards 824a645 left
	# out, this names landing_min_speed, landing_pitch, roll_limit, fov_speed_floor and
	# wall_run_fov_gain.
	var forwarding := DotFpsView.new()
	var unforwarded := PackedStringArray()
	var fields := 0
	for property in DotFpsViewMotion.new().get_property_list():
		var field := String(property.name)
		if not (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or field.begins_with("_"):
			continue
		fields += 1
		if not field in forwarding:
			unforwarded.append(field + " (no export)")
			continue
		forwarding.set(field, float(forwarding.get(field)) + 0.25)
	forwarding._sync_motion()
	for property in forwarding._motion.get_property_list():
		var field := String(property.name)
		if (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) and not field.begins_with("_") \
				and field in forwarding and forwarding._motion.get(field) != forwarding.get(field):
			unforwarded.append(field)
	_check(fields >= 18 and unforwarded.is_empty(), "DotFpsView exports and forwards every DotFpsViewMotion field",
		"%d fields, not reaching the motion: %s" % [fields, ", ".join(unforwarded)])
	forwarding.free()

	# And one of them end to end: a landing under landing_min_speed dips nothing through the view.
	var floor_body := Node3D.new()
	add_child(floor_body)
	var floor_head := Node3D.new()
	floor_body.add_child(floor_head)
	floor_head.add_child(Camera3D.new())
	var floored := DotFpsView.new()
	floored.strafe_roll = 0.0
	floored.fov_speed_gain = 0.0
	floored.landing_min_speed = 12.0
	floor_body.add_child(floored)
	for _i in range(30):
		floored.apply(state, motor, frame)
	var floor_rest := floor_head.position.y
	floored.note_landing(10.0)
	var floor_deepest := 0.0
	for _i in range(72):
		floored.apply(state, motor, frame)
		floor_deepest = minf(floor_deepest, floor_head.position.y - floor_rest)
	_check(absf(floor_deepest) < 1e-5, "a landing under DotFpsView.landing_min_speed dips nothing",
		"%.2f mm" % (-floor_deepest * 1000.0))
	floor_body.queue_free()
	_done()


## Stands in for dot-net's DotNetClock: all `render_state` asks of a clock is `render_alpha`.
class FakeClock extends RefCounted:
	var alpha: float = 0.0

	func render_alpha() -> float:
		return alpha


func _wheel_event(pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_WHEEL_UP
	e.pressed = pressed
	return e


## A wheel tick on jump is one press of jump in the sampled command. The wheel arrives as a
## press and a release in one pair of events, so it is never "held" when a tick polls: armed
## by taking the latch and the poll out of DotFpsSampler.sample, four of the six fail.
func _test_wheel_jump() -> void:
	_section("a wheel tick is one jump")

	var had := InputMap.has_action(&"dot_fps_jump")
	var kept: Array = InputMap.action_get_events(&"dot_fps_jump") if had else []
	if not had:
		InputMap.add_action(&"dot_fps_jump")
	InputMap.action_erase_events(&"dot_fps_jump")
	InputMap.action_add_event(&"dot_fps_jump", _wheel_event(false))

	var s := DotFpsSampler.new(DotFpsTunables.with_profile("legacy"))
	s.handle_event(_wheel_event(true))
	s.handle_event(_wheel_event(false))
	var first := s.sample(STEP)
	var second := s.sample(STEP)
	_check(first.is_pressed(DotFpsCommand.BUTTON_JUMP), "a wheel tick forwarded to handle_event is jump in the next command")
	_check(not second.is_pressed(DotFpsCommand.BUTTON_JUMP), "and in that command only: a tick is a press, not a hold")

	# Two ticks between samples are one press; a tick, a gap and a tick are two press edges,
	# as the motor counts them (buttons & ~previous).
	var seq: Array[int] = []
	for n in [2, 0, 1]:
		for _i in range(n):
			s.handle_event(_wheel_event(true))
			s.handle_event(_wheel_event(false))
		seq.append(s.sample(STEP).buttons & DotFpsCommand.BUTTON_JUMP)
	var edges := 0
	var prev := 0
	for b in seq:
		edges += 1 if (b & ~prev) != 0 else 0
		prev = b
	_check(edges == 2 and seq[1] == 0, "scrolling is repeated presses, each its own edge", str(seq))

	s.handle_event(_wheel_event(true))
	s.suspended = true
	var _quiet := s.sample(STEP)
	s.suspended = false
	_check(not s.sample(STEP).is_pressed(DotFpsCommand.BUTTON_JUMP), "a press while suspended (a menu open) is dropped, not kept for later")

	# A client that forwards only mouse motion: the frame's just_pressed reaches the first
	# command of that physics frame, and only that one.
	var polled := DotFpsSampler.new(DotFpsTunables.with_profile("legacy"))
	Input.parse_input_event(_wheel_event(true))
	Input.parse_input_event(_wheel_event(false))
	await get_tree().physics_frame
	var p1 := polled.sample(STEP)
	var p2 := polled.sample(STEP)
	_check(p1.is_pressed(DotFpsCommand.BUTTON_JUMP) and not p2.is_pressed(DotFpsCommand.BUTTON_JUMP),
		"without the event, the first command of the frame still gets the press, the second does not",
		"%d %d" % [p1.buttons, p2.buttons])

	# The whole way: a LOCAL controller standing on the floor jumps on a wheel tick sent
	# through the engine's input, as a player's mouse would send it.
	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.LOCAL, func(c: DotFpsController) -> void: c.tick_rate = 60)
	await get_tree().physics_frame
	controller.teleport(Vector3(0.0, 0.05, 0.0))
	for _i in range(20):
		await get_tree().physics_frame
	var grounded := controller.state.mode == DotFpsState.Mode.GROUND and controller.state.velocity.y <= 0.001
	Input.parse_input_event(_wheel_event(true))
	Input.parse_input_event(_wheel_event(false))
	var rose := false
	for _i in range(10):
		await get_tree().physics_frame
		rose = rose or controller.state.velocity.y > 0.5
	_check(grounded and rose, "a standing player jumps on one wheel tick",
		"grounded %s, vy %.2f" % [grounded, controller.state.velocity.y])

	world.queue_free()
	InputMap.action_erase_events(&"dot_fps_jump")
	if had:
		for e in kept:
			InputMap.action_add_event(&"dot_fps_jump", e)
	else:
		InputMap.erase_action(&"dot_fps_jump")
	await get_tree().process_frame
	_done()


func _test_pair_exceptions() -> void:
	_section("players pass through the pairs the rules let through")

	var rules := DotPlayerBodyRules.new()
	var world := _make_world()
	var a := _make_player(world, DotFpsController.Drive.EXTERNAL)
	var b := _make_player(world, DotFpsController.Drive.EXTERNAL)
	var node_a := a.get_parent() as CharacterBody3D
	var node_b := b.get_parent() as CharacterBody3D
	var c := _make_player(world, DotFpsController.Drive.EXTERNAL)
	var node_c := c.get_parent() as CharacterBody3D
	await get_tree().physics_frame
	for pair in [[a, node_a, 1], [b, node_b, 2], [c, node_c, 3]]:
		var ctrl := pair[0] as DotFpsController
		var node := pair[1] as CharacterBody3D
		node.collision_layer = 1 << 4
		rules.apply_hull(node, ctrl.tunables.stand_height, ctrl.tunables.radius)
		rules.apply_to(ctrl, 1, 1 << 4)
	node_a.global_position = Vector3(0.0, 0.0, 0.0)
	node_b.global_position = Vector3(2.0, 0.0, 0.0)
	node_c.global_position = Vector3(-2.0, 0.0, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var h := a.tunables.stand_height
	var r := a.tunables.radius
	var from := Vector3(0.0, 0.9, 0.0)
	var entries := {
		1: {"controller": a, "body": node_a},
		2: {"controller": b, "body": node_b},
		3: {"controller": c, "body": node_c},
	}

	rules.apply_exceptions(entries)
	_check(a.body.sweep(from, Vector3(3.0, 0.0, 0.0), h, r).hit, "with no pair rule every hull stops its neighbour")

	# 1 and 2 are teammates, 3 an enemy of both.
	rules.pair_fn = func(x: Variant, y: Variant) -> bool: return int(x) == 3 or int(y) == 3
	rules.apply_exceptions(entries)
	_check(not a.body.sweep(from, Vector3(3.0, 0.0, 0.0), h, r).hit, "a teammate's hull is passed through")
	_check(not b.body.sweep(Vector3(2.0, 0.9, 0.0), Vector3(-3.0, 0.0, 0.0), h, r).hit
		or b.body.sweep(Vector3(2.0, 0.9, 0.0), Vector3(-3.0, 0.0, 0.0), h, r).fraction > 0.5,
		"both ways: the teammate passes through back, so nobody rubber-bands")
	_check(a.body.sweep(from, Vector3(-3.0, 0.0, 0.0), h, r).hit, "an enemy's hull still stops")

	rules.solid = false
	rules.apply_exceptions(entries)
	rules.solid = true
	rules.pair_fn = Callable()
	rules.apply_exceptions(entries)
	_check(a.body.sweep(from, Vector3(3.0, 0.0, 0.0), h, r).hit, "clearing the rule restores every stop")
	_check(a.body.exclude.has(node_a.get_rid()), "and the player's own collider stays excluded")

	world.queue_free()
	await get_tree().process_frame
	_done()


class LegSource extends Node:
	signal legs_broken(seconds: float, speed_scale: float)


func _test_landing_kick_and_legs() -> void:
	_section("landing kick strength (cl_landing_kick) and the leg slowdown modifier")
	var frame := 1.0 / 144.0
	var deepest: Array[float] = []
	for strength in [0.0, 1.0, 2.0]:
		var body := Node3D.new()
		add_child(body)
		var head := Node3D.new()
		body.add_child(head)
		var camera := Camera3D.new()
		head.add_child(camera)
		var view := DotFpsView.new()
		view.strafe_roll = 0.0
		view.slide_roll = 0.0
		view.fov_speed_gain = 0.0
		view.landing_strength = strength
		body.add_child(view)
		var motor := DotFpsMotor.new(DotFpsTunables.with_profile("legacy"), DotFpsFlatBody.with_floor(0.0))
		var state := DotFpsState.new()
		state.mode = DotFpsState.Mode.GROUND
		for _i in range(30):
			view.apply(state, motor, frame)
		var rest := head.position.y
		view.note_landing(10.0)
		var low := 0.0
		for _i in range(100):
			view.apply(state, motor, frame)
			low = minf(low, head.position.y - rest)
		deepest.append(-low)
		body.queue_free()
	_check(deepest[0] < 1e-5, "strength 0 dips nothing", str(deepest))
	_check(deepest[1] > 0.01, "strength 1 is the tuned dip", str(deepest))
	_check_near(deepest[2], deepest[1] * 2.0, deepest[1] * 0.1, "strength 2 doubles it")

	var rules := DotPlayerViewRules.new()
	_check(rules.landing_kick == 1.0, "cl_landing_kick defaults to 1")
	_check(rules.set_cvar("cl_landing_kick", "0.5") and rules.landing_kick == 0.5, "the cvar applies")
	_check(not rules.set_cvar("cl_landing_kick", "lots") and rules.landing_kick == 0.5, "a non-number is refused")
	var _r := rules.set_cvar("cl_landing_kick", "9")
	_check(rules.landing_kick == 2.0, "and is clamped to 2")

	var world := _make_world()
	var controller := _make_player(world, DotFpsController.Drive.EXTERNAL)
	await get_tree().physics_frame
	var src := LegSource.new()
	world.add_child(src)
	var legs := DotFpsLegSlow.new()
	legs.controller = DotNodeRef.of_path(controller.get_path())
	legs.source = DotNodeRef.of_path(src.get_path())
	legs.controller.mode = DotNodeRef.Mode.ABSOLUTE
	legs.source.mode = DotNodeRef.Mode.ABSOLUTE
	world.add_child(legs)
	_check(legs.attach() and not controller.has_modifier(&"legs_broken"), "attached, and nothing is slowed until the legs break")
	src.legs_broken.emit(3.0, 0.5)
	_check(controller.has_modifier(&"legs_broken") and legs.breaks == 1, "the signal adds the modifier")
	var def: DotFpsModifier = controller.motor.modifier_defs[&"legs_broken"]
	_check(def.duration_sec == 3.0 and is_equal_approx(def.max_speed_scale, 0.5), "with the signal's seconds and scale")
	_check(not legs.on_legs_broken(0.0, 0.5), "zero seconds does nothing")
	world.queue_free()
	_done()
