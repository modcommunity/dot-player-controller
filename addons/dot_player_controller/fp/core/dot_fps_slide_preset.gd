class_name DotFpsSlidePreset
extends RefCounted

## The two slide setups games ship, as data over [DotFpsTunables]'s [code]slide_*[/code] numbers, so a game
## stops carrying its own copy. A slide stays off by default; a game calls one of these to turn it on.

## Crouch at any real run slides: a burst, then a long low-friction carry. The minimum is under a
## 5.74 m/s run, so a run slides and a crouch-walk never does (Arena's slide).
const RUN_MIN_SPEED := 4.1
const RUN_BOOST := 3.5
const RUN_MAX_SPEED := 14.0
const RUN_FRICTION := 0.9
const RUN_DURATION := 0.9
const RUN_COOLDOWN := 0.6

## Factor over [member DotFpsTunables.max_speed] a sprint slide needs: it sits above a plain run.
const SPRINT_MIN_FACTOR := 1.05


## Turns the slide on at the run preset: any run slides, no sprint needed.
static func apply_run(t: DotFpsTunables) -> void:
	t.slide_enabled = true
	t.slide_min_speed = RUN_MIN_SPEED
	t.slide_boost = RUN_BOOST
	t.slide_max_speed = RUN_MAX_SPEED
	t.slide_friction = RUN_FRICTION
	t.slide_duration = RUN_DURATION
	t.slide_cooldown = RUN_COOLDOWN


## Only a sprinter holding crouch slides (Zombie Zone's slide): [code]slide_requires_sprint[/code] wants the
## sprint button and the minimum speed is [constant SPRINT_MIN_FACTOR] over [member DotFpsTunables.max_speed],
## so set [code]max_speed[/code] first. [param p_enabled] is the game's switch; friction stays at the default.
static func apply_sprint(
	t: DotFpsTunables, p_enabled: bool, p_boost: float, p_max_speed: float, p_duration: float, p_cooldown: float
) -> void:
	t.slide_enabled = p_enabled
	t.slide_requires_sprint = true
	t.slide_min_speed = t.max_speed * SPRINT_MIN_FACTOR
	t.slide_boost = p_boost
	t.slide_max_speed = p_max_speed
	t.slide_duration = p_duration
	t.slide_cooldown = p_cooldown
