class_name DotFpsBody
extends RefCounted

## The collision queries [DotFpsMotor] needs, and nothing else.
## Not [method PhysicsBody3D.move_and_collide] or [method CharacterBody3D.move_and_slide]: tests need arithmetic without a physics world, a server may run a heightfield, and move_and_slide keeps state a rewind does not restore.
## Implementations must be pure: the same query on the same world gives the same answer, or prediction never converges.

## What a swept collider hit.
class Hit extends RefCounted:
	## Whether anything was hit at all.
	var hit: bool = false

	## Fraction of the requested motion travelled before contact, 0..1.
	var fraction: float = 1.0

	## Contact normal, pointing away from the surface.
	var normal: Vector3 = Vector3.UP

	## Contact point in world space.
	var point: Vector3 = Vector3.ZERO

	## Instance id of what was hit, or 0.
	var collider_id: int = 0

	## Metres the collider is ALREADY past this surface at the start of the sweep.
	## Zero for swept contacts; non-zero only from [method DotFpsBody.rest_contact], where it is the push-back distance along [member normal] ([method DotFpsMotor._depenetrate]).
	var depth: float = 0.0

	func _init() -> void:
		if DotFpsBody.qprof:
			DotFpsBody.q_n[7] += 1

	static func miss() -> Hit:
		return Hit.new()

	func _to_string() -> String:
		if not hit:
			return "Hit(miss)"
		return "Hit(%.3f, n=%.2f,%.2f,%.2f)" % [
			fraction, normal.x, normal.y, normal.z
		]



## Sweeps the collider from [param from] along [param motion] and reports first contact.
## [param height] and [param radius] are per query because the motor tests a size the body does not currently have.
## [param from] is the capsule's [b]centre[/b], not its feet.
func sweep(
	_from: Vector3,
	_motion: Vector3,
	_height: float,
	_radius: float
) -> Hit:
	push_error("DotFpsBody.sweep() was not overridden.")
	return Hit.miss()


## The node a [member Hit.collider_id] names, or null when this body's ids are not engine instance ids.
func collider_node(_id: int) -> Node3D:
	return null


## Whether a capsule of this size at this position overlaps anything (the stand-up test).
## Separate from a zero-length [method sweep], which is worst at starting inside geometry.
func overlaps(_at: Vector3, _height: float, _radius: float) -> bool:
	push_error("DotFpsBody.overlaps() was not overridden.")
	return false


## The surface a capsule at [param at] is ALREADY inside, with how far inside it is.
## A sweep cannot answer this: [method PhysicsDirectSpaceState3D.cast_motion] ignores colliders the shape already overlaps (checked on 4.7.2 at 0 to 50 cm depth), so a surf ramp touched once stops existing and the player falls through it.
## [method overlaps] says inside but not what or which way out. The default is a miss: no recovery.
func rest_contact(_at: Vector3, _height: float, _radius: float) -> Hit:
	return Hit.miss()


## The distance from a Y-aligned capsule's centre to its surface along [param normal].
## Not the bounding box's: that overestimates by about 10 cm on a 60 degree face, misplacing a de-penetration push.
static func capsule_support(normal: Vector3, height: float, radius: float) -> float:
	return maxf(height * 0.5 - radius, 0.0) * absf(normal.y) + radius


## False runs the original query paths (no broad-phase rejection, no per-tick candidate lists). The motor sets it from [member DotFpsMotor.perf_caches] so the equivalence test can replay both and compare.
var perf_caches: bool = true:
	set(value):
		perf_caches = value
		_perf_caches_changed()


func _perf_caches_changed() -> void:
	pass


## Which collision layers to test against. Set by the controller from the tunables.
var collision_mask: int = 1

## Bodies excluded from every query — the player's own collider, above all.
var exclude: Array[RID] = []

## Layers a player may walk out of when it starts inside them (other players' hulls, [DotPlayerBodyRules]): a sweep stops at them, questions about what is touched ignore them.
## Two players spawned together walk apart instead of being held still.
var pass_out_mask: int = 0

## SPIKE (motor-native-spike-1): per-query-kind time and counts, filled only while [member qprof] is on.
## 0 hull sweep (outer), 1 flat sweep, 2 flat rest_contact, 3 flat overlaps, 4 hull rest (outer), 5 hull overlaps (outer), 7 Hit allocations.
static var qprof: bool = false
static var q_us := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
static var q_n := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])


## Sweeps another player's hull stopped, and sweeps the world touched at all. A wrapper that adds hulls counts them so the
## motor can tell a slide stopped only by a player (stepping over a standing player never succeeds) from a wall or kerb.
var hull_blocks: int = 0
var world_touches: int = 0


## Called by the motor around each tick: a wrapper that gathers other bodies' hulls may reuse one gather for the whole tick.
func begin_tick() -> void:
	pass


## Ends the span [method begin_tick] opened.
func end_tick() -> void:
	pass


## A body that answers every question this one does, for a [DotFpsSimulator]: same world, masks and exclusions, none of this one's counters. Null when it cannot copy itself.
## A copy, so a simulation run between live ticks does not show in this body's counters or per-sweep caches. Override in a game's own body.
func copy_for_simulation() -> DotFpsBody:
	return null


## The masks and exclusions [param into] needs to ask what this body asks. For overrides.
func copy_filters_to(into: DotFpsBody) -> DotFpsBody:
	into.collision_mask = collision_mask
	into.exclude = exclude.duplicate()
	into.pass_out_mask = pass_out_mask
	return into


func describe() -> Dictionary:
	return {
		"implementation": get_script().get_global_name() if get_script() != null else "?",
		"mask": collision_mask,
		"excluded": exclude.size(),
	}
