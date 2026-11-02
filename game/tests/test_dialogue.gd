extends TestCase
## Phase 4: DialogueDB lookup/fill/style, persona memory, ChatDirector reactions, and the
## acceptance soak (2 hours of chat: no unfilled placeholders, no line repeated inside its
## cooldown, reactions at their configured rates).

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


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _director(seed: int) -> Array:
	var g := _state()
	var w: World = g.new_world(seed)
	var player := Party.new("player", w.terrain.cell_to_world(w.settlements["town_05_01"]["cell"]))
	player.name = "Wanderer"
	player.roster = Roster.make(30, [0.5, 0.3, 0.2], [1, 0, 0], w.rng)
	w.add_party(player)
	db.last_used.clear()
	var d: Node = load("res://scripts/dialogue/chat_director.gd").new()
	_nodes.append(d)
	d.setup(w, db, g.chat_config, seed)
	w.sim_event.connect(d.on_sim_event)
	return [w, d]


# --- DialogueDB ------------------------------------------------------------------------

func test_bundle_loads_everything() -> void:
	_state()
	check_eq(db.errors.size(), 0, str(db.errors))
	check_eq(db.personas.size(), 120)
	check_eq(db.pools.size(), 8)
	check_eq(db.signatures.size(), 120)
	check_eq(db.conversations.size(), 300)


func test_fill_never_leaves_a_brace_and_respects_ctx() -> void:
	_state()
	var rng := _rng(1)
	var all := "{player} {persona} {town} {castle} {village} {fief} {faction} {my_faction} {enemy_faction} {rival} {troop_count} {gold}"
	var out: String = db.fill(all, {"player": "Wanderer", "town": "Ondrac"}, rng)
	check(not out.contains("{") and not out.contains("}"), out)
	check(out.begins_with("Wanderer "), out)
	check(out.contains(" Ondrac "), out)
	var golds := {}
	for i in 20:
		golds[db.fill("{gold}", {}, rng)] = true
	check(golds.size() > 5, "amounts vary per occurrence")
	check_eq(db.fill("broken {brace", {}, rng), "broken brace")


func test_style_lowercases_and_keeps_placeholders() -> void:
	_state()
	var p := {"chat_style": {"case": "lower", "typos": "none"}}
	check_eq(db.style("GG {player} You Lost", p, _rng(2), {"none": 0.0}), "gg {player} you lost")
	var noisy: String = db.style("absolutely everything changes tonight", {"chat_style": {"case": "sentence", "typos": "frequent"}}, _rng(3), {"frequent": 1.0})
	check(noisy != "absolutely everything changes tonight" and noisy.length() == 37, "typos swap letters, keep length: " + noisy)
	var punct: String = db.style("wait!! what?? ok.", {"chat_style": {"case": "sentence", "typos": "frequent"}}, _rng(4), {"frequent": 1.0})
	check_eq(punct.count("!"), 2, "punctuation never moves: " + punct)
	check(punct.ends_with("ok."), "punctuation never moves: " + punct)


func test_pick_prefers_signature_and_honours_cooldown() -> void:
	_state()
	db.last_used.clear()
	var rng := _rng(4)
	var pid := "persona_003"                       # HelmDodger, a griefer
	var sig_events: Array = db.signatures[pid]["signature"].keys()
	var ev: String = sig_events[0]
	var line: Dictionary = db.signatures[pid]["signature"][ev][0]
	var picked: Dictionary = db.pick(pid, ev, line["rel"] if line["rel"] != "any" else "neutral", line["channel"], 0.0, rng, 1.0)
	check(picked["id"].begins_with("sig."), "bias 1.0 picks the persona's own line: %s" % picked["id"])
	db.last_used.clear()
	var seen := {}
	var repeats := 0
	for i in 8:
		var l: Dictionary = db.pick(pid, "ambient_chatter", "neutral", "global", float(i), rng, 0.0)
		if seen.has(l["id"]):
			repeats += 1
		seen[l["id"]] = true
	check_eq(repeats, 0, "no line repeats while fresh ones remain")
	check_eq(db.rel_key("ambient_chatter", "hostile"), "any")
	check_eq(db.rel_key("beat_player", "hostile"), "hostile")


# --- persona memory ----------------------------------------------------------------------

func test_relations_start_by_archetype_and_band() -> void:
	var w: World = _state().new_world(2)
	var r := w.relations
	var griefers := w.personas.keys().filter(func(id): return w.personas[id]["archetype"] == "griefer")
	var newbies := w.personas.keys().filter(func(id): return w.personas[id]["archetype"] == "newbie")
	var avg := func(ids): return ids.map(func(id): return r.score(id)).reduce(func(a, b): return a + b, 0.0) / ids.size()
	check(avg.call(griefers) < avg.call(newbies) - 20, "griefers start colder than newbies")
	var pid: String = griefers[0]
	r.adjust(pid, -500)
	check_eq(r.score(pid), -100.0, "clamped")
	check_eq(r.band(pid), "hostile")
	r.adjust(pid, 160)
	check_eq(r.band(pid), "friendly")


func test_grudge_makes_aggressive_lords_hunt_the_player() -> void:
	var pair := _director(3)
	var w: World = pair[0]
	var lord: Party = w.parties.filter(func(p): return p.kind == "lord" and float(w.weights(p)["aggression"]) >= 0.6)[0]
	check(not w.hostile(w.player, lord), "not hostile at the start")
	w.relations.adjust(lord.persona_id, -200)
	check(w.hostile(w.player, lord), "a deep grudge plus aggression means they hunt you")


# --- ChatDirector -------------------------------------------------------------------------

func _lord(w: World) -> Party:
	return w.parties.filter(func(p): return p.kind == "lord")[0]


func test_beating_a_lord_draws_a_reaction_and_a_grudge() -> void:
	var pair := _director(4)
	var w: World = pair[0]
	var d: Node = pair[1]
	var lord := _lord(w)
	var before := w.relations.score(lord.persona_id)
	var events := []
	for i in 3:
		d.on_sim_event("player_battle", {"enemy": lord.id, "enemy_kind": "lord", "persona": lord.persona_id,
			"player_won": true, "routed": true, "fled": false, "captured": false, "loot": 0, "prisoners": 0})
	d.advance(60.0)
	var mine: Array = d.log.filter(func(m): return m["pid"] == lord.persona_id and not m["event"].begins_with("ambient"))
	check_eq(mine.size(), 3, "one reaction per battle")
	var kinds: Array = mine.map(func(m): return m["event"])
	kinds.sort()                                  # typing delays make simultaneous reactions post in any order
	check_eq(kinds, ["beat_by_player", "beat_by_player", "beat_by_player_repeat"])
	check(w.relations.score(lord.persona_id) < before, "they like you less")
	for m in mine:
		check(m["text"].length() > 1 and not m["text"].contains("{"), m["text"])


func test_release_is_remembered_kindly() -> void:
	var pair := _director(5)
	var w: World = pair[0]
	var d: Node = pair[1]
	var lord := _lord(w)
	var before := w.relations.score(lord.persona_id)
	d.on_sim_event("lord_released", {"party": lord.id})
	d.advance(60.0)
	check(w.relations.score(lord.persona_id) > before + 20, "released lords warm to you")
	check(d.log.any(func(m): return m["event"] == "released_by_player"), "and say so")


func test_two_hour_soak() -> void:
	var pair := _director(6)
	var w: World = pair[0]
	var d: Node = pair[1]
	var lords := w.parties.filter(func(p): return p.kind == "lord")
	var rng := _rng(99)
	var t0 := Time.get_ticks_msec()
	for s in 7200:
		d.advance(1.0)
		w.step(0.25)                               # 30 game hours per chat hour
		if s % 150 == 75:
			var lord: Party = lords[rng.randi_range(0, lords.size() - 1)]
			d.on_sim_event("player_battle", {"enemy": lord.id, "enemy_kind": "lord", "persona": lord.persona_id,
				"player_won": rng.randf() < 0.6, "routed": true, "fled": false, "captured": false, "loot": 0,
				"prisoners": 0, "player_loss_share": rng.randf()})
	var msgs: Array = d.log
	var leaks := msgs.filter(func(m): return m["text"].contains("{") or m["text"].contains("}"))
	check_eq(leaks.size(), 0, "unfilled placeholders: %s" % str(leaks.slice(0, 3)))
	# no pooled or signature line twice inside its cooldown
	var last := {}
	var too_soon := []
	for m in msgs:
		if m["event"].begins_with("conversation:"):
			continue
		# the cooldown is enforced when a line is picked; posting can lag behind (typing, rate limit)
		if last.has(m["line_id"]) and m["picked"] - last[m["line_id"]] < d.cfg["line_cooldown_s"]:
			too_soon.append(m["line_id"])
		last[m["line_id"]] = m["picked"]
	check_eq(too_soon.size(), 0, "lines repeated inside the cooldown: %s" % str(too_soon.slice(0, 5)))
	for kind in ["player_beats_lord", "lord_beats_player"]:
		var s: Dictionary = d.stats.get(kind, {"triggers": 0, "posted": 0})
		check(s["triggers"] > 0 and s["posted"] == s["triggers"], "%s posts every time: %s" % [kind, str(s)])
	var raids: Dictionary = d.stats.get("village_raided", {"triggers": 0, "posted": 0})
	if raids["triggers"] >= 40:
		var rate: float = raids["posted"] / float(raids["triggers"])
		check(absf(rate - float(d.cfg["reactions"]["village_raided"])) < 0.12, "raid reactions near the configured rate: %.2f" % rate)
	var per_min := msgs.size() / 120.0
	var whispers := msgs.filter(func(m): return m["channel"] == "whisper").size()
	var convs: int = d.stats.get("conversation", {"posted": 0})["posted"]
	print("     2h soak: %d messages (%.1f/min), %d whispers, %d conversations, raid reactions %s, %d ms" % [
		msgs.size(), per_min, whispers, convs, str(raids), Time.get_ticks_msec() - t0])
	check(per_min > 3.0 and per_min < 20.0, "chat pace %.1f msgs/min" % per_min)
	check(whispers > 20, "personas whisper the player")
	check(convs > 20, "scripted conversations play")


func test_chat_survives_real_world_pace() -> void:
	# At 1x one game hour passes per real second: ~15 raids per real minute. World-event reactions
	# must be throttled so global chat stays readable.
	var pair := _director(8)
	var w: World = pair[0]
	var d: Node = pair[1]
	for s in 600:
		d.advance(1.0)
		w.step(1.0)
	var world_reactions: int = d.log.filter(func(m): return m["event"] in ["ambient_brag", "ambient_complaint"]).size()
	var per_min: float = d.log.size() / 10.0
	print("     1x pace, 10 min: %d messages (%.1f/min), %d brag/complaint, throttled %s" % [
		d.log.size(), per_min, world_reactions, str(d.stats.get("village_raided_throttled", {}))])
	check(per_min < 16.0, "chat stays readable at 1x: %.1f msgs/min" % per_min)
	check(world_reactions <= 10 * 60 / int(d.cfg["world_reaction_gap_s"]) * 2 + 20, "world reactions throttled: %d" % world_reactions)
