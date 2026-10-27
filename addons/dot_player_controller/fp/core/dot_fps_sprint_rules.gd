class_name DotFpsSprintRules
extends RefCounted

## The sprint and stamina cvars (`sv_sprint*`, `sv_stamina*`) as one live, replicated group for a game whose players each hold their own [DotFpsTunables].
##
## A server binds it ([method bind_cvars], REPLICATED), a client follows it ([method follow_cvars]), and either side calls [method apply_to] on every player's tunables when [signal changed] fires, so a prediction reads the numbers the server does.
##
## [codeblock]
## rules.apply_from(config_tunables)          # defaults from the game's config
## rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)  # server
## rules.follow_cvars(link)                   # client
## rules.changed.connect(func(): for t in all_tunables: rules.apply_to(t))
## [/codeblock]

## A sprint or stamina value changed.
signal changed

## The cvars this group owns.
const CVARS: PackedStringArray = [
	"sv_sprint", "sv_sprintspeed", "sv_stamina", "sv_stamina_drain", "sv_stamina_recover",
	"sv_stamina_resume", "sv_stamina_delay", "sv_sprint_loadspeed", "sv_sprint_loaddrain",
	"sv_sprint_noaim", "sv_sprint_toggle", "sv_unscope_hit", "sv_unscope_hittime",
]

## Holds the values; a [DotFpsTunables] already knows every unit and clamp.
var _held := DotFpsTunables.new()


func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec in _held.cvar_specs():
		if CVARS.has(String(spec["name"])):
			out.append(spec)
	return out


## False for a cvar this group does not own or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	if not CVARS.has(cvar_name):
		return false
	var before := _snapshot()
	if not _held.set_cvar(cvar_name, value):
		return false
	if _snapshot() != before:
		changed.emit()
	return true


## Takes the sprint and stamina members of [param source] as the current values.
func apply_from(source: DotFpsTunables) -> void:
	var before := _snapshot()
	for member in _members():
		_held.set(member, source.get(member))
	if _snapshot() != before:
		changed.emit()


## Copies the current values onto [param target].
func apply_to(target: DotFpsTunables) -> void:
	for member in _members():
		target.set(member, _held.get(member))


## Registers every cvar through [param add] (`(name, default, description, flags) -> cvar`) and applies what a cfg or argv already set.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for spec in cvar_specs():
		var cvar_name := String(spec["name"])
		var cv: Variant = add.call(cvar_name, str(spec["value"]), String(spec["description"]), flags)
		if not (cv is Object):
			continue
		var obj := cv as Object
		if obj.has_signal(&"changed"):
			obj.connect(&"changed", func(_old: Variant, new_value: Variant) -> void: set_cvar(cvar_name, str(new_value)))
		if obj.has_method(&"get_string"):
			var held := String(obj.call(&"get_string"))
			if held != str(spec["value"]):
				var _applied := set_cvar(cvar_name, held)
		made.append(obj)
	return made


## Follows a server's values through a link with `replicated_cvar` / `replicated_cvar_changed`.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	for cvar_name in CVARS:
		var held := String(source.call(&"replicated_cvar", cvar_name, ""))
		if held != "":
			var _applied := set_cvar(cvar_name, held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated):
		source.connect(&"replicated_cvar_changed", _on_replicated)
	return true


func describe() -> Dictionary:
	var out := {}
	for member in _members():
		out[String(member)] = _held.get(member)
	return out


func _members() -> Array[StringName]:
	var out: Array[StringName] = []
	for spec in cvar_specs():
		out.append(StringName(spec["member"]))
	return out


func _snapshot() -> Array:
	var out: Array = []
	for member in _members():
		out.append(_held.get(member))
	return out


func _on_replicated(cvar_name: String, value: String) -> void:
	var _applied := set_cvar(cvar_name, value)
