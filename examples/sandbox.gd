extends Node

## A playable course for feeling the movement out. Not a test.
##
## [codeblock]
## godot --path . res://examples/sandbox.tscn
##
## # Exit on its own, so a sweep can open it:
## godot --headless --path . res://examples/sandbox.tscn -- --seconds 3
## [/codeblock]
##
## Stairs of increasing height, a surf ramp, and an open floor. WASD to move, space
## to jump, ctrl to crouch, shift to sprint, alt to walk, V to noclip, F1 to dump the
## controller's state to the console, escape to release the mouse.
##
## The controller is wired by nothing: [code]player.tscn[/code] sets no
## [DotNodeRef]s at all, and the view finds the camera and the controller finds the
## collider and the view by type. An inspector-configured project overrides any of
## them; this is what the default costs.

@onready var _controller: DotFpsController = $Player/Controller
@onready var _readout: Label = $UI/Container/Port/Readout


func _ready() -> void:
	_arm_exit_timer()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Noclip is off by default, and gated twice: the shared tunables and this
	# instance. A sandbox is the one place both are safe to open.
	_controller.allow_noclip = true
	_controller.tunables.can_noclip = true
	_controller.tunables.auto_hop = true

	_mark_surfaces()
	_register_movement_extras()

	_controller.landed.connect(_on_landed)
	_controller.surface_changed.connect(_on_surface_changed)

	# Off by default in the addon because head bob is divisive; on here so the
	# sandbox shows what the knob does.
	var view := _controller.view
	if view != null:
		view.bob_amount = 0.035

	print("dot-fps-controller sandbox")
	print(_controller.tunables.describe_summary())
	print("F1 state · F2 speed pad · V noclip · esc mouse")


## Marks the level's geometry with surface ids.
##
## Done in code here so the sandbox is one file to read. A real level sets the same
## metadata in the editor — the resolver does not care which, and both are scene data
## that a client and a server load identically, which is the requirement.
func _mark_surfaces() -> void:
	var ramp := get_node_or_null("World/Area_One/SurfRamp")
	if ramp != null:
		ramp.set_meta(&"dot_fps_surface", "ice")

	for child in $World/Area_One.get_children():
		if child.name.begins_with("Step"):
			child.set_meta(&"dot_fps_surface", "metal")


func _register_movement_extras() -> void:
	var ice := DotFpsSurface.make(&"ice")
	ice.friction_scale = 0.04
	ice.accelerate_scale = 0.2

	var metal := DotFpsSurface.make(&"metal")
	metal.material_tag = &"metal"

	var set := DotFpsSurfaceSet.new()
	set.add(ice).add(metal)

	# Applied after setup, so the motor is told directly rather than through the
	# export. A game wiring this in the inspector never has to do either.
	_controller.surfaces = set
	_controller.motor.surfaces = set
	_controller.motor.surface_resolver = _controller._resolve_surface_id

	var pad := DotFpsModifier.make(&"speed_pad")
	pad.max_speed_scale = 2.0
	pad.accelerate_scale = 1.5
	pad.duration_sec = 4.0
	_controller.motor.register_modifier(pad)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := (event as InputEventKey).keycode

		if key == KEY_ESCAPE:
			Input.mouse_mode = (
				Input.MOUSE_MODE_VISIBLE
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED
			)
		elif key == KEY_F1:
			for line in _controller.describe_lines():
				print(line)
		elif key == KEY_F2:
			_controller.add_modifier(&"speed_pad")
			print("speed pad applied")

	# Clicking back into the window recaptures the mouse, so the sandbox does not
	# need the escape key pressed twice to become playable again.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	if _readout == null:
		return

	var state := _controller.state

	# Horizontal speed, not total: the vertical component is gravity, and a
	# speedometer that counts it reads 20 m/s every time the player steps off a kerb.
	_readout.text = "%d fps   %.1f m/s   %s%s%s%s" % [
		Engine.get_frames_per_second(),
		state.horizontal_speed(),
		DotFpsState.mode_name(state.mode, _controller.motor).to_lower(),
		"  crouched" if state.is_crouched() else "",
		"  on %s" % state.surface if state.surface != &"" else "",
		"  boosted" if _controller.has_modifier(&"speed_pad") else "",
	]


func _on_landed(impact: float) -> void:
	if impact > 12.0:
		print("hard landing: %.1f m/s" % impact)


## Where a game would trigger footstep sounds: one edge per change, not a poll.
func _on_surface_changed(_from: StringName, to: StringName) -> void:
	if to != &"":
		print("stepped onto %s" % to)


## Runs for `--seconds N` and then exits 0. Zero, the default, means forever.
##
## This scene is interactive: it waits for a person, so a blanket "run every example"
## sweep stalls here and the scene is therefore opened by nothing. That is the state a
## load-time regression hides in — a renamed node or a moved resource breaks it and no
## suite in the repository notices. Bounding it is what makes it sweepable, the same
## way dot-auth's issuer example is.
##
## Not a self-test: reaching the timeout only proves the scene loaded and ran frames.
## It exits 0 for exactly that claim and no larger one.
func _arm_exit_timer() -> void:
	var argv := OS.get_cmdline_user_args()
	var at := argv.find("--seconds")
	if at < 0 or at + 1 >= argv.size():
		return

	var seconds := maxf(0.0, argv[at + 1].to_float())
	if seconds <= 0.0:
		return

	print("Exiting in %.1f seconds (--seconds)." % seconds)
	await get_tree().create_timer(seconds).timeout
	print("--seconds elapsed; exiting.")
	get_tree().quit(0)
