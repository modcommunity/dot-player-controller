class_name DotFpsTouchSampler
extends DotFpsSampler

## Produces commands from touch. For phones and for the browser on a tablet.
##
## [b]A sampler, not a control scheme.[/b] It turns finger positions into a
## [DotFpsCommand] and nothing else — no textures, no buttons, no layout. A game
## draws whatever it wants over the top and calls [method hold] for its own on-screen
## buttons, because a virtual stick that ships its own art is a virtual stick nobody
## can restyle.
##
## [codeblock]
## var sampler := DotFpsTouchSampler.new(tunables)
## controller.sampler = sampler
##
## # A jump button the game drew itself.
## $JumpButton.button_down.connect(
##     func(): sampler.hold(DotFpsCommand.BUTTON_JUMP, true))
## $JumpButton.button_up.connect(
##     func(): sampler.hold(DotFpsCommand.BUTTON_JUMP, false))
## [/codeblock]
##
## [b]The screen is split, not divided into fixed widgets.[/b] A finger landing on
## the movement side plants a stick wherever it touched rather than at a spot the
## player has to find; a finger on the look side drags the view. That is the layout
## every touch shooter converges on, and the reason is that a fixed stick position
## requires looking at your thumb.
##
## Nothing here reaches the simulation: this produces commands, and
## [DotFpsMotor] cannot tell where they came from. A replay of a touch session and a
## replay of a keyboard session are the same replay.

## Fraction of the screen width used for movement, from the left edge.
var move_zone: float = 0.5

## Radius in pixels at which the virtual stick reads as fully deflected.
##
## In pixels rather than a fraction of the screen because it corresponds to how far a
## thumb comfortably travels, which does not change with the display.
var stick_radius: float = 90.0

## Deflection below this fraction reads as no input.
##
## Larger than a physical stick's dead zone: a thumb resting on glass drifts, and a
## player who is not moving should not creep.
var dead_zone: float = 0.14

## Degrees of view rotation per pixel dragged.
var look_sensitivity: float = 0.16

## Tap the look side for shorter than this, moving less than
## [member tap_slop], to fire [member tap_button].
var tap_time: float = 0.25

## Pixels a tap may travel and still count as a tap.
var tap_slop: float = 18.0

## Button a tap on the look side presses for one command. 0 disables taps.
##
## Defaults to nothing: which action a tap should take is a game's decision, and
## guessing "fire" would be wrong for half of them.
var tap_button: int = 0

## Buttons held by the game's own on-screen controls. See [method hold].
var _held: int = 0

## Fired by a tap, consumed by the next [method sample].
var _tapped: int = 0

## Finger index driving movement, or -1.
var _move_finger: int = -1
var _move_origin: Vector2 = Vector2.ZERO
var _move_current: Vector2 = Vector2.ZERO

## Finger index driving the view, or -1.
var _look_finger: int = -1
var _look_last: Vector2 = Vector2.ZERO
var _look_start: Vector2 = Vector2.ZERO
var _look_travel: float = 0.0
var _look_elapsed: float = 0.0

var _screen_width: float = 1152.0


func _init(p_tunables: DotFpsTunables) -> void:
	super(p_tunables)


## Tells the sampler how wide the screen is, so the split lands in the right place.
##
## Call on resize. Defaults to Godot's project width, which is right until someone
## rotates a phone.
func set_screen_width(width: float) -> void:
	_screen_width = maxf(1.0, width)


## Holds or releases a button on the game's behalf. For on-screen controls.
func hold(button: int, pressed: bool) -> void:
	if pressed:
		_held |= button
	else:
		_held &= ~button


func handle_event(event: InputEvent) -> void:
	if suspended:
		return

	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)
	else:
		# A tablet with a keyboard, or a desktop build under test. Falling through
		# means one sampler covers both rather than the game swapping them.
		super.handle_event(event)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if event.position.x < _screen_width * move_zone:
			if _move_finger == -1:
				_move_finger = event.index
				# The stick is planted where the thumb landed. A fixed position
				# requires looking at your hand.
				_move_origin = event.position
				_move_current = event.position
		elif _look_finger == -1:
			_look_finger = event.index
			_look_last = event.position
			_look_start = event.position
			_look_travel = 0.0
			_look_elapsed = 0.0
		return

	if event.index == _move_finger:
		_move_finger = -1
	elif event.index == _look_finger:
		# A short, still touch is a tap rather than a drag of zero length.
		if (
			tap_button != 0
			and _look_elapsed <= tap_time
			and _look_travel <= tap_slop
		):
			_tapped |= tap_button

		_look_finger = -1


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index == _move_finger:
		_move_current = event.position
		return

	if event.index != _look_finger:
		return

	var moved := event.position - _look_last
	_look_last = event.position
	_look_travel += moved.length()

	# Routed through the inherited mouse accumulator so a drag and a mouse move go
	# through exactly one path — including the sensitivity, the inversion and the
	# pitch clamp, none of which should have a second implementation.
	_mouse_delta += moved * (look_sensitivity / maxf(0.0001, tunables.mouse_sensitivity))


func sample(delta: float = 0.0) -> DotFpsCommand:
	# Advances the tap timer on the sampling tick rather than in _process, so a
	# sampler that is not being driven does not accumulate time.
	if _look_finger != -1:
		_look_elapsed += delta

	var command := super.sample(delta)

	if suspended:
		return command

	command.move = _stick()
	command.buttons |= _held | _tapped

	# A tap lasts exactly one command. Holding it for longer would make a tap and a
	# hold indistinguishable to the simulation.
	_tapped = 0

	return command


## The virtual stick's deflection, as a move vector.
func _stick() -> Vector2:
	if _move_finger == -1:
		return Vector2.ZERO

	var offset := _move_current - _move_origin
	var deflection := offset.length() / stick_radius

	if deflection <= dead_zone:
		return Vector2.ZERO

	# Rescaled from the dead zone rather than clamped, so the first millimetre of
	# travel past it is a slow walk and not a jump to a quarter speed.
	var scaled := minf((deflection - dead_zone) / (1.0 - dead_zone), 1.0)
	var direction := offset.normalized()

	# Screen y grows downward; forward is up the screen.
	return Vector2(direction.x, -direction.y) * scaled


func describe() -> Dictionary:
	var out := super.describe()
	out["move_finger"] = _move_finger
	out["look_finger"] = _look_finger
	out["stick"] = "(%.2f, %.2f)" % [_stick().x, _stick().y]
	out["held"] = ", ".join(DotFpsCommand.button_names(_held))
	return out
