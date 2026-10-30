@tool
class_name DotFpsTunables
extends "dot_fps_tunables_base.gd"

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
	"sv_sprint_shoot": ["sprint_can_shoot", 1.0, "0 blocks firing while sprinting"],
	"sv_sprint_barrel": ["sprint_shot_follows_barrel", 1.0, "1 sends a sprinting shot along the lowered barrel, not the crosshair"],
	"sv_unscope_hit": ["unscope_on_hit", 1.0, "1 drops a player out of the sights when hit; 0 keeps them aiming (shake and wobble instead)"],
	"sv_unscope_hittime": ["unscope_hit_time", 1.0, "Seconds the sights stay refused after a hit"],
	"sv_hit_shake": ["hit_shake", 1.0, "Degrees of view roll a hit shakes by; 0 off"],
	"sv_hit_wobble": ["hit_wobble", 1.0, "Degrees a hit wobbles the aim by; 0 off"],
	"sv_hit_wobble_hz": ["hit_wobble_hz", 1.0, "Wobble and shake cycles per second"],
	"sv_hit_flinch_time": ["hit_flinch_time", 1.0, "Seconds a hit's shake and wobble last; 0 off"],
	"sv_hit_damage_scale": ["hit_damage_scale", 1.0, "0 every hit flinches the same, 1 in proportion to the damage"],
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
	"sv_wallrun_minheight": ["wall_run_min_height", 1.0, "Wall height a run needs to start on it, m; 0 off (a wall jump needs none)"],
	"sv_wallrun_minlength": ["wall_run_min_length", 1.0, "Wall length ahead a run needs to start, m; 0 off"],
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


# How far these numbers carry a player, so a map sizes a gap or ledge against the class and not its own copy of the formula.

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
