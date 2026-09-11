class_name DotPlayerIntent
extends RefCounted

## One tick of what a player wants, in a form every controller understands.
##
## [b]Intent, not input, and not movement.[/b] It says "forward and right, holding
## jump, looking here" — it does not say which key that was and it does not say what
## happens. A sampler turns devices into one of these; a controller turns one of these
## into motion; a replay hands the same ones back; a server receives them over the wire
## and never sees a keyboard at all.
##
## Each controller in this family still has its own richer command — dot-player-
## controller-fp's [code]DotFpsCommand[/code] carries the movement model's own fields —
## and this is the part they agree about. That is what makes a switch between two
## controllers possible at all: the intent survives the handover even though the state
## does not.

## Ground-plane intent, each component in [code]-1..1[/code].
##
## [b]Deliberately not normalised on arrival.[/b] A controller normalises if its
## movement model says diagonal movement should not be faster, and some models say it
## should — air-strafing depends on the raw vector — so the decision belongs to the
## controller rather than to the value.
var move: Vector2 = Vector2.ZERO

## Look change this tick, in radians. Yaw in x, pitch in y.
##
## A delta rather than an absolute angle because a mouse produces deltas, and because a
## client and a server that disagreed about an absolute angle would fight over it every
## tick. The accumulated angles are in [member view_yaw] and [member view_pitch].
var look: Vector2 = Vector2.ZERO

## Everything held this tick, as [enum Button] bits.
var buttons: int = 0

## Buttons that were not held last tick. Computed by [method diff_from].
##
## Needed because "pressed" and "held" are different intents — a jump is an edge and a
## sprint is a level — and a controller computing edges itself would need to keep the
## previous command, which a stateless replay does not have.
var pressed: int = 0

## Buttons released this tick.
var released: int = 0

## The simulated tick this intent belongs to.
var tick: int = 0

## The accumulated view angles after this tick's [member look] was applied.
var view_yaw: float = 0.0
var view_pitch: float = 0.0

## Anything a game's own controller wants to carry. Not sent by default.
var extra: Dictionary = {}


## Everything a controller might be told to do, as bits.
##
## One list rather than one per controller: a switch that hands over between a
## first-person controller and a vehicle needs both ends to agree what "use" means, and
## two enums with the same names and different values is the quietest possible bug.
##
## [b]Called [code]Btn[/code] rather than [code]Button[/code].[/b] [Button] is a native
## class — the [Control] — and GDScript refuses the shadowing outright. Better here than
## in a subclass, where the error would be reported against the file that used it.
enum Btn {
	NONE = 0,
	JUMP = 1 << 0,
	CROUCH = 1 << 1,
	SPRINT = 1 << 2,
	WALK = 1 << 3,
	USE = 1 << 4,
	ATTACK = 1 << 5,
	ATTACK_ALT = 1 << 6,
	RELOAD = 1 << 7,
	ZOOM = 1 << 8,
	ABILITY_1 = 1 << 9,
	ABILITY_2 = 1 << 10,
	ABILITY_3 = 1 << 11,
	SCORE = 1 << 12,
	## Free for a game. Nothing in this family reads them.
	CUSTOM_1 = 1 << 24,
	CUSTOM_2 = 1 << 25,
	CUSTOM_3 = 1 << 26,
	CUSTOM_4 = 1 << 27,
}

## The names a console, a rebinder or a describe line uses, by bit.
const BUTTON_NAMES := {
	Btn.JUMP: "jump",
	Btn.CROUCH: "crouch",
	Btn.SPRINT: "sprint",
	Btn.WALK: "walk",
	Btn.USE: "use",
	Btn.ATTACK: "attack",
	Btn.ATTACK_ALT: "attack2",
	Btn.RELOAD: "reload",
	Btn.ZOOM: "zoom",
	Btn.ABILITY_1: "ability1",
	Btn.ABILITY_2: "ability2",
	Btn.ABILITY_3: "ability3",
	Btn.SCORE: "score",
}


static func make(
	p_move: Vector2 = Vector2.ZERO,
	p_buttons: int = 0,
	p_tick: int = 0
) -> DotPlayerIntent:
	var i := DotPlayerIntent.new()
	i.move = p_move
	i.buttons = p_buttons
	i.tick = p_tick
	return i


func holding(button: int) -> bool:
	return (buttons & button) != 0


func just_pressed(button: int) -> bool:
	return (pressed & button) != 0


func just_released(button: int) -> bool:
	return (released & button) != 0


## Fills [member pressed] and [member released] from the previous tick's buttons.
##
## Takes the raw bits rather than a whole intent so that a controller keeping only an
## [code]int[/code] of history — which is all it needs — does not have to keep a whole
## object alive to compute an edge.
func diff_from(previous_buttons: int) -> void:
	pressed = buttons & ~previous_buttons
	released = previous_buttons & ~buttons


func is_idle() -> bool:
	return buttons == 0 and move.is_zero_approx() and look.is_zero_approx()


func copy_intent() -> DotPlayerIntent:
	var i := DotPlayerIntent.new()
	i.move = move
	i.look = look
	i.buttons = buttons
	i.pressed = pressed
	i.released = released
	i.tick = tick
	i.view_yaw = view_yaw
	i.view_pitch = view_pitch
	i.extra = extra.duplicate(true)
	return i


## The wire form. Angles are sent, deltas are not.
##
## [b]Deltas are not on the wire on purpose.[/b] A server that integrated a client's
## look deltas would be reconstructing an angle the client already knows, one packet
## loss away from disagreeing about it forever. The client sends where it is looking;
## the server clamps and accepts.
func to_dict() -> Dictionary:
	return {
		"mx": move.x,
		"my": move.y,
		"b": buttons,
		"t": tick,
		"yaw": view_yaw,
		"pitch": view_pitch,
	}


static func from_dict(d: Dictionary) -> DotPlayerIntent:
	var i := DotPlayerIntent.new()
	i.move = Vector2(float(d.get("mx", 0.0)), float(d.get("my", 0.0)))
	i.buttons = int(d.get("b", 0))
	i.tick = int(d.get("t", 0))
	i.view_yaw = float(d.get("yaw", 0.0))
	i.view_pitch = float(d.get("pitch", 0.0))
	return i


## The names of the buttons held, for a describe line or a console.
func button_names() -> PackedStringArray:
	var out := PackedStringArray()

	for bit: Variant in BUTTON_NAMES.keys():
		if (buttons & int(bit)) != 0:
			out.append(str(BUTTON_NAMES[bit]))

	return out


## The bit for a name, or 0.
static func button_of(name: String) -> int:
	for bit: Variant in BUTTON_NAMES.keys():
		if str(BUTTON_NAMES[bit]) == name:
			return int(bit)

	return 0


func describe() -> String:
	return "t%d move=(%.2f, %.2f) yaw=%.1f° pitch=%.1f° [%s]" % [
		tick, move.x, move.y,
		rad_to_deg(view_yaw), rad_to_deg(view_pitch),
		", ".join(button_names()),
	]


func _to_string() -> String:
	return "DotPlayerIntent(%s)" % describe()
