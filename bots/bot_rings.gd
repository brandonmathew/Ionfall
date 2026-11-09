class_name BotRings
extends RefCounted
## Bot distance rings (BR plan p.5, Phase 1 prototype): every bot is classed
## by its distance to the nearest living human, and the ring decides how
## much brain it gets.
##
##   FULL   < 60 m   Today's full BotBrain, no compromises.
##   SIMPLE 60-200 m Thinks every 2nd tick (cached command on off-ticks),
##                    no grenades, no ADS/scope.
##   DOT    > 200 m  No body in the world: a dot that walks toward the map
##                    centre and fights other dots with dice rolls.
##
## A body is only removed past DOT_ENTER_RANGE (220 m) and only re-added
## inside DOT_EXIT_RANGE (180 m), so a bot on the 200 m line doesn't flicker
## between a body and a dot every tick. FULL-ring behaviour is untouched:
## a bot that never leaves FULL gets exactly the commands BotBrain makes.
## No loot tiers exist in Phase 1, so DOT fights are weighted by difficulty
## only; no zone exists yet, so dots walk toward the map centre (the mean
## of the spawn points).

enum Ring { FULL, SIMPLE, DOT }

const FULL_RANGE := 60.0
const SIMPLE_RANGE := 200.0
## Hysteresis around SIMPLE_RANGE for the expensive step (removing /
## re-adding a body): demote past 220 m, promote inside 180 m.
const DOT_ENTER_RANGE := 220.0
const DOT_EXIT_RANGE := 180.0
## SIMPLE bots think this often (in ticks); off-ticks reuse the cached command.
const SIMPLE_THINK_EVERY := 2
## DOT fights resolve on this tick cadence (60 ticks = 1 s).
const DOT_FIGHT_INTERVAL := 60
## Dots this close meet and fight.
const DOT_FIGHT_RANGE := 25.0
## How fast a dot walks toward the map centre (m/s).
const DOT_SPEED := 4.0
## Dice-roll weights by BotBrain.Difficulty (EASY, NORMAL, HARD, INSANE).
const DIFFICULTY_WEIGHTS := [1.0, 1.5, 2.0, 2.5]

var world: SimWorld

var _dots: Dictionary = {}  ## bot id -> {pos: Vector3, difficulty: int, name: String}
var _state: Dictionary = {}  ## bot id -> {ring, cached: PlayerCommand, last_delivered: PackedByteArray, disc}
var _rng := RandomNumberGenerator.new()
var _centre := Vector3.INF


func _init(p_world: SimWorld, seed_value: int = -1) -> void:
	world = p_world
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


## Re-seeds the fight RNG (tests: same seed, same fights).
func seed_rng(value: int) -> void:
	_rng.seed = value


## Which distance band `d` (metres to the nearest living human) falls in.
## No living human (INF) means FULL: with nobody to hide from, bots keep
## today's full brain.
static func ring_for_distance(d: float) -> int:
	if is_inf(d):
		return Ring.FULL
	if d < FULL_RANGE:
		return Ring.FULL
	if d < SIMPLE_RANGE:
		return Ring.SIMPLE
	return Ring.DOT


## `id`'s current ring: DOT if it is a dot, else its distance band. A bodied
## bot in the DOT band is still treated as SIMPLE until update() demotes it
## (see DOT_ENTER_RANGE); ring_stats() reports that effective ring.
func ring_of(id: int) -> int:
	if _dots.has(id):
		return Ring.DOT
	var p: SimPlayer = world.get_player(id)
	if p == null:
		return Ring.FULL
	return ring_for_distance(_nearest_human_distance(p.state.position))


## The command for one tick of a bodied bot. FULL: fresh from the driver
## every tick. SIMPLE: fresh every 2nd tick (staggered by bot id), the
## cached command on off-ticks, grenades and ADS stripped. Never returns
## null, and never returns a command the sim would read as a new press
## twice: off-tick copies carry the same press counters.
func command_for(id: int, driver: Variant, tick: int, p: SimPlayer) -> PlayerCommand:
	if driver == null or p == null:
		var n := PlayerCommand.new()
		n.tick = tick
		if p != null:
			n.set_look(p.state.yaw, p.state.pitch)
		return n
	var st := _state_for(id)
	var ring := Ring.FULL
	if p.state.alive:
		ring = ring_for_distance(_nearest_human_distance(p.state.position))
		if ring == Ring.DOT:
			ring = Ring.SIMPLE  # still bodied: SIMPLE until update() demotes it
	var think: bool = st.cached == null or st.ring != ring or st.disc != p.state.discontinuity_gen \
			or ring == Ring.FULL or (tick + id) % SIMPLE_THINK_EVERY == 0
	var c: PlayerCommand
	if think:
		c = driver.command_for(tick, p)
		if ring == Ring.SIMPLE:
			_strip_simple(c, st, p)
		if st.ring == Ring.SIMPLE and ring == Ring.FULL:
			# The brain's grenade counter ran ahead while its throws were
			# masked; tell the sim those presses were already accounted
			# for, or the first FULL command would throw the whole backlog
			# at once (up to two grenades plus an input anomaly).
			p.state.last_presses[PlayerCommand.Action.GRENADE] = c.presses[PlayerCommand.Action.GRENADE]
		st.ring = ring
		st.disc = p.state.discontinuity_gen
		st.cached = c.copy()
	else:
		c = (st.cached as PlayerCommand).copy()
		c.tick = tick
	st.last_delivered = c.presses.duplicate()
	return c


## Reclassifies every bodied bot and every dot. Returns
## {"demote": [ids], "promote": [ids]}; the caller applies them through
## the normal remove_bot / add_bot paths. Dead bots are never demoted: a
## body that is waiting to respawn must keep its body. With no living
## human, nothing moves: bots keep their bodies and dots keep drifting.
func update(_tick: int, bots: Dictionary) -> Dictionary:
	var demote: Array[int] = []
	var promote: Array[int] = []
	if _has_living_human():
		for id in bots.keys():
			var p: SimPlayer = world.get_player(id)
			if p == null or not p.state.alive:
				continue
			if _nearest_human_distance(p.state.position) > DOT_ENTER_RANGE:
				demote.append(id)
		for id in _dots.keys():
			var d: Dictionary = _dots[id]
			if _nearest_human_distance(d.pos) < DOT_EXIT_RANGE:
				promote.append(id)
	return {"demote": demote, "promote": promote}


## Current ring counts for diagnostics: bodied bots by their effective ring
## (a bodied bot past 200 m still counts as SIMPLE until it is demoted),
## plus the dots.
func ring_stats(bots: Dictionary) -> Dictionary:
	var out := {"full": 0, "simple": 0, "dot": _dots.size()}
	for id in bots.keys():
		var p: SimPlayer = world.get_player(id)
		if p == null:
			continue
		var ring := ring_for_distance(_nearest_human_distance(p.state.position))
		if ring == Ring.FULL:
			out.full += 1
		else:
			out.simple += 1
	return out


# --- DOTs ---

func register_dot(id: int, pos: Vector3, difficulty: int, bot_name: String) -> void:
	_dots[id] = {"pos": pos, "difficulty": clampi(difficulty, 0, DIFFICULTY_WEIGHTS.size() - 1),
			"name": bot_name}


func remove_dot(id: int) -> void:
	_dots.erase(id)


func has_dot(id: int) -> bool:
	return _dots.has(id)


func dot_info(id: int) -> Dictionary:
	return (_dots.get(id, {}) as Dictionary).duplicate()


func dot_position(id: int) -> Vector3:
	var d: Dictionary = _dots.get(id, {})
	return d.get("pos", Vector3.INF)


func dot_count() -> int:
	return _dots.size()


## The ids currently demoted to dots, for the roster (server_session.gd).
func dot_ids() -> Array:
	return _dots.keys()


## The map centre dots walk toward: the mean of the spawn points (no zone
## exists yet). Vector3.ZERO when the map has no spawn points.
func map_centre() -> Vector3:
	if _centre != Vector3.INF:
		return _centre
	var sum := Vector3.ZERO
	var n := 0
	for t: Transform3D in world.spawn_points:
		sum += t.origin
		n += 1
	_centre = sum / float(maxi(n, 1)) if n > 0 else Vector3.ZERO
	return _centre


## Advances the dots one tick: they drift toward the map centre, and every
## DOT_FIGHT_INTERVAL ticks pairs within DOT_FIGHT_RANGE fight. Returns the
## death events (same shape as SimWorld._kill emits) for the losers; the
## caller runs them through the normal event handling.
func tick_dots(tick: int) -> Array:
	var deaths: Array = []
	var centre := map_centre()
	for id in _dots.keys():
		var d: Dictionary = _dots[id]
		var pos: Vector3 = d.pos
		var to := centre - pos
		to.y = 0.0
		var dist := to.length()
		if dist > 0.5:
			var step := DOT_SPEED * Sim.TICK_DT
			d.pos = pos + to.normalized() * minf(step, dist)
	if tick % DOT_FIGHT_INTERVAL == 0:
		deaths = _resolve_dot_fights(tick)
	return deaths


## One dice roll per pair per fight tick, each dot fighting at most one
## opponent. The loser is removed from the dot table at once.
func _resolve_dot_fights(tick: int) -> Array:
	var deaths: Array = []
	var fought := {}
	var ids := _dots.keys()
	ids.sort()
	for a in ids:
		if fought.has(a) or not _dots.has(a):
			continue
		var da: Dictionary = _dots[a]
		var best := -1
		var best_d := DOT_FIGHT_RANGE
		for b in ids:
			if b == a or fought.has(b) or not _dots.has(b):
				continue
			var d: float = (da.pos as Vector3).distance_to((_dots[b] as Dictionary).pos)
			if d < best_d:
				best_d = d
				best = b
		if best < 0:
			continue
		fought[a] = true
		fought[best] = true
		var wa: float = DIFFICULTY_WEIGHTS[int(da.difficulty)]
		var wb: float = DIFFICULTY_WEIGHTS[int((_dots[best] as Dictionary).difficulty)]
		var a_wins := _rng.randf() < wa / (wa + wb)
		var loser: int = best if a_wins else a
		var winner: int = a if a_wins else best
		deaths.append(_dot_death_event(loser, winner, tick))
		_dots.erase(loser)
	return deaths


## A DOT death in exactly the shape SimWorld._kill emits, so stats, the
## kill feed and the wire encoding all treat it like a world death. The id
## is "dot:<victim>:<tick>": Protocol.write_event only needs three
## colon-separated parts with an integer third part (the life byte).
func _dot_death_event(victim: int, killer: int, tick: int) -> Dictionary:
	return {
		"id": "dot:%d:%d" % [victim, tick],
		"type": "death",
		"tick": tick,
		"victim": victim,
		"killer": killer,
		"weapon": &"",
		"suicide": false,
		"headshot": false,
		"environment": false,
		"assists": [],
		"position": (_dots[victim] as Dictionary).pos,
		"team_kill": false,
	}


# --- Helpers ---

func forget_bot(id: int) -> void:
	_state.erase(id)


func _state_for(id: int) -> Dictionary:
	var st: Dictionary = _state.get(id, {})
	if st.is_empty():
		st = {"ring": Ring.FULL, "cached": null, "last_delivered": null, "disc": -1}
		_state[id] = st
	return st


## SIMPLE suppression: no ADS (clear the AIM bit the brain sets for long
## shots) and no grenades (hold the press counter at the last value the
## sim saw, so the brain's throws while SIMPLE never reach the world).
func _strip_simple(c: PlayerCommand, st: Dictionary, p: SimPlayer) -> void:
	c.held &= ~PlayerCommand.Held.AIM
	var g := PlayerCommand.Action.GRENADE
	var base: int = (st.last_delivered as PackedByteArray)[g] if st.last_delivered != null \
			else p.state.last_presses[g]
	c.presses[g] = base


func _nearest_human_distance(pos: Vector3) -> float:
	var best := INF
	for other: SimPlayer in world.players.values():
		if other.is_bot or not other.state.alive:
			continue
		best = minf(best, pos.distance_to(other.state.position))
	return best


func _has_living_human() -> bool:
	for other: SimPlayer in world.players.values():
		if not other.is_bot and other.state.alive:
			return true
	return false
