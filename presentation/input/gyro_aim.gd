class_name GyroAim
extends RefCounted
## Gyroscope aiming for phones (Android/iOS): tilting the phone turns the
## view, like the gyro aim in Fortnite / PUBG Mobile. Rate-based, so there is
## no absolute orientation to drift: the phone's angular velocity each frame
## becomes a look delta, fed into InputAdapter like mouse and touch look.
##
## Axis mapping: Godot reports the gyroscope in SCREEN coordinates on
## Android (remapped to the current display orientation), not in the
## device's natural portrait axes — the first version mapped portrait
## axes and the S25 showed the axes swapped (tilt up/down turned the view
## left/right). So the mapping is the same in every orientation: yaw from
## gyro.y, pitch from gyro.x. Look deltas follow the mouse convention: a
## negative yaw delta turns the view right, a positive pitch delta looks
## up. If a phone reports a sign the other way round, the Settings
## screen's invert toggles fix it without a rebuild. Needs
## input_devices/sensors/enable_gyroscope in project.godot.

## Rest drift below this angular velocity (rad/s) is ignored.
const DEADZONE := 0.03
## Samples count as "at rest" for the bias capture below this rate.
const REST_RATE := 0.15
## Bias capture lasts this long after gyro is (re)enabled.
const CALIBRATE_SECONDS := 1.0

var _bias := Vector3.ZERO
var _bias_samples := 0
var _calibrating := true
var _calibrate_until_msec := 0
var _enabled_was := false
var _smoothed := Vector2.ZERO
## Last raw rates, for the diagnostics overlay.
var last_rates := Vector3.ZERO
var _frames_with_data := 0
var _frames_enabled := 0


## (yaw, pitch) look rates in rad/s for sensor `rates`, before sensitivity
## and invert. Pure: unit-tested. `orientation` is kept for the caller's
## sake (the screen axes already follow the display), the mapping itself
## does not depend on it.
static func map_rates(rates: Vector3, _orientation: int, invert_yaw: bool, invert_pitch: bool) -> Vector2:
	var d := Vector2(rates.y, rates.x)
	if invert_yaw:
		d.x = -d.x
	if invert_pitch:
		d.y = -d.y
	return d


## Soft deadzone: rest drift reads as zero, real motion keeps its size.
static func deadzone(v: float) -> float:
	if absf(v) < DEADZONE:
		return 0.0
	return v - signf(v) * DEADZONE


## One frame of gyro look. Reads Settings live, so toggling gyro in the
## Settings screen applies without restarting the match. Does nothing when
## gyro is off, on a device without a sensor, or while input is disabled
## (menus, dead): the mouse behaves the same way.
func update(delta: float, adapter: InputAdapter) -> void:
	var enabled: bool = Settings.get_value("input", "gyro_enabled")
	if not enabled or not Platform.is_mobile() or not adapter.enabled:
		_enabled_was = false
		_smoothed = Vector2.ZERO
		return
	if not _enabled_was:
		# Freshly enabled (or a new match): re-zero the sensor bias.
		_calibrating = true
		_bias = Vector3.ZERO
		_bias_samples = 0
		_calibrate_until_msec = Time.get_ticks_msec() + int(CALIBRATE_SECONDS * 1000.0)
	_enabled_was = true
	_frames_enabled += 1
	last_rates = Input.get_gyroscope()
	if last_rates.length() > 0.001:
		_frames_with_data += 1
	if _calibrating:
		if Time.get_ticks_msec() > _calibrate_until_msec:
			_calibrating = false
		elif last_rates.length() < REST_RATE:
			# At rest: fold this sample into the bias.
			_bias = (_bias * _bias_samples + last_rates) / (_bias_samples + 1)
			_bias_samples += 1
	var rates := last_rates - _bias
	var target := map_rates(rates,
			DisplayServer.screen_get_orientation(),
			bool(Settings.get_value("input", "gyro_invert_yaw")),
			bool(Settings.get_value("input", "gyro_invert_pitch")))
	target.x = deadzone(target.x)
	target.y = deadzone(target.y)
	# Light smoothing: the sensor is already steady, this only takes the
	# edge off single-frame spikes.
	_smoothed = _smoothed.lerp(target, 0.5)
	if str(Settings.get_value("input", "gyro_mode")) == "aiming" and not adapter.aim_held():
		return
	var sens: float = Settings.get_value("input", "gyro_sensitivity")
	adapter.add_look(_smoothed.x * sens * adapter.look_scale * delta,
			_smoothed.y * sens * adapter.look_scale * delta)


## One line for the diagnostics overlay (F3 / three-finger tap): raw sensor
## rates plus the look rates they produce, so a wrong axis mapping can be
## seen on the phone instead of guessed at.
func status_text() -> String:
	if not bool(Settings.get_value("input", "gyro_enabled")):
		return "gyro off"
	if _frames_enabled > 120 and _frames_with_data == 0:
		return "gyro on, no sensor data (this device may lack a gyroscope)"
	return "gyro x %+.2f y %+.2f z %+.2f -> yaw %+.2f pitch %+.2f rad/s%s" % [
		last_rates.x, last_rates.y, last_rates.z,
		_smoothed.x, _smoothed.y,
		" (calibrating: hold still)" if _calibrating else "",
	]
