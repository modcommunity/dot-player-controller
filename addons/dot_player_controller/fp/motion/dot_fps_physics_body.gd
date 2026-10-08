class_name DotFpsPhysicsBody
extends DotFpsBody

## [DotFpsBody] backed by Godot's 3D physics server. The implementation a game uses.
##
## Queries go through [PhysicsDirectSpaceState3D] with a capsule shape the motor
## sizes per call, rather than through the player's own [CollisionShape3D]. That
## matters more than it looks: the motor asks "would I fit standing up here" and
## "what is under my feet" with sizes and at positions the body does not currently
## have, and resizing the real collider to answer would make every query a mutation
## of the thing being measured.
##
## The shape is allocated once and reused. A [ConvexPolygonShape3D] rebuilt per query
## would allocate several times per tick per player, which on a 32-slot server is the
## largest single cost in the movement code.

const CHANNEL := "fps.body"

var _space: PhysicsDirectSpaceState3D = null
var _shape: CapsuleShape3D = CapsuleShape3D.new()

var _motion_params := PhysicsTestMotionParameters3D.new()
var _shape_params := PhysicsShapeQueryParameters3D.new()

## Queries run this tick. Reset by the controller; watched by the server operator.
var query_count: int = 0


static func for_node(node: Node3D) -> DotFpsPhysicsBody:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var body := new()
	body.bind(node)
	return body


## Binds to the physics space [param node] lives in.
##
## Re-binding on every tick would be wasteful, but the space handle is invalidated by
## a scene change, so [method is_bound] is checked before use rather than assumed.
func bind(node: Node3D) -> DotResult:
	if node == null or not node.is_inside_tree():
		return DotResult.fail(
			DotError.CODE_STATE,
			"DotFpsPhysicsBody needs a node inside the tree."
		)

	_owner = node
	_space = node.get_world_3d().direct_space_state

	if _space == null:
		return DotResult.fail(
			DotError.CODE_STATE, "No physics space is available yet."
		)

	_shape_params.shape = _shape
	_shape_params.collide_with_bodies = true
	_shape_params.collide_with_areas = false

	return DotResult.success(null)


func is_bound() -> bool:
	return _space != null


func _configure(height: float, radius: float) -> void:
	_shape.radius = radius
	# Godot's capsule height is the total including both hemispherical caps, and it
	# silently clamps to 2 * radius. DotFpsTunables.validate() rejects a configuration
	# that would hit that clamp, because a collider a different size from the one the
	# simulation thinks it has is unfindable from the symptom.
	_shape.height = maxf(height, radius * 2.0)

	_shape_params.collision_mask = collision_mask
	_shape_params.exclude = exclude


## The node this body was bound to, so a stale space can be recovered.
var _owner: Node3D = null


## Re-binds to the node's current space. Returns whether a space is available.
##
## The space handle is fetched once and cached because it is read several times per
## tick, but it does not survive a scene change — and a body holding a dead handle
## answers every query with "nothing there", which reads as the player falling
## through a level that is definitely loaded. Cheaper to re-fetch on the first miss
## than to debug that once.
func revalidate() -> bool:
	if _owner == null or not _owner.is_inside_tree():
		return false

	var space := _owner.get_world_3d().direct_space_state

	if space == null:
		return false

	if space != _space:
		_space = space
		_shape_params.shape = _shape
		DotLog.debug(CHANNEL, "re-bound to a new physics space")

	return true


## How much deeper than `unsafe` [method sweep] looks for a contact the first rest query
## missed, in metres. A skin is 1 cm in every game here; these stay well inside it.
const CONTACT_RETRY_DEPTHS: Array[float] = [0.001, 0.002, 0.004]

## How deep `unsafe` may be before [method sweep] treats the sweep's contact as late, in
## metres. cast_motion's own bisection leaves `unsafe` a fraction of a millimetre in.
const LATE_CONTACT_DEPTH := 0.0005


func sweep(
	from: Vector3,
	motion: Vector3,
	height: float,
	radius: float
) -> Hit:
	var result := Hit.miss()

	if _space == null and not revalidate():
		return result

	# A zero-length sweep has no direction to report a normal against, and the
	# physics server's answer for one is not meaningful. The motor never needs it —
	# it uses overlaps() for that question.
	if motion.length_squared() <= 0.0:
		return result

	_configure(height, radius)
	query_count += 1

	_shape_params.transform = Transform3D(Basis.IDENTITY, from)
	_shape_params.motion = motion

	# cast_motion returns [safe, unsafe]: the last fraction with no contact and the
	# first with one. `safe` is what we move by; `unsafe` is where the normal is
	# sampled, because at `safe` the shapes are not yet touching and there is no
	# contact to report.
	var fractions := _space.cast_motion(_shape_params)

	if fractions.is_empty():
		return result

	var safe: float = fractions[0]
	var unsafe: float = fractions[1]

	if safe >= 1.0:
		# Nothing along the sweep. That is two different worlds and they need
		# different answers: genuinely open space, or a collider the sweep refuses to
		# see because the capsule is already inside it. Ask the resting question
		# before the ray, because a ramp underfoot answers the ray badly and this
		# exactly.
		var resting := _blocking_rest_contact(from, motion, height, radius)

		if resting.hit:
			return resting

		var below := _downward_ray_fallback(from, motion, height)

		if below.hit:
			return below

		return _end_overlap_fallback(from, motion, height, radius)

	result.hit = true
	result.fraction = clampf(safe, 0.0, 1.0)

	_shape_params.transform = Transform3D(
		Basis.IDENTITY, from + motion * unsafe
	)
	_shape_params.motion = Vector3.ZERO

	var contacts := _space.get_rest_info(_shape_params)

	if contacts.is_empty():
		# Contact at `unsafe` but no rest info: the shapes are touching to within
		# floating point but not overlapping. [b]Ask again a few millimetres deeper
		# before guessing[/b], because the guess is expensive. Sliding along the
		# motion's own reverse does not "only cost a tick of movement", as this used
		# to say: the motor clips the VELOCITY against the normal too, and a velocity
		# parallel to the motion clipped against its own reverse is zero. A surfer
		# grazing a bank at 254 u/s stopped dead in mid-air on one such tick and hung
		# there for good (`[bank-hang-1]`, game-g2gfast surf_g2g_intro bonus 1, line
		# +48); one millimetre further along, the same query reports the bank's own
		# normal.
		var along := motion.normalized()
		for depth: float in CONTACT_RETRY_DEPTHS:
			_shape_params.transform = Transform3D(
				Basis.IDENTITY, from + motion * unsafe + along * depth
			)
			contacts = _space.get_rest_info(_shape_params)
			if not contacts.is_empty():
				break

	if contacts.is_empty() and motion.normalized().dot(Vector3.DOWN) >= 0.7:
		# [b]Downward, the guess below is a floor made of nothing[/b]
		# (`[jumping-into-crate-1]`, 2026-10-02). A capsule GRAZING a vertical face --
		# beside it, a hair from it, moving down -- makes cast_motion report a contact
		# that no rest query along the motion can name, and the motion's reverse is then
		# straight UP: a perfect floor. A runner jumping beside a crate stack whose upper
		# crate sat 2 cm proud of the face was put on the ground by the crate's SIDE at
		# the jump's apex, jumped again from there, and went up the stack a crate at a time
		# (mg-buses-from-hell; the 2026-09-26 "jumping reached 2.98 m" on a 3 m stack).
		# The ray down the axis is the honest question for a floor: it answers a floor
		# under the player, and a face beside them is not one. Nothing under the axis is
		# a graze, and a graze does not stop a fall.
		return _downward_ray_fallback(from, motion, height)

	if contacts.is_empty():
		# [b]Still nothing: ask where the move ENDS, not what it grazed[/b]
		# (`[fps-face-edge-stop]`, 2026-10-02). This used to answer with the reverse of
		# the motion, which "cannot let the player through" -- and which the motor clips
		# the velocity against, and a velocity clipped against its own reverse is zero.
		# A surfer leaving a rolled, pitched face over its far END grazes the edge
		# between its top and end faces: cast_motion reports a contact, and no rest
		# query along the motion can name it, because the motion is leaving it. Every
		# rider at 30 m/s off a 56/7 degree slab's end stopped dead in mid-air and fell
		# from rest (surf_physics_selftest's last section).
		#
		# A rest query that finds nothing at `unsafe` or a few millimetres past it means
		# the capsule touches without overlapping there, so nothing thin sits in the
		# path. What can still be wrong is the end of the move, and that is the question
		# _end_overlap_fallback already answers for a sweep that saw nothing at all: a
		# surface the move ends inside and goes into, backed off by its depth; clear
		# space or a surface being left, a miss.
		return _end_overlap_fallback(from, motion, height, radius)

	result.normal = contacts.get("normal", -motion.normalized())
	result.point = contacts.get("point", from + motion * safe)
	result.collider_id = int(contacts.get("collider_id", 0))

	# A degenerate normal makes every downstream slide produce NaN, and NaN in a
	# position is unrecoverable — it survives every clamp and propagates to the
	# replicated transform. Cheaper to check here than to find later.
	if not result.normal.is_normalized():
		result.normal = -motion.normalized()
		return result

	# The rest query at `unsafe` is the one [method rest_contact] makes, and its normal
	# can come back reversed the same way. Reversed here, the slide clips the velocity
	# INTO the face it met. The depth is borrowed only for the check: a sweep reports none.
	var at_contact := from + motion * unsafe
	result.depth = maxf(result.normal.dot(result.point - (at_contact - result.normal
		* DotFpsBody.capsule_support(result.normal, height, radius))), 0.0)
	_turn_round_flipped(result, at_contact, height, radius)
	result.depth = 0.0

	# [b]A contact reported late.[/b] Against a large convex, cast_motion's `safe` can be
	# centimetres past the real contact (`[sweep-1]`: a 40 m wall let a capsule 5 cm
	# into it, a 164 m wall 11 cm). The rest query at `unsafe` knows how deep `unsafe`
	# is, from the same numbers [method rest_contact] uses. So when that is more than a
	# rounding error, back off by that depth over the rate of approach.
	var approach := -motion.dot(result.normal)
	if approach > 1e-9:
		var at_unsafe := from + motion * unsafe
		var deepest := at_unsafe - result.normal * DotFpsBody.capsule_support(
			result.normal, height, radius)
		var depth := result.normal.dot(result.point - deepest)
		if depth > LATE_CONTACT_DEPTH:
			result.fraction = clampf(minf(result.fraction, unsafe - depth / approach), 0.0, 1.0)

	return result


## A ray down the capsule's own axis, for when [method PhysicsDirectSpaceState3D.cast_motion]
## refuses to see the floor.
##
## [b]cast_motion skips any collider it believes the shape already overlaps at the
## start of the sweep[/b] — "ignore objects it's inside of", in the engine's own words
## — and that judgement comes out of the GJK distance solver. Against a very large
## convex it is not reliable: measured on 4.7.2 against a 164 m plate, a capsule
## resting 4.5 mm above the floor was reported as free space by a 22 mm downward
## sweep, while a ray through the same gap on the same tick found the floor at y = 0.
## Lifting the start of the sweep does not fix it — the answer flips between hit and
## miss with no threshold, because it is a convergence failure rather than a margin.
##
## The consequence is the worst one this code has: the ground probe misses, the player
## is declared airborne on a floor they are standing on, they sink, and once they are
## inside the geometry every subsequent query starts embedded and answers nothing. They
## leave the level at a constant rate. That is exactly how [code]pg_lobby[/code]'s 164 m
## plate behaved in game-playground.
##
## A ray is analytic against every primitive and has no such failure mode. It is used
## only as a second opinion when the sweep saw nothing at all, so it can never make the
## motor collide with less than it did before.
##
## [b]Downward motion only, and the restriction is not laziness.[/b] The ray runs down
## the capsule's axis from its lowest point, so on a floor the distance it reports IS
## the capsule's contact distance. Sideways, the axis is [member DotFpsTunables.radius]
## behind the leading edge, so the same trick would report a wall late and embed the
## player in it. A wall is [method _end_overlap_fallback]'s, and a wall reported late
## is handled in [method sweep] itself.
func _downward_ray_fallback(
	from: Vector3, motion: Vector3, height: float
) -> Hit:
	var result := Hit.miss()
	var length := motion.length()

	if length <= 0.0 or _space == null:
		return result

	var direction := motion / length

	if direction.dot(Vector3.DOWN) < 0.7:
		return result

	# The capsule's lowest point, which is what a downward sweep is asking about.
	var foot := from - Vector3.UP * (height * 0.5)

	var query := PhysicsRayQueryParameters3D.create(foot, foot + motion)
	query.collision_mask = collision_mask
	query.exclude = exclude
	query.collide_with_areas = false
	query_count += 1

	var contact: Dictionary = _space.intersect_ray(query)

	if contact.is_empty():
		return result

	var point: Vector3 = contact.get("position", foot)

	result.hit = true
	result.fraction = clampf(foot.distance_to(point) / length, 0.0, 1.0)
	result.normal = contact.get("normal", Vector3.UP)
	result.point = point
	result.collider_id = int(contact.get("collider_id", 0))

	if not result.normal.is_normalized():
		result.normal = Vector3.UP

	return result


## Where the sweep said "nothing", whether the capsule would END inside something it is
## moving into, and if so how far back along the motion it stops touching it.
##
## [b]The sideways half of [method _downward_ray_fallback]'s problem (`[sweep-1]`).[/b]
## cast_motion's misjudgement is not only downward: measured on 4.7.2, a capsule 0 to
## 6 mm off a 164 m wall and swept 1 to 12 cm into it was reported free on 299 of 3,000
## sweeps, the worst ending 11 cm inside it (40 m wall: 5 cm; 4 m wall: under a
## millimetre). A ray cannot answer this one, because the axis is a radius behind the
## leading edge. The overlap at the end can: at centimetres of depth there is no
## convergence question, and [method rest_contact]'s depth is exact along its normal.
## So the fraction is backed off by that depth over the motion's rate of approach.
##
## Like the ray, it only runs when the sweep saw nothing, and it only ever reports a
## surface the motion is driving into, so it can never make the motor collide with less.
func _end_overlap_fallback(
	from: Vector3, motion: Vector3, height: float, radius: float
) -> Hit:
	var end := rest_contact(from + motion, height, radius)

	if not end.hit:
		return Hit.miss()

	var approach := -motion.dot(end.normal)

	# Moving along it or out of it: a floor underfoot, or a surface being left.
	if approach <= 1e-9 or end.depth <= 0.0:
		return Hit.miss()

	var result := Hit.miss()
	result.hit = true
	result.fraction = clampf(1.0 - end.depth / approach, 0.0, 1.0)
	result.normal = end.normal
	result.point = end.point
	result.collider_id = end.collider_id
	return result


## A [method rest_contact] filtered to surfaces this motion would drive further into.
##
## [b]The filter is the whole safety of the change.[/b] A capsule that is inside
## something is usually also trying to get out of it — the tick after a push, a step
## up onto a ledge, a crouch under a lip — and reporting a contact whose normal the
## motion is already moving away from would stop that move dead at fraction 0 and pin
## the player against the surface they were escaping. Only a surface being entered
## blocks; one being left is not this query's business.
func _blocking_rest_contact(
	from: Vector3, motion: Vector3, height: float, radius: float
) -> Hit:
	var resting := rest_contact(from, height, radius)

	if not resting.hit or motion.dot(resting.normal) >= 0.0:
		return Hit.miss()

	return resting


func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	var result := _raw_rest_contact(at, height, radius)

	if not result.hit:
		return result

	_turn_round_flipped(result, at, height, radius)
	return result


## Turns [param result] round when its normal points into the surface it came from.
## Shared by [method rest_contact] and [method sweep], which read the same engine answer.
func _turn_round_flipped(result: Hit, at: Vector3, height: float, radius: float) -> void:

	# [b]A contact normal can come back pointing INTO the surface the capsule rests on
	# (`[ramp-pop-1]`, 2026-10-08).[/b] A rider on game-g2gfast's surf_mesa, a skin off a
	# ramp brush and not moving between the two queries, was reported clear on one tick
	# and on the next 57 units deep along the face's exact reverse: the same contact
	# point, the normal flipped. Depth is measured along the normal, so a flipped normal
	# turns a resting contact into an embed of nearly the capsule's whole thickness, and
	# [method DotFpsMotor._depenetrate] pushed the player a full step INTO the ramp; the
	# next tick measured the real 18-unit overlap and pushed them back out. A two-tick dip
	# that a recording shows as one frame of the view jumping off the face and back, many
	# times a ride -- "the ramps are jumpy". It fired on 231 of 270 rides in
	# game-g2gfast's tools/ramp_bump_probe.
	#
	# The tell is that the capsule's centre lies past the contact plane: depth over the
	# support along the normal. A real resting contact never does that, and the reversed
	# normal then measures [code]2 * support - depth[/code], a shallow contact. But a
	# genuine embed of more than half the capsule does too, and there the engine's normal
	# is the right way out. So the reversed answer is TRIED, not assumed: kept only when
	# the capsule moved out along it is clear of whatever it touched.
	#
	# No upper bound on the depth, and the reversed depth floors at zero: the flipped
	# reports measured a few millimetres PAST the whole capsule (56.99 units against a
	# 56.8 span), because the contact point sits inside the shapes' margin. The probe below
	# is what tells a flip from a capsule really buried behind a face, at any depth.
	var support := DotFpsBody.capsule_support(result.normal, height, radius)

	if result.depth <= support:
		return

	var reversed_depth := maxf(support * 2.0 - result.depth, 0.0)
	var probe := at - result.normal * (reversed_depth + FLIP_CHECK_CLEARANCE)
	var after := _raw_rest_contact(probe, height, radius)

	if after.hit and after.depth > FLIP_CHECK_CLEARANCE:
		return

	result.normal = -result.normal
	result.depth = reversed_depth
	flipped_normals += 1


## How clear the capsule has to be, moved out along a reversed normal, for the reversal
## to be believed. Half a millimetre: well inside any skin a motor keeps, and well above
## the noise of a resting contact.
const FLIP_CHECK_CLEARANCE := 0.0005

## Rest contacts whose normal came back pointing into the surface and was turned round.
## See [method rest_contact]. Non-zero on any imported map with sloped brushes; a count
## that is zero where riders are depenetrating every tick is this check not running.
var flipped_normals: int = 0


## One [method PhysicsDirectSpaceState3D.get_rest_info], taken as the engine reports it.
func _raw_rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	var result := Hit.miss()

	if _space == null and not revalidate():
		return result

	_configure(height, radius)
	query_count += 1

	_shape_params.transform = Transform3D(Basis.IDENTITY, at)
	_shape_params.motion = Vector3.ZERO

	var contact: Dictionary = _space.get_rest_info(_shape_params)

	if contact.is_empty():
		return result

	var normal: Vector3 = contact.get("normal", Vector3.ZERO)

	# Unlike the sweep, there is no motion here to fall back on for a direction, so a
	# degenerate normal has no safe substitute and the honest answer is "no contact".
	# Reporting a made-up one would push the player somewhere arbitrary.
	if not normal.is_normalized():
		return Hit.miss()

	var point: Vector3 = contact.get("point", at)

	# How far the capsule's deepest point along -normal lies past the contact point.
	# Measured against get_rest_info's own point rather than against a shape query,
	# and checked to 4 decimal places at depths from 0 to 1 m on 4.7.2.
	var deepest := at - normal * DotFpsBody.capsule_support(normal, height, radius)

	result.hit = true
	result.fraction = 0.0
	result.normal = normal
	result.point = point
	result.collider_id = int(contact.get("collider_id", 0))
	result.depth = maxf(normal.dot(point - deepest), 0.0)

	return result


func overlaps(at: Vector3, height: float, radius: float) -> bool:
	if _space == null and not revalidate():
		return false

	_configure(height, radius)
	query_count += 1

	_shape_params.transform = Transform3D(Basis.IDENTITY, at)
	_shape_params.motion = Vector3.ZERO

	# One result is enough — the question is "is anything there", not "what".
	return not _space.intersect_shape(_shape_params, 1).is_empty()


func describe() -> Dictionary:
	var out := super.describe()
	out["bound"] = is_bound()
	out["queries"] = query_count
	return out
