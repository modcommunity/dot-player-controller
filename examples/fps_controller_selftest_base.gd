extends Node

## Shared fixtures, counters and assertions for the controller self-test.

const STEP := 1.0 / 60.0


var _passed := 0


var _failed := 0


var _failures := PackedStringArray()


var _entered := 0


var _completed := 0


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


class LegSource extends Node:
	signal legs_broken(seconds: float, speed_scale: float)
