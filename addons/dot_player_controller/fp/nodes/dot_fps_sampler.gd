class_name DotFpsSampler
extends RefCounted

## Turns devices into a [DotFpsCommand]. The only part of the controller that reads the keyboard.
## Separate from the motor so a server, replay, bot or demo can produce commands without a device, and so [code]Input.is_action_pressed[/code] is never called during a prediction replay.
## Action names are configurable because input action names are global; [method register_default_actions] adds this addon's set for a project that has none.

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
## A rate, not a delta: treating a held stick like mouse motion would make the turn rate depend on frame rate.
var look_rate: float = 180.0

var tunables: DotFpsTunables

## Current view angles in degrees. Accumulated from mouse motion.
var yaw: float = 0.0
var pitch: float = 0.0

## Ignore devices and emit neutral commands, for a chat box or menu.
var suspended: bool = false

## Multiplies mouse look: a game sets it to the lens's field-of-view scale while zoomed, so a scope turns the view as far per mouse count as the hip does per pixel. 1 at the hip.
var look_scale: float = 1.0

## Mouse motion accumulated since the last [method sample], in pixels.
## Accumulated because events arrive at the device's rate, which would make the view depend on events per frame.
var _mouse_delta: Vector2 = Vector2.ZERO

## Buttons from the previous sample, for edge detection outside the motor.
var _previous_buttons: int = 0

## Button presses seen since the last [method sample], as [constant DotFpsCommand] bits.
## A latch because a wheel tick is a press and release in one event pair, so `is_action_pressed` is never true for it at a tick; each press reaches exactly one command.
var _latched: int = 0

## The frame [method sample] last polled `is_action_just_pressed` on, so a frame that runs
## several ticks gives a press to the first of them only.
var _polled_frame: int = -1

## Sprint toggle state: the latch, and whether the key was down at the last sample.
var _sprint_on: bool = false
var _sprint_raw: bool = false

## Roles whose presses are latched, and their command bits.
const _BUTTON_ROLES := {
	"jump": DotFpsCommand.BUTTON_JUMP,
	"crouch": DotFpsCommand.BUTTON_CROUCH,
	"sprint": DotFpsCommand.BUTTON_SPRINT,
	"walk": DotFpsCommand.BUTTON_WALK,
	"noclip": DotFpsCommand.BUTTON_NOCLIP,
}


func _init(p_tunables: DotFpsTunables) -> void:
	tunables = p_tunables


## Feeds an input event. Call from [method Node._input] with every event, not only mouse motion: a button press is latched until the next [method sample], which is how a wheel tick bound to jump reaches a command.
func handle_event(event: InputEvent) -> void:
	if suspended:
		return

	if event is InputEventMouseMotion:
		_mouse_delta += (event as InputEventMouseMotion).relative
		return

	if not event.is_pressed() or event.is_echo():
		return
	for role in _BUTTON_ROLES:
		var action: StringName = actions.get(role, &"")
		if action != &"" and InputMap.has_action(action) and event.is_action_pressed(action):
			_latched |= int(_BUTTON_ROLES[role])


## Builds the command for this tick and clears the accumulated mouse motion.
## Call once per simulated tick, not per frame, or the view lags the mouse by a frame-rate-dependent fraction.
func sample(delta: float = 0.0) -> DotFpsCommand:
	var command := DotFpsCommand.new()

	if suspended:
		command.yaw = yaw
		command.pitch = pitch
		_previous_buttons = 0
		_latched = 0
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

	# Held, or latched since the last sample, or pressed this frame where the event was not forwarded (the poll).
	# The poll is once per frame, so a multi-tick frame gives the press to the first tick only.
	var frame := Engine.get_physics_frames() if Engine.is_in_physics_frame() else -1 - Engine.get_process_frames()
	var poll := frame != _polled_frame
	_polled_frame = frame
	for role in _BUTTON_ROLES:
		var bit := int(_BUTTON_ROLES[role])
		command.set_button(bit, _pressed(role) or (_latched & bit) != 0 or (poll and _just_pressed(role)))
	_latched = 0
	_apply_sprint_toggle(command, move)

	_previous_buttons = command.buttons
	return command


## With [member DotFpsTunables.sprint_toggle], turns the sprint key's presses into a latch that standing still clears.
func _apply_sprint_toggle(command: DotFpsCommand, move: Vector2) -> void:
	if not tunables.sprint_toggle:
		_sprint_on = false
		_sprint_raw = false
		return
	var raw := command.is_pressed(DotFpsCommand.BUTTON_SPRINT)
	if raw and not _sprint_raw:
		_sprint_on = not _sprint_on
	_sprint_raw = raw
	if move == Vector2.ZERO:
		_sprint_on = false
	command.set_button(DotFpsCommand.BUTTON_SPRINT, _sprint_on)


## Turns the view from the analogue look actions, if bound. A [param delta] of zero disables it.
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

	var sensitivity := tunables.mouse_sensitivity * (clampf(look_scale, 0.01, 1.0) if is_finite(look_scale) else 1.0)

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


func _just_pressed(role: String) -> bool:
	var action: StringName = actions.get(role, &"")
	if action == &"" or not InputMap.has_action(action):
		return false
	return Input.is_action_just_pressed(action)


func _strength(role: String) -> float:
	var action: StringName = actions.get(role, &"")
	if action == &"" or not InputMap.has_action(action):
		return 0.0
	return Input.get_action_strength(action)


## Folds the mouse motion that has arrived since the last [method sample] into [member yaw] and [member pitch] now, and returns them as (yaw, pitch) in degrees.
## For drawing the view once per frame: with the display faster than the tick rate some frames run no tick, so the camera froze and then doubled (96 of 864 frames each at 144 Hz).
## The commands do not change: the angles are cumulative, so the next [method sample] carries this motion exactly as before. Suspended, it folds nothing.
func look_now() -> Vector2:
	if not suspended:
		_apply_mouse()
	return Vector2(yaw, pitch)


## Points the view somewhere without a mouse event. For spawning and teleports.
func look_at_angles(p_yaw: float, p_pitch: float) -> void:
	yaw = wrapf(p_yaw, -180.0, 180.0)
	pitch = clampf(p_pitch, tunables.pitch_min, tunables.pitch_max)
	_mouse_delta = Vector2.ZERO


## Which of this addon's actions the project is missing.
## Call at startup: a missing action is silence in Godot, and the symptom is a controller that does not move.
func missing_actions() -> PackedStringArray:
	var out := PackedStringArray()
	for role in actions:
		var action: StringName = actions[role]
		if action != &"" and not InputMap.has_action(action):
			out.append(String(action))
	return out


## Registers this addon's default bindings for any action the project lacks: WASD, space, ctrl, shift, alt, V for noclip.
## Added at runtime because an addon cannot merge input maps into a host project; existing actions are never touched.
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
