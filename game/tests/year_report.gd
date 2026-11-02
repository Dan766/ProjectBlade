extends SceneTree
## Politics over time (Phase 5 acceptance; not a unit test):
##   <godot> --headless --path game -s res://tests/year_report.gd -- [--days=365] [--seed=42]
## Every 30 days: forts held per faction, active wars, and politics events so far. Flags any
## faction wiped out, and the smallest fort count seen by day 60 (balance guard).


func _initialize() -> void:
	var days := 365
	var seed := 42
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="):
			days = int(arg.trim_prefix("--days="))
		elif arg.begins_with("--seed="):
			seed = int(arg.trim_prefix("--seed="))
	var gs = load("res://scripts/autoload/game_state.gd").new()
	gs.load_all("res://data/generated", "res://data/world")
	var w: World = gs.new_world(seed)
	var ids := w.factions.keys()
	ids.sort()
	var short := {}
	for f in ids:
		short[f] = String(w.factions[f]["name"]).split(" ")[0]
	var min_by_60 := 999
	var wiped := []
	var t0 := Time.get_ticks_msec()
	print("day  " + "  ".join(ids.map(func(f): return "%9s" % short[f])) + "   wars")
	for d in range(1, days + 1):
		w.step(24.0)
		var counts := ids.map(func(f): return w.politics.forts_of(f).size())
		if d <= 60:
			min_by_60 = mini(min_by_60, counts.min())
		for i in ids.size():
			if counts[i] == 0 and not wiped.has(ids[i]):
				wiped.append(ids[i])
		if d % 30 == 0 or d == days:
			var wars := w.wars.keys().map(func(k): return "%s-%s" % [short[k.split("|")[0]], short[k.split("|")[1]]])
			print("%3d  %s   %s" % [d, "  ".join(counts.map(func(c): return "%9d" % c)), ", ".join(wars)])
	var ev := w.event_counts
	print("\nevents: war_declared %d, peace_made %d, siege_started %d, assault %d, fief_captured %d, siege_failed %d" % [
		ev.get("war_declared", 0), ev.get("peace_made", 0), ev.get("siege_started", 0), ev.get("assault", 0),
		ev.get("fief_captured", 0), ev.get("siege_failed", 0)])
	print("smallest fort count by day 60: %d   factions wiped out: %s   stuck parties: %d" % [min_by_60, str(wiped), w.stuck_parties().size()])
	print("%d days in %d ms" % [days, Time.get_ticks_msec() - t0])
	gs.free()
	quit(0)
