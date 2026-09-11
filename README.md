This is the **player controller** asset for TMC's **Dot** collection. It is everything that drives a player: the part every controller has in common, a first-person movement model written to be predicted and reconciled, and a third-person one with the camera rig that makes third person work.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Three halves

```
addons/dot_player_controller/
  core/   nodes/    the contract: intent, look, the abstract base, the switch
  fp/               first-person movement — the one that was dot-fps-controller
  tp/               third-person movement, and the camera rig
```

The base moves nothing. `fp/` and `tp/` are the two shipped implementations, and a vehicle, a ladder, a spectator camera and a cutscene rail are the same shape.

**`fp/` was `dot-fps-controller`.** Every `class_name` is unchanged — `DotFpsController`, `DotFpsMotor`, `DotFpsTunables` and the rest — because `class_name` is global in Godot and renaming one is a breaking change for every project that has it installed, to gain nothing: `DotFps` still says exactly what it is. Its documentation is kept whole, further down and in `CLAUDE.md`.

A game that wants only one half can delete the other folder; the plugin skips a node type whose script is not there, so a trimmed install is a supported shape rather than a broken one.

## Install

Copy `addons/dot_player_controller/`, `addons/dot_player/` and `addons/dot_core/` into your project and enable all three in *Project → Project Settings → Plugins*.

`addons/dot_net/` is optional and is only used by the first-person half's `DotFpsNetSync`, which does not import it.

Requires Godot 4.7 or newer.

## What the base provides

The three things every controller needs and nobody wants to write twice.

## 1. Intent, which is not input and not movement

```gdscript
var intent := DotPlayerIntent.make(Vector2(0, 1), DotPlayerIntent.Btn.JUMP, tick)
intent.view_yaw = look.yaw
controller.drive(intent, delta)
```

It says *"forward, holding jump, looking here"*. It does not say which key that was, and it does not say what happens. A sampler makes them, a controller consumes them, a replay hands the same ones back, and a server receives them over a wire and never sees a keyboard.

`diff_from(previous_buttons)` fills in `pressed` and `released`, because **a jump is an edge and a sprint is a level** — and a controller computing edges itself would need the previous command, which a stateless replay does not have.

The **look delta is not on the wire**. A server that integrated a client's deltas would be reconstructing an angle the client already knows, one lost packet away from disagreeing about it forever. The client sends where it is looking; the server clamps and accepts.

## 2. `DotPlayerLook`, the forty lines everybody rewrites

```gdscript
look.apply(mouse_delta)          # sensitivity, inversion, zoom
camera.basis = look.basis()      # yaw then pitch
body.basis   = look.body_basis() # yaw only
velocity     = look.move_direction(intent.move) * speed
```

Three mistakes it exists to stop:

1. **Pitch clamps; yaw wraps.** Clamping yaw stops the player turning round. Wrapping pitch lets them look through their own feet and come out the top.
2. **The wrap must be bounded.** A yaw that only accumulates is a float losing precision over a long session, and the symptom is a mouse that gets less accurate the longer the server has been up.
3. **Sensitivity multiplies the delta, not the angle.** Applied to the angle it snaps the view every time the setting changes.

`forward_flat()` is separate from `forward()` so a player looking at the floor still walks forwards rather than into it. `move_direction` is here rather than in each controller specifically so the two cannot disagree about which component is X.

## 3. The switch, and the handover

```
DotPlayer
  DotPlayerControllerSwitch    default_controller = &"fp"
  DotFpsController             controller_id = &"fp"
  DotTpsController             controller_id = &"tp"
```

Without it, two controllers both read input and both write the body's transform, and which one wins depends on child order — a result nobody will ever guess from the symptom.

**The handover carries exactly four things: position, velocity, yaw and pitch.** Not the controller's state, and that is deliberate: a first-person motor's state and a third-person motor's have nothing in common, and converting one into the other would be a lie. Getting out of a vehicle should not restore the air-strafe you were in the middle of.

It happens **after** the incoming controller's `_on_activated`, because that is where a real controller resets its motor — hand the state over first and the reset wipes it.

`set_input_enabled(false)` freezes *every* controller, not just the active one: a player who switches view while frozen must stay frozen.

## A frozen controller still ticks

`drive()` with `input_enabled = false` applies an **empty** intent rather than skipping the tick. A frozen player keeps falling, keeps sliding to a stop and keeps being pushed by the world; a controller that skipped would leave them hanging in mid-air, which is the classic warm-up-freeze bug.

## The first-person half

**The simulation is a pure function of (state, command, delta, world)**, which is what lets a client apply input immediately and a server correct it a round trip later without the two disagreeing. It is a property that has to be designed in: nothing about GDScript enforces it, and nothing about a single-player game reveals when it is broken.

`examples/movement_selftest.tscn` runs 400 mixed commands, snapshots at tick 250, replays the last 150 from the snapshot, and requires the same endpoint — the shape of reconciliation — with a negative control, because a test that cannot fail is not a test. `examples/surf_selftest.tscn` is the ramp behaviour on its own.

It does its own collide-and-slide, deliberately: bunny-hopping and surfing are consequences of exactly how the sliding works.

### What is in the box

| | |
| --- | --- |
| `DotFpsCommand` | One tick of player intent. Bit-packed to under 8 bytes. |
| `DotFpsState` | Everything the simulation carries between ticks. Capture, restore, compare. |
| `DotFpsTunables` | Every movement number, layered: exported defaults < JSON < `DOT_FPS_*` < `--fps-*`. |
| `DotFpsMotor` | The simulation. Deterministic, no engine globals, no input reads. |
| `DotFpsBody` | The collision queries the motor needs. `DotFpsPhysicsBody` for real geometry, `DotFpsFlatBody` for tests. |
| `DotFpsController` | The node. Drives the motor, writes to the scene, resizes the collider. |
| `DotFpsView` | Camera, pitch, crouch height, speed FOV. Cosmetic only, runs at frame rate. |
| `DotFpsSampler` | Devices to commands. The only thing that reads the keyboard. |
| `DotFpsNetSync` | What to replicate and how, without importing dot-net. |
| `DotFpsSurface` | How one kind of ground behaves — ice, mud, a conveyor. Multipliers on the tunables. |
| `DotFpsModifier` | A temporary change: a speed pad, a slow field, a stun, a launcher. |
| `DotFpsMoveMode` | A movement mode your game adds — ladder, water, grapple — without forking the motor. |
| `DotFpsTouchSampler` | Commands from touch, for phones and the browser. No art, no layout. |

### Movement

The model is the classic one, so the behaviours players expect from it are all present and
all fall out of the same acceleration function rather than being special-cased:

- **Air-strafing and bunny-hopping.** Airborne acceleration is capped at
  `max_air_wish_speed` (1 m/s by default) measured as a projection onto the wish
  direction, so turning while holding strafe adds speed perpendicular to motion. Set
  it to 0 for a game that does not want this.
- **Surfing.** Steep slopes are walls; velocity slides along them and gravity does
  the rest.
- **Stair stepping** up to `step_height`, refused when there is nothing to stand on
  behind the step.
- **Crouching** that resizes the collider, keeps the feet planted on the ground and
  the head planted in mid-air (crouch-jumping), and refuses to stand up under a low
  ceiling rather than pushing through it.
- **Coyote time** and **jump buffering**, both configurable, both off by setting them
  to zero.
- **Ground snapping** so walking down slopes and stairs does not give you air physics
  every other tick.

Everything above is a value in `DotFpsTunables`, which a dedicated server can set from
a JSON file, the environment or the command line without a rebuild.

### Extending it

Four hooks, and none of them need a fork:

- **Surfaces.** Mark a collider `dot_fps_surface = "ice"` in the inspector (or put it
  in a `surface_ice` group) and give the controller a `DotFpsSurfaceSet`. Ice, mud,
  conveyors, unstandable rails.
- **Modifiers.** `DotFpsModifier` scales speed, acceleration, gravity, friction and
  jumping for a while, or denies moving and jumping outright, or applies an impulse.
  Speed pads, slow fields, stuns, launchers.
- **Movement modes.** `DotFpsMoveMode` gives a game a whole new way to move — a
  ladder, water, a grapple — using the motor's own collision and acceleration.
- **Sampling.** `DotFpsSampler` for keyboard, mouse and gamepad;
  `DotFpsTouchSampler` for touch; or build a `DotFpsCommand` yourself for a bot or a
  demo playback.

All three of the first group are part of the simulation, so all three replicate and
survive a prediction replay. `CLAUDE.md` explains what that constrained.

### Networking

The controller does not depend on dot-net and does not import it. What it gives you
instead is the hard part: a simulation that reproduces itself exactly when replayed,
a command that packs to 49 bits, a state object with nothing left outside it, and
`DotFpsNetSync`, which says what to replicate and at what precision.

Joining the two is about thirty lines in your game. `CLAUDE.md` has the whole thing.

`DotFpsTunables.fingerprint()` is worth wiring up on day one: a client whose movement
config differs from the server's diverges every tick, and the symptom is
indistinguishable from packet loss.

### Credits

- [Christian Deacon](https://github.com/gamemann)
- [BleyChimera](https://github.com/BleyChimera) — the original controller this one
  replaces started from their code.
- [Prototype textures](https://www.kenney.nl/assets/prototype-textures) by Kenney.

MIT licensed.

## The third-person half

An orbit rig on a spring arm, a shoulder offset it can swap, camera-relative movement, turn-to-face and strafe-lock, coyote time and a jump buffer.

`DotTpsMotor.step` is pure, but it does **not** do its own collide-and-slide — `move_and_slide` resolves the collisions. So it is deterministic *given the same collision results*: enough for a replay on one machine, not enough for bit-exact rewind against a server that resolved them itself. A third-person shooter that needs the latter drives the first-person motor and uses `tp/` for the camera alone. That is a real limitation, written down rather than discovered.

## Writing a controller

Five methods:

```gdscript
class MyController extends DotPlayerController:
    func _apply_intent(intent: DotPlayerIntent, delta: float) -> void: ...
    func _read_transform() -> Transform3D: ...
    func _write_transform(to: Transform3D) -> void: ...
    func _read_velocity() -> Vector3: ...
    func _write_velocity(v: Vector3) -> void: ...
```

The base's defaults already read and write a `CharacterBody3D` *or* a `CharacterBody2D` found through the player, so a simple controller can skip four of them. `examples/controller_selftest.gd` has a worked one.

## Licence

MIT. See [LICENSE](LICENSE).
