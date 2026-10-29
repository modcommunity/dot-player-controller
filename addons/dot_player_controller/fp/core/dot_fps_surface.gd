@tool
class_name DotFpsSurface
extends Resource

## How one kind of ground behaves under the player. Ice, mud, metal, a conveyor.
## Multipliers on [DotFpsTunables], so retuning the base feel moves every surface. Simulation, not decoration:
## resolved from something both machines see ([method DotFpsSurfaceSet.resolve_from_node]), never an instance id.

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

## Whether this surface can be stood on at all; false behaves like a wall (a rail, a pane of glass).
@export var standable: bool = true

## Constant push applied while standing on it, in m/s², in world space.
## Friction wins by default: a push under stop_speed * friction * friction_scale cannot move a standing player.
## Equilibrium and numbers: docs/rationale.md.
@export var push: Vector3 = Vector3.ZERO

## How much of a hard landing this surface takes away: 0 none, 1 all (snow, a mattress, a
## hay bale). Read by dot-combat's DotFallDamage; the controller itself ignores it.
@export_range(0.0, 1.0, 0.01) var fall_damping: float = 0.0

@export_group("Presentation")

## Tag a game uses to pick footstep sounds, decals or particles, so there is one lookup.
@export var material_tag: StringName = &""


static func make(p_id: StringName) -> DotFpsSurface:
	var s := DotFpsSurface.new()
	s.id = p_id
	return s


## A movement surface read off a dot-physics `DotPhysicsSurface` (duck-typed: no dependency).
## `traction` is the friction scale, `move_scale` the acceleration scale, `dampening` lowers top speed
## (1 - 0.15 per unit, floor 0.4), `jump_scale` carries over; a `liquid` or non-`solid` is not stood on.
static func from_physics(surface: Object) -> DotFpsSurface:
	var s := DotFpsSurface.new()
	if surface == null:
		return s
	s.id = surface.get("id")
	s.material_tag = s.id
	s.friction_scale = float(surface.get("traction"))
	s.accelerate_scale = float(surface.get("move_scale"))
	s.max_speed_scale = clampf(1.0 - float(surface.get("dampening")) * 0.15, 0.4, 1.0)
	var jump: Variant = surface.get("jump_scale")
	s.jump_scale = float(jump) if jump != null else 1.0
	var liquid: Variant = surface.get("liquid")
	var solid: Variant = surface.get("solid")
	s.standable = not (liquid != null and bool(liquid)) and not (solid != null and not bool(solid))
	return s


func describe() -> Dictionary:
	return {
		"id": String(id),
		"friction": friction_scale,
		"accelerate": accelerate_scale,
		"max_speed": max_speed_scale,
		"jump": jump_scale,
		"standable": standable,
		"fall_damping": fall_damping,
	}


func _to_string() -> String:
	return "DotFpsSurface(%s)" % id
