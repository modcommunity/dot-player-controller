extends "res://examples/movement_selftest_more.gd"
## The wire format, net sync and configuration-fingerprint sections of the movement self-test. Split out of movement_selftest.gd for file size.


func _test_wire_round_trip() -> void:
	_section("wire format")

	var original := DotFpsCommand.new()
	original.move = Vector2(-0.5, 0.75)
	original.yaw = -134.0
	original.pitch = 42.0
	original.buttons = (
		DotFpsCommand.BUTTON_JUMP
		| DotFpsCommand.BUTTON_SPRINT
		| DotFpsCommand.BUTTON_USER_1
	)

	var wire := FakeWire.new()
	original.write(wire)

	var decoded := DotFpsCommand.new()
	decoded.read(wire)

	_check( wire.values.size() == 5, "the command writes every field", "wrote %d" % wire.values.size() )
	_check_near(decoded.move.x, -0.5, 0.01, "move.x survives quantisation")
	_check_near(decoded.move.y, 0.75, 0.01, "move.y survives quantisation")
	_check_near(decoded.yaw, -134.0, 0.2, "yaw survives quantisation")
	_check_near(decoded.pitch, 42.0, 0.5, "pitch survives quantisation")
	_check( decoded.buttons == original.buttons, "buttons survive exactly, including the game's own bits" )
	_check( DotFpsCommand.estimated_bits() < 64, "a command costs under 8 bytes", "%d bits" % DotFpsCommand.estimated_bits() )
	_done()


func _test_net_sync_round_trip() -> void:
	_section("net sync")

	var specs := DotFpsNetSync.state_specs()
	_check(specs.size() == 7, "seven properties replicate", "%d" % specs.size())

	for spec in specs:
		_check( spec.has("property") and spec.has("type") and spec.has("source"), "spec %s is complete" % str(spec.get("property", "?")) )

	# A stand-in for the DotNetBehaviour the host game writes. Only get/set are used,
	# which is exactly what DotFpsNetSync relies on.
	var carrier := Node.new()
	carrier.set_script(_carrier_script())

	var source := DotFpsState.new()
	source.position = Vector3(12.5, 3.25, -7.75)
	source.velocity = Vector3(1.5, -4.0, 0.25)
	source.yaw = 91.0
	source.pitch = -20.0
	source.crouch_fraction = 1.0
	source.crouch_held = true
	source.mode = DotFpsState.Mode.GROUND

	DotFpsNetSync.pull(source, carrier)

	var target := DotFpsState.new()
	DotFpsNetSync.push(carrier, target)

	_check( target.position.is_equal_approx(source.position), "position round-trips" )
	_check( target.velocity.is_equal_approx(source.velocity), "velocity round-trips" )
	_check(target.mode == source.mode, "the movement mode round-trips")
	_check(target.crouch_held == source.crouch_held, "crouch_held round-trips")
	_check_near( target.crouch_fraction, 1.0, 0.0001, "the crouch fraction round-trips" )

	# pull() keeps, per carrier script, which net_* it declares. Other shapes must still get what they have.
	var partial_script := GDScript.new()
	partial_script.source_code = "extends RefCounted\nvar net_position: Vector3\nvar net_yaw: float\n"
	partial_script.reload()
	var partial: Object = partial_script.new()
	DotFpsNetSync.pull(source, partial)
	DotFpsNetSync.pull(source, partial)
	_check(partial.get(&"net_position") == source.position and is_equal_approx(partial.get(&"net_yaw"), 91.0),
		"a carrier with only some of the seven still gets those")
	var dynamic := _DynamicCarrier.new()
	DotFpsNetSync.pull(source, dynamic)
	_check(not dynamic.store.has(&"net_timers2") and dynamic.store[&"net_position"] == source.position,
		"a _get carrier gets what it answers to")
	dynamic.store[&"net_timers2"] = -1
	DotFpsNetSync.pull(source, dynamic)
	_check(dynamic.store[&"net_timers2"] == DotFpsNetSync.pack_timers2(source), "and is asked again each pull")

	# push() reads the declared properties directly once it has seen the carrier's script.
	var again := DotFpsState.new()
	DotFpsNetSync.push(carrier, again)
	_check(again.position == source.position and again.mode == source.mode, "a second push (cached carrier) restores the same state")
	again.modifiers.append(Vector2i(1, -1))
	DotFpsNetSync.push(carrier, again)
	_check(again.modifiers.is_empty(), "a push of mask 0 empties a stale modifier list")
	carrier.set(&"net_modifiers", 5)
	DotFpsNetSync.push(carrier, again)
	_check(again.modifiers.size() == 2 and again.modifiers[0] == Vector2i(0, -1) and again.modifiers[1] == Vector2i(2, -1), "a push of a mask refills the list ascending")
	var pushed := DotFpsState.new()
	DotFpsNetSync.push(dynamic, pushed)
	DotFpsNetSync.push(dynamic, pushed)
	_check(pushed.position == source.position, "a _get carrier is pushed from what it answers to")

	_check_mode_packing()
	_check_timer_and_button_packing()
	_check_modifier_mask()

	_wire_size_checks(_wall_flag_checks())

	carrier.free()
	_done()


## Older encodings read as no wall run, and the whole state update stays small.
func _wire_size_checks(walled: DotFpsState) -> void:
	# An encoding from before the wall fields: the same word with the top thirteen bits clear.
	var older := DotFpsState.new()
	DotFpsNetSync.unpack_flags(
		older, DotFpsNetSync.pack_flags(walled) & ((1 << DotFpsNetSync.WALL_RUN_SHIFT) - 1)
	)
	_check(not older.is_wall_running() and not older.wall_run_spent and older.wall_jumps_in_air == 0
			and is_equal_approx(older.dash_cooldown_left, 2.5),
		"an encoding from before them reads as no run and no wall jumps, the rest intact")
	_check(DotFpsNetSync.FLAG_BITS == 64, "and the flags word is exactly full", "%d bits" % DotFpsNetSync.FLAG_BITS)

	# Under four bytes per player per snapshot for the flags; 28 bytes in all since the modifier mask grew to 48 bits.
	_check(
		DotFpsNetSync.estimated_state_bits() <= 224,
		"a full state update stays within 28 bytes",
		"%d bits" % DotFpsNetSync.estimated_state_bits()
	)


func _test_fingerprint() -> void:
	_section("configuration agreement")

	var a := _tunables()
	var b := _tunables()

	_check( a.fingerprint() == b.fingerprint(), "identical tunables have identical fingerprints" )

	b.mouse_sensitivity = 3.0
	b.invert_look_y = true

	_check( a.fingerprint() == b.fingerprint(), "look preferences do not change the fingerprint" )

	b.air_accelerate = 10.0

	_check( a.fingerprint() != b.fingerprint(), "a simulation value does change it" )
	_check( not DotFpsNetSync.agrees(a, b.fingerprint()), "and the peers are reported as disagreeing" )

	var diff := DotFpsNetSync.differences(a, b)
	var named := false
	for line in diff:
		if line.begins_with("air_accelerate"):
			named = true

	_check(named, "the mismatch names the property that differs")
	_done()


## The wall run and both wall-jump counters, the last thirteen bits of the word; returns the state whose flags were packed.
func _wall_flag_checks() -> DotFpsState:
	var walled := DotFpsState.new()
	walled.wall_run_time = 0.75
	walled.wall_jumps_in_air = 3
	walled.wall_jump_count = 2
	walled.wall_jump_heading = 5
	walled.dash_cooldown_left = 2.5
	walled.previous_buttons = 0xff
	var unwalled := DotFpsState.new()
	DotFpsNetSync.unpack_flags(unwalled, DotFpsNetSync.pack_flags(walled))
	_check(
		is_equal_approx(unwalled.wall_run_time, 0.75) and not unwalled.wall_run_spent
			and unwalled.wall_jumps_in_air == 3 and unwalled.wall_jump_count == 2
			and unwalled.wall_jump_heading == 5,
		"the wall run, both wall-jump counters and the wall's heading round-trip",
		", ".join(unwalled.describe_lines())
	)
	_check(is_equal_approx(unwalled.dash_cooldown_left, 2.5) and unwalled.previous_buttons == 0xff,
		"without disturbing the dash or the buttons below them")
	var longest := DotFpsState.new()
	longest.wall_run_time = DotFpsTunables.WALL_RUN_TIME_LIMIT
	var longest_back := DotFpsState.new()
	DotFpsNetSync.unpack_flags(longest_back, DotFpsNetSync.pack_flags(longest))
	_check_near(longest_back.wall_run_time, DotFpsTunables.WALL_RUN_TIME_LIMIT, 0.5 / 64.0,
		"the longest run the tunables allow fits the field")
	var spent := DotFpsState.new()
	spent.wall_run_spent = true
	var spent_back := DotFpsState.new()
	DotFpsNetSync.unpack_flags(spent_back, DotFpsNetSync.pack_flags(spent))
	_check(spent_back.wall_run_spent and not spent_back.is_wall_running(), "a spent run arrives spent and not running")
	var pairs_ok := true
	for total in range(4):
		for same in (range(1, total + 1) if total > 0 else [0]):
			var back := DotFpsNetSync.wall_jump_counts(DotFpsNetSync.wall_jump_code(total, same))
			pairs_ok = pairs_ok and back == Vector2i(total, same)
	_check(pairs_ok, "all seven (airborne, per-wall) wall-jump count pairs survive their shared field")
	return walled


## A net carrier whose net_* live in a dictionary, so what it has can change between pulls.
class _DynamicCarrier extends RefCounted:
	var store: Dictionary = {
		&"net_position": Vector3.ZERO, &"net_velocity": Vector3.ZERO, &"net_yaw": 0.0, &"net_pitch": 0.0,
		&"net_crouch": 0.0, &"net_flags": 0, &"net_modifiers": 0,
	}

	func _get(property: StringName) -> Variant:
		return store.get(property)

	func _set(property: StringName, value: Variant) -> bool:
		if not store.has(property):
			return false
		store[property] = value
		return true
