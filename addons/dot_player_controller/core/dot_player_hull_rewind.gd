class_name DotPlayerHullRewind
extends RefCounted

## Lag-compensated collision for players whose hulls are physics bodies ([method DotPlayerBodyRules.apply_hull]): [method around] puts every other player's hull where the game's [member feet_fn] says the mover's view had it, runs the step, and puts the hulls back.
## Without it a client predicts a bump against the drawn (interpolated) remote and the server moves the mover against the present: every bump with a moving player is a correction. Design and limits: docs/collision.md, "Lag-compensated hulls".
## Only the physics server's transform is written, never the node, so nothing the game reads (positions, hitboxes, the interpolator) sees a rewound player.

## `(mover_key, other_key, tick) -> Vector3 or null`: the other's feet at the mover's view tick (the server's
## per-tick history; a client's interpolator at the same tick). Null leaves that hull where it stands.
var feet_fn: Callable = Callable()

## `(feet: Vector3) -> Vector3`: snaps a rewound position to the wire grid of the replicated position
## (`DotNetVar.wire_value`), so both ends stand the hull on the same millimetre. Unset: used as given.
var snap_fn: Callable = Callable()

## Only hulls within this many metres (a box around the mover's feet), then or now, are moved; 0 moves every hull.
## Bounds the N-squared cost; a game sets it to the mover's reach this tick (speed times dt, plus two radii and the view lag's drift).
var reach: float = 0.0

## Hull writes made, for a test or a profile.
var moved_total: int = 0

var _rids: Array[RID] = []
var _was: Array[Transform3D] = []


## Whether hulls are standing somewhere other than the present.
func is_rewound() -> bool:
	return not _rids.is_empty()


## Moves each hull in [param bodies] (`{key: CollisionObject3D}`) except the mover's own to where [member feet_fn]
## answers for [param tick]; returns how many moved. [param mover_feet], with [member reach], skips far hulls.
## Call [method restore] after; [method around] does both.
func rewind(mover: Variant, bodies: Dictionary, tick: int, mover_feet: Variant = null) -> int:
	if is_rewound():
		var _undone := restore()
	if not feet_fn.is_valid():
		return 0
	for key: Variant in bodies:
		if key == mover:
			continue
		var body := bodies[key] as CollisionObject3D
		if body == null or not is_instance_valid(body):
			continue
		var then: Variant = feet_fn.call(mover, key, tick)
		if not (then is Vector3):
			continue
		var rid := body.get_rid()
		var now: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var feet: Vector3 = then
		if snap_fn.is_valid():
			feet = snap_fn.call(feet)
		if feet.is_equal_approx(now.origin):
			continue
		if reach > 0.0 and mover_feet is Vector3 and _far(mover_feet, feet) and _far(mover_feet, now.origin):
			continue
		_rids.append(rid)
		_was.append(now)
		var moved := now
		moved.origin = feet
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, moved)
		moved_total += 1
	return _rids.size()


## Puts every rewound hull back; returns how many.
func restore() -> int:
	var count := _rids.size()
	for i in count:
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, _was[i])
	_rids.clear()
	_was.clear()
	return count


## Runs [param work] (a Callable) with the hulls rewound for [param mover] at [param tick] and returns its result.
## With [member DotPlayerBodyRules.solid] or [member DotPlayerBodyRules.unlag] off in [param rules] (or null rules),
## runs it against the present.
func around(rules: DotPlayerBodyRules, mover: Variant, bodies: Dictionary, tick: int, work: Callable, mover_feet: Variant = null) -> Variant:
	if rules == null or not rules.solid or not rules.unlag:
		return work.call()
	var _n := rewind(mover, bodies, tick, mover_feet)
	var result: Variant = work.call()
	var _back := restore()
	return result


func _far(a: Vector3, b: Vector3) -> bool:
	var d := (a - b).abs()
	return maxf(d.x, maxf(d.y, d.z)) > reach
