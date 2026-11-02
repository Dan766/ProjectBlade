class_name World
extends RefCounted
## The living continent: every party and the simulation state of every settlement, advanced
## by step(hours). Pure data, no nodes, so it runs headless in tests at any speed.
##
## Each tick: move parties -> respawn routed lords -> resolve contacts (battles) -> hourly threat
## checks (flee / chase) -> decisions for idle parties -> daily economy and spawning.
##
## Lords pick goals by utility scaled by their persona's ai_weights (raid, trade, patrol,
## aggression, flee_threshold...), so a griefer raids and a trader runs caravans of their own.
## Battles use AutoResolve (a Phase 2 stand-in). The player party is never attacked until Phase 3.

signal sim_event(kind: String, data: Dictionary)
## A hostile party reached the player: the map opens the battle screen and later calls
## apply_player_battle(). The world doesn't step while the clock is paused for the battle.
signal battle_requested(player: Party, enemy: Party)
## The player reached a lord they chose to meet: the map opens the encounter dialog.
signal encounter_requested(player: Party, lord: Party)
## The player's siege camp is over: the map opens the battle screen against the fort's garrison
## and later calls politics.apply_player_assault().
signal assault_requested(player: Party, fort: String, garrison: Party)

const BUCKET_CELLS := 8

var cfg: Dictionary
var battle_rules: Dictionary
var terrain: TerrainMap
var settlements: Dictionary          # bundle data with "cell"; read-only here
var factions: Dictionary
var personas: Dictionary
var state: Dictionary = {}           # settlement id -> {prosperity, recruits, raided_until}
var parties: Array[Party] = []
var by_id: Dictionary = {}
var player: Party                    # the human's party, once added
var battle_pending := false
var relations := Relations.new()     # what each persona remembers about the player (Phase 4)
var politics := Politics.new()       # ownership, diplomacy, sieges (Phase 5)
var chat_cfg: Dictionary = {}
var player_stats := {"streak": 0, "renown": 0, "wins": 0, "losses": 0}
var time := 0.0
var rng := RandomNumberGenerator.new()
var wars: Dictionary = {}            # "faction_a|faction_b" (sorted) -> true
var event_counts: Dictionary = {}
var _next_id := 0
var _last_day := 0
var _buckets: Dictionary = {}
var _forts: Array = []               # town and castle ids
var _towns: Array = []


func setup(data: Object, config: Dictionary, seed: int) -> void:
	cfg = config
	battle_rules = data.battle_config
	chat_cfg = data.chat_config
	terrain = data.terrain
	settlements = data.settlements
	factions = data.factions
	personas = data.personas
	rng.seed = seed
	for pair in cfg["initial_wars"]:
		set_war(pair[0], pair[1], true)
	var ids := settlements.keys()
	ids.sort()
	for id in ids:
		var s: Dictionary = settlements[id]
		state[id] = {"prosperity": 50.0, "raided_until": -1.0,
			"recruits": 10 if s["type"] == "village" else 0}
		if s["type"] != "village":
			_forts.append(id)
		if s["type"] == "town":
			_towns.append(id)
	spawn_lords()
	relations.setup(chat_cfg["relationship"], data.relationship_bands, personas, rng)
	politics.setup(self)


## The faction that currently holds settlement `id` (villages follow their fort).
func owner(id: String) -> String:
	return politics.owner(id)


# --- relations ---------------------------------------------------------------------

func set_war(a: String, b: String, on: bool) -> void:
	var key := _pair(a, b)
	if on:
		wars[key] = true
	else:
		wars.erase(key)


func at_war(a: String, b: String) -> bool:
	return a != b and wars.has(_pair(a, b))


func _pair(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a


func hostile(a: Party, b: Party) -> bool:
	if a.kind == "player" or b.kind == "player":
		var me := a if a.kind == "player" else b
		var other := b if me == a else a
		# bandits prey on everyone; a lord who hates the player and is aggressive hunts them;
		# anyone else only if the player chose to attack them
		if other.kind == "bandit" or (me.goal == "attack" and me.goal_target == other.id):
			return true
		if me.faction != "" and other.kind in ["lord", "caravan"] and at_war(me.faction, other.faction):
			return true                                  # the player's faction is at war with theirs
		return other.kind == "lord" and hunts_player(other)
	if a.kind == "bandit" and b.kind == "bandit":
		return false
	if a.kind == "bandit" or b.kind == "bandit":
		return true
	if a.kind == "caravan" and b.kind == "caravan":
		return false
	return at_war(a.faction, b.faction)


func strength(p: Party) -> float:
	return Roster.strength(p.roster, cfg["tier_power"])


## A lord with a deep grudge (relationship <= max_relationship) and enough aggression hunts the player.
func hunts_player(lord: Party) -> bool:
	if lord.persona_id == "" or chat_cfg.is_empty():
		return false
	var h: Dictionary = chat_cfg["hunt_player"]
	return relations.score(lord.persona_id) <= float(h["max_relationship"]) and float(weights(lord).get("aggression", 0.0)) >= float(h["min_aggression"])


## Leader / battle-AI key: the persona's archetype for lords, otherwise the party kind.
func role(p: Party) -> String:
	return personas[p.persona_id]["archetype"] if p.persona_id != "" else p.kind


# --- parties -------------------------------------------------------------------------

## World never connects to Party.arrived: a bound callable on the party's own signal is a
## reference cycle (Party -> Callable -> World -> Party) that leaked every party. Arrival is
## detected in _tick instead (moving before advance, not moving after).
func add_party(p: Party) -> void:
	parties.append(p)
	by_id[p.id] = p
	p.last_progress = time
	if p.kind == "player":
		player = p


func remove_party(p: Party) -> void:
	parties.erase(p)
	by_id.erase(p.id)


func _new_id(prefix: String) -> String:
	_next_id += 1
	return "%s_%d" % [prefix, _next_id]


func spawn_lords() -> void:
	var homes := {}
	for id in _forts:
		homes.get_or_add(settlements[id]["faction"], []).append(id)
	var counters := {}
	var ids := personas.keys()
	ids.sort()
	for pid in ids:
		var per: Dictionary = personas[pid]
		var f: String = per["faction"]
		var i: int = counters.get(f, 0)
		counters[f] = i + 1
		var home: String = homes[f][i % homes[f].size()]
		var p := Party.new("lord_" + pid, terrain.cell_to_world(settlements[home]["cell"]))
		p.kind = "lord"
		p.name = per["username"]
		p.faction = f
		p.persona_id = pid
		p.home = home
		p.speed = cfg["speeds"]["lord"]
		var size: int = int(cfg["lord_size"]["base"]) + int(cfg["lord_size"]["by_archetype"].get(per["archetype"], 0)) + rng.randi_range(-8, 8)
		p.roster = Roster.make(size, cfg["troop_mix"][f], cfg["starting_tiers"], rng)
		p.gold = int(cfg["lord_gold"]) * (2 if per["archetype"] == "trader" else 1)
		p.next_decision = rng.randf_range(0.0, 6.0)
		add_party(p)


func weights(p: Party) -> Dictionary:
	if p.persona_id != "":
		return personas[p.persona_id]["ai_weights"]
	if p.kind == "bandit":
		return {"aggression": 0.7, "flee_threshold": 0.5}
	return {"aggression": 0.0, "flee_threshold": 0.8}


# --- the tick ----------------------------------------------------------------------------

func step(hours: float) -> void:
	var left := hours
	while left > 1e-6:
		var h := minf(float(cfg["step_hours"]), left)
		_tick(h)
		left -= h


func _tick(h: float) -> void:
	var prev := time
	time += h
	for p in parties:
		if not p.is_active(time):
			continue
		if p.goal_until > time:
			p.last_progress = time
			continue
		var before := p.position
		var was_moving := p.is_moving()
		p.advance(h, terrain)
		if p.position != before:
			p.last_progress = time
		if was_moving and not p.is_moving() and p.kind != "player":
			_on_arrived(p)
	_respawn_routed()
	_update_player_pursuit()
	_rebuild_buckets()
	_resolve_contacts()
	politics.check_sieges()
	if int(time) != int(prev):
		_threat_checks()
	for p in parties.duplicate():
		if p.kind == "player" or not p.is_active(time) or p.goal_until > time:
			continue
		# Only the timer triggers re-planning: arrivals and failures set next_decision themselves.
		# (Deciding whenever the path was empty re-planned failed parties every tick: 10+ min runs.)
		if time >= p.next_decision:
			_decide(p)
	var day := int(time / 24.0)
	if day != _last_day:
		_last_day = day
		_daily()


func _emit(kind: String, data: Dictionary) -> void:
	event_counts[kind] = event_counts.get(kind, 0) + 1
	data["time"] = time
	sim_event.emit(kind, data)


# --- spatial lookup ------------------------------------------------------------------------

func _bucket_of(pos: Vector2) -> Vector2i:
	var px := BUCKET_CELLS * terrain.cell_size
	return Vector2i(floori(pos.x / px), floori(pos.y / px))


func _rebuild_buckets() -> void:
	_buckets.clear()
	for p in parties:
		if p.is_active(time):
			_buckets.get_or_add(_bucket_of(p.position), []).append(p)


func neighbors(p: Party, radius_px: float) -> Array:
	var out := []
	var span := ceili(radius_px / (BUCKET_CELLS * terrain.cell_size))
	var b := _bucket_of(p.position)
	var r2 := radius_px * radius_px
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			for q in _buckets.get(b + Vector2i(dx, dy), []):
				if q != p and q.position.distance_squared_to(p.position) <= r2:
					out.append(q)
	return out


# --- contacts and battles -----------------------------------------------------------------

func _resolve_contacts() -> void:
	var reach := float(cfg["engage_cells"]) * terrain.cell_size
	var fought := {}
	for a in parties.duplicate():
		if not by_id.has(a.id) or not a.is_active(time) or a.battle_cooldown_until > time:
			continue
		for b in neighbors(a, reach):
			if fought.has(a.id) or fought.has(b.id) or b.battle_cooldown_until > time or not hostile(a, b):
				continue
			fought[a.id] = true
			fought[b.id] = true
			if a.kind == "player" or b.kind == "player":
				if not battle_pending:
					battle_pending = true
					battle_requested.emit(a if a.kind == "player" else b, b if a.kind == "player" else a)
			else:
				_battle(a, b)
			break


func terrain_between(a: Party, b: Party) -> String:
	return terrain.terrain_name(terrain.world_to_cell((a.position + b.position) * 0.5))


func _battle(a: Party, b: Party) -> void:
	_after_battle(AutoResolve.resolve(a, b, role(a), role(b), terrain_between(a, b), battle_rules, rng))


## Shared aftermath of every battle (AI or player): cooldowns, events, robbed caravans,
## destroyed bandits, routed or captured lords, and the loser running away.
func _after_battle(r: Dictionary) -> void:
	var w: Party = r["winner"]
	var l: Party = r["loser"]
	w.battle_cooldown_until = time + 1.0
	l.battle_cooldown_until = time + 3.0
	_emit("battle", {"winner": w.id, "loser": l.id, "winner_lost": r["winner_lost"], "loser_lost": r["loser_lost"]})
	if l.kind == "caravan":
		w.gold += l.gold
		_emit("caravan_robbed", {"caravan": l.id, "by": w.id, "faction": l.faction})
		remove_party(l)
	elif l.troops() < 5 and l.kind == "bandit":
		w.gold += 150
		_emit("party_destroyed", {"party": l.id, "by": w.id})
		remove_party(l)
	elif l.kind == "lord" and (l.troops() < 5 or r.get("captured", false)):
		l.routed_until = time + float(cfg["routed_respawn_hours"])
		l.stop()
		w.gold += int(l.gold * 0.3)
		l.gold = int(l.gold * 0.7)
		_emit("party_defeated", {"party": l.id, "by": w.id})
		politics.on_lord_routed(l.faction, w.faction)
	elif l.kind == "player":
		_player_driven_off(l)
	else:
		_flee(l, w)


func _player_driven_off(p: Party) -> void:
	if p.troops() == 0:
		Roster.add(p.roster, "infantry", 0, 5)       # a few stragglers rejoin
	var town := _nearest(p, func(id): return settlements[id]["type"] == "town")
	p.stop()
	p.goal = "idle"
	p.position = terrain.cell_to_world(settlements[town]["cell"])
	# a real chance to regroup: at 1x six game hours were six real seconds, and enemies were back on
	# the player at once (Phase 6 playtest: 58 defeats in 20 minutes)
	p.battle_cooldown_until = time + float(cfg.get("player_regroup_hours", 24))


## Called by the map when the player's battle screen closes. `choice` is "release" or
## "ransom" for a captured lord, otherwise "".
func apply_player_battle(r: Dictionary, choice: String) -> void:
	battle_pending = false
	var enemy: Party = r["loser"] if r["winner"] == player else r["winner"]
	var won: bool = r["winner"] == player
	var lost_mine: int = r["winner_lost"] if won else r["loser_lost"]
	var loss_share := float(lost_mine) / maxf(1.0, float(player.troops() + lost_mine))
	_after_battle(r)
	if player.goal == "attack":
		player.goal = "idle"
	_emit("player_battle", {"enemy": enemy.id, "enemy_kind": enemy.kind, "persona": enemy.persona_id,
		"player_won": r["winner"] == player, "routed": r["routed"], "fled": r["fled"], "captured": r.get("captured", false),
		"enemy_faction": enemy.faction,
		"loot": r["loot"], "prisoners": r["prisoners"], "player_loss_share": loss_share, "player_lost": lost_mine})
	if r.get("captured", false):
		if choice == "ransom":
			player.gold += int(battle_rules["lord_ransom"])
			_emit("lord_ransomed", {"party": enemy.id, "gold": int(battle_rules["lord_ransom"])})
		else:
			_emit("lord_released", {"party": enemy.id})


## Raid the village the player stands in. Returns "" or the reason it isn't possible.
func player_raid(village: String) -> String:
	var o := owner(village)
	if player.faction != "" and o == player.faction:
		return "You won't burn your own realm's village."
	if state[village]["raided_until"] >= time:
		return "There is nothing left to take."
	var econ: Dictionary = cfg["economy"]
	state[village]["raided_until"] = time + float(econ["raid_days"]) * 24.0
	state[village]["prosperity"] = maxf(0.0, state[village]["prosperity"] - float(econ["raid_prosperity_hit"]))
	state[village]["recruits"] = 0
	player.gold += int(econ["raid_gold"])
	var seat: String = settlements[village].get("bound_to", "")
	_emit("player_raided_village", {"village": village, "faction": o, "holder": state[seat]["holder"] if seat != "" else ""})
	return ""


## Start besieging `fort` with the player's party. Returns "" or the reason it isn't possible.
func player_start_siege(fort: String) -> String:
	var why := politics.player_siege_problem(fort)
	if why != "":
		return why
	if player.position.distance_to(terrain.cell_to_world(settlements[fort]["cell"])) > terrain.cell_size * 1.5:
		return "Stand at the fort to besiege it."
	politics.start_siege(player, fort)
	return ""


## The player clicked a lord: walk over and talk (encounter_requested on contact).
func player_meet(target: Party) -> void:
	player.goal = "meet"
	player.goal_target = target.id
	player.set_destination(terrain, terrain.world_to_cell(target.position))


## The player clicked a party: chase it; contact starts a battle.
func player_attack(target: Party) -> void:
	player.goal = "attack"
	player.goal_target = target.id
	player.set_destination(terrain, terrain.world_to_cell(target.position))


func _update_player_pursuit() -> void:
	if player == null or not (player.goal in ["attack", "meet"]):
		return
	var t: Party = by_id.get(player.goal_target)
	if t == null or not t.is_active(time):
		player.goal = "idle"
		player.stop()
		return
	if player.goal == "meet" and t.position.distance_to(player.position) <= float(cfg["engage_cells"]) * terrain.cell_size and not battle_pending:
		player.goal = "idle"
		player.stop()
		battle_pending = true                         # the encounter dialog pauses the world like a battle
		encounter_requested.emit(player, t)
		return
	var cell := terrain.world_to_cell(t.position)
	if player.path.is_empty() or player.path[-1].distance_to(cell) > 1.0:
		player.set_destination(terrain, cell)


## The encounter dialog closed without a fight.
func end_encounter() -> void:
	battle_pending = false


func _respawn_routed() -> void:
	for p in parties:
		if p.routed_until > 0.0 and time >= p.routed_until:
			p.routed_until = -1.0
			p.position = terrain.cell_to_world(settlements[p.home]["cell"])
			# underdog realms' lords come back stronger (catch-up)
			var size := int(float(cfg["respawn_size"]) * maxf(1.0, politics.resilience(p.faction)))
			p.roster = Roster.make(size, cfg["troop_mix"][p.faction], [1.0, 0.0, 0.0], rng)
			p.morale = 50.0
			p.goal = "idle"
			p.next_decision = time
			p.last_progress = time
			_emit("lord_respawned", {"party": p.id})


# --- threats: flee or chase -------------------------------------------------------------------

func flee_ratio(p: Party) -> float:
	if p.kind == "caravan":
		return 0.6
	if p.kind == "bandit":
		return 1.3
	return 2.2 - 1.4 * float(weights(p).get("flee_threshold", 0.5))


func chase_ratio(p: Party) -> float:
	if p.kind == "bandit":
		return 0.8
	return 0.3 + 0.7 * float(weights(p).get("aggression", 0.5))


func _threat_checks() -> void:
	for p in parties.duplicate():
		if p.kind == "player" or not p.is_active(time) or not by_id.has(p.id):
			continue
		_threat_check(p)


## Flee from a much stronger enemy or start chasing a weak one. Returns true if it acted.
## Also run when a party decides, so nobody sets off to recruit next to an enemy army.
func _threat_check(p: Party) -> bool:
	var sight := float(cfg["sight_cells"]) * terrain.cell_size
	if true:
		var own := maxf(strength(p), 1.0)
		var worst: Party = null
		var worst_ratio := 0.0
		var prey: Party = null
		var prey_ratio := INF
		for q in neighbors(p, sight):
			if not hostile(p, q):
				continue
			var ratio := strength(q) / own
			if ratio > worst_ratio:
				worst_ratio = ratio
				worst = q
			if ratio < prey_ratio and q.battle_cooldown_until <= time:
				prey_ratio = ratio
				prey = q
		if worst != null and worst_ratio > flee_ratio(p):
			if p.goal != "flee":
				_flee(p, worst)
			return true
		if p.goal == "chase":
			_continue_chase(p, sight)
			return true
		if prey != null and p.kind != "caravan" and prey_ratio < chase_ratio(p):
			p.goal = "chase"
			p.goal_target = prey.id
			p.goal_until = -1.0
			p.chase_until = time + float(cfg["ai"]["chase_give_up_hours"])
			p.set_destination(terrain, terrain.world_to_cell(prey.position))
			p.next_decision = p.chase_until
			p.last_progress = time
			return true
	return false


func _continue_chase(p: Party, sight: float) -> void:
	var q: Party = by_id.get(p.goal_target)
	if q == null or not q.is_active(time) or time > p.chase_until or q.position.distance_to(p.position) > sight * 1.5:
		p.goal = "idle"
		p.stop()
		p.next_decision = time
		return
	var target := terrain.world_to_cell(q.position)
	if p.path.is_empty() or p.path[-1].distance_to(target) > 2.0:
		p.set_destination(terrain, target)


func _flee(p: Party, threat: Party) -> void:
	var dest := Vector2i(-1, -1)
	if p.kind != "bandit":
		var my := p.position.distance_to(threat.position)
		var best := INF
		for id in _forts:
			if owner(id) != p.faction:
				continue
			var spot := terrain.cell_to_world(settlements[id]["cell"])
			var d := spot.distance_to(p.position)
			if spot.distance_to(threat.position) > my and d < best:
				best = d
				dest = settlements[id]["cell"]
	if dest.x < 0:
		var away := (p.position - threat.position).normalized()
		if away == Vector2.ZERO:
			away = Vector2.RIGHT.rotated(rng.randf() * TAU)
		dest = _passable_near(terrain.world_to_cell(p.position + away * 12.0 * terrain.cell_size), 6)
	p.goal = "flee"
	p.goal_target = threat.id
	p.goal_until = -1.0
	if dest.x >= 0:
		p.set_destination(terrain, dest)
	p.next_decision = time + 6.0
	p.last_progress = time


func _passable_near(cell: Vector2i, radius: int) -> Vector2i:
	for r in radius + 1:
		for i in 12:
			var c := cell + Vector2i(rng.randi_range(-r, r), rng.randi_range(-r, r))
			if terrain.is_passable(c):
				return c
	return Vector2i(-1, -1)


# --- decisions ---------------------------------------------------------------------------------

func _decide(p: Party) -> void:
	p.last_progress = time
	p.next_decision = time + float(cfg["decide_timeout_hours"])
	if p.goal != "chase" and _threat_check(p):
		return
	match p.kind:
		"lord":
			_decide_lord(p)
		"caravan":
			_decide_caravan(p)
		"bandit":
			_decide_bandit(p)


func _cells_between(a: Vector2, b: Vector2) -> float:
	return a.distance_to(b) / terrain.cell_size


func _decide_lord(p: Party) -> void:
	var w := weights(p)
	var ai: Dictionary = cfg["ai"]
	var target_size: int = int(cfg["lord_size"]["base"]) + int(cfg["lord_size"]["by_archetype"].get(personas[p.persona_id]["archetype"], 0))
	var size := p.troops()
	var options := []                                      # [score, goal, settlement id]

	if p.morale < float(ai["low_morale"]):
		options.append([1.2, "home", p.home])
	if size < target_size * 0.8:
		var v := _nearest(p, func(id): return settlements[id]["type"] == "village" and owner(id) == p.faction and state[id]["recruits"] >= 5 and state[id]["raided_until"] < time)
		if v != "":
			options.append([0.6 + (1.0 - float(size) / target_size), "recruit", v])
	if float(w.get("raid", 0.0)) > 0.05 and size >= 15:
		for id in _within(p, float(ai["raid_range_cells"]), func(id): return settlements[id]["type"] == "village" and at_war(p.faction, owner(id)) and state[id]["raided_until"] < time).slice(0, 3):
			var d := _cells_between(p.position, terrain.cell_to_world(settlements[id]["cell"]))
			options.append([float(w["raid"]) * (0.4 + 0.6 * (1.0 - d / float(ai["raid_range_cells"]))), "raid", id])
	if p.gold < 4000:
		var t := _random_within(p, float(ai["trade_range_cells"]), func(id): return settlements[id]["type"] == "town" and not at_war(p.faction, owner(id)))
		if t != "":
			options.append([float(w.get("trade", 0.3)) * 0.7, "trade", t])
	var pat := _random_within(p, float(ai["patrol_range_cells"]), func(id): return owner(id) == p.faction)
	if pat != "":
		options.append([0.25 + float(w.get("patrol", 0.4)) * 0.4, "patrol", pat])
	if float(w.get("besiege", 0.0)) > 0.1:
		var fort := politics.siege_target(p)
		if fort != "":
			options.append([float(w["besiege"]) * float(cfg["politics"]["besiege_weight"]), "besiege", fort])
	if options.is_empty():
		options.append([0.1, "home", p.home])

	var best: Array = []
	var best_score := -INF
	for o in options:
		var s: float = o[0] + rng.randf() * 0.15
		if s > best_score:
			best_score = s
			best = o
	_go(p, best[1], best[2])


func _decide_caravan(p: Party) -> void:
	var here := _settlement_at(p.position)
	var t := _random_within(p, 200.0, func(id): return settlements[id]["type"] == "town" and id != here and not at_war(p.faction, owner(id)))
	if t == "":
		remove_party(p)
		return
	_go(p, "trade", t)


func _decide_bandit(p: Party) -> void:
	var roam := int(cfg["bandits"]["roam_cells"])
	var dest := _passable_near(p.spawn_cell + Vector2i(rng.randi_range(-roam, roam), rng.randi_range(-roam, roam)), 4)
	p.goal = "roam"
	p.goal_target = ""
	if dest.x < 0 or not p.set_destination(terrain, dest):
		p.next_decision = time + 1.0


func _go(p: Party, goal: String, settlement_id: String) -> void:
	p.goal = goal
	p.goal_target = settlement_id
	if not p.set_destination(terrain, settlements[settlement_id]["cell"]):
		p.goal = "idle"
		p.next_decision = time + 1.0
	elif not p.is_moving():
		_on_arrived(p)                                 # already standing there


func _on_arrived(p: Party) -> void:
	if not by_id.has(p.id):
		return
	var id := p.goal_target
	match p.goal:
		"recruit":
			var n: int = state[id]["recruits"]
			state[id]["recruits"] = 0
			for i in n:
				Roster.add(p.roster, Roster.TYPES[Roster._pick(cfg["troop_mix"][p.faction], rng)], 0, 1)
			_emit("recruited", {"party": p.id, "village": id, "count": n})
			_idle(p, 1.0)
		"raid":
			if state[id]["raided_until"] < time and at_war(p.faction, owner(id)):
				var econ: Dictionary = cfg["economy"]
				state[id]["raided_until"] = time + float(econ["raid_days"]) * 24.0
				state[id]["prosperity"] = maxf(0.0, state[id]["prosperity"] - float(econ["raid_prosperity_hit"]))
				state[id]["recruits"] = 0
				p.gold += int(econ["raid_gold"])
				_emit("village_raided", {"party": p.id, "village": id, "faction": owner(id)})
				_idle(p, float(econ["raid_hours"]))
			else:
				_idle(p, 0.0)
		"trade":
			var econ: Dictionary = cfg["economy"]
			if p.kind == "caravan":
				state[id]["prosperity"] = minf(100.0, state[id]["prosperity"] + float(econ["caravan_prosperity"]))
				_emit("caravan_arrived", {"party": p.id, "town": id})
				_idle(p, 2.0)
			else:
				var earned := int(float(econ["trade_gold"]) * state[id]["prosperity"] / 50.0)
				p.gold += earned
				_emit("trade", {"party": p.id, "town": id, "gold": earned})
				_idle(p, 3.0)
		"besiege":
			if politics.can_besiege(p.faction, id):
				politics.start_siege(p, id)
			else:
				_idle(p, 0.0)
		"home":
			p.morale = maxf(p.morale, 70.0)
			_idle(p, 12.0)
		"patrol", "roam":
			_idle(p, rng.randf_range(2.0, 6.0))
		_:
			_idle(p, 0.0)


func _idle(p: Party, wait_hours: float) -> void:
	p.goal = "idle"
	p.goal_until = time + wait_hours if wait_hours > 0.0 else -1.0
	p.next_decision = time + wait_hours
	p.last_progress = time


func _nearest(p: Party, pred: Callable) -> String:
	var best := ""
	var best_d := INF
	for id in settlements:
		if pred.call(id):
			var d := p.position.distance_squared_to(terrain.cell_to_world(settlements[id]["cell"]))
			if d < best_d:
				best_d = d
				best = id
	return best


## Settlement ids matching `pred` within `range_cells`, nearest first.
func _within(p: Party, range_cells: float, pred: Callable) -> Array:
	var hits := []
	for id in settlements:
		var d := _cells_between(p.position, terrain.cell_to_world(settlements[id]["cell"]))
		if d <= range_cells and pred.call(id):
			hits.append([d, id])
	hits.sort_custom(func(a, b): return a[0] < b[0])
	return hits.map(func(h): return h[1])


func _random_within(p: Party, range_cells: float, pred: Callable) -> String:
	var ids := _within(p, range_cells, pred)
	return "" if ids.is_empty() else ids[rng.randi_range(0, ids.size() - 1)]


func _settlement_at(pos: Vector2) -> String:
	for id in settlements:
		if terrain.cell_to_world(settlements[id]["cell"]).distance_to(pos) < terrain.cell_size:
			return id
	return ""


# --- daily: economy and spawning -------------------------------------------------------------

func _daily() -> void:
	politics.daily(int(time / 24.0))
	var econ: Dictionary = cfg["economy"]
	for id in state:
		var s: Dictionary = state[id]
		if settlements[id]["type"] == "village" and s["raided_until"] < time:
			var grow := int(round(float(econ["village_recruits_per_day"]) * politics.resilience(owner(id))))
			s["recruits"] = mini(int(econ["village_recruit_cap"]), s["recruits"] + grow)
			s["prosperity"] = minf(100.0, s["prosperity"] + 0.5)
			var lord_seat: String = settlements[id].get("bound_to", "")
			if lord_seat != "":
				state[lord_seat]["prosperity"] = minf(100.0, state[lord_seat]["prosperity"] + 0.2)
	for p in parties:
		Roster.heal(p.roster, p.wounded, float(battle_rules["wounded_heal_per_day"]), rng)
	for p in parties:
		if p.kind != "lord" or not p.is_active(time):
			continue
		p.gold -= int(p.troops() * float(econ["upkeep_per_troop_per_day"]))
		if p.gold < 0:
			p.morale = maxf(0.0, p.morale - 5.0)
			if p.morale < 20.0:
				var gone := Roster.remove_fraction(p.roster, 0.05, rng)
				if gone > 0:
					_emit("desertion", {"party": p.id, "count": gone})
		Roster.train(p.roster, float(econ["train_t1_to_t2"]), float(econ["train_t2_to_t3"]), rng)
	_spawn_bandits()
	_spawn_caravans()


func count_kind(kind: String) -> int:
	return parties.filter(func(p): return p.kind == kind).size()


func _spawn_bandits() -> void:
	var b: Dictionary = cfg["bandits"]
	for i in int(b["spawn_per_day"]):
		if count_kind("bandit") >= int(b["cap"]):
			return
		for attempt in 40:
			var c := Vector2i(rng.randi_range(0, terrain.width - 1), rng.randi_range(0, terrain.height - 1))
			if not terrain.is_passable(c) or _near_fort(c, int(b["min_cells_from_fort"])):
				continue
			var p := Party.new(_new_id("bandits"), terrain.cell_to_world(c))
			p.kind = "bandit"
			p.name = "Bandits"
			p.speed = cfg["speeds"]["bandit"]
			p.spawn_cell = c
			p.roster = Roster.make(rng.randi_range(int(b["size"][0]), int(b["size"][1])), [0.6, 0.4, 0.0], [0.85, 0.15, 0.0], rng)
			add_party(p)
			_emit("bandits_spawned", {"party": p.id})
			break


func _near_fort(c: Vector2i, cells: int) -> bool:
	for id in _forts:
		if Vector2(settlements[id]["cell"]).distance_to(Vector2(c)) < cells:
			return true
	return false


func _spawn_caravans() -> void:
	var cv: Dictionary = cfg["caravans"]
	for i in int(cv["spawn_per_day"]):
		if count_kind("caravan") >= int(cv["cap"]):
			return
		var town: String = _towns[rng.randi_range(0, _towns.size() - 1)]
		var f: String = owner(town)
		var p := Party.new(_new_id("caravan"), terrain.cell_to_world(settlements[town]["cell"]))
		p.kind = "caravan"
		p.faction = f
		p.name = "%s caravan" % factions[f]["adjective"]
		p.speed = cfg["speeds"]["caravan"]
		p.gold = int(cv["gold"])
		p.roster = Roster.make(rng.randi_range(int(cv["size"][0]), int(cv["size"][1])), [0.7, 0.3, 0.0], [0.8, 0.2, 0.0], rng)
		add_party(p)
		_emit("caravan_spawned", {"party": p.id, "town": town})


# --- diagnostics ----------------------------------------------------------------------------------

## Active parties that have neither moved, waited on purpose nor re-planned for `stuck_hours`.
func stuck_parties() -> Array:
	var limit := float(cfg["stuck_hours"])
	return parties.filter(func(p): return p.kind != "player" and p.is_active(time) and time - p.last_progress > limit)
