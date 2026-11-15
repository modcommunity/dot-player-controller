extends Node

## Counters, the print helpers and the space-query source audit of the controller self-test, split out of controller_selftest.gd for file size.

var _passed := 0
var _failed := 0
var _section_count := 0


## Files that query the physics space or move a body. With physics on its own thread these may only run inside the physics step, so a new one fails here until it is listed in docs/threading.md.
const QUERY_FILES: Array[String] = [
	"fp/motion/dot_fps_physics_body.gd",
	"fp/nodes/dot_fps_wall_probe.gd",
	"tp/nodes/dot_tps_controller.gd",
]
const QUERY_NEEDLES: Array[String] = ["direct_space_state", "space.intersect_", "space.cast_motion(", "space.get_rest_info(", "body.move_and_slide("]
const FRAME_ENTRY_NEEDLES: Array[String] = ["func _input(", "func _unhandled_input(", "call_deferred(", "await "]


func _audit_scripts(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_audit_scripts(dir.path_join(d), out)


## The text of one function, up to the next top-level func.
func _func_body(text: String, signature: String) -> String:
	var at := text.find(signature)
	if at < 0:
		return ""
	var end := text.find("\nfunc ", at + 1)
	return text.substr(at, end - at if end > 0 else -1)


func _test_space_query_audit() -> void:
	_section("space-query audit")
	var scripts: Array[String] = []
	_audit_scripts("res://addons/dot_player_controller", scripts)
	var found: Array[String] = []
	var frame_entry: Array[String] = []
	var in_process: Array[String] = []

	for path in scripts:
		var text := FileAccess.get_file_as_string(path)
		var queries := false
		for n in QUERY_NEEDLES:
			if text.contains(n):
				queries = true
		if not queries:
			continue
		var rel := path.trim_prefix("res://addons/dot_player_controller/")
		found.append(rel)
		for n in FRAME_ENTRY_NEEDLES:
			if text.contains(n):
				frame_entry.append("%s: %s" % [rel, n])
		# The controllers have a _process for the camera and view; it must not reach a query or a move.
		var frame := _func_body(text, "func _process(")
		for n in QUERY_NEEDLES + ["_apply_intent(", "simulate_tick(", "simulate("]:
			if frame.contains(n):
				in_process.append("%s: %s" % [rel, n])

	found.sort()
	var expected := QUERY_FILES.duplicate()
	expected.sort()
	_check(scripts.size() > 10, "the audit found the addon's scripts")
	_check(found == expected, "the files that query the space are exactly the documented ones (found %s)" % [found])
	_check(frame_entry.is_empty(), "no querying file has an input, deferred or awaited entry point %s" % [frame_entry])
	_check(in_process.is_empty(), "no _process in a querying file reaches a query or a tick %s" % [in_process])

	var doc := FileAccess.get_file_as_string("res://docs/threading.md")
	var missing: Array[String] = []
	for f in QUERY_FILES:
		if not doc.contains(f.get_file()):
			missing.append(f)
	_check(missing.is_empty(), "docs/threading.md names every one %s" % [missing])
	var tps := FileAccess.get_file_as_string("res://addons/dot_player_controller/tp/nodes/dot_tps_controller.gd")
	_check(tps.count("_apply_intent(") == 1, "DotTpsController._apply_intent has no caller of its own: only simulate reaches it")
	var fps := FileAccess.get_file_as_string("res://addons/dot_player_controller/fp/nodes/dot_fps_controller.gd")
	_check(_func_body(fps, "func _physics_process(").contains("simulate_tick("), "DotFpsController runs its own ticks from _physics_process")


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
