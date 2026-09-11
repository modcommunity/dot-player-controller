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
	var body := DotFpsPhysicsBody.new()
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
		return result

	result.hit = true
	result.fraction = clampf(safe, 0.0, 1.0)

	_shape_params.transform = Transform3D(
		Basis.IDENTITY, from + motion * unsafe
	)
	_shape_params.motion = Vector3.ZERO

	var contacts := _space.get_rest_info(_shape_params)

	if contacts.is_empty():
		# Contact at `unsafe` but no rest info: the shapes are touching to within
		# floating point but not overlapping. Treating it as a miss would let the
		# player through; sliding along the motion's own reverse is the conservative
		# answer and only ever costs a tick of movement.
		result.normal = -motion.normalized()
		result.point = from + motion * safe
		return result

	result.normal = contacts.get("normal", -motion.normalized())
	result.point = contacts.get("point", from + motion * safe)
	result.collider_id = int(contacts.get("collider_id", 0))

	# A degenerate normal makes every downstream slide produce NaN, and NaN in a
	# position is unrecoverable — it survives every clamp and propagates to the
	# replicated transform. Cheaper to check here than to find later.
	if not result.normal.is_normalized():
		result.normal = -motion.normalized()

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
