class_name DropZoneLayout
extends RefCounted
## Drop Zone (BR map, PLAN §4): an 800 × 800 m ring-station island around
## a central crater, with 8 named areas: Docking Port, Halcyon Spire,
## Vesper Foundry, Hydro Domes, Solar Flats, The Ridge, Crater Rim, plus
## Scatter sites.
##
## REVISED Phase 1 ground truth: the FULL island is built at final quality
## (all 8 districts, kit-bashed from the existing kits), not just the
## Foundry quarter. The quarter is still FoundryLayout.boxes() translated
## by QUARTER_OFFSET, unchanged. Terrain is analytic (ground_height) with
## per-chunk patch collision in the gameplay scene; the island floor is
## the terrain patches, not a flat floor box. Gameplay collision is split
## into 16 chunk bodies (4 × 4 of 200 × 200 m, "World_C0".."World_C15");
## see chunk_index_for() / gameplay.gd.

## Island footprint, in metres; the island is centred on the origin.
const ISLAND_SIZE := 800.0
const ISLAND_HALF := 400.0
## Where the Foundry quarter sits on the island: the east side of the
## ring, clockwise from Docking Port (north) past Halcyon Spire (north-east).
## Quarter footprint (floor box 64 × 48 m) spans x 218–282, z −24–24: well
## inside the island, clear of the crater (radius ~100 m) and of every
## other district rect below.
const QUARTER_OFFSET := Vector3(250, 0, 0)
const QUARTER_HALF_X := FoundryLayout.HALF_X
const QUARTER_HALF_Z := FoundryLayout.HALF_Z
## Horizontal clearance kept around a spawn point (player radius ~0.4 m).
const SPAWN_CLEARANCE := 0.6
## Chunks: 4 × 4 of 200 × 200 m. Chunk index = cx + cz * 4, cx =
## floor((x + 400) / 200), cz = floor((z + 400) / 200), each 0..3.
const CHUNK_COUNT := 4
const CHUNK_SIZE := 200.0
## Spawn grid spacing over the whole island (PLAN: 4–6 m).
const SPAWN_SPACING := 5.0

const Kind := SpireLayout.Kind

## Cached AABBs of boxes() and a 16 m spatial hash over them, so
## point_blocked() stays cheap with ~600 boxes and ~25k spawn candidates.
static var _aabbs: Array = []
static var _cells := {}
## Cached spawn points (deterministic; callers get a duplicate).
static var _spawn_cache: Array[Transform3D] = []


## The other 7 areas as footprints: [name, centre, size (x, z in metres),
## height]. "Scatter sites" is the plan's ~25 small stops; the rect is a
## representative south-west field, not a building — the sites themselves
## are spread in the gaps between named districts (see scatter_sites()).
static func districts() -> Array:
	return [
		{"name": "Docking Port", "centre": Vector3(0, 0, -260), "size": Vector2(140, 70), "height": 14.0},
		{"name": "Halcyon Spire", "centre": Vector3(185, 0, -185), "size": Vector2(80, 80), "height": 45.0},
		{"name": "Hydro Domes", "centre": Vector3(185, 0, 185), "size": Vector2(110, 90), "height": 10.0},
		{"name": "Solar Flats", "centre": Vector3(0, 0, 260), "size": Vector2(130, 70), "height": 4.0},
		{"name": "The Ridge", "centre": Vector3(-260, 0, 0), "size": Vector2(70, 140), "height": 18.0},
		{"name": "Crater Rim", "centre": Vector3(0, 0, 0), "size": Vector2(200, 200), "height": 6.0},
		{"name": "Scatter sites", "centre": Vector3(-185, 0, 185), "size": Vector2(100, 100), "height": 4.0},
	]


## All 8 area names, including the Foundry quarter (not in districts()).
static func district_names() -> Array:
	return ["Docking Port", "Halcyon Spire", "Vesper Foundry", "Hydro Domes",
		"Solar Flats", "The Ridge", "Crater Rim", "Scatter sites"]


## Footprint rect (x, z) of a district by name.
static func district_rect(dname: String) -> Rect2:
	if dname == "Vesper Foundry":
		return Rect2(QUARTER_OFFSET.x - 32, QUARTER_OFFSET.z - 24, 64, 48)
	for d in districts():
		if d["name"] == dname:
			var size: Vector2 = d["size"]
			var centre: Vector3 = d["centre"]
			return Rect2(centre.x - size.x * 0.5, centre.z - size.y * 0.5, size.x, size.y)
	return Rect2()


## Island extents as [min, max] on X and Z (the island is square).
static func island_extents() -> Array:
	return [Vector2(-ISLAND_HALF, -ISLAND_HALF), Vector2(ISLAND_HALF, ISLAND_HALF)]


## ---- Terrain ---------------------------------------------------------
## Analytic ground height. 0 everywhere except:
## - the crater bowl at the centre: smooth fall to −8 m at the middle, with
##   a broad rim swell rising to +2 m at radius 100 m and back to 0 at
##   radius 170 m (compact support, so flat ground is exactly 0);
## - the ridge rise in the west around (−260, 0): smooth hill up to +6 m,
##   compact support radius 100 m.
## The profiles are chosen for low curvature: the bowl is piecewise
## quadratic (tent slope, |curvature| 0.0032 /m) and the swell is a wide
## sine-squared bump (|curvature| <= 0.002 /m), so total |curvature| stays
## under ~0.0052 /m and the 10 m terrain-patch triangulation sits within
## 0.15 m of this function everywhere.
static func ground_height(x: float, z: float) -> float:
	var h := 0.0
	var d := Vector2(x, z).length()
	if d < 170.0:
		if d < 100.0:
			var t := d / 100.0
			var s := 2.0 * t * t if t < 0.5 else 1.0 - 2.0 * (1.0 - t) * (1.0 - t)
			h += -8.0 * (1.0 - s)
		if d > 30.0:
			var u := (d - 30.0) / 140.0
			h += 2.0 * sin(PI * u) * sin(PI * u)
	var rd := Vector2(x + 260.0, z).length()
	if rd < 100.0:
		var r := rd / 100.0
		h += 6.0 * (1.0 - r * r) * (1.0 - r * r)
	return h


## ---- Chunks ----------------------------------------------------------
static func chunk_index_for(x: float, z: float) -> int:
	var cx := clampi(int(floor((x + ISLAND_HALF) / CHUNK_SIZE)), 0, CHUNK_COUNT - 1)
	var cz := clampi(int(floor((z + ISLAND_HALF) / CHUNK_SIZE)), 0, CHUNK_COUNT - 1)
	return cx + cz * CHUNK_COUNT


static func chunk_name(idx: int) -> String:
	return "World_C%d" % idx


## Footprint rect (x, z) of a chunk, in island coords.
static func chunk_rect(idx: int) -> Rect2:
	var cx := idx % CHUNK_COUNT
	var cz := idx / CHUNK_COUNT
	return Rect2(-ISLAND_HALF + cx * CHUNK_SIZE, -ISLAND_HALF + cz * CHUNK_SIZE,
		CHUNK_SIZE, CHUNK_SIZE)


## Boxes whose centre falls in chunk `idx` (assigned by box centre — the
## contract the navmesh worker bakes from).
static func boxes_for_chunk(idx: int) -> Array:
	var out := []
	for b in boxes():
		var c: Vector3 = b[1]
		if chunk_index_for(c.x, c.z) == idx:
			out.append(b)
	return out


## ---- Box helpers -----------------------------------------------------
## One box: [kind, centre, size, rotation (Euler degrees)].
static func _b(kind: int, centre: Vector3, size: Vector3, rot := Vector3.ZERO) -> Array:
	return [kind, centre, size, rot]


## A kit prop as a collision box: [model, position on the ground, yaw].
static func _prop_box(model: String, pos: Vector3, yaw := 0.0) -> Array:
	var size: Vector3 = SpireLayout.PROP_SIZES[model]
	if absf(fmod(yaw, 180.0)) > 45.0:
		size = Vector3(size.z, size.y, size.x)
	return [Kind.PROP, pos + Vector3(0, size.y * 0.5, 0), size, Vector3.ZERO]


## Translate a box list by `offset` (centres only).
static func _shift_boxes(list: Array, offset: Vector3) -> Array:
	var out := []
	for b in list:
		out.append([b[0], (b[1] as Vector3) + offset, b[2], b[3]])
	return out


static func _shift_pieces(list: Array, offset: Vector3) -> Array:
	var out := []
	for p in list:
		var t: Transform3D = p[1]
		out.append([p[0], Transform3D(t.basis, t.origin + offset)])
	return out


static func _shift_decor(list: Array, offset: Vector3) -> Array:
	var out := []
	for d in list:
		out.append([d[0], (d[1] as Vector3) + offset, d[2], d[3]])
	return out


static func _shift_lights(list: Array, offset: Vector3) -> Array:
	var out := []
	for l in list:
		out.append([(l[0] as Vector3) + offset, l[1], l[2], l[3]])
	return out


## Plates covering [x0, x1] × [z0, z1] at height y, in cells of up to
## `cell` m (SpireLayout._tile is fixed at 4 m; the big Docking floor
## tiles at 8 m to keep the piece count sane).
static func _tile(out: Array, model: String, x0: float, x1: float, z0: float, z1: float, y: float, cell := 4.0) -> void:
	var nx := ceili((x1 - x0) / cell - 0.001)
	var nz := ceili((z1 - z0) / cell - 0.001)
	var w := (x1 - x0) / nx
	var d := (z1 - z0) / nz
	for i in nx:
		for j in nz:
			out.append([model, Transform3D(Basis().scaled(Vector3(w / 4.0, 1, d / 4.0)),
					Vector3(x0 + w * (i + 0.5), y + 0.003, z0 + d * (j + 0.5)))])


## ---- Districts -------------------------------------------------------
## Docking Port (140 × 70 at (0, −260)): north landing docks, cargo
## stacks and two cranes, reused Station/Spire kit. Two open dock rooms
## (east face open) at the ends, container rows mid-field.
static func docking_boxes() -> Array:
	var out := [_b(Kind.FLOOR, Vector3(0, -0.5, -260), Vector3(140, 1, 70))]
	for sx in [-1.0, 1.0]:
		# Crane: two legs and a top beam spanning z.
		out.append(_b(Kind.COLUMN, Vector3(42 * sx, 7, -288), Vector3(1.2, 14, 1.2)))
		out.append(_b(Kind.COLUMN, Vector3(42 * sx, 7, -272), Vector3(1.2, 14, 1.2)))
		out.append(_b(Kind.SLAB, Vector3(42 * sx, 14.5, -280), Vector3(2, 1, 20)))
		# Dock room: west/east wall, north/south walls, roof at 4 m.
		out.append(_b(Kind.WALL, Vector3(66 * sx, 2, -260), Vector3(0.5, 4, 10)))
		out.append(_b(Kind.WALL, Vector3(60 * sx, 2, -265), Vector3(12, 4, 0.5)))
		out.append(_b(Kind.WALL, Vector3(60 * sx, 2, -255), Vector3(12, 4, 0.5)))
		out.append(_b(Kind.SLAB, Vector3(60 * sx, 3.75, -260), Vector3(12, 0.5, 10)))
	# Container stacks: two-high rows mid-field, singles on the flanks.
	for x in [-60.0, -48.0, -36.0]:
		out.append(_b(Kind.COVER, Vector3(x, 1, -245), Vector3(4, 2, 2)))
		out.append(_b(Kind.COVER, Vector3(x, 3, -245), Vector3(4, 2, 2)))
	for x in [20.0, 32.0, 44.0]:
		out.append(_b(Kind.COVER, Vector3(x, 1, -245), Vector3(4, 2, 2)))
	for x in [-20.0, -8.0]:
		out.append(_b(Kind.COVER, Vector3(x, 1, -270), Vector3(4, 2, 2)))
	for x in [55.0, 65.0]:
		out.append(_b(Kind.COVER, Vector3(x, 1, -270), Vector3(4, 2, 2)))
		out.append(_b(Kind.COVER, Vector3(x, 3, -270), Vector3(4, 2, 2)))
	out.append(_prop_box("essentials/Prop_Crate_Large", Vector3(-15, 0, -285)))
	out.append(_prop_box("essentials/Prop_Crate_Large", Vector3(0, 0, -285)))
	out.append(_prop_box("essentials/Prop_Crate_Large", Vector3(15, 0, -285)))
	out.append(_prop_box("megakit/Prop_Barrel_Large", Vector3(-70, 0, -232)))
	out.append(_prop_box("megakit/Prop_Barrel_Large", Vector3(68, 0, -288)))
	out.append(_b(Kind.COLUMN, Vector3(0, 2.5, -232), Vector3(1, 5, 1)))
	out.append(_b(Kind.COLUMN, Vector3(0, 2.5, -288), Vector3(1, 5, 1)))
	return out


static func docking_pieces() -> Array:
	var out := []
	_tile(out, "megakit/Platform_Metal", -70, 70, -295, -225, 0.0, 8.0)
	for sx in [-1.0, 1.0]:
		for z in [-288.0, -272.0]:
			out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(1.2, 2.8, 1.2)), Vector3(42 * sx, 0, z))])
		out.append(["megakit/Platform_Metal2", Transform3D(Basis().scaled(Vector3(0.5, 1, 5)), Vector3(42 * sx, 15.0, -280))])
		for b in [_b(Kind.WALL, Vector3(66 * sx, 2, -260), Vector3(0.5, 4, 10)),
				_b(Kind.WALL, Vector3(60 * sx, 2, -265), Vector3(12, 4, 0.5)),
				_b(Kind.WALL, Vector3(60 * sx, 2, -255), Vector3(12, 4, 0.5))]:
			SpireLayout._clad(out, b[1], b[2], 1000.0, 1000.0)
	for p in [["essentials/Prop_Crate_Large", Vector3(-15, 0, -285), 0.0],
			["essentials/Prop_Crate_Large", Vector3(0, 0, -285), 0.0],
			["essentials/Prop_Crate_Large", Vector3(15, 0, -285), 0.0],
			["megakit/Prop_Barrel_Large", Vector3(-70, 0, -232), 0.0],
			["megakit/Prop_Barrel_Large", Vector3(68, 0, -288), 0.0]]:
		out.append([p[0], Transform3D(Basis(Vector3.UP, deg_to_rad(p[2])), p[1])])
	return out


static func docking_decor() -> Array:
	var out := []
	for sx in [-1.0, 1.0]:
		out.append([Kind.TRIM_ORANGE, Vector3(42 * sx, 15.05, -280), Vector3(2.06, 0.06, 20), Vector3.ZERO])
		out.append([Kind.TRIM_CYAN, Vector3(60 * sx, 4.02, -260), Vector3(12, 0.06, 0.06), Vector3.ZERO])
		out.append([Kind.TRIM_CYAN, Vector3(60 * sx, 4.02, -255), Vector3(0.06, 0.06, 10), Vector3.ZERO])
	return out


static func docking_lights() -> Array:
	var cyan := Color(0.35, 0.9, 1.0)
	var orange := Color(1.0, 0.55, 0.2)
	return [
		[Vector3(0, 8, -260), orange, 5.0, 16.0],
		[Vector3(-60, 3.2, -260), cyan, 4.0, 9.0],
		[Vector3(60, 3.2, -260), cyan, 4.0, 9.0],
		[Vector3(-42, 12, -280), orange, 3.0, 10.0],
		[Vector3(42, 12, -280), orange, 3.0, 10.0],
	]


## Halcyon Spire (80 × 80 at (185, −185)): the Spire arena map reused
## whole, translated. Spire is 72 × 56, it fits the rect.
static func spire_offset() -> Vector3:
	return Vector3(185, 0, -185)


static func spire_boxes() -> Array:
	return _shift_boxes(SpireLayout.boxes(), spire_offset())


static func spire_pieces() -> Array:
	return _shift_pieces(SpireLayout.pieces(), spire_offset())


static func spire_decor() -> Array:
	return _shift_decor(SpireLayout.decor(), spire_offset())


static func spire_lights() -> Array:
	return _shift_lights(SpireLayout.lights(), spire_offset())


## Vesper Foundry — KEEP exactly as-is: FoundryLayout.boxes() translated
## by QUARTER_OFFSET. The existing quarter tests must keep passing.
static func quarter_boxes() -> Array:
	var out := []
	for b in FoundryLayout.boxes():
		out.append(offset_box(b))
	return out


static func quarter_pieces() -> Array:
	return _shift_pieces(FoundryLayout.pieces(), QUARTER_OFFSET)


static func quarter_decor() -> Array:
	return _shift_decor(FoundryLayout.decor(), QUARTER_OFFSET)


static func quarter_lights() -> Array:
	return _shift_lights(FoundryLayout.lights(), QUARTER_OFFSET)


## Hydro Domes (110 × 90 at (185, 185)): five dome pads — a low slab,
## a ring of eight low walls, four columns and a central tank each.
## Soft cover, healing-loot feel.
static func hydro_pad_centres() -> Array:
	var out := []
	for off in [Vector2(0, 0), Vector2(-32, -22), Vector2(32, -22), Vector2(-32, 22), Vector2(32, 22)]:
		out.append(Vector3(185 + off.x, 0, 185 + off.y))
	return out


static func hydro_boxes() -> Array:
	var out := []
	for p in hydro_pad_centres():
		out.append(_b(Kind.SLAB, Vector3(p.x, 0.25, p.z), Vector3(13, 0.5, 13)))
		for k in 8:
			var ang := deg_to_rad(k * 45.0)
			var pos := Vector3(p.x + cos(ang) * 5.5, 1.1, p.z + sin(ang) * 5.5)
			out.append(_b(Kind.COVER, pos, Vector3(2.8, 1.2, 0.4), Vector3(0, -(k * 45.0 + 90.0), 0)))
		for k in 4:
			var ang := deg_to_rad(45.0 + k * 90.0)
			out.append(_b(Kind.COLUMN, Vector3(p.x + cos(ang) * 4.2, 2.0, p.z + sin(ang) * 4.2), Vector3(0.8, 3, 0.8)))
		out.append(_b(Kind.COLUMN, Vector3(p.x, 1.75, p.z), Vector3(2, 2.5, 2)))
	for c in [[Vector3(140, 0, 160), "essentials/Prop_Crate"], [Vector3(230, 0, 160), "megakit/Prop_Crate4"],
			[Vector3(140, 0, 210), "megakit/Prop_Crate4"], [Vector3(230, 0, 210), "essentials/Prop_Crate"],
			[Vector3(185, 0, 143), "essentials/Prop_Crate_Large"], [Vector3(185, 0, 227), "essentials/Prop_Crate_Large"],
			[Vector3(150, 0, 185), "megakit/Prop_Barrel_Large"], [Vector3(220, 0, 185), "megakit/Prop_Barrel_Large"]]:
		out.append(_prop_box(c[1], c[0]))
	return out


static func hydro_pieces() -> Array:
	var out := []
	for p in hydro_pad_centres():
		_tile(out, "megakit/Platform_Squares", p.x - 6.5, p.x + 6.5, p.z - 6.5, p.z + 6.5, 0.5)
		for k in 4:
			var ang := deg_to_rad(45.0 + k * 90.0)
			out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(0.8, 0.6, 0.8)),
					Vector3(p.x + cos(ang) * 4.2, 0.5, p.z + sin(ang) * 4.2))])
		out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(2, 0.5, 2)), Vector3(p.x, 0.5, p.z))])
	for c in [[Vector3(140, 0, 160), "essentials/Prop_Crate"], [Vector3(230, 0, 160), "megakit/Prop_Crate4"],
			[Vector3(140, 0, 210), "megakit/Prop_Crate4"], [Vector3(230, 0, 210), "essentials/Prop_Crate"],
			[Vector3(185, 0, 143), "essentials/Prop_Crate_Large"], [Vector3(185, 0, 227), "essentials/Prop_Crate_Large"],
			[Vector3(150, 0, 185), "megakit/Prop_Barrel_Large"], [Vector3(220, 0, 185), "megakit/Prop_Barrel_Large"]]:
		out.append([c[1], Transform3D(Basis(), c[0])])
	return out


static func hydro_decor() -> Array:
	var out := []
	for p in hydro_pad_centres():
		out.append([Kind.TRIM_CYAN, Vector3(p.x, 0.53, p.z - 6.5), Vector3(13, 0.06, 0.06), Vector3.ZERO])
		out.append([Kind.TRIM_CYAN, Vector3(p.x, 0.53, p.z + 6.5), Vector3(13, 0.06, 0.06), Vector3.ZERO])
		out.append([Kind.TRIM_CYAN, Vector3(p.x - 6.5, 0.53, p.z), Vector3(0.06, 0.06, 13), Vector3.ZERO])
		out.append([Kind.TRIM_CYAN, Vector3(p.x + 6.5, 0.53, p.z), Vector3(0.06, 0.06, 13), Vector3.ZERO])
		out.append([Kind.SPIRE_GLOW, Vector3(p.x, 3.2, p.z), Vector3(0.3, 2.0, 0.3), Vector3.ZERO])
	return out


static func hydro_lights() -> Array:
	var cyan := Color(0.35, 0.9, 1.0)
	var orange := Color(1.0, 0.55, 0.2)
	var out := [[Vector3(185, 5, 185), orange, 4.0, 12.0]]
	for p in hydro_pad_centres():
		out.append([Vector3(p.x, 4.0, p.z), cyan, 3.0, 9.0])
	return out


## Solar Flats (130 × 70 at (0, 260)): panel-field rows of tilted low
## cover boxes on legs, plus crates. Panels are cover, not walls: their
## undersides stay above 0.55 m so a fighter can stand under one.
static func solar_boxes() -> Array:
	var out := []
	for z in [238.0, 250.0, 262.0, 274.0, 286.0]:
		for x in [-48.0, -32.0, -16.0, 0.0, 16.0, 32.0, 48.0]:
			out.append(_b(Kind.COVER, Vector3(x, 1.4, z), Vector3(5, 0.2, 3), Vector3(-25, 0, 0)))
			out.append(_b(Kind.COLUMN, Vector3(x, 0.6, z), Vector3(0.4, 1.2, 0.4)))
	for sx in [-1.0, 1.0]:
		out.append(_b(Kind.COVER, Vector3(58 * sx, 0.6, 262), Vector3(0.5, 1.2, 40)))
	for c in [[Vector3(-40, 0, 244), "essentials/Prop_Crate"], [Vector3(40, 0, 244), "megakit/Prop_Crate4"],
			[Vector3(-8, 0, 256), "megakit/Prop_Crate4"], [Vector3(24, 0, 256), "essentials/Prop_Crate"],
			[Vector3(-40, 0, 268), "essentials/Prop_Crate_Large"], [Vector3(8, 0, 268), "megakit/Prop_Crate4"],
			[Vector3(40, 0, 280), "essentials/Prop_Crate"], [Vector3(-24, 0, 280), "megakit/Prop_Crate4"],
			[Vector3(-56, 0, 238), "megakit/Prop_Barrel_Large"], [Vector3(56, 0, 286), "megakit/Prop_Barrel_Large"]]:
		out.append(_prop_box(c[1], c[0]))
	return out


static func solar_pieces() -> Array:
	var out := []
	for z in [238.0, 250.0, 262.0, 274.0, 286.0]:
		for x in [-48.0, -32.0, -16.0, 0.0, 16.0, 32.0, 48.0]:
			out.append(["megakit/Platform_Metal2", Transform3D(
					Basis.from_euler(Vector3(deg_to_rad(-25.0), 0, 0)) * Basis().scaled(Vector3(5.0 / 4.0, 1, 3.0 / 4.0)),
					Vector3(x, 1.4, z))])
			out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(0.4, 0.24, 0.4)), Vector3(x, 0, z))])
	for c in [[Vector3(-40, 0, 244), "essentials/Prop_Crate"], [Vector3(40, 0, 244), "megakit/Prop_Crate4"],
			[Vector3(-8, 0, 256), "megakit/Prop_Crate4"], [Vector3(24, 0, 256), "essentials/Prop_Crate"],
			[Vector3(-40, 0, 268), "essentials/Prop_Crate_Large"], [Vector3(8, 0, 268), "megakit/Prop_Crate4"],
			[Vector3(40, 0, 280), "essentials/Prop_Crate"], [Vector3(-24, 0, 280), "megakit/Prop_Crate4"],
			[Vector3(-56, 0, 238), "megakit/Prop_Barrel_Large"], [Vector3(56, 0, 286), "megakit/Prop_Barrel_Large"]]:
		out.append([c[1], Transform3D(Basis(), c[0])])
	return out


static func solar_decor() -> Array:
	var out := []
	for x in [-48.0, -32.0, -16.0, 0.0, 16.0, 32.0, 48.0]:
		out.append([Kind.TRIM_CYAN, Vector3(x, 2.05, 260.7), Vector3(5, 0.06, 0.06), Vector3.ZERO])
	return out


static func solar_lights() -> Array:
	var cyan := Color(0.35, 0.9, 1.0)
	var orange := Color(1.0, 0.55, 0.2)
	return [
		[Vector3(0, 3, 250), cyan, 3.0, 12.0],
		[Vector3(0, 3, 274), orange, 2.0, 10.0],
		[Vector3(-48, 2.5, 262), cyan, 1.5, 8.0],
		[Vector3(48, 2.5, 262), cyan, 1.5, 8.0],
	]


## The Ridge (70 × 140 at (−260, 0)): rocky high ground on the west
## rim. Few buildings, scattered cover/rocks. Box bases sit on the
## terrain (ground_height at the box centre), so nothing floats on the
## slope or sinks into it.
static func ridge_boxes() -> Array:
	var out := []
	for hut in [Vector2(-258, -18), Vector2(-262, 22)]:
		var base := ground_height(hut.x, hut.y)
		out.append(_b(Kind.WALL, Vector3(hut.x - 4, base + 1.75, hut.y), Vector3(0.5, 3.5, 6)))
		out.append(_b(Kind.WALL, Vector3(hut.x + 4, base + 1.75, hut.y), Vector3(0.5, 3.5, 6)))
		out.append(_b(Kind.WALL, Vector3(hut.x, base + 1.75, hut.y - 3), Vector3(8, 3.5, 0.5)))
		out.append(_b(Kind.SLAB, Vector3(hut.x, base + 3.75, hut.y), Vector3(8.5, 0.5, 6.5)))
	var rock_sizes := [Vector3(2.5, 1.5, 2.5), Vector3(3, 1, 2), Vector3(2, 2, 2)]
	var rock_yaws := [0.0, 30.0, 60.0]
	var i := 0
	for rp in [Vector2(-290, -50), Vector2(-280, 10), Vector2(-240, -55), Vector2(-232, 40),
			Vector2(-275, 55), Vector2(-245, -20), Vector2(-285, 30), Vector2(-230, -40),
			Vector2(-265, -45), Vector2(-250, 55), Vector2(-290, 0), Vector2(-235, 15),
			Vector2(-270, -60), Vector2(-240, 60)]:
		var size: Vector3 = rock_sizes[i % 3]
		out.append(_b(Kind.COVER, Vector3(rp.x, ground_height(rp.x, rp.y) + size.y * 0.5, rp.y),
			size, Vector3(0, rock_yaws[i % 3], 0)))
		i += 1
	out.append(_b(Kind.COVER, Vector3(-258, ground_height(-258, 0) + 0.6, 0), Vector3(4, 1.2, 0.5)))
	out.append(_b(Kind.COVER, Vector3(-270, ground_height(-270, -35) + 0.6, -35), Vector3(0.5, 1.2, 4)))
	out.append(_b(Kind.COVER, Vector3(-245, ground_height(-245, 35) + 0.6, 35), Vector3(0.5, 1.2, 4)))
	return out


static func ridge_pieces() -> Array:
	var out := []
	for hut in [Vector2(-258, -18), Vector2(-262, 22)]:
		var base := ground_height(hut.x, hut.y)
		_tile(out, "megakit/Platform_Metal", hut.x - 4, hut.x + 4, hut.y - 3, hut.y + 3, base)
		SpireLayout._clad(out, Vector3(hut.x - 4, base + 1.75, hut.y), Vector3(0.5, 3.5, 6), 1000.0, 1000.0)
		SpireLayout._clad(out, Vector3(hut.x + 4, base + 1.75, hut.y), Vector3(0.5, 3.5, 6), 1000.0, 1000.0)
		SpireLayout._clad(out, Vector3(hut.x, base + 1.75, hut.y - 3), Vector3(8, 3.5, 0.5), 1000.0, 1000.0)
	var rock_sizes := [Vector3(2.5, 1.5, 2.5), Vector3(3, 1, 2), Vector3(2, 2, 2)]
	var i := 0
	for rp in [Vector2(-290, -50), Vector2(-280, 10), Vector2(-240, -55), Vector2(-232, 40),
			Vector2(-275, 55), Vector2(-245, -20), Vector2(-285, 30), Vector2(-230, -40),
			Vector2(-265, -45), Vector2(-250, 55), Vector2(-290, 0), Vector2(-235, 15),
			Vector2(-270, -60), Vector2(-240, 60)]:
		var size: Vector3 = rock_sizes[i % 3]
		out.append(["megakit/Prop_Crate4", Transform3D(
				Basis(Vector3.UP, deg_to_rad([0.0, 30.0, 60.0][i % 3])) * Basis().scaled(size / 1.12),
				Vector3(rp.x, ground_height(rp.x, rp.y), rp.y))])
		i += 1
	return out


static func ridge_decor() -> Array:
	var out := []
	for hut in [Vector2(-258, -18), Vector2(-262, 22)]:
		var base := ground_height(hut.x, hut.y)
		out.append([Kind.TRIM_ORANGE, Vector3(hut.x, base + 4.03, hut.y), Vector3(8.5, 0.06, 0.06), Vector3.ZERO])
	return out


static func ridge_lights() -> Array:
	var orange := Color(1.0, 0.55, 0.2)
	return [
		[Vector3(-258, ground_height(-258, -18) + 5, -18), orange, 3.0, 9.0],
		[Vector3(-262, ground_height(-262, 22) + 5, 22), orange, 3.0, 9.0],
	]


## Crater Rim (200 × 200 at the centre): the crashed supply ship with
## the match's best loot and no cover worth the name. Hull from large
## slabs/walls/columns, tilted; the ship sits dug into the bowl, so its
## bases use ground_height and its low end is buried, not floating.
static func crater_boxes() -> Array:
	var out := [
		_b(Kind.SLAB, Vector3(0, -4.5, 0), Vector3(44, 2, 14), Vector3(0, 0, 6)),
		_b(Kind.SLAB, Vector3(25, -5.8, 0), Vector3(10, 1.5, 10), Vector3(0, 0, -10)),
		_b(Kind.WALL, Vector3(0, -1.5, 0), Vector3(16, 4, 8), Vector3(0, 0, 6)),
		_b(Kind.SLAB, Vector3(-18, -6, 12), Vector3(20, 1, 10), Vector3(12, 20, 0)),
	]
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			out.append(_b(Kind.COLUMN, Vector3(16 * sx, -3, 5 * sz), Vector3(2, 6, 2)))
	for c in [[Vector3(30, 0, 15), "essentials/Prop_Crate_Large"], [Vector3(-30, 0, -12), "essentials/Prop_Crate"],
			[Vector3(15, 0, 25), "megakit/Prop_Crate4"], [Vector3(-12, 0, -28), "megakit/Prop_Crate4"],
			[Vector3(38, 0, -8), "essentials/Prop_Crate"], [Vector3(-38, 0, 18), "essentials/Prop_Crate_Large"],
			[Vector3(8, 0, -35), "megakit/Prop_Barrel_Large"], [Vector3(-8, 0, 35), "megakit/Prop_Barrel_Large"]]:
		var p: Vector3 = c[0]
		out.append(_prop_box(c[1], Vector3(p.x, ground_height(p.x, p.z), p.z)))
	for r in [Vector3(45, 0, 30), Vector3(-50, 0, -25), Vector3(60, 0, -15), Vector3(-60, 0, 40)]:
		out.append(_b(Kind.COVER, Vector3(r.x, ground_height(r.x, r.z) + 0.75, r.z), Vector3(3, 1.5, 3)))
	return out


static func crater_pieces() -> Array:
	var out := []
	for x in [-16.5, -5.5, 5.5, 16.5]:
		out.append(["megakit/Platform_DarkPlates", Transform3D(
				Basis.from_euler(Vector3(0, 0, deg_to_rad(6.0))) * Basis().scaled(Vector3(11.0 / 4.0, 1, 14.0 / 4.0)),
				Vector3(x, -3.4, 0))])
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(2, 1.2, 2)), Vector3(16 * sx, -6, 5 * sz))])
	for c in [[Vector3(30, 0, 15), "essentials/Prop_Crate_Large"], [Vector3(-30, 0, -12), "essentials/Prop_Crate"],
			[Vector3(15, 0, 25), "megakit/Prop_Crate4"], [Vector3(-12, 0, -28), "megakit/Prop_Crate4"],
			[Vector3(38, 0, -8), "essentials/Prop_Crate"], [Vector3(-38, 0, 18), "essentials/Prop_Crate_Large"],
			[Vector3(8, 0, -35), "megakit/Prop_Barrel_Large"], [Vector3(-8, 0, 35), "megakit/Prop_Barrel_Large"]]:
		var p: Vector3 = c[0]
		out.append([c[1], Transform3D(Basis(), Vector3(p.x, ground_height(p.x, p.z), p.z))])
	return out


static func crater_decor() -> Array:
	return [
		[Kind.TRIM_ORANGE, Vector3(0, -3.4, -7), Vector3(44, 0.06, 0.06), Vector3(0, 0, 6)],
		[Kind.TRIM_ORANGE, Vector3(0, -3.4, 7), Vector3(44, 0.06, 0.06), Vector3(0, 0, 6)],
		[Kind.SPIRE_GLOW, Vector3(-22, -4, 0), Vector3(0.3, 3, 3), Vector3.ZERO],
		[Kind.SPIRE_GLOW, Vector3(-22, -4, -4), Vector3(0.06, 2, 0.4), Vector3.ZERO],
	]


static func crater_lights() -> Array:
	var cyan := Color(0.35, 0.9, 1.0)
	var orange := Color(1.0, 0.55, 0.2)
	return [
		[Vector3(0, 2, 0), orange, 5.0, 18.0],
		[Vector3(20, -4, 0), cyan, 3.0, 10.0],
		[Vector3(-20, -4, 0), cyan, 3.0, 10.0],
	]


## Scatter sites: ~25 small stops (a hut, a relay, a wreck) in the gaps
## between named districts. Each entry: [x, z, kind]. All sit outside
## every other district rect, outside the Foundry quarter and clear of
## the crater's steep bowl (ground_height at the site is the base).
static func scatter_sites() -> Array:
	return [
		[-120, -320, "hut"], [-200, -320, "relay"], [-120, -200, "wreck"],
		[-200, -120, "hut"], [-320, -160, "relay"], [-320, 80, "wreck"],
		[-320, 160, "hut"], [-280, 300, "relay"], [-150, 320, "wreck"],
		[-60, 340, "hut"], [60, 340, "relay"], [150, 320, "wreck"],
		[280, 300, "hut"], [300, 120, "relay"], [300, -120, "wreck"],
		[120, -320, "hut"], [200, -320, "relay"], [320, 40, "wreck"],
		[320, -80, "hut"], [140, 80, "relay"], [80, 140, "wreck"],
		[-80, 140, "hut"], [-80, -140, "relay"], [80, -140, "wreck"],
		[-140, -80, "hut"],
	]


static func scatter_boxes() -> Array:
	var out := []
	for s in scatter_sites():
		var x := float(s[0])
		var z := float(s[1])
		var base := ground_height(x, z)
		match String(s[2]):
			"hut":
				out.append(_b(Kind.WALL, Vector3(x - 2, base + 1.25, z), Vector3(0.4, 2.5, 4)))
				out.append(_b(Kind.WALL, Vector3(x + 2, base + 1.25, z), Vector3(0.4, 2.5, 4)))
				out.append(_b(Kind.SLAB, Vector3(x, base + 2.7, z), Vector3(4.5, 0.4, 4.5)))
				out.append(_prop_box("essentials/Prop_Crate", Vector3(x + 1, base, z + 1)))
			"relay":
				out.append(_b(Kind.COLUMN, Vector3(x, base + 3, z), Vector3(0.8, 6, 0.8)))
				out.append(_b(Kind.COVER, Vector3(x, base + 0.5, z), Vector3(2, 1, 2)))
				out.append(_prop_box("essentials/Prop_SatelliteDish", Vector3(x + 1.5, base, z)))
			"wreck":
				out.append(_b(Kind.COVER, Vector3(x, base + 0.5, z), Vector3(3, 1, 2), Vector3(0, 30, 8)))
				out.append(_b(Kind.COVER, Vector3(x + 2.5, base + 0.4, z + 1), Vector3(2, 0.8, 1.5), Vector3(0, -20, -6)))
				out.append(_prop_box("megakit/Prop_Crate4", Vector3(x - 1.5, base, z - 1.5)))
				out.append(_prop_box("essentials/Prop_Crate", Vector3(x + 1, base, z - 2)))
	return out


static func scatter_pieces() -> Array:
	var out := []
	for s in scatter_sites():
		var x := float(s[0])
		var z := float(s[1])
		var base := ground_height(x, z)
		match String(s[2]):
			"hut":
				_tile(out, "megakit/Platform_Metal", x - 2, x + 2, z - 2, z + 2, base)
				out.append(["essentials/Prop_Crate", Transform3D(Basis(), Vector3(x + 1, base, z + 1))])
			"relay":
				out.append(["megakit/Column_Round", Transform3D(Basis().scaled(Vector3(0.8, 1.2, 0.8)), Vector3(x, base, z))])
				out.append(["essentials/Prop_SatelliteDish", Transform3D(Basis(), Vector3(x + 1.5, base, z))])
			"wreck":
				out.append(["megakit/Prop_Crate4", Transform3D(Basis(), Vector3(x - 1.5, base, z - 1.5))])
				out.append(["essentials/Prop_Crate", Transform3D(Basis(), Vector3(x + 1, base, z - 2))])
	return out


static func scatter_decor() -> Array:
	var out := []
	for s in scatter_sites():
		var x := float(s[0])
		var z := float(s[1])
		var base := ground_height(x, z)
		if String(s[2]) == "hut":
			out.append([Kind.TRIM_CYAN, Vector3(x, base + 2.93, z), Vector3(4.5, 0.06, 0.06), Vector3.ZERO])
		elif String(s[2]) == "relay":
			out.append([Kind.SPIRE_GLOW, Vector3(x, base + 6.1, z), Vector3(0.3, 0.3, 0.3), Vector3.ZERO])
	return out


static func scatter_lights() -> Array:
	var cyan := Color(0.35, 0.9, 1.0)
	var orange := Color(1.0, 0.55, 0.2)
	var out := []
	for s in scatter_sites():
		var x := float(s[0])
		var z := float(s[1])
		var base := ground_height(x, z)
		if String(s[2]) == "relay":
			out.append([Vector3(x, base + 5, z), cyan, 2.0, 7.0])
		elif String(s[2]) == "hut":
			out.append([Vector3(x, base + 2.5, z), orange, 1.5, 6.0])
	return out


## ---- District dispatch -----------------------------------------------
static func district_boxes(dname: String) -> Array:
	match dname:
		"Docking Port":
			return docking_boxes()
		"Halcyon Spire":
			return spire_boxes()
		"Vesper Foundry":
			return quarter_boxes()
		"Hydro Domes":
			return hydro_boxes()
		"Solar Flats":
			return solar_boxes()
		"The Ridge":
			return ridge_boxes()
		"Crater Rim":
			return crater_boxes()
		"Scatter sites":
			return scatter_boxes()
	return []


static func district_pieces(dname: String) -> Array:
	match dname:
		"Docking Port":
			return docking_pieces()
		"Halcyon Spire":
			return spire_pieces()
		"Vesper Foundry":
			return quarter_pieces()
		"Hydro Domes":
			return hydro_pieces()
		"Solar Flats":
			return solar_pieces()
		"The Ridge":
			return ridge_pieces()
		"Crater Rim":
			return crater_pieces()
		"Scatter sites":
			return scatter_pieces()
	return []


static func district_decor(dname: String) -> Array:
	match dname:
		"Docking Port":
			return docking_decor()
		"Halcyon Spire":
			return spire_decor()
		"Vesper Foundry":
			return quarter_decor()
		"Hydro Domes":
			return hydro_decor()
		"Solar Flats":
			return solar_decor()
		"The Ridge":
			return ridge_decor()
		"Crater Rim":
			return crater_decor()
		"Scatter sites":
			return scatter_decor()
	return []


static func district_lights(dname: String) -> Array:
	match dname:
		"Docking Port":
			return docking_lights()
		"Halcyon Spire":
			return spire_lights()
		"Vesper Foundry":
			return quarter_lights()
		"Hydro Domes":
			return hydro_lights()
		"Solar Flats":
			return solar_lights()
		"The Ridge":
			return ridge_lights()
		"Crater Rim":
			return crater_lights()
		"Scatter sites":
			return scatter_lights()
	return []


## ---- Aggregates ------------------------------------------------------
## Collision boxes: ALL island boxes (every district).
static func boxes() -> Array:
	var out := []
	for dname in district_names():
		out.append_array(district_boxes(dname))
	return out


## Kit pieces (visual only): [model, Transform3D], all districts.
static func pieces() -> Array:
	var out := []
	for dname in district_names():
		out.append_array(district_pieces(dname))
	return out


## Visual-only detail, all districts: [kind, centre, size, rotation].
static func decor() -> Array:
	var out := []
	for dname in district_names():
		out.append_array(district_decor(dname))
	return out


## Baked accent lights, all districts: [position, color, energy, range].
static func lights() -> Array:
	var out := []
	for dname in district_names():
		out.append_array(district_lights(dname))
	return out


## World-space AABB of a layout box, honouring its rotation (corners, not
## just centre ± size / 2, so tilted ramps are not under-counted).
static func box_aabb(b: Array) -> AABB:
	var basis := Basis.from_euler((b[3] as Vector3) * (PI / 180.0))
	var centre: Vector3 = b[1]
	var half: Vector3 = (b[2] as Vector3) * 0.5
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for cx in [-1.0, 1.0]:
		for cy in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				var p := centre + basis * Vector3(half.x * cx, half.y * cy, half.z * cz)
				lo = lo.min(p)
				hi = hi.max(p)
	return AABB(lo, hi - lo)


## Build the cached AABB list + 16 m spatial hash (cell expansion 1 m, so
## lookups are exact for any margin <= 1 m).
static func _ensure_index() -> void:
	if not _aabbs.is_empty():
		return
	var all := boxes()
	for i in all.size():
		var a := box_aabb(all[i])
		_aabbs.append(a)
		var x0 := int(floor((a.position.x - 1.0) / 16.0))
		var x1 := int(floor((a.end.x + 1.0) / 16.0))
		var z0 := int(floor((a.position.z - 1.0) / 16.0))
		var z1 := int(floor((a.end.z + 1.0) / 16.0))
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var key := Vector2i(cx, cz)
				if not _cells.has(key):
					_cells[key] = []
				(_cells[key] as Array).append(i)


## True when `point` (island coords) would put a fighter inside a
## collision box, expanded horizontally by `margin`. Floor slabs (top
## y = 0 on flat ground) never block a point standing on them; walls,
## cover, props and raised decks do.
static func point_blocked(point: Vector3, margin: float = SPAWN_CLEARANCE) -> bool:
	_ensure_index()
	var key := Vector2i(int(floor(point.x / 16.0)), int(floor(point.z / 16.0)))
	var ids: Array = _cells.get(key, [])
	for i in ids:
		var a: AABB = _aabbs[i]
		if point.y < a.position.y or point.y > a.end.y:
			continue
		if point.x < a.position.x - margin or point.x > a.end.x + margin:
			continue
		if point.z < a.position.z - margin or point.z > a.end.z + margin:
			continue
		return true
	return false


## The Foundry quarter spawns, exactly as before: a jittered 4 m grid
## over the quarter floor (56 × 40 m), filtered by point_blocked() so
## every spawn stands on free ground. Same seed, same loop order, same
## 94 points as the original quarter-only layout.
static func quarter_spawn_points() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261108
	var gx := -26.0
	while gx <= 26.0:
		var gz := -18.0
		while gz <= 18.0:
			var p := Vector3(
				gx + rng.randf_range(-0.9, 0.9),
				0.05,
				gz + rng.randf_range(-0.9, 0.9))
			if not point_blocked(p + QUARTER_OFFSET):
				out.append(Transform3D(
					Basis(Vector3.UP, atan2(p.x, p.z)),
					p + QUARTER_OFFSET))
			gz += 4.0
		gx += 4.0
	return out


## Spawn points: the quarter spawns above, plus a jittered 5 m grid over
## the rest of the island, filtered by point_blocked() so every spawn
## stands on free ground at y = ground_height + 0.05. Deterministic
## (fixed seeds). 50 fighters need 50 distinct spawns; the island grid
## yields thousands, spread across every district.
static func spawn_points() -> Array[Transform3D]:
	if not _spawn_cache.is_empty():
		return _spawn_cache.duplicate()
	var out: Array[Transform3D] = []
	out.append_array(quarter_spawn_points())
	var quarter := district_rect("Vesper Foundry")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261109
	var gx := -395.0
	while gx <= 395.0:
		var gz := -395.0
		while gz <= 395.0:
			var jx := gx + rng.randf_range(-1.0, 1.0)
			var jz := gz + rng.randf_range(-1.0, 1.0)
			if not (jx >= quarter.position.x and jx <= quarter.end.x
					and jz >= quarter.position.y and jz <= quarter.end.y):
				var p := Vector3(jx, ground_height(jx, jz) + 0.05, jz)
				if not point_blocked(p):
					out.append(Transform3D(Basis(Vector3.UP, atan2(p.x, p.z)), p))
			gz += SPAWN_SPACING
		gx += SPAWN_SPACING
	_spawn_cache = out
	return out.duplicate()


## One Foundry box translated into island space: [kind, centre, size,
## rotation (Euler degrees)]. FoundryLayout is the single source — the
## quarter is never re-listed here.
static func offset_box(b: Array) -> Array:
	return [b[0], (b[1] as Vector3) + QUARTER_OFFSET, b[2], b[3]]


## Pickup spots: the Foundry quarter's (translated) plus a few per new
## district, same shape ({"weapon", "position", "respawn_ticks"}) and no
## new weapon types. Crater Rim gets the best loot (rail sniper + arc
## launcher); Hydro Domes lean to grenades.
static func pickup_spots() -> Array:
	var out := []
	for s in FoundryLayout.pickup_spots():
		var spot: Dictionary = (s as Dictionary).duplicate()
		spot["position"] = (s["position"] as Vector3) + QUARTER_OFFSET
		out.append(spot)
	for s in SpireLayout.pickup_spots():
		var spot: Dictionary = (s as Dictionary).duplicate()
		spot["position"] = (s["position"] as Vector3) + spire_offset()
		out.append(spot)
	var extra := [
		{"weapon": &"rail_sniper", "position": Vector3(-42, 0, -280), "respawn_ticks": 7200},
		{"weapon": &"arc_launcher", "position": Vector3(60, 4, -260), "respawn_ticks": 5400},
		{"weapon": &"grenade", "position": Vector3(-54, 0, -245), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(30, 0, -270), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(170, 0, 163), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(200, 0, 163), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(170, 0, 207), "respawn_ticks": 1200},
		{"weapon": &"arc_launcher", "position": Vector3(200, 0, 207), "respawn_ticks": 5400},
		{"weapon": &"grenade", "position": Vector3(-24, 0, 244), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(24, 0, 268), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(0, 0, 280), "respawn_ticks": 1200},
		{"weapon": &"arc_launcher", "position": Vector3(0, 0, 256), "respawn_ticks": 5400},
		{"weapon": &"rail_sniper", "position": Vector3(-252, ground_height(-252, 0), 0), "respawn_ticks": 7200},
		{"weapon": &"grenade", "position": Vector3(-280, ground_height(-280, -40), -40), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(-240, ground_height(-240, 45), 45), "respawn_ticks": 1200},
		{"weapon": &"rail_sniper", "position": Vector3(30, ground_height(30, 0), 0), "respawn_ticks": 7200},
		{"weapon": &"arc_launcher", "position": Vector3(-35, ground_height(-35, 10), 10), "respawn_ticks": 5400},
		{"weapon": &"grenade", "position": Vector3(12, ground_height(12, -20), -20), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(-15, ground_height(-15, 22), 22), "respawn_ticks": 1200},
		{"weapon": &"grenade", "position": Vector3(0, ground_height(0, -32), -32), "respawn_ticks": 1200},
	]
	for s in extra:
		out.append(s)
	return out


## Jump pads: the Foundry quarter's and the Spire's (translated), plus
## pads where a district needs vertical traversal — up the Ridge crest
## and onto the crashed ship's hull.
static func jump_pads() -> Array:
	var out := []
	for pad in FoundryLayout.jump_pads():
		out.append({
			"position": (pad["position"] as Vector3) + QUARTER_OFFSET,
			"target": (pad["target"] as Vector3) + QUARTER_OFFSET,
		})
	for pad in SpireLayout.jump_pads():
		out.append({
			"position": (pad["position"] as Vector3) + spire_offset(),
			"target": (pad["target"] as Vector3) + spire_offset(),
		})
	out.append({
		"position": Vector3(-218, ground_height(-218, 0), 0),
		"target": Vector3(-252, ground_height(-252, 0), 0),
	})
	out.append({
		"position": Vector3(14, ground_height(14, -10), -10),
		"target": Vector3(0, -3.5, 0),
	})
	return out


## Flag bases: the Foundry pair, translated (unused in BR, harmless).
static func flag_bases() -> Array:
	var out := []
	for v in FoundryLayout.flag_bases():
		out.append((v as Vector3) + QUARTER_OFFSET)
	return out


## Hash of everything the layout is built from.
static func layout_hash() -> String:
	return var_to_str([boxes(), decor(), pieces(), lights()]).sha256_text()
