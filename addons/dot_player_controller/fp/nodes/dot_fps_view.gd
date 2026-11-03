@tool
class_name DotFpsView
extends Node

## Everything the player sees, and nothing the simulation depends on.
## Cosmetic state is driven from the sim state and never written back: anything cosmetic in [DotFpsMotor] would become netcode contract.
## It runs in [method Node._process], not the physics tick, because interpolating the eye between ticks is its point.

const CHANNEL := "fps.view"

@export_group("Wiring")

## The node yaw rotates. Usually the player body, so the avatar turns with the view.
## The body rotates rather than the camera, so a third-person view, a visible avatar and server-side facing are right.
@export var body_ref: DotNodeRef = null

## The node that carries the eye. Moved vertically for crouching.
@export var head_ref: DotNodeRef = null

## The camera. Pitch is applied here.
@export var camera_ref: DotNodeRef = null

@export_group("Camera")

## Field of view when standing still, in degrees.
@export_range(30.0, 140.0, 0.5) var base_fov: float = 90.0

## Extra degrees of field of view at [member fov_speed_reference].
## A cheap speed cue. Zero disables it.
@export_range(0.0, 60.0, 0.5) var fov_speed_gain: float = 15.0

## Horizontal speed at which the full [member fov_speed_gain] is applied, in m/s.
@export_range(1.0, 100.0, 0.5) var fov_speed_reference: float = 18.0

## How quickly the field of view follows speed, per second.
@export_range(0.5, 40.0, 0.5) var fov_response: float = 6.0

## Horizontal speed at which the widening starts, in m/s. A game whose plain run is fast
## puts this at the run, so only going faster than running widens.
@export_range(0.0, 100.0, 0.5) var fov_speed_floor: float = 0.0

@export_group("Feel")

## How far the camera leans into a turn or a strafe, in degrees. 0 disables it.
## Keep it small: past about four degrees it reads as a tilted horizon.
@export_range(0.0, 12.0, 0.1) var strafe_roll: float = 1.6

## Lateral speed at which the full [member strafe_roll] is reached, in m/s.
@export_range(1.0, 40.0, 0.5) var strafe_roll_reference: float = 8.0

## How quickly the roll follows, per second.
@export_range(0.5, 40.0, 0.5) var strafe_roll_response: float = 7.0

## How far the view dips on landing, in metres, at [member landing_reference_speed].
## Scaled by impact, so stepping off a kerb is a twitch and a long fall a lurch.
@export_range(0.0, 0.5, 0.005) var landing_dip: float = 0.09

## Downward speed producing the full [member landing_dip], in m/s.
@export_range(1.0, 60.0, 0.5) var landing_reference_speed: float = 16.0

## Seconds the landing dip takes to recover.
@export_range(0.0, 1.0, 0.01) var landing_recovery: float = 0.28

## Downward speed under which a landing dips nothing, in m/s; the dip grows from here to
## [member landing_reference_speed]. A game that hops all the time puts this over a plain
## hop's landing speed, so only a real fall is felt.
@export_range(0.0, 60.0, 0.5) var landing_min_speed: float = 0.0

## Degrees the view nods down at the deepest of a full landing dip. 0 for none.
@export_range(0.0, 10.0, 0.1) var landing_pitch: float = 1.5

## Multiplies the whole landing kick: 0 for none, 1 the tuned feel (`cl_landing_kick`).
@export_range(0.0, 2.0, 0.05) var landing_strength: float = 1.0

## Vertical camera travel of the walk cycle, in metres. 0 disables the bob.
## Off by default: head bob is divisive and a competitive game usually wants none.
@export_range(0.0, 0.15, 0.001) var bob_amount: float = 0.0

## Extra degrees of field of view while sliding, on top of the speed widening. 0 for none.
## Read only while [method DotFpsState.is_sliding], so a game without sliding sees nothing.
@export_range(0.0, 40.0, 0.5) var slide_fov_gain: float = 8.0

## Degrees the camera rolls while sliding, eased in and out like the strafe roll. 0 for none.
@export_range(-20.0, 20.0, 0.5) var slide_roll: float = 3.0

## Degrees the camera rolls away from the wall while wall running. 0 for none.
## Read only while [method DotFpsState.is_wall_running]. View only: the simulation never sees it.
@export_range(0.0, 30.0, 0.5) var wall_run_roll: float = 6.0

## How quickly the wall-run roll eases in and out, per second. Exponential, so it starts
## and ends without a snap; about a sixth of a second to settle at the default.
@export_range(0.5, 40.0, 0.5) var wall_run_roll_response: float = 6.0

## Metres a game's camera moves away from the wall while wall running (see
## [method DotFpsViewMotion.eye_shift]); this node does not apply it itself.
@export_range(0.0, 0.5, 0.01) var wall_run_eye_shift: float = 0.0

## Degrees a drawn body rolls while wall running (feet toward the wall). A game that draws a
## body applies [method DotFpsViewMotion.body_roll]; the view itself does not move a body.
@export_range(0.0, 60.0, 0.5) var wall_run_body_roll: float = 25.0

## Degrees a drawn body turns toward the wall while wall running.
@export_range(0.0, 45.0, 0.5) var wall_run_body_yaw: float = 12.0

## How quickly the body's wall-run pose eases, per second.
@export_range(0.5, 40.0, 0.5) var wall_run_body_response: float = 10.0

## Extra degrees of field of view while wall running, on top of the speed widening. 0 for
## none.
@export_range(0.0, 40.0, 0.5) var wall_run_fov_gain: float = 0.0

## The most the strafe, slide and wall-run rolls may add up to, degrees either way. 0: no
## bound beyond their sum.
@export_range(0.0, 45.0, 0.5) var roll_limit: float = 0.0

## Horizontal sway, as a fraction of [member bob_amount].
@export_range(0.0, 2.0, 0.05) var bob_sway: float = 0.5

## Bob cycles per metre travelled.
## Distance-based, not time-based, so it stops when the player stands still.
@export_range(0.1, 5.0, 0.05) var bob_cycles_per_metre: float = 0.55

@export_group("Smoothing")

## How quickly the eye follows the simulated eye height, per second.
## Cosmetic: the collider resizes per the tunables; this is the camera catching up.
@export_range(1.0, 60.0, 0.5) var eye_response: float = 18.0

## Smooth the eye's vertical position when the simulation steps the player up stairs.
## Without it every tread moves the camera in one frame; the sim still steps instantly.
@export var smooth_step_up: bool = true

## Seconds over which a step-up is absorbed.
@export_range(0.0, 0.5, 0.005) var step_smooth_time: float = 0.1

## Extra offset added to the eye, in metres.
## Where a prediction correction goes: the view eases to the corrected position while the sim already uses it.
var external_offset: Vector3 = Vector3.ZERO

## Extra rotation added to the camera, in degrees: x pitch (up positive), y yaw, z roll. Where a weapon's view punch goes.
## Presentation only. [method apply] rewrites the camera angles every frame, so anything added to the camera itself was overwritten.
var external_angles: Vector3 = Vector3.ZERO

## A multiplier on the field of view, applied after everything else; where a weapon's aim zoom goes (0.3 is a strong scope).
## Applied after the speed widening's smoothing, not inside it: the aim eases itself and smoothing twice makes a scope arrive late.
var external_fov_scale: float = 1.0

var _body: Node3D = null
var _head: Node3D = null
var _camera: Camera3D = null

var _eye_height: float = 0.0
var _step_offset: float = 0.0
var _fov: float = 0.0
var _ready_ok: bool = false

## The roll, the landing dip and the widening: [DotFpsViewMotion], fed from the exports
## above each frame, so a game that writes its camera itself uses the same arithmetic.
var _motion: DotFpsViewMotion = DotFpsViewMotion.new()
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
## [param state] is the interpolated render state, not the raw tick state.
func apply(
	state: DotFpsState,
	motor: DotFpsMotor,
	delta: float
) -> void:
	if not _ready_ok or state == null or motor == null:
		return

	if _body != null:
		# Yaw only (pitching would tilt the collider), in world space because the controller writes global_position;
		# local rotation made a player parented under anything rotated face the wrong way.
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

	_sync_motion()
	_motion.advance(state, delta)
	_advance_bob(state, delta)

	var eye := _eye_height - _step_offset + _motion.eye_drop() + _bob_offset.y
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
		deg_to_rad(state.pitch + _motion.pitch() + _bob_pitch + external_angles.x),
		deg_to_rad(external_angles.y),
		deg_to_rad(_motion.roll() + external_angles.z)
	)

	_apply_fov()


## The exports above onto [member _motion], every frame because a game may change them any time.
## Every [DotFpsViewMotion] field must be forwarded; one left out keeps the default with no way to change it.
func _sync_motion() -> void:
	_motion.strafe_roll = strafe_roll
	_motion.strafe_roll_reference = strafe_roll_reference
	_motion.strafe_roll_response = strafe_roll_response
	_motion.slide_roll = slide_roll
	_motion.wall_run_roll = wall_run_roll
	_motion.wall_run_roll_response = wall_run_roll_response
	_motion.wall_run_eye_shift = wall_run_eye_shift
	_motion.wall_run_body_roll = wall_run_body_roll
	_motion.wall_run_body_yaw = wall_run_body_yaw
	_motion.wall_run_body_response = wall_run_body_response
	_motion.landing_dip = landing_dip
	_motion.landing_reference_speed = landing_reference_speed
	_motion.landing_recovery = landing_recovery
	_motion.fov_speed_gain = fov_speed_gain
	_motion.fov_speed_reference = fov_speed_reference
	_motion.fov_response = fov_response
	_motion.slide_fov_gain = slide_fov_gain
	_motion.wall_run_fov_gain = wall_run_fov_gain
	_motion.landing_min_speed = landing_min_speed
	_motion.landing_pitch = landing_pitch
	_motion.landing_strength = landing_strength
	_motion.fov_speed_floor = fov_speed_floor
	_motion.roll_limit = roll_limit


## The wall-run roll as drawn this frame, in degrees. For a test or a HUD.
func wall_roll() -> float:
	return _motion.wall_roll()


## Advances the walk cycle by distance travelled and writes the bob offsets.
func _advance_bob(state: DotFpsState, delta: float) -> void:
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
## A kick to the eye's velocity ([DotFpsViewMotion.note_landing]), so the eye dips and returns with no frame where it jumps.
func note_landing(impact: float) -> void:
	_sync_motion()
	_motion.note_landing(impact)


func _apply_fov() -> void:
	var scale := clampf(external_fov_scale, 0.01, 1.0) if is_finite(external_fov_scale) else 1.0
	_fov = base_fov + _motion.fov_added()
	_camera.fov = _fov * scale


## Tells the view the simulation stepped up by [param height] metres.
## Called when a tick's vertical gain looks like a stair step; the view pays it back over [member step_smooth_time].
func note_step_up(height: float) -> void:
	if not smooth_step_up or height <= 0.0:
		return
	_step_offset = minf(_step_offset + height, 1.0)


## Drops all smoothing. Call after a teleport or respawn, or the camera eases across the whole distance.
func snap() -> void:
	_eye_height = 0.0
	_step_offset = 0.0
	_fov = base_fov
	external_offset = Vector3.ZERO
	_motion.snap()
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
		"roll": "%.2f" % _motion.roll(),
		"wall_roll": "%.2f" % _motion.wall_roll(),
		"landing_dip": "%.3f" % _motion.eye_drop(),
		"bob": "%.3f" % _bob_offset.y,
	}
