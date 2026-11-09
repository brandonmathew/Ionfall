extends GutTest
## BR Phase 1 test flag (MatchConfig.br_phase1_test): the test match
## bypasses the phone/PC host caps (50 combatants, 49 bots); every normal
## match keeps its caps, and a default config has the flag off.


func test_flag_defaults_false() -> void:
	var c := MatchConfig.new()
	assert_false(c.br_phase1_test, "a default config is not a Phase 1 test")


func test_flag_off_keeps_pc_cap() -> void:
	var c := MatchConfig.new()
	assert_eq(c.max_combatants(), MatchConfig.PC_HOST_CAP, "PC host cap unchanged")
	assert_eq(c.max_bots(), MatchConfig.PC_HOST_CAP - 1)
	assert_eq(c.clamp_bots(99, false), MatchConfig.PC_HOST_CAP - 1, "bots clamp to the PC cap")


func test_flag_off_keeps_online_cap() -> void:
	var c := MatchConfig.new()
	c.online = true
	assert_eq(c.max_combatants(), MatchConfig.PC_ONLINE_HOST_CAP, "online host cap unchanged")
	assert_eq(c.max_bots(), MatchConfig.PC_ONLINE_HOST_CAP - 1)


func test_flag_on_raises_cap_to_fifty() -> void:
	var c := MatchConfig.new()
	c.br_phase1_test = true
	assert_eq(c.max_combatants(), MatchConfig.BR_PHASE1_TEST_COMBATANTS)
	assert_eq(c.max_combatants(), 50)
	assert_eq(c.max_bots(), 49)


func test_flag_on_clamps_bots_to_49() -> void:
	var c := MatchConfig.new()
	c.br_phase1_test = true
	assert_eq(c.clamp_bots(49, false), 49, "the test match takes 49 bots")
	assert_eq(c.clamp_bots(99, false), 49, "more than 49 clamps to 49")
	assert_eq(c.clamp_bots(1, false), 1)
	assert_eq(c.clamp_bots(0, false), 1, "at least one bot unless none allowed")
	assert_eq(c.clamp_bots(0, true), 0, "none allowed when the caller allows it")


func test_flag_on_ignores_online_cap() -> void:
	var c := MatchConfig.new()
	c.online = true
	c.br_phase1_test = true
	assert_eq(c.max_combatants(), 50, "the test flag wins over the online cap too")


func test_test_config_fields() -> void:
	# The config the Solo page's test button builds (menu: OFFLINE,
	# drop_zone, FFA, 49 bots, flag on).
	var c := MatchConfig.new()
	c.mode = MatchConfig.Mode.OFFLINE
	c.map = "drop_zone"
	c.game_mode = GameMode.FFA
	c.bots = 49
	c.br_phase1_test = true
	assert_eq(c.max_combatants(), 50)
	assert_eq(c.clamp_bots(c.bots, false), 49)
