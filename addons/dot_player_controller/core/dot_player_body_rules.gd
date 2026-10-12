class_name DotPlayerBodyRules
extends RefCounted

## Whether players (people and bots alike) are solid to each other: the `mp_solidplayers`
## cvar, 1 by default.
##
## [codeblock]
## # wherever the game sets a player's mask, on every machine
## player.controller.set_collision_mask(world.body_rules.mask(physics.collision_mask(&"player"), physics.layer_mask(&"player")))
## [/codeblock]
##
## [b]Why solid by default.[/b] dot-physics' shooter layout leaves players out of each other's
## mask, which is the competitive genre's choice: nobody blocks a doorway. The first play
## test (2026-10-11) showed the other side of it in every game with bots: a bot walks into
## the player and its face fills the first-person screen, because nothing stops two bodies
## sharing one place. Solid bodies keep heads at least two radii apart; dot-core's
## [code]DotCameraFade[/code] hides whatever still gets inside the near plane.
##
## [b]It is part of the simulation, so it replicates.[/b] A client predicts its own player
## against the others' capsules where it draws them, which can disagree with the server by
## a few centimetres when two players lean on each other; the reconcile corrects it. A
## server that wants the genre's pass-through sets 0.
##
## Two bodies that start overlapping (a shared spawn) separate: a sweep ignores what it
## starts inside, and the controller's rest check blocks only motion further in.

signal changed

const CVAR_SOLID := "mp_solidplayers"

var solid: bool = true:
	set(value):
		if value == solid:
			return
		solid = value
		changed.emit()


## [param base] (a player's mask from the layout) with [param player_layers] added when
## players are solid, removed when they are not.
func mask(base: int, player_layers: int) -> int:
	return (base | player_layers) if solid else (base & ~player_layers)


func cvar_specs() -> Array[Dictionary]:
	return [
		{"name": CVAR_SOLID, "value": "1" if solid else "0", "min": 0.0, "max": 1.0,
			"description": "Players and bots: 1 solid to each other, 0 they pass through each other"},
	]


## Registers `mp_solidplayers` (see [method DotPlayerViewRules.bind_cvars] for the shape of
## [param add]). Pass dot-server's FLAG_REPLICATED: a client predicts its own player under it.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var made_cvar: Variant = add.call(cvar_name, String(spec["value"]), String(spec["description"]), flags)
		if not (made_cvar is Object) or made_cvar == null:
			continue
		var cv := made_cvar as Object
		if cv.has_method(&"with_range"):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar_changed.bind(cvar_name))
		if cv.has_method(&"get_string"):
			var _applied := set_cvar(cvar_name, String(cv.call(&"get_string")))
		made.append(cv)
	return made


## Follows a server's value through its link; false for an older shell's link.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	var held := String(source.call(&"replicated_cvar", CVAR_SOLID, ""))
	if held != "":
		var _applied := set_cvar(CVAR_SOLID, held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated_cvar):
		source.connect(&"replicated_cvar_changed", _on_replicated_cvar)
	return true


func set_cvar(cvar_name: String, value: String) -> bool:
	if cvar_name != CVAR_SOLID:
		return false
	var text := value.strip_edges()
	if not text.is_valid_int():
		return false
	solid = text.to_int() != 0
	return true


func _on_cvar_changed(_old: Variant, new_value: Variant, cvar_name: String) -> void:
	var _applied := set_cvar(cvar_name, str(new_value))


func _on_replicated_cvar(cvar_name: String, value: String) -> void:
	var _applied := set_cvar(cvar_name, value)


func describe() -> Dictionary:
	return {"solid": solid}


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["players: %s" % ("solid to each other" if solid else "pass through each other")])
