# The contract, the switch, and the third-person half

## The switch

**A switch between two controllers carries position, velocity and view, and nothing else.** That sentence is why this addon exists separately from the controllers that implement it. The alternative, one controller knowing how to become the other, means a first-person motor's state has to be convertible into a third-person motor's, and it is not: the fields have no counterpart and any mapping is a lie. What genuinely survives a view change is where the player is, how fast they are going and where they are looking; everything else starting fresh is correct. Getting out of a vehicle should not restore the air-strafe you were in the middle of.

Two orderings matter:

- **Activate, then hand over.** A real controller resets its motor in `_on_activated`. Passing the state first means the reset wipes it, and the symptom is a player who stops dead every time they change view, which reads as a physics bug. The switch does `incoming.activate()` and then `incoming.adopt_state(...)`; the suite checks `resets == 1` at the point the state has landed.
- **The default is activated deferred.** A switch's `_ready` can run before its siblings', so their `controller_id` may still be whatever the scene had. `call_deferred("_activate_default")` runs one frame later, when every node in the subtree has read its exports.

Two consequences for a consumer, both found in a game:

- **A controller's id must be set before the switch enters the tree.** `_ready` defers activation but calls `refresh()` immediately, and a controller still carrying an empty `controller_id` then is registered under its class name. `default_controller` names something that is not there and the switch falls back to whatever it found first: the game opens in the wrong view, and the only symptom is the camera.
- **Wait one frame before reading `active_id()`.** On the frame the switch is built it is still empty, which is neither controller.

## Freezing is not deactivating

`drive()` with `input_enabled = false` applies an **empty** intent rather than returning early. Gravity, friction and world forces still apply to a frozen player; a controller that skipped the tick leaves them hanging in mid-air, which is the warm-up-freeze bug every game ships once. The return value distinguishes "frozen" from "moved nowhere" so a caller does not have to read a flag.

`input_enabled` and `active` are different things. A player frozen during a countdown is still on their own controller and still has their camera; a controller that deactivated instead would hand the player to nothing. Freezing is a level; activity is an identity.

## What does not go on the wire

`DotPlayerIntent.to_dict` sends the accumulated angles and **not** the look delta, and sends no empty `look` key either: a field sent and ignored is a field somebody will eventually start reading. A server integrating deltas reconstructs an angle the client already knows, and one lost packet makes them disagree about it permanently.

## Dependency direction

`fp/motion/` may not reference `fp/nodes/`, and `tp/core/` may not reference `tp/nodes/`. That direction is what keeps each simulation testable without a scene, and it is the first thing to break when somebody adds a "convenient" reference to the controller.

## It was three addons

`dot-player-controller-fp` (which was `dot-fps-controller`) and `dot-player-controller-tp` were separate repositories and are now folders: nobody installed either half without the base, and the base is useless alone. Every `class_name` survived (`DotFpsController`, `DotFpsMotor`, `DotTpsController`, `DotTpsCameraRig`), because `class_name` is global and renaming one breaks every project that has the addon.

A game may delete `fp/` or `tp/`. `dot_player_controller_plugin.gd` skips a type whose script is absent, so a trimmed install is supported rather than tolerated.

## Three name collisions

- **`Btn`, not `Button`.** `Button` is a native class and GDScript refuses the shadowing outright. Caught here rather than in a subclass, where the error would have been reported against the file that used it.
- **`CONTROLLER_CHANNEL`, not `CHANNEL`.** `DotPlayerComponent` already declares `CHANNEL`, and a constant that shadows a parent's is a parse error.
- **`transform_3d()`, not `transform()`.** `DotPlayerComponent extends Node`, so `transform` is free today, and would not be the moment a controller extended `Node3D`. The error is reported against the using file and `--check-only` on the declaring one says nothing; see [gdscript-hazards.md](../../../docs/gdscript-hazards.md).

## What this does not do

It does not sample input: a sampler belongs with the controller that knows what its actions are called, and dot-ui owns rebinding. It does not own a camera. It does not know what a body is beyond the default read/write pair, which handles a `CharacterBody3D` or `CharacterBody2D` and is overridable because most controllers have their own idea.

## The third-person half

**The rig's arm is a `DotCameraBoom` (dot-core), not a `SpringArm3D`.** The spring arm cast a ray and snapped to the hit, and the shoulder offset was a marker moved sideways after the cast, so a shoulder against a wall put the near plane through it. The boom sweeps a sphere from the rig to the shoulder point and eases in ahead of an obstacle (dot-core's [camera](../../dot-core/docs/camera.md)); `follow()` places it, once a frame, from that frame's pivot. A `DotCameraFade` under the camera fades bodies on `fade_mask` that come between the camera and the character. `tps_selftest`'s "against a wall" section checks the rig against a real wall, armed by the camera's unobstructed position being behind it.

**`DotTpsCameraRig` excludes the body it hangs off.** `SpringArm3D` excludes nothing unless told, and the rig is a child of the player, so on any game whose player is a `CharacterBody3D` the arm collides on its first millimetre and collapses to the margin: the camera sits inside the character at every distance with every tunable reading as configured. `tps_selftest` builds no physics world, so its arm collides with nothing and passed for the one reason it could not fail. It was found by a rendered frame (game-playground's `tools/screenshot_views.sh`). Anything about the rig colliding needs a picture, not an assertion.

## The view and solid players

Two server rules every first-person game binds, both from the first play test (2026-10-11).

**`mp_forceview` (`DotPlayerViewRules`).** 0 the player's choice (the view key toggles first and third person), 1 first person only, 2 third person only: the numbering of dot-spectate's `mp_forcecamera`, where 0 is also the free choice. The view is presentation (the simulation does not know which is on), but a third-person camera sees round corners, which is a competitive question, so the server decides and every client follows: the module binds the cvar with REPLICATED and the client calls `follow_cvars(link)` and re-places its camera on `changed`. `toggled(current)` is what the view key does, `resolve(wanted)` what a player gets, and `refusal()` the line for a key that did nothing. A solo game has no server; the default leaves the toggle on.

**`mp_solidplayers` (`DotPlayerBodyRules`, 1 by default).** dot-physics' shooter layout leaves players out of each other's mask, the competitive genre's choice. The play test showed the cost in every game with bots: a bot walks into you and its face fills the screen, because nothing stops two bodies sharing a place. The family's player bodies carry no collision shape (the motor sweeps a capsule of its own; hitboxes are analytic), so the rule is two halves: a player's mask has the player layer in it (`mask(base, player_layers)`), and `apply_hull` gives the body a standing capsule (`SolidHull`, disabled while the rule is off) that its own controller excludes and every other player's sweep stops at, so heads stay two radii apart. Found by mg-wipeout's `camera_check`: the mask alone let a stand-in run straight through a player; dot-core's `DotCameraFade` hides anything that still gets inside the near plane. It is part of the simulation, so it is applied on every machine and replicated: a client predicts its own player against the others' capsules where it draws them, and a disagreement of a few centimetres while two players lean on each other is reconciled. Two players that start overlapping (a shared spawn, a teleport onto somebody) are never stuck, because a sweep ignores what it starts in; they walk apart, or through each other, and are solid again once clear.

