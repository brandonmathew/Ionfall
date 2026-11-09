extends Node3D
## Gameplay half of Drop Zone (BR, full island): the whole island's world
## collision, jump pads and spawn points — the dedicated server loads
## just this scene (PLAN §3.1).
##
## Collision is split into 16 chunk bodies, "World_C0".."World_C15"
## (4 × 4 of 200 × 200 m; chunk index cx + cz * 4). Each body holds that
## chunk's boxes (assigned by box centre — the contract the navmesh
## worker bakes from), one ConcavePolygonShape3D terrain patch built
## from DropZoneLayout.ground_height() on a 10 m grid, and that chunk's
## jump pad areas. The terrain patches ARE the island floor outside the
## districts: there is no flat 800 × 800 floor box.


## Terrain patch for chunk `idx`: a ConcavePolygonShape3D triangulated
## from ground_height() on a 10 m grid, wound so the faces point up.
func _terrain_shape(idx: int) -> ConcavePolygonShape3D:
	var rect := DropZoneLayout.chunk_rect(idx)
	var faces := PackedVector3Array()
	var steps := int(DropZoneLayout.CHUNK_SIZE / 10.0)
	for i in steps:
		for j in steps:
			var x0 := rect.position.x + i * 10.0
			var z0 := rect.position.y + j * 10.0
			var a := Vector3(x0, DropZoneLayout.ground_height(x0, z0), z0)
			var b := Vector3(x0 + 10.0, DropZoneLayout.ground_height(x0 + 10.0, z0), z0)
			var c := Vector3(x0, DropZoneLayout.ground_height(x0, z0 + 10.0), z0 + 10.0)
			var d := Vector3(x0 + 10.0, DropZoneLayout.ground_height(x0 + 10.0, z0 + 10.0), z0 + 10.0)
			# Wound (a, b, c) / (b, d, c): Godot's concave shapes are
			# single-sided, and a ray from above only hits front faces
			# with this order (the opposite order never registers).
			faces.append_array([a, b, c, b, d, c])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var bodies: Array[StaticBody3D] = []
	for i in 16:
		var body := StaticBody3D.new()
		body.name = DropZoneLayout.chunk_name(i)
		body.collision_layer = Sim.LAYER_WORLD
		body.collision_mask = 0
		add_child(body)
		bodies.append(body)
	var boxes := DropZoneLayout.boxes()
	for b in boxes:
		var c: Vector3 = b[1]
		var idx := DropZoneLayout.chunk_index_for(c.x, c.z)
		var shape := BoxShape3D.new()
		shape.size = b[2]
		var cs := CollisionShape3D.new()
		cs.shape = shape
		var rot: Vector3 = b[3]
		cs.transform = Transform3D(Basis.from_euler(rot * (PI / 180.0)), c)
		bodies[idx].add_child(cs)
	for i in 16:
		var patch := CollisionShape3D.new()
		patch.shape = _terrain_shape(i)
		bodies[i].add_child(patch)
	var pads := DropZoneLayout.jump_pads()
	for pad in pads:
		var p: Vector3 = pad["position"]
		bodies[DropZoneLayout.chunk_index_for(p.x, p.z)].add_child(JumpPads.make_area(pad))
	Log.i("map", "drop_zone gameplay ready in %d ms: 16 chunk bodies, %d boxes, 16 terrain patches, %d jump pads" % [
			Time.get_ticks_msec() - t0, boxes.size(), pads.size()])


func spawn_points() -> Array[Transform3D]:
	return DropZoneLayout.spawn_points()


func pickup_spots() -> Array:
	return DropZoneLayout.pickup_spots()


func flag_bases() -> Array:
	return DropZoneLayout.flag_bases()


func jump_pads() -> Array:
	return DropZoneLayout.jump_pads()
