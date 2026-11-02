extends TestCase
## Phase 5: ownership, borders, captures, the balance guard, diplomacy, sieges (AI and player),
## joining/leaving realms, fief income, and how chat reacts to politics.

var gs: Node
var db: Node
var _nodes: Array[Node] = []


func _state() -> Node:
	if gs == null:
		gs = load("res://scripts/autoload/game_state.gd").new()
		gs.load_all("res://data/generated", "res://data/world")
		db = load("res://scripts/autoload/dialogue_db.gd").new()
		db.load_bundle("res://data/generated")
	return gs


func cleanup() -> void:
	for n in _nodes:
		n.free()
	if db != null:
		db.free()
	if gs != null:
		gs.free()


func _world(seed: int, with_player := true) -> World:
	var w: World = _state().new_world(seed)
	if with_player:
		var p := Party.new("player", w.terrain.cell_to_world(w.settlements["town_05_01"]["cell"]))
		p.name = "Wanderer"
		p.roster = Roster.make(60, [0.5, 0.3, 0.2], [0.5, 0.4, 0.1], w.rng)
		w.add_party(p)
	return w


func _lord_of(w: World, faction: String) -> Party:
	return w.parties.filter(func(p): return p.kind == "lord" and p.faction == faction)[0]


func test_ownership_starts_from_the_bundle_and_villages_follow_their_fort() -> void:
	var w := _world(1, false)
	for id in w.settlements:
		check_eq(w.owner(id), w.settlements[id]["faction"], id)
	var village: String = w.settlements.keys().filter(func(id): return w.settlements[id]["type"] == "village")[0]
	var fort: String = w.settlements[village]["bound_to"]
	var taker := _lord_of(w, "faction_06" if w.owner(fort) != "faction_06" else "faction_01")
	w.politics.capture(fort, taker)
	check_eq(w.owner(fort), taker.faction)
	check_eq(w.owner(village), taker.faction, "the village follows its fort")
	check_eq(w.state[fort]["holder"], taker.persona_id, "the captor holds it")


func test_borders_are_found() -> void:
	var w := _world(1, false)
	check(w.politics.borders.size() >= 5, "six realms share at least five borders: %d" % w.politics.borders.size())
	for f in w.factions:
		check(w.politics.borders.keys().any(func(k): return k.contains(f)), "%s borders someone" % f)


func test_capture_rehomes_lords_and_emits() -> void:
	var w := _world(1, false)
	var events := []
	w.sim_event.connect(func(k, d): events.append([k, d]))
	var victim := _lord_of(w, "faction_05")
	var home := victim.home
	w.politics.capture(home, _lord_of(w, "faction_03"))
	check(victim.home != home and w.owner(victim.home) == "faction_05", "lord moved to another fort of theirs")
	var cap := events.filter(func(e): return e[0] == "fief_captured")
	check_eq(cap.size(), 1)
	check_eq(cap[0][1]["from_faction"], "faction_05")


func test_guard_protects_last_forts() -> void:
	var w := _world(1, false)
	var forts := w.politics.forts_of("faction_05")
	var taker := _lord_of(w, "faction_03")            # at war with the regency at the start
	for i in forts.size() - 2:
		w.politics.capture(forts[i], taker)
	var last: String = w.politics.forts_of("faction_05")[0]
	check(not w.politics.can_besiege("faction_03", last), "the last two forts can't be besieged")


func test_ai_siege_takes_a_weak_fort() -> void:
	var w := _world(2, false)
	var fort: String = w.politics.forts_of("faction_05")[0]
	w.state[fort]["garrison"] = Roster.make(4, [1, 0, 0], [1, 0, 0], w.rng)
	for p in w.parties.duplicate():
		if p.kind != "lord" or p.faction != "faction_03":
			w.remove_party(p)                          # nobody to relieve the fort
	var lord := _lord_of(w, "faction_03")
	lord.position = w.terrain.cell_to_world(w.settlements[fort]["cell"])
	lord.roster = Roster.make(80, [0.5, 0.3, 0.2], [0.3, 0.5, 0.2], w.rng)
	w.politics.start_siege(lord, fort)
	w.step(26.0)
	check_eq(w.owner(fort), "faction_03", "an 80-strong host takes a fort held by 4")
	check(w.event_counts.get("assault", 0) >= 1, "there was an assault")


func test_diplomacy_over_sixty_days() -> void:
	var w := _world(42, false)
	var smallest := 999
	for d in 60:
		w.step(24.0)
		for f in w.factions:
			smallest = mini(smallest, w.politics.forts_of(f).size())
	print("     60 days: war_declared %d, peace_made %d, fief_captured %d, smallest realm %d forts" % [
		w.event_counts.get("war_declared", 0), w.event_counts.get("peace_made", 0), w.event_counts.get("fief_captured", 0), smallest])
	check(w.event_counts.get("war_declared", 0) + w.event_counts.get("peace_made", 0) > 0, "diplomacy happens")
	check(smallest > 0, "no realm wiped out by day 60")
	check_eq(w.stuck_parties().size(), 0, "no stuck parties")


func test_player_joins_leaves_and_becomes_a_target() -> void:
	var w := _world(3)
	var enemy := _lord_of(w, "faction_03")             # at war with the regency
	check(not w.hostile(w.player, enemy), "free company: not at war")
	w.politics.player_join("faction_05")
	check(w.hostile(w.player, enemy), "the regency's enemies are now yours")
	w.politics.player_leave()
	check_eq(w.player.faction, "")
	check(w.event_counts.get("player_left_faction", 0) == 1, "leaving is an event")


func test_player_siege_flow_and_fief_income() -> void:
	var w := _world(4)
	var fort: String = w.politics.forts_of("faction_03")[0]
	check(w.player_start_siege(fort) != "", "can't besiege without a realm")
	w.politics.player_join("faction_05")
	for p in w.parties.duplicate():                   # a clear field: the fort's lords would otherwise
		if p.kind != "player":                        # attack, and that battle (no UI here) blocks the assault
			w.remove_party(p)
	w.player.position = w.terrain.cell_to_world(w.settlements[fort]["cell"])
	check_eq(w.player_start_siege(fort), "", "a sworn lord at war may besiege")
	var asked := []
	w.assault_requested.connect(func(p, f, g): asked.append([f, g]))
	w.step(float(w.cfg["politics"]["player_siege_hours"]) + 1.0)
	check_eq(asked.size(), 1, "assault requested once the camp is over")
	if asked.size() == 1:
		var garrison: Party = asked[0][1]
		garrison.roster = Roster.make(2, [1, 0, 0], [1, 0, 0], w.rng)
		var battle := Battle.new(w.player, garrison, "player", "garrison", "plains", w.battle_rules, w.rng)
		while not battle.over:
			battle.play_round("advance", "hold")
		w.politics.apply_player_assault(battle.finish(), fort, garrison)
		check_eq(w.owner(fort), "faction_05", "taken for your realm")
		check_eq(w.state[fort]["holder"], "player", "and granted to you")
		var gold := w.player.gold
		w.step(24.0)
		check(w.player.gold > gold, "fiefs pay you daily")


func test_chat_reacts_to_politics() -> void:
	var w := _world(5)
	db.last_used.clear()
	var d: Node = load("res://scripts/dialogue/chat_director.gd").new()
	_nodes.append(d)
	d.setup(w, db, _state().chat_config, 5)
	w.sim_event.connect(d.on_sim_event)
	w.politics.set_war("faction_02", "faction_04", true, 0)
	w.politics.player_join("faction_05")
	var member: String = d._members("faction_05")[0]
	var before := w.relations.score(member)
	w.politics.player_leave()
	d.advance(40.0)
	var kinds: Array = d.log.map(func(m): return m["event"])
	check(kinds.has("war_declared"), "war is announced in chat")
	check(kinds.has("player_joined_my_faction") and kinds.has("player_left_my_faction"), "joining and leaving draw comment")
	check(w.relations.score(member) < before, "deserters are disliked")
	check_eq(w.relations.reason(member), "You abandoned their realm.")
	var war_speakers: Array = d.log.filter(func(m): return m["event"] == "war_declared").map(func(m): return m["faction"])
	check(war_speakers.has("faction_02") or war_speakers.has("faction_04"), "someone from the warring realms speaks")


func test_catch_up_favours_the_small_and_tires_the_big() -> void:
	var w := _world(6, false)
	for f in w.factions:
		check_near(w.politics.share(f), w.politics.forts_of(f).size() / (64.0 / 6.0), 0.001, f)
	var big := "faction_04"
	var small := "faction_05"
	var takers := w.politics.forts_of(small)
	for i in takers.size() - 2:                        # the forest wardens take all but two regency forts
		w.politics.capture(takers[i], _lord_of(w, big))
	check(w.politics.share(big) > 1.6, "the wardens are overextended: %.2f" % w.politics.share(big))
	check(w.politics.resilience(small) > 2.5, "the regency recovers fast: %.2f" % w.politics.resilience(small))
	check(w.politics.resilience(big) < 0.7, "the wardens' garrisons refill slowly: %.2f" % w.politics.resilience(big))
	# weariness in a war with an overextended realm grows faster than in an even war
	w.politics.set_war(big, "faction_02", true, 0)
	var key_big := w._pair(big, "faction_02")
	var key_even := w._pair("faction_01", "faction_02")
	var even_before: float = w.politics.weariness.get(key_even, 0.0)
	w.politics._diplomacy(1)
	var big_gain: float = w.politics.weariness[key_big]
	var even_gain: float = w.politics.weariness.get(key_even, 0.0) - even_before
	check(big_gain > even_gain * 1.5, "overextension tires faster: %.2f vs %.2f" % [big_gain, even_gain])
