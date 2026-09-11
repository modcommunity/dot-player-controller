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
## The defaults are the classic ones: fast acceleration, low friction, air control
## that permits strafe-jumping and bunny-hopping. They are a starting point for a
## movement shooter, not a recommendation for every game.

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

@export_group("Speeds")

## Ground speed with no modifier held, in metres per second.
@export_range(0.1, 100.0, 0.1) var max_speed: float = 7.0

## Multipliers applied to [member max_speed]. They do not stack; the most restrictive
## one held wins, in the order crouch, walk, sprint.
##
## [b]This ordering is the fix for a real bug.[/b] The previous controller stored one
## [code]speed_multiplier[/code] and each of crouch/walk/sprint reset it to 1 on
## release, so releasing sprint while still crouched restored full speed and the
## player crouch-ran at sprint speed. Deriving the scale from the held buttons every
## tick makes that unrepresentable.
@export_range(0.0, 5.0, 0.01) var crouch_speed_scale: float = 0.4
@export_range(0.0, 5.0, 0.01) var walk_speed_scale: float = 0.45
@export_range(0.0, 5.0, 0.01) var sprint_speed_scale: float = 1.5

## Speed multiplier applied when moving backwards, as those games do.
##
## Below 1 it discourages backpedalling in a fight without taking control away.
@export_range(0.1, 1.0, 0.01) var backward_speed_scale: float = 1.0

## Hard ceiling on speed in any direction, in m/s.
##
## A backstop against a bug or an exploit compounding into an unbounded velocity, not
## a gameplay number. Keep it well above anything the game can legitimately reach —
## clamping a launcher or a conveyor is a worse failure than the runaway it prevents.
@export_range(1.0, 10000.0, 1.0) var max_velocity: float = 400.0

@export_group("Ground movement")

## Acceleration toward the wish direction on the ground, in units of wish speed
## per second. The familiar [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 10.0

## Friction applied on the ground. The familiar [code]sv_friction[/code].
@export_range(0.0, 20.0, 0.1) var friction: float = 6.0

## Speed below which friction is applied as if the player were moving this fast.
##
## Without it friction is proportional to speed and asymptotes toward zero, so a
## player drifts for a long time at walking pace after releasing the keys. The
## familiar
## [code]sv_stopspeed[/code].
@export_range(0.0, 50.0, 0.1) var stop_speed: float = 4.0

@export_group("Air movement")

## Acceleration while airborne. The familiar [code]sv_airaccelerate[/code].
##
## Large — 100 is not a typo. It is bounded by [member max_air_wish_speed], not by
## this, which is exactly the mechanism that makes air-strafing work: see
## [method DotFpsMotor.accelerate].
@export_range(0.0, 1000.0, 1.0) var air_accelerate: float = 100.0

## The cap that makes air-strafing possible, in m/s.
##
## [b]The whole of air control is this one number.[/b] Airborne acceleration is
## clamped to the projection of current velocity onto the wish direction, so holding
## strafe and turning adds speed perpendicular to motion — which barely reduces the
## projection, so it can be added again next tick. Raise it and air control becomes
## a jetpack; set it to zero and there is none at all.
@export_range(0.0, 100.0, 0.1) var max_air_wish_speed: float = 1.0

## Downward acceleration, in m/s².
##
## Not read from the project's physics settings: those are a rendering-side default
## that a host project may change for its rigid bodies, and a value the client and
## server could disagree about is a value the simulation cannot use.
@export_range(0.0, 200.0, 0.1) var gravity: float = 20.0

## Air friction. Zero in this movement model, and changing it breaks strafe-jumping.
@export_range(0.0, 20.0, 0.05) var air_friction: float = 0.0

@export_group("Jumping")

## Peak height of a standing jump on flat ground, in metres.
##
## Converted to a launch speed with [code]sqrt(2 * gravity * height)[/code], so it
## stays honest when gravity is changed.
@export_range(0.0, 20.0, 0.01) var jump_height: float = 1.1

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
@export_range(0.0, 0.5, 0.005) var coyote_time: float = 0.1

## Seconds before landing during which a jump press is remembered.
##
## The other half of the same forgiveness: pressing jump just before touching down
## should jump on touchdown, not be swallowed.
@export_range(0.0, 0.5, 0.005) var jump_buffer_time: float = 0.1

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
## bunny-hopping. Set it to 1.104 to reproduce retail CS:S.
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
@export_range(0.0, 2.0, 0.01) var step_height: float = 0.4

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
func speed_for(buttons: int) -> float:
	var scale := 1.0

	if can_crouch and (buttons & DotFpsCommand.BUTTON_CROUCH):
		scale = crouch_speed_scale
	elif can_walk and (buttons & DotFpsCommand.BUTTON_WALK):
		scale = walk_speed_scale
	elif can_sprint and (buttons & DotFpsCommand.BUTTON_SPRINT):
		scale = sprint_speed_scale

	return max_speed * scale


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
