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

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-fps-controller controller self-test")
	print("")

	await _test_zero_configuration()
	await _test_external_drive()
	await _test_collider_follows_crouch()
	await _test_noclip_gate()
	await _test_teleport_and_signals()
	await _test_registry_and_describe()
	await _test_local_drive_accumulator()
	await _test_surfaces_from_scene()
	await _test_change_signals()
	await _test_command_veto()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

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
	print("surfaces from the scene")

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


func _test_change_signals() -> void:
	print("change signals")

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


func _test_command_veto() -> void:
	print("command veto and extension registration")

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
		controller.state.horizontal_speed() > 5.0,
		"and lifting the veto restores control",
		"%.2f m/s" % controller.state.horizontal_speed()
	)

	world.queue_free()
	await get_tree().process_frame


func _test_zero_configuration() -> void:
	print("zero-configuration wiring")

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


func _test_external_drive() -> void:
	print("external drive")

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

	world.queue_free()
	await get_tree().process_frame


func _test_collider_follows_crouch() -> void:
	print("collider follows the crouch")

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


func _test_noclip_gate() -> void:
	print("noclip gate")

	var world := _make_world()
	var controller := _make_player(
		world,
		DotFpsController.Drive.EXTERNAL,
		func(c: DotFpsController) -> void:
			c.tunables = DotFpsTunables.new()
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
			c.tunables = DotFpsTunables.new()
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


func _test_teleport_and_signals() -> void:
	print("teleport and signals")

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


func _test_registry_and_describe() -> void:
	print("registry and diagnostics")

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


func _test_local_drive_accumulator() -> void:
	print("local drive")

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

	world.queue_free()
	await get_tree().process_frame
