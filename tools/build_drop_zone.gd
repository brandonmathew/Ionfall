extends SceneTree
## Builds the Drop Zone presentation in chunks (REVISED Phase 1: the FULL
## 800 × 800 m island at final quality, PLAN §4): one scene per chunk in
## maps/drop_zone/chunks/chunk_00.tscn .. chunk_15.tscn, plus the rewritten
## maps/drop_zone/presentation.tscn. Run headless after changing the
## layout (Worker A's drop_zone_layout.gd):
##
##   godot --headless -s tools/build_drop_zone.gd
##
## Per chunk: the chunk's boxes + decor merged into one lightmap-unwrapped
## mesh per kind (the build_map.gd _merge approach, 0.2 m texels), the
## chunk's kit pieces instanced from DropZoneLayout.pieces(), one visual
## terrain mesh from ground_height() on the 10 m grid, the chunk's accent
## lights (BAKE_STATIC, as on the other maps), and an unbaked LightmapGI
## ready for tools/bake_lightmaps.sh on a GPU machine. Each chunk scene
## is self-contained (its meshes + pieces + lights).
##
## The Vesper Foundry quarter is NOT rebuilt: its boxes, pieces, decor
## and lights are skipped here because the main presentation still
## instances the existing baked Foundry presentation at the quarter
## offset. Chunk 11 therefore holds only the quarter's neighbours (the
## Hydro Domes' east pads, scatter sites) plus its terrain.
##
## The main presentation holds the island's WorldEnvironment + Sun (added
## first, so it wins over the Foundry instance's own environment), the
## FoundryQuarter instance (its Sun hidden, so the island is not
## double-lit), one silhouette box per district, and the ChunkLoader.

const MAP_LOOK := preload("res://tools/map_look.gd")
const TEXEL_SIZE := 0.2  ## lightmap texel size in metres (build_map.gd)
const Kind := SpireLayout.Kind
## Box kinds drawn as merged boxes; the rest are drawn by kit pieces or
## are invisible (build_spire.gd's partition).
const BOX_KINDS := [Kind.SLAB, Kind.WALL, Kind.COVER, Kind.TRIM_CYAN, Kind.TRIM_ORANGE, Kind.SPIRE_GLOW]
const DIR := "res://maps/drop_zone/"
const CHUNK_DIR := "res://maps/drop_zone/chunks/"
const MESH_DIR := "res://maps/drop_zone/chunks/meshes/"
## Foundry's grade and lighting, carried to the island (build_spire.gd).
const GRADE := {"shadows": Color(0.02, 0.0, 0.03), "highlights": Color(0.03, 0.01, -0.02), "contrast": 0.18}
const SUN_ROTATION := Vector3(-38.0, 60.0, 0.0)
const SUN_COLOR := Color(1.0, 0.84, 0.68)
const SUN_ENERGY := 1.45
const LIGHTMAP_COLOR := Color(0.44, 0.4, 0.42)
const LIGHTMAP_ENERGY := 1.15

var _panel: Texture2D = load("res://art/textures/panel_grid.png")
var _kit: Dictionary = {}  ## model -> PackedScene
var _errors := 0
## Quarter-origin content, keyed so the chunk builder can skip it.
var _q_boxes := {}
var _q_pieces := {}
var _q_decor := {}
var _q_lights := {}


func _init() -> void:
	for b in DropZoneLayout.quarter_boxes():
		_q_boxes[_box_key(b)] = true
	for p in DropZoneLayout.quarter_pieces():
		_q_pieces[_piece_key(p)] = true
	for d in DropZoneLayout.quarter_decor():
		_q_decor[_box_key(d)] = true
	for l in DropZoneLayout.quarter_lights():
		_q_lights[str(l[0])] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MESH_DIR))
	var total_tris := 0
	var total_pieces := 0
	for idx in 16:
		var stats := _build_chunk(idx)
		total_tris += stats[0]
		total_pieces += stats[1]
		print("build_drop_zone chunk %02d: %d tris, %d pieces, %d lights" % [idx, stats[0], stats[1], stats[2]])
	_build_presentation()
	print("build_drop_zone: 16 chunks, %d tris, %d pieces, errors %d" % [total_tris, total_pieces, _errors])
	quit(0 if _errors == 0 else 1)


func _box_key(b: Array) -> String:
	return "%d|%s" % [b[0], str(b[1])]


func _piece_key(p: Array) -> String:
	return "%s|%s" % [p[0], str((p[1] as Transform3D).origin)]


## Builds one chunk scene; returns [triangles, pieces, lights].
func _build_chunk(idx: int) -> Array:
	var boxes: Array = []
	for b in DropZoneLayout.boxes_for_chunk(idx):
		if not _q_boxes.has(_box_key(b)):
			boxes.append(b)
	var decor: Array = []
	for d in DropZoneLayout.decor():
		var c: Vector3 = d[1]
		if DropZoneLayout.chunk_index_for(c.x, c.z) == idx and not _q_decor.has(_box_key(d)):
			decor.append(d)
	var pieces: Array = []
	for p in DropZoneLayout.pieces():
		var t: Transform3D = p[1]
		if DropZoneLayout.chunk_index_for(t.origin.x, t.origin.z) == idx and not _q_pieces.has(_piece_key(p)):
			pieces.append(p)
	var lights: Array = []
	for l in DropZoneLayout.lights():
		var pos: Vector3 = l[0]
		if DropZoneLayout.chunk_index_for(pos.x, pos.z) == idx and not _q_lights.has(str(pos)):
			lights.append(l)
	var root := Node3D.new()
	root.name = "DropZoneChunk%02d" % idx
	root.set_meta("chunk_index", idx)
	root.set_meta("layout_hash", DropZoneLayout.layout_hash())
	var by_kind: Dictionary = {}
	for b in boxes + decor:
		if b[0] in BOX_KINDS:
			if not by_kind.has(b[0]):
				by_kind[b[0]] = SurfaceTool.new()
			var box := BoxMesh.new()
			box.size = b[2]
			by_kind[b[0]].append_from(box, 0, Transform3D(Basis.from_euler((b[3] as Vector3) * (PI / 180.0)), b[1]))
	var triangles := 0
	for kind: int in by_kind:
		var mesh := _commit(by_kind[kind], _box_material(kind))
		var kind_name: String = Kind.keys()[kind].to_lower()
		var path := MESH_DIR + "chunk_%02d_%s.res" % [idx, kind_name]
		triangles += _save_mesh(root, kind_name.to_pascal_case(), mesh, path)
	var terrain := _terrain_mesh(idx)
	triangles += _save_mesh(root, "Terrain", terrain, MESH_DIR + "chunk_%02d_terrain.res" % idx)
	var terrain_node := root.find_child("Terrain", false, false) as MeshInstance3D
	if terrain_node != null:
		terrain_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for n in pieces.size():
		var model: String = pieces[n][0]
		var scene := _kit_scene(model)
		if scene == null:
			continue
		var inst := scene.instantiate()
		inst.name = "Piece%d" % n
		(inst as Node3D).transform = pieces[n][1]
		root.add_child(inst)
	var i := 0
	for l in lights:
		var omni := OmniLight3D.new()
		omni.name = "Accent%d" % i
		omni.position = l[0]
		omni.light_color = l[1]
		omni.light_energy = l[2]
		omni.omni_range = l[3]
		omni.light_bake_mode = Light3D.BAKE_STATIC
		root.add_child(omni)
		i += 1
	# Unbaked for now (no GPU in this VM): tools/bake_lightmaps.sh can
	# bake each chunk scene in place on a machine with a display.
	var lm := LightmapGI.new()
	lm.name = "LightmapGI"
	lm.bounces = 2
	lm.shadowmask_mode = LightmapGIData.SHADOWMASK_MODE_OVERLAY
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = LIGHTMAP_COLOR
	lm.environment_custom_energy = LIGHTMAP_ENERGY
	root.add_child(lm)
	for n in root.get_children():
		n.owner = root
	var scene := PackedScene.new()
	scene.pack(root)
	var err := ResourceSaver.save(scene, CHUNK_DIR + "chunk_%02d.tscn" % idx)
	if err != OK:
		printerr("build_drop_zone: saving chunk %02d failed: %s" % [idx, error_string(err)])
		_errors += 1
	root.free()
	return [triangles, pieces.size(), lights.size()]


## Commits `st` with `material`, unwraps it for the lightmap.
func _commit(st: SurfaceTool, material: Material) -> ArrayMesh:
	st.index()
	var mesh := st.commit()
	mesh.surface_set_material(0, material)
	mesh.lightmap_unwrap(Transform3D.IDENTITY, TEXEL_SIZE)
	return MapMaterials.converted(mesh)


## Saves `mesh`, adds it as a static MeshInstance3D, returns triangles.
func _save_mesh(root: Node3D, node_name: String, mesh: ArrayMesh, path: String) -> int:
	if mesh.get_surface_count() == 0 or mesh.surface_get_array_index_len(0) == 0:
		printerr("build_drop_zone: empty mesh for %s, not saving" % path)
		_errors += 1
		return 0
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		printerr("build_drop_zone: saving %s failed: %s" % [path, error_string(err)])
		_errors += 1
		return 0
	mesh = load(path)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return mesh.surface_get_array_index_len(0) / 3


## The chunk's visual terrain: ground_height() on the 10 m grid, same
## patches as the gameplay collision, wound so the faces point up. No
## lightmap unwrap: at 0.2 m texels a 200 × 200 m patch would need a
## ~1000 × 1000 lightmap of its own, so the terrain stays dynamically
## lit (gi_mode DISABLED, set by the caller) under the sun.
## Normals are analytic (the heightfield gradient), NOT
## SurfaceTool.generate_normals(): in Godot 4.7 generate_normals()
## returns normals OPPOSITE to the winding — the 1.0.8 terrain shipped
## with all 441 normals pointing down, so the sun (above) lit nothing
## and the ground read as the red sky. The winding stays up (front
## faces up, CULL_BACK); the normals now point up too.
func _terrain_mesh(idx: int) -> ArrayMesh:
	var rect := DropZoneLayout.chunk_rect(idx)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := int(DropZoneLayout.CHUNK_SIZE / 10.0)
	for i in steps:
		for j in steps:
			var x0 := rect.position.x + i * 10.0
			var z0 := rect.position.y + j * 10.0
			var a := Vector3(x0, DropZoneLayout.ground_height(x0, z0), z0)
			var b := Vector3(x0 + 10.0, DropZoneLayout.ground_height(x0 + 10.0, z0), z0)
			var c := Vector3(x0, DropZoneLayout.ground_height(x0, z0 + 10.0), z0 + 10.0)
			var d := Vector3(x0 + 10.0, DropZoneLayout.ground_height(x0 + 10.0, z0 + 10.0), z0 + 10.0)
			st.set_normal(_terrain_normal(a.x, a.z))
			st.add_vertex(a)
			st.set_normal(_terrain_normal(c.x, c.z))
			st.add_vertex(c)
			st.set_normal(_terrain_normal(b.x, b.z))
			st.add_vertex(b)
			st.set_normal(_terrain_normal(b.x, b.z))
			st.add_vertex(b)
			st.set_normal(_terrain_normal(c.x, c.z))
			st.add_vertex(c)
			st.set_normal(_terrain_normal(d.x, d.z))
			st.add_vertex(d)
	st.index()
	var mesh := st.commit()
	mesh.surface_set_material(0, _terrain_material())
	return MapMaterials.converted(mesh)


## Up-facing normal of the heightfield at (x, z), from the gradient of
## ground_height() (central differences on the 10 m grid step).
func _terrain_normal(x: float, z: float) -> Vector3:
	var e := 10.0
	var dx := (DropZoneLayout.ground_height(x + e, z) - DropZoneLayout.ground_height(x - e, z)) / (2.0 * e)
	var dz := (DropZoneLayout.ground_height(x, z + e) - DropZoneLayout.ground_height(x, z - e)) / (2.0 * e)
	return Vector3(-dx, 1.0, -dz).normalized()


func _kit_scene(model: String) -> PackedScene:
	if not _kit.has(model):
		var path := SpireLayout.model_path(model)
		var scene := load(path) as PackedScene
		if scene == null:
			printerr("build_drop_zone: kit model missing: %s" % path)
			_errors += 1
		_kit[model] = scene
	return _kit[model]


func _box_material(kind: int) -> StandardMaterial3D:
	match kind:
		Kind.SLAB: return _panels(Color(0.2, 0.22, 0.26), 0.5, 0.6, 0.4)
		Kind.WALL: return _panels(Color(0.18, 0.2, 0.24), 0.5, 0.6, 0.4)
		Kind.COVER: return _panels(Color(0.3, 0.34, 0.4), 1.0, 0.55, 0.3)
		Kind.TRIM_CYAN: return _emissive(Color(0.35, 0.9, 1.0), 2.6)
		Kind.TRIM_ORANGE: return _emissive(Color(1.0, 0.6, 0.25), 3.0)
		Kind.SPIRE_GLOW: return _emissive(Color(0.4, 0.92, 1.0), 6.0)
	return StandardMaterial3D.new()


func _terrain_material() -> StandardMaterial3D:
	return _panels(Color(0.2, 0.22, 0.27), 0.25, 0.75, 0.1)


func _panels(color: Color, scale: float, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = _panel
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	m.roughness = roughness
	m.metallic = metallic
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


## The rewritten main presentation: island environment + sun, the baked
## Foundry quarter, one silhouette per district, the chunk loader.
func _build_presentation() -> void:
	var root := Node3D.new()
	root.name = "DropZonePresentation"
	root.set_meta("layout_hash", DropZoneLayout.layout_hash())
	# Added first: the first WorldEnvironment in tree order is the one
	# that takes effect, so the island's env wins over the Foundry
	# instance's own (kept inert below it).
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://maps/station/space_sky.gdshader")
	sky_mat.set_shader_parameter("space_color", Color(0.03, 0.012, 0.012))
	sky_mat.set_shader_parameter("nebula_color", Color(0.32, 0.1, 0.06))
	sky_mat.set_shader_parameter("planet_color", Color(0.5, 0.18, 0.08))
	sky_mat.set_shader_parameter("rim_color", Color(1.0, 0.55, 0.25))
	sky_mat.set_shader_parameter("star_density", 0.004)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.38, 0.4)
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.45, 0.3, 0.24)
	# Foundry's 0.005 was tuned for a 64 m arena; at island scale it
	# would fog out every far district, silhouettes included.
	env.fog_density = 0.0015
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = SUN_ROTATION
	sun.light_energy = SUN_ENERGY
	sun.light_color = SUN_COLOR
	sun.light_bake_mode = Light3D.BAKE_DYNAMIC
	sun.shadow_enabled = true
	# Foundry's 40 m was tuned for a 64 m arena; the island needs
	# shadows across the player's surroundings, not just the quarter.
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	root.add_child(sun)
	# The baked quarter, reused as-is. Its own Sun cannot be hidden in
	# this scene file (PackedScene.pack() drops overrides on children of
	# an instance); the ChunkLoader hides it at load time instead, so
	# the island is not lit twice. Its WorldEnvironment stays (inert:
	# the island's, added first, is the one that takes effect) and its
	# LightmapGI + accent lights keep the quarter baked as before.
	var quarter := (load("res://maps/foundry/presentation.tscn") as PackedScene).instantiate()
	quarter.name = "FoundryQuarter"
	(quarter as Node3D).transform = Transform3D(Basis(), DropZoneLayout.QUARTER_OFFSET)
	root.add_child(quarter)
	# One silhouette per district: flat grey massing, always in the
	# scene; the ChunkLoader hides a district's box while any of its
	# chunks is loaded. Vesper Foundry's full presentation is always
	# loaded, so its silhouette is a 1 m foundation plinth, not a box
	# that would hide the real quarter.
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.55, 0.57, 0.6)
	grey.roughness = 0.9
	for dname in DropZoneLayout.district_names():
		var rect := DropZoneLayout.district_rect(dname)
		var height := 1.0
		for d in DropZoneLayout.districts():
			if d["name"] == dname:
				height = float(d["height"])
		var box := BoxMesh.new()
		box.size = Vector3(rect.size.x, height, rect.size.y)
		box.material = grey
		var mi := MeshInstance3D.new()
		mi.name = "Silhouette_" + dname.replace(" ", "")
		mi.mesh = box
		mi.position = Vector3(rect.get_center().x, height * 0.5, rect.get_center().y)
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	var loader := Node.new()
	loader.name = "ChunkLoader"
	var loader_script := load("res://maps/drop_zone/chunk_loader.gd")
	if loader_script == null:
		printerr("build_drop_zone: chunk_loader.gd failed to load")
		_errors += 1
	loader.set_script(loader_script)
	root.add_child(loader)
	MAP_LOOK.finish(root, GRADE)
	for n in root.get_children():
		n.owner = root
	var scene := PackedScene.new()
	scene.pack(root)
	var err := ResourceSaver.save(scene, DIR + "presentation.tscn")
	if err != OK:
		printerr("build_drop_zone: saving presentation failed: %s" % error_string(err))
		_errors += 1
	else:
		print("build_drop_zone: presentation saved (%s)" % error_string(err))
	root.free()
