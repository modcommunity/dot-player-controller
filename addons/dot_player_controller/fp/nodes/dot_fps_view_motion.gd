class_name DotFpsViewMotion
extends RefCounted

## The camera's motion cues as numbers: the landing dip, the strafe and slide roll, the
## wall-run lean and the field of view widening with speed. No nodes and no camera.
##
## [b]Why it is not inside [DotFpsView].[/b] A game that writes its camera itself (one place,
## with its own interpolation, shake and zoom) could not use the view without handing it the
## camera, so it copied the arithmetic instead, and a copy drifts. This is the arithmetic
## alone: [method advance] once a rendered frame with the drawn state, [method note_landing]
## from [signal DotFpsController.landed], then read [method roll], [method eye_drop],
## [method pitch] and [method fov_added] and add them where the camera is written.
## [DotFpsView] is one such host.
##
## [b]Everything here moves without a snap.[/b] The landing dip is a critically damped spring
## kicked in velocity, never in position: the eye keeps going down for a few frames after the
## feet stop and comes back up, so a landing has no frame where the eye jumps. The strafe roll
## and the widening are two exponential stages in a row, so they ease in AND out rather than
## starting at full rate. Each is frame-rate independent (exact in the frame time).
##
## View only: nothing here is read by the simulation, so it may differ per player and per
## machine. That is also why every amount here can be a player's setting.


## Degrees the camera leans into a strafe at [member strafe_roll_reference]. 0 disables it.
## Small: past about four degrees it reads as a tilted horizon.
var strafe_roll: float = 1.6

## Lateral speed, against the view's own right, at which the full [member strafe_roll] is
## reached, in m/s.
var strafe_roll_reference: float = 8.0

## How quickly the strafe roll follows, per second. Two stages at twice this rate each, so the
## roll reaches about two thirds of the way in the time one stage at this rate would.
var strafe_roll_response: float = 7.0

## Degrees the camera rolls while sliding, on top of the strafe roll, eased like it. 0 for none.
var slide_roll: float = 3.0

## Degrees the camera leans away from a wall being run along, toward the open side. 0 for none.
## Scaled by how square the view is to the wall: looking straight along it gives the full
## lean, turning to face away from it blends toward none rather than flipping.
var wall_run_roll: float = 6.0

## How quickly the wall-run lean eases in and out, per second. One exponential stage: about
## a sixth of a second to settle at 6.
var wall_run_roll_response: float = 6.0

## The most the strafe, slide and wall-run rolls may add up to, degrees either way. 0: no
## bound beyond the sum of the three.
var roll_limit: float = 0.0


## How far the eye dips on a landing at [member landing_reference_speed], in metres, at the
## deepest. 0 disables it.
##
## Scaled by impact, so stepping off a kerb is a twitch and a long fall is a lurch.
var landing_dip: float = 0.09

## Downward speed giving the full [member landing_dip], m/s.
var landing_reference_speed: float = 16.0

## Downward speed under which a landing dips nothing, m/s; the dip grows from here to the
## reference. A game that hops all the time puts this over a plain hop's landing speed, so
## only a real fall is felt.
var landing_min_speed: float = 0.0

## Seconds from the landing until the dip has mostly recovered (about nine tenths). The
## deepest point is a fifth of this after the landing.
var landing_recovery: float = 0.28

## Degrees the view nods down at the deepest of a full dip, following the dip's own curve.
var landing_pitch: float = 1.5


## Extra degrees of field of view at [member fov_speed_reference]. 0 disables the speed part.
var fov_speed_gain: float = 15.0

## Horizontal speed at which the widening starts, m/s. A game whose plain run is fast puts
## this at the run, so only going faster than running widens.
var fov_speed_floor: float = 0.0

## Horizontal speed at which the full [member fov_speed_gain] is reached, m/s.
var fov_speed_reference: float = 18.0

## How quickly the widening follows, per second (two stages, like the strafe roll).
var fov_response: float = 6.0

## Extra degrees while sliding, on top of the speed widening. 0 for none.
var slide_fov_gain: float = 8.0

## Extra degrees while wall running, on top of the speed widening. 0 for none.
var wall_run_fov_gain: float = 0.0

var _roll_a: float = 0.0
var _roll: float = 0.0
var _wall_roll: float = 0.0
var _dip: float = 0.0
var _dip_velocity: float = 0.0
var _fov_a: float = 0.0
var _fov: float = 0.0


## Moves every cue on by [param delta] seconds toward what [param state] asks for. Once a
## rendered frame, with the state as drawn (interpolated), never once a tick.
func advance(state: DotFpsState, delta: float) -> void:
	if state == null or not (delta > 0.0):
		return

	var right := DotFpsMotor.forward_for(state.yaw).cross(Vector3.UP)

	# Strafe and slide roll: two stages, so it starts and stops gently.
	var target := 0.0
	if strafe_roll > 0.0 and strafe_roll_reference > 0.0:
		var lateral := state.velocity.dot(right)
		target = -clampf(lateral / strafe_roll_reference, -1.0, 1.0) * strafe_roll
	if state.is_sliding():
		target += slide_roll
	var t := 1.0 - exp(-2.0 * strafe_roll_response * delta)
	_roll_a = lerpf(_roll_a, target, t)
	_roll = lerpf(_roll, _roll_a, t)

	# The wall-run lean, away from the wall.
	var wall := 0.0
	if wall_run_roll > 0.0 and state.is_wall_running() and state.wall_normal != Vector3.ZERO:
		wall = -state.wall_normal.dot(right) * wall_run_roll
	_wall_roll = lerpf(_wall_roll, wall, 1.0 - exp(-wall_run_roll_response * delta))

	_advance_dip(delta)

	# The widening.
	var widen := 0.0
	if fov_speed_gain > 0.0 and fov_speed_reference > fov_speed_floor:
		var ratio := clampf(
			(state.horizontal_speed() - fov_speed_floor) / (fov_speed_reference - fov_speed_floor),
			0.0, 1.0
		)
		widen = fov_speed_gain * ratio
	if state.is_sliding():
		widen += slide_fov_gain
	if state.is_wall_running():
		widen += wall_run_fov_gain
	var f := 1.0 - exp(-2.0 * fov_response * delta)
	_fov_a = lerpf(_fov_a, widen, f)
	_fov = lerpf(_fov, _fov_a, f)


## The spring's angular frequency: the deepest point a fifth of [member landing_recovery] in.
func _omega() -> float:
	return 5.0 / maxf(landing_recovery, 0.01)


## A critically damped spring, solved exactly over [param delta]: x(t) = (x0 + (v0 + w x0) t)
## e^(-w t). Exact rather than stepped, so a long frame neither overshoots nor rings.
func _advance_dip(delta: float) -> void:
	if landing_dip <= 0.0 or landing_recovery <= 0.0:
		_dip = 0.0
		_dip_velocity = 0.0
		return
	if _dip == 0.0 and _dip_velocity == 0.0:
		return
	var w := _omega()
	var decay := exp(-w * delta)
	var c := _dip_velocity + w * _dip
	var x := (_dip + c * delta) * decay
	_dip_velocity = (_dip_velocity - w * c * delta) * decay
	_dip = x
	if absf(_dip) < 0.0001 and absf(_dip_velocity) < 0.001:
		_dip = 0.0
		_dip_velocity = 0.0


## A landing at [param impact] m/s downward. Connect to [signal DotFpsController.landed].
##
## A kick to the eye's velocity, sized so the dip peaks at [member landing_dip] times the
## impact's weight. A softer landing during the recovery of a harder one never lessens it.
func note_landing(impact: float) -> void:
	if landing_dip <= 0.0 or landing_recovery <= 0.0:
		return
	var span := landing_reference_speed - landing_min_speed
	if span <= 0.0:
		return
	var weight := clampf((absf(impact) - landing_min_speed) / span, 0.0, 1.0)
	if weight <= 0.0:
		return
	# Peak of x(t) = v0 t e^(-w t) is v0 / (w e), at t = 1 / w.
	var kick := -landing_dip * weight * _omega() * exp(1.0)
	_dip_velocity = minf(_dip_velocity, kick)


## Drops everything. After a teleport or a respawn.
func snap() -> void:
	_roll_a = 0.0
	_roll = 0.0
	_wall_roll = 0.0
	_dip = 0.0
	_dip_velocity = 0.0
	_fov_a = 0.0
	_fov = 0.0


## The camera's roll this frame, degrees (positive leans left): strafe, slide and wall run,
## bounded by [member roll_limit].
func roll() -> float:
	var total := _roll + _wall_roll
	return clampf(total, -roll_limit, roll_limit) if roll_limit > 0.0 else total


## The strafe and slide part of [method roll], degrees.
func strafe_roll_now() -> float:
	return _roll


## The wall-run lean as drawn this frame, degrees.
func wall_roll() -> float:
	return _wall_roll


## Metres to add to the eye's height this frame: 0 or below, the landing dip.
func eye_drop() -> float:
	return _dip


## Degrees to add to the view's pitch this frame (up positive): the landing nod.
func pitch() -> float:
	if landing_dip <= 0.0:
		return 0.0
	return landing_pitch * _dip / landing_dip


## Degrees to add to the camera's field of view this frame: the speed, slide and wall-run
## widening.
func fov_added() -> float:
	return _fov


func describe() -> Dictionary:
	return {
		"roll": "%.2f" % roll(),
		"strafe_roll": "%.2f" % _roll,
		"wall_roll": "%.2f" % _wall_roll,
		"landing_dip": "%.3f" % _dip,
		"fov_added": "%.2f" % _fov,
	}
