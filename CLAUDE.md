# dot-fps-controller

First-person movement for Godot 4, written so it can be networked.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first — no
autoloads, `DotNodeRef` instead of scene paths, `DotResult` for anything fallible,
`Dot`-prefixed class names, layered configuration, `describe()` on anything stateful.
This file is only what is specific to movement.

## The one idea

**The simulation is a pure function of (state, command, delta, world).**

Everything else here follows from that. It is what lets a client apply input
immediately and a server correct it a round trip later without the two disagreeing —
and it is a property that has to be designed in, because nothing about GDScript
enforces it and nothing about a single-player game reveals when it is broken.

Concretely:

- `DotFpsMotor` never reads the keyboard, the wall clock, an unseeded random stream,
  the frame rate, or a node's transform. Time comes from `delta`, intent comes from
  the command, the world comes from `DotFpsBody`.
- Every timer in `DotFpsState` counts simulated seconds. `Time.get_ticks_msec()`
  appears nowhere in `motion/`.
- `DotFpsState` holds *everything* the simulation reads between ticks. A field left
  on the controller node is not restored by a rewind, so the replay starts from a
  state the server never computed and the correction is measured against a fiction.
- Sampling lives in `DotFpsSampler`, separately, so a replay does not accidentally
  call `Input.is_action_pressed` and get what the player is holding *now*.

`examples/movement_selftest.gd::_test_replay_determinism` is the test that guards
this. It runs 400 mixed commands, snapshots at tick 250, replays the last 150 from
the snapshot, and requires the same endpoint — which is exactly the shape of
reconciliation. It also runs a negative control, because a test that cannot fail is
not a test.

## Layout

```
addons/dot_fps_controller/
  core/
    dot_fps_command.gd      one tick of intent; the wire format
    dot_fps_state.gd        everything carried between ticks
    dot_fps_tunables.gd     every number, as a layered DotConfig
  motion/
    dot_fps_body.gd         the collision queries the motor needs (abstract)
    dot_fps_physics_body.gd against Godot's physics server
    dot_fps_flat_body.gd    against planes and boxes, for tests
    dot_fps_motor.gd        the simulation
  nodes/
    dot_fps_controller.gd   the component a game adds
    dot_fps_view.gd         camera, pitch, crouch height, FOV — cosmetic only
    dot_fps_sampler.gd      devices to commands
  net/
    dot_fps_net_sync.gd     what replicates, without importing dot-net
```

Additions since the first pass, all of them extension points rather than features:

```
  core/
    dot_fps_surface.gd      how one kind of ground behaves. Multipliers, not values.
    dot_fps_surface_set.gd  the table, and how a collider maps to an entry
    dot_fps_modifier.gd     a temporary change to movement, plus the aggregate
  motion/
    dot_fps_move_mode.gd    a movement mode a game adds: ladder, water, grapple
  nodes/
    dot_fps_touch_sampler.gd  commands from touch. No art, no layout.
```

And, for surf and bunny-hop servers — the movement half of what dot-timer times:

```
  core/
    dot_fps_style.gd        a named variation on the movement — a "style".
    dot_fps_stats.gd        jumps, strafes, sync, perfect hops, speed. Per tick.
```

`motion/` may not reference `nodes/`. That direction of dependency is what keeps the
simulation testable without a scene, and it is the first thing to break if a
"convenient" reference to the controller is added to the motor.

## Surf, bunny-hopping and what they needed

Surf is not a feature. It is what this movement model does on a face too steep to
stand on,
and the only question is whether the collide-and-slide gets out of the way. Three
things here decide whether it does, and one of them was wrong:

**A ramp steeper than `max_slope_angle` must not ground the player.** It already did
not — `_categorise_ground` requires `_is_floor` — so the player stays in `Mode.AIR`,
gets gravity and air acceleration, and the slide clips their velocity along the face.
That is surf, in full, and nothing needed adding for it.

**The seam between two ramps did need adding.** `_slide` used to clip against each
contact normal in turn, which is not the same as finding a direction that satisfies
both: at a seam the vector clipped against the first ramp points into the second, and
the vector clipped against the second points back into the first. The player arrives
at 20 m/s and stops dead in the corner. `_resolve_planes` is the classic
`TryPlayerMove`: keep every plane touched this move, take the first clipped direction
that re-enters none of the others, and when there is none, go along the crease — the
cross product of the two normals, which is parallel to both faces by construction.
`crease_slide` turns it off, which is what the self-test's negative control uses.

**Touching the same plane twice must not zero the velocity.** The first version of
the plane list treated a repeated normal as "stuck" and stopped the player. A player
who begins a tick a fraction of a millimetre inside a ramp — which happens on every
spawn onto one and after every prediction correction — was then brought to a dead
stop on a surface they should have been accelerating down. A duplicate plane is one
that has already been satisfied: stop the move, keep the velocity. A *full* plane
list is a real corner and does stop them.

`bhop_speed_cap_scale` is the landing cap those shooters added (they ship
1.104), off here because a movement game that caps hop speed has no bunny-hopping.
`edge_friction` is `sv_edgefriction`, off because it costs a query per grounded tick.

### Styles

`DotFpsStyle` is what a timer server means by the word: sideways,
half-sideways, backwards, low gravity, prebhop. It does exactly two things, and
`DotFpsController.set_style` does both in the right order:

- `apply_to(base)` returns a **derived** `DotFpsTunables`, never mutating the base.
  The controller keeps `_base_tunables` and always derives from it, because deriving
  from the previous style's output compounds the scales — switch to low gravity and
  back and you land in a quarter of it.
- `filter_command(cmd)` clears the keys the style forbids, **in place, on both
  machines, before the motor sees it, and idempotently** because a prediction replay
  runs it again over stored commands. Filtering only on the server makes the client
  predict movement the server will not produce.

Scales rather than absolute values, for the reason `DotFpsSurface` uses them: a style
holding an absolute `max_speed` silently stops tracking the base the first time
somebody retunes it. The two exceptions are `air_accelerate` and
`max_air_wish_speed`, where the pair *is* the style and a scale would mean nothing.

**`timescale` is not applied by `apply_to`.** Scaling the simulation means scaling
`delta`, which is the host's tick loop's decision — and on a server it has to be the
same decision for every player or the tick counter stops meaning anything.

The ranking half of a style — ranked or not, points multiplier, minimum time — is
`DotTimerStyle` in dot-timer. Movement lives where the motor is; records live where
the records are; a game pairs them by id.

### Statistics

`DotFpsStats` is the HUD line every bhop player watches: jumps, strafes, **sync**,
perfect hops, average and peak speed. Two decisions in it are load-bearing:

- **Counted per simulated tick and not per frame**, so two players on different
  monitors get the same sync for the same run.
- **Not observed during a prediction replay.** A replayed tick is one the statistics
  have already seen, and counting it again gives a client on a lossy link a jump
  count that climbs by itself. The server's copy is what a record is filed with.

`DotFpsState.ground_ticks` exists for this and is counted in **ticks**: a perfect hop
is a jump that leaves on the tick of the landing, and deriving that from a seconds
timer scores the same run differently at 64 Hz and at 128 Hz.

`DotFpsFlatBody` grew half-space planes and `add_ramp` so all of this is testable
without a physics world — a surf ramp is one large sloped face and needs nothing else.

## Why the collision goes through DotFpsBody

Three reasons, and the second and third were both found the hard way:

1. **Testing.** The determinism test needs thousands of ticks against known geometry.
   `DotFpsFlatBody` makes it arithmetic; a failure has one possible cause.
2. **`move_and_slide` keeps state.** The floor normal and velocity it remembers
   between calls are not restored by a rewind. The motor does its own
   collide-and-slide over a stateless query instead.
3. **A server does not need a rendering physics world**, and a game whose collision
   is a heightfield or a BSP can implement `DotFpsBody` against that directly.

### Swept queries are the sharp edge

Three separate bugs in this project came from the same place, and all three were
found by running the examples rather than by reading the code:

- **`cast_motion` reports no collision when a move ends exactly touching.** Correct in
  isolation — touching is not overlapping. Fatal in practice: land so your feet come
  to rest at precisely the floor's height and every subsequent downward sweep also
  reports nothing, so you are never grounded again and sink through the world at a
  constant rate. It takes one tick where the fall distance equals the remaining gap.
- **A swept query's precision is proportional to its length.** The binary search stops
  at a tolerance of roughly a percent of the motion, so a 35 cm ground probe can
  return a "safe" distance that overlaps by 3 mm. That is how the ground snap put the
  player *below* the floor it was snapping onto.
- **`Vector3` components are 32-bit and GDScript arithmetic is 64-bit.** A player
  standing exactly on `y = 0` has feet at `-2.4e-8` once the centre has been through
  a `Vector3`. `DotFpsFlatBody` required `feet >= floor_y` and every ground probe
  missed — nothing was ever grounded, friction and ground acceleration never ran, the
  player capped at the air-control speed and slowly sank. One epsilon, four symptoms,
  none of which pointed at the epsilon.

`DotFpsMotor._sweep` is the answer to the first two: every query sweeps a margin
further than asked and gives the distance back, where the margin is
`max(skin_width, length * SWEEP_TOLERANCE)`. `_categorise_ground` carries a fourth
defence — if the swept probe misses but the capsule *overlaps* something and the
player was grounded last tick, they stay grounded. A swept query cannot say anything
useful about a shape that starts inside geometry, and the failure mode without that
check is falling out of the level.

**The ground snap only runs when the player has actually left the ground.** That is
not an optimisation. Running the longest, least precise query in the tick on a player
who is already standing still re-derived a correct position from the worst available
measurement, and moved them a fraction of a millimetre down each time.

## What the rewrite changed, and why

The original was a single-player controller. The problems were not style:

| Was | Now |
| --- | --- |
| Movement ran in `_process`, so the simulation was frame-rate dependent | Fixed-tick, accumulated from frame time, bounded against stalls |
| `Input.is_action_pressed` read inside the controller | `DotFpsCommand`, sampled once per tick by `DotFpsSampler` |
| `vel = settings.max_velocity` assigned a float to a `Vector3` | `limit_length`, with a NaN check that logs and resets |
| Ground `accelerate` applied its increment three times in a loop | Once, as the model says |
| Air jump used `mul * max(0, vel.y)`, so it was zero at rest | One jump path, `sqrt(2 * g * h)` |
| One `speed_multiplier`, reset to 1 by whichever modifier was released | Derived from held buttons each tick; most restrictive wins |
| `is_crouched` was read but never assigned | `crouch_fraction` and `crouch_held`, both simulated |
| Crouch lerped a camera offset; the collider never changed and standing up never checked | Collider resizes; standing up is refused without headroom |
| `snap` was computed and never used | Ground snapping, so slopes are not ice |
| No stair stepping | `step_height`, with the down-leg floor test |
| `can_noclip` documented as "not yet implemented" | Implemented, gated twice |
| Yaw applied to the camera, so the body never turned | Yaw on the body, pitch on the camera |
| States loaded by `load(base_dir + "/states/" + name + ".gd")` | Direct references; no runtime path construction |
| `class_name Player`, `Player_Input` — global names | `Dot`-prefixed throughout |
| Not an addon | `addons/dot_fps_controller/` with a `plugin.cfg` |
| README documented `player_shift`; the project defined `player_sprint` | One set of names, registered at runtime, overridable |

## The three extension systems, and the rule they share

Surfaces, modifiers and custom modes all change the simulation, so all three are
bound by the same constraint as everything else here: **a client and a server must
reach the same answer, and a replay must reproduce it.** That single requirement
decided every interesting part of their design.

### Surfaces

`DotFpsSurface` scales what the tunables already say — friction, acceleration, speed
cap, jump — rather than replacing them, so retuning the base feel does not silently
leave every surface behind.

**The hard part is the mapping, not the table.** The obvious way to answer "what am I
standing on" is to look up the collider the ground probe hit, but a collider's
instance id is process-local: the client and the server get different numbers for the
same floor. Any mapping keyed on it produces two machines that disagree about
friction, which is a divergence prediction cannot reconcile and which only shows up
on some surfaces. So the mapping goes through node metadata or a group — scene data
both machines load from the same file. `DotFpsController._resolve_surface_id` does
that, and caches it, because the answer only changes when the player steps onto a
different collider.

`push` is worth a warning that is also in its own docs: it is an acceleration and it
competes with friction, which is applied as though the player were moving at least
`stop_speed`. A push below `stop_speed * friction` cannot move a standing player at
all. With the shipped defaults that threshold is 24 m/s², which is a lot more than
the number most people would first type.

### Modifiers

**Definitions are configuration; the active set is state.** A prediction rewind
restores `DotFpsState` and replays from it, so a modifier held anywhere else vanishes
on the first correction. The definition — how much faster, for how long — is the same
on every machine and never changes, so it stays out.

`DotFpsState.modifiers` is **sorted by index**, and that is load-bearing rather than
tidy: the aggregate is a product, floating-point multiplication is not associative,
and two machines applying the same set in different orders reach answers that differ
in the last bits. That is exactly the drift that makes a reconciliation never settle.

Effects multiply so they compose in any order; denials (`deny_jump`, `deny_move`) are
sticky so nothing can multiply a stun back off.

**What travels is a 32-bit mask of active indices, and not the expiry tick.** That is
a deliberate trade: the effect while a modifier is active is predicted exactly, and
only its *end* can be late, by up to one snapshot interval. Sending expiries would
cost a varint each to fix something a player cannot feel. Revisit it if a game ever
has a modifier whose expiry frame matters.

Registration order defines the indices, and the indices are what replicate — so
`register_modifier` must be called in the same order on every machine.
`_register_extensions` exists to give that a fixed place; registering conditionally
(only on the server, only in one game mode) gives two peers different ids for the
same modifier, and the symptom is a power-up that works for some players.

### Custom modes

`DotFpsMoveMode` is how a game adds a ladder, water, a grapple or a vehicle seat
without forking the motor. Ground, air and noclip stay built in because they are what
the tunables describe; everything else is a decision about feel.

**A mode owns its whole tick** — gravity, acceleration, collision — because a ladder
that had gravity applied behind its back would have to cancel a force it never asked
for. The motor exposes `accelerate`, `move_and_slide`, `probe`, `would_overlap`,
`categorise_ground`, `effects()` and `surface()` so a mode gets the same skin-margin
and step handling as the built-ins, which is where all the collision bugs were.

**Nothing may be stored on the mode object.** One mode instance serves every player
using it, and a rewind does not restore it. State goes in `DotFpsState`.

## Wiring it to dot-net

dot-net is **not** a dependency and is **not** imported. That is the family rule, and
in GDScript it is not merely a preference: a script that *mentions* a `class_name` the
project does not have fails to parse and takes everything referencing it down too.
The same reason `DotTransportENet` reaches ENet through `ClassDB.instantiate`.

So `DotFpsCommand.write`/`read` take a `Variant` writer and call `DotNetWriter`'s
methods by name, and `DotFpsNetSync` describes the replicated properties as strings a
bridge resolves with `DotNetVar.Type[name]`. `examples/movement_selftest.gd::FakeWire`
checks that contract without the dependency present — a typo in a method name would
otherwise only show up in a host game.

The bridge a game writes, in full:

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

- **`_net_state_applied` must restore the whole state**, which is what
  `DotFpsNetSync.push` does. Reconciliation adopts the server's answer and replays
  every unacknowledged command on top of it; anything not restored makes the replay
  start somewhere the server never was.
- **`delta` must be the tick duration** on both sides, and `tick_rate` must match.
  It is an input to the simulation.
- **Compare `DotFpsTunables.fingerprint()` at connect time.** A client with different
  movement values diverges every tick and it looks exactly like packet loss.
  `DotFpsNetSync.differences()` names the property that differs.

## Where a game plugs in

Nothing here should require a fork.

| To change | Where |
| --- | --- |
| Which node anything attaches to | `DotNodeRef` on the controller and the view |
| Movement feel | `DotFpsTunables`, per instance or per JSON file |
| A named variation on it — sideways, low gravity, prebhop | `DotFpsStyle`, via `DotFpsController.set_style` |
| How one kind of ground behaves | `DotFpsSurface` in a `DotFpsSurfaceSet` |
| How a collider maps to a surface | Node metadata or a group; override `DotFpsController._resolve_surface_id` |
| A temporary effect — pad, slow field, stun, launcher | `DotFpsModifier`, registered in `_register_extensions` |
| A new movement mode (ladders, swimming, vehicles) | `DotFpsMoveMode` subclass, `DotFpsMotor.register_mode` |
| Collision source (heightfield, BSP, a server with no render world) | `DotFpsBody` subclass, assigned by overriding `DotFpsController._make_body` |
| Input devices, action names, a bot, a demo | `DotFpsSampler`; `DotFpsTouchSampler` for touch |
| Extra actions (fire, use, reload) | `BUTTON_USER_0..2`, already on the wire |
| Camera behaviour, view bob, landing kick, strafe roll | `DotFpsView` exports, or a subclass |
| Anything inside the tick — triggers, mode switches | `_on_pre_simulate` / `_on_post_simulate` |
| Refusing input — a cutscene, a respawn freeze | `_accept_command` |
| Reacting to movement | `landed`, `jumped`, `stepped_up`, `crouch_changed`, `surface_changed`, `modifier_added` / `modifier_removed`, `mode_changed` |

`BUTTON_USER_*` exists so a game's own actions ride in the command it already sends,
in tick order with movement, rather than in a second message that has to be
correlated with it.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/movement_selftest.tscn     # 149 checks
godot --headless --path . res://examples/controller_selftest.tscn   # 46 checks
godot --headless --path . res://examples/surf_selftest.tscn         # 52 checks
```

All three exit non-zero on failure. **Run the check-only pass before the scenes**:
a script that fails to parse makes the scene fail to load, and the process then hangs
rather than exiting, because nothing ever reaches `get_tree().quit()`.

Two GDScript hazards that cost time here, both already in the family CLAUDE.md and
both hit again:

- `var x := arr[i].f()` where the array is untyped is a **parse error**, not a
  warning. `Array.duplicate()` returns an untyped array.
- **Lambdas capture locals by value.** `var n := 0` incremented inside a signal
  handler stays zero outside it, so a test asserting on the count reports a failure
  for a signal that fired perfectly. Capture an `Array` instead.

## Things deliberately not here

- **Ladders, swimming, vehicles.** `DotFpsMoveMode` is the hook; the modes
  themselves are a game's own decision about feel. The self-test ships a ladder as a
  worked example of the interface, not as something to use.
- **Weapons, health, hit detection.** dot-net's lag compensation rewinds positions;
  what to trace is a game's concern.
- **Camera shake, weapon sway, procedural lean.** `DotFpsView` has bob, a landing
  kick and strafe roll; the rest is cosmetic and every game wants different ones.
- **On-screen touch controls.** `DotFpsTouchSampler` turns fingers into commands and
  deliberately ships no art or layout — a virtual stick that draws itself is one
  nobody can restyle. A game draws its own and calls `hold()`.
- **Moving platforms.** They need a velocity frame the player inherits, and doing that
  deterministically across a client and a server needs the platform to be part of the
  replicated simulation — which is dot-net's problem, not this one's.
- **A character mesh or animation.** `DotFpsController` publishes position, yaw, pitch
  and crouch; driving an `AnimationTree` from those is a game's own layer.
