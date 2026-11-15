@tool
extends "dot_fps_tunables_base.gd"

## The first exported groups of [DotFpsTunables] (look, profile, speeds, ground and air movement, jumping, surf, crouching).
## Split out of dot_fps_tunables_base.gd for file size and layered above it so the property order is unchanged
## (a derived script lists its properties first). Never instantiate this directly; use [DotFpsTunables].


@export_group("Look")

## Degrees of view rotation per unit of mouse motion.
## Only [DotFpsSampler] reads these; the motor is given absolute angles.
@export_range(0.01, 5.0, 0.01) var mouse_sensitivity: float = 0.25:
	set(value):
		mouse_sensitivity = value
		revision += 1

## Per-axis multipliers on top of [member mouse_sensitivity].
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_x: float = 1.0:
	set(value):
		mouse_sensitivity_x = value
		revision += 1
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_y: float = 1.0:
	set(value):
		mouse_sensitivity_y = value
		revision += 1

@export var invert_look_y: bool = false:
	set(value):
		invert_look_y = value
		revision += 1

## How far the player can look up and down, in degrees.
## Short of ±90 on purpose: exactly vertical makes the forward vector degenerate.
@export_range(-90.0, 0.0, 0.5) var pitch_min: float = -89.0:
	set(value):
		pitch_min = value
		revision += 1
@export_range(0.0, 90.0, 0.5) var pitch_max: float = 89.0:
	set(value):
		pitch_max = value
		revision += 1

@export_group("Profile")

## The named starting set ([constant PROFILE_CLASSIC] or [constant PROFILE_LEGACY]) that
## [method load_layered] applies below the file, environment and command line.
@export var movement_profile: String = "classic":
	set(value):
		movement_profile = value
		revision += 1

@export_group("Speeds")

## Ground speed with no modifier held, in metres per second.
@export_range(0.1, 100.0, 0.1) var max_speed: float = 4.7625:
	set(value):
		max_speed = value
		revision += 1

## Server-wide multiplier on every ground speed (run, walk, crouch, sprint); 1 leaves them as set.
@export_range(0.05, 10.0, 0.01) var speed_scale: float = 1.0:
	set(value):
		speed_scale = value
		revision += 1

## Multipliers applied to [member max_speed]. They do not stack; the most restrictive
## one held wins (crouch, walk, sprint). Derived from the held buttons every tick, because
## a stored multiplier reset on release let a crouched player sprint-run after releasing sprint.
@export_range(0.0, 5.0, 0.01) var crouch_speed_scale: float = 0.34:
	set(value):
		crouch_speed_scale = value
		revision += 1
@export_range(0.0, 5.0, 0.01) var walk_speed_scale: float = 0.52:
	set(value):
		walk_speed_scale = value
		revision += 1
@export_range(0.0, 5.0, 0.01) var sprint_speed_scale: float = 1.0:
	set(value):
		sprint_speed_scale = value
		revision += 1

## Speed multiplier applied when moving backwards, as those games do.
##
## Below 1 it discourages backpedalling in a fight without taking control away.
@export_range(0.1, 1.0, 0.01) var backward_speed_scale: float = 1.0:
	set(value):
		backward_speed_scale = value
		revision += 1

## Hard ceiling on speed in any direction, in m/s.
## A backstop against runaway velocity, not a gameplay number: keep it well above anything legitimate.
@export_range(1.0, 10000.0, 1.0) var max_velocity: float = 66.675:
	set(value):
		max_velocity = value
		revision += 1

## Ceiling on the wish speed a held key asks for, before modifiers, in m/s. 0 disables it.
## The familiar [code]sv_maxspeed[/code]; a modifier still multiplies past it.
@export_range(0.0, 1000.0, 0.01) var max_wish_speed: float = 6.096:
	set(value):
		max_wish_speed = value
		revision += 1

@export_group("Ground movement")

## Acceleration toward the wish direction on the ground, in units of wish speed
## per second. The familiar [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 5.0:
	set(value):
		accelerate = value
		revision += 1

## Friction applied on the ground. The familiar [code]sv_friction[/code].
@export_range(0.0, 20.0, 0.1) var friction: float = 4.0:
	set(value):
		friction = value
		revision += 1

## Speed below which friction is applied as if the player were moving this fast.
## Without it friction asymptotes toward zero and the player drifts after releasing the keys.
## The familiar [code]sv_stopspeed[/code].
@export_range(0.0, 50.0, 0.1) var stop_speed: float = 1.42875:
	set(value):
		stop_speed = value
		revision += 1

@export_group("Air movement")

## Acceleration while airborne. The familiar [code]sv_airaccelerate[/code].
## Large on purpose: it is bounded by [member max_air_wish_speed], which is what makes
## air-strafing work (see [method DotFpsMotor.accelerate]).
@export_range(0.0, 1000.0, 1.0) var air_accelerate: float = 10.0:
	set(value):
		air_accelerate = value
		revision += 1

## The cap that makes air-strafing possible, in m/s: the whole of air control.
## Airborne acceleration is clamped to the velocity's projection on the wish direction;
## raise it and air control becomes a jetpack, set it to zero and there is none.
@export_range(0.0, 100.0, 0.1) var max_air_wish_speed: float = 0.5715:
	set(value):
		max_air_wish_speed = value
		revision += 1

## Downward acceleration, in m/s².
## Not read from project physics settings, which a host may change and a client and server could disagree about.
@export_range(0.0, 200.0, 0.1) var gravity: float = 15.24:
	set(value):
		gravity = value
		revision += 1

## Air friction. Zero in this movement model, and changing it breaks strafe-jumping.
@export_range(0.0, 20.0, 0.05) var air_friction: float = 0.0:
	set(value):
		air_friction = value
		revision += 1

@export_group("Jumping")

## Peak height of a standing jump on flat ground, in metres.
## Converted with [code]sqrt(2 * gravity * height)[/code], so it stays honest when gravity changes.
@export_range(0.0, 20.0, 0.01) var jump_height: float = 1.08585:
	set(value):
		jump_height = value
		revision += 1

## Jump by holding the button rather than tapping it.
## What makes bunny-hopping a skill rather than a keybind. Off by default.
@export var auto_hop: bool = false:
	set(value):
		auto_hop = value
		revision += 1

## Add the launch speed to upward velocity instead of replacing it.
## Off is the classic behaviour; on lets jumps stack on ramps and pads, and a physics bug become an infinite climb.
@export var jump_adds_to_velocity: bool = false:
	set(value):
		jump_adds_to_velocity = value
		revision += 1

## Seconds after walking off a ledge during which a jump still works.
## Players press jump slightly late and read the failure as a missed input.
@export_range(0.0, 0.5, 0.005) var coyote_time: float = 0.0:
	set(value):
		coyote_time = value
		revision += 1

## Seconds before landing during which a jump press is remembered.
## The other half of the same forgiveness: a press just before touchdown jumps on touchdown.
@export_range(0.0, 0.5, 0.005) var jump_buffer_time: float = 0.0:
	set(value):
		jump_buffer_time = value
		revision += 1

## Minimum seconds between jumps. 0 allows one per tick.
@export_range(0.0, 2.0, 0.005) var jump_cooldown: float = 0.0:
	set(value):
		jump_cooldown = value
		revision += 1

@export_group("Surf and bunny-hopping")

## Speed a jump is clamped to, as a multiple of [member max_speed]. 0 disables it.
## The landing cap of retail shooters (1.104); [code]sv_enablebunnyhopping[/code] exists to turn it off.
## Off here because a movement shooter that caps hop speed has no bunny-hopping.
@export_range(0.0, 10.0, 0.001) var bhop_speed_cap_scale: float = 0.0:
	set(value):
		bhop_speed_cap_scale = value
		revision += 1

## Extra friction while standing near a ledge, as a multiplier. 1 disables it.
## The familiar [code]sv_edgefriction[/code] (ships at 2). Costs one extra query per grounded tick,
## so it is off by default; a KZ or bhop server turns it on.
@export_range(1.0, 10.0, 0.05) var edge_friction: float = 1.0:
	set(value):
		edge_friction = value
		revision += 1

## How far past the player's own radius to look for the ledge, in metres.
@export_range(0.0, 2.0, 0.01) var edge_friction_reach: float = 0.4:
	set(value):
		edge_friction_reach = value
		revision += 1

## How far down has to be empty for it to count as a ledge, in metres.
@export_range(0.05, 5.0, 0.01) var edge_friction_drop: float = 0.6:
	set(value):
		edge_friction_drop = value
		revision += 1

## Resolve a two-plane wedge by moving along the crease instead of stopping.
## A naive slide clips against plane one then plane two and stops a surfer dead at a ramp seam;
## this remembers every plane touched and slides along their intersection. Off, plain sequential slide.
@export var crease_slide: bool = true:
	set(value):
		crease_slide = value
		revision += 1

## Planes remembered per move for [member crease_slide].
## The classic implementations use five. More is not better: a player inside a five-plane wedge
## has nowhere to go, and searching on finds a way into the geometry.
@export_range(2, 8, 1) var max_slide_planes: int = 5:
	set(value):
		max_slide_planes = value
		revision += 1

## Speed, as a multiple of [member max_speed], above which a walkable ramp's crest launches the
## player instead of holding them to the floor. 0 never launches. At 1.25 running speed stays
## grounded and hop speed is thrown; a server that wants always-grounded sets 0.
@export_range(0.0, 10.0, 0.01) var crest_launch_speed_scale: float = 1.25:
	set(value):
		crest_launch_speed_scale = value
		revision += 1

@export_group("Crouching")

## Standing collision height, in metres: 72 units on a 0.0254 m/unit map. The capsule's total height.
@export_range(0.2, 5.0, 0.01) var stand_height: float = 1.83:
	set(value):
		stand_height = value
		revision += 1

## Crouched collision height, in metres: 54 units on a 0.0254 m/unit map.
@export_range(0.2, 5.0, 0.01) var crouch_height: float = 1.372:
	set(value):
		crouch_height = value
		revision += 1

## Collider radius, in metres: half of a 32 unit hull width.
@export_range(0.05, 2.0, 0.01) var radius: float = 0.4064:
	set(value):
		radius = value
		revision += 1

## Seconds to move fully between standing and crouching.
## Part of the simulation, not a visual: the collider changes size over it, so peers must agree.
@export_range(0.0, 2.0, 0.005) var crouch_transition_time: float = 0.12:
	set(value):
		crouch_transition_time = value
		revision += 1

## Crouch instantly while airborne.
## The classic crouch-jump: snapping the collider up mid-air clears ledges. Players expect it.
@export var instant_air_crouch: bool = true:
	set(value):
		instant_air_crouch = value
		revision += 1
