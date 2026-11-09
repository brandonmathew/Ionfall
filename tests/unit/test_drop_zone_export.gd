extends GutTest
## The 1.0.7 export broke the Drop Zone: export_presets.cfg excluded
## art/environment/scifi/*.gltf and *.bin, so the exported chunk scenes
## referenced kit models the APK did not contain. Every chunk with kit
## pieces (04 and 08 in Brandon's phone run, all 15 piece-bearing chunks
## in principle) failed to load, leaving the player walking on invisible
## collision over the sky. These tests pin the exclusion gone, so a
## preset edit can't silently break the island again.


func test_scifi_gltf_not_excluded_from_export() -> void:
	var text := FileAccess.get_file_as_string("res://export_presets.cfg")
	assert_false(text.contains("art/environment/scifi/*.gltf"),
			"scifi gltf must be exported: the chunk scenes instance those kit pieces")
	assert_false(text.contains("art/environment/scifi/*.bin"),
			"scifi gltf bin blobs must be exported with their models")
