@tool
class_name DotFpsStyle
extends Resource

## A named variation on the movement, as a bhop or surf server means the word.
##
## [b]What a style is.[/b] "Sideways", "half-sideways", "backwards", "low gravity",
## "half time", "TAS" — the same map, the same timer, the same records table, played
## under different rules. Timer servers have had them for fifteen years and
## they are most of what keeps a map alive after its normal-style record has stopped
## moving: a run nobody can beat straight is wide open sideways.
##
## [b]A style is a transform, not a second movement system.[/b] It does exactly two
## things, and both are applied on the client and the server identically:
##
## [codeblock]
## controller.set_style(style)              # tunables := style.apply_to(base)
## style.filter_command(command)            # before the motor ever sees it
## [/codeblock]
##
## [method apply_to] returns a [i]derived[/i] [DotFpsTunables] and never mutates the
## base, so a server can hold one base configuration and hand thirty players thirty
## different styles without any of them treading on the others. [method filter_command]
## clears the buttons the style forbids.
##
## [b]Scales, not values[/b] — the same choice [DotFpsSurface] made, and for the same
## reason. A style that stored an absolute [code]max_speed[/code] would silently stop
## tracking the base movement the first time somebody retuned it, and the symptom is
## one style feeling wrong months later with nothing in its own definition to explain
## it. The exceptions are the two fields where a scale is meaningless
## ([member air_accelerate] and [member max_air_wish_speed]): those are absolute, and
## a non-positive value means "leave the base alone".
##
## [b]Every player on a server may be on a different style, and that is fine.[/b]
## The tunables are an input to the simulation, so the client and the server must
## agree — but they only have to agree [i]per player[/i]. What must not happen is a
## style changing mid-run, which is why [DotTimerRun] treats a style change as
## stopping the run.
##
## The ranking half of a style — is it ranked, what multiplier do its points carry,
## what is the shortest run that counts — is [code]DotTimerStyle[/code] in dot-timer.
## The split is deliberate: this half is movement and belongs where the motor is;
## that half is records and belongs where the records are. A game pairs them by id.

## A three-state switch, because a style has to be able to say "leave it alone".
##
## Two-state would need a second "does this style override it" bool per field, which
## is the same information with twice the ways to get it wrong.
enum Toggle {
	INHERIT,
	OFF,
	ON,
}

## Which keys a style leaves the player.
##
## Presets over the four block flags, because these five are what every timer
## actually ships and spelling them as flags in a config file gets one wrong.
## [constant KeyPreset.CUSTOM] leaves the flags exactly as set.
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

## Stable id. This is what travels on the wire and what a record is filed under.
##
## Renaming [member display_name] is free; changing this orphans every record ever
## set on the style, which is why they are two fields.
@export var id: StringName = &"normal"

@export var display_name: String = "Normal"

## Two or three characters, for a scoreboard column or a chat tag.
@export var short_name: String = "N"

## A hex colour for the HUD and the site leaderboard, e.g. [code]#7fc8ff[/code].
##
## A string rather than a [Color] so it survives a round trip through JSON and
## through the backbone's leaderboard API without anybody having to agree on a
## serialisation.
@export var html_colour: String = "#ffffff"

@export_multiline var description: String = ""

@export_group("Jumping")

## Hold the jump key instead of tapping it. The familiar
## [code]sv_autobunnyhopping[/code].
##
## Every modern bhop and surf server has this on. It is the difference between the
## skill being "time the tap to the tick" — which is a keyboard-hardware contest —
## and being "aim the strafes", which is the actual game.
@export var auto_hop: Toggle = Toggle.INHERIT

## Whether a jump pressed slightly early still fires on landing. The community
## timers'
## [code]easybhop[/code].
##
## [constant Toggle.OFF] sets the jump buffer to zero, so the press has to land on the
## tick the player touches down and a miss costs all the speed — "hard" or "prebhop"
## style. [constant Toggle.ON] restores the base buffer.
@export var easy_bhop: Toggle = Toggle.INHERIT

## Multiplier on jump height. 1 leaves it alone.
@export_range(0.0, 5.0, 0.01) var jump_scale: float = 1.0

@export_group("Physics")

## Multiplier on gravity. 0.5 is the usual "low gravity" style.
@export_range(0.01, 5.0, 0.01) var gravity_scale: float = 1.0

## Multiplier on ground speed.
@export_range(0.01, 5.0, 0.01) var speed_scale: float = 1.0

## Absolute [member DotFpsTunables.air_accelerate]. Non-positive inherits.
##
## Absolute because this number is not a feel dial: paired with
## [member max_air_wish_speed] it decides how much speed one strafe can add, and
## every style people have muscle memory for is defined by a specific pair.
@export var air_accelerate: float = 0.0

## Absolute [member DotFpsTunables.max_air_wish_speed]. Non-positive inherits.
@export var max_air_wish_speed: float = 0.0

## How fast the clock runs relative to real time. 0.5 is "half time".
##
## [b]Not applied by [method apply_to].[/b] Scaling the simulation means scaling
## [param delta], which is the host's tick loop's decision and not a tunable — and on
## a server it has to be the same decision for every player or the tick counter stops
## meaning anything. It lives here because it is part of the style's definition and
## because the timer needs it to convert ticks to a displayed time; the game applies
## it. See [method scaled_delta].
@export_range(0.05, 4.0, 0.01) var timescale: float = 1.0

@export_group("Keys")

@export var key_preset: KeyPreset = KeyPreset.FREE

## Individual key blocks. Written by [method apply_key_preset] for every preset
## except [constant KeyPreset.CUSTOM].
@export var block_forward: bool = false
@export var block_back: bool = false
@export var block_left: bool = false
@export var block_right: bool = false

## Allow only one strafe key at a time.
##
## Holding A and D together cancels to nothing on flat ground and is a real technique
## in the air, so a style that means "sideways" and not "sideways except for that"
## needs this as well as the blocks.
@export var one_strafe_key_only: bool = false

## Deny crouching entirely. Some styles do, because crouch-jumping trivialises them.
@export var block_crouch: bool = false

@export_group("Limits")

## Horizontal speed a player may leave the start zone with, in m/s. 0 = no limit.
##
## [b]Enforced by the timer, not here.[/b] "Leaving the start zone" is a zone event
## and the motor knows nothing about zones. It is defined on the style because it is
## part of what the style means, and because a record has to be able to say which
## limit it was set under. See [code]DotTimerRules.clamp_prespeed[/code].
@export_range(0.0, 200.0, 0.1) var prespeed_limit: float = 0.0

## Absolute speed cap while the style is in force, in m/s. 0 = the base cap.
##
## Applied to [member DotFpsTunables.max_velocity], so it is a real ceiling in the
## simulation rather than something a timer notices afterwards.
@export_range(0.0, 10000.0, 1.0) var velocity_limit: float = 0.0


# --- Deriving the tunables -------------------------------------------------

## The tunables for a player on this style. [param base] is never modified.
##
## [b]Returns a fresh resource every call[/b], and callers should hold the result
## rather than calling this per tick: a [Resource] allocation inside the tick loop on
## a thirty-player server is measurable, and — worse — the motor holds a reference to
## the tunables it was constructed with, so replacing them under it silently does
## nothing until the motor is rebuilt. [method DotFpsController.set_style] does both
## halves in the right order.
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

	# max_velocity is a backstop against a runaway, and a style that raises max_speed
	# past it would be refused by validate() — which is correct and is also a refusal
	# nobody would understand from the style definition alone. Lift the ceiling
	# instead; it is not a gameplay number.
	if out.max_speed > out.max_velocity:
		out.max_velocity = out.max_speed

	if block_crouch:
		out.can_crouch = false

	return out


## Scales a tick duration by [member timescale]. For a host that supports half-time.
func scaled_delta(delta: float) -> float:
	return delta * timescale


# --- Filtering the command -------------------------------------------------

## Writes the key blocks implied by [member key_preset] into the four flags.
##
## Called by [method filter_command], so a style loaded from JSON with only
## [code]key_preset[/code] set behaves correctly without the loader having to know
## the mapping. Idempotent.
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
##
## [b]Must be called on the client and the server, on the same command, before the
## motor sees it.[/b] Filtering only on the server makes the client predict movement
## the server will not produce, and the correction arrives a round trip later — which
## is the worst possible way to tell somebody a key is disabled.
##
## Idempotent, which is not incidental: a prediction rewind replays stored commands
## and this runs again on each of them.
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


# --- Serialisation ---------------------------------------------------------

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
##
## Spelled as a match rather than as a cast because the value may have come from a
## JSON file or from a server: an out-of-range int cast to an enum is not caught
## anywhere and produces a style whose key preset is a number nothing handles, which
## then falls through every match in [method apply_key_preset] and silently blocks
## nothing. Unknown values fall back to the neutral member.
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


## A short hash of everything that changes the simulation.
##
## Same job as [method DotFpsTunables.fingerprint] and the same reason: a client and
## a server on styles that differ by one field produce a correction every tick, and
## the symptom is indistinguishable from packet loss. Presentation fields are
## excluded — two servers may colour a style differently and still agree about it.
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


# --- The styles every timer ships -----------------------------------------

## The six styles a bhop or surf server is expected to have on day one.
##
## Not a hard-coded list the addon uses anywhere: it is what a game copies and edits.
## Shipping them means a server operator gets a working style table without having to
## know that "half-sideways" means "forward and one strafe key, no back".
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
