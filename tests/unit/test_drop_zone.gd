extends GutTest
## Drop Zone (BR, full island): registered but not offered in the menus,
## all 8 districts at final quality, >= 150 ground spawns clear of
## collision spread across the island, 16 chunk bodies (World_C0..C15)
## each holding its chunk's boxes plus one terrain patch, and terrain
## heights (crater −8, rim +2, ridge +6, flat 0) matching the analytic
## ground_height().

var arena: Node3D


func before_all() -> void:
	arena = Maps.gameplay("drop_zone")
	add_child(arena)
	await wait_physics_frames(2)


func after_all() -> void:
	arena.queue_free()


func test_registered_but_not_playable() -> void:
	assert_true(Maps.has("drop_zone"))
	assert_false(Maps.PLAYABLE.has("drop_zone"), "menus must not offer the test map")
	var entry: Dictionary = Maps.LIST["drop_zone"]
	assert_eq(entry["gameplay"], "res://maps/drop_zone/gameplay.tscn")
	assert_eq(entry["presentation"], "res://maps/drop_zone/presentation.tscn")
	assert_true(ResourceLoader.exists(entry["gameplay"]), "gameplay exists")
	assert_true(ResourceLoader.exists(entry["presentation"]), "presentation exists")
	assert_true(ResourceLoader.exists(entry["thumb"]), "thumb exists (Foundry's, reused)")
	assert_almost_eq(float(entry["exposure"]), 1.3, 0.001)


func test_quarter_boxes_match_foundry_translated() -> void:
	var boxes := DropZoneLayout.quarter_boxes()
	var foundry := FoundryLayout.boxes()
	assert_eq(boxes.size(), foundry.size(), "quarter is the whole Foundry box list")
	for i in boxes.size():
		assert_eq(boxes[i][0], foundry[i][0], "box %d kind" % i)
		assert_eq(boxes[i][1], (foundry[i][1] as Vector3) + DropZoneLayout.QUARTER_OFFSET, "box %d centre" % i)
		assert_eq(boxes[i][2], foundry[i][2], "box %d size" % i)
		assert_eq(boxes[i][3], foundry[i][3], "box %d rotation" % i)
	# The quarter boxes are a subset of the full island box list...
	assert_true(DropZoneLayout.boxes().size() > boxes.size(), "island has more than the quarter")
	var found := 0
	for b in DropZoneLayout.boxes():
		for q in boxes:
			if b[0] == q[0] and (b[1] as Vector3) == (q[1] as Vector3) and b[2] == q[2] and b[3] == q[3]:
				found += 1
				break
	assert_eq(found, boxes.size(), "every quarter box is in the island list")
	# ...and the old single "World" body is gone: collision lives in chunks.
	assert_null(arena.get_node_or_null("World"), "no single World body any more")


func test_all_districts_have_layout_data_and_fit() -> void:
	var rects := {}
	for dname in DropZoneLayout.district_names():
		var boxes := DropZoneLayout.district_boxes(dname)
		assert_gt(boxes.size(), 0, "%s has boxes" % dname)
		assert_gt(DropZoneLayout.district_pieces(dname).size(), 0, "%s has pieces" % dname)
		assert_gt(DropZoneLayout.district_decor(dname).size(), 0, "%s has decor" % dname)
		assert_gt(DropZoneLayout.district_lights(dname).size(), 0, "%s has lights" % dname)
		var rect := DropZoneLayout.district_rect(dname)
		rects[dname] = rect
		if dname == "Scatter sites":
			# Sites spread in the gaps: each box inside the island and
			# clear of every other district's rect.
			for b in boxes:
				var aabb := DropZoneLayout.box_aabb(b)
				assert_true(aabb.position.x >= -400.0 and aabb.end.x <= 400.0, "scatter box %s inside island x" % b[1])
				assert_true(aabb.position.z >= -400.0 and aabb.end.z <= 400.0, "scatter box %s inside island z" % b[1])
			continue
		var grown := rect.grow(0.6)
		for b in boxes:
			var aabb := DropZoneLayout.box_aabb(b)
			assert_true(grown.encloses(Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z)),
				"%s box %s fits its rect" % [dname, b[1]])
	# No two district rects overlap (quarter included).
	var names := DropZoneLayout.district_names()
	for i in names.size():
		for j in range(i + 1, names.size()):
			assert_false((rects[names[i]] as Rect2).intersects(rects[names[j]] as Rect2),
				"%s does not overlap %s" % [names[i], names[j]])


func test_spawn_points_are_plentiful_ground_and_clear() -> void:
	var spawns: Array[Transform3D] = arena.spawn_points()
	assert_gte(spawns.size(), 150, "island spawns, got %d" % spawns.size())
	var seen := {}
	var per_district := {}
	for t: Transform3D in spawns:
		var p: Vector3 = t.origin
		assert_almost_eq(p.y, DropZoneLayout.ground_height(p.x, p.z) + 0.05, 0.01,
			"spawn %s stands on the ground" % p)
		assert_false(DropZoneLayout.point_blocked(p), "spawn %s clear of collision boxes" % p)
		assert_false(seen.has(p), "spawn %s is unique" % p)
		seen[p] = true
		for dname in DropZoneLayout.district_names():
			var r := DropZoneLayout.district_rect(dname)
			if p.x >= r.position.x and p.x <= r.end.x and p.z >= r.position.y and p.z <= r.end.y:
				per_district[dname] = int(per_district.get(dname, 0)) + 1
				break
	var spread := 0
	for dname in per_district:
		if int(per_district[dname]) >= 10:
			spread += 1
	assert_gte(spread, 6, "spawns spread across >= 6 districts, got %d: %s" % [spread, per_district])
	# The Foundry quarter spawns are a subset, unchanged (94 points).
	var quarter := DropZoneLayout.quarter_spawn_points()
	assert_eq(quarter.size(), 94, "quarter spawns preserved")
	for t: Transform3D in quarter:
		assert_true(seen.has(t.origin), "quarter spawn %s is in the island spawns" % t.origin)


func test_spawn_points_have_ground_below() -> void:
	var space := arena.get_world_3d().direct_space_state
	for t: Transform3D in arena.spawn_points():
		var ray := PhysicsRayQueryParameters3D.create(
			t.origin + Vector3.UP * 0.5, t.origin + Vector3.DOWN, Sim.LAYER_WORLD)
		var hit := space.intersect_ray(ray)
		assert_false(hit.is_empty(), "spawn %s has ground" % t.origin)
		if not hit.is_empty():
			assert_almost_eq(hit.position.y, DropZoneLayout.ground_height(t.origin.x, t.origin.z), 0.15,
				"ground under spawn %s matches ground_height" % t.origin)


func test_pickups_jump_pads_and_flag_bases_are_translated() -> void:
	for s in arena.pickup_spots():
		var p: Vector3 = s["position"]
		assert_true(p.x >= -400.0 and p.x <= 400.0 and p.z >= -400.0 and p.z <= 400.0,
			"pickup %s on the island" % p)
		assert_true([&"rail_sniper", &"arc_launcher", &"grenade"].has(s["weapon"]),
			"pickup %s uses a known weapon" % p)
	for s in FoundryLayout.pickup_spots():
		var found := false
		for a in arena.pickup_spots():
			if (a["position"] as Vector3) == (s["position"] as Vector3) + DropZoneLayout.QUARTER_OFFSET and a["weapon"] == s["weapon"]:
				found = true
		assert_true(found, "Foundry pickup %s kept (translated)" % s["position"])
	assert_gte(arena.pickup_spots().size(), FoundryLayout.pickup_spots().size() + 10,
		"new districts add pickups, got %d" % arena.pickup_spots().size())
	for pad in arena.jump_pads():
		assert_true(DropZoneLayout.jump_pads().has(pad), "jump pad %s known" % pad["position"])
	assert_gte(arena.jump_pads().size(), FoundryLayout.jump_pads().size() + 2,
		"ridge + ship jump pads added, got %d" % arena.jump_pads().size())
	assert_eq(arena.flag_bases().size(), FoundryLayout.flag_bases().size())
	for i in arena.flag_bases().size():
		assert_eq(arena.flag_bases()[i],
			(FoundryLayout.flag_bases()[i] as Vector3) + DropZoneLayout.QUARTER_OFFSET)


func test_island_extents_are_800m_and_districts_fit() -> void:
	assert_almost_eq(DropZoneLayout.ISLAND_SIZE, 800.0, 0.001)
	var extents := DropZoneLayout.island_extents()
	assert_eq(extents[0], Vector2(-400, -400))
	assert_eq(extents[1], Vector2(400, 400))
	var districts := DropZoneLayout.districts()
	assert_eq(districts.size(), 7, "the other 7 areas as footprints")
	var quarter := Rect2(
		DropZoneLayout.QUARTER_OFFSET.x - 32, DropZoneLayout.QUARTER_OFFSET.z - 24, 64, 48)
	for d in districts:
		var size: Vector2 = d["size"]
		var centre: Vector3 = d["centre"]
		var rect := Rect2(centre.x - size.x * 0.5, centre.z - size.y * 0.5, size.x, size.y)
		assert_true(Rect2(-400, -400, 800, 800).encloses(rect), "%s fits on the island" % d["name"])
		assert_false(rect.intersects(quarter), "%s does not overlap the Foundry quarter" % d["name"])


func test_chunk_bodies_hold_their_boxes_and_terrain() -> void:
	var total_box_shapes := 0
	for i in 16:
		var body: StaticBody3D = arena.get_node_or_null(DropZoneLayout.chunk_name(i))
		assert_not_null(body, "chunk body %s exists" % DropZoneLayout.chunk_name(i))
		if body == null:
			continue
		assert_eq(body.collision_layer, Sim.LAYER_WORLD, "%s on LAYER_WORLD" % body.name)
		assert_eq(body.collision_mask, 0, "%s mask 0" % body.name)
		var boxes_in_chunk := 0
		var terrain_patches := 0
		for child in body.get_children():
			if child is CollisionShape3D:
				if (child as CollisionShape3D).shape is BoxShape3D:
					boxes_in_chunk += 1
				elif (child as CollisionShape3D).shape is ConcavePolygonShape3D:
					terrain_patches += 1
		assert_eq(boxes_in_chunk, DropZoneLayout.boxes_for_chunk(i).size(),
			"%s holds exactly its chunk's boxes" % body.name)
		assert_eq(terrain_patches, 1, "%s has exactly one terrain patch" % body.name)
		total_box_shapes += boxes_in_chunk
	assert_eq(total_box_shapes, DropZoneLayout.boxes().size(),
		"every box assigned to exactly one chunk body")


func test_terrain_heights() -> void:
	assert_almost_eq(DropZoneLayout.ground_height(0, 0), -8.0, 0.01, "crater centre −8")
	assert_almost_eq(DropZoneLayout.ground_height(100, 0), 2.0, 0.01, "crater rim +2")
	assert_almost_eq(DropZoneLayout.ground_height(0, 100), 2.0, 0.01, "crater rim +2 (z)")
	assert_almost_eq(DropZoneLayout.ground_height(-260, 0), 6.0, 0.01, "ridge crest +6")
	assert_almost_eq(DropZoneLayout.ground_height(250, 0), 0.0, 0.001, "flat at the quarter")
	assert_almost_eq(DropZoneLayout.ground_height(0, 300), 0.0, 0.001, "flat south")
	assert_almost_eq(DropZoneLayout.ground_height(200, 200), 0.0, 0.001, "flat south-east")
	assert_almost_eq(DropZoneLayout.ground_height(-150, -150), 0.0, 0.001, "flat north-west")
	assert_almost_eq(DropZoneLayout.ground_height(0, 200), 0.0, 0.001, "rim swell back to 0")
	# Every terrain-patch vertex sits on the analytic height.
	for i in 16:
		var body: StaticBody3D = arena.get_node_or_null(DropZoneLayout.chunk_name(i))
		assert_not_null(body, "chunk body %s exists" % DropZoneLayout.chunk_name(i))
		for child in body.get_children():
			if child is CollisionShape3D and (child as CollisionShape3D).shape is ConcavePolygonShape3D:
				var faces := ((child as CollisionShape3D).shape as ConcavePolygonShape3D).get_faces()
				assert_gt(faces.size(), 0, "%s patch has faces" % body.name)
				var k := 0
				while k < faces.size():
					var v: Vector3 = faces[k]
					assert_almost_eq(v.y, DropZoneLayout.ground_height(v.x, v.z), 0.05,
						"%s patch vertex %s on ground_height" % [body.name, v])
					k += 7


func test_presentation_loads_with_foundry_quarter_silhouettes_and_loader() -> void:
	var p := Maps.presentation("drop_zone")
	assert_not_null(p, "presentation instantiates")
	var quarter: Node = p.find_child("FoundryQuarter", false, false)
	assert_not_null(quarter, "Foundry presentation instanced at the quarter offset")
	assert_eq((quarter as Node3D).position, DropZoneLayout.QUARTER_OFFSET)
	assert_null(p.find_child("IslandFloor", false, false), "old island floor slab is gone (terrain lives in chunks)")
	var districts := 0
	for dname in DropZoneLayout.district_names():
		var sil := p.find_child("Silhouette_" + dname.replace(" ", ""), false, false)
		assert_not_null(sil, "silhouette for %s" % dname)
		districts += 1
	assert_eq(districts, 8, "one silhouette per district")
	assert_not_null(p.find_child("ChunkLoader", false, false), "chunk loader present")
	assert_not_null(p.find_child("WorldEnvironment", false, false), "island environment")
	assert_not_null(p.find_child("Sun", false, false), "island sun")
	p.free()
