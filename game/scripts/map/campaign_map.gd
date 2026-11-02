extends Node
## The campaign map controller: the player's party, input, HUD, dialogs and battles, built in code.
## The map itself is drawn by MapView3D; it speaks sim world pixels, so the game logic here never
## deals with 3D coordinates.
##
## Automation (used by agents to check the game without a human):
##   <godot> --path game -- --screenshot=<file.png> [--zoom=0.25] [--frames=120] [--travel]
## renders N frames with vsync off, prints the average FPS, saves a screenshot and quits.
## --travel sends the party across the continent at 4x first, to exercise pathing.

const START_TOWN_FACTION := "faction_05"      # the player starts in the central regency

var terrain: TerrainMap
var player: Party
var view: MapView3D
var hud: Hud
var hovered := ""
var hovered_party := ""
var selected := ""
var battle_screen: BattleScreen
var encounter: EncounterDialog
var reputation: ReputationScreen
var chat: ChatPanel
var _speed_before_battle := 1
var _auto: Dictionary = {}


func _ready() -> void:
	if not GameState.errors.is_empty():
		push_error("cannot start the map: " + "; ".join(GameState.errors))
		get_tree().quit(1)
		return
	terrain = GameState.terrain
	var start_id := _first_town(START_TOWN_FACTION)
	player = Party.new("player", terrain.cell_to_world(GameState.settlements[start_id]["cell"]))
	player.name = "Wanderer"                     # what other players call you in chat
	player.speed = GameState.sim_config["speeds"]["player"]
	var start: Dictionary = GameState.battle_config["player_start"]
	player.roster = Roster.make(int(start["troops"]), start["mix"], start["tiers"], GameState.world.rng)
	player.gold = int(start["gold"])
	player.arrived.connect(_on_player_arrived)
	GameState.world.add_party(player)          # the world moves every party, the player's included
	view = MapView3D.new()
	add_child(view)
	view.setup(terrain, GameState.world, player)

	hud = Hud.new()
	add_child(hud)

	SimClock.ticked.connect(func(h: float) -> void: GameState.world.step(h))
	GameState.world.battle_requested.connect(_on_battle_requested)
	GameState.world.encounter_requested.connect(_on_encounter_requested)
	GameState.world.assault_requested.connect(_on_assault_requested)
	chat = ChatPanel.new()
	add_child(chat)
	chat.persona_clicked.connect(_focus_persona)
	view.focus(player.position)
	view.set_zoom_level(0.6)
	_select(start_id)
	_parse_automation()


func _first_town(faction_id: String) -> String:
	var ids := GameState.settlements.keys().filter(
		func(id): return GameState.settlements[id]["faction"] == faction_id and GameState.settlements[id]["type"] == "town")
	ids.sort()
	return ids[0]


func _process(_delta: float) -> void:
	var pointer = view.pointer_world()           # null when the mouse is off the map (3D sky)
	var h := ""
	var hp: Party = null
	if pointer != null:
		var radius: float = view.hover_radius()
		h = GameState.settlement_near(pointer, radius, view.visible_types())
		hp = null if h != "" else view.party_near(pointer, radius)
	if h != hovered:
		hovered = h
		EventBus.settlement_hovered.emit(h)
	view.set_highlight(hovered, selected)
	view.set_hovered_party(hp.id if hp else "")
	if hp:
		hud.show_party(hp)
	elif hovered_party != "":
		hud.show_settlement(selected)            # back to the selected settlement's card
	hovered_party = hp.id if hp else ""
	if _auto:
		_run_automation()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if battle_screen != null or encounter != null:
			return
		if hovered == "" and hovered_party != "":
			var target: Party = GameState.world.by_id.get(hovered_party)
			if target and target.kind == "lord" and not event.shift_pressed:
				GameState.world.player_meet(target)
				hud.notify("Riding to meet %s. (Shift+click to attack instead.)" % target.name)
			elif target:
				GameState.world.player_attack(target)
				hud.notify("Moving to attack %s." % target.name)
			return
		var pointer = view.pointer_world()
		if pointer == null and hovered == "":
			return                                   # clicked the sky
		var target_cell: Vector2i
		if player.goal in ["attack", "sieging"]:
			if player.goal == "sieging":
				hud.notify("You break camp; the siege is abandoned.")
			player.goal = "idle"
			player.goal_until = -1.0
		if hovered != "":
			_select(hovered)
			target_cell = GameState.settlements[hovered]["cell"]
		else:
			target_cell = terrain.world_to_cell(pointer)
		if not player.set_destination(terrain, target_cell):
			hud.notify("Can't travel there (%s)." % terrain.terrain_name(target_cell))
	elif event is InputEventKey and event.pressed and not event.echo and battle_screen == null and encounter == null:
		match event.keycode:
			KEY_SPACE:
				SimClock.toggle_pause()
			KEY_1:
				SimClock.set_speed(1)
			KEY_2:
				SimClock.set_speed(2)
			KEY_3:
				SimClock.set_speed(4)
			KEY_F:
				view.focus(player.position)
			KEY_ESCAPE:
				_select("")
			KEY_R:
				_hire()
			KEY_J:
				_join()
			KEY_L:
				_leave()
			KEY_B:
				_besiege()
			KEY_X:
				var village := _here(["village"])
				if village == "":
					hud.notify("Stand in a village to raid it.")
				else:
					var why := GameState.world.player_raid(village)
					hud.notify(why if why != "" else "You raid %s and carry off %d gold." % [GameState.settlements[village]["name"],
						int(GameState.sim_config["economy"]["raid_gold"])], 4.0)
			KEY_P:
				if not is_instance_valid(reputation):
					reputation = ReputationScreen.new()
					add_child(reputation)
					reputation.open(GameState.world)


func _select(id: String) -> void:
	selected = id
	hud.show_settlement(id)
	if id != "":
		EventBus.settlement_selected.emit(id)


func _on_player_arrived(cell: Vector2i) -> void:
	EventBus.party_arrived.emit(player.id, cell)
	var here := GameState.settlement_near(terrain.cell_to_world(cell), terrain.cell_size * 0.5)
	if here == "":
		return
	_select(here)
	var s: Dictionary = GameState.settlements[here]
	var note := "Arrived at %s." % s["name"]
	if s["type"] == "town" and player.prisoners > 0:
		var gold: int = player.prisoners * int(GameState.battle_config["ransom_per_prisoner"])
		note += " Ransomed %d prisoners for %d gold." % [player.prisoners, gold]
		player.gold += gold
		player.prisoners = 0
	elif s["type"] == "village":
		note += " Press R to hire its recruits."
	hud.notify(note, 4.0)


func _here(types: Array) -> String:
	return GameState.settlement_near(player.position, terrain.cell_size * 0.8, types)


## J: swear allegiance to the realm that holds the town you are in.
func _join() -> void:
	var town := _here(["town"])
	var w := GameState.world
	if town == "":
		hud.notify("Stand in a town to swear allegiance to its realm.")
		return
	var realm := w.owner(town)
	if player.faction == realm:
		hud.notify("You already serve the %s." % GameState.factions[realm]["name"])
		return
	if player.faction != "":
		w.politics.player_leave()
	w.politics.player_join(realm)
	hud.notify("You swear allegiance to the %s." % GameState.factions[realm]["name"], 4.0)


## L: leave your realm (its members won't forget).
func _leave() -> void:
	if player.faction == "":
		hud.notify("You serve no realm.")
		return
	var name: String = GameState.factions[player.faction]["name"]
	GameState.world.politics.player_leave()
	hud.notify("You renounce the %s. Expect to be called a traitor." % name, 4.0)


## B: besiege the enemy town or castle you are standing at.
func _besiege() -> void:
	var fort := _here(["town", "castle"])
	if fort == "":
		hud.notify("Stand at an enemy town or castle to besiege it.")
		return
	var why := GameState.world.player_start_siege(fort)
	if why != "":
		hud.notify(why, 4.0)
	else:
		hud.notify("You make camp before %s. The assault comes in %d hours." % [GameState.settlements[fort]["name"],
			int(GameState.sim_config["politics"]["player_siege_hours"])], 4.0)


func _on_assault_requested(p: Party, fort: String, garrison: Party) -> void:
	if battle_screen != null:
		return
	if SimClock.speed > 0:
		_speed_before_battle = SimClock.speed
	SimClock.set_speed(0)
	var w := GameState.world
	var battle := Battle.new(p, garrison, "player", "garrison", terrain.terrain_name(GameState.settlements[fort]["cell"]), GameState.battle_config, w.rng)
	battle_screen = BattleScreen.new()
	add_child(battle_screen)
	battle_screen.open(battle)
	battle_screen.closed.connect(func(result: Dictionary, _choice: String) -> void:
		battle_screen = null
		w.politics.apply_player_assault(result, fort, garrison)
		SimClock.set_speed(_speed_before_battle)
		var won: bool = result["winner"] == player
		hud.notify("%s is yours!" % GameState.settlements[fort]["name"] if won else "The assault fails.", 4.0))


## Hire the recruits of the village the player is standing in.
func _hire() -> void:
	var here := GameState.settlement_near(player.position, terrain.cell_size * 0.6, ["village"])
	if here == "":
		hud.notify("Stand in a village to hire recruits.")
		return
	var st: Dictionary = GameState.world.state[here]
	var cost := int(GameState.battle_config["hire_cost"])
	var n: int = mini(st["recruits"], player.gold / cost)
	if n <= 0:
		hud.notify("No recruits here right now." if st["recruits"] == 0 else "You can't afford anyone (%d gold each)." % cost)
		return
	var mix: Array = GameState.sim_config["troop_mix"][GameState.settlements[here]["faction"]]
	for i in n:
		Roster.add(player.roster, Roster.TYPES[Roster._pick(mix, GameState.world.rng)], 0, 1)
	st["recruits"] -= n
	player.gold -= n * cost
	hud.notify("Hired %d recruits for %d gold." % [n, n * cost])


func _on_encounter_requested(_p: Party, lord: Party) -> void:
	_speed_before_battle = SimClock.speed if SimClock.speed > 0 else 1
	SimClock.set_speed(0)
	encounter = EncounterDialog.new()
	add_child(encounter)
	encounter.open(GameState.world, lord)
	encounter.closed.connect(_on_encounter_closed.bind(lord))


func _on_encounter_closed(action: String, lord: Party) -> void:
	encounter = null
	var w := GameState.world
	w.end_encounter()
	if action == "attack" or action == "ambushed":
		w.player_attack(lord)                     # makes them hostile; they're adjacent, so fight now
		w.battle_pending = true
		_on_battle_requested(player, lord)
		return
	SimClock.set_speed(_speed_before_battle)


## A username was clicked in chat: show that lord on the map.
func _focus_persona(pid: String) -> void:
	var p: Party = GameState.world.by_id.get("lord_" + pid)
	if p == null or not p.is_active(GameState.world.time):
		hud.notify("%s is off the map right now." % GameState.personas[pid]["username"])
		return
	view.focus(p.position)
	hud.show_party(p)


func _on_battle_requested(p: Party, enemy: Party) -> void:
	if battle_screen != null:
		return
	if SimClock.speed > 0:
		_speed_before_battle = SimClock.speed
	SimClock.set_speed(0)
	var w := GameState.world
	var battle := Battle.new(p, enemy, "player", w.role(enemy), w.terrain_between(p, enemy), GameState.battle_config, w.rng)
	battle_screen = BattleScreen.new()
	add_child(battle_screen)
	battle_screen.open(battle)
	battle_screen.closed.connect(_on_battle_closed)


func _on_battle_closed(result: Dictionary, choice: String) -> void:
	battle_screen = null
	GameState.world.apply_player_battle(result, choice)
	SimClock.set_speed(_speed_before_battle)
	var won: bool = result["winner"] == player
	hud.notify("Victory!" if won else "Defeat. Your survivors regroup.", 3.0)


# --- automation --------------------------------------------------------------------

func _parse_automation() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			_auto["path"] = arg.trim_prefix("--screenshot=")
		elif arg.begins_with("--zoom="):
			_auto["zoom"] = float(arg.trim_prefix("--zoom="))
		elif arg.begins_with("--frames="):
			_auto["frames"] = int(arg.trim_prefix("--frames="))
		elif arg == "--travel":
			_auto["travel"] = true
		elif arg == "--battle" or arg == "--battle-auto":    # -auto: then auto-resolve, to show the aftermath
			_auto["battle"] = true
			_auto["battle_auto"] = arg == "--battle-auto"
		elif arg.begins_with("--encounter"):
			_auto["encounter"] = arg.trim_prefix("--encounter=") if arg.contains("=") else "alliance"
		elif arg == "--chat":
			_auto["chat"] = true
		elif arg == "--reputation":
			_auto["reputation"] = true
		elif arg == "--siege":
			_auto["siege"] = true
		elif arg.begins_with("--parties="):           # stress: top up with caravans to N active parties, run at 4x
			_auto["parties"] = int(arg.trim_prefix("--parties="))
		elif arg == "--hover-party":                  # point at the lord banner nearest the screen centre
			_auto["hover_party"] = true
		elif arg == "--capture-test":                 # capture a castle, time until it is recoloured
			_auto["capture_test"] = true
		elif arg == "--watch-siege":                  # run at 4x until an AI siege starts, then frame it
			_auto["watch_siege"] = true
		elif arg.begins_with("--focus="):             # centre the camera on a settlement id
			_auto["focus"] = arg.trim_prefix("--focus=")
		elif arg.begins_with("--click="):             # a real mouse move + left click at this pixel
			var xy := arg.trim_prefix("--click=").split(",")
			_auto["click"] = Vector2(float(xy[0]), float(xy[1]))
	if not _auto.has("path"):
		_auto = {}
		return
	view.set_edge_scroll(false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if _auto.has("zoom"):
		view.focus(terrain.world_size() * 0.5)
		view.set_zoom_level(_auto["zoom"])
	if _auto.has("parties"):
		var w := GameState.world
		w.cfg["caravans"]["cap"] = 10000
		for i in 1000:
			if w.parties.filter(func(p): return p.is_active(w.time)).size() >= int(_auto["parties"]):
				break
			w._spawn_caravans()
		player.battle_cooldown_until = 1e9           # no battle screen pausing the measurement
		SimClock.set_speed(4)
		var active := w.parties.filter(func(p): return p.is_active(w.time))
		print("AUTO parties active=%d (lords %d, bandits %d, caravans %d) at 4x" % [active.size(),
			active.filter(func(p): return p.kind == "lord").size(), active.filter(func(p): return p.kind == "bandit").size(),
			active.filter(func(p): return p.kind == "caravan").size()])
	if _auto.get("watch_siege", false):
		SimClock.set_speed(4)
		_auto["frames"] = 100000                       # ends once the siege has been framed
	if _auto.has("focus") and GameState.settlements.has(_auto["focus"]):
		view.focus(terrain.cell_to_world(GameState.settlements[_auto["focus"]]["cell"]))
		_select(_auto["focus"])
	if _auto.get("battle", false):
		# Stage the ambush in open country: in town, the local lords kill the bandits first.
		var w := GameState.world
		var start := terrain.world_to_cell(player.position)
		for r in range(12, 40):
			var c := start + Vector2i(r, r / 2)
			if terrain.is_passable(c) and GameState.settlement_near(terrain.cell_to_world(c), terrain.cell_size * 4) == "":
				player.position = terrain.cell_to_world(c)
				break
		view.focus(player.position)
		var bandit := Party.new("bandits_auto", player.position + Vector2(terrain.cell_size * 0.5, 0))
		bandit.kind = "bandit"
		bandit.name = "Bandits"
		bandit.roster = Roster.make(22, [0.6, 0.4, 0.0], [0.85, 0.15, 0.0], w.rng)
		bandit.gold = 120
		w.add_party(bandit)
		SimClock.set_speed(1)
	if _auto.has("encounter"):
		var w := GameState.world
		var lord: Party = w.parties.filter(func(p): return p.kind == "lord" and p.persona_id == "persona_003")[0]
		player.position = lord.position + Vector2(terrain.cell_size * 0.4, 0)
		view.focus(player.position)
		w.player_meet(lord)
		SimClock.set_speed(1)
	if _auto.get("chat", false):
		SimClock.set_speed(1)
	if _auto.get("reputation", false):
		# a short history: sworn to the regency, beat two lords, released one, captured another
		var w := GameState.world
		w.politics.player_join("faction_05")
		var lords := w.parties.filter(func(p): return p.kind == "lord")
		for i in 4:
			var l: Party = lords[i * 7]
			ChatDirector.on_sim_event("player_battle", {"enemy": l.id, "enemy_kind": "lord", "persona": l.persona_id,
				"player_won": i != 3, "routed": true, "fled": false, "captured": false, "loot": 0, "prisoners": 0})
		ChatDirector.on_sim_event("lord_released", {"party": lords[7].id})
		w.politics.capture(w.politics.forts_of("faction_03")[0], player)
	if _auto.get("siege", false):
		var w := GameState.world
		w.politics.player_join("faction_05")
		var fort: String = w.politics.forts_of("faction_03").filter(func(id): return GameState.settlements[id]["type"] == "castle")[0]
		player.position = terrain.cell_to_world(GameState.settlements[fort]["cell"]) + Vector2(4, 4)
		view.focus(player.position)
		view.set_zoom_level(1.0)
		print("AUTO siege: %s" % w.player_start_siege(fort))
		_select(fort)
	if _auto.get("travel", false):
		var far := _first_town("faction_02")          # the fen clans, far west
		var ok := player.set_destination(terrain, GameState.settlements[far]["cell"])
		print("AUTO travel to %s planned=%s steps=%d" % [far, ok, player.path.size()])
		SimClock.set_speed(4)
		_auto["travel_target"] = far
	_auto["frame"] = 0
	_auto["t0"] = 0


func _run_automation() -> void:
	_auto["frame"] += 1
	if _auto.get("hover_party", false):
		if _auto["frame"] == 1:
			SimClock.set_speed(4)                        # let lords ride out of their forts first
		elif _auto["frame"] == 200:
			SimClock.set_speed(0)                        # hold still so the pointer stays on the banner
			var cam: Camera3D = view.rig.camera
			var centre := get_viewport().get_visible_rect().size * 0.5
			var best: Array = []
			for entry in view.parties.shown:
				if entry[0].kind != "lord" or cam.is_position_behind(entry[1]):
					continue
				# a lord in the open: settlements win the hover over parties, and two banners
				# on one spot would make "which one" a coin toss
				var pos: Vector2 = entry[0].position
				if GameState.settlement_near(pos, terrain.cell_size * 4.0) != "":
					continue
				if view.parties.shown.any(func(o): return o[0] != entry[0] and (o[0].position as Vector2).distance_to(pos) < terrain.cell_size * 2.0):
					continue
				if not Rect2(640, 180, 920, 660).has_point(cam.unproject_position(entry[1])):
					continue                             # keep clear of the HUD card, chat and news panels
				var d := cam.unproject_position(entry[1]).distance_to(centre)
				if best.is_empty() or d < best[1]:
					best = [entry, d]
			if not best.is_empty():
				view.mouse_override = cam.unproject_position(best[0][1]) + Vector2(4, -3)   # a few px off
				_auto["hover_want"] = best[0][0].id
		elif _auto["frame"] == 204 and _auto.has("hover_want"):
			print("AUTO hover: pointing at %s -> hovered '%s' (%s)" % [_auto["hover_want"], hovered_party,
				"card shown" if hovered_party == _auto["hover_want"] else "MISSED"])
	if _auto.get("capture_test", false):
		var fort := "castle_05_02"
		var i: Dictionary = view.models.info[fort]
		var mm: MultiMesh = view.models.groups[i["group"]].multimesh
		if _auto["frame"] == 30:
			var w := GameState.world
			var taker: Party = w.parties.filter(func(p): return p.kind == "lord" and p.faction == "faction_03")[0]
			w.politics.capture(fort, taker)
			_auto["captured_at"] = Time.get_ticks_msec()
			_auto["want"] = GameState.faction_color("faction_03")
			print("AUTO captured %s for faction_03; buffer colour before: %s" % [fort, str(mm.get_instance_custom_data(i["index"]))])
		elif _auto.has("captured_at") and not _auto.has("recoloured"):
			var got: Color = mm.get_instance_custom_data(i["index"])
			if got.is_equal_approx(_auto["want"]):
				_auto["recoloured"] = true
				print("AUTO recoloured after %d ms (buffer %s)" % [Time.get_ticks_msec() - int(_auto["captured_at"]), str(got)])
	if _auto.get("watch_siege", false) and _auto["frame"] % 20 == 0 and not _auto.has("siege_at"):
		for id in GameState.world.state:
			var st: Dictionary = GameState.world.state[id]
			if st.has("siege") and not st["siege"].is_empty():
				print("AUTO siege seen at %s by %s, game hour %.1f" % [id, st["siege"]["faction"], SimClock.hours])
				_auto["siege_at"] = _auto["frame"]
				SimClock.set_speed(1)
				view.focus(terrain.cell_to_world(GameState.settlements[id]["cell"]))
				view.set_zoom_level(1.8)
				_select(id)
				_auto["frames"] = _auto["frame"] + 90 - 10   # shoot 90 frames later (smoke rises)
				break
	if _auto.has("click"):
		var at: Vector2 = _auto["click"]
		if _auto["frame"] == 5:
			view.mouse_override = at                     # pushed events don't move the viewport's mouse
		elif _auto["frame"] == 7:
			var pointer = view.pointer_world()
			_auto["click_cell"] = terrain.world_to_cell(pointer) if pointer != null else Vector2i(-1, -1)
			for pressed in [true, false]:
				var press := InputEventMouseButton.new()
				press.button_index = MOUSE_BUTTON_LEFT
				press.pressed = pressed
				press.position = at
				get_viewport().push_input(press)
		elif _auto["frame"] == 9:
			print("AUTO click %s -> cell %s (%s, hovered '%s'), moving=%s, destination %s" % [str(at), str(_auto["click_cell"]),
				terrain.terrain_name(_auto["click_cell"]), hovered, player.is_moving(), str(player.path[-1]) if player.is_moving() else "-"])
	if _auto.get("battle", false) and battle_screen != null and _auto["frame"] in [40, 60]:
		battle_screen.play("hold" if _auto["frame"] == 40 else "charge")
	if _auto.get("battle_auto", false) and battle_screen != null and _auto["frame"] == 80:
		battle_screen._auto_resolve()
	if _auto.has("encounter") and encounter != null and _auto["frame"] == 50:
		encounter.choose(_auto["encounter"])
	if _auto.get("chat", false) or _auto.get("reputation", false):
		ChatDirector.advance(0.6)                  # fast-forward chat so the panel fills for the shot
	if _auto.get("reputation", false) and _auto["frame"] == 60:
		reputation = ReputationScreen.new()
		add_child(reputation)
		reputation.open(GameState.world)
	if _auto.get("siege", false) and _auto["frame"] % 30 == 0:
		_select(selected)                          # refresh the card
	if _auto["frame"] == 10:                           # skip warm-up frames
		_auto["t0"] = Time.get_ticks_usec()
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		_auto["prof"] = {"process": 0.0, "gpu": 0.0, "cpu_render": 0.0, "draws": 0.0, "n": 0}
	elif _auto["frame"] > 10:                            # per-frame costs, averaged (see the AUTO profile line)
		var vp := get_viewport().get_viewport_rid()
		var pr: Dictionary = _auto["prof"]
		pr["process"] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		pr["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		pr["cpu_render"] += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		pr["draws"] += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		pr["n"] += 1
	if _auto["frame"] < 10 + _auto.get("frames", 120):
		return
	var seconds: float = (Time.get_ticks_usec() - int(_auto["t0"])) / 1_000_000.0
	print("AUTO frames=%d avg_fps=%.1f zoom=%.2f settlements=%d" % [
		_auto.get("frames", 120), _auto.get("frames", 120) / seconds, view.zoom_level(), GameState.settlements.size()])
	var prof: Dictionary = _auto.get("prof", {"n": 0})
	if int(prof["n"]) > 0:
		var n := float(prof["n"])
		print("AUTO profile ms/frame: process %.2f, render cpu %.2f, render gpu %.2f, draw calls %.0f" % [
			prof["process"] / n, prof["cpu_render"] / n, prof["gpu"] / n, prof["draws"] / n])
	if view.parties.sync_calls > 0:
		print("AUTO party sync %.2f ms/frame avg over %d frames; labels %.2f ms/frame" % [
			view.parties.sync_usec_total / 1000.0 / view.parties.sync_calls, view.parties.sync_calls,
			view.labels.draw_usec_total / 1000.0 / maxi(view.labels.draw_calls, 1)])
		print("AUTO labels redrawn %d times" % view.labels.draw_calls)
	if _auto.get("travel", false):
		print("AUTO travel game_hours=%.1f remaining_steps=%d" % [SimClock.hours - 8.0, player.path.size()])
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_auto["path"])
	print("AUTO screenshot %s err=%d" % [_auto["path"], err])
	_auto = {}
	get_tree().quit(0)
