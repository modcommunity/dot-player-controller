class_name DotFpsMoveMode
extends RefCounted

## A movement mode the game adds: a ladder, water, a grappling hook, a vehicle seat. Ground, air and noclip
## are built into [DotFpsMotor]. Modes obey the motor's determinism contract (no input, clock or node reads;
## per-player memory lives in [DotFpsState]). Example and rules: docs/extending.md and docs/rationale.md.

## Id assigned by [method DotFpsMotor.register_mode]. Do not set this yourself.
var mode_id: int = -1


## The name this mode reports in logs and diagnostics. Must be unique.
func _name() -> StringName:
	return &"custom"


## Called once when the player enters this mode.
## [param state] is the only place to record anything: one mode object serves every player.
func _enter(_state: DotFpsState, _motor: DotFpsMotor) -> void:
	pass


func _exit(_state: DotFpsState, _motor: DotFpsMotor) -> void:
	pass


## One tick, replacing the built-in ground/air simulation entirely.
## The mode owns the whole tick, gravity included; nothing is applied behind its back.
func _simulate(
	_state: DotFpsState,
	_command: DotFpsCommand,
	_delta: float,
	_motor: DotFpsMotor
) -> void:
	push_error("DotFpsMoveMode._simulate() was not overridden.")


## Whether the crouch fraction is updated for this mode.
##
## Off for modes where the collider should not resize — swimming, a vehicle seat.
func _uses_crouch() -> bool:
	return true


func describe() -> Dictionary:
	return {"id": mode_id, "name": String(_name())}


func _to_string() -> String:
	return "DotFpsMoveMode(%s #%d)" % [_name(), mode_id]
