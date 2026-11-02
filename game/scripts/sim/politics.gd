class_name Politics
extends RefCounted
## Factions as political actors (Phase 5), owned by World:
##   - who owns each fort (villages follow the fort they pay dues to), its garrison and holder
##   - diplomacy, daily: wars grow weary (time, lost fiefs, routed lords) until peace becomes
##     likely; bordering factions at peace long enough may go to war. Balance guard: nobody may
##     besiege a faction's last `min_forts_guard` forts, and wars on a nearly-dead faction end.
##   - sieges: lords (and the player) camp at an enemy fort, then assault it; the garrison fights
##     behind walls (leader "garrison"). Victory changes the owner and grants the fief.
##   - the player joining and leaving factions, and income from fiefs they hold.

## Weak reference: World owns Politics, so a strong one back would be a cycle that leaks the
## whole world (every party) each time one is discarded.
var _world: WeakRef
var w: World:
	get:
		return _world.get_ref()
var cfg: Dictionary
var war_since: Dictionary = {}       # faction pair -> day the war began
var peace_since: Dictionary = {}     # faction pair -> day the peace began
var weariness: Dictionary = {}       # faction pair -> war weariness
var borders: Dictionary = {}         # faction pair -> true when their lands touch


func setup(world: World) -> void:
	_world = weakref(world)
	cfg = w.cfg["politics"]
	for id in w._forts:
		var s: Dictionary = w.settlements[id]
		w.state[id]["owner"] = s["faction"]
		w.state[id]["holder"] = ""
		w.state[id]["siege"] = {}
		w.state[id]["garrison"] = Roster.make(int(cfg["garrison"][s["type"]]), w.cfg["troop_mix"][s["faction"]], [0.5, 0.35, 0.15], w.rng)
	for p in w.parties:
		if p.kind == "lord" and w.state[p.home]["holder"] == "":
			w.state[p.home]["holder"] = p.persona_id
	_find_borders()
	var ids := w.factions.keys()
	for a in ids:
		for b in ids:
			if a < b:
				var key := w._pair(a, b)
				if w.at_war(a, b):
					war_since[key] = 0
				else:
					peace_since[key] = 0
				weariness[key] = 0.0


func _find_borders() -> void:
	var t := w.terrain
	for y in t.height - 1:
		for x in t.width - 1:
			var a := t.faction_at(Vector2i(x, y))
			if a == "":
				continue
			for n in [Vector2i(x + 1, y), Vector2i(x, y + 1)]:
				var b := t.faction_at(n)
				if b != "" and b != a:
					borders[w._pair(a, b)] = true


# --- ownership -------------------------------------------------------------------------

func owner(id: String) -> String:
	var s: Dictionary = w.settlements[id]
	if s["type"] == "village":
		return w.state[s["bound_to"]]["owner"] if s.has("bound_to") else s["faction"]
	return w.state[id]["owner"]


func forts_of(faction: String) -> Array:
	return w._forts.filter(func(id): return w.state[id]["owner"] == faction)


## Forts of `faction` that nobody is besieging: the balance guard counts these, so several
## simultaneous sieges can't take a faction's last strongholds at once (Lauresse was wiped out
## by day 30 before this).
func safe_forts(faction: String) -> int:
	return forts_of(faction).filter(func(id): return w.state[id]["siege"].is_empty()).size()


## A realm's forts relative to the average realm (1.0 = fair share).
func share(faction: String) -> float:
	var avg := float(w._forts.size()) / maxf(1.0, float(w.factions.size()))
	return forts_of(faction).size() / avg


## Catch-up multiplier for regeneration: small realms recover faster (up to underdog_max),
## overextended ones slower (down to overextended_min).
func resilience(faction: String) -> float:
	var c: Dictionary = cfg["catch_up"]
	return clampf(1.0 / maxf(share(faction), 0.01), float(c["overextended_min"]), float(c["underdog_max"]))


func wars_of(faction: String) -> int:
	return w.factions.keys().filter(func(f): return w.at_war(faction, f)).size()


func garrison_party(fort: String) -> Party:
	var g := Party.new("garrison_" + fort, w.terrain.cell_to_world(w.settlements[fort]["cell"]))
	g.kind = "garrison"
	g.name = "Garrison of %s" % w.settlements[fort]["name"]
	g.faction = owner(fort)
	g.roster = w.state[fort]["garrison"]
	return g


# --- diplomacy ---------------------------------------------------------------------------

func daily(day: int) -> void:
	_diplomacy(day)
	for id in w._forts:
		var cap := int(cfg["garrison"][w.settlements[id]["type"]])
		var g: Dictionary = w.state[id]["garrison"]
		if Roster.size(g) < cap and w.state[id]["siege"].is_empty():
			var regen := float(cfg["garrison_regen_per_day"]) * resilience(owner(id))
			var n := int(regen) + (1 if w.rng.randf() < regen - int(regen) else 0)
			Roster.add(g, Roster.TYPES[Roster._pick(w.cfg["troop_mix"][owner(id)], w.rng)], 0, mini(n, cap - Roster.size(g)))
		if w.state[id]["holder"] == "player" and w.player:
			w.player.gold += int(w.state[id]["prosperity"] * float(cfg["fief_income_per_prosperity"]))


func _diplomacy(day: int) -> void:
	var ids := w.factions.keys()
	ids.sort()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: String = ids[i]
			var b: String = ids[j]
			var key := w._pair(a, b)
			var weak := forts_of(a).size() <= int(cfg["min_forts_guard"]) or forts_of(b).size() <= int(cfg["min_forts_guard"])
			var c: Dictionary = cfg["catch_up"]
			var biggest := maxf(share(a), share(b))
			if w.at_war(a, b):
				# overextended empires tire of war faster
				weariness[key] = weariness.get(key, 0.0) + 1.0 + float(c["overextension_weariness"]) * maxf(0.0, biggest - 1.0)
				var chance := clampf((weariness[key] - float(cfg["weariness_floor"])) / float(cfg["weariness_scale"]), 0.0, float(cfg["max_peace_chance"]))
				if weak:
					chance = maxf(chance, 0.2)              # don't grind a faction out of existence
				if day - int(war_since.get(key, 0)) >= int(cfg["min_war_days"]) and w.rng.randf() < chance:
					set_war(a, b, false, day)
			else:
				# a dominant realm draws coalitions: neighbours declare on it more often
				var chance := float(cfg["war_chance_per_day"])
				if biggest >= float(c["coalition_share"]):
					chance *= float(c["coalition_war_mult"])
				if borders.has(key) and not weak and day - int(peace_since.get(key, 0)) >= int(cfg["min_peace_days"]) \
						and wars_of(a) < int(cfg["max_wars"]) and wars_of(b) < int(cfg["max_wars"]) \
						and w.rng.randf() < chance:
					set_war(a, b, true, day)


func set_war(a: String, b: String, on: bool, day: int) -> void:
	var key := w._pair(a, b)
	w.set_war(a, b, on)
	if on:
		war_since[key] = day
		weariness[key] = 0.0
		w._emit("war_declared", {"a": a, "b": b})
	else:
		peace_since[key] = day
		for id in w._forts:                            # sieges between them are lifted
			if not w.state[id]["siege"].is_empty() and w._pair(w.state[id]["siege"]["faction"], owner(id)) == key:
				_lift_siege(id)
		w._emit("peace_made", {"a": a, "b": b})


func on_lord_routed(a: String, b: String) -> void:
	if a != "" and b != "" and w.at_war(a, b):
		var key := w._pair(a, b)
		weariness[key] = weariness.get(key, 0.0) + float(cfg["rout_weariness"])


# --- sieges ---------------------------------------------------------------------------------

func can_besiege(faction: String, fort: String) -> bool:
	var o := owner(fort)
	var siege: Dictionary = w.state[fort]["siege"]
	if not w.at_war(faction, o):
		return false
	if not siege.is_empty():
		return siege["faction"] == faction           # join an ally's siege
	return safe_forts(o) > int(cfg["min_forts_guard"])


## An enemy fort `lord` could take, or "" (used by the lord AI's besiege option).
func siege_target(p: Party) -> String:
	if p.troops() < int(cfg["besiege_min_troops"]):
		return ""
	var options := w._within(p, float(cfg["besiege_range_cells"]), func(id): return _worth_besieging(p, id))
	return "" if options.is_empty() else options[0]


func _worth_besieging(p: Party, id: String) -> bool:
	if w.settlements[id]["type"] == "village" or not can_besiege(p.faction, id):
		return false
	var walls := Roster.strength(w.state[id]["garrison"], w.cfg["tier_power"]) * float(w.battle_rules["leader"]["garrison"])
	return walls * float(cfg["besiege_strength_margin"]) < w.strength(p) * _allies_at(id, p.faction)


func _allies_at(fort: String, faction: String) -> float:
	var siege: Dictionary = w.state[fort]["siege"]
	return 1.5 if not siege.is_empty() and siege["faction"] == faction else 1.0


func start_siege(p: Party, fort: String) -> void:
	var siege: Dictionary = w.state[fort]["siege"]
	var hours := float(cfg["player_siege_hours"] if p.kind == "player" else cfg["siege_hours"])
	if siege.is_empty():
		w.state[fort]["siege"] = {"faction": p.faction, "since": w.time, "leader": p.id, "until": w.time + hours}
		w._emit("siege_started", {"fief": fort, "faction": p.faction, "party": p.id, "by_player": p.kind == "player",
			"holder": w.state[fort]["holder"], "owner": owner(fort)})
	p.stop()
	p.goal = "sieging"
	p.goal_target = fort
	p.goal_until = maxf(w.time + 0.25, float(w.state[fort]["siege"]["until"]))
	p.next_decision = p.goal_until
	p.last_progress = w.time


func _lift_siege(fort: String) -> void:
	w.state[fort]["siege"] = {}
	for p in w.parties:
		if p.goal == "sieging" and p.goal_target == fort:
			p.goal = "idle"
			p.goal_until = -1.0
			p.next_decision = w.time


## Called every tick: assault forts whose siege camp is over.
func check_sieges() -> void:
	for fort in w._forts:
		var siege: Dictionary = w.state[fort]["siege"]
		if siege.is_empty() or w.time < float(siege["until"]):
			continue
		var attackers := w.parties.filter(func(p): return p.goal == "sieging" and p.goal_target == fort and p.is_active(w.time))
		var player_in := attackers.any(func(p): return p.kind == "player")
		if player_in:
			if not w.battle_pending:
				w.battle_pending = true
				w.assault_requested.emit(w.player, fort, garrison_party(fort))
			continue
		if attackers.is_empty() or not w.at_war(siege["faction"], owner(fort)) \
				or forts_of(owner(fort)).size() <= int(cfg["min_forts_guard"]):
			_lift_siege(fort)                          # guard re-checked at the moment of assault
			continue
		_assault(fort, attackers)


func _assault(fort: String, attackers: Array) -> void:
	var leader: Party = attackers[0]
	var host := Party.new("host_" + fort)
	host.kind = "lord"
	host.name = leader.name
	host.faction = leader.faction
	var before := 0
	for a in attackers:
		for t in Roster.TYPES:
			for tier in 3:
				Roster.add(host.roster, t, tier, a.roster[t][tier])
		before += a.troops()
	var garrison := garrison_party(fort)
	# lords of the owner standing at the fort man the walls too
	var cell: Vector2i = w.settlements[fort]["cell"]
	var defenders := w.parties.filter(func(p): return p.kind == "lord" and p.faction == garrison.faction \
		and p.is_active(w.time) and w.terrain.world_to_cell(p.position).distance_to(cell) <= 1.5)
	var walls := Party.new("walls_" + fort)
	walls.kind = "garrison"
	walls.name = garrison.name
	walls.faction = garrison.faction
	for t in Roster.TYPES:
		for tier in 3:
			Roster.add(walls.roster, t, tier, garrison.roster[t][tier])
	var def_before := 0
	for dp in defenders:
		def_before += dp.troops()
		for t in Roster.TYPES:
			for tier in 3:
				Roster.add(walls.roster, t, tier, dp.roster[t][tier])
	var walls_before := walls.troops()
	var r := AutoResolve.resolve(host, walls, w.role(leader), "garrison", w.terrain.terrain_name(cell), w.battle_rules, w.rng)
	var lost := 1.0 - float(host.troops()) / maxf(1.0, float(before))
	for a in attackers:
		Roster.remove_fraction(a.roster, lost, w.rng)
		a.goal = "idle"
		a.goal_until = -1.0
		a.next_decision = w.time
	var def_lost := 1.0 - float(walls.troops()) / maxf(1.0, float(walls_before))
	Roster.remove_fraction(garrison.roster, def_lost, w.rng)
	for dp in defenders:
		Roster.remove_fraction(dp.roster, def_lost, w.rng)
	w.state[fort]["siege"] = {}
	w._emit("assault", {"fief": fort, "faction": leader.faction, "won": r["winner"] == host, "attackers": attackers.size()})
	if r["winner"] == host:
		capture(fort, leader)
	else:
		w._emit("siege_failed", {"fief": fort, "faction": leader.faction, "party": leader.id})


## `by` (a lord or the player) takes `fort` for their faction and holds it.
func capture(fort: String, by: Party) -> void:
	var old := owner(fort)
	var old_holder: String = w.state[fort]["holder"]
	w.state[fort]["owner"] = by.faction
	w.state[fort]["holder"] = "player" if by.kind == "player" else by.persona_id
	w.state[fort]["siege"] = {}
	w.state[fort]["garrison"] = Roster.make(int(cfg["garrison_after_capture"]), w.cfg["troop_mix"][by.faction], [1, 0, 0], w.rng)
	var key := w._pair(old, by.faction)
	weariness[key] = weariness.get(key, 0.0) + float(cfg["fief_loss_weariness"])
	for p in w.parties:                              # lords who lived there move to another fort of theirs
		if p.kind == "lord" and p.home == fort and p.faction != by.faction:
			var mine := forts_of(p.faction)
			if not mine.is_empty():
				mine.sort_custom(func(x, y): return _dist(p, x) < _dist(p, y))
				p.home = mine[0]
	w._emit("fief_captured", {"fief": fort, "faction": by.faction, "from_faction": old, "by": by.id,
		"by_player": by.kind == "player", "old_holder": old_holder})


func _dist(p: Party, fort: String) -> float:
	return p.position.distance_squared_to(w.terrain.cell_to_world(w.settlements[fort]["cell"]))


# --- the player ------------------------------------------------------------------------------

func player_join(faction: String) -> void:
	w.player.faction = faction
	w._emit("player_joined_faction", {"faction": faction})


func player_leave() -> void:
	var old := w.player.faction
	if old == "":
		return
	w.player.faction = ""
	for id in w._forts:                              # the faction takes back the player's fiefs
		if w.state[id]["holder"] == "player":
			var lords := w.parties.filter(func(p): return p.kind == "lord" and p.faction == owner(id))
			w.state[id]["holder"] = lords[w.rng.randi_range(0, lords.size() - 1)].persona_id if lords else ""
	w._emit("player_left_faction", {"faction": old})


## "" if the player may besiege `fort` now, otherwise why not.
func player_siege_problem(fort: String) -> String:
	if w.player.faction == "":
		return "Swear allegiance to a faction first (J in one of its towns)."
	if not w.at_war(w.player.faction, owner(fort)):
		return "Your faction is not at war with its owner."
	if forts_of(owner(fort)).size() <= int(cfg["min_forts_guard"]):
		return "It is one of their last strongholds; the realms won't allow it."
	var siege: Dictionary = w.state[fort]["siege"]
	if not siege.is_empty() and siege["faction"] != w.player.faction:
		return "Someone else is already besieging it."
	return ""


## The player's assault ended (battle screen closed).
func apply_player_assault(r: Dictionary, fort: String, garrison: Party) -> void:
	w.battle_pending = false
	w.state[fort]["garrison"] = garrison.roster
	for p in w.parties:
		if p.goal == "sieging" and p.goal_target == fort:
			p.goal = "idle"
			p.goal_until = -1.0
			p.next_decision = w.time
	w.state[fort]["siege"] = {}
	if r["winner"] == w.player:
		capture(fort, w.player)
	else:
		w._emit("siege_failed", {"fief": fort, "faction": w.player.faction, "party": w.player.id})
		w._player_driven_off(w.player)
