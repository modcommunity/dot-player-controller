class_name DotFpsPhysicsBody
extends DotFpsBody

## [DotFpsBody] backed by Godot's 3D physics server. The implementation a game uses.
## Queries use a capsule shape the motor sizes per call instead of the player's own [CollisionShape3D], so asking "would I fit standing" never mutates the thing measured.
## The shape is allocated once and reused; rebuilding one per query was the largest single cost on a 32-slot server.

const CHANNEL := "fps.body"

var _space: PhysicsDirectSpaceState3D = null
var _shape: CapsuleShape3D = CapsuleShape3D.new()

var _motion_params := PhysicsTestMotionParameters3D.new()
var _shape_params := PhysicsShapeQueryParameters3D.new()
var _ray_params := PhysicsRayQueryParameters3D.new()
var _ray_exclude: Array[RID] = []

## Queries run this tick. Reset by the controller; watched by the server operator. Counts the native body's too.
var query_count: int:
	get:
		return _queries + (_native.query_count() if _native != null else 0)
	set(value):
		_queries = value
		if _native != null:
			_native.set_query_count(0)

var _queries: int = 0

## dot-sim's native body ([code]DotSimFpsBody[/code], the [code]motor[/code] module): the same sweep, rest contact and
## overlap, rounded the same way, so its answers are this script's to the bit (dot-sim's motor parity suite proves it over
## recorded input streams). Used when the extension is loaded, [member native_enabled] is on and [member profile] is off;
## on the web, or with no library installed, this script answers. The motor's collide-and-slide runs there too ([method native_slide]).
const NATIVE_CLASS := &"DotSimFpsBody"

## Whether the native body is used when present (a game's cvar; a suite turns it off to compare).
static var native_enabled: bool = true

## This body's own switch beside [member native_enabled]: off, it answers in script whatever the game chose.
var use_native: bool = true

static var _native_known: int = -1
var _native: Object = null
var _native_space: PhysicsDirectSpaceState3D = null
var _native_exclude: Array[RID] = []


## Whether dot-sim's native body is loaded and enabled.
static func native_available() -> bool:
	if _native_known < 0:
		_native_known = 1 if ClassDB.class_exists(NATIVE_CLASS) else 0
	return native_enabled and _native_known == 1


## The native body to ask, synced to this one's space and exclusions; null to answer in script.
func _nat() -> Object:
	if profile or not use_native or not native_available():
		return null
	if _native == null:
		_native = ClassDB.instantiate(NATIVE_CLASS)
		_native.set_perf_caches(perf_caches)
		if _in_tick:
			_native.begin_tick()
	if _native_space != _space:
		_native_space = _space
		_native.set_space(_space)
	if exclude != _native_exclude:
		_native.set_exclude(exclude)
		_native_exclude = exclude.duplicate()
	return _native


## Slides run natively in one call ([method native_slide]), for a suite's check.
static var native_slides: int = 0


func native_slide(
	from: Vector3, velocity: Vector3, motion: Vector3, height: float,
	mode: int, flag: bool, tun: PackedFloat64Array, has_hulls: bool = false, hulls: Array = []
) -> PackedFloat64Array:
	if _space == null and not revalidate():
		return PackedFloat64Array()
	var nat := _nat()
	if nat == null:
		return PackedFloat64Array()
	native_slides += 1
	var t := DotFrameCost.now()
	var before: int = nat.query_count() if t > 0 else 0
	var r: PackedFloat64Array = nat.move_slide(
		from, velocity, motion, height, mode, flag, tun, has_hulls, hulls, collision_mask, pass_out_mask
	)
	_charge_native(&"native_slide", t, before)
	return r


## Tick halves run natively ([method native_tick]), for a suite's check.
static var native_ticks: int = 0

## 1 when the loaded library has the motor tick ([code]motor_pre[/code]; dot-sim releases before it do not), 0 when not, -1 unknown.
static var _tick_known: int = -1


## Whether [method native_tick] can run: the native body is available and its library has the motor tick.
static func native_tick_available() -> bool:
	if _tick_known < 0:
		_tick_known = 1 if ClassDB.class_exists(NATIVE_CLASS) and ClassDB.class_has_method(NATIVE_CLASS, &"motor_pre") else 0
	return _tick_known == 1 and native_available()


func native_tick(
	phase: int, state: PackedFloat64Array, tun: PackedFloat64Array, hulls_mode: int = 0, hulls: Array = []
) -> PackedFloat64Array:
	if not native_tick_available() or (_space == null and not revalidate()):
		return PackedFloat64Array()
	var nat := _nat()
	if nat == null:
		return PackedFloat64Array()
	native_ticks += 1
	if phase == 0:
		return nat.motor_pre(state, tun, hulls_mode, hulls, collision_mask, pass_out_mask)
	return nat.motor_post(state, tun, hulls_mode, hulls, collision_mask, pass_out_mask)


## Whether this body's queries have gone to the native body (a suite's check).
func uses_native() -> bool:
	return _native != null


## A native answer as a [DotFpsBody.Hit]: empty for a miss, else fraction, normal, point, depth and the collider id in halves.
static func _hit_of(a: PackedFloat64Array) -> Hit:
	var h := Hit.new()
	if a.is_empty():
		return h
	h.hit = true
	h.fraction = a[0]
	h.normal = Vector3(a[1], a[2], a[3])
	h.point = Vector3(a[4], a[5], a[6])
	h.depth = a[7]
	h.collider_id = int(a[8]) | (int(a[9]) << 32)
	return h


func _perf_caches_changed() -> void:
	if _native != null:
		_native.set_perf_caches(perf_caches)

## Per engine query kind (cast, rest, overlap, ray): calls and microseconds, filled only while [member profile] is on.
static var profile: bool = false
static var prof := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
## The system queries are charged to in DotFrameCost (dot-profiler's query table) while it is enabled.
static var cost_system: StringName = &"p_controller"


func _q_cast() -> PackedFloat32Array:
	if not profile and not DotFrameCost.enabled:
		return _space.cast_motion(_shape_params)
	var t := Time.get_ticks_usec()
	var r := _space.cast_motion(_shape_params)
	_charge(0, DotSpaceQuery.CAST, t)
	return r


func _q_rest() -> Dictionary:
	if not profile and not DotFrameCost.enabled:
		return _space.get_rest_info(_shape_params)
	var t := Time.get_ticks_usec()
	var r := _space.get_rest_info(_shape_params)
	_charge(2, DotSpaceQuery.REST, t)
	return r


func _q_overlap() -> Array[Dictionary]:
	if not profile and not DotFrameCost.enabled:
		return _space.intersect_shape(_shape_params, 1)
	var t := Time.get_ticks_usec()
	var r := _space.intersect_shape(_shape_params, 1)
	_charge(4, DotSpaceQuery.SHAPE, t)
	return r


func _q_ray(query: PhysicsRayQueryParameters3D) -> Dictionary:
	if not profile and not DotFrameCost.enabled:
		return _space.intersect_ray(query)
	var t := Time.get_ticks_usec()
	var r := _space.intersect_ray(query)
	_charge(6, DotSpaceQuery.RAY, t)
	return r


## Times one script-path query into [member prof] and DotFrameCost, whichever is on.
static func _charge(i: int, kind: StringName, t: int) -> void:
	if profile:
		prof[i] += 1
		prof[i + 1] += Time.get_ticks_usec() - t
	DotFrameCost.add_query(cost_system, kind, t)


## Charges a native call to DotFrameCost as [param kind], counting the engine queries it ran; a no-op while off.
func _charge_native(kind: StringName, t: int, before: int) -> void:
	if t > 0:
		DotFrameCost.add_query(cost_system, kind, t, maxi(_native.query_count() - before, 1))


static func for_node(node: Node3D) -> DotFpsPhysicsBody:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var body := new()
	body.bind(node)
	return body


## Binds to the physics space [param node] lives in. A scene change invalidates the handle, so [method is_bound] is checked before use.
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
	# Writing a shape's size re-sends it to the physics server and emits `changed` even when unchanged, and a tick asks a dozen
	# questions with two or three sizes, so touch the shape only when a size or the exclusion list differs. The mask is set always:
	# [method sweep] overwrites it per query.
	var total := maxf(height, radius * 2.0)
	if radius != _cfg_radius:
		_shape.radius = radius
		_cfg_radius = radius
	# Godot's capsule height includes both caps and clamps to 2 * radius; DotFpsTunables.validate() rejects configurations
	# that would hit the clamp, since a collider of the wrong size is unfindable from the symptom.
	if total != _cfg_height:
		_shape.height = total
		_cfg_height = total

	# Everything but the sweep's own cast and the contact it found asks about what the
	# capsule is already in, and a layer it may walk out of is not part of that answer.
	_set_mask(collision_mask & ~pass_out_mask)
	# The setter rebuilds the engine's set from the array each time. A copy is kept, not
	# the array itself, so an in-place edit of [member exclude] is seen.
	if exclude != _cfg_exclude:
		_shape_params.exclude = exclude
		_cfg_exclude = exclude.duplicate()
		_rm_valid = false


## [member PhysicsShapeQueryParameters3D.collision_mask], written only when it changes: a
## property write on an engine object costs a call, and most queries ask for the mask the
## last one left.
func _set_mask(mask: int) -> void:
	if mask != _cfg_mask:
		_shape_params.collision_mask = mask
		_cfg_mask = mask


var _cfg_mask: int = -1


## What [method _configure] last wrote to the shape; NAN until the first write.
var _cfg_radius: float = NAN
var _cfg_height: float = NAN
var _cfg_exclude: Array[RID] = []


## The node this body was bound to, so a stale space can be recovered.
var _owner: Node3D = null


## Re-binds to the node's current space. Returns whether a space is available.
## The handle is cached but does not survive a scene change, and a dead one answers every query "nothing there", which looks like falling through a loaded level.
func revalidate() -> bool:
	if _owner == null or not _owner.is_inside_tree():
		return false

	var space := _owner.get_world_3d().direct_space_state

	if space == null:
		return false

	if space != _space:
		_space = space
		_rm_valid = false
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

	var nat := _nat()
	if nat != null:
		var t := DotFrameCost.now()
		var before: int = nat.query_count() if t > 0 else 0
		var h := _hit_of(nat.sweep(from, motion, height, radius, collision_mask, pass_out_mask))
		_charge_native(&"native_sweep", t, before)
		return h

	# A zero-length sweep has no direction to report a normal against, and the
	# physics server's answer for one is not meaningful. The motor never needs it —
	# it uses overlaps() for that question.
	if motion.length_squared() <= 0.0:
		return result

	_configure(height, radius)
	_queries += 1

	# The cast sees players' hulls too, unless the capsule starts inside one: a convex cast starting overlapping another
	# reports it at fraction 0 and two players on one spot held each other still. Inside one, their layers are left out until apart.
	_set_mask(collision_mask)
	_shape_params.transform = Transform3D(Basis.IDENTITY, from)
	_shape_params.motion = Vector3.ZERO
	if pass_out_mask != 0:
		_set_mask(collision_mask & pass_out_mask)
		if not _q_overlap().is_empty():
			_set_mask(collision_mask & ~pass_out_mask)
		else:
			_set_mask(collision_mask)
	_shape_params.motion = motion

	# cast_motion returns [safe, unsafe]: the last fraction with no contact and the first with one. Move by `safe`; sample the
	# normal at `unsafe`, since at `safe` the shapes do not yet touch.
	var fractions := _q_cast()

	if fractions.is_empty():
		return result

	var safe: float = fractions[0]
	var unsafe: float = fractions[1]

	if safe >= 1.0:
		_set_mask(collision_mask & ~pass_out_mask)
		# Nothing along the sweep: either open space or a collider the sweep refuses to see because the capsule is already inside.
		# Ask the resting question before the ray; a ramp underfoot answers the ray badly and this exactly.
		var resting := _blocking_rest_contact(from, motion, height, radius)

		if resting != null:
			return resting

		# The ray answers downward motion only (motion.y < 0 is necessary for that).
		if motion.y < 0.0:
			var below := _downward_ray_fallback(from, motion, height)

			if below.hit:
				return below

		var ending := _end_overlap_fallback(from, motion, height, radius)
		return ending if ending != null else result

	result.hit = true
	result.fraction = clampf(safe, 0.0, 1.0)

	_shape_params.transform = Transform3D(
		Basis.IDENTITY, from + motion * unsafe
	)
	_shape_params.motion = Vector3.ZERO

	var contacts := _q_rest()

	if contacts.is_empty():
		# Contact at `unsafe` but no rest info: touching without overlapping. Ask again a few millimetres deeper before guessing,
		# because sliding along the motion's reverse clips the velocity to zero too, and a surfer grazing a bank hung mid-air
		# for good (`[bank-hang-1]`); a millimetre further the query reports the bank's own normal.
		var along := motion.normalized()
		for depth: float in CONTACT_RETRY_DEPTHS:
			_shape_params.transform = Transform3D(
				Basis.IDENTITY, from + motion * unsafe + along * depth
			)
			contacts = _q_rest()
			if not contacts.is_empty():
				break

	if contacts.is_empty() and motion.normalized().dot(Vector3.DOWN) >= 0.7:
		# Downward, the guess below is a floor made of nothing (`[jumping-into-crate-1]`): a capsule grazing a vertical face makes
		# cast_motion report a contact no rest query names, so the motion's reverse is straight UP, a perfect floor, and a runner
		# climbed a crate stack by its sides. A ray down the axis answers floors honestly; nothing under it is a graze.
		return _downward_ray_fallback(from, motion, height)

	if contacts.is_empty():
		# Still nothing: ask where the move ENDS, not what it grazed (`[fps-face-edge-stop]`); the motion's reverse clipped velocity to zero
		# and stopped a surfer dead leaving a pitched face over its end edge. Nothing at rest means touching without overlap,
		# so _end_overlap_fallback answers: back off by the depth of a surface entered, else a miss.
		var ending := _end_overlap_fallback(from, motion, height, radius)
		return ending if ending != null else Hit.miss()

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

	# A contact reported late (`[sweep-1]`): against a large convex, cast_motion's `safe` can be centimetres past the real
	# contact (a 164 m wall let a capsule in 11 cm). The rest query at `unsafe` knows the depth, so back off by depth over the rate of approach.
	var approach := -motion.dot(result.normal)
	if approach > 1e-9:
		var at_unsafe := from + motion * unsafe
		var deepest := at_unsafe - result.normal * DotFpsBody.capsule_support(
			result.normal, height, radius)
		var depth := result.normal.dot(result.point - deepest)
		if depth > LATE_CONTACT_DEPTH:
			result.fraction = clampf(minf(result.fraction, unsafe - depth / approach), 0.0, 1.0)

	return result


## A ray down the capsule's own axis, for when [method PhysicsDirectSpaceState3D.cast_motion] refuses to see the floor.
## cast_motion skips colliders it believes the shape already overlaps, unreliable against a very large convex (4.7.2: 4.5 mm above a 164 m plate read free), so the player sank through.
## Analytic, runs only when the sweep saw nothing. Downward only: a sideways edge would report a wall late; walls are [method _end_overlap_fallback]'s.
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

	# One query object kept: a fresh one per ray is an allocation on the hot path.
	var query := _ray_params
	query.from = foot
	query.to = foot + motion
	query.collision_mask = collision_mask & ~pass_out_mask
	if exclude != _ray_exclude:
		query.exclude = exclude
		_ray_exclude = exclude.duplicate()
	query.collide_with_areas = false
	_queries += 1

	var contact: Dictionary = _q_ray(query)

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


## Where the sweep said "nothing", whether the capsule would END inside something it moves into, and how far back along the motion it stops touching it.
## The sideways half of [method _downward_ray_fallback]'s problem (`[sweep-1]`): 299 of 3,000 sweeps 0 to 6 mm off a 164 m wall ended up to 11 cm inside it. A ray cannot answer (axis behind the edge); the end overlap can.
## Backs the fraction off by that depth over the rate of approach; only reports surfaces being driven into, so it never collides with less.
func _end_overlap_fallback(
	from: Vector3, motion: Vector3, height: float, radius: float
) -> Hit:  # null for a miss
	var at := from + motion
	var end := _raw_rest_or_null(at, height, radius)

	if end == null:
		return null

	_turn_round_flipped(end, at, height, radius)

	var approach := -motion.dot(end.normal)

	# Moving along it or out of it: a floor underfoot, or a surface being left.
	if approach <= 1e-9 or end.depth <= 0.0:
		return null

	var result := Hit.new()
	result.hit = true
	result.fraction = clampf(1.0 - end.depth / approach, 0.0, 1.0)
	result.normal = end.normal
	result.point = end.point
	result.collider_id = end.collider_id
	return result


## A [method rest_contact] filtered to surfaces this motion would drive further into.
## The filter is the safety: a capsule inside something usually tries to leave it (after a push, a step up, a crouch under a lip), and blocking surfaces being left would pin it.
func _blocking_rest_contact(
	from: Vector3, motion: Vector3, height: float, radius: float
) -> Hit:  # null when nothing blocks, to spare a miss
	var resting := _raw_rest_or_null(from, height, radius)

	if resting == null:
		return null

	_turn_round_flipped(resting, from, height, radius)

	if motion.dot(resting.normal) >= 0.0:
		return null

	return resting


func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	if _space == null and not revalidate():
		return Hit.miss()
	var nat := _nat()
	if nat != null:
		var t := DotFrameCost.now()
		var before: int = nat.query_count() if t > 0 else 0
		var h := _hit_of(nat.rest_contact(at, height, radius, collision_mask, pass_out_mask))
		_charge_native(&"native_rest", t, before)
		return h

	var result := _raw_rest_contact(at, height, radius)

	if not result.hit:
		return result

	_turn_round_flipped(result, at, height, radius)
	return result


## Turns [param result] round when its normal points into the surface it came from.
## Shared by [method rest_contact] and [method sweep], which read the same engine answer.
func _turn_round_flipped(result: Hit, at: Vector3, height: float, radius: float) -> void:

	# A contact normal can point INTO the surface the capsule rests on (`[ramp-pop-1]`), reading it as embedded and making
	# [method DotFpsMotor._depenetrate] push riders a full step into the ramp.
	# A genuinely buried capsule shows the same tell, so the reversed answer is TRIED and kept only if the capsule moved out along it is clear; its depth floors at zero.
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
	_flipped += 1


## How clear the capsule has to be, moved out along a reversed normal, for the reversal
## to be believed. Half a millimetre: well inside any skin a motor keeps, and well above
## the noise of a resting contact.
const FLIP_CHECK_CLEARANCE := 0.0005

## Rest contacts whose normal came back pointing into the surface and was turned round.
## See [method rest_contact]. Non-zero on any imported map with sloped brushes; a count
## that is zero where riders are depenetrating every tick is this check not running. Counts the native body's too.
var flipped_normals: int:
	get:
		return _flipped + (_native.flipped_normals() if _native != null else 0)
	set(value):
		_flipped = value

var _flipped: int = 0


## One [method PhysicsDirectSpaceState3D.get_rest_info], taken as the engine reports it.
func _raw_rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	var found := _raw_rest_or_null(at, height, radius)
	return found if found != null else Hit.miss()


## [method _raw_rest_contact] without the allocation of a miss: null when nothing is found.
## Most rest queries in open air find nothing, and a tick makes several.
func _raw_rest_or_null(at: Vector3, height: float, radius: float) -> Hit:
	if _space == null and not revalidate():
		return null

	_configure(height, radius)

	# Within one motor tick nothing this query can see moves, and the tick asks the same question more than once (the de-penetration test, then the slide's opening check at the same spot).
	# Answered from the last result when the shape, place and filters are identical; a hit is rebuilt so callers may edit what they are given.
	var memo := perf_caches and _in_tick
	if memo and _rm_valid and at == _rm_at and height == _rm_height and radius == _rm_radius and _cfg_mask == _rm_mask:
		_memo_hits += 1
		if _rm_normal == Vector3.ZERO:
			return null
		var again := Hit.new()
		again.hit = true
		again.fraction = 0.0
		again.normal = _rm_normal
		again.point = _rm_point
		again.collider_id = _rm_id
		again.depth = _rm_depth
		return again

	var found := _raw_rest_query(at, height, radius)

	if memo:
		_rm_valid = true
		_rm_at = at
		_rm_height = height
		_rm_radius = radius
		_rm_mask = _cfg_mask
		if found == null:
			_rm_normal = Vector3.ZERO
		else:
			_rm_normal = found.normal
			_rm_point = found.point
			_rm_id = found.collider_id
			_rm_depth = found.depth

	return found


## Rest queries answered from [method _raw_rest_or_null]'s memo (the native body's included). Diagnostic.
var rest_memo_hits: int:
	get:
		return _memo_hits + (_native.rest_memo_hits() if _native != null else 0)
	set(value):
		_memo_hits = value

var _memo_hits: int = 0

var _in_tick: bool = false
var _rm_valid: bool = false
var _rm_at := Vector3.ZERO
var _rm_height := 0.0
var _rm_radius := 0.0
var _rm_mask := 0
var _rm_normal := Vector3.ZERO
var _rm_point := Vector3.ZERO
var _rm_id := 0
var _rm_depth := 0.0


func begin_tick() -> void:
	_in_tick = true
	_rm_valid = false
	if _native != null:
		_native.begin_tick()


func end_tick() -> void:
	_in_tick = false
	_rm_valid = false
	if _native != null:
		_native.end_tick()


## The query itself; see [method _raw_rest_or_null].
func _raw_rest_query(at: Vector3, height: float, radius: float) -> Hit:
	_queries += 1

	_shape_params.transform = Transform3D(Basis.IDENTITY, at)
	_shape_params.motion = Vector3.ZERO

	var contact: Dictionary = _q_rest()

	if contact.is_empty():
		return null

	var normal: Vector3 = contact.get("normal", Vector3.ZERO)

	# Unlike the sweep, there is no motion here to fall back on for a direction, so a
	# degenerate normal has no safe substitute and the honest answer is "no contact".
	# Reporting a made-up one would push the player somewhere arbitrary.
	if not normal.is_normalized():
		return null

	var point: Vector3 = contact.get("point", at)

	# How far the capsule's deepest point along -normal lies past the contact point.
	# Measured against get_rest_info's own point rather than against a shape query,
	# and checked to 4 decimal places at depths from 0 to 1 m on 4.7.2.
	var deepest := at - normal * DotFpsBody.capsule_support(normal, height, radius)

	var result := Hit.new()
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

	var nat := _nat()
	if nat != null:
		return nat.overlaps(at, height, radius, collision_mask, pass_out_mask)

	_configure(height, radius)
	_queries += 1

	_shape_params.transform = Transform3D(Basis.IDENTITY, at)
	_shape_params.motion = Vector3.ZERO

	# One result is enough — the question is "is anything there", not "what".
	return not _q_overlap().is_empty()


## A body over the same physics space (bound to the node this one is), with its masks and
## exclusions: the player's own collider stays excluded. Null while this one is unbound.
func copy_for_simulation() -> DotFpsBody:
	if _owner == null or not _owner.is_inside_tree():
		return null
	var copy: DotFpsPhysicsBody = (get_script() as GDScript).new()
	if not copy.bind(_owner).ok:
		return null
	return copy_filters_to(copy)


func describe() -> Dictionary:
	var out := super.describe()
	out["bound"] = is_bound()
	out["queries"] = query_count
	return out


func collider_node(id: int) -> Node3D:
	return instance_from_id(id) as Node3D
