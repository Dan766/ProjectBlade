extends TestCase
## The player in the world: bandits hunt them, contact opens a battle instead of auto-resolving,
## and the battle screen's result flows back through World.apply_player_battle().

var gs: Node


func _state() -> Node:
	if gs == null:
		gs = load("res://scripts/autoload/game_state.gd").new()
		gs.load_all("res://data/generated", "res://data/world")
	return gs


func cleanup() -> void:
	if gs != null:
		gs.free()


func _empty_world() -> World:
	var w: World = _state().new_world(5)
	for p in w.parties.duplicate():
		w.remove_party(p)
	return w


func _party(w: World, id: String, kind: String, cell: Vector2i, troops: int) -> Party:
	var p := Party.new(id, w.terrain.cell_to_world(cell))
	p.kind = kind
	p.name = id
	p.roster = Roster.make(troops, [0.5, 0.3, 0.2], [1, 0, 0], w.rng)
	w.add_party(p)
	return p


func test_bandits_engage_the_player_and_open_a_battle() -> void:
	var w := _empty_world()
	var cell: Vector2i = w.settlements["town_05_01"]["cell"]
	var you := _party(w, "player", "player", cell, 30)
	var bandits := _party(w, "bandits_x", "bandit", cell, 15)
	var asked := []
	w.battle_requested.connect(func(p, e): asked.append([p, e]))
	w.step(0.25)
	check_eq(asked.size(), 1, "one battle request")
	check_eq(asked[0][0], you)
	check_eq(asked[0][1], bandits)
	check_eq(w.event_counts.get("battle", 0), 0, "not auto-resolved")
	w.step(0.25)
	check_eq(asked.size(), 1, "no second request while one is pending")


func test_lords_ignore_the_player_unless_attacked() -> void:
	var w := _empty_world()
	var cell: Vector2i = w.settlements["town_05_01"]["cell"]
	var you := _party(w, "player", "player", cell, 30)
	var lord := _party(w, "lord_x", "lord", cell, 30)
	check(not w.hostile(you, lord), "neutral by default")
	w.player_attack(lord)
	check(w.hostile(you, lord), "hostile once the player attacks")


func test_player_victory_over_a_lord_captures_and_ransoms() -> void:
	var w := _empty_world()
	var cell: Vector2i = w.settlements["town_05_01"]["cell"]
	var you := _party(w, "player", "player", cell, 120)
	var pid: String = w.personas.keys()[0]
	var lord := _party(w, "lord_" + pid, "lord", cell, 10)
	lord.persona_id = pid
	lord.faction = w.personas[pid]["faction"]
	lord.home = "town_05_01"
	var events := []
	w.sim_event.connect(func(k, d): events.append([k, d]))
	var battle := Battle.new(you, lord, "player", w.role(lord), "plains", w.battle_rules, w.rng)
	while not battle.over:
		battle.play_round("charge", "hold")
	var r := battle.finish()
	check_eq(r["winner"], you)
	var gold_before := you.gold
	w.battle_pending = true
	w.apply_player_battle(r, "ransom")
	check(not w.battle_pending, "pending cleared")
	var kinds := events.map(func(e): return e[0])
	check(kinds.has("player_battle"), "player_battle event")
	if r["captured"]:
		check(kinds.has("lord_ransomed"), "ransom event")
		check_eq(you.gold, gold_before + int(w.battle_rules["lord_ransom"]))
		check(not lord.is_active(w.time), "captured lord is off the map until respawn")


func test_defeated_player_regroups_at_a_town() -> void:
	var w := _empty_world()
	var cell: Vector2i = w.settlements["village_05_01"]["cell"]
	var you := _party(w, "player", "player", cell, 5)
	var bandits := _party(w, "bandits_y", "bandit", cell, 60)
	var battle := Battle.new(you, bandits, "player", "bandit", "plains", w.battle_rules, w.rng)
	while not battle.over:
		battle.play_round("hold", "charge")
	var r := battle.finish()
	check_eq(r["winner"], bandits)
	w.apply_player_battle(r, "")
	var at := w.terrain.world_to_cell(you.position)
	var town := w.settlements.keys().filter(func(id): return w.settlements[id]["type"] == "town" and w.settlements[id]["cell"] == at)
	check_eq(town.size(), 1, "moved to a town")
	check(you.troops() > 0, "never left with zero troops")


func test_wounded_heal_over_days() -> void:
	var w := _empty_world()
	var you := _party(w, "player", "player", w.settlements["town_05_01"]["cell"], 10)
	Roster.add(you.wounded, "infantry", 0, 40)
	w.step(24.0 * 5)
	check(Roster.size(you.wounded) < 25, "most of 40 wounded recover in 5 days: %d left" % Roster.size(you.wounded))
	check_eq(you.troops() + Roster.size(you.wounded), 50, "nobody vanishes while healing")
