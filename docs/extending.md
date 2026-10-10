# Extending the first-person controller

Surfaces, modifiers and custom modes all change the simulation, so all three are bound by the same constraint as everything else here: **a client and a server must reach the same answer, and a replay must reproduce it.** That single requirement decided every interesting part of their design. Nothing here should need a fork; the family's subclass-or-assign rules are in [extension-points.md](../../../docs/extension-points.md).

## Where a game plugs in

| To change | Where |
| --- | --- |
| Which node anything attaches to | `DotNodeRef` on the controller and the view |
| Movement feel | `DotFpsTunables`, per instance or per JSON file |
| How far a jump carries a player, for sizing a gap or a ledge | `DotFpsTunables.jump_reach` / `climb_limit` / `jump_airtime`, or the static `reach_for` / `airtime_for` |
| A named variation (sideways, low gravity, prebhop) | `DotFpsStyle`, via `DotFpsController.set_style` |
| How one kind of ground behaves | `DotFpsSurface` in a `DotFpsSurfaceSet` |
| How a collider maps to a surface | Node metadata or a group; override `DotFpsController._resolve_surface_id` |
| A temporary effect (pad, slow field, stun, launcher) | `DotFpsModifier`, registered in `_register_extensions` |
| A new movement mode (ladders, vehicles) | `DotFpsMoveMode` subclass in `DotFpsController.extra_modes` (survives a style) or `_register_extensions` |
| Water | `DotFpsSwimMode` in `extra_modes`, with the map's boxes |
| Collision source (heightfield, BSP, a server with no render world) | `DotFpsBody` subclass, assigned by overriding `DotFpsController._make_body` |
| Which layers the player collides with | `DotFpsController.set_collision_mask(mask)` |
| Input devices, action names, a bot, a demo | `DotFpsSampler`; `DotFpsTouchSampler` for touch |
| Extra actions (fire, use, reload) | `BUTTON_USER_0..2`, already on the wire |
| Camera behaviour, view bob, landing kick, strafe roll | `DotFpsView` exports, or a subclass |
| Anything inside the tick (triggers, mode switches) | `_on_pre_simulate` / `_on_post_simulate` |
| Refusing input (a cutscene, a respawn freeze) | `_accept_command` |
| A slide off a crouch press at a run | `DotFpsTunables.slide_*` (`slide_enabled` first); `DotFpsView.slide_fov_gain` / `slide_roll`; `slide_changed` |
| A dash along the way the player steers | `DotFpsTunables.dash_*` (`dash_button` as with the launch); `dashed` |
| An ability that throws the player into the air | `DotFpsTunables.launch_*`, with `launch_button` set to a command bit the game has free; `launched` |
| An administrator's noclip, freeze, speed or gravity | `admin_abilities` on every machine, then `DotFpsAdminModifiers` on the server |
| Reacting to movement | `landed`, `jumped`, `stepped_up`, `crouch_changed`, `surface_changed`, `modifier_added` / `modifier_removed`, `mode_changed` |

`BUTTON_USER_*` exists so a game's own actions ride in the command it already sends, in tick order with movement, rather than in a second message that has to be correlated with it.

## Surfaces

`DotFpsSurface` **scales** what the tunables say (friction, acceleration, speed cap, jump) rather than replacing it, so retuning the base feel does not silently leave every surface behind.

**The hard part is the mapping.** The obvious answer to "what am I standing on" is the collider the ground probe hit, but a collider's instance id is process-local: client and server get different numbers for the same floor, and any mapping keyed on it gives two machines that disagree about friction. So the mapping goes through node metadata or a group, scene data both machines load from the same file. `_resolve_surface_id` does that and caches it, because the answer only changes when the player steps onto a different collider.

`push` is an acceleration and competes with friction, which is applied as though the player were moving at least `stop_speed`. A push below `stop_speed * friction` cannot move a standing player at all; with the shipped defaults that is 24 m/s², more than most people would first type.

## Modifiers

**Definitions are configuration; the active set is state.** A rewind restores `DotFpsState` and replays from it, so a modifier held anywhere else vanishes on the first correction. The definition (how much, how long) is the same on every machine and stays out.

- `DotFpsState.modifiers` is **sorted by index**: the aggregate is a product, floating-point multiplication is not associative, and two machines applying the same set in different orders differ in the last bits, which is exactly the drift that keeps a reconciliation from settling.
- Effects multiply so they compose in any order; denials (`deny_jump`, `deny_move`) are sticky so nothing multiplies a stun back off.
- **What travels is a 32-bit mask of active indices, not the expiry tick.** The effect is predicted exactly; only its end can be late, by up to one snapshot interval. Revisit if a game ever has a modifier whose expiry frame matters.
- **Registration order defines the indices, and the indices replicate.** `register_modifier` must be called in the same order on every machine; `_register_extensions` is the fixed place. Registering conditionally (only on the server, only in one mode) gives two peers different ids for the same modifier: a power-up that works for some players.

## Admin abilities

`DotFpsAdminModifiers` is noclip, freeze, a speed step and a gravity step, and **every one is a `DotFpsModifier`**, because that is the only shape of server decision the prediction already carries. Refused alternatives:

- **Setting `state.mode = NOCLIP` on the server** reaches the client in the next snapshot, and the client's `_update_noclip` drops the player to AIR on every replayed tick because the client's `can_noclip` is false (correctly: a client's tunables are not a permission). Rubber-banding between flying and falling with every server number right. `movement_selftest`'s admin section keeps this as its negative control.
- **Changing a tunable** is the same bug by another route, and a fingerprint mismatch.

`DotFpsModifier.forces_noclip` is read in `_update_noclip` **before** the ability gate, so it wins over `can_noclip` and the player's own button. `_simulate_noclip` honours `deny_move`, so frozen-and-noclipped stays frozen.

Two deliberate costs. **The multipliers are a ladder** (`SPEED_STEPS`, `GRAVITY_STEPS`) because only membership travels and a value made up at runtime is one the client has never heard of; `set_speed` returns the step it picked. **`admin_abilities` must be on for every player on every machine**, because registration order is the wire contract: the admin modifiers register straight after `_register_extensions` so a game's own indices do not move, and `DotFpsAdminModifiers` refuses rather than registering on the spot for a controller built without them.

## Custom modes and swimming

`DotFpsMoveMode` is how a game adds a ladder, a grapple or a vehicle seat. Ground, air and noclip stay built in because they are what the tunables describe.

- **A mode owns its whole tick** (gravity, acceleration, collision): a ladder that had gravity applied behind its back would have to cancel a force it never asked for. The motor exposes `accelerate`, `move_and_slide`, `probe`, `would_overlap`, `categorise_ground`, `effects()` and `surface()` so a mode gets the same skin-margin and step handling as the built-ins, which is where all the collision bugs were.
- **Nothing may be stored on the mode object.** One instance serves every player and a rewind does not restore it. State goes in `DotFpsState`.
- **Register through `DotFpsController.extra_modes`.** A mode registered by hand on the motor is lost the first time a style rebuilds it; `fps_controller_selftest` asserts one survives two.

`DotFpsSwimMode` (`fp/motion/dot_fps_swim_mode.gd`) is the first built-in custom mode:

- **Water is a list of axis-aligned boxes** (`volumes`) the game hands over from its map, never an `Area3D`: overlap signals arrive after the physics step, and a client replaying ticks cannot ask an area where it was. A box list answers any question any number of times, the same on both ends.
- **Entering is the game's once-a-tick call** (`update(motor, state)`, from per-tick logic that also runs during a replay), when the waist (`waist`, 1 m above the feet) is in a volume. **Leaving is the mode's own**, the moment the waist is out: it hands the player to AIR.
- In the water the wish follows the view (pitch included), jump swims up and crouch dives, with nothing pressed the player drifts to float with the head `float_depth` above the surface, and a jump with the waist within `exit_reach` of the surface sets the upward speed to `exit_speed`, enough to get over an edge. `_uses_crouch` is false, so the collider does not change size underwater.

## Slide, launch and dash

**All three are off by default, and that is the whole compatibility story.** Every `slide_*`, `launch_*` and `dash_*` number is read only behind its `*_enabled`, so a game that never sets them simulates what it did before they existed. They are still in `fingerprint()`: two peers that disagree about them disagree about where a crouching runner goes.

- **A slide is a crouch with different friction and steering, nothing else.** It starts on the crouch PRESS, grounded, at `slide_min_speed`; crouch already held when the speed arrives is a crouch. The collider is the crouched one, so a slide goes under what a crouch goes under. While it lasts `slide_friction` replaces `friction` (surfaces and modifiers still scale it) and `slide_accelerate` replaces `accelerate`; the wish speed is the crouched one, so acceleration bends the run rather than speeding it up. `slide_boost` is capped by `slide_max_speed`, and a player already faster gets no burst rather than being slowed.
- **The launch is an ability, not a `DotFpsModifier`**, because it is an impulse and a modifier is a multiplier. It sets the vertical speed rather than adding to it, so a launch at the top of a jump goes no higher than one from the ground. **Its button is a setting, not a new bit**: every bit on the wire is spoken for, so `launch_button` names whichever one the game has free. A stun refuses it.
- **The dash is the launch's shape sideways**: a press of `dash_button` sets the horizontal speed along the move direction (the view's heading with nothing held) to at least `dash_speed`, never less than the player already has along it, and adds `dash_lift` so ground friction does not eat it on the first tick. Holding against a dash in the air brakes it at the air-acceleration rate; that is air control, not a bug.
- **Their timers (`slide_time`, the slide, launch and dash cooldowns) are in `DotFpsState` AND in the snapshot**, packed into `net_flags` with `previous_buttons`. See [networking.md](networking.md#what-rides-in-net_flags).
- `slide_changed`, `launched` and `dashed` are **not** emitted during a prediction replay, unlike `crouch_changed`: they are where a game hangs a sound, and a replayed tick is one the player already heard.

## The collision mask

`DotFpsController.simulate_tick` hands `tunables.collision_mask` to its `body` every tick, because every game sets the mask after setup (when it knows its physics layout) and a body that copied it once in `_make_body` kept the world layer only: players walked through every prop with the tunables reading the right mask.

And `set_style` rebuilds `tunables` from the base copy taken at the first setup, so a mask written on the live tunables reverts at the next style. **`DotFpsController.set_collision_mask(mask)` sets the base, the live tunables and the body, and is the way to set it.**
