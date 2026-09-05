This is the **first-person movement** asset for TMC's **Dot** collection. It is the feel of the game, and it is written to be predicted on a client and reconciled on a server rather than bolted onto netcode later.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## First-Person Movement, Built to be Networked
A first-person movement controller for Godot 4, built to be **networked**.

Classic strafe acceleration — air-strafing, bunny-hopping, surf ramps — with
stair stepping, crouching that checks for headroom, coyote time and jump buffering.
The simulation is deterministic and driven entirely by explicit commands, so a client
can predict it and a server can reconcile it.

Part of the [dot-\*](../) family. Requires [dot-core](../dot-core). Works with
[dot-net](../dot-net) and [dot-server](../dot-server), and requires neither.

## Install

Copy `addons/dot_fps_controller/` and `addons/dot_core/` into your project and enable
both in *Project → Project Settings → Plugins*.

## Use

```
Player (CharacterBody3D)
 ├── Collision   (CollisionShape3D)
 ├── Head        (Node3D)
 │    └── Camera (Camera3D)
 ├── View        (DotFpsView)
 └── Controller  (DotFpsController)
```

That is the whole setup. Nothing is wired by hand: the view finds the camera by type
and the controller finds the collider and the view the same way. Every one of those
is a `DotNodeRef` you can override in the inspector when your scene looks different.

Input actions are registered at runtime if your project has none — WASD, space, ctrl,
shift, alt, V. Existing actions are never touched; point `DotFpsSampler.actions` at
your own names to use them instead.

Try it:

```bash
godot --path . res://examples/sandbox.tscn
```

## What is in the box

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

## Movement

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

## Extending it

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

## Networking

The controller does not depend on dot-net and does not import it. What it gives you
instead is the hard part: a simulation that reproduces itself exactly when replayed,
a command that packs to 49 bits, a state object with nothing left outside it, and
`DotFpsNetSync`, which says what to replicate and at what precision.

Joining the two is about thirty lines in your game. `CLAUDE.md` has the whole thing.

`DotFpsTunables.fingerprint()` is worth wiring up on day one: a client whose movement
config differs from the server's diverges every tick, and the symptom is
indistinguishable from packet loss.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/movement_selftest.tscn     # 149 checks
godot --headless --path . res://examples/controller_selftest.tscn   # 46 checks
```

Both exit non-zero on failure.

## Credits

- [Christian Deacon](https://github.com/gamemann)
- [BleyChimera](https://github.com/BleyChimera) — the original controller this one
  replaces started from their code.
- [Prototype textures](https://www.kenney.nl/assets/prototype-textures) by Kenney.

MIT licensed.
