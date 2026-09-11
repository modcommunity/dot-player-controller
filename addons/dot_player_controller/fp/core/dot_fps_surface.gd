@tool
class_name DotFpsSurface
extends Resource

## How one kind of ground behaves under the player. Ice, mud, metal, a conveyor.
##
## [b]Multipliers, not values.[/b] A surface scales what [DotFpsTunables] already
## says rather than replacing it, so a game retunes its movement once and every
## surface follows. A surface that set absolute numbers would silently ignore every
## later change to the base feel, which is the failure mode of every "surface
## override" system that stores values.
##
## [codeblock]
## var ice := DotFpsSurface.new()
## ice.id = &"ice"
## ice.friction_scale = 0.05
## ice.accelerate_scale = 0.3
## [/codeblock]
##
## [b]Surfaces are simulation, not decoration.[/b] They change acceleration, so a
## client and a server that disagree about which surface a player is on will disagree
## about where the player is. That is why they are resolved from something both
## machines can see — see [DotFpsSurfaceSet.resolve_from_node] — rather than from the
## collider's instance id, which differs between processes.

## Name this surface is looked up by. Must match on every machine.
@export var id: StringName = &"default"

@export_group("Movement")

## Scales [member DotFpsTunables.friction]. Low is ice; high is glue.
@export_range(0.0, 5.0, 0.01) var friction_scale: float = 1.0

## Scales [member DotFpsTunables.accelerate]. Low means slow to get going.
@export_range(0.0, 5.0, 0.01) var accelerate_scale: float = 1.0

## Scales the ground speed cap.
@export_range(0.0, 5.0, 0.01) var max_speed_scale: float = 1.0

## Scales the jump launch speed. 0 makes a surface unjumpable.
@export_range(0.0, 5.0, 0.01) var jump_scale: float = 1.0

@export_group("Behaviour")

## Whether this surface can be stood on at all.
##
## False makes it behave like a wall regardless of its angle — a rail, a pane of
## glass, the top of a fence.
@export var standable: bool = true

## Constant push applied while standing on it, in m/s². A conveyor or a slick slope.
##
## In world space, so a level designer places the direction with the geometry rather
## than deriving it from the surface normal.
##
## [b]It competes with friction, and friction wins by default.[/b] Ground friction is
## applied as though the player were moving at least
## [member DotFpsTunables.stop_speed], so a push below
## [code]stop_speed * friction * friction_scale[/code] — 24 m/s² with the shipped
## defaults — cannot move a standing player at all, and one just above it produces a
## crawl. A conveyor that visibly moves someone wants a value several times that, or
## a low [member friction_scale] to go with it. The equilibrium speed is
## [code]push / (friction * friction_scale)[/code] once that speed exceeds
## [code]stop_speed[/code].
@export var push: Vector3 = Vector3.ZERO

@export_group("Presentation")

## Tag a game uses to pick footstep sounds, decals or particles.
##
## Carried here so the surface is one lookup rather than two parallel systems that
## can disagree about what the player is standing on.
@export var material_tag: StringName = &""


static func make(p_id: StringName) -> DotFpsSurface:
	var s := DotFpsSurface.new()
	s.id = p_id
	return s


func describe() -> Dictionary:
	return {
		"id": String(id),
		"friction": friction_scale,
		"accelerate": accelerate_scale,
		"max_speed": max_speed_scale,
		"jump": jump_scale,
		"standable": standable,
	}


func _to_string() -> String:
	return "DotFpsSurface(%s)" % id
