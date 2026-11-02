extends TestCase
## The world simulation on the real continent (Phase 2 acceptance: a 30-day headless run with
## all 120 lords, no stuck parties, event counts logged).

const DAYS := 30

var gs: Node
var _long: World            # the 30-day run, shared by the tests that inspect it
var _log := []              # [kind, data] for every sim event of the long run


func _state() -> Node:
	if gs == null:
		gs = load("res://scripts/autoload/game_state.gd").new()
		gs.load_all("res://data/generated", "res://data/world")
	return gs


func cleanup() -> void:
	if _long != null:
		# the logging lambda captures this suite: suite -> world -> lambda -> suite is a cycle
		for c in _long.sim_event.get_connections():
			_long.sim_event.disconnect(c["callable"])
		_long = null
	if gs != null:
		gs.free()


func _long_run() -> World:
	if _long == null:
		_long = _state().new_world(42)
		_long.sim_event.connect(func(kind, data): _log.append([kind, data]))
		var t0 := Time.get_ticks_msec()
		_long.step(24.0 * DAYS)
		print("     30-day sim: %d ms, events %s, parties %d (bandits %d, caravans %d)" % [
			Time.get_ticks_msec() - t0, str(_long.event_counts), _long.parties.size(),
			_long.count_kind("bandit"), _long.count_kind("caravan")])
	return _long


func _archetype(party_id: String) -> String:
	var p: Party = _long.by_id.get(party_id)
	return "" if p == null or p.persona_id == "" else _state().personas[p.persona_id]["archetype"]


func test_lords_spawn_at_home_with_persona_sized_armies() -> void:
	var w: World = _state().new_world(1)
	var lords := w.parties.filter(func(p): return p.kind == "lord")
	check_eq(lords.size(), 120)
	var by_type := {}
	for p in lords:
		var home: Dictionary = w.settlements[p.home]
		check_eq(home["faction"], p.faction, p.id)
		check(home["type"] != "village", "%s lives in a town or castle" % p.id)
		check_eq(p.position, w.terrain.cell_to_world(home["cell"]))
		by_type.get_or_add(w.personas[p.persona_id]["archetype"], []).append(p.troops())
	var avg := func(a): return a.reduce(func(x, y): return x + y, 0) / float(a.size())
	check(avg.call(by_type["tryhard"]) > avg.call(by_type["newbie"]) + 15, "tryhards field bigger armies than newbies")


func test_thirty_days_run_without_stuck_parties() -> void:
	var w := _long_run()
	var stuck := w.stuck_parties().map(func(p): return "%s(%s, goal %s)" % [p.id, p.kind, p.goal])
	check_eq(stuck, [], "stuck parties")
	check_eq(w.parties.filter(func(p): return p.kind == "lord").size(), 120, "lords are routed and respawn, never deleted")
	for p in w.parties:
		if p.is_active(w.time):
			check(w.terrain.is_passable(w.terrain.world_to_cell(p.position)), "%s on impassable ground" % p.id)


func test_the_world_actually_happens() -> void:
	var w := _long_run()
	for kind in ["battle", "village_raided", "trade", "recruited", "caravan_arrived", "bandits_spawned", "caravan_spawned"]:
		check(w.event_counts.get(kind, 0) > 0, "no '%s' events in %d days" % [kind, DAYS])
	for id in w.state:
		var pr: float = w.state[id]["prosperity"]
		check(pr >= 0.0 and pr <= 100.0, "%s prosperity %f" % [id, pr])


func test_personas_shape_behaviour() -> void:
	_long_run()
	var raids := {}
	var trades := {}
	for e in _log:
		var a := _archetype(e[1].get("party", ""))
		if e[0] == "village_raided":
			raids[a] = raids.get(a, 0) + 1
		elif e[0] == "trade":
			trades[a] = trades.get(a, 0) + 1
	var per_lord := func(counts: Dictionary, arch: String) -> float:
		var n: int = _state().personas.values().filter(func(p): return p["archetype"] == arch).size()
		return counts.get(arch, 0) / float(n)
	print("     raids/lord griefer %.2f trader %.2f | trades/lord trader %.2f griefer %.2f" % [
		per_lord.call(raids, "griefer"), per_lord.call(raids, "trader"), per_lord.call(trades, "trader"), per_lord.call(trades, "griefer")])
	check(per_lord.call(raids, "griefer") > per_lord.call(raids, "trader"), "griefers raid more than traders")
	check(per_lord.call(trades, "trader") > per_lord.call(trades, "griefer"), "traders trade more than griefers")


func test_same_seed_same_history() -> void:
	var a: World = _state().new_world(9)
	var b: World = _state().new_world(9)
	a.step(72.0)
	b.step(72.0)
	check_eq(a.event_counts, b.event_counts)
	check_eq(a.parties.map(func(p): return p.position), b.parties.map(func(p): return p.position))


func _duel_world() -> World:
	var w: World = _state().new_world(3)
	for p in w.parties.duplicate():
		w.remove_party(p)
	return w


func _lord(w: World, pid: String, cell: Vector2i, troops: int) -> Party:
	var per: Dictionary = w.personas[pid]
	var p := Party.new("lord_" + pid, w.terrain.cell_to_world(cell))
	p.kind = "lord"
	p.persona_id = pid
	p.faction = per["faction"]
	p.home = w.settlements.keys().filter(func(id): return w.settlements[id]["faction"] == p.faction and w.settlements[id]["type"] == "town")[0]
	p.roster = Roster.make(troops, [1, 0, 0], [1, 0, 0], w.rng)
	w.add_party(p)
	return p


func _pid(w: World, faction: String) -> String:
	var ids := w.personas.keys().filter(func(id): return w.personas[id]["faction"] == faction)
	ids.sort()
	return ids[0]


func test_weak_lord_flees_and_strong_lord_chases() -> void:
	var w := _duel_world()
	var start: Vector2i = w.settlements["town_05_01"]["cell"]   # regency vs ashlands are at war
	var strong := _lord(w, _pid(w, "faction_03"), start + Vector2i(4, 0), 80)
	var weak := _lord(w, _pid(w, "faction_05"), start, 10)
	w.personas[strong.persona_id]["ai_weights"]["aggression"] = 0.9
	w.step(1.0)
	check_eq(weak.goal, "flee", "10 troops next to 80 enemies run")
	check_eq(strong.goal, "chase", "80 troops go after 10")
	check_eq(strong.goal_target, weak.id)


func test_contact_between_enemies_is_a_battle() -> void:
	var w := _duel_world()
	var cell: Vector2i = w.settlements["town_01_01"]["cell"]   # republic vs fen are at war
	_lord(w, _pid(w, "faction_01"), cell, 40)
	_lord(w, _pid(w, "faction_02"), cell, 40)
	w.step(0.25)
	check_eq(w.event_counts.get("battle", 0), 1)
