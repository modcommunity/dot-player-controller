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
