extends GutTest
## Drop Zone chunk presentation (Worker B, REVISED Phase 1): the 16
## chunk scenes built by tools/build_drop_zone.gd, the 3×3 chunk loader
## (maps/drop_zone/chunk_loader.gd), and the rewritten presentation
## (island environment + sun, 8 silhouettes, loader, baked Foundry
## quarter). The chunk scenes are NOT baked: the editor lightmap bake
## cannot run in this VM (no display/GPU), so the accent lights are
## BAKE_STATIC as on the other maps and the LightmapGI nodes sit unbaked
## until tools/bake_lightmaps.sh runs on a GPU machine.

const BOX_KINDS := [SpireLayout.Kind.SLAB, SpireLayout.Kind.WALL, SpireLayout.Kind.COVER,
		SpireLayout.Kind.TRIM_CYAN, SpireLayout.Kind.TRIM_ORANGE, SpireLayout.Kind.SPIRE_GLOW]


func _chunk_path(idx: int) -> String:
	return "res://maps/drop_zone/chunks/chunk_%02d.tscn" % idx


## Boxes + decor in chunk `idx` that the builder merges (kinds in
## BOX_KINDS), minus the Foundry quarter's (reused baked, not rebuilt).
func _expected_box_tris(idx: int) -> int:
	var quarter := {}
	for b in DropZoneLayout.quarter_boxes() + DropZoneLayout.quarter_decor():
		quarter["%d|%s" % [b[0], str(b[1])]] = true
	var count := 0
	for b in DropZoneLayout.boxes_for_chunk(idx):
		if b[0] in BOX_KINDS and not quarter.has("%d|%s" % [b[0], str(b[1])]):
			count += 1
	for d in DropZoneLayout.decor():
		var c: Vector3 = d[1]
		if DropZoneLayout.chunk_index_for(c.x, c.z) == idx and d[0] in BOX_KINDS \
				and not quarter.has("%d|%s" % [d[0], str(d[1])]):
			count += 1
	return count * 12  # one BoxMesh is 12 triangles


## Kit pieces in chunk `idx`, minus the quarter's.
func _expected_pieces(idx: int) -> int:
	var quarter := {}
	for p in DropZoneLayout.quarter_pieces():
		quarter["%s|%s" % [p[0], str((p[1] as Transform3D).origin)]] = true
	var count := 0
	for p in DropZoneLayout.pieces():
		var t: Transform3D = p[1]
		if DropZoneLayout.chunk_index_for(t.origin.x, t.origin.z) == idx \
				and not quarter.has("%s|%s" % [p[0], str(t.origin)]):
			count += 1
	return count


## Accent lights in chunk `idx`, minus the quarter's.
func _expected_lights(idx: int) -> int:
	var quarter := {}
	for l in DropZoneLayout.quarter_lights():
		quarter[str(l[0])] = true
	var count := 0
	for l in DropZoneLayout.lights():
		var pos: Vector3 = l[0]
		if DropZoneLayout.chunk_index_for(pos.x, pos.z) == idx and not quarter.has(str(pos)):
			count += 1
	return count


func test_all_16_chunk_scenes_exist_and_instantiate() -> void:
	for idx in 16:
		var path := _chunk_path(idx)
		assert_true(ResourceLoader.exists(path), "chunk scene %s exists" % path)
		var scene := load(path) as PackedScene
		assert_not_null(scene, "chunk %02d loads" % idx)
		var chunk := scene.instantiate() as Node3D
		assert_not_null(chunk, "chunk %02d instantiates" % idx)
		assert_eq(chunk.name, "DropZoneChunk%02d" % idx, "chunk %02d root name" % idx)
		assert_eq(int(chunk.get_meta("chunk_index", -1)), idx, "chunk %02d meta" % idx)
		# Terrain: one visual patch covering exactly this chunk's rect.
		var terrain := chunk.find_child("Terrain", false, false) as MeshInstance3D
		assert_not_null(terrain, "chunk %02d has its terrain patch" % idx)
		var rect := DropZoneLayout.chunk_rect(idx)
		var aabb := terrain.mesh.get_aabb()
		assert_almost_eq(aabb.position.x, rect.position.x, 0.01, "chunk %02d terrain x0" % idx)
		assert_almost_eq(aabb.end.x, rect.end.x, 0.01, "chunk %02d terrain x1" % idx)
		assert_almost_eq(aabb.position.z, rect.position.y, 0.01, "chunk %02d terrain z0" % idx)
		assert_almost_eq(aabb.end.z, rect.end.y, 0.01, "chunk %02d terrain z1" % idx)
		assert_eq(terrain.gi_mode, GeometryInstance3D.GI_MODE_DISABLED,
			"chunk %02d terrain is not lightmapped (too big at 0.2 m texels)" % idx)
		# Merged boxes + decor: exactly the chunk's non-quarter boxes.
		var tris := 0
		for mi: MeshInstance3D in chunk.find_children("*", "MeshInstance3D", false, false):
			if mi.name != "Terrain":
				tris += mi.mesh.surface_get_array_index_len(0) / 3
		assert_eq(tris, _expected_box_tris(idx), "chunk %02d merged box tris" % idx)
		# Kit pieces instanced, accent lights, unbaked LightmapGI.
		var pieces := 0
		for n: Node in chunk.get_children():
			if n.name.begins_with("Piece"):
				pieces += 1
		assert_eq(pieces, _expected_pieces(idx), "chunk %02d kit pieces" % idx)
		var lights := chunk.find_children("Accent*", "OmniLight3D", false, false).size()
		assert_eq(lights, _expected_lights(idx), "chunk %02d accent lights" % idx)
		for omni: OmniLight3D in chunk.find_children("Accent*", "OmniLight3D", false, false):
			assert_eq(omni.light_bake_mode, Light3D.BAKE_STATIC, "chunk %02d accent is BAKE_STATIC" % idx)
		var lm := chunk.find_child("LightmapGI", false, false) as LightmapGI
		assert_not_null(lm, "chunk %02d has a LightmapGI ready for the bake" % idx)
		assert_null(lm.light_data, "chunk %02d lightmap is unbaked (no GPU bake in this VM)" % idx)
		chunk.free()


func test_chunk_loader_3x3_rule() -> void:
	# Island centre: the full 3×3, own chunk first.
	var centre := DropZoneChunkLoader.wanted_chunk_indices(Vector3.ZERO)
	assert_eq(centre.size(), 9, "centre wants 9 chunks")
	assert_eq(centre[0], 10, "own chunk loads first")
	for idx in [5, 6, 7, 9, 10, 11, 13, 14, 15]:
		assert_true(centre.has(idx), "centre wants chunk %d" % idx)
	# Corners clamp to 4 chunks.
	assert_eq(DropZoneChunkLoader.wanted_chunk_indices(Vector3(-400, 0, -400)).size(), 4, "NW corner wants 4")
	for idx in [0, 1, 4, 5]:
		assert_true(DropZoneChunkLoader.wanted_chunk_indices(Vector3(-400, 0, -400)).has(idx),
			"NW corner wants chunk %d" % idx)
	assert_eq(DropZoneChunkLoader.wanted_chunk_indices(Vector3(400, 0, 400)).size(), 4, "SE corner wants 4")
	for idx in [10, 11, 14, 15]:
		assert_true(DropZoneChunkLoader.wanted_chunk_indices(Vector3(400, 0, 400)).has(idx),
			"SE corner wants chunk %d" % idx)
	# Edges clamp to 6 chunks; outside the island clamps to the corner.
	var edge := DropZoneChunkLoader.wanted_chunk_indices(Vector3(0, 0, -400))
	assert_eq(edge.size(), 6, "north edge wants 6")
	for idx in [1, 2, 3, 5, 6, 7]:
		assert_true(edge.has(idx), "north edge wants chunk %d" % idx)
	var outside := DropZoneChunkLoader.wanted_chunk_indices(Vector3(500, 0, 500))
	for idx in [10, 11, 14, 15]:
		assert_true(outside.has(idx), "outside clamps to the SE corner set, chunk %d" % idx)
	var west := DropZoneChunkLoader.wanted_chunk_indices(Vector3(-500, 0, 0))
	assert_eq(west.size(), 6, "west edge wants 6")
	for idx in [4, 5, 8, 9, 12, 13]:
		assert_true(west.has(idx), "west edge wants chunk %d" % idx)
	# District -> chunk mapping the silhouettes use.
	assert_eq(DropZoneChunkLoader.district_chunk_indices("Docking Port"), [1, 2] as Array[int])
	assert_eq(DropZoneChunkLoader.district_chunk_indices("Halcyon Spire"), [2, 3, 6, 7] as Array[int])
	assert_eq(DropZoneChunkLoader.district_chunk_indices("Crater Rim"), [5, 6, 9, 10] as Array[int])
	assert_eq(DropZoneChunkLoader.district_chunk_indices("Vesper Foundry"), [7, 11] as Array[int])


func test_presentation_loads_with_env_sun_silhouettes_and_loader() -> void:
	var p := Maps.presentation("drop_zone")
	assert_not_null(p, "presentation instantiates")
	add_child(p)  # runs the ChunkLoader's _ready (hides the Foundry Sun)
	assert_eq(p.get_child(0).name, "WorldEnvironment", "the island env is first, so it wins over Foundry's")
	assert_not_null(p.find_child("WorldEnvironment", false, false), "island environment")
	var sun := p.find_child("Sun", false, false) as DirectionalLight3D
	assert_not_null(sun, "island sun")
	assert_true(sun.visible, "island sun is on")
	assert_almost_eq(sun.light_energy, 1.45, 0.01, "island sun energy")
	var visible_suns := 0
	for l: DirectionalLight3D in p.find_children("*", "DirectionalLight3D", true, false):
		if l.visible:
			visible_suns += 1
	assert_eq(visible_suns, 1, "exactly one visible sun (the Foundry Sun is hidden at load)")
	assert_false((p.get_node("FoundryQuarter/Sun") as Node3D).visible, "Foundry Sun hidden, no double light")
	assert_eq(p.get_meta("layout_hash", ""), DropZoneLayout.layout_hash(), "presentation matches the layout")
	for dname in DropZoneLayout.district_names():
		var sil := p.find_child("Silhouette_" + dname.replace(" ", ""), false, false) as MeshInstance3D
		assert_not_null(sil, "silhouette for %s" % dname)
		assert_true(sil.mesh is BoxMesh, "silhouette for %s is a box" % dname)
		assert_eq(sil.gi_mode, GeometryInstance3D.GI_MODE_DISABLED, "silhouette %s is not lightmapped" % dname)
		assert_eq(sil.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "silhouette %s casts no shadow" % dname)
	var loader := p.find_child("ChunkLoader", false, false)
	assert_not_null(loader, "chunk loader present")
	assert_true(loader is DropZoneChunkLoader, "chunk loader is the loader script")
	assert_not_null(p.find_child("FoundryQuarter", false, false), "baked Foundry quarter reused")
	assert_eq((p.find_child("FoundryQuarter", false, false) as Node3D).position, DropZoneLayout.QUARTER_OFFSET)
	assert_null(p.find_child("IslandFloor", false, false), "old island floor slab is gone (terrain is in chunks)")
	p.queue_free()


func test_loader_loads_and_frees_3x3_one_per_tick() -> void:
	var loader := DropZoneChunkLoader.new()
	loader.player_position_callback = func() -> Vector3: return Vector3.ZERO
	# One chunk per tick: the first refresh loads only the player's own.
	loader._refresh()
	assert_eq(loader.loaded_indices(), [10] as Array[int], "first tick loads only the own chunk")
	for i in 8:
		loader._refresh()
	assert_eq(loader.loaded_indices(), [5, 6, 7, 9, 10, 11, 13, 14, 15] as Array[int],
		"9 ticks fill the centre 3×3")
	# Silhouettes toggle with the loaded chunks (fakes under the test node).
	var sil_spire := MeshInstance3D.new()
	sil_spire.name = "Silhouette_HalcyonSpire"
	add_child(sil_spire)
	var sil_dock := MeshInstance3D.new()
	sil_dock.name = "Silhouette_DockingPort"
	add_child(sil_dock)
	add_child(loader)  # _ready starts the timer; _refresh is still driven here
	loader._refresh()
	assert_false(sil_spire.visible, "Spire silhouette hides while its chunks are loaded")
	assert_true(sil_dock.visible, "Docking silhouette shows while its chunks are unloaded")
	# Walk to the far corner: the ring frees and reloads, one per tick.
	loader.player_position_callback = func() -> Vector3: return Vector3(390, 0, 390)
	for i in 10:
		loader._refresh()
	assert_eq(loader.loaded_indices(), [10, 11, 14, 15] as Array[int], "corner 3×3 after moving")
	assert_true(sil_spire.visible, "Spire silhouette returns once its chunks unload")
	assert_true(sil_dock.visible, "Docking silhouette still shows at the far corner")
	loader.queue_free()
	sil_spire.queue_free()
	sil_dock.queue_free()
