extends SceneTree
## Battle balance report (Phase 3 acceptance; not a unit test):
##   <godot> --headless --path game -s res://tests/balance_report.gd -- [--runs=10000]
## AI vs AI auto-resolve over many seeded battles per scenario; prints win rate, rounds and
## how battles end. Targets are in the right-hand column; tune data/config/battle.json.

const MIXED := [0.5, 0.3, 0.2]
const INF := [1, 0, 0]
const ARC := [0, 1, 0]
const CAV := [0, 0, 1]

# name, n_a, mix_a, n_b, mix_b, terrain, role_a, role_b, target
const SCENARIOS := [
	["mirror 40 v 40", 40, MIXED, 40, MIXED, "plains", "memer", "memer", "45-55%"],
	["60 v 30", 60, MIXED, 30, MIXED, "plains", "memer", "memer", ">90%"],
	["50 v 40", 50, MIXED, 40, MIXED, "plains", "memer", "memer", "85-98% (AI v AI)"],
	["infantry v cavalry", 40, INF, 40, CAV, "plains", "memer", "memer", ">60%"],
	["cavalry v archers", 40, CAV, 40, ARC, "plains", "memer", "memer", "80-95%"],
	["archers v infantry", 40, ARC, 40, INF, "plains", "memer", "memer", ">55%"],
	["cavalry v mixed, plains", 40, CAV, 40, MIXED, "plains", "memer", "memer", "cav plains >"],
	["cavalry v mixed, marsh", 40, CAV, 40, MIXED, "marsh", "memer", "memer", "  marsh + 20pts"],
	["tryhard v newbie", 40, MIXED, 40, MIXED, "plains", "tryhard", "newbie", ">60%"],
	["roleplayer v trader", 40, MIXED, 40, MIXED, "plains", "roleplayer", "trader", "~50%"],
	["lord 45 v bandits 20", 45, MIXED, 20, [0.6, 0.4, 0.0], "plains", "griefer", "bandit", ">95%"],
	["tactician 40 v memer 40", 40, MIXED, 40, MIXED, "plains", "tactician", "memer", "~50% (random foe can't be read)"],
	["always-Hold 40 v griefer 40", 40, MIXED, 40, MIXED, "plains", "always_hold", "griefer", ">70% (read the charger)"],
	["always-Flank 40 v griefer 40", 40, MIXED, 40, MIXED, "plains", "always_flank", "griefer", "<45% (misread)"],
	["always-Hold 40 v griefer 50", 40, MIXED, 50, MIXED, "plains", "always_hold", "griefer", ">30% (reading beats numbers)"],
]


func _initialize() -> void:
	var runs := 10000
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--runs="):
			runs = int(arg.trim_prefix("--runs="))
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/battle.json"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	print("%-26s %7s %7s %8s %8s %9s   target" % ["scenario", "A wins", "rounds", "routed", "fled", "withdrew"])
	var t0 := Time.get_ticks_msec()
	for sc in SCENARIOS:
		var wins := 0
		var rounds := 0
		var ends := {"routed": 0, "fled": 0, "withdrew": 0}
		for i in runs:
			var a := _army("A", sc[1], sc[2], rng)
			var b := _army("B", sc[3], sc[4], rng)
			var battle := Battle.new(a, b, sc[6], sc[7], sc[5], rules, rng)
			battle.auto_play()
			if battle.outcome["winner"] == a:
				wins += 1
			rounds += battle.round
			for k in ends:
				if battle.outcome[k]:
					ends[k] += 1
		print("%-26s %6.1f%% %7.2f %7.1f%% %7.1f%% %8.1f%%   %s" % [sc[0], 100.0 * wins / runs, float(rounds) / runs,
			100.0 * ends["routed"] / runs, 100.0 * ends["fled"] / runs, 100.0 * ends["withdrew"] / runs, sc[8]])
	print("%d battles in %d ms" % [runs * SCENARIOS.size(), Time.get_ticks_msec() - t0])
	quit(0)


func _army(name: String, n: int, mix: Array, rng: RandomNumberGenerator) -> Party:
	var p := Party.new(name)
	p.name = name
	p.kind = "lord"
	p.roster = Roster.make(n, mix, [1.0, 0.0, 0.0], rng)
	return p
