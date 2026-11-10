# API levels

Moved from `dot_player_controller_api.gd`; one line per level, newest last. The rule for bumping is on dot-core's `DotAddonApi`.

- 1: everything before this file existed.
- 2: DotPlayerViewRules (mp_forceview) and DotPlayerBodyRules (mp_solidplayers: mask(), apply_to(), apply_hull()); DotFpsBody.pass_out_mask, DotFpsController.set_pass_out_layers; DotTpsCameraRig's arm is a dot-core DotCameraBoom (same spring_length, margin, collision_mask, add_excluded_object), fade_mask/set_fade_mask() and its fade.
- 3: DotFpsSimulator (a second motor over a copy of a player's body: step, command, oracle, mechanics, EVENT_*), DotFpsController.simulator(), DotFpsBody.copy_for_simulation() and copy_filters_to() (flat and physics bodies copy themselves).
- 4: DotFpsViewMotion.body_roll()/body_yaw() and wall_run_body_roll/_yaw/_response (the pose of a drawn body on a wall), exported on DotFpsView.
- 5: DotFpsSampler latches button presses between samples (handle_event takes every event, sample() also polls is_action_just_pressed once a frame), so a mouse-wheel tick on jump is one press of jump in a command.
- 6: DotFpsLadderMode (volumes, climb_speed, jump_off_speed, reach, update()).
- 7: DotFpsSwimMode.friction/set_cvar/cvar_specs (sv_wateraccelerate, sv_waterfriction) and DotFpsLadderMode.dampen/set_cvar/cvar_specs (sv_ladder_dampen).
- 8: DotFpsCvars (fp/core): binds the cvar_specs of tunables, swim and ladder to a console, and map_config_keys() for DotGameMapConfig.
- 9: DotPlayerBodyRules.pair_fn/blocks()/refresh()/apply_exceptions() and DotFpsController.set_extra_excludes(): per-pair pass-through (dot-team's mp_teamblock).
- 10: DotFpsNetSync.rewind_specs()/pack_timers()/unpack_timers(): the jump timers in net_timers.
- 11: DotFpsSprintRules (sprint and stamina cvars as one live group), DotFpsTunables.sprint_toggle (sv_sprint_toggle, applied by DotFpsSampler), and `sprinting`/`sprint_blocks_aim` in motion().
- 12: DotPlayerController.apply_external_velocity(dv): a push (tornado, explosion) the controller keeps.
- 13: DotPlayerViewRules.first_person_body (BODY_OFF, BODY_LEGS, BODY_FULL), own_body(choice) and the `mp_fp_body` cvar (off, legs and feet, whole body; default legs). `mp_fp_legs` is still accepted by set_cvar but no longer registered; `first_person_legs` reads the new value.
- 14: `DotFpsMotor.idle_fast_path`, `idle_full_every` and `idle_ticks`: a cheap tick for a settled, idle, grounded body that wakes on any change (docs/collision.md).
- 15: `DotFpsPhysicsBody.cost_system`: while dot-core's `DotFrameCost` is enabled (dot-core level 30), every script-path query and each native slide, sweep and rest call is charged to it by kind, so dot-profiler's query table shows the controller's collision work.
- 16: `DotFpsMotor.native_tick` and `native_full`: a player tick in one native dot-sim call (halves, or the whole tick with `native_full`), bit-identical to the script; `DotFpsBody.native_tick` is the hook a body answers it through.
- 17: `DotFpsBody.set_hull_world(world, slot)` (hulls from dot-sim's `DotSimHullWorld`, mode 3) and its hull-body and physics-body overrides; a no-op returning false without the library.
- 18: a settled body (`reuse_settled_ground`, native start included) no longer keeps its ground stamp for ever when it stands still: a start check that reused the stamp does not excuse the end check, so a floor removed under it is noticed within two ticks. No new API; a game that needs the fix guards on this level. With `native_full` the fix is in dot-sim's `full.rs`, so the library must be dot-sim v0.2.2 or newer (an older library keeps the stale stamp; the script path is correct at any version, and `motor_native_tick_parity` fails against an older library).
- 19: `DotFpsMotorBatch` (`start`, `add`, `finish`, `skip`, `moved_after`): every player's motor tick of a game tick in one dot-sim call (`DotSimMotorBatch`), bit-identical to ticking them one by one; with it `DotFpsController.begin_tick` and `end_tick` (a tick's start and end around a batched motor step), `has_external_velocity`, and `DotFpsBody.native_batch` and `native_batch_done`, the hooks a body joins a batch through.
- 20: `DotFpsController.phase_timers` (static): fills `phase_us` without `DotFpsMotor.profile`, which also switches the native motor off, so a bench times the controller's phases on the path players really run.
- 21: `DotFpsSlidePreset` (`apply_run`, `apply_sprint`): the two slide setups Arena and Zombie Zone each carried, as shared data over `DotFpsTunables.slide_*`.
