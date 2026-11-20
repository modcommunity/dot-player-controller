extends "dot_fps_motor_walls.gd"

## The motor's collide-and-slide: the ground probes and their per-tick cache, the slide, stepping, creases,
## depenetration and the snap to ground. Split out of [DotFpsMotor] for file size; it is the layer between
## that and dot_fps_motor_walls.gd, and nothing outside the motor names this script.


func _is_floor(normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) <= tunables.max_slope_radians()


const QUADRANTS: Array[Vector2] = [
	Vector2(-1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0),
]


## One of four half-radius capsules, one per quarter of the player, that finds a FLOOR along [param probe]. See [method _categorise_ground].
## Each sits half a radius out along its diagonal, inside the player's footprint: one poking outside would start inside the very face that made it necessary, or find floor the player is not over.
func _quadrant_floor(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	if not static_world:
		return _quadrant_floor_probe(centre, probe, height)
	# The end-of-tick check and the next tick's first check ask this at one position, and in a
	# world nothing moves in the answer is the same: 4 sweeps, up to 16 queries, saved.
	var radius := tunables.radius
	var mask := body.collision_mask
	if (_qf_valid and centre == _qf_centre and probe == _qf_probe and height == _qf_height
			and radius == _qf_radius and mask == _qf_mask):
		return _copy_hit(_qf_hit) if _qf_hit != null else DotFpsBody.Hit.new()
	var found := _quadrant_floor_probe(centre, probe, height)
	_qf_valid = true
	_qf_centre = centre
	_qf_probe = probe
	_qf_height = height
	_qf_radius = radius
	_qf_mask = mask
	_qf_hit = _copy_hit(found) if found.hit else null
	return found


## The ground check's sweep, remembered across ticks under [member static_world] like
## [method _quadrant_floor]: the last check of a tick and the first of the next are one question.
func _ground_probe(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	if not static_world:
		return _sweep(centre, probe, height)
	var radius := tunables.radius
	var mask := body.collision_mask
	if (_gp_valid and centre == _gp_centre and probe == _gp_probe and height == _gp_height
			and radius == _gp_radius and mask == _gp_mask and tunables.skin_width == _gp_skin):
		return _copy_hit(_gp_hit)
	var found := _sweep(centre, probe, height)
	_gp_valid = true
	_gp_centre = centre
	_gp_probe = probe
	_gp_height = height
	_gp_radius = radius
	_gp_mask = mask
	_gp_skin = tunables.skin_width
	_gp_hit = _copy_hit(found)
	return found


var _gp_valid := false
var _gp_centre := Vector3.ZERO
var _gp_probe := Vector3.ZERO
var _gp_height := 0.0
var _gp_radius := 0.0
var _gp_mask := 0
var _gp_skin := 0.0
var _gp_hit: DotFpsBody.Hit = null


## True when nothing the body queries moves between ticks (no platforms, doors or hulls), so
## the quarter probes may be reused across ticks. Off by default: a moving world makes a
## remembered answer wrong. Call [method invalidate_probe_cache] when the level changes.
var static_world := false:
	set(value):
		if value != static_world:
			_qf_valid = false
			_gp_valid = false
			_en_valid = false
			body.set_static_world(value)
		static_world = value


## Forgets the remembered quarter probe; for a level change under a [member static_world] motor.
func invalidate_probe_cache() -> void:
	_qf_valid = false
	_gp_valid = false
	_en_valid = false


func _copy_hit(from: DotFpsBody.Hit) -> DotFpsBody.Hit:
	var out := DotFpsBody.Hit.new()
	out.hit = from.hit
	out.fraction = from.fraction
	out.normal = from.normal
	out.point = from.point
	out.collider_id = from.collider_id
	out.depth = from.depth
	return out


var _qf_valid := false
var _qf_found := false
var _qf_centre := Vector3.ZERO
var _qf_probe := Vector3.ZERO
var _qf_height := 0.0
var _qf_radius := 0.0
var _qf_mask := 0
var _qf_hit: DotFpsBody.Hit = null


func _quadrant_floor_probe(centre: Vector3, probe: Vector3, height: float) -> DotFpsBody.Hit:
	var half := tunables.radius * 0.5
	for quarter: Vector2 in QUADRANTS:
		var offset := Vector3(quarter.x, 0.0, quarter.y).normalized() * half
		var hit := _sweep(centre + offset, probe, height, half)
		if hit.hit and _is_floor(hit.normal):
			return hit
	return DotFpsBody.Hit.miss()


## The collide-and-slide result to keep: the plain slide, or the stepped one when it got further.
func _prefer_step(
	state: DotFpsState, plain: MoveResult, motion: Vector3, height: float,
	walking: bool, hull_only: bool
) -> MoveResult:
	# Stepping is tried only when it could help: grounded, blocked, and not the tick a jump left the surface.
	# A step cannot travel further than the horizontal motion, so when the slide is already within the acceptance margin of it, skip its queries.
	if (
		walking and plain.blocked and tunables.step_height > 0.0
		and not hull_only
		and plain.travelled + tunables.skin_width * 2.0 + 1e-4
			< Vector2(motion.x, motion.z).length()
	):
		var stepped := _slide_with_step(state.position, state.velocity, motion, height)

		# Only if it got further, or a step that gains nothing but ends higher would ratchet the player up a wall.
		# And by more than a skin: raised to step height, the rounded bottom can slide a millimetre past a kerb's top corner that dropped back is inside the kerb's face.
		if stepped.travelled > plain.travelled + tunables.skin_width * 2.0:
			return stepped

	return plain


## Removes the lift a steep face added to a walker's velocity along the floor they stood on.
func _strip_steep_lift(
	state: DotFpsState, plain: MoveResult, velocity_in: Vector3, stood_on: Vector3, walking: bool
) -> void:
	# A walker is not lifted by a face they cannot stand on (`[steep-climb-1]`). The classic walk move zeroes the vertical before and after, so a walk never climbs.
	# Here only the lift the slide ADDED along the floor's normal goes, and only when a steep face did it; a walkable ramp's lift is the floor's own, and a jump never reaches this.
	# With the quarter probes in [method _categorise_ground] this is the other half; either alone still let a walker up a 70 degree face.
	if walking and plain.met_steep_face:
		var lift := state.velocity.dot(stood_on) - maxf(velocity_in.dot(stood_on), 0.0)
		if lift > 0.0:
			state.velocity -= stood_on * lift


## The result of one collide-and-slide.
class MoveResult extends RefCounted:
	var position: Vector3
	var velocity: Vector3
	var travelled: float = 0.0
	var blocked: bool = false
	## Iterations were exhausted with motion remaining: a wedge the slide gave up on.
	var ran_out: bool = false
	## The move stopped early because it met a plane it had already resolved against.
	## Not a failure, but the tick's remaining motion goes unspent. Counted apart from running out of iterations because telling the two apart is the point of counting either.
	var stopped_on_duplicate: bool = false
	## Whether the move met a face too steep to stand on that leans back toward the
	## sky. Sliding along one of those turns a push into a climb.
	var met_steep_face: bool = false


## Collide and slide: move, and on contact continue along the surface.
## Velocity is slid as well as motion, so running into a wall at an angle keeps the component along it, and the next tick starts from a velocity consistent with what happened.
## Every plane touched during one move is remembered and the direction must satisfy all of them; see [method _resolve_planes], which surf depends on.
func _slide(
	from: Vector3,
	velocity: Vector3,
	motion: Vector3,
	height: float
) -> MoveResult:
	var result := MoveResult.new()
	result.position = from
	result.velocity = velocity

	var start := from

	# The move is carried as direction-and-speed plus the fraction of the tick left, because crease resolution re-derives the direction from the ORIGINAL motion every bump.
	# Deriving it from the already-clipped vector makes the answer depend on the order planes were hit in.
	var current := motion
	var time_left := 1.0

	var planes: Array[Vector3] = []

	for _i in range(tunables.max_slide_iterations):
		var step := current * time_left

		if step.length_squared() <= 1e-12:
			break

		var centre := _capsule_centre(result.position, height)
		var hit := _sweep(centre, step, height)

		if not hit.hit:
			result.position += step
			time_left = 0.0
			break

		result.blocked = true
		if hit.normal.y > 0.0 and not _is_floor(hit.normal):
			result.met_steep_face = true

		# The skin gap is already deducted by _sweep, so this stops just short of the
		# surface rather than exactly on it.
		result.position += step * hit.fraction
		time_left -= time_left * hit.fraction

		if not tunables.crease_slide:
			current = current.slide(hit.normal)
			result.velocity = result.velocity.slide(hit.normal)
			continue

		var outcome := _remember_plane(planes, hit.normal)

		if outcome == PLANE_FULL:
			# A genuine five-plane corner: no direction out. Carrying on finds one that leaves the player inside the geometry.
			current = Vector3.ZERO
			result.velocity = Vector3.ZERO
			break

		if outcome == PLANE_DUPLICATE:
			# Spend the rest of the tick along the plane, a skin off it, and stop. The same plane again at the start of a leg is a capsule resting on it with a velocity already in it (a surfer pressed into a bank);
			# breaking there spent none of the tick, and the player hung in mid-air with its speed intact (697 of 1,786 ticks of one bank).
			# One leg, not a return to the loop: carrying on fills the plane list with near-copies and zeroes the velocity in a corner that is not there. The velocity is not touched.
			var rest := current * time_left + hit.normal * tunables.skin_width
			var clear := _sweep(_capsule_centre(result.position, height), rest, height)
			var spent := 1.0 if not clear.hit else clear.fraction
			result.position += rest * spent
			if spent > 1e-6:
				# Stopped part of the way along: in a wedge, by the other face, and the
				# rest of the tick goes along the crease instead of nowhere. Off a wedge
				# there is no other face and this changes nothing.
				if spent < 1.0:
					var _along := _leave_crease(
						result, planes, motion, velocity, time_left * (1.0 - spent),
						hit.normal, height
					)
				time_left = 0.0
				break
			# Still nothing: step off the face first, then go along it (`[arrive-3]`). A capsule exactly touching a face is blocked at the first bisection step by ANY move starting there, even one leaving it,
			# and a grazing contact leaves it there since the skin is taken along the motion, not the normal; a rider hung at 75 u/s for good. Lifted a millimetre, the same leg ran 40 cm clear.
			# A wedge first: when the face the queries keep naming is one of two the capsule is in, none of the legs below can leave it ([method _leave_crease]).
			if _leave_crease(result, planes, motion, velocity, time_left, hit.normal, height):
				time_left = 0.0
				break
			if _leave_face(result, current * time_left, hit.normal, height):
				time_left = 0.0
				break
			if _split_leg(result, current * time_left, height):
				time_left = 0.0
				break
			result.stopped_on_duplicate = true
			# The same plane again: the velocity is already resolved against it, so resolving again is a no-op and the loop would spin. Stop the move and KEEP the velocity.
			# Zeroing looks tidy but stops a player who starts a tick a millimetre inside a surf ramp (every spawn onto one, every correction) dead on a surface they should accelerate down.
			break

		current = _resolve_planes(planes, motion)
		result.velocity = _resolve_planes(planes, velocity)

	# Motion left over means the move did not complete, which is two things: the duplicate-plane break above leaves this state on purpose (time left, velocity kept),
	# while running out of iterations is a player wedged in geometry. Counting both in [member stuck_ticks] read 10% to 14% of ticks on imported maps and hid the real figure, one tick in fifteen thousand.
	# Raising max_slide_iterations from 5 to 20 moved it not at all, which is what separates them.
	if time_left > 1e-6 and current.length_squared() > 1e-12 and not result.stopped_on_duplicate:
		result.ran_out = true

	result.travelled = Vector3(
		result.position.x - start.x, 0.0, result.position.z - start.z
	).length()

	return result


## The duplicate-plane leg's last resort: lift straight off [param normal] by one, two, then four skins and spend [param leg] from there.
## True and [param result] moved if any got anywhere; false and untouched if none did, which leaves the old answer (stop, keep the velocity).
## Bounded on purpose: a wrong answer is a few millimetres of air that gravity takes back next tick.
func _leave_face(
	result: MoveResult, leg: Vector3, normal: Vector3, height: float
) -> bool:
	if tunables.skin_width <= 0.0 or leg.length_squared() <= 1e-12:
		return false

	for scale: float in [1.0, 2.0, 4.0]:
		var lift := normal * tunables.skin_width * scale
		var off := _sweep(_capsule_centre(result.position, height), lift, height)
		if off.hit:
			return false
		var from := result.position + lift
		var along := _sweep(_capsule_centre(from, height), leg, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6:
			result.position = from + leg * spent
			return true

	return false


## The duplicate-plane leg's answer in a wedge (`g2gfast-surf-crease-hang-1`): find the second face and spend the leg along the crease. True and [param result] moved if that got anywhere; false and untouched otherwise.
## A surfer in the V of two slabs sits in both and the rest query names one of two equal contacts; named the same face twice, the leg, the lift and the split all stop at fraction zero and the rider hangs.
## Asked before [method _leave_face] and [method _split_leg], because both can succeed by a hair there and the same ride would finish in different times.
func _leave_crease(
	result: MoveResult,
	planes: Array[Vector3],
	motion: Vector3,
	velocity: Vector3,
	time_left: float,
	normal: Vector3,
	height: float
) -> bool:
	if tunables.skin_width <= 0.0:
		return false

	# The face the queries are not naming. A skin or more off the one they do name, that one
	# is no longer touched and the rest query has only the other left to report.
	var other := Vector3.ZERO
	for scale: float in [1.0, 2.0, 4.0]:
		var probe := body.rest_contact(
			_capsule_centre(result.position + normal * tunables.skin_width * scale, height),
			height, tunables.radius
		)
		if probe.hit and probe.normal.dot(normal) < 0.999:
			other = probe.normal
			break

	if other == Vector3.ZERO:
		return false

	# Two faces almost back to back are a slot, not a crease: there is no lift off both.
	var c := normal.dot(other)
	if c < -0.9:
		return false

	var wedge: Array[Vector3] = planes.duplicate()
	if _remember_plane(wedge, other) == PLANE_FULL:
		return false

	var leg := _resolve_planes(wedge, motion) * time_left
	if leg.length_squared() <= 1e-12:
		return false

	# From where the capsule is first, and only then lifted off both faces at once (the lift that leaves each by a skin lies along their sum).
	# Unlifted first because a crease leg clear from here is the leg the slide takes when the query names the faces the other way round, so either answer rides the same line.
	var off_both := (normal + other) * (tunables.skin_width / (1.0 + c))
	for scale: float in [0.0, 1.0, 2.0, 4.0]:
		var lift := off_both * scale
		if scale > 0.0 and _sweep(_capsule_centre(result.position, height), lift, height).hit:
			continue
		var from := result.position + lift
		var along := _sweep(_capsule_centre(from, height), leg, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6 and (scale > 0.0 or not along.hit):
			result.position = from + leg * spent
			result.velocity = _resolve_planes(wedge, velocity)
			crease_leg_ticks += 1
			return true

	return false


## The duplicate-plane leg's very last resort (`[hns-door-wedge-1]`): spend [param leg]'s vertical part alone, or failing that its horizontal part alone. True and [param result] moved if either got anywhere.
## A rest query names one contact and with two touching it can be the wrong one (a wall corner with an open door panel: a normal square to the motion, which clips nothing). The panel cannot be added as a plane, so splitting asks nothing new of the world.
func _split_leg(result: MoveResult, leg: Vector3, height: float) -> bool:
	for part: Vector3 in [Vector3(0.0, leg.y, 0.0), Vector3(leg.x, 0.0, leg.z)]:
		if part.length_squared() <= 1e-12:
			continue
		var along := _sweep(_capsule_centre(result.position, height), part, height)
		var spent := 1.0 if not along.hit else along.fraction
		if spent > 1e-6:
			result.position += part * spent
			split_leg_ticks += 1
			return true

	return false


## Outcomes of [method _remember_plane]. The two failures need different answers.
const PLANE_ADDED := 0
const PLANE_DUPLICATE := 1
const PLANE_FULL := 2


## Adds [param normal] to the plane list.
## Near-duplicates are rejected because a long surf ramp yields a contact every few centimetres with a normal differing in the last bits, which would fill the list and hide the wall the player is caught on.
## A duplicate and a full list are told apart because the caller treats them differently: a duplicate is already satisfied, a full list is a corner.
func _remember_plane(planes: Array[Vector3], normal: Vector3) -> int:
	for existing in planes:
		if existing.dot(normal) > 0.999:
			return PLANE_DUPLICATE

	if planes.size() >= tunables.max_slide_planes:
		return PLANE_FULL

	planes.append(normal)
	return PLANE_ADDED


## A direction that satisfies every plane touched so far, or zero if there is none. This is why surf works.
## Clipping against one plane then the next does not leave both: at a seam of two shallow ramps the clipped vector points back into the other and the player stops dead. Take the first plane whose clip re-enters no other, else go along the crease (cross of the normals); three planes with no direction is a corner and stopping is correct.
## [param original] is the velocity or motion at the START of the move, never the clipped one; see [method _slide].
func _resolve_planes(planes: Array[Vector3], original: Vector3) -> Vector3:
	var count := planes.size()

	for i in range(count):
		var candidate := original.slide(planes[i])
		var clear := true

		for j in range(count):
			if j == i:
				continue
			# A small negative tolerance rather than zero: a direction exactly in a
			# plane reads as "entering" it about half the time in single precision,
			# and rejecting it sends a surfer to the crease branch on a flat ramp.
			if candidate.dot(planes[j]) < -1e-5:
				clear = false
				break

		if clear:
			return candidate

	# Every crease, not only the first two planes (`[hns-door-wedge-1]`). The classic slide stops dead at three planes, right for a corner with no way out and wrong for one with a way down:
	# a body hopping into a corner under a window met the side wall and two box edges, and the line where the wall and the upright edge meet (straight down) left all three.
	# A crease of two planes that also leaves every other one is a real way out; with two planes this is the old answer exactly.
	for i in range(count):
		for j in range(i + 1, count):
			var crease := planes[i].cross(planes[j])

			# Parallel planes — two faces of the same wall the player is sandwiched
			# between. There is no crease and no way through.
			if crease.length_squared() < 1e-12:
				continue

			crease = crease.normalized()
			var along := crease * crease.dot(original)
			var leaves := true

			for k in range(count):
				if k != i and k != j and along.dot(planes[k]) < -1e-5:
					leaves = false
					break

			if leaves:
				return along

	return Vector3.ZERO


## Whether there is a drop just in front of the player. For [member DotFpsTunables.edge_friction].
## Probed with a thin capsule offset past their radius: sweeping the full capsule would answer "no" for anybody standing against a wall, doubling the friction of every player in a corridor.
func _near_ledge(state: DotFpsState) -> bool:
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if horizontal.length_squared() < 1e-6:
		return false

	var ahead := (
		state.position
		+ horizontal.normalized()
		* (tunables.radius + tunables.edge_friction_reach)
	)

	var probe_radius := minf(0.05, tunables.radius * 0.25)
	var probe_height := probe_radius * 2.0
	var centre := ahead + Vector3.UP * (probe_height * 0.5 + 0.02)

	var hit := body.sweep(
		centre,
		Vector3.DOWN * tunables.edge_friction_drop,
		probe_height,
		probe_radius
	)

	return not hit.hit


## Up, across, down: the standard way to walk up a step without jumping.
## Done explicitly because [method CharacterBody3D.move_and_slide] needs the stateful move this motor avoids, and the down leg must land on a floor or the step is rejected rather than depositing the player on top of a wall.
func _slide_with_step(
	from: Vector3,
	velocity: Vector3,
	motion: Vector3,
	height: float
) -> MoveResult:
	var centre := _capsule_centre(from, height)

	# A step is measured from the floor, not the feet: a grounded player can be up to the probe's two centimetres above it, and a full lift from there clears a kerb that much taller than step_height.
	# One short query, and only on a tick the slide was blocked.
	var seat := _sweep(centre, Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02), height)
	var hover := 0.0
	if seat.hit:
		hover = maxf((tunables.skin_width * 2.0 + 0.02) * seat.fraction - tunables.skin_width, 0.0)
	var floor_y := from.y - hover
	var lift := Vector3.UP * (tunables.step_height - hover)

	# Up. If there is no room above, there is no step to take.
	var up := _sweep(centre, lift, height)
	if up.hit:
		var result := MoveResult.new()
		result.position = from
		result.velocity = velocity
		result.blocked = true
		return result

	var raised := from + lift

	# Across, horizontally only: keeping the vertical component would carry the
	# player's fall through the step and undo the lift.
	var horizontal := Vector3(motion.x, 0.0, motion.z)
	var across := _slide(raised, velocity, horizontal, height)

	# Down, by at least the lift. Landing higher than we started is a step up;
	# landing lower is walking off the far edge, which the ground snap then handles.
	var drop := Vector3.DOWN * (lift.y + tunables.skin_width)
	var landing := _sweep(_capsule_centre(across.position, height), drop, height)

	var result := MoveResult.new()
	result.velocity = across.velocity
	result.blocked = across.blocked

	# And what it lands on is at most step_height above the floor it left. Asked of every landing, not only the edge's:
	# a capsule coming down a quarter-metre short of a kerb meets the corner at about 41 degrees, which is a floor, and a 0.5 m kerb with step_height 0.45 was stepped onto.
	var too_high := landing.hit and landing.point.y - floor_y > tunables.step_height + tunables.skin_width

	if not landing.hit or too_high or not (
		_is_floor(landing.normal) or _floor_beyond_edge(landing, across.position, floor_y)
	):
		# Nothing to stand on up there. Refusing the step is important: accepting it
		# would leave the player floating at step height with no ground under them,
		# and the next tick would drop them back, once per tick, forever.
		result.position = from
		result.travelled = 0.0
		result.blocked = true
		return result

	result.position = across.position + drop * landing.fraction
	result.travelled = Vector3(
		result.position.x - from.x, 0.0, result.position.z - from.z
	).length()

	return result


## Whether a steep landing contact is the capsule's rounded bottom on the edge of a floor, rather than a steep face.
## The step's down leg reports the capsule's normal, not the kerb's (50 to 80 degrees from up at walking pace), so a thin probe just past the contact must find a floor at the contact's own height. A steep face answers no, so surf and walls are unaffected.
## And the floor must be within a step of where the step started ([param start_y]): the across leg rides the hemisphere up the corner, so without that any kerb answered yes (0.7 m at 7 m/s with step_height 0.45).
func _floor_beyond_edge(landing: DotFpsBody.Hit, feet: Vector3, start_y: float) -> bool:
	return _edge_floor_normal(landing, feet, start_y) != Vector3.ZERO


## The floor's own normal behind [method _floor_beyond_edge]'s answer, or
## [constant Vector3.ZERO] when there is none.
func _edge_floor_normal(landing: DotFpsBody.Hit, feet: Vector3, start_y: float) -> Vector3:
	if landing.point.y - start_y > tunables.step_height + tunables.skin_width:
		return Vector3.ZERO

	var outward := Vector3(landing.point.x - feet.x, 0.0, landing.point.z - feet.z)
	if outward.length_squared() < 1e-8:
		return Vector3.ZERO

	var probe_radius := minf(0.05, tunables.radius * 0.25)
	var probe_height := probe_radius * 2.0
	var at := landing.point + outward.normalized() * (probe_radius + 0.01)
	var centre := at + Vector3.UP * (probe_radius + 0.05)
	var hit := body.sweep(centre, Vector3.DOWN * 0.1, probe_height, probe_radius)

	if not hit.hit or not _is_floor(hit.normal):
		return Vector3.ZERO

	var bottom := centre.y - probe_radius + (-0.1 * hit.fraction)
	return hit.normal if absf(bottom - landing.point.y) < 0.02 else Vector3.ZERO


## Puts a grounded player back a skin clear of the floor [param hit] found, if closer than half of one. Straight up, never further than the skin.
## Exactly touching a floor is a state a horizontal sweep cannot move out of: cast_motion reports the floor as an obstacle to a HORIZONTAL move at fraction ~0 in about one position in five, so a runner spawned on a floor froze in front of every kerb.
## Every query here stops a skin short, so only a spawn at the floor's height gets there, and a grounded player is never snapped.
func _keep_skin(state: DotFpsState, hit: DotFpsBody.Hit, probe: Vector3) -> void:
	var gap := probe.length() * hit.fraction
	if gap < tunables.skin_width * 0.5 and hit.normal.y > 0.0:
		state.position.y += tunables.skin_width - gap


## The floor [param hit] puts the player on, or [constant Vector3.ZERO] if it is not one.
## A walkable contact is its own answer. A steep one is the capsule's rounded bottom on an edge and counts as the floor beyond it ([method _edge_floor_normal]), [b]only for a player moving onto that floor[/b].
## Otherwise the next tick read a kerb corner's normal as AIR and the air slide turned a run into a climb (1.07 m at 15 m/s over a 0.34 m kerb). Standing on, walking off or running along a ledge keep the capsule's answer.
func _standable_normal(state: DotFpsState, hit: DotFpsBody.Hit) -> Vector3:
	if not hit.hit:
		return Vector3.ZERO

	if _is_floor(hit.normal):
		return hit.normal

	var toward := Vector3(hit.point.x - state.position.x, 0.0, hit.point.z - state.position.z)
	var horizontal := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if horizontal.dot(toward) <= 0.0:
		return Vector3.ZERO

	if not static_world:
		return _edge_floor_normal(hit, state.position, state.position.y)
	# Remembered like [method _ground_probe]: the same landing point from the same feet.
	var mask := body.collision_mask
	if (_en_valid and hit.point == _en_point and state.position == _en_feet
			and mask == _en_mask and tunables.radius == _en_radius):
		return _en_normal
	var found := _edge_floor_normal(hit, state.position, state.position.y)
	_en_valid = true
	_en_point = hit.point
	_en_feet = state.position
	_en_mask = mask
	_en_radius = tunables.radius
	_en_normal = found
	return found


var _en_valid := false
var _en_point := Vector3.ZERO
var _en_feet := Vector3.ZERO
var _en_mask := 0
var _en_radius := 0.0
var _en_normal := Vector3.ZERO


## Pushes the capsule out of whatever it is inside along that surface's own normal. Returns whether it moved.
## The general form of [method _lift_clear]: straight up is right out of a floor and wrong out of a 60 degree ramp, and [method _lift_clear] is reached only for a player GROUNDED last tick, which a surfer never is.
## One query a tick per player: the cheaper [method DotFpsBody.overlaps] cannot tell a player resting on a floor from one buried in it.
func _depenetrate(state: DotFpsState, height: float) -> bool:
	var centre := _capsule_centre(state.position, height)
	var resting := body.rest_contact(centre, height, tunables.radius)

	if not resting.hit or resting.depth <= 0.0:
		return false

	# Out by the measured depth plus the skin every sweep expects, never further than a step per tick.
	# The clamp makes a wrong answer survivable: a degenerate normal moves a player a centimetre, unclamped against a deep penetration it throws them across the level. A deep embed climbs out over a few ticks.
	var push := minf(
		resting.depth + tunables.skin_width,
		maxf(tunables.step_height, tunables.skin_width * 2.0)
	)

	state.position += resting.normal * push
	depenetrated_ticks += 1

	return true


## Lifts a player who is inside geometry until they are not, and says whether it worked.
## Straight up and never further than a step: the player got here by sinking through a surface they stood on. Lifting further would be a teleport.
## The lift doubles each try (about nine overlap queries to cover a step, not hundreds), landing up to twice as high as needed; the next ground probe brings them back down. Deterministic: shape queries and arithmetic only.
func _lift_clear(state: DotFpsState, height: float) -> bool:
	var lift := maxf(tunables.skin_width * 2.0, 0.0005)
	var limit := maxf(tunables.step_height, lift)
	var moved := 0.0

	while moved < limit:
		moved = minf(moved + lift, limit)
		var centre := _capsule_centre(state.position + Vector3.UP * moved, height)

		if not body.overlaps(centre, height, tunables.radius):
			state.position.y += moved
			return true

		if moved >= limit:
			break

		lift *= 2.0

	return false


## Pulls the player back down onto ground they have just walked off the edge of, so walking down a ramp does not get air physics (no friction) one tick in a few.
## [param stood_on] is the floor at the start of the tick. Moving away from it means a launch the snap must not cancel; moving along it is a walk, and at a ramp's crest that walk still points upward.
func _snap_to_ground(
	state: DotFpsState,
	height: float,
	stood_on: Vector3 = Vector3.UP
) -> void:
	if state.velocity.dot(stood_on) > LEAVING_SPEED:
		return

	var centre := _capsule_centre(state.position, height)
	var probe := Vector3.DOWN * tunables.ground_snap_distance

	var hit := _sweep(centre, probe, height)

	# The same quarters as [method _categorise_ground], for the same capsule: pressed
	# against a face that leans back, the whole capsule's probe meets the face and the
	# snap gave up with the floor a couple of centimetres under the player.
	if hit.hit and not _is_floor(hit.normal):
		hit = _quadrant_floor(centre, probe, height)

	if not hit.hit or not _is_floor(hit.normal):
		return

	# Over a crest, still carrying the climb, and fast enough: a launch, not a snap. Left in
	# the air with every bit of its speed (`crest_launch_speed_scale`).
	if (
		tunables.crest_launch_speed_scale > 0.0
		and state.velocity.dot(hit.normal) > LEAVING_SPEED
		and state.velocity.length() >= tunables.max_speed * tunables.crest_launch_speed_scale
	):
		return

	state.position += probe * hit.fraction
	state.mode = DotFpsState.Mode.GROUND
	state.ground_normal = hit.normal
	state.ground_id = hit.collider_id

	# Downward velocity accumulated while briefly airborne is discarded, or the next tick sees a fast descent and un-grounds again (the flicker).
	# Upward velocity belongs to whatever launched the player and is not ours to cancel.
	if state.velocity.y < 0.0:
		state.velocity.y = 0.0
	elif state.velocity.dot(hit.normal) > LEAVING_SPEED:
		# Walked over a crest, still carrying the ramp's climb. Laid along the floor they
		# have been put on, or the next tick reads that climb as leaving it.
		state.velocity = state.velocity.slide(hit.normal)


## Moves the player by its velocity for one tick, colliding and sliding.
## Exposed so a [DotFpsMoveMode] gets the same skin-margin and step handling without re-implementing collide-and-slide.
## [param step] enables stair stepping; a swimming or flying mode wants it off.
func move_and_slide(
	state: DotFpsState,
	delta: float,
	step: bool = false
) -> void:
	var height := _height(state)
	var motion := state.velocity * delta

	if motion.length_squared() <= 0.0:
		return

	var result := _native_move(state.position, state.velocity, motion, height, 1, step)
	if result == null:
		result = _slide(state.position, state.velocity, motion, height)

		if step and result.blocked and tunables.step_height > 0.0:
			var stepped := _slide_with_step(state.position, state.velocity, motion, height)
			if stepped.travelled > result.travelled + tunables.skin_width * 2.0:
				result = stepped

	state.position = result.position
	state.velocity = result.velocity

	if result.ran_out:
		stuck_ticks += 1


## A swept capsule query with the skin margin applied, in world space.
## [param from] is the player's feet, not the capsule centre, the same convention as [member DotFpsState.position].
func probe(
	state: DotFpsState,
	from: Vector3,
	motion: Vector3
) -> DotFpsBody.Hit:
	var height := _height(state)
	return _sweep(_capsule_centre(from, height), motion, height)


## Whether the player's capsule would overlap anything at [param feet].
func would_overlap(state: DotFpsState, feet: Vector3) -> bool:
	var height := _height(state)
	return body.overlaps(_capsule_centre(feet, height), height, tunables.radius)


## [method _slide] then [method _prefer_step] (mode 0, [param flag] walking) or the slide and step of [method move_and_slide]
## (mode 1, [param flag] step) in one native call, when the body runs one ([method DotFpsBody.native_slide]); null to run them here.
## The native slide is this script's to the bit (GameSpice Sim's motor parity suite), so a web client running the script agrees.
func _native_move(
	from: Vector3, velocity: Vector3, motion: Vector3, height: float, mode: int, flag: bool
) -> MoveResult:
	var tun := PackedFloat64Array([
		tunables.max_slide_iterations, 1.0 if tunables.crease_slide else 0.0, tunables.skin_width,
		tunables.max_slide_planes, tunables.step_height, tunables.radius, tunables.max_slope_radians(),
	])
	var r := body.native_slide(from, velocity, motion, height, mode, flag, tun)
	if r.size() < 13:
		return null
	var m := MoveResult.new()
	m.position = Vector3(r[0], r[1], r[2])
	m.velocity = Vector3(r[3], r[4], r[5])
	m.travelled = r[6]
	var flags := int(r[7])
	m.blocked = flags & 1 != 0
	m.ran_out = flags & 2 != 0
	m.stopped_on_duplicate = flags & 4 != 0
	m.met_steep_face = flags & 8 != 0
	crease_leg_ticks += int(r[8])
	split_leg_ticks += int(r[9])
	return m
