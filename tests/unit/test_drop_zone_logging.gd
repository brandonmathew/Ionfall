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
