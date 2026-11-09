extends GutTest
## The 1.0.8 terrain shipped with every normal pointing DOWN:
## tools/build_drop_zone.gd used SurfaceTool.generate_normals(), which
## in Godot 4.7 returns normals opposite to the triangle winding. The
## faces were wound up (so the terrain rendered, not culled), but the
## sun above lit nothing and the ground read as the red sky — the
## island "not registering" in Brandon's 1.0.8 phone run, even though
## every chunk loaded with zero errors. The builder now sets analytic
## heightfield normals instead. These tests pin both sides: the
## winding faces up (front faces, CULL_BACK) AND the normals point up
## (lit by the sun).


func _terrain_mesh() -> ArrayMesh:
	var ps: PackedScene = load("res://maps/drop_zone/chunks/chunk_04.tscn")
	var root: Node = ps.instantiate()
	add_child_autofree(root)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if mi.name == "Terrain":
			return (mi as MeshInstance3D).mesh
	return null


func test_terrain_normals_point_up() -> void:
	var mesh := _terrain_mesh()
	assert_not_null(mesh, "chunk_04 must have a Terrain mesh")
	var arrays: Array = mesh.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_true(normals.size() > 0, "Terrain must have normals")
	var avg := Vector3.ZERO
	for n in normals:
		avg += n
		assert_gt(n.y, 0.5, "every terrain normal must point up, got %s" % str(n))
	avg /= float(normals.size())
	assert_gt(avg.y, 0.9, "average terrain normal must point up, got %s" % str(avg))


func test_terrain_winding_faces_up() -> void:
	var mesh := _terrain_mesh()
	assert_not_null(mesh, "chunk_04 must have a Terrain mesh")
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_true(idx.size() >= 3, "Terrain must have triangles")
	var face := (verts[idx[1]] - verts[idx[0]]).cross(verts[idx[2]] - verts[idx[0]]).normalized()
	assert_gt(face.y, 0.9, "terrain winding must face up (front faces for CULL_BACK), got %s" % str(face))
