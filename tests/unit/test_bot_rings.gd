extends GutTest
## Bot distance rings (bots/bot_rings.gd, BR plan p.5): ring boundaries,
## SIMPLE think cadence and suppression, DOT drift and dice-roll fights,
## promotion/demotion, and the server hook (net/server_session.gd).

var world: SimWorld
var nav: BotNavigation
var arena: Node3D
var rings: BotRings


## A driver that counts command_for calls and, on request, throws a
## grenade and aims down sights on every think — like a BotBrain in a
## fight, but with the behaviour under test control.
class CountingDriver extends RefCounted:
	var calls := 0
	var throw_grenades := false
	var _presses := PackedByteArray([0, 0, 0, 0, 0, 0, 0])

	func command_for(tick: int, p: SimPlayer) -> PlayerCommand:
		calls += 1
		var c := PlayerCommand.new()
		c.tick = tick
		if p != null:
			c.set_look(p.state.yaw, 0.0)
		c.set_move(Vector2(0.0, 1.0))
		if throw_grenades:
			_presses[PlayerCommand.Action.GRENADE] = (_presses[PlayerCommand.Action.GRENADE] + 1) & 0xFF
		c.presses = _presses.duplicate()
		c.held |= PlayerCommand.Held.AIM
		return c

	func grenade_presses() -> int:
		return _presses[PlayerCommand.Action.GRENADE]


func before_each() -> void:
	arena = SimHarness.make_arena()
	add_child_autofree(arena)
	await wait_physics_frames(2)
	world = SimHarness.make_world(5)
	add_child_autofree(world)
	rings = BotRings.new(world, 1234)


func _build_nav() -> void:
	nav = BotNavigation.new()
	add_child_autofree(nav)
	await nav.build(arena)


func _add_human(id: int, pos: Vector3) -> SimPlayer:
	var p := world.add_player(id, Loadouts.ffa(), "Human %d" % id, false)
	SimHarness.place(p, pos, 0.0)
	return p


func _add_bot(id: int, pos: Vector3, difficulty: int = BotBrain.Difficulty.NORMAL) -> BotBrain:
	var p := world.add_player(id, Loadouts.ffa(), "Bot %d" % id, true)
	SimHarness.place(p, pos, 0.0)
	return BotBrain.new(world, nav, id, 100 + id, difficulty)


## Runs `ticks` rings ticks for one bot, stepping the world with the
## commands the rings produce; returns every drained event.
func _run_bot(id: int, driver: Variant, ticks: int) -> Array:
	var events: Array = []
	var p := world.get_player(id)
	for t in ticks:
		var cmd := rings.command_for(id, driver, world.tick, p)
		world.step({id: cmd})
		events.append_array(world.drain_events())
	return events


# --- Ring boundaries ---

func test_ring_boundaries() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	world.add_player(1000, Loadouts.ffa(), "Bot", true)
	var cases := [
		[59.0, BotRings.Ring.FULL], [60.0, BotRings.Ring.SIMPLE],
		[199.0, BotRings.Ring.SIMPLE], [200.0, BotRings.Ring.DOT],
		[201.0, BotRings.Ring.DOT],
	]
	for c in cases:
		SimHarness.place(world.get_player(1000), Vector3(c[0], 0.05, 0), 0.0)
		assert_eq(rings.ring_of(1000), c[1], "%.0f m from the nearest human" % c[0])


func test_ring_uses_nearest_human() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	_add_human(2, Vector3(100, 0.05, 0))
	world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(world.get_player(1000), Vector3(150, 0.05, 0), 0.0)
	assert_eq(rings.ring_of(1000), BotRings.Ring.FULL, "50 m from human 2, 150 m from human 1")


func test_no_living_human_means_full() -> void:
	world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(world.get_player(1000), Vector3(500, 0.05, 0), 0.0)
	assert_eq(rings.ring_of(1000), BotRings.Ring.FULL, "no human to hide from: full brain")


func test_dead_humans_do_not_count() -> void:
	var h := _add_human(1, Vector3(0, 0.05, 0))
	world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(world.get_player(1000), Vector3(59, 0.05, 0), 0.0)
	assert_eq(rings.ring_of(1000), BotRings.Ring.FULL, "59 m from a living human")
	h.state.alive = false
	assert_eq(rings.ring_of(1000), BotRings.Ring.FULL, "dead human ignored (falls back to FULL)")


# --- SIMPLE cadence ---

func test_simple_cadence_halves_driver_calls() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(100, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	for t in 60:
		rings.command_for(1000, driver, t, bot)
	assert_eq(driver.calls, 30, "SIMPLE bot thinks every 2nd tick")


func test_full_cadence_calls_every_tick() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(10, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	for t in 60:
		rings.command_for(1000, driver, t, bot)
	assert_eq(driver.calls, 60, "FULL bot thinks every tick")


func test_simple_off_tick_reuses_cached_command() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(100, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	var c0 := rings.command_for(1000, driver, 0, bot)  # think: (0 + 1000) % 2 == 0
	var c1 := rings.command_for(1000, driver, 1, bot)  # off-tick
	assert_eq(driver.calls, 1, "off-tick does not call the driver")
	assert_eq(c1.tick, 1, "cached command carries the current tick")
	assert_eq(c1.move_y, c0.move_y, "cached command keeps moving the bot")
	assert_eq(c1.view_yaw, c0.view_yaw, "cached command keeps the bot's aim")
	assert_true(c1 != c0, "off-tick returns a copy, not the cached object itself")


func test_real_brain_survives_simple_cadence() -> void:
	await _build_nav()
	_add_human(1, Vector3(0, 0.05, 0))
	var brain := _add_bot(1000, Vector3(100, 0.05, 0))
	var bot := world.get_player(1000)
	for t in 60:
		var cmd := rings.command_for(1000, brain, t, bot)
		assert_true(cmd != null, "SIMPLE never leaves a bot command-less")
		world.step({1000: cmd})
		world.drain_events()
	assert_true(bot.state.alive, "SIMPLE bot still alive after 1 s at half think rate")


# --- SIMPLE suppression ---

func test_simple_suppression_strips_grenade_and_aim() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(100, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	driver.throw_grenades = true
	var delivered_grenade := -1
	for t in 60:
		var cmd := rings.command_for(1000, driver, t, bot)
		assert_false(cmd.is_held(PlayerCommand.Held.AIM), "SIMPLE: no ADS/scope (tick %d)" % t)
		if delivered_grenade < 0:
			delivered_grenade = cmd.presses[PlayerCommand.Action.GRENADE]
		assert_eq(cmd.presses[PlayerCommand.Action.GRENADE], delivered_grenade,
				"SIMPLE: grenade press counter never advances (tick %d)" % t)
	assert_gt(driver.grenade_presses(), 0, "the driver really tried to throw grenades")


func test_full_does_not_suppress() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(10, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	driver.throw_grenades = true
	var last := rings.command_for(1000, driver, 0, bot)
	assert_true(last.is_held(PlayerCommand.Held.AIM), "FULL keeps ADS")
	assert_gt(last.presses[PlayerCommand.Action.GRENADE], 0, "FULL keeps grenade throws")


## The backlog case: a SIMPLE bot's masked grenade throws must not fire all
## at once when it steps back up to FULL.
func test_simple_to_full_grenade_backlog_is_discarded() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(100, 0.05, 0), 0.0)
	var driver := CountingDriver.new()
	driver.throw_grenades = true
	var grenades_at_start := bot.state.grenades
	assert_gt(grenades_at_start, 0, "bot spawns with grenades to lose")
	# 1 s in SIMPLE, throwing (and being masked) every think tick.
	var events := _run_bot(1000, driver, 60)
	assert_eq(events.filter(func(e: Dictionary) -> bool: return e.type == "fire" and e.weapon == &"frag_grenade").size(),
			0, "no grenade fires while SIMPLE")
	assert_eq(bot.state.grenades, grenades_at_start, "no grenades spent while SIMPLE")
	assert_gt(driver.grenade_presses(), 10, "the driver attempted many throws while SIMPLE")
	# Step up to FULL with no new throws attempted: nothing may fire now.
	SimHarness.place(bot, Vector3(0, 0.05, 17), 0.0)
	driver.throw_grenades = false
	events = _run_bot(1000, driver, 120)
	assert_eq(events.filter(func(e: Dictionary) -> bool: return e.type == "fire" and e.weapon == &"frag_grenade").size(),
			0, "no phantom grenade on promotion to FULL")
	assert_eq(bot.state.grenades, grenades_at_start, "no grenades spent by the backlog")
	assert_eq(bot.state.input_anomalies, 0, "no input anomaly from the discarded backlog")


# --- DOTs ---

func test_dot_drifts_toward_map_centre() -> void:
	rings.register_dot(1000, Vector3(100, 0, 0), BotBrain.Difficulty.NORMAL, "Dot")
	var before := rings.dot_position(1000).distance_to(rings.map_centre())
	for t in 60:
		rings.tick_dots(t)
	var after := rings.dot_position(1000).distance_to(rings.map_centre())
	assert_lt(after, before, "dot walks toward the centre")
	assert_almost_eq(before - after, 4.0, 0.3, "about 4 m in 1 s at DOT_SPEED")


func test_dot_fight_kills_loser() -> void:
	var r: BotRings = BotRings.new(world, 42)
	r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.NORMAL, "A")
	r.register_dot(1001, Vector3(5, 0, 0), BotBrain.Difficulty.NORMAL, "B")
	var deaths := r.tick_dots(60)  # a fight tick
	assert_eq(deaths.size(), 1, "two dots in range: one fight, one death")
	var d: Dictionary = deaths[0]
	assert_eq(d.type, "death")
	assert_false(d.suicide, "a DOT fight is not a suicide")
	assert_eq(d.weapon, &"", "DOT fights have no weapon")
	assert_true(r.has_dot(d.killer), "winner stays a dot")
	assert_false(r.has_dot(d.victim), "loser leaves the dot table")


func test_dot_death_event_matches_world_shape() -> void:
	var r: BotRings = BotRings.new(world, 9)
	r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.NORMAL, "A")
	r.register_dot(1001, Vector3(5, 0, 0), BotBrain.Difficulty.NORMAL, "B")
	var deaths := r.tick_dots(60)
	assert_eq(deaths.size(), 1)
	var d: Dictionary = deaths[0]
	for key in ["id", "type", "tick", "victim", "killer", "weapon", "suicide", "headshot",
			"environment", "assists", "position", "team_kill"]:
		assert_true(d.has(key), "death event carries %s" % key)
	# It must survive the exact wire format the server sends to clients.
	var w := Wire.Writer.new()
	assert_true(Protocol.write_event(w, d), "DOT death encodes on the wire")
	var back := Protocol.read_event(Wire.Reader.new(w.data()))
	assert_eq(back.type, "death")
	assert_eq(back.victim, d.victim, "wire round-trip keeps the victim")
	assert_eq(back.killer, d.killer, "wire round-trip keeps the killer")


func test_dot_fight_determinism_with_seed() -> void:
	var outcome := func() -> Array:
		var r: BotRings = BotRings.new(world, 777)
		r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.NORMAL, "A")
		r.register_dot(1001, Vector3(10, 0, 0), BotBrain.Difficulty.HARD, "B")
		r.register_dot(1002, Vector3(20, 0, 0), BotBrain.Difficulty.EASY, "C")
		return r.tick_dots(60)
	assert_eq(outcome.call(), outcome.call(), "same seed, same fights")


func test_dot_fight_weights_difficulty() -> void:
	var hard_wins := 0
	var trials := 300
	for i in trials:
		var r: BotRings = BotRings.new(world, i * 7919 + 13)
		r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.HARD, "Hard")
		r.register_dot(1001, Vector3(5, 0, 0), BotBrain.Difficulty.EASY, "Easy")
		var deaths := r.tick_dots(60)
		assert_eq(deaths.size(), 1, "trial %d: one fight" % i)
		if (deaths[0] as Dictionary).killer == 1000:
			hard_wins += 1
	gut.p("HARD vs EASY over %d fights: HARD won %d (%.0f%%, weights say 67%%)" % [trials, hard_wins,
			100.0 * hard_wins / trials])
	assert_gt(hard_wins, trials * 58 / 100, "HARD wins clearly more often than EASY")


func test_dots_only_fight_in_range() -> void:
	var r: BotRings = BotRings.new(world, 5)
	r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.NORMAL, "A")
	r.register_dot(1001, Vector3(100, 0, 0), BotBrain.Difficulty.NORMAL, "B")
	assert_eq(r.tick_dots(60), [], "100 m apart: no fight")
	r.register_dot(1002, Vector3(110, 0, 0), BotBrain.Difficulty.NORMAL, "C")
	assert_eq(r.tick_dots(120).size(), 1, "10 m apart: they fight")


func test_dots_do_not_fight_off_the_slow_tick() -> void:
	var r: BotRings = BotRings.new(world, 5)
	r.register_dot(1000, Vector3(0, 0, 0), BotBrain.Difficulty.NORMAL, "A")
	r.register_dot(1001, Vector3(5, 0, 0), BotBrain.Difficulty.NORMAL, "B")
	for t in range(1, 60):
		assert_eq(r.tick_dots(t), [], "no fights between slow ticks (tick %d)" % t)


# --- Promotion / demotion ---

func test_bot_demotes_when_far_from_humans() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var bot := world.add_player(1000, Loadouts.ffa(), "Bot", true)
	SimHarness.place(bot, Vector3(100, 0.05, 0), 0.0)
	var bots := {1000: CountingDriver.new()}
	assert_eq(rings.update(0, bots).demote, [], "100 m: stays bodied")
	SimHarness.place(bot, Vector3(250, 0.05, 0), 0.0)
	assert_eq(rings.update(1, bots).demote, [1000], "250 m: demoted to a dot")
	assert_eq(rings.update(2, bots).demote, [1000], "still demoted while far (hysteresis holds past 220 m)")
	SimHarness.place(bot, Vector3(210, 0.05, 0), 0.0)
	assert_eq(rings.update(3, bots).demote, [], "210 m: inside the 220 m demote line, keeps its body")


func test_dot_promotes_when_human_approaches() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	rings.register_dot(1000, Vector3(300, 0.05, 0), BotBrain.Difficulty.NORMAL, "Dot")
	var bots := {}
	assert_eq(rings.update(0, bots).promote, [], "dot 300 m away stays a dot")
	SimHarness.place(world.get_player(1), Vector3(100, 0.05, 0), 0.0)
	assert_eq(rings.update(1, bots).promote, [], "200 m away: outside the 180 m promote line")
	SimHarness.place(world.get_player(1), Vector3(130, 0.05, 0), 0.0)
	assert_eq(rings.update(2, bots).promote, [1000], "170 m away: inside the 180 m promote line")


func test_ring_stats_counts() -> void:
	_add_human(1, Vector3(0, 0.05, 0))
	var b1 := world.add_player(1000, Loadouts.ffa(), "Near", true)
	var b2 := world.add_player(1001, Loadouts.ffa(), "Mid", true)
	SimHarness.place(b1, Vector3(10, 0.05, 0), 0.0)
	SimHarness.place(b2, Vector3(100, 0.05, 0), 0.0)
	rings.register_dot(1002, Vector3(300, 0.05, 0), BotBrain.Difficulty.NORMAL, "Far")
	var bots := {1000: CountingDriver.new(), 1001: CountingDriver.new()}
	assert_eq(rings.ring_stats(bots), {"full": 1, "simple": 1, "dot": 1})


# --- Server hook ---

func _make_server(bot_count: int) -> ServerSession:
	var server := ServerSession.new()
	add_child_autofree(server)
	assert_eq(server.start(-1, SimHarness.MOVEMENT, SimHarness.loadout(), TestArenaLayout.spawn_points()), OK)
	server.max_combatants = 50
	server.bot_count = bot_count
	server.rings_enabled = true
	server.add_local_player("Host")
	return server


func test_rings_off_by_default() -> void:
	var server := ServerSession.new()
	add_child_autofree(server)
	assert_eq(server.start(-1, SimHarness.MOVEMENT, SimHarness.loadout(), TestArenaLayout.spawn_points()), OK)
	assert_false(server.rings_enabled, "rings off unless the BR test match turns them on")
	assert_eq(server.ring_stats(), {"full": 0, "simple": 0, "dot": 0})


func test_server_demotes_and_promotes_bots() -> void:
	var server := _make_server(3)
	for t in 2:
		server._physics_process(0.0)
	assert_eq(server.bots.size(), 3)
	assert_eq(server.ring_stats(), {"full": 3, "simple": 0, "dot": 0})
	# One bot walks 250 m from the human: it becomes a dot.
	var far_id: int = server.bots.keys()[0]
	SimHarness.place(server.world.get_player(far_id), Vector3(250, 0.05, 0), 0.0)
	for t in 5:
		server._physics_process(0.0)
	assert_eq(server.bots.size(), 2, "far bot demoted to a dot")
	assert_eq(server.rings.dot_count(), 1)
	assert_eq(server.ring_stats(), {"full": 2, "simple": 0, "dot": 1})
	assert_false(server.world.players.has(far_id), "dot has no body in the world")
	# The human walks to 100 m from the dot (and stays near the other bots):
	# the dot spawns back in with the same id and name.
	SimHarness.place(server.world.get_player(1), Vector3(100, 0.05, 0), 0.0)
	for t in 5:
		server._physics_process(0.0)
	assert_eq(server.bots.size(), 3, "dot promoted back to a body")
	assert_eq(server.rings.dot_count(), 0)
	assert_true(server.world.players.has(far_id), "same net id on the way back")
	assert_eq(server.world.get_player(far_id).display_name,
			server.stats.lines[far_id].name, "same name on the way back")


func test_server_dot_death_flows_through_stats_and_host_events() -> void:
	var server := _make_server(0)
	server._physics_process(0.0)  # creates the rings
	server.rings.register_dot(1000, Vector3(300, 0, 0), BotBrain.Difficulty.NORMAL, "DotA")
	server.rings.register_dot(1001, Vector3(305, 0, 0), BotBrain.Difficulty.NORMAL, "DotB")
	# As demoted bots, they already have stats lines (left when demoted).
	server.stats.add_player(1000, "DotA", true, server.world.tick)
	server.stats.add_player(1001, "DotB", true, server.world.tick)
	for t in 65:
		server._physics_process(0.0)
	var deaths := server.drain_host_events().filter(
			func(e: Dictionary) -> bool: return e.type == "death")
	assert_eq(deaths.size(), 1, "exactly one DOT fight in 65 ticks (one slow tick)")
	var d: Dictionary = deaths[0]
	assert_true(server.rings.dot_count() == 1, "loser left the dot table")
	assert_eq((server.stats.lines[d.victim] as MatchStats.Line).deaths, 1, "victim's death counted")
	assert_eq((server.stats.lines[d.killer] as MatchStats.Line).kills, 1, "killer's kill counted")


# --- Chunked navmesh (Drop Zone, BR Phase 1) ---

## Builds BotNavigation on the full drop_zone gameplay scene (16 chunk
## bodies). Returns [gameplay, nav]; both are autofree'd.
func _build_drop_zone_nav() -> Array:
	var gameplay := Maps.gameplay("drop_zone")
	add_child_autofree(gameplay)
	await wait_physics_frames(2)
	var dz_nav := BotNavigation.new()
	add_child_autofree(dz_nav)
	await dz_nav.build(gameplay)
	return [gameplay, dz_nav]


func test_chunked_navmesh_builds_on_drop_zone() -> void:
	var built := await _build_drop_zone_nav()
	var dz_nav: BotNavigation = built[1]
	assert_true(dz_nav.chunked, "drop_zone bakes per chunk, not one 800 m mesh")
	assert_eq(dz_nav.navmeshes.size(), 16, "one navmesh per chunk")
	assert_eq(dz_nav.regions.size(), 16, "one region per chunk")
	assert_true(dz_nav.ready_for_queries, "chunked nav is ready for queries")
	assert_eq(dz_nav.bake_timings_ms.size(), 16, "one bake timing per chunk")
	var total_polys := 0
	for m in dz_nav.navmeshes:
		assert_gt(m.get_polygon_count(), 0, "every chunk bakes polygons")
		total_polys += m.get_polygon_count()
	assert_gt(total_polys, 100, "island navmesh has substance, got %d polys" % total_polys)
	gut.p("chunk bake: total %.0f ms, slowest chunk %.0f ms, %d polys" % [
			dz_nav.bake_total_ms, dz_nav.bake_timings_ms.max(), total_polys])
	assert_lt(dz_nav.bake_total_ms, 20000.0,
			"full-island bake fits a phone budget (~20 s), got %.0f ms" % dz_nav.bake_total_ms)


func test_cross_chunk_paths() -> void:
	var built := await _build_drop_zone_nav()
	var dz_nav: BotNavigation = built[1]
	# Short hop across the x = -200 seam (chunk C0 -> C1).
	var hop := dz_nav.path(Vector3(-205, 0.05, -350), Vector3(-195, 0.05, -350))
	assert_false(hop.is_empty(), "path crosses the chunk seam at x = -200")
	assert_lt((hop[-1][0] as Vector3).distance_to(Vector3(-195, 0.05, -350)), 5.0,
			"seam hop ends near its target")
	# Long diagonal across the whole island (chunk C0 -> C15), through the crater.
	var diag := dz_nav.path(Vector3(-350, 0.05, -350), Vector3(350, 0.05, 350))
	assert_false(diag.is_empty(), "path crosses the island corner to corner")
	assert_lt((diag[-1][0] as Vector3).distance_to(Vector3(350, 0.05, 350)), 5.0,
			"diagonal ends near its target")
	# The Hydro centre pad's slab top must actually bake (regression: with
	# the box triangles wound the wrong way it baked to 2 polygons and the
	# diagonal died at the crater; correct winding gives ~60 slab-top polys).
	var c10: NavigationMesh = dz_nav.navmeshes[10]
	var verts := c10.get_vertices()
	var slab_top := 0
	for i in c10.get_polygon_count():
		var poly := c10.get_polygon(i)
		var c := Vector3.ZERO
		for idx in poly:
			c += verts[idx]
		c /= poly.size()
		if c.x >= 178.5 and c.x <= 191.5 and c.z >= 178.5 and c.z <= 191.5 \
				and c.y > 0.9 and c.y < 1.1:
			slab_top += 1
	assert_gt(slab_top, 10, "Hydro centre pad slab top bakes (got %d polys)" % slab_top)
	# Foundry quarter to the Spire: chunk C11 -> C6. The target is a real
	# spawn point inside the Spire district rect (the district centre
	# itself sits inside Spire structure, with no navmesh under it).
	# Start on the Foundry floor south of the crucible: the quarter centre
	# (250, 0) is inside the crucible box and on the z = 0 seam, so a path
	# from there snaps to the sealed floor pocket under the crucible.
	var spire_target := Vector3(185, 0.05, -185)
	for t: Transform3D in DropZoneLayout.spawn_points():
		var p: Vector3 = t.origin
		if p.x >= 140.0 and p.x <= 230.0 and p.z >= -230.0 and p.z <= -140.0:
			spire_target = p
			break
	var leg := dz_nav.path(Vector3(250, 0.05, 15), spire_target)
	assert_false(leg.is_empty(), "path from the Foundry quarter to the Spire")
	assert_lt((leg[-1][0] as Vector3).distance_to(spire_target), 5.0,
			"quarter-to-Spire ends near its target")


func test_chunked_navmesh_has_traversal_links() -> void:
	var built := await _build_drop_zone_nav()
	var dz_nav: BotNavigation = built[1]
	var kinds := {}
	for l in dz_nav.links:
		kinds[l.get_meta("traversal")] = true
	gut.p("chunked links: %d" % dz_nav.links.size())
	assert_gt(dz_nav.links.size(), 0, "island navmesh generates traversal links")
	assert_true(kinds.has(BotNavigation.Traversal.JUMP_MANTLE) or kinds.has(BotNavigation.Traversal.DROP),
			"island has climb or drop links")


# --- DOT live verification on the full island ---

## A rings-on server on drop_zone spawns (no bot_nav: TargetDummyDriver
## bodies, so the test exercises the rings, not BotBrain pathing). The
## drop_zone gameplay scene is in the tree first: without real ground
## under them the players fall past SimWorld.KILL_Y (-30 m) and die as
## environment deaths, which would pollute the DOT death count.
func _make_island_server(bot_count: int) -> ServerSession:
	var gameplay := Maps.gameplay("drop_zone")
	add_child_autofree(gameplay)
	await wait_physics_frames(2)
	var server := ServerSession.new()
	add_child_autofree(server)
	assert_eq(server.start(-1, SimHarness.MOVEMENT, SimHarness.loadout(), DropZoneLayout.spawn_points()), OK)
	server.max_combatants = 50
	server.bot_count = bot_count
	server.rings_enabled = true
	server.add_local_player("Host")
	return server


func _step_server(server: ServerSession, ticks: int) -> void:
	for t in ticks:
		server._physics_process(0.0)


func test_island_dots_demoted_fight_and_score() -> void:
	var server := await _make_island_server(4)
	var human := server.world.get_player(1)
	SimHarness.place(human, Vector3(250, 0.05, 0), 0.0)
	var ids: Array = server.bots.keys()
	ids.sort()
	assert_eq(ids.size(), 4, "four bots on the island")
	# A fighting pair far from the human, one lone far bot, one near bot.
	SimHarness.place(server.world.get_player(ids[0]), Vector3(-300, 0.05, -300), 0.0)
	SimHarness.place(server.world.get_player(ids[1]), Vector3(-295, 0.05, -300), 0.0)
	SimHarness.place(server.world.get_player(ids[2]), Vector3(300, 0.05, 300), 0.0)
	SimHarness.place(server.world.get_player(ids[3]), Vector3(260, 0.05, 0), 0.0)
	_step_server(server, 5)
	assert_eq(server.ring_stats(), {"full": 1, "simple": 0, "dot": 3},
			"three far bots demoted to dots, the near bot stays bodied")
	assert_eq(server.rings.dot_count(), 3)
	# DOT fights resolve on the 60-tick slow tick: the close pair meets
	# within a few seconds while the lone dot walks alone.
	_step_server(server, 130)
	var deaths := server.drain_host_events().filter(
			func(e: Dictionary) -> bool: return e.type == "death")
	assert_eq(deaths.size(), 1, "exactly one DOT fight death in ~2 s")
	var d: Dictionary = deaths[0]
	assert_true([ids[0], ids[1]].has(d.victim) and [ids[0], ids[1]].has(d.killer),
			"the close pair fought, not the lone dot")
	assert_false(d.suicide, "a DOT fight is not a suicide")
	assert_eq((server.stats.lines[d.victim] as MatchStats.Line).deaths, 1, "victim's death counted")
	assert_eq((server.stats.lines[d.killer] as MatchStats.Line).kills, 1, "killer's kill counted")
	# Kill feed: the roster must name the dot killer, not "?".
	var row := server.roster().filter(func(r: Dictionary) -> bool: return r.id == d.killer)
	assert_eq(row.size(), 1, "dot killer is on the roster")
	assert_eq(row[0].name, (server.stats.lines[d.killer] as MatchStats.Line).name,
			"roster names the dot killer (kill feed shows the name, not '?')")
	assert_eq(row[0].score, 1, "DOT kill scores on the roster")
	# Promote the killer back: its world score carries the DOT kill.
	var killer_pos := server.rings.dot_position(d.killer)
	SimHarness.place(human, Vector3(killer_pos.x + 100.0, 0.05, killer_pos.z), 0.0)
	_step_server(server, 5)
	assert_true(server.world.players.has(d.killer), "killer promoted back to a body")
	assert_eq(server.world.scores[d.killer], 1, "DOT kill survives promotion into world.scores")


func test_island_dot_promotion_restores_bodied_score() -> void:
	var server := await _make_island_server(1)
	var human := server.world.get_player(1)
	SimHarness.place(human, Vector3(250, 0.05, 0), 0.0)
	var id: int = server.bots.keys()[0]
	# The bot earns a bodied kill first (world score 1), then demotes.
	server.world.scores[id] = 1
	SimHarness.place(server.world.get_player(id), Vector3(-300, 0.05, -300), 0.0)
	_step_server(server, 5)
	assert_eq(server.rings.dot_count(), 1, "bot demoted")
	assert_eq(server.roster().filter(func(r: Dictionary) -> bool: return r.id == id)[0].score, 1,
			"bodied score still on the roster while a dot")
	SimHarness.place(human, Vector3(-200, 0.05, -300), 0.0)
	_step_server(server, 5)
	assert_true(server.world.players.has(id), "bot promoted back")
	assert_eq(server.world.scores[id], 1, "bodied score survives demote/promote")
