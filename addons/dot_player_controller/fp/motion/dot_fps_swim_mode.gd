class_name DotFpsSwimMode
extends DotFpsMoveMode

## Swimming: move where you look, jump rises, crouch dives, let go to float with the head out, jump at an edge to climb out.
## Water is data, not an area: [member volumes] is a box list the game supplies, so a replay can ask where a player WAS.
## The game calls [method update] once a tick to enter; leaving is this mode's own. Usage: docs/rationale.md.

## The liquid boxes, world space.
var volumes: Array[AABB] = []

## Top swimming speed, m/s. Slower than running, as water is.
var swim_speed: float = 3.81

## How fast the velocity eases toward what the player asks for, per second.
var accelerate: float = 10.0

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

## Downward m/s for a player who presses nothing. 0 drifts them to [member float_depth], head out;
## above 0 they sink at this speed instead (a pit of water is climbed out of by holding jump).
var idle_sink_speed: float = 0.0

## Drag on the swimmer's speed, per second (0 off, 1 the classic profile and the default): the
## velocity loses speed * friction * delta before it eases to the wish.
var friction: float = 1.0

## cvar name -> [member, description]; the values are the classic profile's own units.
const CVARS := {
	"sv_wateraccelerate": ["accelerate", "Water acceleration, per second toward the wish"],
	"sv_waterfriction": ["friction", "Water friction; 0 off, 1 classic"],
}


## Applies one water cvar by name. False for an unknown name or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	if not CVARS.has(cvar_name) or not value.strip_edges().is_valid_float():
		return false
	set(CVARS[cvar_name][0], maxf(0.0, value.strip_edges().to_float()))
	return true


## One entry per water cvar: name, value, description, member.
func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cvar_name in CVARS:
		var entry: Array = CVARS[cvar_name]
		out.append({"name": cvar_name, "value": get(entry[0]), "description": entry[1], "member": entry[0]})
	return out


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
	if is_in(state.position) and has_room_to_float(motor, state):
		motor.set_mode(state, mode_id)


## Whether the water under [param state] is deep enough to float in: false when the bed
## is above where a floating swimmer's feet would hang ([member float_depth] under the
## surface). Water that shallow is waded; a swimmer held there is pressed into the bed.
func has_room_to_float(motor: DotFpsMotor, state: DotFpsState) -> bool:
	var surface := surface_at(state.position + Vector3.UP * waist)
	if is_nan(surface):
		return false
	var drop := state.position.y - (surface - float_depth)
	if drop <= 0.0:
		return true
	return not motor.probe(state, state.position, Vector3.DOWN * drop).hit


func _simulate(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float,
	motor: DotFpsMotor
) -> void:
	var surface := surface_at(state.position + Vector3.UP * waist)

	if is_nan(surface) or not has_room_to_float(motor, state):
		# Out, or standing in water too shallow to float: the motor's own modes decide next tick.
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
	elif command.move == Vector2.ZERO and idle_sink_speed > 0.0:
		wish.y = -idle_sink_speed
	elif command.move == Vector2.ZERO:
		# Nothing pressed: drift to floating, head a little out of the water.
		var floating := surface - float_depth
		wish.y = clampf((floating - state.position.y) * 2.0, -swim_speed * 0.5, swim_speed * 0.5)

	if friction > 0.0:
		state.velocity *= maxf(0.0, 1.0 - friction * delta)
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
	out["idle_sink_speed"] = idle_sink_speed
	return out
