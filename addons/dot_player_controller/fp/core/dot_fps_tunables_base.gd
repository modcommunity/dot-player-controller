@tool
extends DotConfig

## The exported numbers of [DotFpsTunables], kept apart so the class that reads them stays small.
## Never instantiate this directly; use [DotFpsTunables].

@export_group("Look")

## Degrees of view rotation per unit of mouse motion.
## Only [DotFpsSampler] reads these; the motor is given absolute angles.
@export_range(0.01, 5.0, 0.01) var mouse_sensitivity: float = 0.25

## Per-axis multipliers on top of [member mouse_sensitivity].
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_x: float = 1.0
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_y: float = 1.0

@export var invert_look_y: bool = false

## How far the player can look up and down, in degrees.
## Short of ±90 on purpose: exactly vertical makes the forward vector degenerate.
@export_range(-90.0, 0.0, 0.5) var pitch_min: float = -89.0
@export_range(0.0, 90.0, 0.5) var pitch_max: float = 89.0

@export_group("Profile")

## The named starting set ([constant PROFILE_CLASSIC] or [constant PROFILE_LEGACY]) that
## [method load_layered] applies below the file, environment and command line.
@export var movement_profile: String = "classic"

@export_group("Speeds")

## Ground speed with no modifier held, in metres per second.
@export_range(0.1, 100.0, 0.1) var max_speed: float = 4.7625

## Multipliers applied to [member max_speed]. They do not stack; the most restrictive
## one held wins (crouch, walk, sprint). Derived from the held buttons every tick, because
## a stored multiplier reset on release let a crouched player sprint-run after releasing sprint.
@export_range(0.0, 5.0, 0.01) var crouch_speed_scale: float = 0.34
@export_range(0.0, 5.0, 0.01) var walk_speed_scale: float = 0.52
@export_range(0.0, 5.0, 0.01) var sprint_speed_scale: float = 1.0

## Speed multiplier applied when moving backwards, as those games do.
##
## Below 1 it discourages backpedalling in a fight without taking control away.
@export_range(0.1, 1.0, 0.01) var backward_speed_scale: float = 1.0

## Hard ceiling on speed in any direction, in m/s.
## A backstop against runaway velocity, not a gameplay number: keep it well above anything legitimate.
@export_range(1.0, 10000.0, 1.0) var max_velocity: float = 66.675

## Ceiling on the wish speed a held key asks for, before modifiers, in m/s. 0 disables it.
## The familiar [code]sv_maxspeed[/code]; a modifier still multiplies past it.
@export_range(0.0, 1000.0, 0.01) var max_wish_speed: float = 6.096

@export_group("Ground movement")

## Acceleration toward the wish direction on the ground, in units of wish speed
## per second. The familiar [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 5.0

## Friction applied on the ground. The familiar [code]sv_friction[/code].
@export_range(0.0, 20.0, 0.1) var friction: float = 4.0

## Speed below which friction is applied as if the player were moving this fast.
## Without it friction asymptotes toward zero and the player drifts after releasing the keys.
## The familiar [code]sv_stopspeed[/code].
@export_range(0.0, 50.0, 0.1) var stop_speed: float = 1.42875

@export_group("Air movement")

## Acceleration while airborne. The familiar [code]sv_airaccelerate[/code].
## Large on purpose: it is bounded by [member max_air_wish_speed], which is what makes
## air-strafing work (see [method DotFpsMotor.accelerate]).
@export_range(0.0, 1000.0, 1.0) var air_accelerate: float = 10.0

## The cap that makes air-strafing possible, in m/s: the whole of air control.
## Airborne acceleration is clamped to the velocity's projection on the wish direction;
## raise it and air control becomes a jetpack, set it to zero and there is none.
@export_range(0.0, 100.0, 0.1) var max_air_wish_speed: float = 0.5715

## Downward acceleration, in m/s².
## Not read from project physics settings, which a host may change and a client and server could disagree about.
@export_range(0.0, 200.0, 0.1) var gravity: float = 15.24

## Air friction. Zero in this movement model, and changing it breaks strafe-jumping.
@export_range(0.0, 20.0, 0.05) var air_friction: float = 0.0

@export_group("Jumping")

## Peak height of a standing jump on flat ground, in metres.
## Converted with [code]sqrt(2 * gravity * height)[/code], so it stays honest when gravity changes.
@export_range(0.0, 20.0, 0.01) var jump_height: float = 1.08585

## Jump by holding the button rather than tapping it.
## What makes bunny-hopping a skill rather than a keybind. Off by default.
@export var auto_hop: bool = false

## Add the launch speed to upward velocity instead of replacing it.
## Off is the classic behaviour; on lets jumps stack on ramps and pads, and a physics bug become an infinite climb.
@export var jump_adds_to_velocity: bool = false

## Seconds after walking off a ledge during which a jump still works.
## Players press jump slightly late and read the failure as a missed input.
@export_range(0.0, 0.5, 0.005) var coyote_time: float = 0.0

## Seconds before landing during which a jump press is remembered.
## The other half of the same forgiveness: a press just before touchdown jumps on touchdown.
@export_range(0.0, 0.5, 0.005) var jump_buffer_time: float = 0.0

## Minimum seconds between jumps. 0 allows one per tick.
@export_range(0.0, 2.0, 0.005) var jump_cooldown: float = 0.0

@export_group("Surf and bunny-hopping")

## Speed a jump is clamped to, as a multiple of [member max_speed]. 0 disables it.
## The landing cap of retail shooters (1.104); [code]sv_enablebunnyhopping[/code] exists to turn it off.
## Off here because a movement shooter that caps hop speed has no bunny-hopping.
@export_range(0.0, 10.0, 0.001) var bhop_speed_cap_scale: float = 0.0

## Extra friction while standing near a ledge, as a multiplier. 1 disables it.
## The familiar [code]sv_edgefriction[/code] (ships at 2). Costs one extra query per grounded tick,
## so it is off by default; a KZ or bhop server turns it on.
@export_range(1.0, 10.0, 0.05) var edge_friction: float = 1.0

## How far past the player's own radius to look for the ledge, in metres.
@export_range(0.0, 2.0, 0.01) var edge_friction_reach: float = 0.4

## How far down has to be empty for it to count as a ledge, in metres.
@export_range(0.05, 5.0, 0.01) var edge_friction_drop: float = 0.6

## Resolve a two-plane wedge by moving along the crease instead of stopping.
## A naive slide clips against plane one then plane two and stops a surfer dead at a ramp seam;
## this remembers every plane touched and slides along their intersection. Off, plain sequential slide.
@export var crease_slide: bool = true

## Planes remembered per move for [member crease_slide].
## The classic implementations use five. More is not better: a player inside a five-plane wedge
## has nowhere to go, and searching on finds a way into the geometry.
@export_range(2, 8, 1) var max_slide_planes: int = 5

## Speed, as a multiple of [member max_speed], above which a walkable ramp's crest launches the
## player instead of holding them to the floor. 0 never launches. At 1.25 running speed stays
## grounded and hop speed is thrown; a server that wants always-grounded sets 0.
@export_range(0.0, 10.0, 0.01) var crest_launch_speed_scale: float = 1.25

@export_group("Crouching")

## Standing collision height, in metres. The capsule's total height.
@export_range(0.2, 5.0, 0.01) var stand_height: float = 1.8

## Crouched collision height, in metres.
@export_range(0.2, 5.0, 0.01) var crouch_height: float = 0.9

## Collider radius, in metres.
@export_range(0.05, 2.0, 0.01) var radius: float = 0.35

## Seconds to move fully between standing and crouching.
## Part of the simulation, not a visual: the collider changes size over it, so peers must agree.
@export_range(0.0, 2.0, 0.005) var crouch_transition_time: float = 0.12

## Crouch instantly while airborne.
## The classic crouch-jump: snapping the collider up mid-air clears ledges. Players expect it.
@export var instant_air_crouch: bool = true

@export_group("Collision")

## Steepest floor the player can stand on, in degrees. Anything steeper is a wall.
@export_range(0.0, 89.0, 0.5) var max_slope_angle: float = 46.0

## Tallest step the player walks up without jumping, in metres.
## The familiar [code]sv_stepsize[/code]. Without it every kerb stops the player dead,
## the commonest flaw of a hand-written character controller.
@export_range(0.0, 2.0, 0.01) var step_height: float = 0.3429

## Keep the player attached to the ground when walking down slopes and steps.
## Off, a ramp descent is a string of airborne ticks: no friction, no ground acceleration.
@export var ground_snap: bool = true

## How far below the feet to look for ground when snapping, in metres.
@export_range(0.0, 2.0, 0.01) var ground_snap_distance: float = 0.35

## Collide-and-slide iterations per move. More handles tighter corners.
@export_range(1, 16, 1) var max_slide_iterations: int = 5

## Gap kept between the collider and surfaces, in metres.
## Resting exactly on a surface leaves the next query at the mercy of rounding, which
## reads as intermittently falling through the floor.
@export_range(0.0, 0.1, 0.0001) var skin_width: float = 0.001

## Physics collision layers the player collides with.
@export_flags_3d_physics var collision_mask: int = 1

@export_group("Abilities")

## Whether the crouch button does anything.
@export var can_crouch: bool = true
@export var can_sprint: bool = true

@export_group("Sprint stamina")

## Whether sprinting drains [member DotFpsState.stamina] and stops when it is empty. Off keeps sprint free.
@export var stamina_enabled: bool = false

## Stamina (a 0 to 1 fraction) lost per second of sprinting while moving.
@export_range(0.0, 10.0, 0.01) var stamina_drain: float = 0.2

## Stamina regained per second when not sprinting.
@export_range(0.0, 10.0, 0.01) var stamina_recover: float = 0.15

## After running out, sprint refuses until stamina is back to this fraction.
@export_range(0.0, 1.0, 0.01) var stamina_resume_at: float = 0.3

## Seconds after running out before stamina starts to refill.
@export_range(0.0, 3.5, 0.05) var stamina_exhaust_delay: float = 1.0

## How strongly the carried load (0 empty to 1 at capacity, set on the motor) cuts the sprint bonus; 0 off.
@export_range(0.0, 2.0, 0.01) var sprint_load_speed: float = 0.0

## How strongly the carried load raises the stamina drain; 0 off.
@export_range(0.0, 4.0, 0.01) var sprint_load_drain: float = 0.0

## Whether a sprinting player may aim down sights or reload (read by weapon code through [member DotFpsState.sprinting]).
@export var sprint_blocks_aim: bool = false

## Whether a sprinting player may fire (read by weapon code through `motion()`); false blocks the trigger while sprinting.
@export var sprint_can_shoot: bool = true

## Whether a shot fired while sprinting leaves along the lowered barrel instead of the crosshair.
@export var sprint_shot_follows_barrel: bool = true

## Whether taking damage drops the player out of the sights ([DotFpsAimBreak]). Off: the sights stay and the hit shakes the view and wobbles the aim instead (the `hit_*` members).
@export var unscope_on_hit: bool = false

## Seconds the sights stay refused after a hit.
@export_range(0.0, 3.0, 0.05) var unscope_hit_time: float = 0.4

## Degrees of camera roll a hit shakes the view by (and a few millimetres of offset); 0 off. Read when `unscope_on_hit` is off.
@export_range(0.0, 10.0, 0.05) var hit_shake: float = 1.2

## Degrees the aim wobbles by after a hit (it moves where the shots go); 0 off.
@export_range(0.0, 10.0, 0.05) var hit_wobble: float = 0.6

## Wobble and shake cycles per second.
@export_range(0.5, 30.0, 0.5) var hit_wobble_hz: float = 9.0

## Seconds a hit's shake and wobble last, fading to nothing; 0 turns the flinch off.
@export_range(0.0, 3.0, 0.05) var hit_flinch_time: float = 0.5

## How much the damage taken scales the shake and wobble: 0 the same for every hit, 1 in proportion (25 damage is the 1x hit).
@export_range(0.0, 1.0, 0.05) var hit_damage_scale: float = 0.5

## Whether the sprint button toggles instead of being held (read by [DotFpsSampler]; stopping clears it).
@export var sprint_toggle: bool = false
@export var can_walk: bool = true
@export var can_jump: bool = true

## Whether the noclip button does anything.
## Off by default and gated separately on the server, because a client can set this bit
## in a command at will. See [DotFpsController.allow_noclip].
@export var can_noclip: bool = false

## Noclip flight speed, in m/s.
@export_range(0.1, 200.0, 0.1) var noclip_speed: float = 16.0

## How quickly noclip velocity settles toward the wish velocity, per second.
@export_range(0.1, 100.0, 0.1) var noclip_accelerate: float = 12.0

@export_group("Sliding")

## Whether pressing crouch while running starts a slide.
## Off by default: every number below is read only while this is on, so a game that never
## sets it simulates what it did before sliding. In [method fingerprint], as peers must agree.
@export var slide_enabled: bool = false

## Horizontal speed, in m/s, a grounded player needs for a crouch press to start a slide
## rather than an ordinary crouch.
@export_range(0.0, 100.0, 0.1) var slide_min_speed: float = 6.0

## Speed added along the run when a slide starts, in m/s. 0 for a slide with no burst.
@export_range(0.0, 50.0, 0.1) var slide_boost: float = 3.0

## The boost never takes horizontal speed past this, in m/s.
## A cap on the boost, not on the slide: a faster player keeps their speed and gets no burst,
## since clamping them down would make sliding a way to lose speed.
@export_range(0.0, 100.0, 0.1) var slide_max_speed: float = 13.0

## Ground friction while sliding, in place of [member friction]. Low, so a slide carries.
@export_range(0.0, 20.0, 0.05) var slide_friction: float = 0.8

## Acceleration toward the wish direction while sliding, in place of [member accelerate].
## It steers rather than speeds up (the crouched wish speed is below a slider's speed), so it
## only bends the run. 0 locks the direction.
@export_range(0.0, 100.0, 0.1) var slide_accelerate: float = 2.0

## The longest a slide lasts, in seconds, before it settles into an ordinary crouch.
@export_range(0.05, 10.0, 0.05) var slide_duration: float = 1.0

## A slide that slows below this horizontal speed, in m/s, ends early.
@export_range(0.0, 50.0, 0.1) var slide_end_speed: float = 3.0

## Seconds after a slide ends before another can start.
@export_range(0.0, 10.0, 0.05) var slide_cooldown: float = 0.5

## Whether a slide also needs the sprint button held.
@export var slide_requires_sprint: bool = false

@export_group("Launch")

## Whether [member launch_button] throws the player into the air. Off by default, like
## [member slide_enabled]. An ability, not a [DotFpsModifier]: it is an impulse and a modifier
## is a multiplier.
@export var launch_enabled: bool = false

## The command button that launches, as a [DotFpsCommand] button bit
## ([code]BUTTON_USER_0[/code] is 32). 0 means no button does.
## A setting rather than a new bit, because every wire bit is already spoken for.
@export_range(0, 255, 1) var launch_button: int = 0

## Upward speed a launch sets, in m/s. It replaces a lower vertical speed rather than
## adding to it, so a launch at the top of a jump goes as high as one from the ground.
@export_range(0.0, 100.0, 0.1) var launch_velocity: float = 13.0

## Speed added along the view's heading, in m/s, flat. 0 for straight up.
@export_range(0.0, 100.0, 0.1) var launch_forward: float = 0.0

## Seconds between launches.
@export_range(0.0, 600.0, 0.1) var launch_cooldown: float = 8.0

## Whether a launch works in mid-air. Off, it needs the ground (or coyote time).
@export var launch_from_air: bool = true

@export_group("Dash")

## Whether [member dash_button] throws the player along the way they are moving.
## Off by default, like the launch and for the same reason.
@export var dash_enabled: bool = false

## The command button that dashes, as a [DotFpsCommand] button bit. 0 means none. A game
## with no sprint can give it the sprint bit, which is already on the wire.
@export_range(0, 255, 1) var dash_button: int = 0

## Horizontal speed a dash sets along its direction, in m/s. A player already faster
## along it keeps their speed: a dash is never a brake.
@export_range(0.0, 100.0, 0.1) var dash_speed: float = 16.0

## Upward speed a dash adds, in m/s, so a dash from the ground leaves it for a moment and
## ground friction does not eat it on the first tick.
@export_range(0.0, 20.0, 0.1) var dash_lift: float = 2.5

## Seconds between dashes.
@export_range(0.0, 600.0, 0.1) var dash_cooldown: float = 3.0

## Whether a dash works in mid-air.
@export var dash_from_air: bool = true

@export_group("Wall running")

## Whether an airborne player moving fast along a near-vertical wall runs along it.
## Off by default, like the slide: every [code]wall_run_*[/code] number is read only behind this and
## no wall probe is made. Reasoning in docs/wall-movement.md.
@export var wall_run_enabled: bool = false

## Horizontal speed ALONG the wall, in m/s, an airborne player needs to start a run.
## Measured along the wall rather than in total, so running into it head-on is no run.
@export_range(0.0, 100.0, 0.1) var wall_run_min_speed: float = 6.0

## A run that slows below this speed along the wall, in m/s, ends.
@export_range(0.0, 100.0, 0.1) var wall_run_end_speed: float = 3.0

## The longest a run lasts, in seconds: "a few steps". At most
## [constant WALL_RUN_TIME_LIMIT], which is what the replicated field can hold.
@export_range(0.05, 1.9, 0.05) var wall_run_max_time: float = 1.0

## Gravity while running, as a multiple of [member gravity]. 0 holds the height; 1 is
## an ordinary fall (with [member wall_run_vertical_damping] still slowing it).
@export_range(0.0, 1.0, 0.01) var wall_run_gravity_scale: float = 0.25

## How fast the vertical speed a player arrives with is eased away while running, per second.
## Eased rather than zeroed: zeroing is a one-tick velocity spike. With [member wall_run_gravity_scale]
## it sets the slow sink a long run settles into ([code]gravity * scale / damping[/code]).
@export_range(0.0, 60.0, 0.1) var wall_run_vertical_damping: float = 8.0

## A player falling faster than this, in m/s, does not catch a wall. Brushing a wall must
## not be a way to stop a long fall.
@export_range(0.0, 100.0, 0.1) var wall_run_max_fall_speed: float = 6.0

## The steepest angle a wall may lean from vertical, in degrees, and still be run on or
## jumped off. Applies to the wall jump too.
@export_range(0.0, 45.0, 0.5) var wall_max_angle_from_vertical: float = 15.0

## The largest angle, in degrees, between the player's horizontal velocity and the wall's
## plane at which a run starts. The velocity must be at least [code]90 - this[/code] degrees
## from straight into the wall. 0 needs a velocity exactly along it; 90 accepts any.
@export_range(0.0, 90.0, 0.5) var wall_run_max_approach_angle: float = 60.0

## How tall a wall must be, in metres, for a run to START on it: the face has to reach this far
## up and down around the contact and above the player's hip. A crate edge or low ledge is not
## a wall to run on, though a wall jump off it still works. 0 turns the check off.
@export_range(0.0, 20.0, 0.1) var wall_run_min_height: float = 2.0

## How far the wall must continue ahead along the run, in metres, for a run to start. 0 is off.
@export_range(0.0, 20.0, 0.1) var wall_run_min_length: float = 1.0

## Whether forward has to be held to start and to keep running. Releasing it drops off
## the wall, which is the player's way off a run short of jumping.
@export var wall_run_requires_forward: bool = true

## Whether a jump press in the air beside a wall STARTS a run (the heading turns along the
## wall, at the speed the player had), and a second press leaves it by the wall jump.
## Needs [member wall_run_enabled]. Off by default.
@export var wall_run_on_jump: bool = false

## Airborne and moving into a wall within the jump-run limits starts a run with no press
## (the heading turns along the wall); a press then wall-jumps. Replaces the on-jump press.
@export var wall_run_auto: bool = false

## Horizontal speed, in m/s, a jump-started run needs. The speed is not measured along the
## wall: the press turns the heading, so any approach angle up to
## [member wall_run_jump_max_angle] qualifies.
@export_range(0.0, 100.0, 0.1) var wall_run_jump_min_speed: float = 5.0

## Widest angle, in degrees, between the velocity and the wall's plane at which a press
## starts a run. 90 accepts a head-on approach.
@export_range(0.0, 90.0, 0.5) var wall_run_jump_max_angle: float = 75.0

## Seconds after a run ends before another may start, jump-started or not. 0 for none.
@export_range(0.0, 10.0, 0.05) var wall_run_cooldown: float = 0.0
## A jump-started run turns the player's view along the wall (the owner's look input is rotated once).
@export var wall_run_turn_view: bool = false

## How far beside the player, in metres, a wall still counts as touched: for a run, and
## for a wall jump off a wall the player is not running on.
@export_range(0.01, 1.0, 0.01) var wall_reach: float = 0.25

## Fastest fall, in m/s, of an airborne player against a wall they push into or whose run ended
## on it: the wall slide, and what a timed-out run decays into. 0 turns it off (default).
## A faster fall is eased down at [member wall_run_vertical_damping], never cut in one tick.
@export_range(0.0, 50.0, 0.1) var wall_slide_speed: float = 0.0

@export_group("Wall jumping")

## Whether a jump press in the air beside a wall (touched or run on) jumps off it.
## Off by default, like [member wall_run_enabled]; the two are independent.
@export var wall_jump_enabled: bool = false

## Speed a wall jump pushes away from the wall, in m/s. The speed the player had along
## the wall is kept on top of it.
@export_range(0.0, 50.0, 0.1) var wall_jump_push_speed: float = 7.0

## Upward speed a wall jump sets, in m/s. It replaces a lower vertical speed rather than
## adding to it, like the launch.
@export_range(0.0, 50.0, 0.1) var wall_jump_up_speed: float = 6.5

## How far the push leans from the wall's normal toward where the player looks, 0..1.
## 0 pushes straight out; the part of the look into the wall is ignored, so the push
## always leaves the wall.
@export_range(0.0, 1.0, 0.01) var wall_jump_look_blend: float = 0.3

## Wall jumps off the same wall before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width. The same wall is the same normal (within
## an eighth of a turn), so facing corridor walls can be climbed between but one alone cannot.
@export_range(0, 3, 1) var wall_jump_max_per_wall: int = 1

## Wall jumps in all, off any walls, before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width. On top of [member wall_jump_max_per_wall]:
## the budget a single airborne stretch gets, refilled only by landing.
@export_range(0, 3, 1) var wall_jump_max_per_air: int = 3
