class_name DotPlayerController
extends DotPlayerComponent

## The contract every player controller keeps, and the reason a game can swap one.
## Abstract: it moves nothing. It provides an id, an active flag, an intent queue, a teleport and the interface a switch uses to hand a player between controllers.
##
## Subclasses override five things and nothing else:
##
## [codeblock]
## _apply_intent(intent, delta)   move, this tick
## _read_transform()              where the player is now
## _write_transform(t)            put them there
## _read_velocity()               how fast, for a handover
## _write_velocity(v)             carry it in
## [/codeblock]
##
## A vehicle, a ladder, a spectator camera and a cutscene rail are all the same shape.

## Not [code]CHANNEL[/code]: the first-person controller declares its own, and a constant that shadows a parent's is a parse error.
const CONTROLLER_CHANNEL := "player.controller"

## This controller took over.
signal activated()

## It handed over.
signal deactivated()

## Somebody moved the player from outside the simulation.
signal teleported(to: Transform3D)

## What a switch asks for by name: [code]&"fp"[/code], [code]&"tp"[/code],
## [code]&"vehicle"[/code].
@export var controller_id: StringName = &""

## Whether this controller is the one driving the player.
## Read-only from outside; use [method activate] and [method deactivate] or a [DotPlayerControllerSwitch] so exactly one is true.
@export var active: bool = false:
	set(value):
		if value == active:
			return

		active = value

		if active:
			_on_activated()
			activated.emit()
		else:
			_on_deactivated()
			deactivated.emit()

## Whether intents are accepted at all.
## Distinct from [member active]: a player frozen in a warm-up keeps their controller and camera.
@export var input_enabled: bool = true

## Multiplier on movement speed, for dot-player-class and for status effects.
@export_range(0.0, 10.0, 0.01) var speed_scale: float = 1.0

## Multiplier on jump strength.
@export_range(0.0, 10.0, 0.01) var jump_scale: float = 1.0

var _last_buttons: int = 0
var _last_intent: DotPlayerIntent = null



## Feeds one tick of intent. The only way a controller is driven.
## Named [code]simulate[/code], not [code]drive[/code]: the first-person controller has an exported [code]drive[/code] property, and a property shadowing an inherited method is refused with the error reported against the file that uses it.
## Fills in the pressed/released edges, remembers the intent for [method describe_lines] and returns whether it was applied.
func simulate(intent: DotPlayerIntent, delta: float) -> bool:
	if intent == null or not active:
		return false

	intent.diff_from(_last_buttons)
	_last_buttons = intent.buttons
	_last_intent = intent

	if not input_enabled:
		# Still applied with everything released: a frozen player keeps falling and sliding; skipping the tick leaves them hanging in mid-air.
		var idle := DotPlayerIntent.make(Vector2.ZERO, 0, intent.tick)
		idle.view_yaw = intent.view_yaw
		idle.view_pitch = intent.view_pitch
		_apply_intent(idle, delta)
		return false

	_apply_intent(intent, delta)
	return true


## Takes over. Use a [DotPlayerControllerSwitch] when there is more than one.
func activate() -> void:
	active = true


func deactivate() -> void:
	active = false


func is_active() -> bool:
	return active


func last_intent() -> DotPlayerIntent:
	return _last_intent



## Moves the player outside the simulation, and says so.
## Named [code]place[/code], not [code]teleport[/code]: the first-person controller has a [code]teleport[/code] with another signature, which is a parse error on override.
## A separate door from the movement path so a spawn or server correction is never integrated as motion.
func place(to: Transform3D, keep_velocity: bool = false) -> void:
	if not keep_velocity:
		_write_velocity(Vector3.ZERO)

	_write_transform(to)
	teleported.emit(to)


## Adds [param dv] (m/s) to the player's velocity, the door for a tornado, a blast or a jump pad
## that is not the player's own input. A controller that integrates its own motion overrides it
## to apply the change on its next simulated tick, where a direct write would be undone.
func apply_external_velocity(dv: Vector3) -> void:
	_write_velocity(_read_velocity() + dv)


func transform_3d() -> Transform3D:
	return _read_transform()


func velocity() -> Vector3:
	return _read_velocity()


func speed() -> float:
	return _read_velocity().length()


## Where a camera or a weapon should be. Defaults to the body transform; a first-person controller overrides it with the eye height.
func eye_transform() -> Transform3D:
	return _read_transform()



## Everything worth carrying from one controller to the next: where the player is, how fast, and where they look.
## Deliberately not the controller's state: first- and third-person motor states have nothing in common, and everything else starts fresh.
func handover_state() -> Dictionary:
	var t := _read_transform()
	return {
		"transform": t,
		"velocity": _read_velocity(),
		"yaw": _read_yaw(),
		"pitch": _read_pitch(),
	}


## Takes it on.
func adopt_state(state: Dictionary) -> void:
	if state.has("transform"):
		_write_transform(state["transform"] as Transform3D)

	if state.has("velocity"):
		_write_velocity(state["velocity"] as Vector3)

	if state.has("yaw") and state.has("pitch"):
		_write_angles(float(state["yaw"]), float(state["pitch"]))



## Move, this tick. The one method a controller must implement.
func _apply_intent(_intent: DotPlayerIntent, _delta: float) -> void:
	pass


func _read_transform() -> Transform3D:
	var b := player().body() if is_bound() else null

	if b is Node3D:
		return (b as Node3D).global_transform

	if b is Node2D:
		var n := b as Node2D
		return Transform3D(
			Basis(Vector3.UP, n.global_rotation),
			Vector3(n.global_position.x, n.global_position.y, 0.0)
		)

	return Transform3D.IDENTITY


func _write_transform(to: Transform3D) -> void:
	var b := player().body() if is_bound() else null

	if b is Node3D:
		(b as Node3D).global_transform = to
	elif b is Node2D:
		var n := b as Node2D
		n.global_position = Vector2(to.origin.x, to.origin.y)
		n.global_rotation = to.basis.get_euler().y


func _read_velocity() -> Vector3:
	var b := player().body() if is_bound() else null

	if b is CharacterBody3D:
		return (b as CharacterBody3D).velocity

	if b is CharacterBody2D:
		var v := (b as CharacterBody2D).velocity
		return Vector3(v.x, v.y, 0.0)

	return Vector3.ZERO


func _write_velocity(v: Vector3) -> void:
	var b := player().body() if is_bound() else null

	if b is CharacterBody3D:
		(b as CharacterBody3D).velocity = v
	elif b is CharacterBody2D:
		(b as CharacterBody2D).velocity = Vector2(v.x, v.y)


func _read_yaw() -> float:
	return 0.0


func _read_pitch() -> float:
	return 0.0


func _write_angles(_yaw: float, _pitch: float) -> void:
	pass


## Called when this controller takes over. Runs before [signal activated].
func _on_activated() -> void:
	pass


func _on_deactivated() -> void:
	pass


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s (%s)%s%s speed x%.2f" % [
		component_name(),
		String(controller_id) if controller_id != &"" else "unnamed",
		" ACTIVE" if active else " idle",
		"" if input_enabled else " FROZEN",
		speed_scale,
	])

	if _last_intent != null:
		out.append("  " + _last_intent.describe())

	out.append("  velocity %.2f m/s" % speed())
	return out
