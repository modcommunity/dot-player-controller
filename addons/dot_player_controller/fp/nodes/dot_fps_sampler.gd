class_name DotFpsSampler
extends RefCounted

## Turns devices into a [DotFpsCommand]. The only part of the controller that reads
## the keyboard.
##
## [b]Separate from the motor on purpose.[/b] A server applying a command from the
## network, a replay, a bot and a demo playback all need commands and none of them
## have an input device. Keeping sampling out of the simulation is what makes all
## four possible, and it is what stops [code]Input.is_action_pressed[/code] from
## being called during a prediction replay — where it would return what the player is
## holding [i]now[/i] rather than what they held on the tick being replayed, and
## silently break reconciliation.
##
## Action names are configurable rather than fixed, because [code]class_name[/code]
## is global in Godot and so are input action names: a project that already has
## [code]move_forward[/code] should not have to add [code]player_f[/code] as well.
## [method register_default_actions] adds this addon's own set at runtime for a
## project that has none.

## Action names, keyed by role. Assign to remap without subclassing.
var actions: Dictionary = {
	"left": &"dot_fps_left",
	"right": &"dot_fps_right",
	"forward": &"dot_fps_forward",
	"back": &"dot_fps_back",
	"jump": &"dot_fps_jump",
	"crouch": &"dot_fps_crouch",
	"sprint": &"dot_fps_sprint",
	"walk": &"dot_fps_walk",
	"noclip": &"dot_fps_noclip",
	# Optional. Bound to a stick, these turn the view at a rate; unbound, they cost
	# a dictionary lookup and nothing else.
	"look_left": &"dot_fps_look_left",
	"look_right": &"dot_fps_look_right",
	"look_up": &"dot_fps_look_up",
	"look_down": &"dot_fps_look_down",
}

## Degrees per second at full deflection for the analogue look actions.
##
## A rate, not a delta: a stick held over is a continuous input, so the view should
## turn at a speed. Treating it like mouse motion makes the turn rate depend on the
## frame rate.
var look_rate: float = 180.0

var tunables: DotFpsTunables

## Current view angles in degrees. Accumulated from mouse motion.
var yaw: float = 0.0
var pitch: float = 0.0

## Ignore devices and emit neutral commands.
##
## For a chat box or a menu: the player should stop moving, not keep running because
## the key was down when the overlay opened.
var suspended: bool = false

## Mouse motion accumulated since the last [method sample], in pixels.
##
## Accumulated rather than applied immediately because mouse events arrive at the
## device's rate — often several hundred hertz — and applying each one directly makes
## the view a function of how many events happened to land in a frame.
var _mouse_delta: Vector2 = Vector2.ZERO

## Buttons from the previous sample, for edge detection outside the motor.
var _previous_buttons: int = 0


func _init(p_tunables: DotFpsTunables) -> void:
	tunables = p_tunables


## Feeds a mouse-motion event. Call from [method Node._input].
func handle_event(event: InputEvent) -> void:
	if suspended:
		return

	if event is InputEventMouseMotion:
		_mouse_delta += (event as InputEventMouseMotion).relative


## Builds the command for this tick and clears the accumulated mouse motion.
##
## [b]Call this once per simulated tick, not once per frame.[/b] Called per frame at
## a rate above the tick rate, the mouse motion between two ticks is split across
## several commands of which only the last is used, and the view lags the mouse by a
## fraction that changes with the frame rate.
func sample(delta: float = 0.0) -> DotFpsCommand:
	var command := DotFpsCommand.new()

	if suspended:
		command.yaw = yaw
		command.pitch = pitch
		_previous_buttons = 0
		return command

	_apply_mouse()
	_apply_analogue_look(delta)

	command.yaw = yaw
	command.pitch = pitch

	var move := Vector2.ZERO
	move.x = _strength("right") - _strength("left")
	move.y = _strength("forward") - _strength("back")

	# Clamped rather than normalised: normalising would make a half-pressed analogue
	# stick behave like a full one, and clamping only bites on the diagonal, which is
	# where the extra √2 of speed would otherwise come from.
	command.move = move.limit_length(1.0)

	command.set_button(DotFpsCommand.BUTTON_JUMP, _pressed("jump"))
	command.set_button(DotFpsCommand.BUTTON_CROUCH, _pressed("crouch"))
	command.set_button(DotFpsCommand.BUTTON_SPRINT, _pressed("sprint"))
	command.set_button(DotFpsCommand.BUTTON_WALK, _pressed("walk"))
	command.set_button(DotFpsCommand.BUTTON_NOCLIP, _pressed("noclip"))

	_previous_buttons = command.buttons
	return command


## Turns the view from the analogue look actions, if a project binds them.
##
## [param delta] is the tick duration. Zero disables it, which is what a caller that
## has only a mouse passes.
func _apply_analogue_look(delta: float) -> void:
	if delta <= 0.0:
		return

	var horizontal := _strength("look_right") - _strength("look_left")
	var vertical := _strength("look_down") - _strength("look_up")

	if horizontal == 0.0 and vertical == 0.0:
		return

	yaw -= horizontal * look_rate * delta

	var pitch_delta := vertical * look_rate * delta
	pitch += pitch_delta if tunables.invert_look_y else -pitch_delta

	yaw = wrapf(yaw, -180.0, 180.0)
	pitch = clampf(pitch, tunables.pitch_min, tunables.pitch_max)


func _apply_mouse() -> void:
	if _mouse_delta == Vector2.ZERO:
		return

	var sensitivity := tunables.mouse_sensitivity

	yaw -= _mouse_delta.x * sensitivity * tunables.mouse_sensitivity_x

	var vertical := _mouse_delta.y * sensitivity * tunables.mouse_sensitivity_y
	pitch += vertical if tunables.invert_look_y else -vertical

	yaw = wrapf(yaw, -180.0, 180.0)
	pitch = clampf(pitch, tunables.pitch_min, tunables.pitch_max)

	_mouse_delta = Vector2.ZERO


func _pressed(role: String) -> bool:
	var action: StringName = actions.get(role, &"")
	if action == &"" or not InputMap.has_action(action):
		return false
	return Input.is_action_pressed(action)


func _strength(role: String) -> float:
	var action: StringName = actions.get(role, &"")
	if action == &"" or not InputMap.has_action(action):
		return 0.0
	return Input.get_action_strength(action)


## Points the view somewhere without a mouse event. For spawning and teleports.
func look_at_angles(p_yaw: float, p_pitch: float) -> void:
	yaw = wrapf(p_yaw, -180.0, 180.0)
	pitch = clampf(p_pitch, tunables.pitch_min, tunables.pitch_max)
	_mouse_delta = Vector2.ZERO


## Which of this addon's actions the project is missing.
##
## Worth calling at startup: a missing action is not an error in Godot, it is silence,
## and the symptom is a controller that runs perfectly and does not move.
func missing_actions() -> PackedStringArray:
	var out := PackedStringArray()
	for role in actions:
		var action: StringName = actions[role]
		if action != &"" and not InputMap.has_action(action):
			out.append(String(action))
	return out


## Registers this addon's default bindings for any action the project lacks.
##
## WASD, space, ctrl, shift, alt, and V for noclip. Added at runtime rather than
## shipped in a [code]project.godot[/code], because an addon cannot merge input maps
## into a host project and a game that has its own bindings should keep them —
## existing actions are never touched.
static func register_default_actions(sampler: DotFpsSampler = null) -> PackedStringArray:
	var defaults := {
		"left": KEY_A,
		"right": KEY_D,
		"forward": KEY_W,
		"back": KEY_S,
		"jump": KEY_SPACE,
		"crouch": KEY_CTRL,
		"sprint": KEY_SHIFT,
		"walk": KEY_ALT,
		"noclip": KEY_V,
	}

	var names := {
		"left": &"dot_fps_left",
		"right": &"dot_fps_right",
		"forward": &"dot_fps_forward",
		"back": &"dot_fps_back",
		"jump": &"dot_fps_jump",
		"crouch": &"dot_fps_crouch",
		"sprint": &"dot_fps_sprint",
		"walk": &"dot_fps_walk",
		"noclip": &"dot_fps_noclip",
	}

	if sampler != null:
		names = sampler.actions

	var added := PackedStringArray()

	for role in defaults:
		var action: StringName = names.get(role, &"")
		if action == &"" or InputMap.has_action(action):
			continue

		InputMap.add_action(action)

		var event := InputEventKey.new()
		event.physical_keycode = defaults[role]
		InputMap.action_add_event(action, event)

		added.append(String(action))

	if not added.is_empty():
		DotLog.debug(
			"fps.input",
			"registered default input actions",
			{"actions": ", ".join(added)}
		)

	return added


func describe() -> Dictionary:
	return {
		"yaw": "%.1f" % yaw,
		"pitch": "%.1f" % pitch,
		"suspended": suspended,
		"missing_actions": Array(missing_actions()),
	}
