@tool
class_name DotFpsStyle
extends Resource

## A named variation on the movement ("sideways", "low gravity"): same map and records table, different rules.
## A transform, not a second system: [method apply_to] derives tunables without mutating the base and [method filter_command] clears forbidden buttons, identically on client and server.
## A style must not change mid-run ([DotTimerRun]); the ranking half is [code]DotTimerStyle[/code] in dot-timer.

## A three-state switch so a style can say "leave it alone" without a second override bool per field.
enum Toggle {
	INHERIT,
	OFF,
	ON,
}

## Presets over the four block flags, the five combinations timers ship; [constant KeyPreset.CUSTOM] leaves the flags as set.
enum KeyPreset {
	## Every key. Normal style.
	FREE,
	## Forward only. No strafe keys, so the only air control is the mouse.
	FORWARD_ONLY,
	## Strafe keys only. "Sideways" — the classic.
	SIDEWAYS,
	## Forward plus a strafe key. "Half-sideways" (HSW).
	HALF_SIDEWAYS,
	## Back only.
	BACKWARDS,
	## Whatever the block flags say.
	CUSTOM,
}

@export_group("Identity")

## Stable id; it travels on the wire and files records. Renaming [member display_name] is free, changing this orphans records.
@export var id: StringName = &"normal"

@export var display_name: String = "Normal"

## Two or three characters, for a scoreboard column or a chat tag.
@export var short_name: String = "N"

## A hex colour for the HUD and leaderboard, e.g. [code]#7fc8ff[/code]; a string so it survives JSON unchanged.
@export var html_colour: String = "#ffffff"

@export_multiline var description: String = ""

@export_group("Jumping")

## Hold the jump key instead of tapping it ([code]sv_autobunnyhopping[/code]), so the skill is aiming strafes, not tap timing.
@export var auto_hop: Toggle = Toggle.INHERIT

## Whether a jump pressed slightly early still fires on landing ([code]easybhop[/code]).
## [constant Toggle.OFF] zeroes the jump buffer ("hard" or "prebhop"); [constant Toggle.ON] restores the base buffer.
@export var easy_bhop: Toggle = Toggle.INHERIT

## Multiplier on jump height. 1 leaves it alone.
@export_range(0.0, 5.0, 0.01) var jump_scale: float = 1.0

@export_group("Physics")

## Multiplier on gravity. 0.5 is the usual "low gravity" style.
@export_range(0.01, 5.0, 0.01) var gravity_scale: float = 1.0

## Multiplier on ground speed.
@export_range(0.01, 5.0, 0.01) var speed_scale: float = 1.0

## Absolute [member DotFpsTunables.air_accelerate]. Non-positive inherits.
## Absolute because with [member max_air_wish_speed] it fixes how much one strafe adds, and styles are defined by that pair.
@export var air_accelerate: float = 0.0

## Absolute [member DotFpsTunables.max_air_wish_speed]. Non-positive inherits.
@export var max_air_wish_speed: float = 0.0

## How fast the clock runs relative to real time; 0.5 is "half time".
## Not applied by [method apply_to]: scaling [param delta] is the host tick loop's decision and must be the same for every player. See [method scaled_delta].
@export_range(0.05, 4.0, 0.01) var timescale: float = 1.0

@export_group("Keys")

@export var key_preset: KeyPreset = KeyPreset.FREE

## Individual key blocks. Written by [method apply_key_preset] for every preset
## except [constant KeyPreset.CUSTOM].
@export var block_forward: bool = false
@export var block_back: bool = false
@export var block_left: bool = false
@export var block_right: bool = false

## Allow only one strafe key at a time (A and D together cancel on the ground but are a technique in the air).
@export var one_strafe_key_only: bool = false

## Deny crouching entirely. Some styles do, because crouch-jumping trivialises them.
@export var block_crouch: bool = false

@export_group("Limits")

## Horizontal speed a player may leave the start zone with, in m/s. 0 = no limit.
## Enforced by the timer (the motor knows no zones); defined here so a record says which limit it was set under. See [code]DotTimerRules.clamp_prespeed[/code].
@export_range(0.0, 200.0, 0.1) var prespeed_limit: float = 0.0

## Absolute speed cap while the style is in force, in m/s. 0 = the base cap; applied to [member DotFpsTunables.max_velocity], a real ceiling in the simulation.
@export_range(0.0, 10000.0, 1.0) var velocity_limit: float = 0.0



## The tunables for a player on this style. [param base] is never modified.
## Returns a fresh resource each call; hold the result. The motor keeps the tunables it was built with, so
## [method DotFpsController.set_style] swaps both in the right order.
func apply_to(base: DotFpsTunables) -> DotFpsTunables:
	if base == null:
		base = DotFpsTunables.new()

	var out := base.duplicate(true) as DotFpsTunables

	match auto_hop:
		Toggle.ON:
			out.auto_hop = true
		Toggle.OFF:
			out.auto_hop = false

	match easy_bhop:
		Toggle.ON:
			# Restore the base window, or a sane one if the base had none. A style
			# that says "easy" and then leaves a zero buffer is a style that says
			# nothing.
			out.jump_buffer_time = maxf(base.jump_buffer_time, 0.1)
		Toggle.OFF:
			# The press has to land on the tick of the touchdown. This is the whole
			# of "hard" bhop.
			out.jump_buffer_time = 0.0

	out.jump_height = base.jump_height * jump_scale
	out.gravity = base.gravity * gravity_scale
	out.max_speed = base.max_speed * speed_scale

	if air_accelerate > 0.0:
		out.air_accelerate = air_accelerate

	if max_air_wish_speed > 0.0:
		out.max_air_wish_speed = max_air_wish_speed

	if velocity_limit > 0.0:
		out.max_velocity = velocity_limit

	# max_velocity is a backstop; raising max_speed past it would make validate() refuse the style for a reason the
	# style does not show, so lift the ceiling instead.
	if out.max_speed > out.max_velocity:
		out.max_velocity = out.max_speed

	if block_crouch:
		out.can_crouch = false

	return out


## Scales a tick duration by [member timescale]. For a host that supports half-time.
func scaled_delta(delta: float) -> float:
	return delta * timescale



## Writes the key blocks implied by [member key_preset] into the four flags.
## Idempotent; [method filter_command] calls it, so a style loaded from JSON with only [code]key_preset[/code] works.
func apply_key_preset() -> void:
	match key_preset:
		KeyPreset.FREE:
			block_forward = false
			block_back = false
			block_left = false
			block_right = false
		KeyPreset.FORWARD_ONLY:
			block_forward = false
			block_back = true
			block_left = true
			block_right = true
		KeyPreset.SIDEWAYS:
			block_forward = true
			block_back = true
			block_left = false
			block_right = false
		KeyPreset.HALF_SIDEWAYS:
			# Forward and one strafe key. Blocking back is what makes it "half":
			# the player is committed to a diagonal and steers with the mouse.
			block_forward = false
			block_back = true
			block_left = false
			block_right = false
		KeyPreset.BACKWARDS:
			block_forward = true
			block_back = false
			block_left = true
			block_right = true
		KeyPreset.CUSTOM:
			pass


## Removes the input this style forbids, in place.
## [b]Call on client and server, on the same command, before the motor.[/b] Server-only filtering makes the client predict movement the server then corrects.
## Idempotent, because a rewind replays stored commands through it again.
func filter_command(command: DotFpsCommand) -> void:
	if command == null:
		return

	apply_key_preset()

	if block_forward and command.move.y > 0.0:
		command.move.y = 0.0

	if block_back and command.move.y < 0.0:
		command.move.y = 0.0

	# x is "strafe right", so left is the negative half.
	if block_left and command.move.x < 0.0:
		command.move.x = 0.0

	if block_right and command.move.x > 0.0:
		command.move.x = 0.0

	if one_strafe_key_only and command.move.x != 0.0 and command.move.y != 0.0:
		# Keep the strafe. A style called "sideways" that silently preferred the
		# forward key would let a player hold W+D and get the diagonal it exists to
		# remove.
		command.move.y = 0.0

	if block_crouch:
		command.set_button(DotFpsCommand.BUTTON_CROUCH, false)



## The style as a plain dictionary, for a config file or the wire.
func to_dictionary() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"short_name": short_name,
		"html_colour": html_colour,
		"description": description,
		"auto_hop": auto_hop,
		"easy_bhop": easy_bhop,
		"jump_scale": jump_scale,
		"gravity_scale": gravity_scale,
		"speed_scale": speed_scale,
		"air_accelerate": air_accelerate,
		"max_air_wish_speed": max_air_wish_speed,
		"timescale": timescale,
		"key_preset": key_preset,
		"block_forward": block_forward,
		"block_back": block_back,
		"block_left": block_left,
		"block_right": block_right,
		"one_strafe_key_only": one_strafe_key_only,
		"block_crouch": block_crouch,
		"prespeed_limit": prespeed_limit,
		"velocity_limit": velocity_limit,
	}


static func from_dictionary(data: Dictionary) -> DotFpsStyle:
	var style := DotFpsStyle.new()

	style.id = StringName(str(data.get("id", "normal")))
	style.display_name = str(data.get("display_name", String(style.id)))
	style.short_name = str(data.get("short_name", style.display_name.substr(0, 2)))
	style.html_colour = str(data.get("html_colour", "#ffffff"))
	style.description = str(data.get("description", ""))

	style.auto_hop = _to_toggle(data.get("auto_hop", Toggle.INHERIT))
	style.easy_bhop = _to_toggle(data.get("easy_bhop", Toggle.INHERIT))

	style.jump_scale = float(data.get("jump_scale", 1.0))
	style.gravity_scale = float(data.get("gravity_scale", 1.0))
	style.speed_scale = float(data.get("speed_scale", 1.0))
	style.air_accelerate = float(data.get("air_accelerate", 0.0))
	style.max_air_wish_speed = float(data.get("max_air_wish_speed", 0.0))
	style.timescale = float(data.get("timescale", 1.0))

	style.key_preset = _to_key_preset(data.get("key_preset", KeyPreset.FREE))
	style.block_forward = bool(data.get("block_forward", false))
	style.block_back = bool(data.get("block_back", false))
	style.block_left = bool(data.get("block_left", false))
	style.block_right = bool(data.get("block_right", false))
	style.one_strafe_key_only = bool(data.get("one_strafe_key_only", false))
	style.block_crouch = bool(data.get("block_crouch", false))

	style.prespeed_limit = float(data.get("prespeed_limit", 0.0))
	style.velocity_limit = float(data.get("velocity_limit", 0.0))

	style.apply_key_preset()

	return style


## Reads an enum out of untrusted data.
## A match rather than a cast: an out-of-range int would give a preset nothing handles and silently block nothing. Unknown falls back to the neutral member.
static func _to_toggle(value: Variant) -> Toggle:
	match int(value):
		Toggle.OFF:
			return Toggle.OFF
		Toggle.ON:
			return Toggle.ON
		_:
			return Toggle.INHERIT


static func _to_key_preset(value: Variant) -> KeyPreset:
	match int(value):
		KeyPreset.FORWARD_ONLY:
			return KeyPreset.FORWARD_ONLY
		KeyPreset.SIDEWAYS:
			return KeyPreset.SIDEWAYS
		KeyPreset.HALF_SIDEWAYS:
			return KeyPreset.HALF_SIDEWAYS
		KeyPreset.BACKWARDS:
			return KeyPreset.BACKWARDS
		KeyPreset.CUSTOM:
			return KeyPreset.CUSTOM
		_:
			return KeyPreset.FREE


## A short hash of everything that changes the simulation, like [method DotFpsTunables.fingerprint].
## Presentation fields are excluded.
func fingerprint() -> String:
	apply_key_preset()

	return DotHash.sha256_text("|".join(PackedStringArray([
		String(id),
		str(auto_hop), str(easy_bhop),
		"%.4f" % jump_scale, "%.4f" % gravity_scale, "%.4f" % speed_scale,
		"%.4f" % air_accelerate, "%.4f" % max_air_wish_speed,
		"%.4f" % timescale,
		str(block_forward), str(block_back), str(block_left), str(block_right),
		str(one_strafe_key_only), str(block_crouch),
		"%.4f" % prespeed_limit, "%.4f" % velocity_limit,
	]))).substr(0, 16)



## The six styles a bhop or surf server is expected to have on day one.
## Not used by the addon: it is what a game copies and edits.
static func defaults() -> Array[DotFpsStyle]:
	var out: Array[DotFpsStyle] = []

	var normal := DotFpsStyle.new()
	normal.id = &"normal"
	normal.display_name = "Normal"
	normal.short_name = "N"
	normal.html_colour = "#ffffff"
	normal.auto_hop = Toggle.ON
	normal.easy_bhop = Toggle.ON
	out.append(normal)

	var sideways := DotFpsStyle.new()
	sideways.id = &"sideways"
	sideways.display_name = "Sideways"
	sideways.short_name = "SW"
	sideways.html_colour = "#ffb347"
	sideways.auto_hop = Toggle.ON
	sideways.easy_bhop = Toggle.ON
	sideways.key_preset = KeyPreset.SIDEWAYS
	out.append(sideways)

	var half := DotFpsStyle.new()
	half.id = &"half_sideways"
	half.display_name = "Half-Sideways"
	half.short_name = "HSW"
	half.html_colour = "#ff7f7f"
	half.auto_hop = Toggle.ON
	half.easy_bhop = Toggle.ON
	half.key_preset = KeyPreset.HALF_SIDEWAYS
	half.one_strafe_key_only = true
	out.append(half)

	var backwards := DotFpsStyle.new()
	backwards.id = &"backwards"
	backwards.display_name = "Backwards"
	backwards.short_name = "BW"
	backwards.html_colour = "#b39ddb"
	backwards.auto_hop = Toggle.ON
	backwards.easy_bhop = Toggle.ON
	backwards.key_preset = KeyPreset.BACKWARDS
	out.append(backwards)

	var low_gravity := DotFpsStyle.new()
	low_gravity.id = &"low_gravity"
	low_gravity.display_name = "Low Gravity"
	low_gravity.short_name = "LG"
	low_gravity.html_colour = "#7fe0c0"
	low_gravity.auto_hop = Toggle.ON
	low_gravity.easy_bhop = Toggle.ON
	low_gravity.gravity_scale = 0.5
	out.append(low_gravity)

	var hard := DotFpsStyle.new()
	hard.id = &"prebhop"
	hard.display_name = "Prebhop"
	hard.short_name = "PB"
	hard.html_colour = "#ff5f5f"
	# The one style where the jump has to be tapped on the exact tick of the landing.
	hard.auto_hop = Toggle.OFF
	hard.easy_bhop = Toggle.OFF
	out.append(hard)

	return out


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"speed": "x%.2f" % speed_scale,
		"gravity": "x%.2f" % gravity_scale,
		"auto_hop": Toggle.keys()[auto_hop],
		"easy_bhop": Toggle.keys()[easy_bhop],
		"key_preset": KeyPreset.keys()[key_preset],
		"timescale": "x%.2f" % timescale,
		"fingerprint": fingerprint(),
	}


func _to_string() -> String:
	return "DotFpsStyle(%s)" % display_name
