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

Anything the next replayed tick reads must be in the snapshot, not only in `DotFpsState`. The slide time, the slide, launch and dash cooldowns and `previous_buttons` (which every press edge is detected against) are packed into `net_flags` by `DotFpsNetSync.pack_flags`, the timers in sixty-fourths of a second. Leaving a timer out "like the jump timers" means a snapshot from before a launch arrives, the rewind keeps the client's CURRENT cooldown and buttons, and the replay reaches the press with the cooldown running and the key already down: no launch, and metres between the two ends. Carrying `previous_buttons` closes the same hole for a buffered jump.

They are in the flags word rather than new properties because every game already declares `net_flags` and reads its width from `FLAG_BITS`. A new field that a replay reads goes there too, with a `movement_selftest` section that replays from a snapshot in the middle of the thing and a negative control that drops the field.

## Rendering between ticks

`render_state()` interpolates position and crouch between the last two ticks, so motion is smooth at a frame rate that is not the tick rate. It works for `Drive.LOCAL` and `Drive.EXTERNAL` (every networked owner is EXTERNAL); an earlier guard returned the raw tick state for anything but LOCAL, which made the blend unreachable in every networked game ([history.md](history.md#render_state-was-unreachable)). Two things it needs from a host, neither enforceable here:

- **Step the controller once per physics frame.** The derived alpha is `Engine.get_physics_interpolation_fraction()`, a fraction through a physics frame, and only a fraction through a tick while the engine's physics rate equals `tick_rate`. A host that runs two ticks on one physics frame and three on the next gets no benefit at all.
- **Do not call it for a `Drive.REMOTE` player.** Its position arrives already interpolated from the network and its `_previous_state` is never updated, so blending would drag it backwards every frame. `render_state` refuses that drive itself.

Pass an explicit alpha to override the derivation; `fps_controller_selftest.gd` does, because the fraction's source is the host's business and the blend is this class's.
