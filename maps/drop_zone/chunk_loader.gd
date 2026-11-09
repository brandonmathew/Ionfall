class_name DropZoneChunkLoader
extends Node
## Streams the Drop Zone island in 3×3 chunks around the local player
## (PLAN §4: "the game loads the 9 around you and unloads the rest").
## Lives only in maps/drop_zone/presentation.tscn, so it is inert on every
## other map. The match wires `player_position_callback` to the local
## player's position (see Match._drop_zone_player_position); with no
## callback the loader falls back to the island centre until a player is
## known. One chunk loads per 0.5 s tick at most, nearest first, so a
## load can never hitch the frame budget; frees are immediate.
##
## Silhouettes: each district's silhouette box (a sibling in the
## presentation scene) is visible exactly while none of that district's
## chunks is loaded, so far districts still read from across the map and
## loaded districts are never hidden behind their own grey box.

const CHUNK_SCENE := "res://maps/drop_zone/chunks/chunk_%02d.tscn"
const CHECK_SECONDS := 0.5

## The local player's position, or Vector3.INF while there is none.
var player_position_callback: Callable

var _loaded: Dictionary = {}  ## chunk index -> chunk root Node
var _timer: Timer


## The chunks around `player_pos`, nearest first (the player's own chunk
## is element 0, so it loads on the first tick). Clamped at the island
## edges: a corner player wants 4 chunks, an edge player 6, anywhere
## else the full 3×3.
static func wanted_chunk_indices(player_pos: Vector3) -> Array[int]:
	var centre := DropZoneLayout.chunk_index_for(player_pos.x, player_pos.z)
	var cx := centre % DropZoneLayout.CHUNK_COUNT
	var cz := centre / DropZoneLayout.CHUNK_COUNT
	var out: Array[int] = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var nx := cx + dx
			var nz := cz + dz
			if nx >= 0 and nx < DropZoneLayout.CHUNK_COUNT and nz >= 0 and nz < DropZoneLayout.CHUNK_COUNT:
				out.append(nx + nz * DropZoneLayout.CHUNK_COUNT)
	out.sort_custom(func(a: int, b: int) -> bool:
		return _chunk_centre_dist2(a, player_pos) < _chunk_centre_dist2(b, player_pos))
	# Nearest first, but the player's own chunk is always element 0
	# (the sort ties on equidistant neighbours, so force it).
	out.erase(centre)
	out.push_front(centre)
	return out


## Chunk indices overlapped by an axis-aligned island rect (x, z).
static func chunks_for_rect(rect: Rect2) -> Array[int]:
	var x0 := clampi(int(floor((rect.position.x + DropZoneLayout.ISLAND_HALF) / DropZoneLayout.CHUNK_SIZE)),
		0, DropZoneLayout.CHUNK_COUNT - 1)
	var x1 := clampi(int(floor((rect.end.x - 0.01 + DropZoneLayout.ISLAND_HALF) / DropZoneLayout.CHUNK_SIZE)),
		0, DropZoneLayout.CHUNK_COUNT - 1)
	var z0 := clampi(int(floor((rect.position.y + DropZoneLayout.ISLAND_HALF) / DropZoneLayout.CHUNK_SIZE)),
		0, DropZoneLayout.CHUNK_COUNT - 1)
	var z1 := clampi(int(floor((rect.end.y - 0.01 + DropZoneLayout.ISLAND_HALF) / DropZoneLayout.CHUNK_SIZE)),
		0, DropZoneLayout.CHUNK_COUNT - 1)
	var out: Array[int] = []
	for cz in range(z0, z1 + 1):
		for cx in range(x0, x1 + 1):
			out.append(cx + cz * DropZoneLayout.CHUNK_COUNT)
	return out


## Chunk indices overlapped by a district's rect.
static func district_chunk_indices(dname: String) -> Array[int]:
	return chunks_for_rect(DropZoneLayout.district_rect(dname))


static func _chunk_centre_dist2(idx: int, player_pos: Vector3) -> float:
	var rect := DropZoneLayout.chunk_rect(idx)
	var c := Vector2(rect.get_center().x, rect.get_center().y)
	return Vector2(player_pos.x, player_pos.z).distance_squared_to(c)


func _ready() -> void:
	# The Foundry quarter is the baked Foundry presentation instanced
	# whole, Sun included; the island has its own Sun, so the quarter's
	# must stay off or the island is lit twice. This cannot be stored in
	# presentation.tscn: PackedScene.pack() does not persist overrides on
	# children of an instance (verified 2026-11-09, two pack variants),
	# so it is done here, every time the presentation loads. The
	# quarter's WorldEnvironment is left alone: the island's, first in
	# tree order, is the one that takes effect.
	var parent := get_parent()
	if parent != null:
		var qsun := parent.get_node_or_null("FoundryQuarter/Sun")
		if qsun != null:
			(qsun as Node3D).visible = false
	Log.i("map", "chunk loader ready: 3x3 around the player, one chunk per %.1f s tick" % CHECK_SECONDS)
	_timer = Timer.new()
	_timer.name = "ChunkTimer"
	_timer.wait_time = CHECK_SECONDS
	_timer.autostart = true
	_timer.timeout.connect(_refresh)
	add_child(_timer)


## Chunk indices currently loaded, sorted.
func loaded_indices() -> Array[int]:
	var out: Array[int] = []
	for idx in _loaded:
		out.append(idx)
	out.sort()
	return out


func _player_position() -> Vector3:
	if player_position_callback.is_valid():
		var p: Variant = player_position_callback.call()
		if p is Vector3 and (p as Vector3) != Vector3.INF and (p as Vector3).is_finite():
			return p
	return Vector3.ZERO  # no player yet: the crater 3×3, until one is known


## One tick: free chunks outside the ring, load at most one missing
## chunk (nearest first), then refresh the silhouettes.
func _refresh() -> void:
	var wanted := wanted_chunk_indices(_player_position())
	var wanted_set := {}
	for idx in wanted:
		wanted_set[idx] = true
	for idx in _loaded.keys():
		if not wanted_set.has(idx):
			Log.d("map", "chunk %02d freed (player moved)" % idx)
			(_loaded[idx] as Node).queue_free()
			_loaded.erase(idx)
	for idx in wanted:
		if not _loaded.has(idx):
			_load_chunk(idx)
			break
	_update_silhouettes()


func _load_chunk(idx: int) -> void:
	var path := CHUNK_SCENE % idx
	if not ResourceLoader.exists(path):
		Log.e("map", "chunk %02d scene missing: %s (island will have a hole there)" % [idx, path])
		return
	var t0 := Time.get_ticks_msec()
	var scene := load(path) as PackedScene
	if scene == null:
		Log.e("map", "chunk %02d failed to load: %s" % [idx, path])
		return
	var chunk := scene.instantiate()
	chunk.name = "Chunk%02d" % idx
	add_child(chunk)
	# Chunks load after MapDetail.apply ran on the presentation: bring
	# the new chunk to the same quality tier.
	MapDetail.apply(chunk, "drop_zone", MeshyRig.current_tier())
	_loaded[idx] = chunk
	Log.i("map", "chunk %02d loaded in %d ms (%d loaded)" % [idx, Time.get_ticks_msec() - t0, _loaded.size()])


func _update_silhouettes() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for dname in DropZoneLayout.district_names():
		var sil := parent.get_node_or_null("Silhouette_" + dname.replace(" ", ""))
		if sil == null:
			continue
		var any_loaded := false
		for idx in district_chunk_indices(dname):
			if _loaded.has(idx):
				any_loaded = true
				break
		(sil as Node3D).visible = not any_loaded
