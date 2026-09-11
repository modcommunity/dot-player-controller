class_name DotFpsMoveMode
extends RefCounted

## A movement mode the game adds: a ladder, water, a grappling hook, a vehicle seat.
##
## Ground, air and noclip are built into [DotFpsMotor] because every first-person game
## has them and because they are what the tunables describe. Everything else is a
## game's own decision about feel, and the previous answer — "fork the motor" — was
## the wrong one.
##
## [codeblock]
## class LadderMode extends DotFpsMoveMode:
##     func _name() -> StringName:
##         return &"ladder"
##
##     func _simulate(state, command, delta, motor) -> void:
##         var up := command.move.y * motor.tunables.max_speed * 0.6
##         state.velocity = Vector3(0.0, up, 0.0)
##         motor.move_and_slide(state, delta)
##
##         if not still_on_ladder(state):
##             motor.set_mode(state, DotFpsState.Mode.AIR)
##
## var ladder := motor.register_mode(LadderMode.new())
## motor.set_mode(state, ladder)
## [/codeblock]
##
## [b]The determinism contract applies here exactly as it does to the motor.[/b] A
## mode runs inside client-side prediction and inside the server's authoritative tick,
## and a replay re-runs it. It may not read the keyboard, the wall clock, an unseeded
## random stream or a node's transform; anything it needs to remember between ticks
## belongs in [DotFpsState], not on the mode object — the mode is shared by every
## player using it, and a rewind does not restore it.
##
## [DotFpsMotor] exposes the pieces a mode needs: [method DotFpsMotor.accelerate],
## [method DotFpsMotor.move_and_slide], [method DotFpsMotor.probe], and the surface
## and modifier aggregates.

## Id assigned by [method DotFpsMotor.register_mode]. Do not set this yourself.
var mode_id: int = -1


## The name this mode reports in logs and diagnostics. Must be unique.
func _name() -> StringName:
	return &"custom"


## Called once when the player enters this mode.
##
## [param state] is the only place to record anything: two players can be on ladders
## at the same time and there is one mode object between them.
func _enter(_state: DotFpsState, _motor: DotFpsMotor) -> void:
	pass


func _exit(_state: DotFpsState, _motor: DotFpsMotor) -> void:
	pass


## One tick, replacing the built-in ground/air simulation entirely.
##
## The mode owns the whole tick: gravity, acceleration, collision. Nothing is applied
## for it, because a ladder that had gravity applied behind its back would need to
## cancel a force it never asked for.
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
