class_name DotFpsFlatBody
extends DotFpsBody

## A [DotFpsBody] made of analytic planes and boxes, with no physics server.
## Exists so determinism (replay reproduces the simulation) can be tested headless in milliseconds, with a failure that has one cause; also an example for a heightfield or BSP body.
## Not a collision engine: axis-aligned boxes, an infinite ground plane and half-space planes, the capsule swept as a box. See [method add_ramp].

## Ground plane height. Set to -INF for no floor.
var floor_y: float = 0.0

## Axis-aligned solid boxes, in world space.
var boxes: Array[AABB] = []

## Solid half-spaces: everything BEHIND each plane is solid.
## [Plane] normals point out of the solid, as in [member DotFpsBody.Hit.normal]. Infinite so surf tests need no convex-hull sweep; speed kept down a face is a property of the face.
var planes: Array[Plane] = []

## Synthetic collider id reported for the ground plane; the motor resolves surfaces from the reported hit, so surfaces would be untestable without one. Boxes get [code]BOX_ID_BASE + index[/code].
const FLOOR_ID := 1
const BOX_ID_BASE := 2

## Planes are numbered downward from a high base so they never collide with box ids.
const PLANE_ID_BASE := 100000


## The collider id this body reports for the box at [param index].
static func box_id(index: int) -> int:
	return BOX_ID_BASE + index


static func with_floor(y: float = 0.0) -> DotFpsFlatBody:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var b := new()
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


## Adds a surf ramp: a face through [param through], tilted [param angle_degrees] from horizontal, falling away toward [param fall].
## [param fall] is the horizontal direction a player on it slides. Above [member DotFpsTunables.max_slope_angle] it is a ramp, below a walkable hill.
## Height along the fall is [code]through.y - tan(angle) * distance[/code]; see [method ramp_height].
func add_ramp(
	through: Vector3,
	fall: Vector3,
	angle_degrees: float
) -> DotFpsFlatBody:
	var horizontal := Vector3(fall.x, 0.0, fall.z)

	if horizontal.length_squared() < 1e-9:
		horizontal = Vector3.FORWARD

	horizontal = horizontal.normalized()

	# Tilt the up vector TOWARD the fall direction (0 deg is a floor, 90 a wall). A surface descending along `fall` has a
	# backward gradient and a forward-leaning normal; the other sign builds a ramp that rises where it should fall.
	var radians := deg_to_rad(angle_degrees)
	var normal := (
		Vector3.UP * cos(radians) + horizontal * sin(radians)
	).normalized()

	return add_plane(Plane(normal, normal.dot(through)))


## Height of the plane at [param index] directly above [param at], so callers do not re-derive the tilt sign.
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

		# Feet already at or below the floor contact immediately: Vector3 is 32-bit while GDScript is 64-bit, so a player on y = 0
		# has feet at -2.4e-8 after a round trip, and requiring feet > floor_y made every ground probe miss.
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
	# The contact point, not the swept centre: the motor reads its height to refuse steps landing more than step_height above
	# the floor left. The capsule is a box here, so it is the box's support point against the normal (face centre or corner).
	var centre := from + motion * result.fraction
	result.point = centre - Vector3(
		signf(best_normal.x) * radius,
		signf(best_normal.y) * height * 0.5,
		signf(best_normal.z) * radius
	)
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
## Measured by SUPPORT distance along the plane normal, not a radius: a radius makes a player on a steep ramp float a third of their height above it.
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


## The deepest surface the capsule at [param at] is already inside.
## The analytic counterpart of [method DotFpsPhysicsBody.rest_contact], so de-penetration is proven against a known answer. Boxes report the face least far past; planes are exact.
func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	var best := Hit.miss()
	var deepest := 0.0

	if floor_y > -INF:
		var depth := floor_y - (at.y - height * 0.5)
		if depth > deepest:
			deepest = depth
			best = _rest_hit(Vector3.UP, depth, FLOOR_ID)

	for i in range(planes.size()):
		var plane := planes[i]
		var support := DotFpsBody.capsule_support(plane.normal, height, radius)
		var depth := support - (plane.normal.dot(at) - plane.d)
		if depth > deepest:
			deepest = depth
			best = _rest_hit(plane.normal, depth, plane_id(i))

	var bounds := _bounds(at, height, radius)

	for i in range(boxes.size()):
		var box := boxes[i]
		if not bounds.intersects(box):
			continue

		# Within ONE box take the axis that separates soonest: anything larger moves the player further than the overlap, through
		# whatever is on the far side. Keeping the largest axis slid a capsule 6 mm into a long wall along it every tick, drifting a predicting client from the server (`[fps-flat-rest-axis-1]`).
		var least := INF
		var normal := Vector3.ZERO
		for axis in range(3):
			var out_positive := box.position[axis] + box.size[axis] - bounds.position[axis]
			var out_negative := bounds.position[axis] + bounds.size[axis] - box.position[axis]
			var depth := minf(out_positive, out_negative)
			if depth > 0.0 and depth < least:
				least = depth
				normal = Vector3.ZERO
				normal[axis] = 1.0 if out_positive < out_negative else -1.0

		# Across boxes, the deepest of those: the one that most needs resolving first.
		if least < INF and least > deepest:
			deepest = least
			best = _rest_hit(normal, least, box_id(i))

	return best


func _rest_hit(normal: Vector3, depth: float, id: int) -> Hit:
	var hit := Hit.new()
	hit.hit = true
	hit.fraction = 0.0
	hit.normal = normal
	hit.depth = depth
	hit.collider_id = id
	return hit


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


## The same boxes, planes and floor (shared: a sweep only reads them), with this body's masks.
func copy_for_simulation() -> DotFpsBody:
	var copy: DotFpsFlatBody = (get_script() as GDScript).new()
	copy.floor_y = floor_y
	copy.boxes = boxes
	copy.planes = planes
	return copy_filters_to(copy)


func describe() -> Dictionary:
	var out := super.describe()
	out["floor_y"] = floor_y
	out["boxes"] = boxes.size()
	out["planes"] = planes.size()
	return out
