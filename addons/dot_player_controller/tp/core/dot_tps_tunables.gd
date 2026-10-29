@tool
class_name DotTpsTunables
extends DotConfig

## Every number a third-person controller has, layered.

@export_group("Ground")

## Metres per second at full stick.
@export_range(0.1, 100.0, 0.1) var walk_speed: float = 4.0

@export_range(0.1, 100.0, 0.1) var run_speed: float = 7.0

@export_range(0.1, 100.0, 0.1) var crouch_speed: float = 2.0

## How quickly the character reaches its target speed, in m/s².
## Acceleration, not a snap: a visible model changing direction instantly reads as weightless.
@export_range(1.0, 500.0, 1.0) var acceleration: float = 45.0

## How quickly it stops.
@export_range(1.0, 500.0, 1.0) var deceleration: float = 60.0

@export_group("Air")

@export_range(0.0, 200.0, 0.1) var gravity: float = 20.0

## Apex height of a jump, in metres. Converted with the gravity above.
@export_range(0.0, 20.0, 0.01) var jump_height: float = 1.1

## Fraction of ground acceleration available in the air.
## Zero makes a missed jump unrecoverable; one makes the arc meaningless.
@export_range(0.0, 1.0, 0.01) var air_control: float = 0.33

## Seconds after walking off a ledge during which a jump still works.
## Without it a jump pressed one frame late just falls and reads as unreliable.
@export_range(0.0, 1.0, 0.01) var coyote_time: float = 0.12

## Seconds before landing during which a jump press is remembered.
##
## The other half of the same problem, from the other side.
@export_range(0.0, 1.0, 0.01) var jump_buffer: float = 0.15

## How many extra jumps are available in the air.
@export_range(0, 8, 1) var air_jumps: int = 0

@export_group("Turning")

## How the character's facing relates to the camera: [code]face_movement[/code] turns towards travel,
## [code]face_camera[/code] locks to the camera for strafing (aiming is a temporary face_camera).
@export_enum("face_movement", "face_camera") var turn_mode: int = 0

## Radians per second the body turns towards its target facing (not instant, for the same reason as acceleration).
@export_range(0.1, 100.0, 0.1) var turn_speed: float = 12.0

@export_group("Camera")

## Metres behind the character.
@export_range(0.5, 30.0, 0.1) var camera_distance: float = 4.0

## Metres behind while aiming.
@export_range(0.1, 30.0, 0.1) var aim_distance: float = 1.6

## Metres above the character's feet the arm pivots at.
@export_range(0.0, 10.0, 0.01) var camera_height: float = 1.5

## Metres to the side. Positive is over the right shoulder.
## Keeps the character off the line between the player and the target, so a crosshair means something.
@export_range(-3.0, 3.0, 0.01) var shoulder_offset: float = 0.55

## Shoulder offset while aiming.
@export_range(-3.0, 3.0, 0.01) var aim_shoulder_offset: float = 0.4

## How far down and up the camera may pitch, in degrees.
@export_range(-89.0, 0.0, 0.5) var pitch_min: float = -60.0

@export_range(0.0, 89.0, 0.5) var pitch_max: float = 70.0

## How quickly the camera catches up with the character, per second, frame-rate independent.
## Zero is rigid (right for a competitive shooter).
@export_range(0.0, 60.0, 0.1) var camera_lag: float = 18.0

## How quickly the distance and shoulder change when aiming starts.
@export_range(0.1, 60.0, 0.1) var aim_blend: float = 12.0

## Field of view while aiming, as a fraction of the normal one.
@export_range(0.2, 1.0, 0.01) var aim_fov_scale: float = 0.8


func env_prefix() -> String:
	return "DOT_TPS_"


func cli_prefix() -> String:
	return "--tps-"


func validate() -> DotResult:
	if run_speed < walk_speed:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Running (%.1f) is slower than walking (%.1f)." % [run_speed, walk_speed]
		)

	if pitch_min >= pitch_max:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The camera's pitch range is inverted (%.1f to %.1f)." % [pitch_min, pitch_max]
		)

	if aim_distance > camera_distance:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Aiming pulls the camera to %.1f m and it sits at %.1f m."
			% [aim_distance, camera_distance],
			"Aiming would push the camera away from the character, which is the "
			+ "opposite of what the player pressed the button for."
		)

	if deceleration <= 0.0 or acceleration <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "Acceleration must be positive.")

	return DotResult.success(null)


## Launch speed for the configured jump height under the configured gravity.
func jump_speed() -> float:
	return sqrt(2.0 * maxf(0.0001, gravity) * maxf(0.0, jump_height))


func pitch_min_radians() -> float:
	return deg_to_rad(pitch_min)


func pitch_max_radians() -> float:
	return deg_to_rad(pitch_max)


func speed_for(running: bool, crouched: bool) -> float:
	if crouched:
		return crouch_speed

	return run_speed if running else walk_speed


## A frame-rate-independent smoothing factor.
## Not [code]lerp(a, b, rate * delta)[/code], which differs at 60 and 144 fps and can oscillate when low.
## The exponential form converges the same at any rate.
static func smoothing(rate: float, delta: float) -> float:
	if rate <= 0.0:
		return 1.0

	return 1.0 - exp(-rate * delta)


# Presets

## Over-the-shoulder, camera-locked, tight. A third-person shooter.
static func shooter() -> DotTpsTunables:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var t := new()
	t.turn_mode = 1
	t.walk_speed = 3.2
	t.run_speed = 6.0
	t.acceleration = 60.0
	t.deceleration = 80.0
	t.camera_distance = 3.2
	t.shoulder_offset = 0.6
	t.camera_lag = 25.0
	t.air_control = 0.25
	return t


## Behind and above, turning to face movement. An adventure game.
static func adventure() -> DotTpsTunables:
	var t := new()
	t.turn_mode = 0
	t.walk_speed = 3.0
	t.run_speed = 6.5
	t.camera_distance = 5.0
	t.shoulder_offset = 0.0
	t.camera_height = 1.7
	t.camera_lag = 10.0
	t.turn_speed = 9.0
	return t


## Fast, forgiving, and jumping a lot. A platformer.
static func platformer() -> DotTpsTunables:
	var t := new()
	t.turn_mode = 0
	t.walk_speed = 5.0
	t.run_speed = 9.0
	t.acceleration = 80.0
	t.jump_height = 1.8
	t.air_control = 0.6
	t.air_jumps = 1
	t.coyote_time = 0.15
	t.jump_buffer = 0.2
	t.camera_distance = 6.0
	t.shoulder_offset = 0.0
	return t


static func presets() -> Dictionary:
	return {
		&"shooter": shooter,
		&"adventure": adventure,
		&"platformer": platformer,
	}


static func preset(p_id: StringName) -> DotTpsTunables:
	var table := presets()

	if not table.has(p_id):
		return null

	var fn: Callable = table[p_id]
	# Returned through the declared type rather than cast to this class by name; see the
	# note on the presets above.
	return fn.call()
