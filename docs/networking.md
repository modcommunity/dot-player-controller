# Wiring a controller to dot-net

## dot-net is never named

dot-net is **not** a dependency and is **not** imported. In GDScript that is not a preference: a script that mentions a `class_name` the project does not have fails to parse and takes everything referencing it down too (the same reason `DotTransportENet` reaches ENet through `ClassDB.instantiate`).

So `DotFpsCommand.write`/`read` take a `Variant` writer and call `DotNetWriter`'s methods by name, and `DotFpsNetSync` describes the replicated properties as strings a bridge resolves with `DotNetVar.Type[name]`. `movement_selftest.gd::FakeWire` checks that contract without dot-net present; a typo in a method name would otherwise show up only in a host game.

## The bridge a game writes

```gdscript
class_name PlayerInput extends DotNetInput

var command := DotFpsCommand.new()

func _write(w: DotNetWriter) -> void:
    command.write(w)

func _read(r: DotNetReader) -> void:
    command.read(r)

func _sanitise() -> void:
    # Not optional. Everything here came from a client.
    command.sanitise()

func _equals(other: DotNetInput) -> bool:
    return other is PlayerInput and command.equals((other as PlayerInput).command)
```

```gdscript
class_name PlayerNet extends DotNetBehaviour

@export var controller: DotFpsController

var net_position: Vector3
var net_velocity: Vector3
var net_yaw: float
var net_pitch: float
var net_crouch: float
var net_flags: int

func _register_net_vars() -> void:
    for spec in DotFpsNetSync.state_specs():
        var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
        if spec.bits > 0:
            declaration.bits(spec.bits)
        if spec.interpolated:
            declaration.interpolated()

func _net_ready() -> void:
    # SHARED authority: the owner predicts, the server corrects. The controller
    # simulates on both and only receives on everyone else's copy.
    controller.drive = (
        DotFpsController.Drive.EXTERNAL if identity.can_simulate()
        else DotFpsController.Drive.REMOTE
    )
    # Never from the client's own config, and never from the tunables the client
    # sent. This is the server's decision about this player.
    controller.allow_noclip = false

func _net_apply_input(input: DotNetInput, _tick: int) -> void:
    controller.apply_command((input as PlayerInput).command)

func _net_simulate(tick: int, delta: float) -> void:
    controller.simulate_tick(tick, delta)
    DotFpsNetSync.pull(controller.state, self)

func _net_state_applied(_tick: int) -> void:
    DotFpsNetSync.push(self, controller.state)
```

Three things that are easy to get wrong:

- **`_net_state_applied` must restore the whole state**, which is what `DotFpsNetSync.push` does. Reconciliation adopts the server's answer and replays every unacknowledged command on top; anything not restored makes the replay start somewhere the server never was.
- **`delta` must be the tick duration** on both sides, and `tick_rate` must match. It is an input to the simulation.
- **Compare `DotFpsTunables.fingerprint()` at connect time.** A client with different movement values diverges every tick and it looks exactly like packet loss. `DotFpsNetSync.differences()` names the property that differs.

## What rides in net_flags

Anything the next replayed tick reads must be in the snapshot, not only in `DotFpsState`. The slide time, the slide, launch and dash cooldowns and `previous_buttons` (which every press edge is detected against) are packed into `net_flags` by `DotFpsNetSync.pack_flags`, the timers in sixty-fourths of a second. Leaving a timer out means a snapshot from before a launch arrives, the rewind keeps the client's CURRENT cooldown and buttons, and the replay reaches the press with the cooldown running and the key already down: no launch, and metres between the two ends. Carrying `previous_buttons` closes the same hole for a buffered jump.

The wall run, the two wall-jump counters and the wall's heading are the last thirteen bits, which fills the word to 64 ([wall-movement.md](wall-movement.md#what-the-wire-carries)); the next field that has to travel needs a property of its own.

They are in the flags word rather than new properties because every game already declares `net_flags` and reads its width from `FLAG_BITS`. A new field that a replay reads goes there too, with a `movement_selftest` section that replays from a snapshot in the middle of the thing and a negative control that drops the field.

## The jump timers

`time_since_grounded`, `time_since_jump` and `time_since_jump_pressed` (coyote time, the jump buffer, the jump cooldown) did not travel, and against a wall that is metres of correction: a rewind to a tick where the server was in the air kept the client's grounded timer, so the replay coyote-jumped or wall-jumped where the server had not, wrong only in height. The flags word is full, so they ride in a property of their own, `net_timers` (42 bits, 1/7680 s, which is whole codes per tick from 20 to 128 Hz). It is opt-in: declare `var net_timers: int` and add `DotFpsNetSync.rewind_specs()` to the owner-only replicated properties; `pull` and `push` carry it when the property exists. A game that ships its own exact copy of the state (game-arena's `net_exact`) can carry the three floats there instead. `movement_selftest`'s "rewinding a wall-pinned hop" section is the check, with the negative control that drops it.

## Rendering between ticks

`render_state()` interpolates position and crouch between the last two ticks, so motion is smooth at a frame rate that is not the tick rate. It works for `Drive.LOCAL` and `Drive.EXTERNAL` (every networked owner is EXTERNAL); an earlier guard returned the raw tick state for anything but LOCAL, which made the blend unreachable in every networked game ([history.md](history.md#render_state-was-unreachable)). Two things it needs from a host, neither enforceable here:

- **Step the controller once per physics frame.** The derived alpha is `Engine.get_physics_interpolation_fraction()`, a fraction through a physics frame, and only a fraction through a tick while the engine's physics rate equals `tick_rate`. A host that runs two ticks on one physics frame and three on the next gets no benefit at all.
- **A connected client hands it the clock: `controller.set(&"render_clock", net.clock)`.** dot-net's clock stretches and shrinks its ticks while it settles on the server, so now and then a physics frame runs no tick and a later one two, and drawn at the engine's fraction the eye stood still on one frame and moved double on the next (game-arena: 4 to 8 frames in 5 s, 10 to 16 cm off at 60 Hz). With a `render_clock`, the derived alpha is its `render_alpha()`, which carries the slip and takes it back at a tenth of a tick per tick, from -1 to 2 for a moment: past 1 the drawing goes on along the last step, below 0 it is between the two ticks before (`_position_two_back`, reset by `teleport`). By name both ways: `set` on a shell's older controller is a no-op, and a clock without `render_alpha` leaves the engine's fraction in charge. Offline and on a server leave it null.
- **Do not call it for a `Drive.REMOTE` player.** Its position arrives already interpolated from the network and its `_previous_state` is never updated, so blending would drag it backwards every frame. `render_state` refuses that drive itself.

**The view is drawn from the sampler, once a frame, not from the state** (`DotFpsSampler.look_now()`, 2026-10-10). The state's yaw and pitch change only when a tick runs, and with the display faster than the tick rate some frames run none: at 144 Hz against 128 ticks one frame in nine drew the view where the last one left it and the next turned twice as far (game-g2gfast's `headless_feel`: 96 of 864 frames still, 96 doubled; 0 and 0 drawn from `look_now`), and at 240 Hz it is nearly every other frame. `look_now()` folds the mouse motion pending since the last `sample()` into the sampler's angles and returns them; the angles are cumulative, so the next command carries exactly what it would have and nothing the simulation does changes. The controller's own `_process` does it for `Drive.LOCAL`; a host that draws an EXTERNAL player itself calls it and draws what it returns (game-g2gfast's `G2GPlayer.view_now`).

**A press shorter than a tick is latched, not polled** (API 5, 2026-10-18). A mouse-wheel tick is a press and a release in one pair of events, so `Input.is_action_pressed` is false at every moment a tick can ask (measured: false in every frame; `is_action_just_pressed` true for one physics frame), and a wheel bound to jump never jumped. `handle_event` now latches the press of every button action until the next `sample()`, which puts it in that command's button bit and clears it: one tick, one press, and two ticks with a gap between are two press edges. What the prediction, the server and a replay see is the command, so the latch adds nothing they must restore. `sample()` also polls `is_action_just_pressed` once per frame, for a client that forwards only mouse motion, but that misses a frame on which no tick ran: **a client driving its own sampler forwards every event to `handle_event`**, as `DotFpsController` does.

Pass an explicit alpha to override the derivation; `fps_controller_selftest.gd` does, because the fraction's source is the host's business and the blend is this class's.

## Sprint stamina

`stamina`, `stamina_exhausted` and `stamina_delay_left` are in `DotFpsState` (so a replay reproduces them) and ride in an opt-in owner-only property like the jump timers: declare `var net_stamina: int` and replicate `DotFpsNetSync.stamina_specs()` (14 bits); `pull` and `push` carry it. It is not in `estimated_state_bits()`, so the 224-bit budget is unchanged. The carried load is `DotFpsMotor.load_fraction`, set by the game on both machines. Tunables and cvars: `stamina_*`, `sprint_load_*`, `sv_stamina*`, `sv_sprint*`. A game whose players each hold their own tunables binds `DotFpsSprintRules` (the `sv_sprint*`/`sv_stamina*` group): the server calls `bind_cvars` (REPLICATED), a client `follow_cvars`, both `apply_to` each player's tunables on `changed`. `sv_sprint_shoot 0` blocks the trigger while sprinting (default 1), and `sv_sprint_barrel` (default 1) sends a sprinting shot along the lowered barrel instead of the crosshair; `motion()` carries both as `sprint_blocks_fire` and `sprint_shot_follows_barrel` and zee-dot-weapons' rig turns the aim by the art's sprint carry. `sv_sprint_toggle` makes `DotFpsSampler` latch the sprint key (stopping clears it). `motion()` reports `sprinting` and `sprint_blocks_aim` for dot-weapon.
