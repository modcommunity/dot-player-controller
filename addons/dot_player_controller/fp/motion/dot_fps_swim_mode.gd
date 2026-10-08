class_name DotFpsSwimMode
extends DotFpsMoveMode

## Swimming: a player in water moves where they look, rises with jump, dives with crouch,
## floats to the surface with their head out when they let go, and climbs out at an edge
## with a jump.
##
## [b]Water is data, not an area.[/b] [member volumes] is a list of axis-aligned boxes the
## game hands over (from its map), and every question is a containment test against it:
## an `Area3D`'s overlap signals arrive after the physics step, on the main loop, and a
## client replaying ten ticks of prediction cannot ask an area where it WAS. A box list can
## be asked anything, any number of times, and gives both ends the same answer.
##
## [b]Entering is the game's call, once a tick[/b] ([method update]), and leaving is this
## mode's own: the moment the waist is out of every volume it hands the player to AIR. Both
## read only [member volumes] and the state, so a replay enters and leaves on the same ticks.
##
## [codeblock]
## var swim := DotFpsSwimMode.new()
## swim.volumes = map.water_boxes()
## swim_id = controller.motor.register_mode(swim)
## # every tick, after the move:
## swim.update(controller.motor, controller.state)
## [/codeblock]

## The liquid boxes, world space.
var volumes: Array[AABB] = []

## Top swimming speed, m/s. Slower than running, as water is.
var swim_speed: float = 4.0

## How fast the velocity eases toward what the player asks for, per second.
var accelerate: float = 3.5

## Height above the feet that counts as "in the water": the waist. A player wading in water
## shallower than this is walking, with the ground's own movement.
var waist: float = 1.0

## Height above the feet the head floats at, relative to the surface, when nobody presses
## anything: a little out, so a player who lets go breathes rather than sinks.
var float_depth: float = 1.35

## Upward speed a jump at the surface gives, to climb out over an edge.
var exit_speed: float = 5.0

## How close to the surface the waist must be for that jump to count, metres.
var exit_reach: float = 0.5


func _name() -> StringName:
	return &"swim"


func _uses_crouch() -> bool:
	return false


## The surface height of the volume containing [param point], or NAN if it is in none.
func surface_at(point: Vector3) -> float:
	for box in volumes:
		if box.has_point(point):
			return box.end.y
	return NAN


## Whether a player whose feet are at [param feet] is in the water.
func is_in(feet: Vector3) -> bool:
	return not is_nan(surface_at(feet + Vector3.UP * waist))


## The game's once-a-tick call: puts a player whose waist is in the water into this mode.
## Leaving is handled by [method _simulate]. Noclip is left alone.
func update(motor: DotFpsMotor, state: DotFpsState) -> void:
	if mode_id < 0 or state.mode == mode_id or state.mode == DotFpsState.Mode.NOCLIP:
		return
	if is_in(state.position):
		motor.set_mode(state, mode_id)


func _simulate(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float,
	motor: DotFpsMotor
) -> void:
	var surface := surface_at(state.position + Vector3.UP * waist)

	if is_nan(surface):
		# Out: falling or standing, the motor's own modes decide which on the next tick.
		motor.set_mode(state, DotFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	var basis := DotFpsMotor._view_basis(state.yaw, state.pitch)
	var wish := (basis.right * command.move.x + basis.forward * command.move.y).limit_length(1.0) * swim_speed
	var vertical := 0.0
	if command.is_pressed(DotFpsCommand.BUTTON_JUMP):
		vertical += 1.0
	if command.is_pressed(DotFpsCommand.BUTTON_CROUCH):
		vertical -= 1.0

	if vertical != 0.0:
		wish.y += vertical * swim_speed
	elif command.move == Vector2.ZERO:
		# Nothing pressed: drift to floating, head a little out of the water.
		var floating := surface - float_depth
		wish.y = clampf((floating - state.position.y) * 2.0, -swim_speed * 0.5, swim_speed * 0.5)

	var t := clampf(accelerate * delta, 0.0, 1.0)
	state.velocity = state.velocity.lerp(wish, t)

	# At the surface, a jump is a climb out: enough to get a foot over an edge beside you.
	if vertical > 0.0 and surface - (state.position.y + waist) < exit_reach:
		state.velocity.y = maxf(state.velocity.y, exit_speed)

	motor.move_and_slide(state, delta)


func describe() -> Dictionary:
	var out := super.describe()
	out["volumes"] = volumes.size()
	out["swim_speed"] = swim_speed
	return out
