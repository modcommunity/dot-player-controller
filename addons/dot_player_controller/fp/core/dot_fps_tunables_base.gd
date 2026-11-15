@tool
extends DotConfig

## The exported numbers of [DotFpsTunables], kept apart so the class that reads them stays small.
## Never instantiate this directly; use [DotFpsTunables].

## Bumped by every exported property's setter, so a reader can cache what it derives from them ([DotFpsMotor]'s native
## tick settings) and rebuild only when one changes. Not exported, not saved.
var revision: int = 0

@export_group("Collision")

## Steepest floor the player can stand on, in degrees. Anything steeper is a wall.
@export_range(0.0, 89.0, 0.5) var max_slope_angle: float = 46.0:
	set(value):
		max_slope_angle = value
		revision += 1

## Tallest step the player walks up without jumping, in metres.
## The familiar [code]sv_stepsize[/code]. Without it every kerb stops the player dead,
## the commonest flaw of a hand-written character controller.
@export_range(0.0, 2.0, 0.01) var step_height: float = 0.3429:
	set(value):
		step_height = value
		revision += 1

## Keep the player attached to the ground when walking down slopes and steps.
## Off, a ramp descent is a string of airborne ticks: no friction, no ground acceleration.
@export var ground_snap: bool = true:
	set(value):
		ground_snap = value
		revision += 1

## How far below the feet to look for ground when snapping, in metres.
@export_range(0.0, 2.0, 0.01) var ground_snap_distance: float = 0.35:
	set(value):
		ground_snap_distance = value
		revision += 1

## Collide-and-slide iterations per move. More handles tighter corners.
@export_range(1, 16, 1) var max_slide_iterations: int = 5:
	set(value):
		max_slide_iterations = value
		revision += 1

## Gap kept between the collider and surfaces, in metres.
## Resting exactly on a surface leaves the next query at the mercy of rounding, which
## reads as intermittently falling through the floor.
@export_range(0.0, 0.1, 0.0001) var skin_width: float = 0.001:
	set(value):
		skin_width = value
		revision += 1

## Physics collision layers the player collides with.
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		revision += 1

@export_group("Abilities")

## Whether the crouch button does anything.
@export var can_crouch: bool = true:
	set(value):
		can_crouch = value
		revision += 1
@export var can_sprint: bool = true:
	set(value):
		can_sprint = value
		revision += 1

@export_group("Sprint stamina")

## Whether sprinting drains [member DotFpsState.stamina] and stops when it is empty. Off keeps sprint free.
@export var stamina_enabled: bool = false:
	set(value):
		stamina_enabled = value
		revision += 1

## Stamina (a 0 to 1 fraction) lost per second of sprinting while moving.
@export_range(0.0, 10.0, 0.01) var stamina_drain: float = 0.2:
	set(value):
		stamina_drain = value
		revision += 1

## Stamina regained per second when not sprinting.
@export_range(0.0, 10.0, 0.01) var stamina_recover: float = 0.15:
	set(value):
		stamina_recover = value
		revision += 1

## After running out, sprint refuses until stamina is back to this fraction.
@export_range(0.0, 1.0, 0.01) var stamina_resume_at: float = 0.3:
	set(value):
		stamina_resume_at = value
		revision += 1

## Seconds after running out before stamina starts to refill.
@export_range(0.0, 3.5, 0.05) var stamina_exhaust_delay: float = 1.0:
	set(value):
		stamina_exhaust_delay = value
		revision += 1

## How strongly the carried load (0 empty to 1 at capacity, set on the motor) cuts the sprint bonus; 0 off.
@export_range(0.0, 2.0, 0.01) var sprint_load_speed: float = 0.0:
	set(value):
		sprint_load_speed = value
		revision += 1

## How strongly the carried load raises the stamina drain; 0 off.
@export_range(0.0, 4.0, 0.01) var sprint_load_drain: float = 0.0:
	set(value):
		sprint_load_drain = value
		revision += 1

## Whether a sprinting player may aim down sights or reload (read by weapon code through [member DotFpsState.sprinting]).
@export var sprint_blocks_aim: bool = false:
	set(value):
		sprint_blocks_aim = value
		revision += 1

## Whether a sprinting player may fire (read by weapon code through `motion()`); false blocks the trigger while sprinting.
@export var sprint_can_shoot: bool = true:
	set(value):
		sprint_can_shoot = value
		revision += 1

## Whether a shot fired while sprinting leaves along the lowered barrel instead of the crosshair.
@export var sprint_shot_follows_barrel: bool = true:
	set(value):
		sprint_shot_follows_barrel = value
		revision += 1

## The move-command button that says the player is aiming down sights, as a [DotFpsCommand]
## button bit; 0 means none. A move bit rather than the weapon's, so prediction and the server
## read the same input in [method DotFpsTunables.speed_for].
@export_range(0, 255, 1) var aim_button: int = 0:
	set(value):
		aim_button = value
		revision += 1

## Ground speed while [member aim_button] is held, as a fraction of the speed it would be; 1 off.
@export_range(0.0, 1.0, 0.01) var aim_speed_scale: float = 1.0:
	set(value):
		aim_speed_scale = value
		revision += 1

## Whether taking damage drops the player out of the sights ([DotFpsAimBreak]). Off: the sights stay and the hit shakes the view and wobbles the aim instead (the `hit_*` members).
@export var unscope_on_hit: bool = false:
	set(value):
		unscope_on_hit = value
		revision += 1

## Seconds the sights stay refused after a hit.
@export_range(0.0, 3.0, 0.05) var unscope_hit_time: float = 0.4:
	set(value):
		unscope_hit_time = value
		revision += 1

## Degrees of camera roll a hit shakes the view by (and a few millimetres of offset); 0 off. Read when `unscope_on_hit` is off.
@export_range(0.0, 10.0, 0.05) var hit_shake: float = 1.2:
	set(value):
		hit_shake = value
		revision += 1

## Degrees the aim wobbles by after a hit (it moves where the shots go); 0 off.
@export_range(0.0, 10.0, 0.05) var hit_wobble: float = 0.6:
	set(value):
		hit_wobble = value
		revision += 1

## Wobble and shake cycles per second.
@export_range(0.5, 30.0, 0.5) var hit_wobble_hz: float = 9.0:
	set(value):
		hit_wobble_hz = value
		revision += 1

## Seconds a hit's shake and wobble last, fading to nothing; 0 turns the flinch off.
@export_range(0.0, 3.0, 0.05) var hit_flinch_time: float = 0.5:
	set(value):
		hit_flinch_time = value
		revision += 1

## How much the damage taken scales the shake and wobble: 0 the same for every hit, 1 in proportion (25 damage is the 1x hit).
@export_range(0.0, 1.0, 0.05) var hit_damage_scale: float = 0.5:
	set(value):
		hit_damage_scale = value
		revision += 1

## Whether the sprint button toggles instead of being held (read by [DotFpsSampler]; stopping clears it).
@export var sprint_toggle: bool = false:
	set(value):
		sprint_toggle = value
		revision += 1
@export var can_walk: bool = true:
	set(value):
		can_walk = value
		revision += 1
@export var can_jump: bool = true:
	set(value):
		can_jump = value
		revision += 1

## Whether the noclip button does anything.
## Off by default and gated separately on the server, because a client can set this bit
## in a command at will. See [DotFpsController.allow_noclip].
@export var can_noclip: bool = false:
	set(value):
		can_noclip = value
		revision += 1

## Noclip flight speed, in m/s.
@export_range(0.1, 200.0, 0.1) var noclip_speed: float = 16.0:
	set(value):
		noclip_speed = value
		revision += 1

## How quickly noclip velocity settles toward the wish velocity, per second.
@export_range(0.1, 100.0, 0.1) var noclip_accelerate: float = 12.0:
	set(value):
		noclip_accelerate = value
		revision += 1

@export_group("Sliding")

## Whether pressing crouch while running starts a slide.
## Off by default: every number below is read only while this is on, so a game that never
## sets it simulates what it did before sliding. In [method fingerprint], as peers must agree.
@export var slide_enabled: bool = false:
	set(value):
		slide_enabled = value
		revision += 1

## Horizontal speed, in m/s, a grounded player needs for a crouch press to start a slide
## rather than an ordinary crouch.
@export_range(0.0, 100.0, 0.1) var slide_min_speed: float = 6.0:
	set(value):
		slide_min_speed = value
		revision += 1

## Speed added along the run when a slide starts, in m/s. 0 for a slide with no burst.
@export_range(0.0, 50.0, 0.1) var slide_boost: float = 3.0:
	set(value):
		slide_boost = value
		revision += 1

## The boost never takes horizontal speed past this, in m/s.
## A cap on the boost, not on the slide: a faster player keeps their speed and gets no burst,
## since clamping them down would make sliding a way to lose speed.
@export_range(0.0, 100.0, 0.1) var slide_max_speed: float = 13.0:
	set(value):
		slide_max_speed = value
		revision += 1

## Ground friction while sliding, in place of [member friction]. Low, so a slide carries.
@export_range(0.0, 20.0, 0.05) var slide_friction: float = 0.8:
	set(value):
		slide_friction = value
		revision += 1

## Acceleration toward the wish direction while sliding, in place of [member accelerate].
## It steers rather than speeds up (the crouched wish speed is below a slider's speed), so it
## only bends the run. 0 locks the direction.
@export_range(0.0, 100.0, 0.1) var slide_accelerate: float = 2.0:
	set(value):
		slide_accelerate = value
		revision += 1

## The longest a slide lasts, in seconds, before it settles into an ordinary crouch.
@export_range(0.05, 10.0, 0.05) var slide_duration: float = 1.0:
	set(value):
		slide_duration = value
		revision += 1

## A slide that slows below this horizontal speed, in m/s, ends early.
@export_range(0.0, 50.0, 0.1) var slide_end_speed: float = 3.0:
	set(value):
		slide_end_speed = value
		revision += 1

## Seconds after a slide ends before another can start.
@export_range(0.0, 10.0, 0.05) var slide_cooldown: float = 0.5:
	set(value):
		slide_cooldown = value
		revision += 1

## Whether a slide also needs the sprint button held.
@export var slide_requires_sprint: bool = false:
	set(value):
		slide_requires_sprint = value
		revision += 1

@export_group("Launch")

## Whether [member launch_button] throws the player into the air. Off by default, like
## [member slide_enabled]. An ability, not a [DotFpsModifier]: it is an impulse and a modifier
## is a multiplier.
@export var launch_enabled: bool = false:
	set(value):
		launch_enabled = value
		revision += 1

## The command button that launches, as a [DotFpsCommand] button bit
## ([code]BUTTON_USER_0[/code] is 32). 0 means no button does.
## A setting rather than a new bit, because every wire bit is already spoken for.
@export_range(0, 255, 1) var launch_button: int = 0:
	set(value):
		launch_button = value
		revision += 1

## Upward speed a launch sets, in m/s. It replaces a lower vertical speed rather than
## adding to it, so a launch at the top of a jump goes as high as one from the ground.
@export_range(0.0, 100.0, 0.1) var launch_velocity: float = 13.0:
	set(value):
		launch_velocity = value
		revision += 1

## Speed added along the view's heading, in m/s, flat. 0 for straight up.
@export_range(0.0, 100.0, 0.1) var launch_forward: float = 0.0:
	set(value):
		launch_forward = value
		revision += 1

## Seconds between launches.
@export_range(0.0, 600.0, 0.1) var launch_cooldown: float = 8.0:
	set(value):
		launch_cooldown = value
		revision += 1

## Whether a launch works in mid-air. Off, it needs the ground (or coyote time).
@export var launch_from_air: bool = true:
	set(value):
		launch_from_air = value
		revision += 1

@export_group("Dash")

## Whether [member dash_button] throws the player along the way they are moving.
## Off by default, like the launch and for the same reason.
@export var dash_enabled: bool = false:
	set(value):
		dash_enabled = value
		revision += 1

## The command button that dashes, as a [DotFpsCommand] button bit. 0 means none. A game
## with no sprint can give it the sprint bit, which is already on the wire.
@export_range(0, 255, 1) var dash_button: int = 0:
	set(value):
		dash_button = value
		revision += 1

## Horizontal speed a dash sets along its direction, in m/s. A player already faster
## along it keeps their speed: a dash is never a brake.
@export_range(0.0, 100.0, 0.1) var dash_speed: float = 16.0:
	set(value):
		dash_speed = value
		revision += 1

## Upward speed a dash adds, in m/s, so a dash from the ground leaves it for a moment and
## ground friction does not eat it on the first tick.
@export_range(0.0, 20.0, 0.1) var dash_lift: float = 2.5:
	set(value):
		dash_lift = value
		revision += 1

## Seconds between dashes.
@export_range(0.0, 600.0, 0.1) var dash_cooldown: float = 3.0:
	set(value):
		dash_cooldown = value
		revision += 1

## Whether a dash works in mid-air.
@export var dash_from_air: bool = true:
	set(value):
		dash_from_air = value
		revision += 1

@export_group("Wall running")

## Whether an airborne player moving fast along a near-vertical wall runs along it.
## Off by default, like the slide: every [code]wall_run_*[/code] number is read only behind this and
## no wall probe is made. Reasoning in docs/wall-movement.md.
@export var wall_run_enabled: bool = false:
	set(value):
		wall_run_enabled = value
		revision += 1

## Horizontal speed ALONG the wall, in m/s, an airborne player needs to start a run.
## Measured along the wall rather than in total, so running into it head-on is no run.
@export_range(0.0, 100.0, 0.1) var wall_run_min_speed: float = 6.0:
	set(value):
		wall_run_min_speed = value
		revision += 1

## A run that slows below this speed along the wall, in m/s, ends.
@export_range(0.0, 100.0, 0.1) var wall_run_end_speed: float = 3.0:
	set(value):
		wall_run_end_speed = value
		revision += 1

## The longest a run lasts, in seconds: "a few steps". At most
## [constant WALL_RUN_TIME_LIMIT], which is what the replicated field can hold.
@export_range(0.05, 1.9, 0.05) var wall_run_max_time: float = 1.0:
	set(value):
		wall_run_max_time = value
		revision += 1

## Gravity while running, as a multiple of [member gravity]. 0 holds the height; 1 is
## an ordinary fall (with [member wall_run_vertical_damping] still slowing it).
@export_range(0.0, 1.0, 0.01) var wall_run_gravity_scale: float = 0.25:
	set(value):
		wall_run_gravity_scale = value
		revision += 1

## How fast the vertical speed a player arrives with is eased away while running, per second.
## Eased rather than zeroed: zeroing is a one-tick velocity spike. With [member wall_run_gravity_scale]
## it sets the slow sink a long run settles into ([code]gravity * scale / damping[/code]).
@export_range(0.0, 60.0, 0.1) var wall_run_vertical_damping: float = 8.0:
	set(value):
		wall_run_vertical_damping = value
		revision += 1

## A player falling faster than this, in m/s, does not catch a wall. Brushing a wall must
## not be a way to stop a long fall.
@export_range(0.0, 100.0, 0.1) var wall_run_max_fall_speed: float = 6.0:
	set(value):
		wall_run_max_fall_speed = value
		revision += 1

## The steepest angle a wall may lean from vertical, in degrees, and still be run on or
## jumped off. Applies to the wall jump too.
@export_range(0.0, 45.0, 0.5) var wall_max_angle_from_vertical: float = 15.0:
	set(value):
		wall_max_angle_from_vertical = value
		revision += 1

## The largest angle, in degrees, between the player's horizontal velocity and the wall's
## plane at which a run starts. The velocity must be at least [code]90 - this[/code] degrees
## from straight into the wall. 0 needs a velocity exactly along it; 90 accepts any.
@export_range(0.0, 90.0, 0.5) var wall_run_max_approach_angle: float = 60.0:
	set(value):
		wall_run_max_approach_angle = value
		revision += 1

## How tall a wall must be, in metres, for a run to START on it: the face has to reach this far
## up and down around the contact and above the player's hip. A crate edge or low ledge is not
## a wall to run on, though a wall jump off it still works. 0 turns the check off.
@export_range(0.0, 20.0, 0.1) var wall_run_min_height: float = 2.0:
	set(value):
		wall_run_min_height = value
		revision += 1

## How far the wall must continue ahead along the run, in metres, for a run to start. 0 is off.
@export_range(0.0, 20.0, 0.1) var wall_run_min_length: float = 1.0:
	set(value):
		wall_run_min_length = value
		revision += 1

## Whether forward has to be held to start and to keep running. Releasing it drops off
## the wall, which is the player's way off a run short of jumping.
@export var wall_run_requires_forward: bool = true:
	set(value):
		wall_run_requires_forward = value
		revision += 1

## Whether a jump press in the air beside a wall STARTS a run (the heading turns along the
## wall, at the speed the player had), and a second press leaves it by the wall jump.
## Needs [member wall_run_enabled]. Off by default.
@export var wall_run_on_jump: bool = false:
	set(value):
		wall_run_on_jump = value
		revision += 1

## Airborne and moving into a wall within the jump-run limits starts a run with no press
## (the heading turns along the wall); a press then wall-jumps. Replaces the on-jump press.
@export var wall_run_auto: bool = false:
	set(value):
		wall_run_auto = value
		revision += 1

## Horizontal speed, in m/s, a jump-started run needs. The speed is not measured along the
## wall: the press turns the heading, so any approach angle up to
## [member wall_run_jump_max_angle] qualifies.
@export_range(0.0, 100.0, 0.1) var wall_run_jump_min_speed: float = 5.0:
	set(value):
		wall_run_jump_min_speed = value
		revision += 1

## Widest angle, in degrees, between the velocity and the wall's plane at which a press
## starts a run. 90 accepts a head-on approach.
@export_range(0.0, 90.0, 0.5) var wall_run_jump_max_angle: float = 75.0:
	set(value):
		wall_run_jump_max_angle = value
		revision += 1

## Seconds after a run ends before another may start, jump-started or not. 0 for none.
@export_range(0.0, 10.0, 0.05) var wall_run_cooldown: float = 0.0:
	set(value):
		wall_run_cooldown = value
		revision += 1
## A jump-started run turns the player's view along the wall (the owner's look input is rotated once).
@export var wall_run_turn_view: bool = false:
	set(value):
		wall_run_turn_view = value
		revision += 1
## Widest angle, degrees, between the view and the new heading that the turn still applies at. 90 leaves a view facing into the wall alone; 180 always aligns it.
@export_range(1.0, 180.0, 1.0) var wall_run_turn_view_max_angle: float = 90.0:
	set(value):
		wall_run_turn_view_max_angle = value
		revision += 1

## How far beside the player, in metres, a wall still counts as touched: for a run, and
## for a wall jump off a wall the player is not running on.
@export_range(0.01, 1.0, 0.01) var wall_reach: float = 0.25:
	set(value):
		wall_reach = value
		revision += 1

## Fastest fall, in m/s, of an airborne player against a wall they push into or whose run ended
## on it: the wall slide, and what a timed-out run decays into. 0 turns it off (default).
## A faster fall is eased down at [member wall_run_vertical_damping], never cut in one tick.
@export_range(0.0, 50.0, 0.1) var wall_slide_speed: float = 0.0:
	set(value):
		wall_slide_speed = value
		revision += 1

@export_group("Wall jumping")

## Whether a jump press in the air beside a wall (touched or run on) jumps off it.
## Off by default, like [member wall_run_enabled]; the two are independent.
@export var wall_jump_enabled: bool = false:
	set(value):
		wall_jump_enabled = value
		revision += 1

## Speed a wall jump pushes away from the wall, in m/s. The speed the player had along
## the wall is kept on top of it.
@export_range(0.0, 50.0, 0.1) var wall_jump_push_speed: float = 7.0:
	set(value):
		wall_jump_push_speed = value
		revision += 1

## Upward speed a wall jump sets, in m/s. It replaces a lower vertical speed rather than
## adding to it, like the launch.
@export_range(0.0, 50.0, 0.1) var wall_jump_up_speed: float = 6.5:
	set(value):
		wall_jump_up_speed = value
		revision += 1

## How far the push leans from the wall's normal toward where the player looks, 0..1.
## 0 pushes straight out; the part of the look into the wall is ignored, so the push
## always leaves the wall.
@export_range(0.0, 1.0, 0.01) var wall_jump_look_blend: float = 0.3:
	set(value):
		wall_jump_look_blend = value
		revision += 1

## Wall jumps off the same wall before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width. The same wall is the same normal (within
## an eighth of a turn), so facing corridor walls can be climbed between but one alone cannot.
@export_range(0, 3, 1) var wall_jump_max_per_wall: int = 1:
	set(value):
		wall_jump_max_per_wall = value
		revision += 1

## Wall jumps in all, off any walls, before the player touches the ground again. 0 for no
## limit; at most 3, the replicated counter's width. On top of [member wall_jump_max_per_wall]:
## the budget a single airborne stretch gets, refilled only by landing.
@export_range(0, 3, 1) var wall_jump_max_per_air: int = 3:
	set(value):
		wall_jump_max_per_air = value
		revision += 1
