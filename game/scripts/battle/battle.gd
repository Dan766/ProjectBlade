class_name Battle
extends RefCounted
## One battle between parties `a` and `b`, fought in rounds (rules: res://data/config/battle.json).
##
## Each round both sides pick a command. A side's damage is
##   W^(numbers_exponent - 1) x sum over its troop types t of  (troops_t weighted by tier power)
##     x  matchup of t against the enemy's mix  x  command bonus for t  x  terrain modifier for t
##   x  command-vs-command multiplier  x  leader skill  x  luck
## and damage x lethality = troops hit, spread over the enemy's stacks (weaker tiers more
## exposed), each hit killed or wounded. The battle ends when a side drops below rout_below of
## its starting strength (routed), escapes with Retreat, or max_rounds pass (the side that held up
## worse withdraws). finish() then applies loot, prisoners, drill (XP) and morale, exactly once.
##
## The player's battle screen calls play_round() with the player's choice; AI battles use auto_play().

const COMMANDS: Array[String] = ["hold", "advance", "flank", "charge", "retreat"]

var a: Party
var b: Party
var role_a: String               # leader / AI key: archetype, "bandit", "caravan" or "player"
var role_b: String
var terrain_name: String
var rules: Dictionary
var rng: RandomNumberGenerator

var round := 0
var over := false
var log: Array[String] = []
var last_cmd := {"a": "", "b": ""}
var start_a := 0.0
var start_b := 0.0
var losses := {"a": {"killed": 0, "wounded": 0}, "b": {"killed": 0, "wounded": 0}}
var outcome := {}                # winner, loser, routed, fled, withdrew, rounds
var _finished := {}


func _init(party_a: Party, party_b: Party, a_role: String, b_role: String, terrain: String, battle_rules: Dictionary, random: RandomNumberGenerator) -> void:
	a = party_a
	b = party_b
	role_a = a_role
	role_b = b_role
	terrain_name = terrain if battle_rules["terrain"].has(terrain) else "plains"
	rules = battle_rules
	rng = random
	start_a = strength(a)
	start_b = strength(b)


func strength(p: Party) -> float:
	return Roster.strength(p.roster, rules["tier_power"])


func mix(p: Party) -> Dictionary:
	var total := float(maxi(1, p.troops()))
	var out := {}
	for t in Roster.TYPES:
		out[t] = (p.roster[t][0] + p.roster[t][1] + p.roster[t][2]) / total
	return out


## Damage `side` deals this round, before luck.
func power(side: Party, cmd: String, enemy: Party, enemy_cmd: String, role: String) -> float:
	var enemy_mix := mix(enemy)
	var tm: Dictionary = rules["type_matchup"]
	var bonus: Dictionary = rules["command_type_bonus"][cmd]
	var ground: Dictionary = rules["terrain"][terrain_name]
	var total := 0.0
	var all_weighted := 0.0
	for t in Roster.TYPES:
		var weighted := 0.0
		for tier in 3:
			weighted += side.roster[t][tier] * float(rules["tier_power"][tier])
		if weighted <= 0.0:
			continue
		all_weighted += weighted
		var vs := 0.0
		for u in Roster.TYPES:
			vs += enemy_mix[u] * float(tm[t][u])
		total += weighted * vs * float(bonus[t]) * float(ground[t])
	# Damage grows sub-linearly with army size (numbers_exponent < 1): more troops still help, but
	# a 25% edge no longer snowballs over the rounds into a near-certain win against good tactics.
	if all_weighted > 0.0:
		total *= pow(all_weighted, float(rules.get("numbers_exponent", 1.0)) - 1.0)
	return total * float(rules["command_matchup"][cmd][enemy_cmd]) * float(rules["leader"].get(role, 1.0))


## Play one round with both commands. Returns a short summary (also appended to `log`).
func play_round(cmd_a: String, cmd_b: String) -> String:
	if over:
		return ""
	round += 1
	var luck: Array = rules["luck"]
	var pa := power(a, cmd_a, b, cmd_b, role_a) * rng.randf_range(luck[0], luck[1])
	var pb := power(b, cmd_b, a, cmd_a, role_b) * rng.randf_range(luck[0], luck[1])
	if cmd_a == "retreat":
		pb *= float(rules["retreat_incoming"])
	if cmd_b == "retreat":
		pa *= float(rules["retreat_incoming"])
	var hit_b := _apply_hits(b, pa * float(rules["lethality"]), "b")
	var hit_a := _apply_hits(a, pb * float(rules["lethality"]), "a")
	last_cmd = {"a": cmd_a, "b": cmd_b}
	var line := "Round %d: %s %s, %s %s. %s lose %d (%d dead), %s lose %d (%d dead)." % [
		round, a.name, cmd_a, b.name, cmd_b, a.name, hit_a[0] + hit_a[1], hit_a[0], b.name, hit_b[0] + hit_b[1], hit_b[0]]
	log.append(line)

	if cmd_a == "retreat" and rng.randf() < escape_chance(a, b):
		_end(b, a, "fled")
	elif cmd_b == "retreat" and rng.randf() < escape_chance(b, a):
		_end(a, b, "fled")
	elif strength(a) < float(rules["rout_below"]) * start_a:
		_end(b, a, "routed")
	elif strength(b) < float(rules["rout_below"]) * start_b:
		_end(a, b, "routed")
	elif round >= int(rules["max_rounds"]):
		# nobody broke: whoever kept the larger share of their strength holds the field. Exact ties
		# are common with equal armies, and `>=` gave every tie to side A (mirror matches went 56/44).
		var kept_a := strength(a) / maxf(start_a, 0.001)
		var kept_b := strength(b) / maxf(start_b, 0.001)
		if kept_a > kept_b or (is_equal_approx(kept_a, kept_b) and rng.randf() < 0.5):
			_end(a, b, "withdrew")
		else:
			_end(b, a, "withdrew")
	return line


func escape_chance(runner: Party, chaser: Party) -> float:
	var e: Dictionary = rules["escape"]
	var c: float = float(e["base"]) + float(e["own_cavalry"]) * mix(runner)["cavalry"] + float(e["enemy_cavalry"]) * mix(chaser)["cavalry"]
	return clampf(c, float(e["min"]), float(e["max"]))


func _apply_hits(p: Party, hits: float, side: String) -> Array:
	var n := int(hits) + (1 if rng.randf() < hits - int(hits) else 0)
	n = mini(n, p.troops())
	var vuln: Array = rules["tier_vulnerability"]
	var killed := 0
	var wounded := 0
	for i in n:
		var weights := []
		var keys := []
		for t in Roster.TYPES:
			for tier in 3:
				if p.roster[t][tier] > 0:
					weights.append(p.roster[t][tier] * float(vuln[tier]))
					keys.append([t, tier])
		if keys.is_empty():
			break
		var k: Array = keys[Roster._pick(weights, rng)]
		p.roster[k[0]][k[1]] -= 1
		if rng.randf() < float(rules["killed_share"]):
			killed += 1
		else:
			wounded += 1
			p.wounded[k[0]][k[1]] += 1
	losses[side]["killed"] += killed
	losses[side]["wounded"] += wounded
	return [killed, wounded]


func _end(winner: Party, loser: Party, how: String) -> void:
	over = true
	outcome = {"winner": winner, "loser": loser, "routed": how == "routed", "fled": how == "fled",
		"withdrew": how == "withdrew", "rounds": round}
	var verb: String = {"routed": "%s are routed!", "fled": "%s escape the field.", "withdrew": "%s withdraw; the field is held."}[how]
	log.append(verb % loser.name)


## The AI's command for `side` (role decides the personality), given the opponent's last command.
func ai_command(side: Party, enemy: Party, role: String, enemy_last: String) -> String:
	var w: Dictionary = (rules["ai_commands"].get(role, rules["ai_commands"]["memer"]) as Dictionary).duplicate()
	var m := mix(side)
	if m["cavalry"] > 0.4:
		w["charge"] = float(w.get("charge", 1.0)) * 1.5
		w["flank"] = float(w.get("flank", 1.0)) * 1.5
	if m["archers"] > 0.45:
		w["hold"] = float(w.get("hold", 1.0)) * 1.6
	# Retreat only when actually outmatched (by absolute strength, per personality); before this a
	# winning army sometimes bolted, and 60-v-30 battles were lost 16% of the time.
	var below: Dictionary = rules["retreat_when_below"]
	var ratio := strength(side) / maxf(strength(enemy), 0.001)
	if ratio >= float(below.get(role, below["default"])):
		w["retreat"] = 0.0
	elif ratio < 0.5:
		w["retreat"] = float(w.get("retreat", 0.0)) * float(rules["losing_retreat_boost"])
	var options := []
	var weights := []
	for key in w:
		if key.begins_with("_") or float(w[key]) <= 0.0:
			continue
		var cmd: String = key
		if key == "counter":
			if enemy_last == "":
				continue
			cmd = rules["counter"][enemy_last]
		options.append(cmd)
		weights.append(float(w[key]))
	return options[Roster._pick(weights, rng)] if options else "hold"


## Both sides choose by AI until the battle ends (AI vs AI, or auto-resolve).
func auto_play() -> void:
	while not over:
		var ca := ai_command(a, b, role_a, last_cmd["b"])
		var cb := ai_command(b, a, role_b, last_cmd["a"])
		play_round(ca, cb)


## Apply the aftermath once: loot, prisoners, drill and morale. Returns the outcome plus totals.
func finish() -> Dictionary:
	if not _finished.is_empty() or not over:
		return _finished
	var w: Party = outcome["winner"]
	var l: Party = outcome["loser"]
	var winner_side := "a" if w == a else "b"
	var loser_side := "b" if winner_side == "a" else "a"
	var loot := 0
	var prisoners := 0
	if not outcome["fled"]:
		loot = int(l.gold * float(rules["loot_share"]))
		l.gold -= loot
		w.gold += loot
		if outcome["routed"]:
			prisoners = int(losses[loser_side]["wounded"] * float(rules["prisoner_share"]))
			Roster.remove_fraction(l.wounded, float(rules["prisoner_share"]), rng)
			w.prisoners += prisoners
	var xw: Array = rules["xp"]["winner"]
	var xl: Array = rules["xp"]["loser"]
	Roster.train(w.roster, xw[0], xw[1], rng)
	Roster.train(l.roster, xl[0], xl[1], rng)
	w.morale = minf(100.0, w.morale + 10.0)
	l.morale = maxf(0.0, l.morale - (5.0 if outcome["fled"] else 20.0))
	_finished = outcome.duplicate()
	_finished.merge({
		"loot": loot, "prisoners": prisoners, "terrain": terrain_name,
		"winner_lost": losses[winner_side]["killed"] + losses[winner_side]["wounded"],
		"loser_lost": losses[loser_side]["killed"] + losses[loser_side]["wounded"],
		"losses": losses,
		"captured": l.kind == "lord" and w.kind == "player" and outcome["routed"],
	})
	return _finished
