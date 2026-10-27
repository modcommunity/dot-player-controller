@tool
class_name DotFpsTunables
extends DotConfig

## Every number the movement simulation reads. Layered like every [DotConfig]:
## exported defaults, then a JSON file, then [code]DOT_FPS_*[/code] environment
## variables, then [code]--fps-*[/code] arguments.
##
## [b]Why a config resource and not exports on the controller.[/b] A dedicated
## server has to be able to run a mode with different movement without an editor and
## without a rebuild — the same reason those engines expose [code]sv_accelerate[/code] and
## [code]sv_airaccelerate[/code] as cvars rather than compile-time constants. Making
## this a [Resource] also means a game can ship several (`movement_default.tres`,
## `movement_lowgrav.tres`) and swap them per map or per round.
##
## [b]These values must be identical on the client and the server.[/b] They are an
## input to the simulation, so a client running different ones diverges from the
## server every tick and reconciliation corrects it forever. A server should send its
## own set at connect time rather than trusting the client's copy; see
## [method fingerprint].
##
## The defaults are the classic competitive-shooter profile ([constant PROFILE_CLASSIC]):
## every number is that genre's, converted from its 0.01905 m units, so ground friction with
## a stop speed, a low-wish-speed air cap and strafe-jumping behave as players know them.
## [constant PROFILE_LEGACY] is the movement-shooter set this class shipped before; see
## [method apply_profile]. Every number is also a server cvar ([method cvar_specs]).

@export_group("Look")

## Degrees of view rotation per unit of mouse motion.
##
## Only [DotFpsSampler] reads these — the motor is given absolute angles. A game with
## a sensitivity slider changes them here and nothing else has to know.
@export_range(0.01, 5.0, 0.01) var mouse_sensitivity: float = 0.25

## Per-axis multipliers on top of [member mouse_sensitivity].
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_x: float = 1.0
@export_range(0.0, 5.0, 0.01) var mouse_sensitivity_y: float = 1.0

@export var invert_look_y: bool = false

## How far the player can look up and down, in degrees.
##
## Stopping short of ±90 is deliberate: exactly vertical makes the forward vector
## degenerate, and every frame spent there is a frame where yaw has no visible effect.
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
## one held wins, in the order crouch, walk, sprint.
##
## [b]This ordering is the fix for a real bug.[/b] The previous controller stored one
## [code]speed_multiplier[/code] and each of crouch/walk/sprint reset it to 1 on
## release, so releasing sprint while still crouched restored full speed and the
## player crouch-ran at sprint speed. Deriving the scale from the held buttons every
## tick makes that unrepresentable.
@export_range(0.0, 5.0, 0.01) var crouch_speed_scale: float = 0.34
@export_range(0.0, 5.0, 0.01) var walk_speed_scale: float = 0.52
@export_range(0.0, 5.0, 0.01) var sprint_speed_scale: float = 1.0

## Speed multiplier applied when moving backwards, as those games do.
##
## Below 1 it discourages backpedalling in a fight without taking control away.
@export_range(0.1, 1.0, 0.01) var backward_speed_scale: float = 1.0

## Hard ceiling on speed in any direction, in m/s.
##
## A backstop against a bug or an exploit compounding into an unbounded velocity, not
## a gameplay number. Keep it well above anything the game can legitimately reach —
## clamping a launcher or a conveyor is a worse failure than the runaway it prevents.
@export_range(1.0, 10000.0, 1.0) var max_velocity: float = 66.675

## Ceiling on the wish speed a held key asks for, before modifiers, in m/s. 0 disables it.
##
## The familiar [code]sv_maxspeed[/code]. A scale above 1 (or a raised [member max_speed]) cannot
## ask for more than this, as on the shooter servers; a modifier still multiplies past it.
@export_range(0.0, 1000.0, 0.01) var max_wish_speed: float = 6.096

@export_group("Ground movement")

## Acceleration toward the wish direction on the ground, in units of wish speed
## per second. The familiar [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 5.0

## Friction applied on the ground. The familiar [code]sv_friction[/code].
@export_range(0.0, 20.0, 0.1) var friction: float = 4.0

## Speed below which friction is applied as if the player were moving this fast.
##
## Without it friction is proportional to speed and asymptotes toward zero, so a
## player drifts for a long time at walking pace after releasing the keys. The
## familiar
## [code]sv_stopspeed[/code].
@export_range(0.0, 50.0, 0.1) var stop_speed: float = 1.42875

@export_group("Air movement")

## Acceleration while airborne. The familiar [code]sv_airaccelerate[/code].
##
## Large — 100 is not a typo. It is bounded by [member max_air_wish_speed], not by
## this, which is exactly the mechanism that makes air-strafing work: see
## [method DotFpsMotor.accelerate].
@export_range(0.0, 1000.0, 1.0) var air_accelerate: float = 10.0

## The cap that makes air-strafing possible, in m/s.
##
## [b]The whole of air control is this one number.[/b] Airborne acceleration is
## clamped to the projection of current velocity onto the wish direction, so holding
## strafe and turning adds speed perpendicular to motion — which barely reduces the
## projection, so it can be added again next tick. Raise it and air control becomes
## a jetpack; set it to zero and there is none at all.
@export_range(0.0, 100.0, 0.1) var max_air_wish_speed: float = 0.5715

## Downward acceleration, in m/s².
##
## Not read from the project's physics settings: those are a rendering-side default
## that a host project may change for its rigid bodies, and a value the client and
## server could disagree about is a value the simulation cannot use.
@export_range(0.0, 200.0, 0.1) var gravity: float = 15.24

## Air friction. Zero in this movement model, and changing it breaks strafe-jumping.
@export_range(0.0, 20.0, 0.05) var air_friction: float = 0.0

@export_group("Jumping")

## Peak height of a standing jump on flat ground, in metres.
##
## Converted to a launch speed with [code]sqrt(2 * gravity * height)[/code], so it
## stays honest when gravity is changed.
@export_range(0.0, 20.0, 0.01) var jump_height: float = 1.08585

## Jump by holding the button rather than tapping it.
##
## The difference between bunny-hopping being a skill and being a keybind. Off by
## default; a movement game usually wants it on.
@export var auto_hop: bool = false

## Add the launch speed to upward velocity instead of replacing it.
##
## Off is the classic behaviour and is what most games want. On lets jumps stack on
## anything already moving the player upward — ramps, pads, another jump — which is
## fun and is also how a physics bug becomes an infinite climb.
@export var jump_adds_to_velocity: bool = false

## Seconds after walking off a ledge during which a jump still works.
##
## Players press jump slightly late and read the failure as the game missing the
## input. Costs nothing when the player is on the ground.
@export_range(0.0, 0.5, 0.005) var coyote_time: float = 0.0

## Seconds before landing during which a jump press is remembered.
##
## The other half of the same forgiveness: pressing jump just before touching down
## should jump on touchdown, not be swallowed.
@export_range(0.0, 0.5, 0.005) var jump_buffer_time: float = 0.0

## Minimum seconds between jumps. 0 allows one per tick.
@export_range(0.0, 2.0, 0.005) var jump_cooldown: float = 0.0

@export_group("Surf and bunny-hopping")

## Speed a jump is clamped to, as a multiple of [member max_speed]. 0 disables it.
##
## The landing cap those shooters ship at 1.104:
## a player leaving the ground faster than that has their horizontal velocity scaled
## back down, so hopping cannot compound speed. A bhop or surf server turns it off,
## which is the whole reason [code]sv_enablebunnyhopping[/code] exists.
##
## [b]It is off here and on in those shooters[/b] because this addon's defaults are
## a movement shooter's, and a movement shooter that caps hop speed has no
## bunny-hopping. Set it to 1.104 to reproduce the retail behaviour of the round-based
## competitive shooters this genre came from.
@export_range(0.0, 10.0, 0.001) var bhop_speed_cap_scale: float = 0.0

## Extra friction while standing near a ledge, as a multiplier. 1 disables it.
##
## The familiar [code]sv_edgefriction[/code], which ships at 2. Standing with your toes
## over a drop makes you stop faster, so a player who walks to the edge of a block
## does not slide off it. Costs one extra query per grounded tick, which is why it
## is off by default and why a KZ or bhop server — where the effect is part of the
## movement people have trained on — turns it on.
@export_range(1.0, 10.0, 0.05) var edge_friction: float = 1.0

## How far past the player's own radius to look for the ledge, in metres.
@export_range(0.0, 2.0, 0.01) var edge_friction_reach: float = 0.4

## How far down has to be empty for it to count as a ledge, in metres.
@export_range(0.05, 5.0, 0.01) var edge_friction_drop: float = 0.6

## Resolve a two-plane wedge by moving along the crease instead of stopping.
##
## [b]This is the difference between a surf ramp being playable and not.[/b] A surf
## map is built from long ramps that meet each other, and a player sliding down one
## reaches the seam at 20 m/s. Clipping velocity against the first plane and then the
## second — which is what a naive collide-and-slide does — leaves a vector pointing
## back into the first, so the next iteration clips it again and the player stops
## dead in the corner. The classic slide pass keeps every plane it has
## touched this move, notices when a clipped direction re-enters an earlier one, and
## slides along the intersection of the two instead. That is what carries a surfer
## through a seam with their speed intact.
##
## Off, the motor is the plain sequential slide it was before. Nothing else changes.
@export var crease_slide: bool = true

## Planes remembered per move for [member crease_slide].
##
## The classic implementations use five. More is not better: a player genuinely
## inside a five-plane wedge has nowhere to go, and continuing to search finds a
## direction that leaves them inside the geometry rather than outside it.
@export_range(2, 8, 1) var max_slide_planes: int = 5

## Speed, as a multiple of [member max_speed], above which the crest of a walkable ramp
## launches the player instead of holding them to the floor past it. 0 never launches.
##
## A bhop or surf player taking a ramp at speed expects to leave its top, and one running up
## it expects to walk onto the plateau: the threshold is what tells the two apart. Since the
## walkable-slope fix every crest held everybody to the floor, which is the second half and
## not the first. At 1.25 a player at their running speed stays grounded and one carrying
## hop speed over the crest is thrown, with their speed. A server that wants the old
## behaviour back sets 0.
@export_range(0.0, 10.0, 0.01) var crest_launch_speed_scale: float = 1.25

@export_group("Crouching")

## Standing collision height, in metres. The capsule's total height.
@export_range(0.2, 5.0, 0.01) var stand_height: float = 1.8

## Crouched collision height, in metres.
@export_range(0.2, 5.0, 0.01) var crouch_height: float = 0.9

## Collider radius, in metres.
@export_range(0.05, 2.0, 0.01) var radius: float = 0.35

## Seconds to move fully between standing and crouching.
##
## Part of the simulation, not a visual: the collider changes size over it, so a
## client and server that used different values would disagree about what fits.
@export_range(0.0, 2.0, 0.005) var crouch_transition_time: float = 0.12

## Crouch instantly while airborne.
##
## The classic "crouch-jump": snapping the collider up mid-air clears ledges a
## standing jump cannot. Free to allow and players expect it.
@export var instant_air_crouch: bool = true

@export_group("Collision")

## Steepest floor the player can stand on, in degrees. Anything steeper is a wall.
@export_range(0.0, 89.0, 0.5) var max_slope_angle: float = 46.0

## Tallest step the player walks up without jumping, in metres.
##
## The familiar [code]sv_stepsize[/code]. Without it every kerb and stair tread stops the
## player dead, which is the single most common thing wrong with a hand-written
## character controller — the previous version of this one included.
@export_range(0.0, 2.0, 0.01) var step_height: float = 0.3429

## Keep the player attached to the ground when walking down slopes and steps.
##
## Off, a player walking down a ramp leaves the ground every tick and gets air
## physics — no friction, no ground acceleration — which feels like ice.
@export var ground_snap: bool = true

## How far below the feet to look for ground when snapping, in metres.
@export_range(0.0, 2.0, 0.01) var ground_snap_distance: float = 0.35

## Collide-and-slide iterations per move. More handles tighter corners.
@export_range(1, 16, 1) var max_slide_iterations: int = 5

## Gap kept between the collider and surfaces, in metres.
##
## Resting exactly on a surface leaves the next query's result at the mercy of
## floating-point rounding, which reads as the player intermittently falling through
## a floor they are standing on.
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

## Whether the sprint button toggles instead of being held (read by [DotFpsSampler]; stopping clears it).
@export var sprint_toggle: bool = false
@export var can_walk: bool = true
@export var can_jump: bool = true

## Whether the noclip button does anything.
##
## Off by default and separately gated on the server, because a client can set this
## bit in a command whenever it likes. See [DotFpsController.allow_noclip].
@export var can_noclip: bool = false

## Noclip flight speed, in m/s.
@export_range(0.1, 200.0, 0.1) var noclip_speed: float = 16.0

## How quickly noclip velocity settles toward the wish velocity, per second.
@export_range(0.1, 100.0, 0.1) var noclip_accelerate: float = 12.0

@export_group("Sliding")

## Whether pressing crouch while running starts a slide.
##
## [b]Off by default, and that is the whole compatibility story.[/b] Every number below
## is read only while this is on, so a game that never sets it simulates exactly what it
## did before sliding existed. It is still in [method fingerprint] like everything else,
## because two peers that disagree about it disagree about where a crouching runner goes.
@export var slide_enabled: bool = false

## Horizontal speed, in m/s, a grounded player needs for a crouch press to start a slide
## rather than an ordinary crouch.
@export_range(0.0, 100.0, 0.1) var slide_min_speed: float = 6.0

## Speed added along the run when a slide starts, in m/s. 0 for a slide with no burst.
@export_range(0.0, 50.0, 0.1) var slide_boost: float = 3.0

## The boost never takes horizontal speed past this, in m/s.
##
## [b]A cap on the boost, not on the slide.[/b] A player already faster than this (off a
## ramp, out of a bunny-hop) keeps that speed and gets no burst; a cap that clamped them
## down to it would make sliding a way to lose speed, which nobody presses a key for.
@export_range(0.0, 100.0, 0.1) var slide_max_speed: float = 13.0

## Ground friction while sliding, in place of [member friction]. Low, so a slide carries.
@export_range(0.0, 20.0, 0.05) var slide_friction: float = 0.8

## Acceleration toward the wish direction while sliding, in place of [member accelerate].
##
## It steers rather than speeds up: the wish speed while sliding is the crouched one,
## which a sliding player is already well past, so [method DotFpsMotor.accelerate] adds
## nothing along the run and only bends it. 0 locks the direction.
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

## Whether [member launch_button] throws the player into the air.
##
## Off by default for the same reason as [member slide_enabled]. An ability rather than a
## [DotFpsModifier] because it is an impulse, and a modifier is a multiplier.
@export var launch_enabled: bool = false

## The command button that launches, as a [DotFpsCommand] button bit
## ([code]BUTTON_USER_0[/code] is 32). 0 means no button does.
##
## [b]A setting rather than a new bit[/b], because every bit on the wire is already
## spoken for: the user bits are each game's own, and a game picks the one it has free.
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
##
## Off by default, like the slide and for the same reason: every [code]wall_run_*[/code]
## number is read only behind this, and the wall probe is not even made, so a game that
## never sets it simulates exactly what it did before wall running existed. The reasoning
## is in docs/wall-movement.md.
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

## How fast the vertical speed a player arrives with is eased away while running, per
## second (exponential, like the view's smoothing).
##
## [b]Eased rather than zeroed[/b]: zeroing it on the first tick is a one-tick velocity
## spike, the jolt this whole feature is meant not to have. Against
## [member wall_run_gravity_scale] it also sets the slow sink a long run settles into
## ([code]gravity * scale / damping[/code], about 0.6 m/s with the defaults).
@export_range(0.0, 60.0, 0.1) var wall_run_vertical_damping: float = 8.0

## A player falling faster than this, in m/s, does not catch a wall. Brushing a wall must
## not be a way to stop a long fall.
@export_range(0.0, 100.0, 0.1) var wall_run_max_fall_speed: float = 6.0

## The steepest angle a wall may lean from vertical, in degrees, and still be run on or
## jumped off. Applies to the wall jump too.
@export_range(0.0, 45.0, 0.5) var wall_max_angle_from_vertical: float = 15.0

## The largest angle, in degrees, between the player's horizontal velocity and the wall's
## plane at which a run starts.
##
## Said from the other side, the velocity must be at least [code]90 - this[/code] degrees
## away from pointing straight into the wall: running at a wall head-on is not a wall run.
## 0 needs a velocity exactly along the wall; 90 accepts any.
@export_range(0.0, 90.0, 0.5) var wall_run_max_approach_angle: float = 60.0

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

## Fastest fall, in m/s, of an airborne player against a wall who is pushing into it or
## whose run has ended on it: the wall slide that lets a player ride a wall down under
## control, and what a timed-out run decays into rather than a sudden fall. 0 turns the
## slide off, and is the default.
##
## A faster fall is eased down to it at [member wall_run_vertical_damping], never cut in
## one tick. Independent of [member wall_run_enabled].
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
##
## 0 pushes straight out from the wall; a little (0.3) sends the jump where the player
## expects it to go. The part of the look that points into the wall is ignored, so the
## push always leaves the wall.
@export_range(0.0, 1.0, 0.01) var wall_jump_look_blend: float = 0.3

## Wall jumps off the same wall before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width.
##
## [b]The same wall is the same normal[/b] (to within one eighth of a turn), so two
## facing walls of a corridor are two walls and a player can climb between them, while
## one wall cannot be climbed alone by jumping off it again and again.
@export_range(0, 3, 1) var wall_jump_max_per_wall: int = 1

## Wall jumps in all, off any walls, before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width. Applies on top of
## [member wall_jump_max_per_wall]: the budget the fast movement shooters give a single
## airborne stretch, refilled only by landing.
@export_range(0, 3, 1) var wall_jump_max_per_air: int = 3


# --- Profiles and cvars -----------------------------------------------------

## One source unit in metres (16 units to the foot, 0.75 scale): what a map made in them
## and every value in [method cvar_specs] is converted by.
const SOURCE_UNIT := 0.01905

const PROFILE_CLASSIC := "classic"
const PROFILE_LEGACY := "legacy"

const CVAR_PROFILE := "sv_movement_profile"

## The members the profiles differ in. Everything else is the same in both.
const _PROFILES := {
	"classic": {
		"max_speed": 4.7625, "crouch_speed_scale": 0.34, "walk_speed_scale": 0.52,
		"sprint_speed_scale": 1.0, "max_velocity": 66.675, "max_wish_speed": 6.096,
		"accelerate": 5.0, "friction": 4.0, "stop_speed": 1.42875,
		"air_accelerate": 10.0, "max_air_wish_speed": 0.5715, "gravity": 15.24,
		"jump_height": 1.08585, "coyote_time": 0.0, "jump_buffer_time": 0.0,
		"step_height": 0.3429, "bhop_speed_cap_scale": 0.0, "auto_hop": false,
	},
	"legacy": {
		"max_speed": 7.0, "crouch_speed_scale": 0.4, "walk_speed_scale": 0.45,
		"sprint_speed_scale": 1.5, "max_velocity": 400.0, "max_wish_speed": 0.0,
		"accelerate": 10.0, "friction": 6.0, "stop_speed": 4.0,
		"air_accelerate": 100.0, "max_air_wish_speed": 1.0, "gravity": 20.0,
		"jump_height": 1.1, "coyote_time": 0.1, "jump_buffer_time": 0.1,
		"step_height": 0.4, "bhop_speed_cap_scale": 0.0, "auto_hop": false,
	},
}

## cvar name -> [member, factor to metres (1 for a ratio), description]. Source units in.
const _CVARS := {
	"sv_accelerate": ["accelerate", 1.0, "Ground acceleration"],
	"sv_airaccelerate": ["air_accelerate", 1.0, "Air acceleration"],
	"sv_friction": ["friction", 1.0, "Ground friction"],
	"sv_stopspeed": ["stop_speed", SOURCE_UNIT, "Speed friction treats as the minimum, units/s"],
	"sv_gravity": ["gravity", SOURCE_UNIT, "Gravity, units/s^2"],
	"sv_maxspeed": ["max_wish_speed", SOURCE_UNIT, "Ceiling on a key's wish speed, units/s; 0 off"],
	"sv_maxvelocity": ["max_velocity", SOURCE_UNIT, "Ceiling on total speed, units/s"],
	"sv_stepsize": ["step_height", SOURCE_UNIT, "Tallest walkable step, units"],
	"sv_airwishspeed": ["max_air_wish_speed", SOURCE_UNIT, "Air wish-speed cap that makes strafe-jumping, units/s"],
	"sv_runspeed": ["max_speed", SOURCE_UNIT, "Running speed, units/s"],
	"sv_crouchspeed": ["crouch_speed_scale", 1.0, "Crouch speed, fraction of run"],
	"sv_walkspeed": ["walk_speed_scale", 1.0, "Walk speed, fraction of run"],
	"sv_sprint": ["can_sprint", 1.0, "1 lets the sprint button work"],
	"sv_sprintspeed": ["sprint_speed_scale", 1.0, "Sprint speed, fraction of run"],
	"sv_stamina": ["stamina_enabled", 1.0, "1 makes sprinting drain stamina and stop when it is empty"],
	"sv_stamina_drain": ["stamina_drain", 1.0, "Stamina fraction lost per second of sprinting"],
	"sv_stamina_recover": ["stamina_recover", 1.0, "Stamina fraction regained per second"],
	"sv_stamina_resume": ["stamina_resume_at", 1.0, "Stamina fraction an exhausted player needs before sprinting again"],
	"sv_stamina_delay": ["stamina_exhaust_delay", 1.0, "Seconds after running out before stamina refills"],
	"sv_sprint_loadspeed": ["sprint_load_speed", 1.0, "How strongly carry load cuts the sprint bonus; 0 off"],
	"sv_sprint_loaddrain": ["sprint_load_drain", 1.0, "How strongly carry load raises the stamina drain; 0 off"],
	"sv_sprint_noaim": ["sprint_blocks_aim", 1.0, "1 stops aiming and reloading while sprinting"],
	"sv_sprint_toggle": ["sprint_toggle", 1.0, "1 makes the sprint key a toggle (stopping ends it)"],
	"sv_jumpheight": ["jump_height", SOURCE_UNIT, "Apex of a standing jump, units"],
	"sv_ducktime": ["crouch_transition_time", 1.0, "Seconds to move between standing and crouching; 0 instant"],
	"sv_airduck": ["instant_air_crouch", 1.0, "1 lets a crouch in the air pull the feet up at once (crouch-jump)"],
	"sv_autohop": ["auto_hop", 1.0, "1 jumps again on landing while jump is held"],
	"sv_bhopcap": ["bhop_speed_cap_scale", 1.0, "Landing speed cap as a multiple of run speed; 0 none"],
	"sv_edgefriction": ["edge_friction", 1.0, "Friction multiplier near a ledge; 1 off"],
	"sv_wallrun": ["wall_run_enabled", 1.0, "1 lets a fast airborne player run along a wall"],
	"sv_wallrun_auto": ["wall_run_auto", 1.0, "1 starts a wall run on touching a wall in the air, no press; a press wall-jumps"],
	"sv_wallrun_onjump": ["wall_run_on_jump", 1.0, "1 starts a wall run on a jump press beside a wall, turning the heading along it"],
	"sv_wallrun_minspeed": ["wall_run_min_speed", 1.0, "Speed along the wall a run needs, m/s"],
	"sv_wallrun_jumpminspeed": ["wall_run_jump_min_speed", 1.0, "Horizontal speed a jump-started run needs, m/s"],
	"sv_wallrun_jumpangle": ["wall_run_jump_max_angle", 1.0, "Widest angle off the wall's plane a jump-started run accepts, degrees"],
	"sv_wallrun_angle": ["wall_run_max_approach_angle", 1.0, "Widest angle off the wall's plane an automatic run starts at, degrees"],
	"sv_wallrun_time": ["wall_run_max_time", 1.0, "Longest a wall run lasts, seconds (at most 1.9)"],
	"sv_wallrun_gravity": ["wall_run_gravity_scale", 1.0, "Share of gravity felt while wall running, 0 to 1"],
	"sv_wallrun_turnview": ["wall_run_turn_view", 1.0, "A jump-started wall-run turns the view along the wall (0/1)"],
	"sv_wallrun_cooldown": ["wall_run_cooldown", 1.0, "Seconds after a run ends before another may start"],
	"sv_wallrun_endspeed": ["wall_run_end_speed", 1.0, "A run ends below this speed along the wall, m/s"],
	"sv_wallrun_angle_limit": ["wall_max_angle_from_vertical", 1.0, "Steepest lean from vertical a wall may have, degrees"],
	"sv_walljump": ["wall_jump_enabled", 1.0, "1 lets a jump press beside a wall jump off it"],
	"sv_walljump_push": ["wall_jump_push_speed", 1.0, "Speed a wall jump pushes off the wall, m/s"],
	"sv_walljump_up": ["wall_jump_up_speed", 1.0, "Upward speed a wall jump sets, m/s"],
	"sv_wallslide": ["wall_slide_speed", 1.0, "Fastest fall against a wall, m/s; 0 off"],
}


## A tunables set to [param profile_name] ([constant PROFILE_CLASSIC] or [constant PROFILE_LEGACY]).
static func with_profile(profile_name: String) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	var _res := t.apply_profile(profile_name)
	return t


## Sets every member the profiles differ in to [param profile_name]'s values and remembers it.
## Fails on an unknown name and changes nothing. Members outside the table are left alone.
func apply_profile(profile_name: String) -> DotResult:
	if not _PROFILES.has(profile_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown movement profile.",
			"%s (have %s)" % [profile_name, ", ".join(profile_names())]
		)
	var values: Dictionary = _PROFILES[profile_name]
	for key in values:
		set(key, values[key])
	movement_profile = profile_name
	return DotResult.success(self)


static func profile_names() -> PackedStringArray:
	return PackedStringArray(_PROFILES.keys())


## One entry per movement cvar: name, value (in the cvar's own source units), description, and
## the member it sets. The profile cvar is first.
func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{
		"name": CVAR_PROFILE, "value": movement_profile, "member": "movement_profile",
		"description": "Named movement set applied first: %s" % ", ".join(profile_names()),
	}]
	for cvar_name in _CVARS:
		var entry: Array = _CVARS[cvar_name]
		var current: Variant = get(entry[0])
		var shown := (1.0 if current else 0.0) if current is bool else float(current) / float(entry[1])
		out.append({
			"name": cvar_name, "value": snappedf(shown, 0.0001), "member": entry[0],
			"description": String(entry[2]),
		})
	return out


## Applies one cvar by name (source units in). A profile name replaces the profile's members.
## False for an unknown cvar or a value that is not a number or profile.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()
	if cvar_name == CVAR_PROFILE:
		return apply_profile(text).ok
	if not _CVARS.has(cvar_name) or not text.is_valid_float():
		return false
	var entry: Array = _CVARS[cvar_name]
	if get(entry[0]) is bool:
		set(entry[0], text.to_float() != 0.0)
	else:
		set(entry[0], text.to_float() * float(entry[1]))
	return true


## Boots the layers with the profile first: the profile named by the file, environment or
## command line is applied, then those layers on top of it, so a single number still wins.
func load_layered(file_path: String = "") -> DotResult:
	var probe := DotFpsTunables.new()
	if file_path != "":
		var _file := probe.apply_json_file(file_path)
	var _env := probe.apply_env()
	var _cli := probe.apply_cli()
	if probe.movement_profile != PROFILE_CLASSIC:
		var res := apply_profile(probe.movement_profile)
		if not res.ok:
			return res
	return super.load_layered(file_path)


func env_prefix() -> String:
	return "DOT_FPS_"


func cli_prefix() -> String:
	return "--fps-"


func validate() -> DotResult:
	if crouch_height > stand_height:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"crouch_height must not exceed stand_height.",
			"crouch %.2f, stand %.2f" % [crouch_height, stand_height]
		)

	# A capsule whose total height is under twice its radius has no cylindrical
	# section, and Godot silently grows it — so the collider the simulation thinks it
	# has is not the one the physics server uses, and the player sinks into floors
	# only while crouched.
	if crouch_height < radius * 2.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"crouch_height must be at least twice the radius.",
			"crouch %.2f, radius %.2f" % [crouch_height, radius]
		)

	if pitch_min >= pitch_max:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"pitch_min must be below pitch_max.",
			"%.1f .. %.1f" % [pitch_min, pitch_max]
		)

	# Stepping higher than the collider is tall lets the player climb walls one
	# move at a time, which looks like the collision being broken rather than a
	# misconfiguration.
	if step_height >= crouch_height:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"step_height must be below crouch_height.",
			"step %.2f, crouch %.2f" % [step_height, crouch_height]
		)

	if wall_run_max_time > WALL_RUN_TIME_LIMIT:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"wall_run_max_time must not exceed %.1f s, what the wire can carry." % WALL_RUN_TIME_LIMIT,
			"%.2f s" % wall_run_max_time
		)

	if max_speed > max_velocity:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"max_velocity must not be below max_speed.",
			"%.1f vs %.1f" % [max_velocity, max_speed]
		)

	return DotResult.success(null)


# --- Derived values --------------------------------------------------------

## Upward launch speed for a jump, in m/s.
func jump_velocity() -> float:
	return sqrt(2.0 * gravity * jump_height)


func max_slope_radians() -> float:
	return deg_to_rad(max_slope_angle)


## Height of the collider at a given crouch fraction, 0 standing to 1 crouched.
func height_at(crouch_fraction: float) -> float:
	return lerpf(stand_height, crouch_height, clampf(crouch_fraction, 0.0, 1.0))


## Ground speed for the modifiers held in [param buttons].
##
## Most restrictive wins. See [member crouch_speed_scale] for why this is derived
## rather than stored.
func speed_for(buttons: int, load_fraction: float = 0.0) -> float:
	var scale := 1.0

	if can_crouch and (buttons & DotFpsCommand.BUTTON_CROUCH):
		scale = crouch_speed_scale
	elif can_walk and (buttons & DotFpsCommand.BUTTON_WALK):
		scale = walk_speed_scale
	elif can_sprint and (buttons & DotFpsCommand.BUTTON_SPRINT):
		scale = 1.0 + (sprint_speed_scale - 1.0) * (1.0 - clampf(load_fraction * sprint_load_speed, 0.0, 1.0))

	var wish := max_speed * scale
	return minf(wish, max_wish_speed) if max_wish_speed > 0.0 else wish


# --- Reach -----------------------------------------------------------------
#
# How far these numbers carry a player, for anyone sizing a gap or a ledge against them.
#
# [b]Why here rather than in each map.[/b] Four games in this family each carried a copy
# of the same arithmetic over their own copy of three of these numbers, with a check that
# the copies agreed, and two of those games had shipped courses nobody could finish
# because the copy was the wrong formula. The numbers are this class's; so is the
# question.

## How much of the apex a climb is asked to use.
##
## A player landing at exactly [member jump_height] arrives with no vertical speed at the
## one instant of the arc where a tick either side of it is short: a ledge that works when
## the tick lands right and not when it does not. Nine tenths works every time.
const CLIMB_MARGIN := 0.9

## The longest [member wall_run_max_time] can be, in seconds: what the run's replicated
## field holds (125 sixty-fourths; see [DotFpsNetSync]). A longer run would arrive in a
## snapshot as a shorter one, and the client would drop off the wall early.
const WALL_RUN_TIME_LIMIT := 1.9


## Seconds from take-off to landing [param rise] metres higher (negative for lower), for a
## jump of [param p_jump_height] under [param p_gravity]. -1.0 when no jump reaches that
## high, or gravity is not positive.
##
## [b]The landing height is the point.[/b] The airtime everybody writes down is the time
## to fall back to the height you left, and it is the wrong one for anything that climbs:
## with a 1.15 m jump under 20 m/s² a player is airborne 0.68 s flat and 0.53 s onto a
## step 0.8 m up. A course sized with the first number is 30% longer than the movement.
## Static, so a map holding its own constants can ask without building a tunables.
static func airtime_for(p_gravity: float, p_jump_height: float, rise: float) -> float:
	if p_gravity <= 0.0:
		return -1.0

	var launch := sqrt(2.0 * p_gravity * maxf(p_jump_height, 0.0))
	var remaining := launch * launch - 2.0 * p_gravity * rise

	if remaining < 0.0:
		return -1.0

	# The DESCENDING root. The ascending one is the same height on the way up, which is a
	# shorter jump that lands on the near lip rather than the far one.
	return (launch + sqrt(remaining)) / p_gravity


## The clear air crossed at [param speed] by a jump landing [param rise] metres higher, in
## metres; see [method airtime_for]. 0.0 when no jump reaches that high.
static func reach_for(
	speed: float, p_gravity: float, p_jump_height: float, rise: float
) -> float:
	var time := airtime_for(p_gravity, p_jump_height, rise)
	return speed * time if time > 0.0 else 0.0


## The apex of a standing jump on flat ground, in metres. [member jump_height] by
## definition — the launch is derived from it — and named so a caller does not mistake
## it for the height of something a player can get onto, which is [method climb_limit].
func jump_apex() -> float:
	return jump_height


## Seconds airborne in a jump landing [param rise] metres higher, or -1.0 if unreachable.
func jump_airtime(rise: float = 0.0) -> float:
	return airtime_for(gravity, jump_height, rise)


## The clear air a player crosses in one jump landing [param rise] metres higher, at
## [param speed] ([member max_speed] when negative), in metres. 0.0 if unreachable.
##
## Ground speed held through the air, which is what holding forward does: air
## acceleration is capped at [member max_air_wish_speed] along the wish direction, so it
## adds nothing to a player already moving faster than that. Strafing adds more and a
## landing cap ([member bhop_speed_cap_scale]) takes some away; both are a game's
## question about skill, not this one. Measured from the player's centre, lip to lip,
## with no credit for the capsule's radius — that is the margin.
func jump_reach(rise: float = 0.0, speed: float = -1.0) -> float:
	return reach_for(max_speed if speed < 0.0 else speed, gravity, jump_height, rise)


## The highest top face a player standing on flat ground is asked to jump onto, in metres:
## [member jump_height] × [param margin]. Above this a block is a wall; at or below
## [member step_height] it is walked.
func climb_limit(margin: float = CLIMB_MARGIN) -> float:
	return jump_height * margin


## A short hash of every value that affects the simulation.
##
## [b]The point of this is to fail loudly.[/b] A client whose tunables differ from
## the server's diverges every tick, and the symptom — constant small corrections —
## looks exactly like ordinary packet loss. Comparing fingerprints at connect time
## turns three days of "the netcode feels bad" into one line in a log.
##
## Look-only values are excluded: mouse sensitivity is a per-player preference and
## does not enter the simulation.
func fingerprint() -> String:
	var parts := PackedStringArray()

	for key in config_keys():
		if key.begins_with("mouse_") or key == "invert_look_y":
			continue
		parts.append("%s=%s" % [key, str(get(key))])

	return DotHash.sha256_text("|".join(parts)).substr(0, 16)


func describe_summary() -> String:
	return "speed %.1f accel %.1f air %.1f/%.1f grav %.1f jump %.2fm [%s]" % [
		max_speed, accelerate, air_accelerate, max_air_wish_speed,
		gravity, jump_height, fingerprint()
	]
