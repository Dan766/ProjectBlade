extends Node
## Turns the world into server chat (autoload "ChatDirector"; also built headless in tests).
##
## Sources:
##   - player battles (World "player_battle"): the lord reacts (beat_by_player[_repeat] /
##     beat_player / player_fled_from_me); streaks, big defeats and renown get the server talking
##   - World events: raids, routs and robbed caravans draw ambient brags and complaints
##   - lord_released: a thank-you; relationship changes for every one of these (Relations)
##   - timers: ambient chatter, scripted conversations, and personas whispering the player first
## Chat runs on its own clock: real seconds of unpaused play, so it reads at human pace at any
## game speed. Messages wait out a typing delay; global chat is rate limited.

signal message_posted(msg: Dictionary)

const AMBIENT_REL := "neutral"            # ambient events use "any"; the band is ignored

var world: World
var db: Node
var cfg: Dictionary
var rng := RandomNumberGenerator.new()
var clock := 0.0
var log: Array[Dictionary] = []           # everything posted, oldest first
var whispers: Dictionary = {}             # persona id -> [msg]
var stats: Dictionary = {}                # trigger kind -> {"triggers": n, "posted": n}
var _queue: Array[Dictionary] = []        # {due, msg}
var _recent_global: Array[float] = []
var _next := {"ambient": 0.0, "conversation": 0.0, "whisper": 0.0}
var _played_threads: Array[String] = []
var _last_world_reaction := -INF
var _last_broadcast: Dictionary = {}      # event -> chat time of the last server-wide comment


func _ready() -> void:
	if GameState.world == null:
		return
	setup(GameState.world, DialogueDB, GameState.chat_config, 1)
	EventBus.sim_event.connect(on_sim_event)


func setup(w: World, dialogue_db: Node, config: Dictionary, seed: int) -> void:
	world = w
	db = dialogue_db
	cfg = config
	rng.seed = seed
	db.cooldown_s = float(cfg["line_cooldown_s"])
	for key in _next:
		_next[key] = clock + _between(cfg["timers"][key + "_s"])


func _process(delta: float) -> void:
	if world != null and not SimClock.is_paused():
		advance(delta)


## Move chat time forward: fire due timers, post due messages.
func advance(dt: float) -> void:
	clock += dt
	if clock >= _next["ambient"]:
		_next["ambient"] = clock + _between(cfg["timers"]["ambient_s"])
		_ambient()
	if clock >= _next["conversation"]:
		_next["conversation"] = clock + _between(cfg["timers"]["conversation_s"])
		play_conversation("ambient")
	if clock >= _next["whisper"]:
		_next["whisper"] = clock + _between(cfg["timers"]["whisper_s"])
		_unprompted_whisper()
	_flush()


func _between(r: Array) -> float:
	return rng.randf_range(float(r[0]), float(r[1]))


# --- speaking ----------------------------------------------------------------------------

## Queue a line from persona `pid` for `event` on `channel`. Returns false if nothing fits.
## Background chatter passes allow_reuse = false: better silent than a repeated line. Reactions
## to the player may reuse the least recently used line as a last resort.
func say(pid: String, event: String, channel: String, ctx: Dictionary = {}, extra_delay: float = 0.0, allow_reuse: bool = false) -> bool:
	if not db.personas.has(pid):
		return false
	var band: String = world.relations.band(pid) if world else "neutral"
	var line: Dictionary = db.pick(pid, event, band, channel, clock, rng, float(cfg["signature_bias"]), allow_reuse)
	if line.is_empty():
		return false
	var persona: Dictionary = db.personas[pid]
	var text: String = db.style(line["text"], persona, rng, cfg["chat_style"]["typo_rate"])
	text = db.fill(text, _ctx(pid, ctx), rng)
	var typing: Dictionary = cfg["typing"]
	var delay := float(typing["base_s"]) + float(typing["per_char_s"]) * text.length() + rng.randf_range(0.0, float(typing["jitter_s"]))
	_queue.append({"due": clock + extra_delay + delay, "msg": {
		"channel": channel, "pid": pid, "name": persona["username"], "faction": persona["faction"],
		"text": text, "event": event, "line_id": line["id"], "picked": clock}})
	return true


## A line spoken right now (face to face in a dialog), not posted to chat. "" if none fits.
func speak_now(pid: String, event: String, channel: String = "face", ctx: Dictionary = {}) -> String:
	if not db.personas.has(pid):
		return ""
	var line: Dictionary = db.pick(pid, event, world.relations.band(pid), channel, clock, rng, float(cfg["signature_bias"]), true)
	if line.is_empty():
		return ""
	var text: String = db.style(line["text"], db.personas[pid], rng, cfg["chat_style"]["typo_rate"])
	return db.fill(text, _ctx(pid, ctx), rng)


func _ctx(pid: String, extra: Dictionary) -> Dictionary:
	var p: Dictionary = db.personas[pid]
	var ctx := {"persona": p["username"], "faction_id": p["faction"],
		"my_faction": db.faction_names.get(p["faction"], "my realm")}
	if world and world.player:
		ctx["player"] = world.player.name
	if p.get("rivals", []).size() > 0 and db.personas.has(p["rivals"][0]):
		ctx["rival"] = db.personas[p["rivals"][0]]["username"]
	if world:
		var enemies := world.factions.keys().filter(func(f): return world.at_war(p["faction"], f))
		if not enemies.is_empty():
			ctx["enemy_faction"] = db.faction_names[enemies[rng.randi_range(0, enemies.size() - 1)]]
	var others: Array = db.faction_names.keys().filter(func(f): return f != p["faction"])
	if not others.is_empty():
		ctx["faction"] = db.faction_names[others[rng.randi_range(0, others.size() - 1)]]
	ctx.merge(extra, true)
	return ctx


func _flush() -> void:
	var limit: Dictionary = cfg["global_rate_limit"]
	_recent_global = _recent_global.filter(func(t): return clock - t < float(limit["per_s"]))
	_queue.sort_custom(func(a, b): return a["due"] < b["due"])
	var keep: Array[Dictionary] = []
	for item in _queue:
		if item["due"] > clock:
			keep.append(item)
			continue
		var msg: Dictionary = item["msg"]
		if msg["channel"] == "global" and _recent_global.size() >= int(limit["messages"]):
			item["due"] = clock + rng.randf_range(2.0, 6.0)      # server is busy: post a bit later
			keep.append(item)
			continue
		msg["t"] = clock
		if msg["channel"] == "global":
			_recent_global.append(clock)
		else:
			whispers.get_or_add(msg["pid"], []).append(msg)
		log.append(msg)
		message_posted.emit(msg)
	_queue = keep


func _count(kind: String, posted: bool) -> void:
	var s: Dictionary = stats.get_or_add(kind, {"triggers": 0, "posted": 0})
	s["triggers"] += 1
	if posted:
		s["posted"] += 1


func _chance(key: String) -> bool:
	return rng.randf() < float(cfg["reactions"][key])


## World events (raids, routs, robberies) happen far faster than people chat (at 1x a game day
## is 24 real seconds), so reactions to them are spaced at least world_reaction_gap_s apart.
func _world_reaction_allowed(kind: String) -> bool:
	if clock - _last_world_reaction < float(cfg["world_reaction_gap_s"]):
		var s: Dictionary = stats.get_or_add(kind + "_throttled", {"triggers": 0, "posted": 0})
		s["triggers"] += 1
		return false
	return true


func _world_reacted(kind: String, ok: bool) -> void:
	_count(kind, ok)
	if ok:
		_last_world_reaction = clock


func _channel() -> String:
	return "whisper" if rng.randf() < float(cfg["reactions"]["whisper_share"]) else "global"


# --- reacting to the world -------------------------------------------------------------------

func on_sim_event(kind: String, data: Dictionary) -> void:
	match kind:
		"player_battle":
			_player_battle(data)
		"lord_released":
			var pid := _persona_of(data["party"])
			if pid != "":
				world.relations.adjust_why(pid, float(world.chat_cfg["relationship"]["released"]), "You released them after a battle.")
				world.relations.count(pid, "released")
				_count("lord_released", _chance("lord_released") and say(pid, "released_by_player", _channel(), {}, 20.0, true))
		"lord_ransomed":
			var pid := _persona_of(data["party"])
			if pid != "":
				world.relations.adjust_why(pid, float(world.chat_cfg["relationship"]["ransomed"]), "You ransomed them.")
				world.relations.count(pid, "ransomed")
		"village_raided":
			if _world_reaction_allowed("village_raided"):
				var ok := false
				if _chance("village_raided"):
					var victim := _random_persona(func(p): return p["faction"] == data["faction"])
					var raider := _persona_of(data["party"])
					ok = victim != "" and say(victim, "ambient_complaint", "global", {"village": db_place(data["village"])})
					if raider != "" and rng.randf() < 0.5:
						ok = say(raider, "ambient_brag", "global", {}, 6.0) or ok
				_world_reacted("village_raided", ok)
		"party_defeated":
			if _world_reaction_allowed("lord_routed"):
				var ok := false
				if _chance("lord_routed"):
					var speaker := _persona_of(data["by"]) if rng.randf() < 0.5 else _persona_of(data["party"])
					var event := "ambient_brag" if speaker == _persona_of(data["by"]) else "ambient_complaint"
					ok = speaker != "" and say(speaker, event, "global")
				_world_reacted("lord_routed", ok)
		"war_declared", "peace_made":
			_war_or_peace(kind, data["a"], data["b"])
		"fief_captured":
			_fief_captured(data)
		"siege_started":
			if data["by_player"] and String(data["holder"]) not in ["", "player"]:
				var holder: String = data["holder"]
				world.relations.adjust_why(holder, float(world.chat_cfg["relationship"]["besieged"]), "You besieged their fief %s." % db_place(data["fief"]))
				_count("player_besieging", say(holder, "player_besieging_my_fief", _channel(), {"fief": db_place(data["fief"])}, 3.0, true))
		"player_raided_village":
			var holder: String = data["holder"]
			var victim := holder if holder not in ["", "player"] else _random_persona(func(p): return p["faction"] == data["faction"])
			if victim != "":
				var village := db_place(data["village"])
				world.relations.adjust_why(victim, float(world.chat_cfg["relationship"]["raided"]), "You burned %s." % village)
				_count("player_raided", say(victim, "player_raided_my_village", _channel(), {"village": village}, 4.0, true))
		"player_joined_faction":
			var f: String = data["faction"]
			for pid in _members(f):
				world.relations.adjust_why(pid, float(world.chat_cfg["relationship"]["joined_faction"]), "You swore allegiance to their realm.")
			var ok := false
			for pid in _pick_members(f, 2):
				ok = say(pid, "player_joined_my_faction", _channel(), {}, 4.0 + 6.0 * rng.randf(), true) or ok
			_count("player_joined", ok)
		"player_left_faction":
			var f: String = data["faction"]
			for pid in _members(f):
				world.relations.adjust_why(pid, float(world.chat_cfg["relationship"]["left_faction"]), "You abandoned their realm.")
			var ok := false
			for pid in _pick_members(f, 3):
				ok = say(pid, "player_left_my_faction", _channel(), {"faction": "no one"}, 3.0 + 8.0 * rng.randf(), true) or ok
			_count("player_left", ok)
		"caravan_robbed":
			if _world_reaction_allowed("caravan_robbed"):
				var ok := false
				if _chance("caravan_robbed"):
					var trader := _random_persona(func(p): return p["faction"] == data["faction"] and p["archetype"] == "trader")
					ok = trader != "" and say(trader, "ambient_complaint", "global")
				_world_reacted("caravan_robbed", ok)


func db_place(settlement_id: String) -> String:
	return world.settlements[settlement_id]["name"] if world and world.settlements.has(settlement_id) else ""


func _persona_of(party_id: String) -> String:
	var p: Party = world.by_id.get(party_id) if world else null
	return p.persona_id if p else ""


func _random_persona(pred: Callable) -> String:
	var ids: Array = db.personas.keys().filter(func(id): return pred.call(db.personas[id]))
	return "" if ids.is_empty() else ids[rng.randi_range(0, ids.size() - 1)]


func _player_battle(d: Dictionary) -> void:
	var rel: Dictionary = world.chat_cfg["relationship"]
	var pid: String = d.get("persona", "")
	var won: bool = d["player_won"]
	var stats_p: Dictionary = world.player_stats
	if pid != "":
		var arch: String = db.personas[pid]["archetype"]
		if won:
			var n := world.relations.count(pid, "beaten_by_player")
			world.relations.adjust_why(pid, float(rel["beaten_by_player_roleplayer"] if arch == "roleplayer" else rel["beaten_by_player"]),
				"You beat them in battle (%d time%s)." % [n, "" if n == 1 else "s"])
			var event := "beat_by_player_repeat" if n >= int(rel["repeat_threshold"]) else "beat_by_player"
			_count("player_beats_lord", _chance("player_beats_lord") and say(pid, event, _channel(), {}, 4.0, true))
		elif d["fled"]:
			_count("player_fled", _chance("player_fled") and say(pid, "player_fled_from_me", _channel(), {}, 4.0, true))
		else:
			world.relations.count(pid, "beat_player")
			world.relations.adjust_why(pid, float(rel["beat_player"]), "They beat you in battle.")
			_count("lord_beats_player", _chance("lord_beats_player") and say(pid, "beat_player", _channel(), {}, 4.0, true))

	if won:
		_fought_alongside(d)
		stats_p["wins"] += 1
		stats_p["streak"] += 1
		var before: int = stats_p["renown"]
		stats_p["renown"] += int(cfg["renown_per_win"].get(d["enemy_kind"], 0))
		if stats_p["streak"] in cfg["streak_thresholds"]:
			_count("streak", _chance("streak") and _broadcast("player_win_streak", 2))
		for threshold in cfg["renown_thresholds"]:
			if before < int(threshold) and stats_p["renown"] >= int(threshold):
				_count("renown", _chance("renown") and _broadcast("player_renown_up", 1))
	else:
		stats_p["losses"] += 1
		stats_p["streak"] = 0
		if float(d.get("player_loss_share", 0.0)) >= 0.6:
			_count("big_defeat", _chance("big_defeat") and _broadcast("player_big_defeat", 2, {"troop_count": str(d.get("player_lost", 40))}))


func _members(faction: String) -> Array:
	return db.personas.keys().filter(func(id): return db.personas[id]["faction"] == faction)


func _pick_members(faction: String, n: int) -> Array:
	var ids := _members(faction)
	ids.shuffle()
	return ids.slice(0, n)


func _fname(faction: String) -> String:
	return db.faction_names.get(faction, "their enemies")


func _war_or_peace(kind: String, a: String, b: String) -> void:
	var ok := false
	for side in [[a, b], [b, a]]:
		for pid in _pick_members(side[0], 1):
			var other := _fname(side[1])
			ok = say(pid, kind, "global", {"enemy_faction": other, "faction": other}, 2.0 + 10.0 * rng.randf(), true) or ok
	_count(kind, ok)
	if ok and rng.randf() < 0.5:
		play_conversation(kind)


func _fief_captured(d: Dictionary) -> void:
	var fief := db_place(d["fief"])
	var old_holder: String = d["old_holder"]
	var rel: Dictionary = world.chat_cfg["relationship"]
	if d["by_player"]:
		var ok := false
		if old_holder not in ["", "player"]:
			world.relations.adjust_why(old_holder, float(rel["fief_taken"]), "You took %s from them." % fief)
			ok = say(old_holder, "player_took_my_fief", _channel(), {"fief": fief}, 3.0, true)
		for pid in _pick_members(d["from_faction"], 1):
			if pid != old_holder:
				ok = say(pid, "player_took_my_fief", "global", {"fief": fief}, 9.0, true) or ok
		for pid in _pick_members(d["faction"], 2):          # your own realm: proud, or jealous
			if db.personas[pid]["archetype"] == "politician":
				world.relations.adjust_why(pid, float(rel["granted_fief_jealousy"]), "You were granted %s over them." % fief)
			ok = say(pid, "player_granted_fief", _channel(), {"fief": fief}, 14.0 + 6.0 * rng.randf(), true) or ok
		_count("player_took_fief", ok)
	else:
		var ok := false
		var winner := _persona_of(d["by"])
		if winner != "":
			ok = say(winner, "my_faction_took_fief", "global", {"fief": fief, "enemy_faction": _fname(d["from_faction"])})
		if old_holder not in ["", "player"] and rng.randf() < 0.5:
			ok = say(old_holder, "ambient_complaint", "global", {"town": fief}, 8.0) or ok
		_count("fief_captured", ok)


## A lord near the player who also wanted that enemy beaten thanks them (fought_alongside_player).
func _fought_alongside(d: Dictionary) -> void:
	if world == null or world.player == null or not _chance("fought_alongside"):
		return
	var sight := float(world.cfg["sight_cells"]) * world.terrain.cell_size
	var foe_faction: String = d.get("enemy_faction", "")
	var near := world.parties.filter(func(p): return p.kind == "lord" and p.is_active(world.time) \
		and p.persona_id != d.get("persona", "") and p.position.distance_to(world.player.position) <= sight \
		and (d["enemy_kind"] == "bandit" or (foe_faction != "" and world.at_war(p.faction, foe_faction)) \
			or bool(world.relations.get_value(p.persona_id, "allied"))))
	if near.is_empty():
		return
	var ally: Party = near[rng.randi_range(0, near.size() - 1)]
	world.relations.adjust_why(ally.persona_id, float(world.chat_cfg["relationship"]["same_side_victory"]), "You fought on the same side.")
	_count("fought_alongside", say(ally.persona_id, "fought_alongside_player", _channel(), {"enemy_faction": _fname(foe_faction)}, 6.0, true))


## `n` personas (one leaning hostile, one leaning friendly when possible) comment on the player.
## Each kind of broadcast has a cooldown: the Phase 6 playtest lost 58 battles in 20 minutes and
## the server commented on every one ("player_big_defeat" x77).
func _broadcast(event: String, n: int, ctx: Dictionary = {}) -> bool:
	var cool := float(cfg.get("broadcast_cooldown_s", {}).get(event, 0.0))
	if clock - float(_last_broadcast.get(event, -INF)) < cool:
		return false
	_last_broadcast[event] = clock
	var ids: Array = db.personas.keys()
	ids.sort_custom(func(a, b): return world.relations.score(a) < world.relations.score(b))
	var picks := [ids[rng.randi_range(0, mini(20, ids.size() - 1))], ids[ids.size() - 1 - rng.randi_range(0, mini(20, ids.size() - 1))]]
	var any := false
	for i in mini(n, picks.size()):
		var channels: Array = db.events.get(event, {}).get("channels", ["global"])
		var ch: String = "whisper" if channels.has("whisper") and rng.randf() < 0.4 else "global"
		any = say(picks[i], event, ch, ctx, 3.0 + 5.0 * i, true) or any
	if any and rng.randf() < 0.5:
		play_conversation(event)
	return any


# --- timers -----------------------------------------------------------------------------------

func _ambient() -> void:
	var events: Dictionary = cfg["ambient_events"]
	var keys := events.keys()
	var weights := keys.map(func(k): return float(events[k]))
	var event: String = keys[Roster._pick(weights, rng)]
	var pid := _random_persona(func(p): return true)
	_count("ambient", pid != "" and say(pid, event, "global"))


## Play a scripted thread whose trigger matches ("ambient" or an event id). Lines keep their
## authored delays; places are fixed for the whole thread, amounts vary per line.
func play_conversation(trigger: String) -> bool:
	var options: Array = db.conversations.filter(func(t): return t["trigger"] == trigger and not _played_threads.has(t["id"]))
	if options.is_empty():
		return false
	var t: Dictionary = options[rng.randi_range(0, options.size() - 1)]
	_played_threads.append(t["id"])
	if _played_threads.size() > 60:
		_played_threads.pop_front()
	var first: Dictionary = db.personas[t["participants"][0]]
	var ctx := {"town": db.fill("{town}", {"faction_id": first["faction"]}, rng),
		"village": db.fill("{village}", {"faction_id": first["faction"]}, rng),
		"fief": db.fill("{fief}", {"faction_id": first["faction"]}, rng)}
	var at := 0.0
	for line in t["lines"]:
		at += float(line["delay_s"])
		var pid: String = line["speaker"]
		var persona: Dictionary = db.personas[pid]
		var text: String = db.fill(db.style(line["text"], persona, rng, cfg["chat_style"]["typo_rate"]), _ctx(pid, ctx), rng)
		_queue.append({"due": clock + at, "msg": {"channel": "global", "pid": pid, "name": persona["username"],
			"faction": persona["faction"], "text": text, "event": "conversation:" + t["id"], "line_id": t["id"]}})
	_count("conversation", true)
	return true


func _unprompted_whisper() -> void:
	if world == null:
		return
	var ids: Array = db.personas.keys()
	ids.sort_custom(func(a, b): return absf(world.relations.score(a)) > absf(world.relations.score(b)))
	var pid: String = ids[rng.randi_range(0, mini(15, ids.size() - 1))]   # strong feelings speak up
	var band: String = world.relations.band(pid)
	var options := ["whisper_taunt", "whisper_challenge", "whisper_alliance_offer", "whisper_beg_help"].filter(
		func(e): return db.events[e]["relationships"].has(band))
	var ok := not options.is_empty() and say(pid, options[rng.randi_range(0, options.size() - 1)], "whisper")
	_count("whisper", ok)
