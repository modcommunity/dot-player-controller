class_name DotPlayerIntent
extends RefCounted

## One tick of what a player wants, in a form every controller understands.
## Intent, not input and not movement: a sampler produces it, a controller turns it into motion,
## a replay or the wire hands it back. It survives a controller switch though state does not.

## Ground-plane intent, each component in [code]-1..1[/code].
## Not normalised on arrival: whether diagonals are faster is the movement model's decision.
var move: Vector2 = Vector2.ZERO

## Look change this tick, in radians (yaw in x, pitch in y).
## A delta because a mouse produces deltas; the absolute angles are [member view_yaw] and [member view_pitch].
var look: Vector2 = Vector2.ZERO

## Everything held this tick, as [enum Button] bits.
var buttons: int = 0

## Buttons that were not held last tick. Computed by [method diff_from].
## A jump is an edge and a sprint is a level; a stateless replay cannot compute edges itself.
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
## One list so a switch between controllers agrees what "use" means.
## Named [code]Btn[/code] because GDScript refuses to shadow the native [Button].
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
## Takes the raw bits so a controller need only keep an [code]int[/code] of history.
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


## The wire form. Angles are sent, deltas are not: the client says where it is looking and
## the server clamps and accepts, so a lost packet cannot leave them disagreeing.
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
