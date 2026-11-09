extends GutTest
## Spawn scaling (BR Phase 1 phone stall, 2026-11-08): _choose_spawn used
## to score EVERY spawn point against EVERY player with a physics
## raycast per pair — on Drop Zone (25,050 points) that is ~30M raycasts
## to fill a 50-bot match, all on the main thread inside match startup,
## which froze the loading screen (each bot took longer than the last:
## 0.3 s for bot 1, 2.1 s by bot 23). The pick now scores a random
## sample of at most SPAWN_EVAL_MAX points and only raycasts enemies
## within SPAWN_SIGHT_RANGE.


## A Drop Zone-sized spawn list: 5 m grid over 800×800 m.
func _big_spawn_list() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for x in range(-400, 401, 5):
		for z in range(-400, 401, 5):
			out.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.0, z)))
	return out


func test_filling_25_players_on_25k_spawns_is_fast_and_spread() -> void:
	var world := SimHarness.make_world()
	world.spawn_points = _big_spawn_list()
	add_child_autofree(world)
	await wait_physics_frames(2)
	var t0 := Time.get_ticks_msec()
	var seen := {}
	for i in 25:
		var p := world.add_player(1000 + i, SimHarness.loadout(), "bot%d" % i, true)
		assert_true(p.state.alive, "bot %d spawned alive" % i)
		seen[p.state.position] = true
	var ms := Time.get_ticks_msec() - t0
	gut.p("25 spawns on %d points took %d ms" % [world.spawn_points.size(), ms])
	assert_lt(ms, 10000, "25 picks stay fast (was minutes before the fix)")
	assert_eq(seen.size(), 25, "every bot landed on a different spawn point")


func test_small_maps_still_score_every_point() -> void:
	var world := SimHarness.make_world()
	add_child_autofree(world)
	await wait_physics_frames(2)
	# Test arena: fewer points than SPAWN_EVAL_MAX, so the sample is all.
	assert_lt(world.spawn_points.size(), SimWorld.SPAWN_EVAL_MAX)
	var candidates := world._spawn_candidates()
	assert_eq(candidates.size(), world.spawn_points.size(), "small map: every point scored")
