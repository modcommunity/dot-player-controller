class_name DotFpsCvars
extends RefCounted

## Binds the movement cvars (`sv_gravity`, `sv_airaccelerate`, `sv_waterfriction`, `sv_ladder_dampen` and the rest) of any number of targets to a console, so a cvar change reaches them.
##
## A target is anything with `cvar_specs()` and `set_cvar(name, value)`: [DotFpsTunables], [DotFpsSwimMode], [DotFpsLadderMode]. Layered config comes for free: a cvar set by a cfg file or the command line before [method bind_cvars] is read back and applied, and a per-map override (dot-game's `DotGameMapConfig`, which sets and restores console cvars) reaches the targets by the same `changed` signal as an operator typing it.
##
## [codeblock]
## var movement := DotFpsCvars.new().add_target(tunables).add_target(swim).add_target(ladder)
## movement.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
## movement.applied.connect(func(_name): rebuild_players())
## map_config = DotGameMapConfig.for_console("my-game", console, movement.map_config_keys())
## [/codeblock]

## A cvar was applied to at least one target.
signal applied(cvar_name: String, value: String)

var targets: Array[Object] = []

## Cvar name -> the default text it was registered with; a read-back equal to it is not re-applied, so a profile set by a cfg is not undone by the plain defaults after it.
var _defaults: Dictionary = {}


## Adds a target; chainable. Null and objects without the two methods are ignored.
func add_target(target: Object) -> DotFpsCvars:
	if target != null and target.has_method(&"cvar_specs") and target.has_method(&"set_cvar"):
		targets.append(target)
	return self


## Every target's specs, the first target winning a name two of them share; the profile cvar stays first.
func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for target in targets:
		for spec: Dictionary in target.call(&"cvar_specs"):
			if not seen.has(spec["name"]):
				seen[spec["name"]] = true
				out.append(spec)
	return out


## Applies [param value] to every target that knows [param cvar_name]. False when none does.
func set_cvar(cvar_name: String, value: String) -> bool:
	var any := false
	for target in targets:
		if bool(target.call(&"set_cvar", cvar_name, value)):
			any = true
	if any:
		applied.emit(cvar_name, value)
	return any


## Registers every spec through [param add] (a server module's `add_cvar`, shaped `(name, default, description, flags) -> cvar` with a `changed` signal and `get_string()`), then applies what the cvars already hold from a cfg or argv. Returns the cvars made.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var default_text := str(spec["value"])
		_defaults[cvar_name] = default_text
		var made_cvar: Variant = add.call(cvar_name, default_text, String(spec["description"]), flags)
		if not (made_cvar is Object) or made_cvar == null:
			continue
		var cv := made_cvar as Object
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar_changed.bind(cvar_name))
		if cv.has_method(&"get_string"):
			var held := String(cv.call(&"get_string"))
			if held != default_text and not _same_number(held, default_text):
				var _ok := set_cvar(cvar_name, held)
		made.append(cv)
	return made


## The whitelist for `DotGameMapConfig` (`key -> {type, min, max}`): every numeric cvar of the targets except the profile (it replaces members a map did not mean to touch), minus [param exclude]. Merge a game's own limits over it with [param limits] (`name -> {min, max}`).
func map_config_keys(exclude: PackedStringArray = PackedStringArray(), limits: Dictionary = {}) -> Dictionary:
	var out := {}
	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		if cvar_name == DotFpsTunables.CVAR_PROFILE or exclude.has(cvar_name):
			continue
		var entry := {"type": "bool" if _is_bool(spec) else "float"}
		if entry["type"] == "float":
			entry["min"] = 0.0
		if limits.has(cvar_name):
			entry.merge(limits[cvar_name], true)
		out[cvar_name] = entry
	return out


func describe() -> Dictionary:
	return {"targets": targets.size(), "cvars": cvar_specs().size()}


func _is_bool(spec: Dictionary) -> bool:
	for target in targets:
		if spec.has("member") and target.get(String(spec["member"])) is bool:
			return true
	return false


func _same_number(a: String, b: String) -> bool:
	return a.is_valid_float() and b.is_valid_float() and is_equal_approx(a.to_float(), b.to_float())


func _on_cvar_changed(_old: Variant, new_value: Variant, cvar_name: String) -> void:
	var _ok := set_cvar(cvar_name, str(new_value))
