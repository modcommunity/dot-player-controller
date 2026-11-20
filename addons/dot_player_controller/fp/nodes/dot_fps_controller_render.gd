@tool
extends "dot_fps_controller_signals.gd"

## How [DotFpsController] is drawn between ticks, kept apart so the controller file stays small.


## The position of the tick before this one: [code]render_state(0.0).position[/code] without the copied state, for a
## server that keeps a trail of positions every tick (API 25). [constant Drive.REMOTE], or no [member tick_rate], is [member state]'s.
func previous_position() -> Vector3:
	if drive == Drive.REMOTE or tick_rate <= 0:
		return state.position
	return _previous_state.position


## The state to render this frame, interpolated between the last two ticks. Rendering the tick state directly quantises motion to the tick rate. Purely cosmetic: the returned state is a copy and nothing writes it back. [param alpha] is how far this frame sits between the last two ticks; left at -1 it is derived from who drives:
## - [constant Drive.LOCAL] ticks from its own accumulator, so that is the fraction. - [constant Drive.EXTERNAL] is stepped once per physics frame by its host, so the engine's interpolation fraction is it, but only while the physics rate equals the tick rate: at 60 against a 128-tick server the drawn position moved 74 mm on six frames in seven and 112 mm on the seventh. Put the engine on the server's rate ([method AirdriftNetBridge._adopt_tick_rate]). With a [member render_clock] set, its [code]render_alpha()[/code] replaces the fraction and runs from -1 to 2 after a frame with no tick or two. - [constant Drive.REMOTE] is not simulated here; its position arrives already interpolated by [DotNetInterpolator], and blending toward a [member _previous_state] nothing updates would drag it backwards.
func render_state(alpha: float = -1.0) -> DotFpsState:
	if drive == Drive.REMOTE or tick_rate <= 0:
		return state

	var beyond := 0.0
	if alpha < 0.0:
		if drive == Drive.LOCAL:
			alpha = clampf(_accumulator / (1.0 / float(tick_rate)), 0.0, 1.0)
		elif (
			render_clock != null and is_instance_valid(render_clock)
			and render_clock.has_method(&"render_alpha")
		):
			# By name: the clock is GameSpice Net's, which this addon does not depend on, and
			# one older than `render_alpha` leaves the engine's fraction in charge.
			var from_clock := float(render_clock.call(&"render_alpha"))
			alpha = clampf(from_clock, 0.0, 1.0)
			beyond = clampf(from_clock, -1.0, 2.0) - alpha
		else:
			alpha = Engine.get_physics_interpolation_fraction()

	alpha = clampf(alpha, 0.0, 1.0)

	var blended := state.duplicate_state()
	blended.position = _previous_state.position.lerp(state.position, alpha)
	if beyond > 0.0:
		# Later than the newest tick (a slip that ran a physics frame with no tick): on
		# along the last tick's step, as the drawing would have been had the tick run.
		blended.position += (state.position - _previous_state.position) * beyond
	elif beyond < 0.0 and _position_two_back.is_finite():
		# Earlier than the previous tick (a physics frame that ran two): between the two
		# before. Clamped to the previous tick when there is no third, as before.
		blended.position = _position_two_back.lerp(_previous_state.position, 1.0 + beyond)
	blended.crouch_fraction = lerpf(
		_previous_state.crouch_fraction, state.crouch_fraction, alpha
	)

	# View angles are not interpolated: blending toward the previous tick adds a frame of latency to aiming.
	# They are the last tick's, a frame behind the mouse on a frame with no tick; a renderer draws `DotFpsSampler.look_now()` over them for its own player.
	return blended


## [code]render_state(alpha).position[/code] without copying the state (API 32): for a reader that needs only where the
## body is drawn, such as a killcam recording every body. Same alpha rules and the same answer as [method render_state].
func render_position(alpha: float = -1.0) -> Vector3:
	if drive == Drive.REMOTE or tick_rate <= 0:
		return state.position
	var beyond := 0.0
	if alpha < 0.0:
		if drive == Drive.LOCAL:
			alpha = _accumulator / (1.0 / float(tick_rate))
		elif render_clock != null and is_instance_valid(render_clock) and render_clock.has_method(&"render_alpha"):
			var from_clock := float(render_clock.call(&"render_alpha"))
			alpha = clampf(from_clock, 0.0, 1.0)
			beyond = clampf(from_clock, -1.0, 2.0) - alpha
		else:
			alpha = Engine.get_physics_interpolation_fraction()
	alpha = clampf(alpha, 0.0, 1.0)
	if beyond > 0.0:
		return _previous_state.position.lerp(state.position, alpha) + (state.position - _previous_state.position) * beyond
	if beyond < 0.0 and _position_two_back.is_finite():
		return _position_two_back.lerp(_previous_state.position, 1.0 + beyond)
	return _previous_state.position.lerp(state.position, alpha)
