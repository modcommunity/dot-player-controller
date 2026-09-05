@tool
class_name DotFpsView
extends Node

## Everything the player sees, and nothing the simulation depends on.
##
## [b]The split this node exists to enforce.[/b] Simulation runs at a fixed tick rate
## and must be identical on every machine; rendering runs at whatever the display
## does and may differ freely. Anything cosmetic that leaked into [DotFpsMotor] would
## become part of the netcode contract — a client with view bob disabled would
## simulate differently from the server. So the camera height, the pitch, the
## field of view and the smoothing all live here, are driven [i]from[/i] the state,
## and never write back to it.
##
## That is also why this node runs in [method Node._process] rather than
## [method Node._physics_process]: interpolating the eye position between ticks is
## the entire point, and doing it on the tick would quantise the view to the tick
## rate and undo it.

const CHANNEL := "fps.view"

@export_group("Wiring")

## The node yaw rotates. Usually the player body, so the avatar turns with the view.
##
## [b]Rotating the body rather than the camera is a deliberate change from the
## previous controller[/b], which put both angles on the camera. That works for a
## single-player first-person game and nothing else: the body never turned, so a
## third-person view, a shadow, a visible avatar and anything on the server that
## cared which way a player faced were all wrong.
@export var body_ref: DotNodeRef = null

## The node that carries the eye. Moved vertically for crouching.
@export var head_ref: DotNodeRef = null

## The camera. Pitch is applied here.
@export var camera_ref: DotNodeRef = null

@export_group("Camera")

## Field of view when standing still, in degrees.
@export_range(30.0, 140.0, 0.5) var base_fov: float = 90.0

## Extra degrees of field of view at [member fov_speed_reference].
##
## A speed cue, and a cheap one: the periphery moving faster than the centre is most
## of what makes fast movement feel fast. Zero disables it.
@export_range(0.0, 60.0, 0.5) var fov_speed_gain: float = 15.0

## Horizontal speed at which the full [member fov_speed_gain] is applied, in m/s.
@export_range(1.0, 100.0, 0.5) var fov_speed_reference: float = 18.0

## How quickly the field of view follows speed, per second.
@export_range(0.5, 40.0, 0.5) var fov_response: float = 6.0

@export_group("Feel")

## How far the camera leans into a turn or a strafe, in degrees. 0 disables it.
##
## The cue that makes strafing read as movement rather than as the world sliding.
## Small: past about four degrees it reads as a tilted horizon.
@export_range(0.0, 12.0, 0.1) var strafe_roll: float = 1.6

## Lateral speed at which the full [member strafe_roll] is reached, in m/s.
@export_range(1.0, 40.0, 0.5) var strafe_roll_reference: float = 8.0

## How quickly the roll follows, per second.
@export_range(0.5, 40.0, 0.5) var strafe_roll_response: float = 7.0

## How far the view dips on landing, in metres, at [member landing_reference_speed].
##
## Scaled by impact and decayed, so stepping off a kerb is a twitch and a long fall
## is a lurch — the same event carrying its own weight rather than one canned
## animation for both.
@export_range(0.0, 0.5, 0.005) var landing_dip: float = 0.09

## Downward speed producing the full [member landing_dip], in m/s.
@export_range(1.0, 60.0, 0.5) var landing_reference_speed: float = 16.0

## Seconds the landing dip takes to recover.
@export_range(0.0, 1.0, 0.01) var landing_recovery: float = 0.28

## Vertical camera travel of the walk cycle, in metres. 0 disables the bob.
##
## Off by default. Head bob is divisive and a competitive game usually wants none;
## it is here so a game that wants it does not implement it against the wrong data.
@export_range(0.0, 0.15, 0.001) var bob_amount: float = 0.0

## Horizontal sway, as a fraction of [member bob_amount].
@export_range(0.0, 2.0, 0.05) var bob_sway: float = 0.5

## Bob cycles per metre travelled.
##
## Distance-based, not time-based: a bob driven by a timer keeps bobbing while the
## player stands still and runs at the wrong rate when they walk.
@export_range(0.1, 5.0, 0.05) var bob_cycles_per_metre: float = 0.55

@export_group("Smoothing")

## How quickly the eye follows the simulated eye height, per second.
##
## Cosmetic only. The collider resizes at the rate the tunables specify; this is the
## camera catching up, so a crouch does not snap the view.
@export_range(1.0, 60.0, 0.5) var eye_response: float = 18.0

## Smooth the eye's vertical position when the simulation steps the player up stairs.
##
## Without it, every stair tread moves the camera up by the tread height in one
## frame, which is the staircase stutter familiar from a hand-rolled controller. The
## step still happens instantly in the simulation; only the view lags.
@export var smooth_step_up: bool = true

## Seconds over which a step-up is absorbed.
@export_range(0.0, 0.5, 0.005) var step_smooth_time: float = 0.1

## Extra offset added to the eye, in metres.
##
## Where a prediction correction goes. A [DotFpsController] under dot-net feeds the
## predictor's decaying offset in here, so the view eases toward the corrected
## position while the simulation is already using it.
var external_offset: Vector3 = Vector3.ZERO

var _body: Node3D = null
var _head: Node3D = null
var _camera: Camera3D = null

var _eye_height: float = 0.0
var _step_offset: float = 0.0
var _fov: float = 0.0
var _ready_ok: bool = false

var _roll: float = 0.0
var _landing_dip: float = 0.0
var _landing_pitch: float = 0.0
var _bob_phase: float = 0.0
var _bob_offset: Vector3 = Vector3.ZERO
var _bob_pitch: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_fov = base_fov
	_resolve()


func _resolve() -> void:
	if body_ref == null:
		body_ref = DotNodeRef.new()
		body_ref.mode = DotNodeRef.Mode.PARENT

	_body = body_ref.resolve_or_null(self, CHANNEL) as Node3D

	if camera_ref != null:
		_camera = camera_ref.resolve_or_null(self, CHANNEL) as Camera3D
	elif _body != null:
		# Unwired: find the one camera under the body. A first-person player has
		# exactly one, and making the conventional layout work with no configuration
		# costs nothing — an explicit ref still overrides it.
		var found := DotNodeRef.new()
		found.mode = DotNodeRef.Mode.DESCENDANT_OF_TYPE
		found.type_name = &"Camera3D"
		found.on_missing = DotNodeRef.OnMissing.NULL
		_camera = found.resolve_or_null(_body, CHANNEL) as Camera3D

	if head_ref != null:
		_head = head_ref.resolve_or_null(self, CHANNEL) as Node3D
	elif _camera != null:
		# The camera's parent, when that is a node between the camera and the body —
		# the "Head" of the conventional layout. A camera parented straight to the
		# body has no head, and the camera then carries the eye height itself.
		var parent := _camera.get_parent()
		if parent is Node3D and parent != _body:
			_head = parent as Node3D

	# The head is optional — a game may pitch the camera directly — but without a
	# camera there is nothing here to do, and saying so at boot beats a first-person
	# game that renders from the origin.
	if _camera == null:
		DotLog.warn(CHANNEL, "no camera resolved; the view will do nothing")

	_ready_ok = _camera != null


## Applies a simulated state to the visible nodes.
##
## [param state] is the render state — interpolated between ticks by the controller,
## not the raw tick state — and [param delta] is the frame time.
func apply(
	state: DotFpsState,
	motor: DotFpsMotor,
	delta: float
) -> void:
	if not _ready_ok or state == null or motor == null:
		return

	if _body != null:
		# Yaw only — pitching the body would tilt the collider with it — and set in
		# world space, because the controller writes the simulated position to
		# global_position. Using the local rotation here made the two disagree the
		# moment a player was parented under anything rotated: the body would move to
		# the right place and face the wrong way.
		_body.global_basis = Basis(Vector3.UP, deg_to_rad(state.yaw))

	var target_eye := motor.eye_position(state).y - state.position.y

	if _eye_height <= 0.0:
		_eye_height = target_eye

	# Exponential smoothing framed as a per-second rate, so the result does not
	# change with the frame rate — a plain lerp by `response * delta` converges
	# faster at 144 Hz than at 60, which makes a crouch feel different per machine.
	var t := 1.0 - exp(-eye_response * delta)
	_eye_height = lerpf(_eye_height, target_eye, t)

	if smooth_step_up and step_smooth_time > 0.0:
		_step_offset = move_toward(
			_step_offset, 0.0, (1.0 / step_smooth_time) * delta
		)
	else:
		_step_offset = 0.0

	_advance_bob(state, delta)

	var eye := _eye_height - _step_offset + _landing_dip + _bob_offset.y
	# The vertical component was being dropped, so a prediction correction that was
	# mostly vertical — landing, a step, a lift — was applied to two axes out of
	# three and the camera drifted away from the entity it belongs to.
	eye += external_offset.y

	if _head != null:
		_head.position = Vector3(
			external_offset.x + _bob_offset.x,
			eye,
			external_offset.z
		)
	else:
		# No head node: the camera carries the eye height itself.
		_camera.position = Vector3(_bob_offset.x, eye, 0.0)

	_camera.rotation = Vector3(
		deg_to_rad(state.pitch + _landing_pitch + _bob_pitch),
		0.0,
		deg_to_rad(_roll)
	)

	_apply_roll(state, delta)
	_apply_fov(state, delta)


## Leans the camera into lateral motion.
##
## Measured against the view's own right vector rather than against world axes, so
## the roll follows where the player is looking and not where the level was built.
func _apply_roll(state: DotFpsState, delta: float) -> void:
	if strafe_roll <= 0.0:
		_roll = 0.0
		return

	var right := DotFpsMotor.forward_for(state.yaw).cross(Vector3.UP)
	var lateral := state.velocity.dot(right)

	var target := -clampf(
		lateral / strafe_roll_reference, -1.0, 1.0
	) * strafe_roll

	var t := 1.0 - exp(-strafe_roll_response * delta)
	_roll = lerpf(_roll, target, t)


## Advances the walk cycle by distance travelled and writes the bob offsets.
func _advance_bob(state: DotFpsState, delta: float) -> void:
	if landing_recovery > 0.0 and _landing_dip != 0.0:
		var recovery := (1.0 / landing_recovery) * delta
		_landing_dip = move_toward(_landing_dip, 0.0, landing_dip * recovery)
		_landing_pitch = move_toward(_landing_pitch, 0.0, 6.0 * recovery)
	else:
		_landing_dip = 0.0
		_landing_pitch = 0.0

	if bob_amount <= 0.0:
		_bob_offset = Vector3.ZERO
		_bob_pitch = 0.0
		return

	# Grounded only. Bobbing in mid-air is the tell that the cycle is being driven by
	# a timer rather than by walking.
	if not state.is_grounded():
		var settle := 1.0 - exp(-8.0 * delta)
		_bob_offset = _bob_offset.lerp(Vector3.ZERO, settle)
		_bob_pitch = lerpf(_bob_pitch, 0.0, settle)
		return

	_bob_phase += state.horizontal_speed() * delta * bob_cycles_per_metre * TAU
	_bob_phase = fposmod(_bob_phase, TAU)

	# The vertical component runs at twice the horizontal one: two footfalls per
	# stride, one sway.
	_bob_offset = Vector3(
		sin(_bob_phase) * bob_amount * bob_sway,
		-absf(sin(_bob_phase * 2.0)) * bob_amount,
		0.0
	)
	_bob_pitch = sin(_bob_phase) * bob_amount * 8.0


## Kicks the view down. Connect to [signal DotFpsController.landed].
func note_landing(impact: float) -> void:
	if landing_dip <= 0.0 or landing_reference_speed <= 0.0:
		return

	var weight := clampf(impact / landing_reference_speed, 0.0, 1.0)

	# Never reduced by a softer landing arriving during the recovery of a harder one.
	_landing_dip = minf(_landing_dip - landing_dip * weight, _landing_dip)
	_landing_pitch = maxf(_landing_pitch, 6.0 * weight)


func _apply_fov(state: DotFpsState, delta: float) -> void:
	if fov_speed_gain <= 0.0:
		_camera.fov = base_fov
		return

	var ratio := clampf(state.horizontal_speed() / fov_speed_reference, 0.0, 1.0)
	var target := base_fov + fov_speed_gain * ratio

	var t := 1.0 - exp(-fov_response * delta)
	_fov = lerpf(_fov, target, t)
	_camera.fov = _fov


## Tells the view the simulation stepped up by [param height] metres.
##
## Called by [DotFpsController] when a tick's vertical gain looks like a stair step
## rather than a jump. The view absorbs it and pays it back over
## [member step_smooth_time].
func note_step_up(height: float) -> void:
	if not smooth_step_up or height <= 0.0:
		return
	_step_offset = minf(_step_offset + height, 1.0)


## Drops all smoothing. Call after a teleport or a respawn.
##
## Without it the camera eases across the whole teleport distance, which shows the
## player the inside of the level on the way.
func snap() -> void:
	_eye_height = 0.0
	_step_offset = 0.0
	_fov = base_fov
	external_offset = Vector3.ZERO
	_roll = 0.0
	_landing_dip = 0.0
	_landing_pitch = 0.0
	_bob_phase = 0.0
	_bob_offset = Vector3.ZERO
	_bob_pitch = 0.0


func camera() -> Camera3D:
	return _camera


func describe() -> Dictionary:
	return {
		"camera": _camera.name if _camera != null else "<none>",
		"head": _head.name if _head != null else "<none>",
		"body": _body.name if _body != null else "<none>",
		"eye_height": "%.3f" % _eye_height,
		"step_offset": "%.3f" % _step_offset,
		"fov": "%.1f" % _fov,
		"roll": "%.2f" % _roll,
		"landing_dip": "%.3f" % _landing_dip,
		"bob": "%.3f" % _bob_offset.y,
	}
