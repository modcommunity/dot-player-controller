class_name DotFpsWallProbe
extends RefCounted

## Finds the wall a remote player is running along, which is not replicated.
##
## A remote machine gets the run's bits but not [member DotFpsState.wall_normal], so a body
## drawn from the wire alone would stay upright. Two rays to either side of the velocity at
## chest height give the side without adding a field to the full state word.


## The nearest near-vertical wall's normal beside [param position] (the feet), or ZERO.
static func find(space: PhysicsDirectSpaceState3D, position: Vector3, velocity: Vector3, mask: int, reach: float = 1.0, chest: float = 1.0) -> Vector3:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if space == null or flat.length_squared() < 0.01:
		return Vector3.ZERO
	var side := flat.normalized().cross(Vector3.UP)
	var origin := position + Vector3.UP * chest
	var best := Vector3.ZERO
	var best_dist := INF
	for dir in [side, -side]:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach, mask)
		var hit := space.intersect_ray(query)
		if hit.is_empty() or absf((hit["normal"] as Vector3).y) > 0.5:
			continue
		var dist := origin.distance_to(hit["position"])
		if dist < best_dist:
			best_dist = dist
			best = hit["normal"]
	return best
