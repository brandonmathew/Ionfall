extends GutTest
## Gyroscope aiming (phones): the sensor reports screen-relative axes, so
## yaw comes from gyro.y and pitch from gyro.x in every orientation, with
## invert toggles, and the deadzone swallows rest drift. (The first version
## mapped the device's portrait axes; the S25 showed the axes swapped.)

const RATES := Vector3(0.5, 0.25, 0.1)


func test_screen_axes_mapping() -> void:
	# Yaw from gyro.y, pitch from gyro.x.
	var d := GyroAim.map_rates(RATES, DisplayServer.SCREEN_LANDSCAPE, false, false)
	assert_eq(d, Vector2(0.25, 0.5), "yaw = +gyro.y, pitch = +gyro.x")


func test_mapping_is_orientation_independent() -> void:
	var want := Vector2(0.25, 0.5)
	for orientation in [DisplayServer.SCREEN_PORTRAIT, DisplayServer.SCREEN_LANDSCAPE,
			DisplayServer.SCREEN_REVERSE_LANDSCAPE, DisplayServer.SCREEN_REVERSE_PORTRAIT]:
		assert_eq(GyroAim.map_rates(RATES, orientation, false, false), want,
				"screen axes follow the display, so orientation changes nothing")


func test_invert_flags() -> void:
	var d := GyroAim.map_rates(RATES, DisplayServer.SCREEN_LANDSCAPE, true, true)
	assert_eq(d, Vector2(-0.25, -0.5), "both inverts flip both deltas")
	d = GyroAim.map_rates(RATES, DisplayServer.SCREEN_LANDSCAPE, true, false)
	assert_eq(d, Vector2(-0.25, 0.5), "yaw invert flips only yaw")


func test_deadzone() -> void:
	assert_eq(GyroAim.deadzone(0.02), 0.0, "below the deadzone reads as zero")
	assert_eq(GyroAim.deadzone(-0.02), 0.0, "deadzone is symmetric")
	assert_almost_eq(GyroAim.deadzone(0.05), 0.02, 0.0001, "above it keeps the excess")
	assert_almost_eq(GyroAim.deadzone(-0.05), -0.02, 0.0001, "negative too")
