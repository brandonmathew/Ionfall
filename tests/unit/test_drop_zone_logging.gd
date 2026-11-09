extends GutTest
## Map-load logging (BR Phase 1 diagnosis): the Drop Zone load path used
## to be silent — a missing chunk scene, a slow navmesh bake, or a
## missing ChunkLoader left nothing in the session log. These tests pin
## the new lines: gameplay counts, chunk load failures, and the chunked
## navmesh bake totals. The log itself already goes to the Android
## external files folder (LogService), so a phone run leaves a file
## Brandon can pull off with USB / adb.


## The log lines written after `before` was captured.
func _tail(before: String) -> String:
	return Log.recent_text().substr(before.length())


func test_gameplay_ready_logs_counts() -> void:
	var before := Log.recent_text()
	var gameplay := Maps.gameplay("drop_zone")
	add_child(gameplay)
	var tail := _tail(before)
	assert_true(tail.contains("[map] drop_zone gameplay ready"), tail)
	assert_true(tail.contains("16 chunk bodies"), tail)
	assert_true(tail.contains("531 boxes"), tail)
	gameplay.queue_free()


func test_chunk_load_missing_scene_logs_error() -> void:
	var before := Log.recent_text()
	var loader := DropZoneChunkLoader.new()
	loader._load_chunk(99)  # no chunk_99.tscn
	var tail := _tail(before)
	assert_true(tail.contains("[map] chunk 99 scene missing"), tail)
	loader.queue_free()


func test_chunk_load_gives_up_after_three_attempts() -> void:
	# A broken chunk used to be retried every 0.5 s tick forever (1.0.7
	# phone run: chunks 04/08 failed 159 times in 90 s, spamming the
	# log and hitching frames). Now the third failure says so and the
	# loader stops.
	var before := Log.recent_text()
	var loader := DropZoneChunkLoader.new()
	loader._load_chunk(99)
	loader._load_chunk(99)
	loader._load_chunk(99)
	var tail := _tail(before)
	assert_true(tail.contains("attempt 1/3"), tail)
	assert_true(tail.contains("attempt 2/3"), tail)
	assert_true(tail.contains("giving up after 3 attempts"), tail)
	assert_true(loader._given_up(99), "chunk 99 is given up after 3 failures")
	loader.queue_free()


func test_given_up_chunk_is_not_retried() -> void:
	var loader := DropZoneChunkLoader.new()
	loader.player_position_callback = func() -> Vector3: return Vector3(-300, 0, -100)  # chunk 04
	loader._note_failure(4, "chunk 04 failed to load: test")
	loader._note_failure(4, "chunk 04 failed to load: test")
	loader._note_failure(4, "chunk 04 failed to load: test")
	assert_true(loader._given_up(4), "chunk 04 given up after 3 failures")
	var before := Log.recent_text()
	loader._refresh()
	var tail := _tail(before)
	assert_false(tail.contains("chunk 04"), "given-up chunk 04 is not retried: " + tail)
	assert_false(loader.loaded_indices().has(4), "chunk 04 stays unloaded")
	assert_true(loader.loaded_indices().size() >= 1, "a neighbour still loads")
	loader.queue_free()


func test_chunked_bake_logs_total() -> void:
	var gameplay := Maps.gameplay("drop_zone")
	add_child(gameplay)
	await wait_physics_frames(2)
	var before := Log.recent_text()
	var nav := BotNavigation.new()
	add_child(nav)
	await nav.build(gameplay)
	var tail := _tail(before)
	assert_true(tail.contains("[nav] building navmesh (chunked, 16 chunk bodies)"), tail)
	assert_true(tail.contains("[nav] chunked navmesh ready"), tail)
	assert_true(tail.contains("16 regions"), tail)
	assert_true(nav.ready_for_queries, "navmesh usable after the logged bake")
	gameplay.queue_free()
	nav.queue_free()
