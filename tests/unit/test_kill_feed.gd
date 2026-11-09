extends GutTest
## Kill feed rows are reused (M4: building rows cost ~15 ms per kill on the
## Mi 11X), newest last, at most MAX_ROWS shown.

func _death(killer: int, victim: int) -> Dictionary:
	return {"killer": killer, "victim": victim, "weapon": &"pulse_rifle", "suicide": false,
			"headshot": false, "assists": []}


func test_rows_are_reused_newest_last() -> void:
	var kf := KillFeed.new()
	add_child_autofree(kf)
	var name_of := func(id: int) -> String: return "P%d" % id
	for i in 8:
		kf.add_death(_death(i, i + 1), name_of, 0)
	assert_eq(kf.get_child_count(), KillFeed.MAX_ROWS)
	var newest := kf.get_child(KillFeed.MAX_ROWS - 1).get_child(0).get_children()
	assert_eq((newest[0] as Label).text, "P7")
	assert_eq((newest[2] as Label).text, "P8")
	var start := Time.get_ticks_usec()
	for i in 50:
		kf.add_death(_death(i, i + 1), name_of, 0)
	print("KillFeed: %.3f ms per row" % ((Time.get_ticks_usec() - start) / 50000.0))


func test_rows_expire_and_clear() -> void:
	var kf := KillFeed.new()
	add_child_autofree(kf)
	kf.add_death(_death(1, 2), func(id: int) -> String: return str(id), 1)
	assert_true(kf.get_child(KillFeed.MAX_ROWS - 1).visible)
	kf._process(KillFeed.ROW_SECONDS + 0.1)
	assert_false(kf.get_child(KillFeed.MAX_ROWS - 1).visible)
	kf.add_death(_death(1, 2), func(id: int) -> String: return str(id), 1)
	kf.clear()
	for row in kf.get_children():
		assert_false(row.visible)


## A DOT death (two far-away bots fighting abstractly) has no weapon, so
## it used to read as a fall: "FALL ?" in the feed, as in Brandon's
## 1.0.7 phone run. It now reads DOT, with both names.
func test_dot_death_shows_dot_not_fall() -> void:
	var kf := KillFeed.new()
	add_child_autofree(kf)
	var name_of := func(id: int) -> String: return "[BOT] P%d" % id
	kf.add_death({"killer": 1000, "victim": 1001, "weapon": &"", "dot": true, "suicide": false,
			"headshot": false, "assists": []}, name_of, 0)
	var row := kf.get_child(KillFeed.MAX_ROWS - 1).get_child(0).get_children()
	assert_eq((row[0] as Label).text, "[BOT] P1000")
	assert_eq((row[1] as Label).text, "DOT")
	assert_eq((row[2] as Label).text, "[BOT] P1001")


## A real fall (environment death, empty weapon, no dot flag) still reads
## FALL — the DOT label must not swallow genuine falls.
func test_environment_death_still_shows_fall() -> void:
	var kf := KillFeed.new()
	add_child_autofree(kf)
	var name_of := func(id: int) -> String: return "[BOT] P%d" % id
	kf.add_death({"killer": 0, "victim": 1001, "weapon": &"", "environment": true, "suicide": false,
			"headshot": false, "assists": []}, name_of, 0)
	var row := kf.get_child(KillFeed.MAX_ROWS - 1).get_child(0).get_children()
	assert_eq((row[1] as Label).text, "FALL")
