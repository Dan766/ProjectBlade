extends SceneTree
## Automated playtest (Phase 6; not a unit test):
##   <godot> --headless --path game -s res://tests/playtest.gd -- [--minutes=20] [--seed=7] [--out=<file>]
## A scripted bot plays at real 1x pace (world: 1 game hour per second; chat: real seconds):
## fights bandits, joins the regency, attacks enemy lords, raids, besieges, leaves, fights on.
## Battles it is drawn into (ambushes, grudges) are fought on the spot. Writes a timestamped chat
## transcript with the bot's actions marked, and prints chat metrics for tuning.

const PLAYER_EVENTS := ["beat_by_player", "beat_by_player_repeat", "beat_player", "player_fled_from_me",
	"released_by_player", "fought_alongside_player", "player_besieging_my_fief", "player_took_my_fief",
	"player_raided_my_village", "player_joined_my_faction", "player_left_my_faction", "player_granted_fief",
	"player_win_streak", "player_big_defeat", "player_renown_up"]

var w: World
var d: Node
var transcript: PackedStringArray = []
var _pending: Array = []                     # [kind, args] requested during a world step


func _initialize() -> void:
	var minutes := 20
	var seed := 7
	var out := "res://../pipeline/out/reports/playtest_transcript.txt"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--minutes="):
			minutes = int(arg.trim_prefix("--minutes="))
		elif arg.begins_with("--seed="):
			seed = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs = load("res://scripts/autoload/game_state.gd").new()
	gs.load_all("res://data/generated", "res://data/world")
	var db = load("res://scripts/autoload/dialogue_db.gd").new()
	db.load_bundle("res://data/generated")
	w = gs.new_world(seed)
	var p := Party.new("player", w.terrain.cell_to_world(w.settlements["town_05_01"]["cell"]))
	p.name = "Wanderer"
	p.roster = Roster.make(45, [0.45, 0.3, 0.25], [0.5, 0.35, 0.15], w.rng)
	p.gold = 800
	w.add_party(p)
	d = load("res://scripts/dialogue/chat_director.gd").new()
	d.setup(w, db, gs.chat_config, seed)
	w.sim_event.connect(d.on_sim_event)
	w.battle_requested.connect(func(pl, e): _pending.append(["battle", e]))
	w.assault_requested.connect(func(pl, f, g): _pending.append(["assault", [f, g]]))
	w.encounter_requested.connect(func(pl, l): w.end_encounter())
	d.message_posted.connect(_on_message)

	var t0 := Time.get_ticks_msec()
	var plan := {60: "attack_bandit", 180: "join", 300: "attack_enemy_lord", 420: "raid", 540: "attack_enemy_lord",
		600: "siege", 780: "attack_enemy_lord", 900: "leave", 1020: "attack_bandit", 1140: "attack_any_lord"}
	for s in minutes * 60:
		if plan.has(s):
			_act(plan[s])
		d.advance(1.0)
		w.step(1.0)
		while not _pending.is_empty():
			var job: Array = _pending.pop_front()
			if job[0] == "battle":
				_fight(job[1])
			else:
				_assault(job[1][0], job[1][1])
	_report(minutes, Time.get_ticks_msec() - t0)
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(transcript) + "\n")
		print("transcript: %s (%d lines)" % [ProjectSettings.globalize_path(out), transcript.size()])
	d.free()
	db.free()
	gs.free()
	quit(0)


func _stamp() -> String:
	return "[%02d:%02d]" % [int(d.clock) / 60, int(d.clock) % 60]


func _on_message(m: Dictionary) -> void:
	var tag := "whisper" if m["channel"] == "whisper" else "global "
	transcript.append("%s (%s) %s: %s   <%s>" % [_stamp(), tag, m["name"], m["text"], m["event"]])


func _note(text: String) -> void:
	transcript.append("%s === BOT: %s" % [_stamp(), text])


func _nearest(pred: Callable) -> Party:
	var best: Party = null
	for q in w.parties:
		if q.kind != "player" and q.is_active(w.time) and pred.call(q):
			if best == null or q.position.distance_squared_to(w.player.position) < best.position.distance_squared_to(w.player.position):
				best = q
	return best


func _act(action: String) -> void:
	match action:
		"attack_bandit", "attack_enemy_lord", "attack_any_lord":
			var target := _nearest(func(q):
				if action == "attack_bandit":
					return q.kind == "bandit"
				if action == "attack_any_lord":
					return q.kind == "lord"
				return q.kind == "lord" and w.player.faction != "" and w.at_war(w.player.faction, q.faction))
			if target:
				w.player.position = target.position + Vector2(40, 0)      # bot shortcut: ride up close
				w.player_attack(target)
				_note("attacks %s (%s, %d troops)" % [target.name, target.kind, target.troops()])
		"join":
			w.politics.player_join("faction_05")
			_note("swears allegiance to the %s" % w.factions["faction_05"]["name"])
		"leave":
			_note("renounces the %s" % w.factions[w.player.faction]["name"] if w.player.faction != "" else "has no realm to leave")
			w.politics.player_leave()
		"raid":
			var v: String = w.settlements.keys().filter(func(id): return w.settlements[id]["type"] == "village" \
				and w.player.faction != "" and w.at_war(w.player.faction, w.owner(id)) and w.state[id]["raided_until"] < w.time)[0]
			w.player.position = w.terrain.cell_to_world(w.settlements[v]["cell"])
			var why := w.player_raid(v)
			_note("raids %s %s" % [w.settlements[v]["name"], "" if why == "" else "(refused: %s)" % why])
		"siege":
			for fort in w._forts:
				if w.player.faction != "" and w.politics.player_siege_problem(fort) == "":
					w.player.position = w.terrain.cell_to_world(w.settlements[fort]["cell"])
					var why := w.player_start_siege(fort)
					_note("besieges %s %s" % [w.settlements[fort]["name"], "" if why == "" else "(refused: %s)" % why])
					return
			_note("finds no fort to besiege")


func _fight(enemy: Party) -> void:
	var b := Battle.new(w.player, enemy, "player", w.role(enemy), w.terrain_between(w.player, enemy), w.battle_rules, w.rng)
	while not b.over:
		var guess: String = "hold" if w.role(enemy) in ["griefer", "bandit", "roleplayer"] else ["advance", "flank", "hold"][w.rng.randi_range(0, 2)]
		b.play_round(guess, b.ai_command(enemy, w.player, w.role(enemy), b.last_cmd["a"]))
	var r := b.finish()
	var choice := ""
	if r.get("captured", false):
		choice = "release" if w.rng.randf() < 0.5 else "ransom"
	_note("battle vs %s: %s%s" % [enemy.name, "won" if r["winner"] == w.player else "lost", " (captured, %s)" % choice if choice else ""])
	w.apply_player_battle(r, choice)
	if w.player.troops() < 20:                                          # bot shortcut: refill between fights
		for i in 25:
			Roster.add(w.player.roster, Roster.TYPES[i % 3], 0, 1)


func _assault(fort: String, garrison: Party) -> void:
	var b := Battle.new(w.player, garrison, "player", "garrison", "plains", w.battle_rules, w.rng)
	b.auto_play()
	var r := b.finish()
	_note("assaults %s: %s" % [w.settlements[fort]["name"], "taken" if r["winner"] == w.player else "repulsed"])
	w.politics.apply_player_assault(r, fort, garrison)


func _report(minutes: int, ms: int) -> void:
	var msgs: Array = d.log
	var per_min := {}
	for m in msgs:
		per_min[int(m["t"]) / 60] = per_min.get(int(m["t"]) / 60, 0) + 1
	var about_player := msgs.filter(func(m): return PLAYER_EVENTS.has(m["event"]) or m["channel"] == "whisper").size()
	var texts := {}
	var dupes := 0
	for m in msgs:
		var k: String = m["text"].to_lower()
		if texts.has(k):
			dupes += 1
		texts[k] = true
	var speakers := {}
	for m in msgs:
		speakers[m["name"]] = speakers.get(m["name"], 0) + 1
	var top := speakers.keys()
	top.sort_custom(func(a, b): return speakers[a] > speakers[b])
	var kinds := {}
	for m in msgs:
		var e: String = m["event"].get_slice(":", 0)
		kinds[e] = kinds.get(e, 0) + 1
	var lines := PackedStringArray([
		"PLAYTEST %d min, %d ms" % [minutes, ms],
		"messages %d (%.1f/min), per minute: %s" % [msgs.size(), msgs.size() / float(minutes), str(range(minutes).map(func(i): return per_min.get(i, 0)))],
		"about the player (player events + whispers): %d (%.0f%%)" % [about_player, 100.0 * about_player / maxf(1, msgs.size())],
		"whispers %d, distinct speakers %d, exact repeats %d" % [msgs.filter(func(m): return m["channel"] == "whisper").size(), speakers.size(), dupes],
		"top speakers: %s" % ", ".join(top.slice(0, 5).map(func(n): return "%s %d" % [n, speakers[n]])),
		"by event: %s" % str(kinds),
		"player: %s, renown %d, gold %d, troops %d" % [str(w.player_stats), w.player_stats["renown"], w.player.gold, w.player.troops()],
	])
	for l in lines:
		print(l)
	transcript.insert(0, "\n".join(lines) + "\n")
