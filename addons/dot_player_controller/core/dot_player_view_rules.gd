class_name DotPlayerViewRules
extends RefCounted

## Whether a player sees through their own eyes or from behind, and what the server owner lets them choose: the `mp_forceview` cvar.
## 0 the player's choice, 1 first person only, 2 third person only. Presentation only: it replicates, each client
## applies it via [signal changed] and [method resolve]; the simulation and cameras are untouched here.

## Emitted when [member force_view] changes, from a cvar or by hand.
signal changed

const CVAR_FORCE := "mp_forceview"

## The views the view key cycles through, comma separated ("fp,tp"). A game may add its own ids with [method register_mode].
const CVAR_CYCLE := "mp_viewcycle"

## A first-person player's own body when they look down: [constant BODY_OFF], [constant BODY_LEGS] (the default) or [constant BODY_FULL].
const CVAR_BODY := "mp_fp_body"
## The older 0/1 name, still accepted by [method set_cvar] (1 is [constant BODY_LEGS]); no longer registered.
const CVAR_LEGS := "mp_firstperson_legs"

## Strength of the camera kick on a landing, 0 off to 2 double (client-side, default 1).
const CVAR_LANDING_KICK := "cl_landing_kick"

## The player's choice.
const ANY := 0
## First person only.
const FIRST_ONLY := 1
## Third person only.
const THIRD_ONLY := 2

## No body of your own in first person.
const BODY_OFF := 0
## Legs and feet, nothing from the belly up.
const BODY_LEGS := 1
## The whole body but the head and arms (the view model draws the arms).
const BODY_FULL := 2

## [constant ANY], [constant FIRST_ONLY] or [constant THIRD_ONLY].
var force_view: int = ANY:
	set(value):
		var clamped := clampi(value, ANY, THIRD_ONLY)
		if clamped == force_view:
			return
		force_view = clamped
		changed.emit()


## The cycle order of the view key. Ids not in [member known_modes] are skipped.
var view_cycle: PackedStringArray = PackedStringArray(["fp", "tp"]):
	set(value):
		if value == view_cycle:
			return
		view_cycle = value
		changed.emit()

## Every view this game can show: first and third person, plus what [method register_mode] added.
var known_modes: PackedStringArray = PackedStringArray(["fp", "tp"])

## How much of their own body a first-person player sees: `mp_fp_body`. The game reads it through
## [method own_body] where it draws the body; nothing here draws.
var first_person_body: int = BODY_LEGS:
	set(value):
		value = clampi(value, BODY_OFF, BODY_FULL)
		if value == first_person_body:
			return
		first_person_body = value
		changed.emit()

## Whether any of it shows; true sets [constant BODY_LEGS] when it was off.
var first_person_legs: bool:
	get:
		return first_person_body != BODY_OFF
	set(value):
		if value != first_person_legs:
			first_person_body = BODY_LEGS if value else BODY_OFF


## Multiplier for the camera's landing kick (`cl_landing_kick`); the game hands it to `DotFpsView.landing_strength`.
var landing_kick: float = 1.0:
	set(value):
		value = clampf(value, 0.0, 2.0)
		if is_equal_approx(value, landing_kick):
			return
		landing_kick = value
		changed.emit()


## Adds a view (a third-person variant, say) the cycle may name. It counts as third person for [member force_view].
func register_mode(id: StringName) -> void:
	if not known_modes.has(String(id)):
		known_modes.append(String(id))


## Whether [param id] is shown under [member force_view].
func allows_mode(id: StringName) -> bool:
	return allows_first() if id == &"fp" else allows_third()


## The view after [param current] in the cycle, skipping unknown and forbidden ones. [param current] itself when there is none or the view is forced.
func next_mode(current: StringName) -> StringName:
	if not may_toggle():
		return current
	var order := view_cycle
	var at := order.find(String(current))
	for step in range(1, order.size() + 1):
		var id := StringName(order[(at + step) % order.size()] if at >= 0 else order[step - 1])
		if id != current and known_modes.has(String(id)) and allows_mode(id):
			return id
	return current


## Whether the player may switch between the views.
func may_toggle() -> bool:
	return force_view == ANY


## Whether third person is allowed at all.
func allows_third() -> bool:
	return force_view != FIRST_ONLY


## Whether first person is allowed at all.
func allows_first() -> bool:
	return force_view != THIRD_ONLY


## The view a player gets when they want [param third_person]: their wish if allowed, the
## forced one if not.
func resolve(third_person: bool) -> bool:
	match force_view:
		FIRST_ONLY:
			return false
		THIRD_ONLY:
			return true
	return third_person


## The view after the player pressed the view key while in [param third_person]: the other
## one if they may switch, the forced one otherwise.
func toggled(third_person: bool) -> bool:
	return resolve(not third_person) if may_toggle() else resolve(third_person)


## Why the view key did nothing, for a HUD line; empty when it did something.
func refusal() -> String:
	match force_view:
		FIRST_ONLY:
			return "This server is first person only"
		THIRD_ONLY:
			return "This server is third person only"
	return ""


# Server cvars

func cvar_specs() -> Array[Dictionary]:
	return [
		{"name": CVAR_FORCE, "value": str(force_view), "min": float(ANY), "max": float(THIRD_ONLY),
			"description": "Players' view: 0 their choice (the view key toggles), 1 first person only, 2 third person only"},
		{"name": CVAR_CYCLE, "value": ",".join(view_cycle),
			"description": "The views the view key cycles through, comma separated: fp, tp, plus any the game adds"},
		{"name": CVAR_BODY, "value": str(first_person_body), "min": float(BODY_OFF), "max": float(BODY_FULL),
			"description": "A first-person player's own body when looking down: 0 none, 1 legs and feet, 2 the whole body but head and arms; a player's own setting overrides it"},
		{"name": CVAR_LANDING_KICK, "value": str(landing_kick), "min": 0.0, "max": 2.0,
			"description": "Camera kick on a landing: 0 none, 1 normal, 2 double"},
	]


## Registers these rules' cvars through [param add] (a server module's `add_cvar`, shaped
## `(name, default, description, flags) -> cvar`) and keeps these rules in step with it. Pass
## FLAG_REPLICATED. Duck-typed (dot-server is not a dependency); a value already held is read back.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var made_cvar: Variant = add.call(cvar_name, String(spec["value"]), String(spec["description"]), flags)
		if not (made_cvar is Object) or made_cvar == null:
			continue
		var cv := made_cvar as Object
		if spec.has("min") and cv.has_method(&"with_range"):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))
		if cv.has_signal(&"changed"):
			var on_change := _on_cvar_changed.bind(cvar_name)
			if not cv.is_connected(&"changed", on_change):
				cv.connect(&"changed", on_change)
		if cv.has_method(&"get_string"):
			var _applied := set_cvar(cvar_name, String(cv.call(&"get_string")))
		made.append(cv)
	return made


## Follows a server's value through [param source] (dot-server's `DotClientLink`, or
## anything with `replicated_cvar(name, fallback)` and a `replicated_cvar_changed(name,
## value)` signal). False when it cannot (an older shell's link); the rules keep their own.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	for cv in [CVAR_FORCE, CVAR_BODY, CVAR_CYCLE]:
		var held := String(source.call(&"replicated_cvar", cv, ""))
		if held != "":
			var _applied := set_cvar(cv, held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated_cvar):
		source.connect(&"replicated_cvar_changed", _on_replicated_cvar)
	return true


## Applies one cvar by name. False for another name or a value out of its range.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()
	if cvar_name == CVAR_BODY:
		if not text in ["0", "1", "2"]:
			return false
		first_person_body = text.to_int()
		return true
	if cvar_name == CVAR_LEGS:
		if text != "0" and text != "1":
			return false
		first_person_legs = text == "1"
		return true
	if cvar_name == CVAR_CYCLE:
		var ids := PackedStringArray()
		for part in text.split(",", false):
			ids.append(part.strip_edges())
		if ids.is_empty():
			return false
		view_cycle = ids
		return true
	if cvar_name == CVAR_LANDING_KICK:
		if not text.is_valid_float():
			return false
		landing_kick = text.to_float()
		return true
	if cvar_name != CVAR_FORCE:
		return false
	if not text.is_valid_int() or text.to_int() < ANY or text.to_int() > THIRD_ONLY:
		DotLog.debug("player.view", "mp_forceview refused a value", {"value": value})
		return false
	force_view = text.to_int()
	return true


func _on_cvar_changed(_old: Variant, new_value: Variant, cvar_name: String) -> void:
	var _applied := set_cvar(cvar_name, str(new_value))


func _on_replicated_cvar(cvar_name: String, value: String) -> void:
	var _applied := set_cvar(cvar_name, value)


## The body the local player sees of themselves in first person: their own [param choice]
## (a client setting, BODY_*) when they made one, else the server's [member first_person_body]; -1 is no choice.
func own_body(choice: int = -1) -> int:
	return clampi(choice, BODY_OFF, BODY_FULL) if choice >= 0 else first_person_body


## Whether the local player's own legs are drawn in first person: the server's [constant CVAR_BODY], or the game's own wish [param game_wants].
func shows_own_legs(game_wants: bool = false) -> bool:
	return first_person_legs or game_wants


func describe() -> Dictionary:
	return {"force_view": force_view, "may_toggle": may_toggle(), "first_person_body": first_person_body, "landing_kick": landing_kick}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"view: %s" % ["the player's choice", "first person only", "third person only"][force_view]
	])
