extends "dot_fps_motor_base.gd"

## The motor's geometry helpers and its wall running and wall jumping, split out of
## [DotFpsMotor] to keep that file under the size gate; it is the layer between them.


## How finely a wall's heading is counted for [member DotFpsTunables.wall_jump_max_per_wall]: eighths of a turn, the replicated field's width.
## Two walls at a right angle are always two headings apart, and one wall is never two.
const WALL_HEADINGS := 8

## The wall counters' ceiling, the width of their replicated field.
const WALL_JUMP_COUNT_MAX := 3

## Below this horizontal speed, in m/s, the velocity has no direction worth probing along,
## and only the view's directions are asked.
const WALL_PROBE_MIN_SPEED := 0.5


## The probe directions for a wall: both sides of the velocity when moving, then the view's four flat directions.
func _wall_probe_directions(state: DotFpsState) -> Array[Vector3]:
	var directions: Array[Vector3] = []
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if flat.length() >= WALL_PROBE_MIN_SPEED:
		var side := flat.normalized().cross(Vector3.UP)
		directions.append(side)
		directions.append(-side)

	var view := _view_basis(state.yaw, 0.0)
	directions.append(view.forward)
	directions.append(-view.forward)
	directions.append(view.right)
	directions.append(-view.right)
	return directions


## The wall beside the player this tick, or null. Also writes [member DotFpsState.wall_normal].
## Asked fresh every tick: the world answers the same on both machines, and a remembered normal is one more thing a rewind must restore.
## Probed only when the answer will be used (a run, a possible start, or a wall-jump press): a short sideways sweep (`wall_reach`) to each side of the velocity, then the view's four flat directions; the nearest steep enough wall wins.
func _wall_contact(state: DotFpsState, command: DotFpsCommand) -> DotFpsBody.Hit:
	if (
		not tunables.wall_run_enabled
		and not tunables.wall_jump_enabled
		and tunables.wall_slide_speed <= 0.0
	):
		return null

	state.wall_normal = Vector3.ZERO

	if state.mode != DotFpsState.Mode.AIR:
		return null

	var wants_run := (
		tunables.wall_run_enabled
		and (state.is_wall_running() or (
			not state.wall_run_spent
			and state.horizontal_speed() >= (
				tunables.wall_run_jump_min_speed if tunables.wall_run_auto
				else tunables.wall_run_min_speed
			)
		))
	)
	var wants_jump := (
		(tunables.wall_jump_enabled or (tunables.wall_run_enabled and tunables.wall_run_on_jump))
		and state.time_since_jump_pressed <= tunables.jump_buffer_time
	)

	var wants_slide := (
		tunables.wall_slide_speed > 0.0
		and state.velocity.y < 0.0
		and (command.move != Vector2.ZERO or state.wall_run_spent)
	)

	if not wants_run and not wants_jump and not wants_slide:
		return null

	var directions := _wall_probe_directions(state)
	var height := _height(state)
	var centre := _capsule_centre(state.position, height)
	var steepest := cos(deg_to_rad(90.0 - tunables.wall_max_angle_from_vertical))
	var best: DotFpsBody.Hit = null

	# A run keeps the wall beside it: while running, the two sideways probes win over anything nearer, since a ledge's end face has no "along" speed and ended runs under nearest-wins.
	var sideways := 2 if state.is_wall_running() and directions.size() == 6 else 0
	var beside: DotFpsBody.Hit = null

	for index in range(directions.size()):
		var direction := directions[index]
		var hit := _sweep(centre, direction * tunables.wall_reach, height)
		if not hit.hit or absf(hit.normal.y) > steepest:
			continue
		if hit.normal.dot(direction) >= 0.0:
			continue
		if index < sideways and (beside == null or hit.fraction < beside.fraction):
			beside = hit
		if best == null or hit.fraction < best.fraction:
			best = hit

	if beside != null:
		best = beside

	if best != null:
		state.wall_normal = best.normal

	return best


## The wall's normal laid flat and normalised: what "away from the wall" means for a push
## and "along the wall" for a run, whatever the wall's lean.
static func _flat_normal(normal: Vector3) -> Vector3:
	var flat := Vector3(normal.x, 0.0, normal.z)
	return flat.normalized() if flat.length_squared() > 1e-8 else Vector3.ZERO


## A flat normal's heading in eighths of a turn, 0..7.
static func wall_heading_of(normal: Vector3) -> int:
	var turns := atan2(normal.x, normal.z) / TAU
	return posmod(roundi(turns * WALL_HEADINGS), WALL_HEADINGS)


## Whether two headings name the same wall: within one eighth, either way round.
## One either side rather than an exact match, so a wall whose normal sits on a boundary
## is not two walls depending on which side of it the rounding falls.
static func _same_wall(a: int, b: int) -> bool:
	var apart := posmod(a - b, WALL_HEADINGS)
	return apart <= 1 or apart >= WALL_HEADINGS - 1


## Slack, in seconds, on the run's time cap. A cap that is a whole number of ticks (1 s at 66 Hz) is reached by a sum of tick lengths on the server, which lands a hair under it, and by the exactly decoded value ([constant DotFpsNetSync.timer_scale]) on a client that has just rewound, which lands on it; the run then ended a tick apart. With the slack both end on the cap's tick. Far under a tick at any rate; a cap that is not a whole number of ticks moves by nothing.
const WALL_RUN_TIME_SLACK := 1e-4


## Starts, carries and ends a wall run.
## Entered only from the air, beside a steep enough wall, moving along it at [member DotFpsTunables.wall_run_min_speed] or more, not falling fast, forward held when required, and not after a run already ended this airborne stretch.
## Speed along the wall is left alone and gravity reduced ([method _wall_run_vertical]). Ends on the time cap, losing the wall, slowing, releasing forward, landing, or any jump or launch.
func _update_wall_run(
	state: DotFpsState,
	command: DotFpsCommand,
	delta: float,
	wall: DotFpsBody.Hit,
	left_this_tick: bool
) -> void:
	if not tunables.wall_run_enabled and not tunables.wall_jump_enabled:
		return

	# Touching the ground resets both wall moves, whichever of them is on. Also done in
	# [method _advance_timers], because a jump off the ground has put the player in AIR by
	# the time this runs, and that tick started on the ground all the same.
	if state.mode == DotFpsState.Mode.GROUND:
		_reset_walls(state)
		return

	if not tunables.wall_run_enabled:
		# A run in progress when a server turns running off ends rather than freezing.
		if state.is_wall_running():
			_end_wall_run(state)
		return

	if state.is_wall_running():
		state.wall_run_time += delta

		if (
			left_this_tick
			or wall == null
			or _effects.deny_move
			or state.wall_run_time >= minf(tunables.wall_run_max_time, DotFpsTunables.WALL_RUN_TIME_LIMIT) - WALL_RUN_TIME_SLACK
			or _speed_along_wall(state, wall) < tunables.wall_run_end_speed
			or (tunables.wall_run_requires_forward and command.move.y <= 0.0)
			or (
				not tunables.wall_jump_enabled and tunables.wall_run_on_jump
				and state.time_since_jump_pressed <= tunables.jump_buffer_time
			)
		):
			# A wall jump has already ended the run and un-spent it; nothing to do.
			if state.is_wall_running():
				_end_wall_run(state)
		return

	if left_this_tick or wall == null or state.wall_run_spent or _effects.deny_move:
		return

	if state.mode != DotFpsState.Mode.AIR or state.wall_run_cooldown_left > 0.0:
		return

	if state.time_since_grounded < WALL_ENTRY_MIN_AIR:
		return

	if tunables.wall_run_requires_forward and command.move.y <= 0.0:
		return

	if state.velocity.y < -tunables.wall_run_max_fall_speed:
		return

	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var into := -flat.dot(normal)

	# Moving away from the wall is leaving it, not running on it.
	if into < -LEAVING_SPEED:
		return

	var along := _speed_along_wall(state, wall)
	if along < tunables.wall_run_min_speed:
		return

	# The angle between the velocity and the wall's plane: 0 along it, 90 straight in.
	var approach := rad_to_deg(atan2(maxf(into, 0.0), along))
	if approach > tunables.wall_run_max_approach_angle:
		return

	if not _wall_runnable(state, wall):
		return

	state.wall_run_time = 0.0
	wall_runs += 1


## Seconds off the ground before a run may start: a step, kerb or slope bump that flickers the
## mode to AIR for a tick while walking beside a wall must not attach. A jump sets it to 1000.
const WALL_ENTRY_MIN_AIR := 0.08
const WALL_PROBE_STEP := 0.25
const WALL_PROBE_STANDOFF := 0.12
const WALL_PROBE_RADIUS := 0.05
const WALL_PROBE_HEIGHT := 0.12


## Whether [param wall] is big enough to START a run on: tall enough around the contact (and
## reaching above the hip) and long enough ahead. Probes only the world, so both peers agree.
## A wall jump never asks: a ledge is still a thing to push off.
func _wall_runnable(state: DotFpsState, wall: DotFpsBody.Hit) -> bool:
	var min_height := tunables.wall_run_min_height
	var min_length := tunables.wall_run_min_length
	if min_height <= 0.0 and min_length <= 0.0:
		return true

	var normal := _flat_normal(wall.normal)
	if normal == Vector3.ZERO:
		return false

	var height := _height(state)
	var feet_y := state.position.y
	var base := Vector3(wall.point.x, 0.0, wall.point.z)

	# The capsule's contact point can sit above a low wall's top, so find the highest part
	# of the face inside the capsule's span instead.
	var contact_y := -INF
	var level := feet_y + height
	while level >= feet_y + 0.05 and contact_y == -INF:
		if _wall_probe(base, normal, level) == 1:
			contact_y = level
		level -= WALL_PROBE_STEP * 0.5
	if contact_y == -INF:
		return false

	if min_height > 0.0:
		var top := _wall_extent(base, normal, contact_y, 1.0, min_height)
		var bottom := _wall_extent(base, normal, contact_y, -1.0, min_height)
		if top + bottom < min_height - 0.001 or contact_y + top < feet_y + height * 0.5:
			return false

	if min_length > 0.0:
		var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
		var tangent := normal.cross(Vector3.UP)
		if tangent.dot(flat) < 0.0:
			tangent = -tangent
		var ahead := _wall_extent_along(base, normal, tangent, contact_y, min_length)
		if ahead < min_length - 0.001:
			return false

	return true


## Whether a thin probe at [param at] (flat) and [param y] finds the wall face.
func _wall_probe(at: Vector3, normal: Vector3, y: float) -> int:
	var origin := Vector3(at.x, y, at.z) + normal * WALL_PROBE_STANDOFF
	if body.overlaps(origin, WALL_PROBE_HEIGHT, WALL_PROBE_RADIUS):
		return 2
	var hit := _sweep(origin, -normal * (WALL_PROBE_STANDOFF + 0.2), WALL_PROBE_HEIGHT, WALL_PROBE_RADIUS)
	if hit.hit and _flat_normal(hit.normal).dot(normal) > 0.9:
		return 1
	return 0


## How far the face continues up (+1) or down (-1) from [param y], up to [param limit]. A probe
## that starts inside solid ground ends the count there: the face runs into the floor.
func _wall_extent(base: Vector3, normal: Vector3, y: float, sign_y: float, limit: float) -> float:
	var reached := 0.0
	while reached < limit:
		var found := _wall_probe(base, normal, y + sign_y * (reached + WALL_PROBE_STEP))
		if found == 2:
			return reached
		if found == 0:
			break
		reached += WALL_PROBE_STEP
	return reached


func _wall_extent_along(base: Vector3, normal: Vector3, tangent: Vector3, y: float, limit: float) -> float:
	var reached := 0.0
	while reached < limit:
		var at := base + tangent * (reached + WALL_PROBE_STEP)
		if _wall_probe(at, normal, y) != 1:
			break
		reached += WALL_PROBE_STEP
	return reached


func _reset_walls(state: DotFpsState) -> void:
	state.wall_run_time = -1.0
	state.wall_run_spent = false
	state.wall_jump_count = 0
	state.wall_jumps_in_air = 0


func _end_wall_run(state: DotFpsState) -> void:
	state.wall_run_time = -1.0
	state.wall_run_spent = true
	state.wall_run_cooldown_left = tunables.wall_run_cooldown


## A jump press in the air beside a wall starts a run: the heading is turned along the wall at
## the horizontal speed the player had, and the press is spent. Returns whether it started one.
func _try_jump_run(state: DotFpsState, wall: DotFpsBody.Hit) -> bool:
	if not (tunables.wall_run_enabled and tunables.wall_run_on_jump) or wall == null:
		return false

	if tunables.wall_run_auto:
		return false

	if state.mode != DotFpsState.Mode.AIR or state.is_wall_running() or state.wall_run_spent:
		return false

	if state.wall_run_cooldown_left > 0.0 or _effects.deny_move or _effects.deny_jump:
		return false

	if state.time_since_grounded < WALL_ENTRY_MIN_AIR:
		return false

	if state.time_since_jump_pressed > tunables.jump_buffer_time:
		return false

	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := flat.length()
	if normal == Vector3.ZERO or speed < tunables.wall_run_jump_min_speed:
		return false

	var into := -flat.dot(normal)
	if into < -LEAVING_SPEED:
		return false

	var tangent := normal.cross(Vector3.UP)
	if tangent.dot(flat) < 0.0:
		tangent = -tangent
	var approach := rad_to_deg(atan2(maxf(into, 0.0), absf(tangent.dot(flat))))
	if approach > tunables.wall_run_jump_max_angle:
		return false

	if not _wall_runnable(state, wall):
		return false

	_turn_along(state, tangent * speed)
	state.time_since_jump_pressed = 1000.0
	return true


## Starts a run with no press: airborne, moving into a wall within the jump-run limits.
## A press in the air takes the wall jump first, so a quick press during the run leaves it.
func _try_auto_run(state: DotFpsState, command: DotFpsCommand, wall: DotFpsBody.Hit) -> void:
	if not (tunables.wall_run_enabled and tunables.wall_run_auto) or wall == null:
		return

	if state.mode != DotFpsState.Mode.AIR or state.is_wall_running() or state.wall_run_spent:
		return

	if state.wall_run_cooldown_left > 0.0 or _effects.deny_move:
		return

	if state.time_since_grounded < WALL_ENTRY_MIN_AIR:
		return

	if tunables.wall_run_requires_forward and command.move.y <= 0.0:
		return

	if state.velocity.y < -tunables.wall_run_max_fall_speed:
		return

	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := flat.length()
	if normal == Vector3.ZERO or speed < tunables.wall_run_jump_min_speed:
		return

	var into := -flat.dot(normal)
	if into < -LEAVING_SPEED:
		return

	var tangent := normal.cross(Vector3.UP)
	if tangent.dot(flat) < 0.0:
		tangent = -tangent
	var approach := rad_to_deg(atan2(maxf(into, 0.0), absf(tangent.dot(flat))))
	if approach > tunables.wall_run_jump_max_angle:
		return

	if not _wall_runnable(state, wall):
		return

	_turn_along(state, tangent * speed)


## Begins a run with the horizontal velocity [param turned] (along the wall).
func _turn_along(state: DotFpsState, turned: Vector3) -> void:
	state.velocity.x = turned.x
	state.velocity.z = turned.z
	state.wall_run_time = 0.0
	wall_runs += 1
	if tunables.wall_run_turn_view:
		var view := forward_for(state.yaw)
		var limit := tunables.wall_run_turn_view_max_angle
		if limit >= 180.0 or view.dot(turned.normalized()) > cos(deg_to_rad(limit)) + 1e-6:
			view_turn = wrapf(rad_to_deg(atan2(-turned.x, -turned.z)) - state.yaw, -180.0, 180.0)


## Horizontal speed along the wall's face.
func _speed_along_wall(state: DotFpsState, wall: DotFpsBody.Hit) -> float:
	var normal := _flat_normal(wall.normal)
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	return (flat - normal * flat.dot(normal)).length()


## The vertical half of a wall run, in place of gravity: scaled by [member DotFpsTunables.wall_run_gravity_scale] and eased toward zero at [member DotFpsTunables.wall_run_vertical_damping] per second.
## Eased, never set, so nothing changes by more than a tick's gravity at the start, during, or at the end.
func _wall_run_vertical(state: DotFpsState, delta: float) -> void:
	state.velocity.y -= tunables.gravity * tunables.wall_run_gravity_scale * _effects.gravity * delta
	state.velocity.y *= exp(-tunables.wall_run_vertical_damping * delta)


## Whether an airborne player is sliding down a wall this tick: falling, beside a wall, and
## either pushing into it or done running on it (so a run that ends decays into a slide).
func _wall_slides(state: DotFpsState, command: DotFpsCommand, wall: DotFpsBody.Hit) -> bool:
	if tunables.wall_slide_speed <= 0.0 or wall == null or state.velocity.y >= 0.0:
		return false

	if state.mode != DotFpsState.Mode.AIR or state.is_wall_running():
		return false

	if state.wall_run_spent:
		return true

	var basis := _view_basis(state.yaw, 0.0)
	var wish := basis.right * command.move.x + basis.forward * command.move.y
	wish.y = 0.0
	if wish.length_squared() < 1e-6:
		return false

	# Into the wall by more than a glance: about 30 degrees off along it, or steeper.
	return wish.normalized().dot(-_flat_normal(wall.normal)) > 0.5


## The wall slide, after gravity: a fall reaching [member DotFpsTunables.wall_slide_speed] stops gaining speed, and a faster one eases down to it exponentially at [member DotFpsTunables.wall_run_vertical_damping].
## Never cut to the cap in one tick. [param falling_at] is the vertical speed before this tick's gravity.
func _wall_slide_vertical(state: DotFpsState, falling_at: float, delta: float) -> void:
	var cap := -tunables.wall_slide_speed
	if state.velocity.y >= cap:
		return

	if falling_at >= cap:
		state.velocity.y = cap
	else:
		state.velocity.y = cap + (falling_at - cap) * exp(-tunables.wall_run_vertical_damping * delta)


## A jump off a wall the player is touching or running on. Returns whether it fired.
## On the buffered jump press, never held (holding with [member DotFpsTunables.auto_hop] would wall-jump the instant a wall came in reach), in the air, beside a steep enough wall, under [member DotFpsTunables.wall_jump_max_per_wall].
## Speed along the wall is kept and the push added; the push leans from the normal toward the view by [member DotFpsTunables.wall_jump_look_blend] with the into-wall part dropped, so it always leaves the wall. Upward speed replaces a lower one, like the launch's.
func _try_wall_jump(
	state: DotFpsState,
	command: DotFpsCommand,
	wall: DotFpsBody.Hit
) -> bool:
	if not tunables.wall_jump_enabled or wall == null:
		return false

	if not tunables.can_jump or _effects.deny_jump or _effects.deny_move or _effects.jump <= 0.0:
		return false

	if state.mode != DotFpsState.Mode.AIR:
		return false

	if state.time_since_jump_pressed > tunables.jump_buffer_time:
		return false

	if state.time_since_jump < tunables.jump_cooldown:
		return false

	var normal := _flat_normal(wall.normal)
	if normal == Vector3.ZERO:
		return false

	var heading := wall_heading_of(normal)
	var same := state.wall_jump_count > 0 and _same_wall(heading, state.wall_jump_heading)

	if (
		same
		and tunables.wall_jump_max_per_wall > 0
		and state.wall_jump_count >= tunables.wall_jump_max_per_wall
	):
		return false

	if (
		tunables.wall_jump_max_per_air > 0
		and state.wall_jumps_in_air >= tunables.wall_jump_max_per_air
	):
		return false

	var look := _view_basis(state.yaw, 0.0).forward
	look.y = 0.0
	look = look.normalized()
	# Only the part of the look that does not point into the wall.
	look -= normal * minf(look.dot(normal), 0.0)

	var push := normal * (1.0 - tunables.wall_jump_look_blend) + look * tunables.wall_jump_look_blend
	push = push.normalized() if push.length_squared() > 1e-8 else normal

	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	# Whatever was going into the wall is gone (the wall stopped it); along it is kept.
	var kept := flat - normal * minf(flat.dot(normal), 0.0)
	var jumped := kept + push * tunables.wall_jump_push_speed * _effects.jump

	state.velocity.x = jumped.x
	state.velocity.z = jumped.z
	state.velocity.y = maxf(state.velocity.y, tunables.wall_jump_up_speed * _effects.jump)

	state.time_since_jump = 0.0
	state.time_since_jump_pressed = 1000.0
	state.time_since_grounded = 1000.0

	# A jump ends a run, and un-spends running: a jump to the facing wall may run on it.
	state.wall_run_time = -1.0
	state.wall_run_spent = false

	state.wall_jump_count = mini(state.wall_jump_count + 1, WALL_JUMP_COUNT_MAX) if same else 1
	state.wall_jumps_in_air = mini(state.wall_jumps_in_air + 1, WALL_JUMP_COUNT_MAX)
	state.wall_jump_heading = heading
	wall_jumps += 1

	return true


## A sweep that always leaves [member DotFpsTunables.skin_width] between the player and whatever it hit.
## [method PhysicsDirectSpaceState3D.cast_motion] reports no collision when a move ends exactly touching, so a player resting at precisely the floor height is never grounded again and sinks at a constant rate (within seconds at 60 Hz).
## Every query therefore sweeps skin_width further and gives it back; the returned fraction is rescaled to the asked motion, so call sites read as if none of this happened.
func _sweep(
	centre: Vector3,
	motion: Vector3,
	height: float,
	radius: float = -1.0
) -> DotFpsBody.Hit:
	var length := motion.length()

	if length <= 0.0:
		return DotFpsBody.Hit.miss()

	var direction := motion / length

	# Proportional to the sweep, never less than the configured skin. See
	# SWEEP_TOLERANCE: a fixed margin is correct for a short slide step and far too
	# small for a long probe.
	var margin := maxf(tunables.skin_width, length * SWEEP_TOLERANCE)

	var hit := body.sweep(
		centre, motion + direction * margin, height,
		tunables.radius if radius < 0.0 else radius
	)

	if not hit.hit:
		return hit

	var travelled := clampf(
		hit.fraction * (length + margin) - margin, 0.0, length
	)
	hit.fraction = travelled / length

	return hit


## View directions for a yaw and pitch, in degrees.
class ViewBasis extends RefCounted:
	var forward: Vector3
	var right: Vector3
	var up: Vector3


## [param state].position is the player's feet, not the capsule's centre: that is where a scene places a character's origin, so the node transform and simulated position are the same number. Everything talking to [DotFpsBody] converts here.
func _capsule_centre(feet: Vector3, height: float) -> Vector3:
	return feet + Vector3.UP * (height * 0.5)


func _height(state: DotFpsState) -> float:
	return tunables.height_at(state.crouch_fraction)


static func _view_basis(yaw_degrees: float, pitch_degrees: float) -> ViewBasis:
	var yaw := deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)

	var basis := ViewBasis.new()

	# Godot is Y-up and right-handed with -Z forward.
	basis.forward = Vector3(
		-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)
	)
	basis.right = Vector3(cos(yaw), 0.0, -sin(yaw))
	basis.up = basis.right.cross(basis.forward)

	return basis


## The flat forward direction for a yaw, for aiming and for a game's own traces.
static func forward_for(yaw_degrees: float) -> Vector3:
	var yaw := deg_to_rad(yaw_degrees)
	return Vector3(-sin(yaw), 0.0, -cos(yaw))
