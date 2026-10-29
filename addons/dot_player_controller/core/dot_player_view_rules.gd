class_name DotPlayerViewRules
extends RefCounted

## Whether a player sees through their own eyes or from behind, and what the server owner
## lets them choose: the `mp_forceview` cvar every first-person game in the family binds.
##
## [codeblock]
## # server module
## world.view_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
## # client, once it has a link
## game.view_rules.follow_cvars(link)
## game.view_rules.changed.connect(_apply_view)
## # the view key
## third_person = game.view_rules.toggled(third_person)
## [/codeblock]
##
## [b]0 the player's choice, 1 first person only, 2 third person only[/b], the numbering of
## the spectator rule it sits beside (`mp_forcecamera`, where 0 is also "free"): an owner
## who knows one reads the other. Christian's words for it (2026-10-11): "first person and
## third person should be toggleable for server owners if they want to allow users to
## toggle them". The default is 0, the choice.
##
## [b]Presentation, decided by the server.[/b] The simulation does not know which view is on
## (a third-person camera sees round corners, which is why an owner may forbid it), so the
## rule replicates and every client applies it; nothing here touches a camera. A server
## that forces a view does not move a camera by itself either: a client that follows the
## cvar gets [signal changed] and puts its own camera where [method resolve] says.
##
## A solo game has no server: the game's console variable or its config sets
## [member force_view], and the default leaves the toggle on.

## Emitted when [member force_view] changes, from a cvar or by hand.
signal changed

const CVAR_FORCE := "mp_forceview"

## 1 draws a first-person player's own legs when they look down, 0 (the default) does not.
## The views the view key cycles through, comma separated ("fp,tp"). A game may add its own ids with [method register_mode].
const CVAR_CYCLE := "mp_viewcycle"

const CVAR_LEGS := "mp_firstperson_legs"

## Strength of the camera kick on a landing, 0 off to 2 double (client-side, default 1).
const CVAR_LANDING_KICK := "cl_landing_kick"

## The player's choice.
const ANY := 0
## First person only.
const FIRST_ONLY := 1
## Third person only.
const THIRD_ONLY := 2

## [constant ANY], [constant FIRST_ONLY] or [constant THIRD_ONLY].
var force_view: int = ANY:
	set(value):
		var clamped := clampi(value, ANY, THIRD_ONLY)
		if clamped == force_view:
			return
		force_view = clamped
		changed.emit()


## Whether a first-person player sees their own legs when looking down: `mp_firstperson_legs`.
## The game reads it where it draws the body; nothing here draws.
## The cycle order of the view key. Ids not in [member known_modes] are skipped.
var view_cycle: PackedStringArray = PackedStringArray(["fp", "tp"]):
	set(value):
		if value == view_cycle:
			return
		view_cycle = value
		changed.emit()

## Every view this game can show: first and third person, plus what [method register_mode] added.
var known_modes: PackedStringArray = PackedStringArray(["fp", "tp"])

var first_person_legs: bool = false:
	set(value):
		if value == first_person_legs:
			return
		first_person_legs = value
		changed.emit()


## Multiplier for the camera's landing kick (`cl_landing_kick`); the game hands it to `DotFpsView.landing_strength`.
var landing_kick: float = 1.0:
	set(value):
		value = clampf(value, 0.0, 2.0)
		if is_equal_approx(value, landing_kick):
			return
		landing_kick = value
		changed.emit()


## Whether the player may switch between the two.
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


# --- Server cvars ------------------------------------------------------------

func cvar_specs() -> Array[Dictionary]:
	return [
		{"name": CVAR_FORCE, "value": str(force_view), "min": float(ANY), "max": float(THIRD_ONLY),
			"description": "Players' view: 0 their choice (the view key toggles), 1 first person only, 2 third person only"},
		{"name": CVAR_CYCLE, "value": ",".join(view_cycle),
			"description": "The views the view key cycles through, comma separated: fp, tp, plus any the game adds"},
		{"name": CVAR_LEGS, "value": "1" if first_person_legs else "0", "min": 0.0, "max": 1.0,
			"description": "1 lets a first-person player see their own legs when they look down"},
		{"name": CVAR_LANDING_KICK, "value": str(landing_kick), "min": 0.0, "max": 2.0,
			"description": "Camera kick on a landing: 0 none, 1 normal, 2 double"},
	]


## Registers `mp_forceview` through [param add] (a server module's `add_cvar`, or anything
## shaped `(name, default, description, flags) -> cvar` with a `changed` signal and
## `get_string()`) and keeps these rules in step with it. Pass dot-server's
## FLAG_REPLICATED: the clients are the ones that place cameras. Duck-typed, because
## dot-server is not a dependency here; the value a cvar already holds (argv, a config file)
## is read back after registering.
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
	for cv in [CVAR_FORCE, CVAR_LEGS, CVAR_CYCLE]:
		var held := String(source.call(&"replicated_cvar", cv, ""))
		if held != "":
			var _applied := set_cvar(cv, held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated_cvar):
		source.connect(&"replicated_cvar_changed", _on_replicated_cvar)
	return true


## Applies one cvar by name. False for another name or a value that is not 0, 1 or 2.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()
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


## Whether the local player's own legs are drawn in first person: the server's [constant CVAR_LEGS], or the game's own setting [param game_wants]. Hand it to whatever draws the body (for example DotPlayerFirstPersonBody).
func shows_own_legs(game_wants: bool = false) -> bool:
	return first_person_legs or game_wants


func describe() -> Dictionary:
	return {"force_view": force_view, "may_toggle": may_toggle(), "first_person_legs": first_person_legs, "landing_kick": landing_kick}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"view: %s" % ["the player's choice", "first person only", "third person only"][force_view]
	])
