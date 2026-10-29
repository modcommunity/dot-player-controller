@tool
extends DotPlayerController

## The signals of [DotFpsController], kept apart so the controller file stays small.

## Emitted after every simulated tick, on whichever peer simulated it.
signal simulated(tick: int, state: DotFpsState)


## Emitted when the player touches down. [param impact] is the downward speed lost.
signal landed(impact: float)


signal jumped()


## Emitted when the movement mode changes. Modes are ints because a game registers its own;
## render one with [method DotFpsState.mode_name].
signal mode_changed(from: int, to: int)


## Emitted when the player steps up onto something, with the height gained.
signal stepped_up(height: float)


## Emitted when the ground under the player changes kind (ids, not resources): the hook for
## footstep sounds and decals.
signal surface_changed(from: StringName, to: StringName)


## Emitted when the player starts or stops being crouched.
signal crouch_changed(crouched: bool)


## Emitted when a slide starts or ends ([member DotFpsTunables.slide_enabled]). Not during a
## prediction replay, unlike [signal crouch_changed]: a replayed tick is one the player
## already heard.
signal slide_changed(sliding: bool)


## Emitted when the launch ability fires. Not during a replay, for the same reason.
signal launched()


## Emitted when the dash fires. Not during a replay.
signal dashed()


## Emitted when a wall run starts or ends. Not during a replay, like [signal slide_changed].
## See [member DotFpsTunables.wall_run_enabled].
signal wall_run_changed(running: bool)


## Emitted with the degrees a jump-started wall-run turns the view; a controller with a sampler has already applied it, a game that samples its own look input applies it there. Not during a replay.
signal view_turned(degrees: float)


## Emitted when a wall jump fires. Not during a replay. See
## [member DotFpsTunables.wall_jump_enabled].
signal wall_jumped()


## Emitted when a modifier starts or stops applying, on whichever peer simulates.
signal modifier_added(id: StringName)


signal modifier_removed(id: StringName)


var _external_velocity: Vector3 = Vector3.ZERO


## Queued and added on the next live tick, before the move, so the motor sees it and an upward
## change lifts the player off the ground instead of being snapped back down.
func apply_external_velocity(dv: Vector3) -> void:
	_external_velocity += dv


func _consume_external_velocity(s: DotFpsState, replaying: bool) -> void:
	if _external_velocity == Vector3.ZERO or replaying:
		return
	s.velocity += _external_velocity
	if _external_velocity.y > 0.0:
		s.mode = DotFpsState.Mode.AIR
		s.time_since_grounded = 1000.0
	_external_velocity = Vector3.ZERO
