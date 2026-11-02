extends TestCase
## Phase 3 battle rules: matchups, commands, terrain, leaders, endings, aftermath, AI personalities.
## Win-rate checks run a few hundred battles; tests/balance_report.gd runs 10k per scenario.

var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/battle.json"))


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _army(name: String, n: int, mix: Array, rng: RandomNumberGenerator, kind: String = "lord") -> Party:
	var p := Party.new(name)
	p.name = name
	p.kind = kind
	p.roster = Roster.make(n, mix, [1.0, 0.0, 0.0], rng)
	p.gold = 1000
	return p


## Share of battles side A wins, AI vs AI.
func _win_rate(runs: int, n_a: int, mix_a: Array, n_b: int, mix_b: Array, terrain := "plains", role_a := "memer", role_b := "memer") -> float:
	var rng := _rng(1234)
	var wins := 0
	for i in runs:
		var a := _army("A", n_a, mix_a, rng)
		var b := _army("B", n_b, mix_b, rng)
		var r := AutoResolve.resolve(a, b, role_a, role_b, terrain, rules, rng)
		if r["winner"] == a:
			wins += 1
	return wins / float(runs)


const INF := [1, 0, 0]
const ARC := [0, 1, 0]
const CAV := [0, 0, 1]
const MIXED := [0.5, 0.3, 0.2]


func test_matrices_encode_the_intended_counters() -> void:
	var tm: Dictionary = rules["type_matchup"]
	check(tm["infantry"]["cavalry"] > tm["cavalry"]["infantry"], "pikes beat horse")
	check(tm["cavalry"]["archers"] > tm["archers"]["cavalry"], "horse beats bows")
	check(tm["archers"]["infantry"] > tm["infantry"]["archers"], "bows beat foot")
	var cm: Dictionary = rules["command_matchup"]
	for pair in [["flank", "hold"], ["hold", "charge"], ["charge", "flank"], ["charge", "advance"]]:
		check(cm[pair[0]][pair[1]] > cm[pair[1]][pair[0]], "%s beats %s" % pair)
	for cmd in Battle.COMMANDS:
		check_eq(rules["counter"].has(cmd), true, "counter for " + cmd)
		var c: String = rules["counter"][cmd]
		check(cm[c][cmd] >= 1.2, "counter to %s (%s) is strong: %s" % [cmd, c, cm[c][cmd]])


func test_rock_paper_scissors_holds_in_battle() -> void:
	var inf_vs_cav := _win_rate(300, 40, INF, 40, CAV)
	var cav_vs_arc := _win_rate(300, 40, CAV, 40, ARC)
	var arc_vs_inf := _win_rate(300, 40, ARC, 40, INF)
	print("     infantry>cavalry %.2f  cavalry>archers %.2f  archers>infantry %.2f" % [inf_vs_cav, cav_vs_arc, arc_vs_inf])
	check(inf_vs_cav > 0.6, "infantry beat equal cavalry: %.2f" % inf_vs_cav)
	check(cav_vs_arc > 0.75, "cavalry beat equal archers: %.2f" % cav_vs_arc)
	check(arc_vs_inf > 0.55, "archers beat equal infantry: %.2f" % arc_vs_inf)


func test_numbers_and_fairness() -> void:
	var even := _win_rate(400, 40, MIXED, 40, MIXED)
	var double := _win_rate(300, 60, MIXED, 30, MIXED)
	check(even > 0.42 and even < 0.58, "mirror match is a coin flip: %.2f" % even)
	check(double > 0.9, "double numbers almost always win: %.2f" % double)


func test_terrain_and_leaders_matter() -> void:
	var plains := _win_rate(300, 40, CAV, 40, MIXED, "plains")
	var marsh := _win_rate(300, 40, CAV, 40, MIXED, "marsh")
	check(plains > marsh + 0.2, "cavalry fare far worse in the marsh: plains %.2f marsh %.2f" % [plains, marsh])
	var skill := _win_rate(300, 40, MIXED, 40, MIXED, "plains", "tryhard", "newbie")
	check(skill > 0.6, "a tryhard beats a newbie with the same army: %.2f" % skill)


func test_command_choice_matters_against_a_predictable_enemy() -> void:
	# The enemy always holds: flanking it should beat charging into it.
	var flank_wins := 0
	var charge_wins := 0
	var rng := _rng(77)
	for i in 300:
		for cmd in ["flank", "charge"]:
			var a := _army("A", 40, MIXED, rng)
			var b := _army("B", 40, MIXED, rng)
			var battle := Battle.new(a, b, "player", "memer", "plains", rules, rng)
			while not battle.over:
				battle.play_round(cmd, "hold")
			if battle.outcome["winner"] == a:
				if cmd == "flank":
					flank_wins += 1
				else:
					charge_wins += 1
	check(flank_wins > charge_wins + 60, "flank %d vs charge %d wins against Hold" % [flank_wins, charge_wins])


func test_round_mechanics_and_endings() -> void:
	var rng := _rng(5)
	var ends := {"routed": 0, "fled": 0, "withdrew": 0}
	for i in 200:
		var a := _army("A", 40, MIXED, rng)
		var b := _army("B", 40, MIXED, rng)
		var before_a := a.troops() + Roster.size(a.wounded)
		var battle := Battle.new(a, b, "memer", "trader", "plains", rules, rng)
		battle.auto_play()
		check(battle.round <= int(rules["max_rounds"]), "at most max_rounds")
		check_eq(a.troops() + Roster.size(a.wounded) + battle.losses["a"]["killed"], before_a, "every loss is killed or wounded")
		for k in ends:
			if battle.outcome[k]:
				ends[k] += 1
	print("     endings over 200 battles: %s" % str(ends))
	for k in ends:
		check(ends[k] > 0, "some battles end by '%s'" % k)


func test_retreat_with_cavalry_escapes_more_often() -> void:
	var b_rules := rules
	var horse := 0
	var foot := 0
	var rng := _rng(9)
	for i in 400:
		var run := Battle.new(_army("A", 30, CAV, rng), _army("B", 30, INF, rng), "memer", "memer", "plains", b_rules, rng)
		if run.escape_chance(run.a, run.b) > Battle.new(_army("C", 30, INF, rng), _army("D", 30, CAV, rng), "memer", "memer", "plains", b_rules, rng).escape_chance(run.b, run.a):
			horse += 1
		else:
			foot += 1
	check_eq(foot, 0, "cavalry always escape more easily than infantry")


func test_finish_applies_loot_prisoners_and_capture_once() -> void:
	var rng := _rng(11)
	var you := _army("You", 80, MIXED, rng, "player")
	var lord := _army("Lord", 15, MIXED, rng, "lord")
	lord.persona_id = "persona_001"
	var battle := Battle.new(you, lord, "player", "newbie", "plains", rules, rng)
	while not battle.over:
		battle.play_round("advance", "advance")
	var r := battle.finish()
	check_eq(r["winner"], you)
	check_eq(r["loot"], 500, "half the lord's 1000 gold")
	check_eq(you.gold, 1500)
	if r["routed"]:
		check(r["captured"], "a routed lord beaten by the player is captured")
		check_eq(you.prisoners, r["prisoners"])
	check_eq(battle.finish(), r, "finish() is idempotent")
	check_eq(you.gold, 1500, "no double loot")


func test_ai_personalities() -> void:
	var rng := _rng(21)
	var a := _army("A", 40, MIXED, rng)
	var b := _army("B", 40, MIXED, rng)
	var battle := Battle.new(a, b, "tryhard", "roleplayer", "plains", rules, rng)
	var counters := 0
	var rp_retreats := 0
	for i in 400:
		if battle.ai_command(a, b, "tryhard", "hold") == "flank":
			counters += 1
		if battle.ai_command(b, a, "roleplayer", "") == "retreat":
			rp_retreats += 1
	check(counters > 200, "tryhards mostly counter the last command: %d/400" % counters)
	check_eq(rp_retreats, 0, "roleplayers never retreat")
	for cmd in Battle.COMMANDS:
		check(Battle.COMMANDS.has(battle.ai_command(a, b, "memer", cmd)), "valid command")
