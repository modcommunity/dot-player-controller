Everything that drives a player: a shared base, a first-person movement model built for prediction and reconciliation, and a third-person model with a camera rig.

```
addons/dot_player_controller/
  core/, nodes/   intent, look, the abstract base, the switch
  fp/             first-person movement (formerly dot-fps-controller; class names unchanged)
  tp/             third-person movement and camera rig
```

You can delete `fp/` or `tp/` if you only need one. A vehicle, ladder or spectator camera can be written as another controller.

## Install

1. Copy `addons/dot_player_controller/`, `addons/dot_player/` and `addons/dot_core/` into your project.
2. Enable all three in *Project > Project Settings > Plugins*.

`addons/dot_net/` is optional and only used by `DotFpsNetSync`.

Needs Godot 4.7 or newer.

## The shared base

**Intent.** `DotPlayerIntent` says "forward, holding jump, looking here". It is not key presses and not movement, so a sampler, a replay or a server can all produce it.

```gdscript
var intent := DotPlayerIntent.make(Vector2(0, 1), DotPlayerIntent.Btn.JUMP, tick)
intent.view_yaw = look.yaw
controller.simulate(intent, delta)
```

`diff_from(previous_buttons)` fills in `pressed` and `released`. The look delta is not sent over the network; the client sends where it looks and the server clamps it.

**Look.** `DotPlayerLook` handles mouse look: pitch clamps, yaw wraps, sensitivity scales the delta.

```gdscript
look.apply(mouse_delta)
camera.basis = look.basis()
body.basis   = look.body_basis()
velocity     = look.move_direction(intent.move) * speed
```

**Switch.** `DotPlayerControllerSwitch` makes exactly one controller active and hands over position, velocity, yaw and pitch, not controller state.

```
DotPlayer
  DotPlayerControllerSwitch    default_controller = &"fp"
  DotFpsController             controller_id = &"fp"
  DotTpsController             controller_id = &"tp"
```

`set_input_enabled(false)` freezes every controller but still ticks with an empty intent, so a frozen player keeps falling.

## First-person movement

The simulation is a pure function of (state, command, delta, world), so a client can predict and a server can correct without disagreeing. `examples/movement_selftest.tscn` replays 400 commands from a snapshot and checks the same end state; `examples/surf_selftest.tscn` tests ramps. It does its own collide-and-slide, because bunny-hopping and surfing depend on the exact sliding.

| Class | Purpose |
| --- | --- |
| `DotFpsCommand` | One tick of player intent, packed to 49 bits. |
| `DotFpsState` | Everything carried between ticks. |
| `DotFpsTunables` | Every movement number, layered: defaults, JSON, `DOT_FPS_*` environment, `--fps-*` command line. Also `jump_reach(rise)`, `jump_airtime(rise)`, `climb_limit()` for level designers. |
| `DotFpsMotor` | The deterministic simulation. |
| `DotFpsBody` | Collision queries: `DotFpsPhysicsBody` for real geometry, `DotFpsFlatBody` for tests. |
| `DotFpsController` | The node. Drives the motor, writes to the scene, resizes the collider. |
| `DotFpsView` | Camera, pitch, crouch height, speed FOV. Cosmetic, runs per frame. |
| `DotFpsViewMotion` | Landing dip, strafe and slide roll, wall-run lean as plain numbers, for games with their own camera. |
| `DotFpsSampler` | Keyboard, mouse and gamepad to commands. |
| `DotFpsTouchSampler` | Touch to commands. |
| `DotFpsNetSync` | What to replicate and how, without importing dot-net. |
| `DotFpsSurface` | Ground behaviour such as ice, mud or a conveyor. |
| `DotFpsModifier` | A temporary change such as a speed pad, slow field, stun or launcher. |
| `DotFpsMoveMode` | A movement mode your game adds, such as a ladder, water or grapple. |

### Movement features

The defaults are a classic competitive-shooter profile (see [docs/motor.md](docs/motor.md)); `DotFpsTunables.with_profile("legacy")` gives the older set. Features marked "off" are enabled with tunables.

| Feature | Notes |
| --- | --- |
| Air-strafing and bunny-hopping | Air acceleration is capped by `max_air_wish_speed`; set it to 0 to disable. |
| Surfing | Steep slopes slide the player. |
| Stair stepping | Up to `step_height`. |
| Crouching | Resizes the collider and refuses to stand under a low ceiling. |
| Coyote time, jump buffering | Set to 0 to turn off. |
| Ground snapping | Walking down slopes and stairs stays grounded. |
| Sliding (off) | Crouch at a run; `slide_duration`, `slide_boost` and a cooldown are tunables. |
| Launch ability (off) | `launch_button` throws the player up and optionally forward, on a cooldown. |
| Wall running, wall jumping, wall slide (off) | Each is a separate tunable. |

### Extending it

- **Surfaces:** set `dot_fps_surface = "ice"` on a collider (or put it in a `surface_ice` group) and give the controller a `DotFpsSurfaceSet`.
- **Modifiers:** `DotFpsModifier` scales speed, acceleration, gravity, friction and jumping, denies movement, or applies an impulse.
- **Admin abilities:** `admin_abilities = true` registers noclip, freeze, and speed and gravity steps that the owning client predicts.
- **Movement modes:** subclass `DotFpsMoveMode`.
- **Sampling:** use a sampler, or build a `DotFpsCommand` yourself for a bot or demo.

These are part of the simulation, so they replicate and survive replays. See [docs/extending.md](docs/extending.md).

### Networking

The controller does not import dot-net. Wiring it up takes about 30 lines; see [docs/networking.md](docs/networking.md). Compare `DotFpsTunables.fingerprint()` between client and server, because a config mismatch looks like packet loss.

## Third-person movement

An orbit rig on a spring arm with a swappable shoulder offset, camera-relative movement, turn-to-face, strafe-lock, coyote time and a jump buffer. `DotTpsMotor.step` relies on `move_and_slide` for collisions, so it is repeatable on one machine but not bit-exact against a server. For that, drive the first-person motor and use `tp/` only for the camera.

## Writing a controller

```gdscript
class MyController extends DotPlayerController:
    func _apply_intent(intent: DotPlayerIntent, delta: float) -> void: ...
    func _read_transform() -> Transform3D: ...
    func _write_transform(to: Transform3D) -> void: ...
    func _read_velocity() -> Vector3: ...
    func _write_velocity(v: Vector3) -> void: ...
```

The defaults read and write a `CharacterBody3D` or `CharacterBody2D`, so simple controllers can skip four of them. See `examples/controller_selftest.gd`. All docs: [docs/README.md](docs/README.md).

## Credits

| What | Author / source | License |
| --- | --- | --- |
| Original first-person controller this one started from | [BleyChimera](https://github.com/BleyChimera) | Code basis, now under the repo MIT licence |
| Maintainer | [Christian Deacon](https://github.com/gamemann) | MIT |
| Prototype textures | [Kenney](https://www.kenney.nl/assets/prototype-textures) | CC0 |

## Status and licence

Part of the TMC **dot-\*** family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/gamespice-platform/player-controller/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the TMC platform is the web back end; you can use your own instead of TMC's.
