class_name DotFpsFlatBody
extends DotFpsBody

## A [DotFpsBody] made of analytic planes and boxes, with no physics server.
##
## [b]This exists so the movement can be tested at all.[/b] The determinism the
## netcode depends on — replaying a command sequence reproduces the simulation
## exactly — is a property of [DotFpsMotor], not of Godot's physics. Testing it
## against a real world means a scene, physics ticks, and a frame of latency per
## query, and a failure could be the motor or could be the physics server. Here it
## is arithmetic: the test runs headless in milliseconds and a failure has one cause.
##
## It is also a working example of implementing [DotFpsBody] against geometry that is
## not Godot collision shapes, which is what a game with a heightfield or a BSP would
## do.
##
## Not a general collision engine. It handles axis-aligned boxes, an infinite ground
## plane and arbitrary half-space planes, treats the capsule as a swept box, and is
## meant for tests and grey-box prototyping.
##
## The half-space planes are what surf is tested against. A surf ramp is a single
## large sloped face and nothing about it needs a physics world — see
## [method add_ramp].

## Ground plane height. Set to -INF for no floor.
var floor_y: float = 0.0

## Axis-aligned solid boxes, in world space.
var boxes: Array[AABB] = []

## Solid half-spaces: everything BEHIND each plane is solid.
##
## Godot's [Plane] is [code]normal · x = d[/code] with the normal pointing out of the
## solid, which is the same convention [member DotFpsBody.Hit.normal] uses, so a hit
## reports the plane's normal unchanged.
##
## Infinite, deliberately. A surf ramp in a real map is bounded, but a bounded one
## here would need a convex-hull sweep to test the thing these exist to test — that a
## player sliding down a steep face keeps their speed, and that two faces meeting at a
## seam do not stop them. Both are properties of the faces, not of where they end.
var planes: Array[Plane] = []

## Synthetic collider id reported for the ground plane.
##
## Not a real instance id — there is no node here — but [DotFpsMotor] resolves the
## surface under the player from whatever the hit reports, so a body that reported
## nothing made surfaces untestable without a physics world. Boxes get
## [code]BOX_ID_BASE + index[/code].
const FLOOR_ID := 1
const BOX_ID_BASE := 2

## Planes are numbered downward from a high base so they never collide with box ids.
const PLANE_ID_BASE := 100000


## The collider id this body reports for the box at [param index].
static func box_id(index: int) -> int:
	return BOX_ID_BASE + index


static func with_floor(y: float = 0.0) -> DotFpsFlatBody:
	var b := DotFpsFlatBody.new()
	b.floor_y = y
	return b


func add_box(box: AABB) -> DotFpsFlatBody:
	boxes.append(box.abs())
	return self


## Adds a step of [param height] at [param at], for testing stair climbing.
func add_step(at: Vector3, size: Vector3) -> DotFpsFlatBody:
	return add_box(AABB(at, size))


## The collider id this body reports for the plane at [param index].
static func plane_id(index: int) -> int:
	return PLANE_ID_BASE + index


func add_plane(plane: Plane) -> DotFpsFlatBody:
	planes.append(plane)
	return self


## Adds a surf ramp: a face through [param through], tilted [param angle_degrees]
## from horizontal, falling away toward [param fall].
##
## [param fall] is the horizontal direction the ramp descends in, which is the
## direction a player on it slides. An angle above
## [member DotFpsTunables.max_slope_angle] is a ramp; below it, it is a hill the
## player can walk up, and the distinction is the whole of surf.
##
## The surface height along the fall direction is
## [code]through.y - tan(angle) * distance[/code], which is what a test needs to place
## a player just above it. See [method ramp_height].
func add_ramp(
	through: Vector3,
	fall: Vector3,
	angle_degrees: float
) -> DotFpsFlatBody:
	var horizontal := Vector3(fall.x, 0.0, fall.z)

	if horizontal.length_squared() < 1e-9:
		horizontal = Vector3.FORWARD

	horizontal = horizontal.normalized()

	# Tilt the up vector TOWARD the fall direction by the ramp angle. At 0° the normal
	# is straight up and the face is a floor; at 90° it is a wall.
	#
	# Toward, not away: a surface descending along `fall` has its height decreasing in
	# that direction, so its gradient points backwards and its normal leans forwards.
	# The other sign builds a ramp that rises where it was asked to fall, which a
	# test then places its player 20 metres underneath.
	var radians := deg_to_rad(angle_degrees)
	var normal := (
		Vector3.UP * cos(radians) + horizontal * sin(radians)
	).normalized()

	return add_plane(Plane(normal, normal.dot(through)))


## Height of the plane at [param index] directly above [param at].
##
## For placing something on a ramp without re-deriving the plane equation at the call
## site — which is where the sign of the tilt gets lost.
func ramp_height(index: int, at: Vector3) -> float:
	var plane := planes[index]

	if absf(plane.normal.y) < 1e-6:
		return INF

	return (
		plane.d - plane.normal.x * at.x - plane.normal.z * at.z
	) / plane.normal.y


## The capsule as an axis-aligned box. [param at] is the centre.
func _bounds(at: Vector3, height: float, radius: float) -> AABB:
	var half := Vector3(radius, height * 0.5, radius)
	return AABB(at - half, half * 2.0)


func sweep(
	from: Vector3,
	motion: Vector3,
	height: float,
	radius: float
) -> Hit:
	var result := Hit.miss()

	if motion.length_squared() <= 0.0:
		return result

	var best := 1.0
	var best_normal := Vector3.UP
	var best_id := 0
	var found := false

	# Ground plane. Only blocks downward motion — a plane the player is under is not
	# something this body models.
	if motion.y < 0.0 and floor_y > -INF:
		var feet := from.y - height * 0.5

		# [b]Feet already at or below the floor contact immediately[/b] rather than
		# being treated as a miss. That is not just robustness: [Vector3] components
		# are 32-bit while GDScript arithmetic is 64-bit, so a player standing
		# exactly on y = 0 has feet at -2.4e-8 once the centre has made the round
		# trip through a Vector3. Requiring feet > floor_y made every ground probe
		# miss, so nothing was ever grounded — friction and ground acceleration
		# never ran, the player capped at the air-control speed, and they sank
		# through the floor at a fixed rate. One epsilon, four symptoms, none of
		# which pointed here.
		var t := 0.0
		if feet > floor_y:
			t = (floor_y - feet) / motion.y

		if t < best:
			best = t
			best_normal = Vector3.UP
			best_id = FLOOR_ID
			found = true

	var start := _bounds(from, height, radius)

	for index in range(boxes.size()):
		var slab := _slab_sweep(start, motion, boxes[index])
		if slab.x < 0.0 or slab.x >= best:
			continue
		best = slab.x
		best_normal = _axis_normal(int(slab.y), motion)
		best_id = box_id(index)
		found = true

	for index in range(planes.size()):
		var t := _plane_sweep(from, motion, height, radius, planes[index])
		if t < 0.0 or t >= best:
			continue
		best = t
		best_normal = planes[index].normal
		best_id = plane_id(index)
		found = true

	if not found:
		return result

	result.hit = true
	result.fraction = clampf(best, 0.0, 1.0)
	result.normal = best_normal
	result.collider_id = best_id
	result.point = from + motion * result.fraction
	return result


## Swept-AABB against a static box. Returns (entry fraction, axis), or x < 0 for a
## miss. The standard slab method.
func _slab_sweep(start: AABB, motion: Vector3, box: AABB) -> Vector2:
	var entry := -INF
	var exit_t := INF
	var axis := -1

	for i in range(3):
		var a_min: float = start.position[i]
		var a_max: float = start.position[i] + start.size[i]
		var b_min: float = box.position[i]
		var b_max: float = box.position[i] + box.size[i]
		var d: float = motion[i]

		if absf(d) < 1e-9:
			# Parallel on this axis: no crossing, so it can only ever be a miss.
			if a_max <= b_min or a_min >= b_max:
				return Vector2(-1.0, -1.0)
			continue

		var t1 := (b_min - a_max) / d
		var t2 := (b_max - a_min) / d

		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap

		if t1 > entry:
			entry = t1
			axis = i

		exit_t = minf(exit_t, t2)

		if entry > exit_t:
			return Vector2(-1.0, -1.0)

	if axis < 0 or entry < 0.0 or entry > 1.0:
		return Vector2(-1.0, -1.0)

	return Vector2(entry, float(axis))


## Swept capsule-as-box against a half-space. Returns the entry fraction, or -1.
##
## The capsule is measured by its SUPPORT distance along the plane's normal — how far
## the box extends toward the plane from its centre — rather than by a radius. A
## sphere's support is the same in every direction and a capsule's is not, and using a
## radius makes a player standing on a steep ramp float a third of their height above
## it, which reads as the ramp being in the wrong place.
func _plane_sweep(
	from: Vector3,
	motion: Vector3,
	height: float,
	radius: float,
	plane: Plane
) -> float:
	var n := plane.normal
	var support := (
		radius * absf(n.x) + height * 0.5 * absf(n.y) + radius * absf(n.z)
	)

	var distance := n.dot(from) - plane.d - support

	# Already touching or inside. Reported as an immediate hit rather than as a miss,
	# for the reason the floor plane above is: a swept query that says nothing about
	# a shape starting inside geometry is how a player ends up under the world.
	if distance <= 0.0:
		return 0.0

	var closing := n.dot(motion)

	if closing >= 0.0:
		return -1.0

	var t := distance / -closing

	if t > 1.0:
		return -1.0

	return t


static func _axis_normal(axis: int, motion: Vector3) -> Vector3:
	var n := Vector3.ZERO
	n[axis] = -signf(motion[axis])
	return n


func overlaps(at: Vector3, height: float, radius: float) -> bool:
	var bounds := _bounds(at, height, radius)

	if floor_y > -INF and bounds.position.y < floor_y:
		return true

	for box in boxes:
		if bounds.intersects(box):
			return true

	for plane in planes:
		var n := plane.normal
		var support := (
			radius * absf(n.x) + height * 0.5 * absf(n.y) + radius * absf(n.z)
		)
		if n.dot(at) - plane.d - support < 0.0:
			return true

	return false


func describe() -> Dictionary:
	var out := super.describe()
	out["floor_y"] = floor_y
	out["boxes"] = boxes.size()
	out["planes"] = planes.size()
	return out
