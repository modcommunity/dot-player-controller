extends RefCounted

## dot-player-controller's API level. The rule for bumping it is on dot-core's DotAddonApi.
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning.

# 1: everything before this file existed.
# 2: DotPlayerViewRules (mp_forceview) and DotPlayerBodyRules (mp_solidplayers: mask(),
#    apply_to(), apply_hull()); DotFpsBody.pass_out_mask, DotFpsController.set_pass_out_layers;
#    DotTpsCameraRig's arm is a dot-core DotCameraBoom (same spring_length, margin,
#    collision_mask, add_excluded_object), fade_mask/set_fade_mask() and its fade.
# 3: DotFpsSimulator (a second motor over a copy of a player's body: step, command, oracle,
#    mechanics, EVENT_*), DotFpsController.simulator(), DotFpsBody.copy_for_simulation() and
#    copy_filters_to() (flat and physics bodies copy themselves).
# 4: DotFpsViewMotion.body_roll()/body_yaw() and wall_run_body_roll/_yaw/_response (the pose of
#    a drawn body on a wall), exported on DotFpsView.
# 5: DotFpsSampler latches button presses between samples (handle_event takes every event,
#    sample() also polls is_action_just_pressed once a frame), so a mouse-wheel tick on jump
#    is one press of jump in a command.
# 6: DotFpsLadderMode (volumes, climb_speed, jump_off_speed, reach, update()).
# 7: DotFpsSwimMode.friction/set_cvar/cvar_specs (sv_wateraccelerate, sv_waterfriction) and
#    DotFpsLadderMode.dampen/set_cvar/cvar_specs (sv_ladder_dampen).
const LEVEL := 7
const OLDEST := 1
