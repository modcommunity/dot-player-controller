class_name DotFpsBody
extends RefCounted

## The collision queries [DotFpsMotor] needs, and nothing else.
##
## [b]Why the motor does not just call [method PhysicsBody3D.move_and_collide].[/b]
## Three reasons, and each one came up while building this:
##
## [i]Testing.[/i] The self-test has to prove that replaying a command sequence
## reproduces a simulation exactly — the property client-side prediction depends on.
## Against a real physics world that test needs a scene, a physics step, and a frame
## of latency per query. Against [DotFpsFlatBody] it is arithmetic, runs headless in
## milliseconds, and fails for exactly one reason when it fails.
##
## [i]Server cost.[/i] A dedicated server simulating a movement-only mode does not
## need a rendering-capable physics world. A game whose collision is a heightfield or
## a BSP can implement this against that directly and skip the physics server.
##
## [i]Determinism.[/i] [method CharacterBody3D.move_and_slide] keeps state on the
## body between calls — the last floor normal, the last velocity — that a rewind does
## not restore. Everything the simulation remembers has to be in [DotFpsState], so
## the motor does its own collide-and-slide over a stateless query instead.
##
## Implementations must be [b]pure with respect to the simulation[/b]: the same query
## against the same world gives the same answer. Anything that changes between the
## client's copy of the world and the server's — geometry only one side has streamed
## in, a moving platform driven by wall-clock time — shows up as a prediction that
## never converges.

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
	##
	## Zero for every ordinary swept contact, which is the only kind that existed when
	## this class was written. Non-zero only for a [method DotFpsBody.rest_contact],
	## where it is the exact distance the motor has to push back along
	## [member normal] to be clear — see [method DotFpsMotor._depenetrate].
	var depth: float = 0.0

	static func miss() -> Hit:
		return Hit.new()

	func _to_string() -> String:
		if not hit:
			return "Hit(miss)"
		return "Hit(%.3f, n=%.2f,%.2f,%.2f)" % [
			fraction, normal.x, normal.y, normal.z
		]


# --- Interface -------------------------------------------------------------

## Sweeps the collider from [param from] along [param motion] and reports first
## contact.
##
## [param height] and [param radius] describe the capsule for this query rather than
## being body state, because the motor tests "would I fit if I stood up here" against
## a size the body does not currently have.
##
## [param from] is the capsule's [b]centre[/b], not its feet. Feet-relative would be
## more convenient at one call site and wrong at every other.
func sweep(
	_from: Vector3,
	_motion: Vector3,
	_height: float,
	_radius: float
) -> Hit:
	push_error("DotFpsBody.sweep() was not overridden.")
	return Hit.miss()


## Whether a capsule of this size at this position overlaps anything.
##
## Used for the standing-up test. Separate from a zero-length [method sweep] because
## a sweep starting inside geometry is exactly the case swept queries are worst at.
func overlaps(_at: Vector3, _height: float, _radius: float) -> bool:
	push_error("DotFpsBody.overlaps() was not overridden.")
	return false


## The surface a capsule at [param at] is ALREADY inside, with how far inside it is.
##
## [b]A swept query cannot answer this, and the reason is the worst bug in this
## file's history.[/b] Godot's [method PhysicsDirectSpaceState3D.cast_motion] ignores
## any collider the shape already overlaps — reasonably, since there is no first
## contact to report — and returns "nothing there". Measured on 4.7.2 against a surf
## ramp: a capsule 2 cm clear of the face is reported correctly, and a capsule
## touching it, or 1 mm, 1 cm, 20 cm or 50 cm inside it, is reported as free space at
## every one of those depths. The ramp does not merely become hard to see; it stops
## existing.
##
## Which makes contact an absorbing state. A surfer touches the ramp — that is what
## surfing is — and from that tick the ramp is invisible, so nothing clips their
## velocity, gravity keeps pulling them into it, and they accelerate through the
## inside of the level. [member DotFpsMotor.stuck_ticks] and every other counter read
## zero throughout, because from the motor's point of view nothing went wrong.
##
## [method overlaps] can tell you that you are inside something but not what, or which
## way is out. This reports both, so there is a route back out of a state the sweep
## alone can only sink deeper into. The default is a miss: a game with its own body
## keeps working and simply gets no recovery.
func rest_contact(_at: Vector3, _height: float, _radius: float) -> Hit:
	return Hit.miss()


## The distance from a Y-aligned capsule's centre to its surface along [param normal].
##
## [b]Not the bounding box's.[/b] The box approximation
## ([code]radius * |n.x| + height/2 * |n.y| + radius * |n.z|[/code]) appears in
## placement helpers, where erring large is safe. Used as a real support it
## overestimates by about 10 cm on a 60 degree face for the shipped collider, which is
## enough to put a de-penetration push in the wrong place and a probe outside the
## geometry it was meant to find.
static func capsule_support(normal: Vector3, height: float, radius: float) -> float:
	return maxf(height * 0.5 - radius, 0.0) * absf(normal.y) + radius


## Which collision layers to test against. Set by the controller from the tunables.
var collision_mask: int = 1

## Bodies excluded from every query — the player's own collider, above all.
var exclude: Array[RID] = []


func describe() -> Dictionary:
	return {
		"implementation": get_script().get_global_name() if get_script() != null else "?",
		"mask": collision_mask,
		"excluded": exclude.size(),
	}
