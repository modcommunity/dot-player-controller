class_name DotPlayerLook
extends RefCounted

## Where a player is looking, accumulated from deltas, clamped, and never wrapping.
##
## [b]Forty lines that every project rewrites and half of them get wrong.[/b] The three
## mistakes, in the order they are discovered:
##
## 1. [b]Pitch is clamped, yaw is wrapped.[/b] Clamping yaw stops the player turning
##    round; wrapping pitch lets them look through their own feet and come out the top.
## 2. [b]The wrap has to happen, and to a bounded range.[/b] A yaw that only ever
##    accumulates is a float that loses precision over a long session, and the symptom
##    is a mouse that gets less accurate the longer the server has been up.
## 3. [b]Sensitivity is applied to the delta, not to the angle.[/b] Applied to the
##    angle it is a multiplier on where you are looking, which snaps the view every
##    time the setting changes.

## Radians. Wrapped to [code]-PI..PI[/code].
var yaw: float = 0.0

## Radians. Clamped to [member pitch_min] and [member pitch_max].
var pitch: float = 0.0

## Multiplier on incoming deltas.
var sensitivity: float = 1.0

## Multiplier applied on top while zoomed. Below 1 is slower, which is the point.
var zoom_sensitivity: float = 0.4

## Whether the pitch delta is inverted.
var invert_pitch: bool = false

## How far down the player may look. Radians, negative.
var pitch_min: float = -PI * 0.5 + 0.01

## How far up. Radians.
var pitch_max: float = PI * 0.5 - 0.01

## Whether zoom sensitivity is in effect.
var zoomed: bool = false


func _init(p_sensitivity: float = 1.0) -> void:
	sensitivity = p_sensitivity


## Applies one tick of look delta and returns the new angles as a [Vector2].
func apply(delta_look: Vector2) -> Vector2:
	var scale := sensitivity * (zoom_sensitivity if zoomed else 1.0)

	yaw = wrapf(yaw - delta_look.x * scale, -PI, PI)

	var dy := delta_look.y * scale
	pitch = clampf(pitch + (dy if invert_pitch else -dy), pitch_min, pitch_max)

	return Vector2(yaw, pitch)


## Sets the angles outright, clamping and wrapping. For a teleport or a server correction.
func set_angles(p_yaw: float, p_pitch: float) -> void:
	yaw = wrapf(p_yaw, -PI, PI)
	pitch = clampf(p_pitch, pitch_min, pitch_max)


## The direction being looked along.
func forward() -> Vector3:
	var cos_pitch := cos(pitch)
	return Vector3(
		-sin(yaw) * cos_pitch,
		sin(pitch),
		-cos(yaw) * cos_pitch
	)


## The direction being looked along, flattened onto the ground plane.
##
## What movement uses, and separate from [method forward] because a player looking at
## the floor should still walk forwards rather than into it.
func forward_flat() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right_flat() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


## A basis for a first-person camera: yaw then pitch.
func basis() -> Basis:
	return Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)


## The yaw alone, as a body's rotation.
func body_basis() -> Basis:
	return Basis(Vector3.UP, yaw)


## Turns a ground-plane intent into a world direction, relative to where the player is
## looking.
##
## [b]Here rather than in each controller.[/b] Both the first-person and the third-
## person controller need it, they need it to agree, and the version that gets written
## twice is the version where one of them has X and Y the wrong way round.
func move_direction(move: Vector2) -> Vector3:
	return (forward_flat() * move.y + right_flat() * move.x)


## The same for a 2D game: an angle and a direction on the screen plane.
func direction_2d() -> Vector2:
	return Vector2(cos(yaw), sin(yaw))


## Where a 2D player's aim points, given a screen offset from them.
##
## Wrapped to the same range as [member yaw] so a 2D game and a 3D one describe an angle
## the same way, which matters when a replay, a wire message or a describe line is read
## by something that does not know which it came from.
static func angle_to(from: Vector2, to: Vector2) -> float:
	return wrapf((to - from).angle(), -PI, PI)


func copy_look() -> DotPlayerLook:
	var l := DotPlayerLook.new(sensitivity)
	l.yaw = yaw
	l.pitch = pitch
	l.zoom_sensitivity = zoom_sensitivity
	l.invert_pitch = invert_pitch
	l.pitch_min = pitch_min
	l.pitch_max = pitch_max
	l.zoomed = zoomed
	return l


func describe() -> String:
	return "yaw %.1f° pitch %.1f°%s" % [
		rad_to_deg(yaw), rad_to_deg(pitch), " (zoomed)" if zoomed else ""
	]


func _to_string() -> String:
	return "DotPlayerLook(%s)" % describe()
